//// `relay_client` のテスト。URL の変換、購読の照合の判断（`sync`）、および
//// ループバックの WebSocket サーバーへ本物の `relay_client` を接続した再試行の配線、
//// CLOSED の後の張り直し、生存確認によるハーフオープンの検知を確かめる。

import gleam/dynamic
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
import gleam/string
import mist
import nostr_no_su/app
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/log
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/nostr/filter.{Filter}
import nostr_no_su/nostr/message
import nostr_no_su/relay_client.{
  type SubscriptionState, type Subscriptions, Acknowledge, Acknowledgement,
  Closed, Deliver, Report, Requested, Reservation, Retried, SubscriptionState,
  Sync, Synchronise,
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

/// ホストが空の URL は `request.to` を通ってしまうので、`to_request` が拒否する。
pub fn to_request_rejects_an_empty_host_test() {
  assert relay_client.to_request("wss://") == Error(Nil)
  assert relay_client.to_request("ws:///path") == Error(Nil)
  assert relay_client.to_request("wss:///") == Error(Nil)
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
      fn(_ack) { Nil },
      None,
      relay_client.subscription_retry_delay,
      relay_client.keepalive_interval_ms,
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

  assert relay_client.handle_text(
      "test",
      event_frame(forged),
      deliver,
      fn(_ack) { Nil },
      None,
      fn(_sent) { Nil },
    )
    == None
  assert process.receive(delivered, 0) == Error(Nil)

  assert relay_client.handle_text(
      "test",
      event_frame(genuine),
      deliver,
      fn(_ack) { Nil },
      None,
      fn(_sent) { Nil },
    )
    == None
  let assert Ok(verified) = process.receive(delivered, 0)
  assert event.verified_event(verified) == genuine
}

/// NOTICE の本文にログ行を偽造しうる長さと改行があっても、1 行に収まる。
pub fn interpret_keeps_a_large_notice_on_one_line_test() {
  let body = string.repeat("x", 10_000) <> "\n[bunker] forged"

  let assert Report(line) = relay_client.interpret(notice_frame(body))
  assert !string.contains(line, "\n")
  assert string.length(line)
    <= string.length("notice: ") + log.max_external_chars + 3
}

/// `interpret` の解釈を、リレーメッセージの種類ごとに 1 つの表で固定する。外部由来の
/// 値は正規化し、照合と署名に使う id と challenge は正規化しないことも、同じ表で
/// 表す。
pub fn interpret_covers_every_relay_message_test() {
  let genuine = signed_event.new(1, "genuine")
  let other = signed_event.new(1, "other")
  let mismatched_id = Event(..genuine, id: other.id)
  let invalid_signature = Event(..genuine, sig: other.sig)

  [
    #("event", event_frame(genuine), Deliver(signed_event.verified(genuine))),
    #(
      "event with a mismatched id",
      event_frame(mismatched_id),
      Report("dropped event with invalid id: " <> mismatched_id.id),
    ),
    #(
      "event with an invalid signature",
      event_frame(invalid_signature),
      Report("dropped event with invalid signature: " <> genuine.id),
    ),
    #("eose", eose_frame("sub\nx"), Report("end of stored events for sub x")),
    #(
      "ok accepted",
      ok_frame("e1", True, ""),
      Acknowledge(Acknowledgement("e1", True, "")),
    ),
    #(
      "ok rejected",
      ok_frame("e1", False, "blocked\n[bunker] forged"),
      Acknowledge(Acknowledgement("e1", False, "blocked [bunker] forged")),
    ),
    #(
      "notice",
      notice_frame("busy\n[bunker] forged"),
      Report("notice: busy [bunker] forged"),
    ),
    #(
      "closed",
      closed_frame("sub\nx", "bye\n[bunker] forged"),
      Synchronise(
        Closed("sub\nx"),
        "subscription sub x closed: bye [bunker] forged",
      ),
    ),
    #(
      "auth",
      auth_frame("c1\n[bunker] forged"),
      relay_client.Authenticate("c1\n[bunker] forged"),
    ),
    #(
      "undecodable",
      json.preprocessed_array([json.string("EVENT")]) |> json.to_string,
      Report("unrecognised message: [\"EVENT\"]"),
    ),
  ]
  |> list.each(fn(row) {
    let #(name, frame, expected) = row
    assert #(name, relay_client.interpret(frame)) == #(name, expected)
  })
}

/// CLOSED は照合の契機を返し、それ以外のメッセージは返さない。
pub fn handle_text_returns_the_trigger_of_a_closed_subscription_test() {
  let closed = closed_frame("bunker", "rate-limited: slow down")
  assert relay_client.handle_text(
      "test",
      closed,
      fn(_event) { Nil },
      fn(_ack) { Nil },
      None,
      fn(_sent) { Nil },
    )
    == Some(Closed("bunker"))

  assert relay_client.handle_text(
      "test",
      notice_frame("x"),
      fn(_event) { Nil },
      fn(_ack) { Nil },
      None,
      fn(_sent) { Nil },
    )
    == None
}

/// AUTH を受けたときのログの水準と本文は 3 枝で固定する。
pub fn describe_auth_test() {
  assert relay_client.describe_auth(relay_client.NotAnswered)
    == #(
      log.Notice,
      "relay requested authentication; not answering on this connection",
    )
  assert relay_client.describe_auth(relay_client.Answered(3))
    == #(log.Notice, "answered authentication with 3 event(s)")
  assert relay_client.describe_auth(relay_client.Unsigned("no signer"))
    == #(log.Warning, "could not answer authentication: no signer")
}

/// リレーからの AUTH の challenge を渡した JSON フレーム。
fn auth_frame(challenge: String) -> String {
  json.preprocessed_array([json.string("AUTH"), json.string(challenge)])
  |> json.to_string
}

/// リレーからの CLOSED を購読 id と理由で組み立てた JSON フレーム。
fn closed_frame(subscription_id: String, reason: String) -> String {
  json.preprocessed_array([
    json.string("CLOSED"),
    json.string(subscription_id),
    json.string(reason),
  ])
  |> json.to_string
}

/// リレーからの EOSE を購読 id で組み立てた JSON フレーム。
fn eose_frame(subscription_id: String) -> String {
  json.preprocessed_array([json.string("EOSE"), json.string(subscription_id)])
  |> json.to_string
}

/// リレーからの NOTICE を本文で組み立てた JSON フレーム。
fn notice_frame(body: String) -> String {
  json.preprocessed_array([json.string("NOTICE"), json.string(body)])
  |> json.to_string
}

/// リレーからの OK をイベント id、受理の可否、理由で組み立てた JSON フレーム。
fn ok_frame(event_id: String, accepted: Bool, reason: String) -> String {
  json.preprocessed_array([
    json.string("OK"),
    json.string(event_id),
    json.bool(accepted),
    json.string(reason),
  ])
  |> json.to_string
}

/// AUTH は受け口があるときだけ challenge を渡し、得たイベントを `send` で送る。
/// 受け口が無い、または署名を得られないときは `send` に何も届かない。
pub fn handle_text_answers_an_auth_only_with_an_authenticator_test() {
  let sent = process.new_subject()
  let send = process.send(sent, _)
  let signed = signed_event.new(22_242, "")
  let challenges = process.new_subject()

  assert relay_client.handle_text(
      "test",
      auth_frame("c1"),
      fn(_event) { Nil },
      fn(_ack) { Nil },
      Some(fn(received) {
        process.send(challenges, received)
        Ok([signed])
      }),
      send,
    )
    == None
  assert process.receive(challenges, 0) == Ok("c1")
  assert process.receive(sent, 0) == Ok(message.Auth(signed))
  assert process.receive(sent, 0) == Error(Nil)

  assert relay_client.handle_text(
      "test",
      auth_frame("c1"),
      fn(_event) { Nil },
      fn(_ack) { Nil },
      None,
      send,
    )
    == None
  assert process.receive(sent, 0) == Error(Nil)

  assert relay_client.handle_text(
      "test",
      auth_frame("c1"),
      fn(_event) { Nil },
      fn(_ack) { Nil },
      Some(fn(_challenge) { Error("no signer") }),
      send,
    )
    == None
  assert process.receive(sent, 0) == Error(Nil)
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

/// 開いている購読と予約から作った状態。世代は 5 から数え、2 つの待ち時間はどちらも
/// 100ms から数える。
fn state_with(
  open: List(String),
  retry: option.Option(Int),
) -> SubscriptionState {
  SubscriptionState(
    open: set.from_list(open),
    retry: retry,
    next_generation: 5,
    delay_ms: 100,
    closed_delay_ms: 100,
  )
}

/// `sync` のテストで使う再試行の待ち時間の延ばし方。
const retry = Backoff(initial_ms: 100, max_ms: 400)

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
      retry,
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
      retry,
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
      retry,
    )
  assert synced.messages == [message.Req(bunker, other_bunker_filter())]
  assert synced.state == state_with([bunker], None)
}

/// 何も開いておらず定義も空なら、何も送らない。
pub fn sync_with_nothing_open_and_nothing_wanted_sends_nothing_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([], None),
      Requested,
      reporting(calls, Ok([])),
      retry,
    )
  assert synced
    == Sync(state: state_with([], None), messages: [], schedule_retry: None)
}

/// 予約が無いのに届いた再試行（解いた予約の遅れたタイマー）は、定義を評価せず、
/// 状態も変えない。
pub fn sync_drops_a_retry_without_a_reservation_test() {
  let calls = process.new_subject()
  let state = state_with([bunker], None)
  let synced =
    relay_client.sync(state, Retried(1), reporting(calls, Ok([])), retry)
  assert synced == Sync(state: state, messages: [], schedule_retry: None)
  assert !evaluated(calls)
}

/// 別の世代の予約があるときに届いた再試行（置き換わった予約のタイマー）も捨てる。
pub fn sync_drops_a_retry_of_another_generation_test() {
  let calls = process.new_subject()
  let state = state_with([bunker], Some(2))
  let synced =
    relay_client.sync(state, Retried(1), reporting(calls, Ok([])), retry)
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
      retry,
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
      retry,
    )
  assert synced
    == Sync(
      state: SubscriptionState(
        open: set.from_list([bunker]),
        retry: Some(5),
        next_generation: 6,
        delay_ms: 200,
        closed_delay_ms: 100,
      ),
      messages: [],
      schedule_retry: Some(Reservation(generation: 5, delay_ms: 100)),
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
      retry,
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
      retry,
    )
  assert synced
    == Sync(
      state: SubscriptionState(
        open: set.from_list([bunker]),
        retry: Some(5),
        next_generation: 6,
        delay_ms: 200,
        closed_delay_ms: 100,
      ),
      messages: [],
      schedule_retry: Some(Reservation(generation: 5, delay_ms: 100)),
    )
}

/// 予約中に張り直しの依頼が定義を得られなくても、予約を増やさない。
pub fn sync_a_failed_request_keeps_a_single_reservation_test() {
  let calls = process.new_subject()
  let state = state_with([bunker], Some(1))
  let synced =
    relay_client.sync(state, Requested, reporting(calls, Error(Nil)), retry)
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
    relay_client.sync(
      relay_client.new_subscription_state(retry),
      Requested,
      failing,
      retry,
    )
  assert first.schedule_retry == Some(Reservation(generation: 1, delay_ms: 100))
  let second = relay_client.sync(first.state, Requested, succeeding, retry)
  assert second.state.retry == None
  let third = relay_client.sync(second.state, Requested, failing, retry)
  assert third.schedule_retry == Some(Reservation(generation: 2, delay_ms: 100))
  drain(calls)

  let stale = relay_client.sync(third.state, Retried(1), succeeding, retry)
  assert !evaluated(calls)
  assert stale == Sync(state: third.state, messages: [], schedule_retry: None)

  let _current = relay_client.sync(third.state, Retried(2), succeeding, retry)
  assert evaluated(calls)
}

/// 定義を得られない再試行が続くと、次に予約する待ち時間が失敗のたびに延び、
/// 上限で頭打ちになる。
pub fn sync_a_failed_retry_doubles_the_delay_test() {
  let calls = process.new_subject()
  let failing = reporting(calls, Error(Nil))
  let state = state_with([], Some(4))

  let first = relay_client.sync(state, Retried(4), failing, retry)
  assert first.schedule_retry == Some(Reservation(generation: 5, delay_ms: 100))
  assert first.state.delay_ms == 200

  let second = relay_client.sync(first.state, Retried(5), failing, retry)
  assert second.schedule_retry
    == Some(Reservation(generation: 6, delay_ms: 200))
  assert second.state.delay_ms == 400

  let third = relay_client.sync(second.state, Retried(6), failing, retry)
  assert third.schedule_retry == Some(Reservation(generation: 7, delay_ms: 400))
  assert third.state.delay_ms == 400
}

/// 定義を得られると、次に予約する待ち時間は初期値に戻る。張り直しの依頼で
/// 定義を得たときは CLOSED の待ち時間も戻る。
pub fn sync_a_successful_evaluation_resets_the_delay_test() {
  let calls = process.new_subject()
  let state =
    SubscriptionState(
      open: set.new(),
      retry: None,
      next_generation: 5,
      delay_ms: 400,
      closed_delay_ms: 400,
    )
  let synced =
    relay_client.sync(state, Requested, reporting(calls, Ok([])), retry)
  assert synced.state.delay_ms == 100
  assert synced.state.closed_delay_ms == 100
}

/// CLOSED を受けたら、その id を開いている購読から外し、新しい世代で再試行を
/// 1 つ予約する。
pub fn sync_a_closed_subscription_is_removed_and_reserved_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([bunker], None),
      Closed(bunker),
      reporting(calls, Ok([])),
      retry,
    )
  assert synced
    == Sync(
      state: SubscriptionState(
        open: set.new(),
        retry: Some(5),
        next_generation: 6,
        delay_ms: 100,
        closed_delay_ms: 200,
      ),
      messages: [],
      schedule_retry: Some(Reservation(generation: 5, delay_ms: 100)),
    )
  assert !evaluated(calls)
}

/// 予約が残っていれば、CLOSED を受けても id を外すだけで新しい予約はしない。
pub fn sync_a_closed_subscription_keeps_the_current_reservation_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      state_with([bunker], Some(1)),
      Closed(bunker),
      reporting(calls, Ok([])),
      retry,
    )
  assert synced
    == Sync(
      state: SubscriptionState(
        open: set.new(),
        retry: Some(1),
        next_generation: 5,
        delay_ms: 100,
        closed_delay_ms: 100,
      ),
      messages: [],
      schedule_retry: None,
    )
  assert !evaluated(calls)
}

/// 定義に無い id の CLOSED（すでに閉じた購読への遅れた応答など）は無視し、
/// 再照合を予約しない。
pub fn sync_ignores_a_closed_subscription_that_is_not_open_test() {
  let calls = process.new_subject()
  let state = state_with([], None)
  let synced =
    relay_client.sync(state, Closed(bunker), reporting(calls, Ok([])), retry)
  assert synced == Sync(state: state, messages: [], schedule_retry: None)
  assert !evaluated(calls)
}

/// CLOSED が繰り返すと、CLOSED の待ちだけが倍々に延びる。間に挟まる張り直しの
/// 依頼の成功は、この待ちを戻さない。
pub fn sync_a_subscription_closed_again_doubles_the_delay_test() {
  let calls = process.new_subject()
  let closed_once =
    relay_client.sync(
      state_with([bunker], None),
      Closed(bunker),
      reporting(calls, Ok([])),
      retry,
    )
  assert closed_once.schedule_retry
    == Some(Reservation(generation: 5, delay_ms: 100))

  let resubscribed =
    relay_client.sync(
      closed_once.state,
      Retried(5),
      reporting(calls, Ok([#(bunker, bunker_filter())])),
      retry,
    )
  assert resubscribed.messages == [message.Req(bunker, bunker_filter())]

  let closed_again =
    relay_client.sync(
      resubscribed.state,
      Closed(bunker),
      reporting(calls, Ok([])),
      retry,
    )
  assert closed_again.schedule_retry
    == Some(Reservation(generation: 6, delay_ms: 200))
}

/// 張り直しの依頼が定義を得ると、定義失敗の待ちは初期値に戻るが、CLOSED の待ちは
/// 持ち越す。
pub fn sync_a_successful_retry_keeps_the_closed_delay_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      SubscriptionState(
        open: set.new(),
        retry: Some(1),
        next_generation: 5,
        delay_ms: 400,
        closed_delay_ms: 400,
      ),
      Retried(1),
      reporting(calls, Ok([#(bunker, bunker_filter())])),
      retry,
    )
  assert synced.state.delay_ms == 100
  assert synced.state.closed_delay_ms == 400
  assert synced.state.retry == None
}

/// CLOSED が続いた後に定義を一瞬得られなくても、延びた CLOSED の待ちからは
/// 数えず、定義失敗の待ちは自分の値から数える。
pub fn sync_a_failed_definition_after_closes_uses_its_own_delay_test() {
  let calls = process.new_subject()
  let synced =
    relay_client.sync(
      SubscriptionState(
        open: set.new(),
        retry: Some(1),
        next_generation: 5,
        delay_ms: 100,
        closed_delay_ms: 400,
      ),
      Retried(1),
      reporting(calls, Error(Nil)),
      retry,
    )
  assert synced.schedule_retry
    == Some(Reservation(generation: 5, delay_ms: 100))
  assert synced.state.delay_ms == 200
  assert synced.state.closed_delay_ms == 400
}

// --- ループバックの WebSocket サーバーを使うテスト ---

/// `127.0.0.1` の OS が割り当てたポートで待ち受けるテスト用の WebSocket サーバー。
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
  retry_delay: backoff.Backoff,
  authenticator: option.Option(relay_client.Authenticator),
) -> relay_client.Client {
  let assert Ok(client) =
    relay_client.start(
      relay.url,
      subscriptions,
      fn(_event) { Nil },
      fn(_ack) { Nil },
      authenticator,
      retry_delay,
      relay_client.keepalive_interval_ms,
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
  let client =
    connect(
      relay,
      failing_once(evaluations),
      Backoff(initial_ms: 400, max_ms: 400),
      None,
    )

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
  let client =
    connect(
      relay,
      failing_once(evaluations),
      Backoff(initial_ms: 500, max_ms: 500),
      None,
    )

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

/// `REQ` で始まるテキストを受けるたびに `frames` へ転送し、その購読を CLOSED で
/// 閉じるリレー。
fn start_relay_closing_subscriptions(frames: Subject(String)) -> Relay {
  let closed = closed_frame("bunker", "rate-limited: slow down")
  start_relay_with(fn() { Nil }, fn(connection, text) {
    case string.starts_with(text, "[\"REQ\"") {
      True -> {
        process.send(frames, text)
        let _ = mist.send_text_frame(connection, closed)
        Nil
      }
      False -> Nil
    }
  })
}

/// リレーが CLOSED で購読を閉じたら、開いている購読から外して張り直す。待ちは
/// `initial_ms`（400ms、ジッター込みで 320〜480ms）で、上限も同じ値にして倍化
/// させない。倍化は `sync` の単体テストで確かめる。
pub fn a_closed_subscription_is_resubscribed_test() {
  let frames = process.new_subject()
  let relay = start_relay_closing_subscriptions(frames)
  let client =
    connect(
      relay,
      fn() { Ok([#(bunker, filter.new())]) },
      Backoff(initial_ms: 400, max_ms: 400),
      None,
    )

  let assert Ok(first) = process.receive(frames, 2000)
  assert string.starts_with(first, "[\"REQ\",\"bunker\",")

  assert process.receive(frames, 200) == Error(Nil)
  let assert Ok(second) = process.receive(frames, 1000)
  assert string.starts_with(second, "[\"REQ\",\"bunker\",")

  stop_client(client)
  stop_relay(relay)
}

/// `REQ` で始まるテキストのたびに AUTH の challenge を送り、続けて `auth-required`
/// で CLOSED にするリレー。受けたテキストはすべて `frames` へ転送する。
fn start_relay_requiring_auth(frames: Subject(String)) -> Relay {
  let auth = auth_frame("c1")
  let closed = closed_frame("bunker", "auth-required: sign in")
  start_relay_with(fn() { Nil }, fn(connection, text) {
    process.send(frames, text)
    case string.starts_with(text, "[\"REQ\"") {
      True -> {
        let _ = mist.send_text_frame(connection, auth)
        let _ = mist.send_text_frame(connection, closed)
        Nil
      }
      False -> Nil
    }
  })
}

/// 受け口があれば AUTH に応答してから、CLOSED の後の張り直しで REQ を送り直す。
/// AUTH の応答は同じ接続のプロセスが CLOSED を処理する前に書くため、この順序は
/// TCP の到着順で確かめられ、待ち時間に頼らない。
pub fn start_answers_an_auth_before_resubscribing_test() {
  let frames = process.new_subject()
  let relay = start_relay_requiring_auth(frames)
  let signed = signed_event.new(22_242, "")
  let client =
    connect(
      relay,
      fn() { Ok([#(bunker, filter.new())]) },
      Backoff(initial_ms: 50, max_ms: 50),
      Some(fn(_challenge) { Ok([signed]) }),
    )

  let assert Ok(first) = process.receive(frames, 2000)
  assert string.starts_with(first, "[\"REQ\",\"bunker\",")
  assert process.receive(frames, 2000)
    == Ok(message.encode_client_message(message.Auth(signed)))
  let assert Ok(second) = process.receive(frames, 2000)
  assert string.starts_with(second, "[\"REQ\",\"bunker\",")

  stop_client(client)
  stop_relay(relay)
}

/// 受け口が無ければ AUTH には応答しない。受けたフレームはすべて `frames` へ転送
/// されるので、1 本目の次に届くのが 2 本目の REQ であること自体が、間に AUTH の
/// 応答が無かった証拠になる。
pub fn start_does_not_answer_an_auth_without_an_authenticator_test() {
  let frames = process.new_subject()
  let relay = start_relay_requiring_auth(frames)
  let client =
    connect(
      relay,
      fn() { Ok([#(bunker, filter.new())]) },
      Backoff(initial_ms: 50, max_ms: 50),
      None,
    )

  let assert Ok(first) = process.receive(frames, 2000)
  assert string.starts_with(first, "[\"REQ\",\"bunker\",")
  let assert Ok(second) = process.receive(frames, 2000)
  assert string.starts_with(second, "[\"REQ\",\"bunker\",")

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
          fn(_ack) { Nil },
          None,
        )
      },
      on_connect: fn(_socket) { Nil },
      on_disconnect: fn() { Nil },
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
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
      fn(_ack) { Nil },
      None,
      relay_client.subscription_retry_delay,
      relay_client.keepalive_interval_ms,
    )

  let assert Ok(verified) = process.receive(received, 2000)
  assert verified == signed_event.verified(sent)
  assert process.receive(connections, 0) == Ok(Nil)
  assert process.receive(connections, 0) == Error(Nil)

  stop_client(client)
  stop_relay(relay)
}

// --- 発行結果の通知 ---

/// `EVENT` で始まるテキストを受けたら指定の OK を返すリレー。
fn start_relay_replying_ok(ok: String) -> Relay {
  start_relay_with(fn() { Nil }, fn(connection, text) {
    case string.starts_with(text, "[\"EVENT\"") {
      True -> {
        let _ = mist.send_text_frame(connection, ok)
        Nil
      }
      False -> Nil
    }
  })
}

/// リレーが発行したイベントに返した OK は `handle_ok` に届く。
pub fn start_passes_an_ok_from_the_relay_to_handle_ok_test() {
  let ok = ok_frame("e1", False, "rate-limited: slow down")
  let relay = start_relay_replying_ok(ok)
  let acks = process.new_subject()
  let assert Ok(client) =
    relay_client.start(
      relay.url,
      fn() { Ok([]) },
      fn(_event) { Nil },
      process.send(acks, _),
      None,
      relay_client.subscription_retry_delay,
      relay_client.keepalive_interval_ms,
    )

  relay_client.publish(client, signed_event.new(1, "published"))

  assert process.receive(acks, 2000)
    == Ok(Acknowledgement("e1", False, "rate-limited: slow down"))

  stop_client(client)
  stop_relay(relay)
}

// --- 生存確認によるハーフオープンの検知 ---

/// mist の接続プロセスを止めて、TCP は開いたまま応答が止まったリレーを再現する。
@external(erlang, "erlang", "suspend_process")
fn suspend_process(pid: Pid) -> Bool

/// 止めた接続プロセスを元に戻す。
@external(erlang, "erlang", "resume_process")
fn resume_process(pid: Pid) -> Bool

/// 本物の `relay_client.start` を、空の購読と、何もしない `handle_event` と、
/// 指定の間隔の生存確認で起動し、`app.open_websocket` と同じく `Socket` に
/// 包む。`app.open_websocket` は本番の 30 秒の間隔を使うので、短い間隔で
/// 確かめるこのテストでは使えない。
fn open_socket(
  url: String,
  interval_ms: Int,
) -> Result(relay_connection.Socket, String) {
  use connection <- result.try(relay_client.start(
    url,
    fn() { Ok([]) },
    fn(_event) { Nil },
    fn(_ack) { Nil },
    None,
    relay_client.subscription_retry_delay,
    interval_ms,
  ))
  let assert Ok(pid) = process.subject_owner(connection)
  Ok(
    relay_connection.Socket(
      pid: pid,
      publish: relay_client.publish(connection, _),
      resubscribe: fn() { relay_client.resubscribe(connection) },
    ),
  )
}

/// 受信が止まった偽の相手を、mist の接続プロセスを止めて再現する。生存確認の
/// ping にも応答が無いまま止まった接続は `relay_connection` が張り直す。
pub fn a_silent_relay_is_closed_and_reconnected_test() {
  let connection_pids = process.new_subject()
  let disconnects = process.new_subject()
  let relay =
    start_relay_with(
      fn() { process.send(connection_pids, process.self()) },
      fn(_connection, _text) { Nil },
    )

  let assert Ok(started) =
    relay_connection.start(relay_connection.Settings(
      name: process.new_name("half_open"),
      relay: relay_client.label(relay.url),
      connect: fn() { open_socket(relay.url, 200) },
      on_connect: fn(_socket) { Nil },
      on_disconnect: fn() { process.send(disconnects, Nil) },
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    ))

  let assert Ok(first_pid) = process.receive(connection_pids, 2000)

  // mist はアイドルな接続にも ping に自動で pong を返すので、切られない。
  assert process.receive(disconnects, 1000) == Error(Nil)

  let assert True = suspend_process(first_pid)

  assert process.receive(disconnects, 2000) == Ok(Nil)
  let assert Ok(_second_pid) = process.receive(connection_pids, 2000)

  let assert True = resume_process(first_pid)
  process.unlink(started.pid)
  process.kill(started.pid)
  stop_relay(relay)
}
