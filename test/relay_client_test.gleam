//// `relay_client` のテスト。URL の変換、購読の照合の判断（`sync`）、および
//// ループバックの WebSocket サーバーへ本物の `relay_client` を接続した再試行の配線を
//// 確かめる。

import gleam/dynamic
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/set
import gleam/string
import mist
import nostr_no_su/app
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/nostr/filter.{Filter}
import nostr_no_su/nostr/message
import nostr_no_su/relay_client.{
  type SubscriptionState, type Subscriptions, Requested, Retried,
  SubscriptionState, Sync,
}
import nostr_no_su/relay_connection
import stratus
import support/signed_event

/// 取り除くのは先頭のスキームだけで、以降に現れる "://" は残す。
pub fn label_strips_only_the_scheme_test() {
  assert relay_client.label("ws://127.0.0.1:7777") == "127.0.0.1:7777"
  assert relay_client.label("wss://relay.example/wss://x")
    == "relay.example/wss://x"
  assert relay_client.label("relay.example") == "relay.example"
}

/// `wss` は、stratus が TLS ソケットに戻す https リクエストになる。
pub fn to_request_maps_wss_to_https_test() {
  let assert Ok(req) = relay_client.to_request("wss://relay.example/path")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
  assert req.path == "/path"
}

/// `ws` はポートも含めてそのまま平文の http リクエストになる。
pub fn to_request_maps_ws_to_http_test() {
  let assert Ok(req) = relay_client.to_request("ws://127.0.0.1:7777")
  assert req.scheme == http.Http
  assert req.host == "127.0.0.1"
  assert req.port == Some(7777)
}

/// それ以外のスキームは手を加えずそのまま通す。
pub fn to_request_leaves_other_schemes_alone_test() {
  let assert Ok(req) = relay_client.to_request("https://relay.example")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
}

// --- 接続の失敗の理由 ---

/// ハンドシェイクの失敗は stratus が組み立てた文をそのまま使う。
pub fn describe_start_error_keeps_the_handshake_failure_test() {
  assert relay_client.describe_start_error(actor.InitFailed(
      "WebSocket handshake failed: Sock(Econnrefused)",
    ))
    == "WebSocket handshake failed: Sock(Econnrefused)"
}

/// 初期化の中でプロセスが落ちたときの終了理由（スタックトレースを含みうる）は
/// 1 行の理由に含めない。同じ内容はクラッシュレポートに出る。
pub fn describe_start_error_omits_the_exit_reason_test() {
  assert relay_client.describe_start_error(
      actor.InitExited(process.Abnormal(dynamic.string("stacktrace"))),
    )
    == "WebSocket client exited during the handshake"
}

/// ハンドシェイクがタイムアウトした場合の理由。
pub fn describe_start_error_reports_a_timeout_test() {
  assert relay_client.describe_start_error(actor.InitTimeout)
    == "WebSocket handshake timed out"
}

/// `.invalid` は RFC 6761 で名前解決に必ず失敗することが定められた予約ドメインで、
/// 名前解決の失敗（vendor のパッチ 0003 が扱う `nxdomain`）を安定して再現できる。
/// この経路が回帰すると、`InitExited` のスタックトレースを含む文が返る。
pub fn start_reports_an_unresolvable_host_as_a_handshake_failure_test() {
  assert relay_client.start(
      "ws://relay.invalid:7777",
      fn() { Ok([]) },
      fn(_event) { Nil },
      relay_client.subscription_retry_delay_ms,
    )
    == Error("WebSocket handshake failed: Sock(Nxdomain)")
}

// --- handle_text の単体テスト ---

/// リレーが購読 `sub` に配信する EVENT メッセージ。
fn event_frame(sent: Event) -> String {
  json.preprocessed_array([
    json.string("EVENT"),
    json.string("sub"),
    event.to_json(sent),
  ])
  |> json.to_string
}

/// 署名の合わないイベントは `handle_event` に渡さず、正しいイベントは渡す。署名は
/// 別のイベントのものに差し替えるので、形式と id は正しいまま署名だけが合わない。
pub fn handle_text_drops_an_event_with_an_invalid_signature_test() {
  let delivered = process.new_subject()
  let deliver = process.send(delivered, _)
  let genuine = signed_event.new(1, "genuine")
  let forged = Event(..genuine, sig: signed_event.new(1, "other").sig)

  relay_client.handle_text("test", event_frame(forged), deliver)
  assert process.receive(delivered, 0) == Error(Nil)

  relay_client.handle_text("test", event_frame(genuine), deliver)
  let assert Ok(verified) = process.receive(delivered, 0)
  assert event.verified_event(verified) == genuine
}

// --- sync の単体テスト ---

/// 照合で使う購読 id。
const bunker = "bunker"

/// 購読 1 件ぶんのフィルター。
fn bunker_filter() -> filter.Filter {
  Filter(..filter.new(), kinds: Some([24_133]))
}

/// 同じ id で中身の違うフィルター。置き換えの REQ を確かめるために使う。
fn other_bunker_filter() -> filter.Filter {
  Filter(..filter.new(), kinds: Some([24_133]), limit: Some(1))
}

/// 開いている購読と予約から作った状態。世代は 5 から数える。
fn state_with(
  open: List(String),
  retry: option.Option(Int),
) -> SubscriptionState {
  SubscriptionState(open: set.from_list(open), retry: retry, next_generation: 5)
}

/// 評価されたことを `calls` へ報告してから `result` を返すサンク。
fn reporting(
  calls: Subject(Nil),
  result: Result(List(#(String, filter.Filter)), Nil),
) -> Subscriptions {
  fn() {
    process.send(calls, Nil)
    result
  }
}

/// サンクが評価されたかどうか。`sync` は呼び出したプロセスの中で評価するので、
/// 報告はすでに届いている。
fn evaluated(calls: Subject(Nil)) -> Bool {
  process.receive(calls, 0) == Ok(Nil)
}

/// すでに届いている評価の報告を捨てる。
fn drain(calls: Subject(Nil)) -> Nil {
  case evaluated(calls) {
    True -> drain(calls)
    False -> Nil
  }
}

/// 何も開いていない状態と 1 件の定義からは、その REQ を送って開く。
pub fn sync_opens_a_wanted_subscription_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([], None),
      Requested,
      reporting(calls, Ok([#(bunker, bunker_filter())])),
    )
  assert synced
    == Sync(
      state: state_with([bunker], None),
      messages: [message.Req(bunker, bunker_filter())],
      schedule_retry: None,
    )
  assert evaluated(calls)
}

/// 定義から消えた購読には CLOSE を送る。空の #p の REQ は送らない。
pub fn sync_closes_a_subscription_that_is_no_longer_wanted_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([bunker], None),
      Requested,
      reporting(calls, Ok([])),
    )
  assert synced
    == Sync(
      state: state_with([], None),
      messages: [message.Close(bunker)],
      schedule_retry: None,
    )
}

/// 開いている購読の定義が変わったら、同じ id の REQ で置き換え、CLOSE は送らない。
pub fn sync_replaces_an_open_subscription_without_closing_it_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([bunker], None),
      Requested,
      reporting(calls, Ok([#(bunker, other_bunker_filter())])),
    )
  assert synced.messages == [message.Req(bunker, other_bunker_filter())]
  assert synced.state == state_with([bunker], None)
}

/// 何も開いておらず定義も空なら、何も送らない。
pub fn sync_with_nothing_open_and_nothing_wanted_sends_nothing_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(state_with([], None), Requested, reporting(calls, Ok([])))
  assert synced
    == Sync(state: state_with([], None), messages: [], schedule_retry: None)
}

/// 予約が無いのに届いた再試行（解いた予約の遅れたタイマー）は、定義を評価せず、
/// 状態も変えない。
pub fn sync_drops_a_retry_without_a_reservation_test() {
  let calls = process.new_subject()
  let state = state_with([bunker], None)
  let synced = relay_client.sync(state, Retried(1), reporting(calls, Ok([])))
  assert synced == Sync(state: state, messages: [], schedule_retry: None)
  assert !evaluated(calls)
}

/// 別の世代の予約があるときに届いた再試行（置き換わった予約のタイマー）も捨てる。
pub fn sync_drops_a_retry_of_another_generation_test() {
  let calls = process.new_subject()
  let state = state_with([bunker], Some(2))
  let synced = relay_client.sync(state, Retried(1), reporting(calls, Ok([])))
  assert synced == Sync(state: state, messages: [], schedule_retry: None)
  assert !evaluated(calls)
}

/// 現在の予約の再試行が定義を得たら、照合して予約を解く。
pub fn sync_a_successful_retry_clears_the_reservation_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([], Some(1)),
      Retried(1),
      reporting(calls, Ok([#(bunker, bunker_filter())])),
    )
  assert synced
    == Sync(
      state: state_with([bunker], None),
      messages: [message.Req(bunker, bunker_filter())],
      schedule_retry: None,
    )
  assert evaluated(calls)
}

/// 現在の予約の再試行が定義を得られなければ、購読を変えずに新しい世代で予約し直す。
pub fn sync_a_failed_retry_reserves_a_new_generation_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([bunker], Some(1)),
      Retried(1),
      reporting(calls, Error(Nil)),
    )
  assert synced
    == Sync(
      state: SubscriptionState(
        open: set.from_list([bunker]),
        retry: Some(5),
        next_generation: 6,
      ),
      messages: [],
      schedule_retry: Some(5),
    )
  assert evaluated(calls)
}

/// 予約中でも、張り直しの依頼が定義を得れば予約を解く。
pub fn sync_a_successful_request_clears_the_reservation_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([], Some(1)),
      Requested,
      reporting(calls, Ok([#(bunker, bunker_filter())])),
    )
  assert synced.state == state_with([bunker], None)
  assert synced.schedule_retry == None
}

/// 張り直しの依頼が定義を得られなければ、開いている購読を閉じずに予約する。
pub fn sync_a_failed_request_keeps_the_open_subscriptions_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([bunker], None),
      Requested,
      reporting(calls, Error(Nil)),
    )
  assert synced
    == Sync(
      state: SubscriptionState(
        open: set.from_list([bunker]),
        retry: Some(5),
        next_generation: 6,
      ),
      messages: [],
      schedule_retry: Some(5),
    )
}

/// 予約中に張り直しの依頼が定義を得られなくても、予約を増やさない。
pub fn sync_a_failed_request_keeps_a_single_reservation_test() {
  let calls = process.new_subject()
  let state = state_with([bunker], Some(1))
  let synced = relay_client.sync(state, Requested, reporting(calls, Error(Nil)))
  assert synced == Sync(state: state, messages: [], schedule_retry: None)
  assert evaluated(calls)
}

/// 失敗、成功、失敗の順に照合した後、1 回目の失敗で予約した古い世代のタイマーは
/// 評価せず、現在の世代のタイマーだけを評価する。予約の有無だけで判断する実装では、
/// 古いタイマーも評価して再試行の系列が 2 本になる。
pub fn sync_ignores_the_timer_of_an_old_generation_test() {
  let calls = process.new_subject()
  let failing = reporting(calls, Error(Nil))
  let succeeding = reporting(calls, Ok([#(bunker, bunker_filter())]))

  let first =
    relay_client.sync(relay_client.new_subscription_state(), Requested, failing)
  assert first.schedule_retry == Some(1)
  let second = relay_client.sync(first.state, Requested, succeeding)
  assert second.state.retry == None
  let third = relay_client.sync(second.state, Requested, failing)
  assert third.schedule_retry == Some(2)
  drain(calls)

  let stale = relay_client.sync(third.state, Retried(1), succeeding)
  assert !evaluated(calls)
  assert stale == Sync(state: third.state, messages: [], schedule_retry: None)

  let _current = relay_client.sync(third.state, Retried(2), succeeding)
  assert evaluated(calls)
}

// --- ループバックの WebSocket サーバーを使うテスト ---

/// テスト用のリレー。受け取ったテキストフレームをテストへ転送する。
type Relay {
  Relay(server: Pid, url: String)
}

/// `127.0.0.1` の OS が割り当てたポートで WebSocket サーバーを立てる。接続を
/// 受け入れるたびに `on_connect` を、テキストフレームを受け取るたびに `on_text` を
/// 呼ぶ。
fn start_relay_with(
  on_connect: fn() -> Nil,
  on_text: fn(mist.WebsocketConnection, String) -> Nil,
) -> Relay {
  let ports = process.new_subject()
  let assert Ok(started) =
    mist.new(fn(request) {
      mist.websocket(
        request: request,
        handler: fn(state, received, connection) {
          case received {
            mist.Text(text) -> on_text(connection, text)
            _ -> Nil
          }
          mist.continue(state)
        },
        on_init: fn(_connection) {
          on_connect()
          #(Nil, None)
        },
        on_close: fn(_state) { Nil },
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _scheme, _address) {
      process.send(ports, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(ports, 2000)
  Relay(server: started.pid, url: "ws://127.0.0.1:" <> int.to_string(port))
}

/// `127.0.0.1` の OS が割り当てたポートで WebSocket サーバーを立てる。受け取った
/// テキストフレームをテストへ転送する。
fn start_relay(frames: Subject(String)) -> Relay {
  start_relay_with(fn() { Nil }, fn(_connection, text) {
    process.send(frames, text)
  })
}

/// テストプロセスにリンクしたクライアントを、テストを巻き込まずに止める。
fn stop_client(client: relay_client.Client) -> Nil {
  let assert Ok(pid) = process.subject_owner(client)
  process.unlink(pid)
  process.kill(pid)
}

/// サーバーを親プロセスと同じ方法で止める。スーパーバイザーは親からの normal な
/// exit を順序立った停止に変えるので、kill と違ってクラッシュレポートを出さない。
fn stop_relay(relay: Relay) -> Nil {
  process.unlink(relay.server)
  process.send_exit(relay.server)
}

/// 1 回目の評価だけ定義を得られず、2 回目以降は `bunker` を返すサンク。評価の
/// 回数は、評価が行われる stratus のプロセスの中で数えて `evaluations` へ送る。
fn failing_once(evaluations: Subject(Int)) -> Subscriptions {
  fn() {
    let count = next_evaluation()
    process.send(evaluations, count)
    case count {
      0 -> Error(Nil)
      _ -> Ok([#(bunker, filter.new())])
    }
  }
}

/// 評価の回数を 0 から数え、呼ぶ前の値を返す。
@external(erlang, "subscription_counter", "next")
fn next_evaluation() -> Int

/// 本物の `relay_client` を接続する。
fn connect(
  relay: Relay,
  subscriptions: Subscriptions,
  retry_delay_ms: Int,
) -> relay_client.Client {
  let assert Ok(client) =
    relay_client.start(
      relay.url,
      subscriptions,
      fn(_event) { Nil },
      retry_delay_ms,
    )
  client
}

/// 接続直後の評価で定義を得られなければ何も送らず、予約した再試行で REQ を送る。
/// 再試行の宛先をセレクターに入れ忘れる、世代を渡し忘れる、タイマーの宛先を誤る、
/// のいずれでも REQ が届かずに落ちる。
pub fn a_failed_evaluation_is_retried_until_the_req_is_sent_test() {
  let frames = process.new_subject()
  let evaluations = process.new_subject()
  let relay = start_relay(frames)
  let client = connect(relay, failing_once(evaluations), 300)

  assert process.receive(evaluations, 2000) == Ok(0)
  assert process.receive(frames, 200) == Error(Nil)
  assert process.receive(evaluations, 1000) == Ok(1)
  let assert Ok(frame) = process.receive(frames, 1000)
  assert string.starts_with(frame, "[\"REQ\",\"bunker\",")

  stop_client(client)
  stop_relay(relay)
}

/// 予約した後に張り直しの依頼が成功すれば、後から届く再試行のタイマーは評価せず、
/// REQ も重ねて送らない。
pub fn a_retry_after_a_successful_resubscribe_is_not_evaluated_test() {
  let frames = process.new_subject()
  let evaluations = process.new_subject()
  let relay = start_relay(frames)
  let client = connect(relay, failing_once(evaluations), 500)

  assert process.receive(evaluations, 2000) == Ok(0)
  relay_client.resubscribe(client)
  assert process.receive(evaluations, 1000) == Ok(1)
  let assert Ok(frame) = process.receive(frames, 1000)
  assert string.starts_with(frame, "[\"REQ\",\"bunker\",")
  assert process.receive(evaluations, 900) == Error(Nil)
  assert process.receive(frames, 0) == Error(Nil)

  stop_client(client)
  stop_relay(relay)
}

// --- 受信バッファの上限 ---

/// REQ を受け取るたびに `bytes` バイトのバイナリフレームを送ってから `after` の
/// テキストフレームを送るリレー。接続を受け入れるたびに `connections` へ知らせる。
fn start_sending_relay(
  connections: Subject(Nil),
  bytes: Int,
  after: String,
) -> Relay {
  start_relay_with(
    fn() { process.send(connections, Nil) },
    fn(connection, text) {
      case string.starts_with(text, "[\"REQ\"") {
        True -> {
          // クライアントが上限を超えたフレームを受け取った直後に切ることがあり、
          // 続く送信は失敗しうる。`let assert` にするとハンドラーが落ちて、テスト
          // の出力にエラーが混ざる。
          let _ = mist.send_binary_frame(connection, <<0:size(bytes)-unit(8)>>)
          let _ = mist.send_text_frame(connection, after)
          Nil
        }
        False -> Nil
      }
    },
  )
}

/// 受信バッファの上限（`stratus.max_buffer_bytes`）を超えるフレームを送ると、
/// 接続アクターが異常終了し、`relay_connection` が張り直す。
pub fn a_frame_over_the_receive_limit_reconnects_test() {
  let connections = process.new_subject()
  let relay =
    start_sending_relay(connections, stratus.max_buffer_bytes + 1, "[]")
  let assert Ok(started) =
    relay_connection.start(relay_connection.Settings(
      name: process.new_name("receive_limit"),
      relay: relay_client.label(relay.url),
      connect: fn() {
        app.open_websocket(
          relay.url,
          fn() { Ok([#(bunker, filter.new())]) },
          fn(_event) { Nil },
        )
      },
      on_connect: fn(_socket) { Nil },
      on_disconnect: fn() { Nil },
      reconnect_delay_ms: 100,
    ))

  assert process.receive(connections, 2000) == Ok(Nil)
  assert process.receive(connections, 2000) == Ok(Nil)

  process.unlink(started.pid)
  process.kill(started.pid)
  stop_relay(relay)
}

/// 上限の半分のフレームは受け取っても接続を保ち、続くイベントを届ける。
pub fn a_frame_under_the_receive_limit_is_received_test() {
  let connections = process.new_subject()
  let sent = signed_event.new(1, "under the receive limit")
  let relay =
    start_sending_relay(
      connections,
      stratus.max_buffer_bytes / 2,
      event_frame(sent),
    )
  let received = process.new_subject()
  let assert Ok(client) =
    relay_client.start(
      relay.url,
      fn() { Ok([#(bunker, filter.new())]) },
      process.send(received, _),
      relay_client.subscription_retry_delay_ms,
    )

  let assert Ok(verified) = process.receive(received, 2000)
  assert verified == signed_event.verified(sent)
  assert process.receive(connections, 0) == Ok(Nil)
  assert process.receive(connections, 0) == Error(Nil)

  stop_client(client)
  stop_relay(relay)
}
