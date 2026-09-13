//// リレーへの WebSocket 接続 1 本（stratus）。
////
//// 購読は「現在の定義に合わせる」照合で開く。接続直後と張り直しの依頼のたびに
//// 定義を評価し、定義にある購読には REQ（同じ id は NIP-01 で置き換え）を、開いて
//// いて定義から消えた購読には CLOSE を送る。定義を得られなかったときは開いている
//// 購読を変えずに再試行を 1 つだけ予約する。判断は純粋関数 `sync` にあり、stratus の
//// ループはその結果を送信と予約に移すだけである。

import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import gleam/string
import nostr_no_su/backoff
import nostr_no_su/log
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter}
import nostr_no_su/nostr/message
import stratus

/// リレー接続に対する指示。stratus のユーザーメッセージとして送る。
pub type Msg {
  /// 購読を現在の定義に合わせる。定義にある購読には REQ を送り（同じ id は置き換え
  /// になる）、開いていて定義から消えた購読には CLOSE を送る。接続直後と、張り直しの
  /// 依頼で送る。
  Subscribe
  /// 定義を得られなかった照合をやり直す。relay_client が自分宛てに予約する。
  /// generation は予約の世代。
  RetrySubscribe(generation: Int)
  /// イベントを 1 件このソケットから発行する。
  Publish(event: event.Event)
}

/// 起動済みのリレークライアント。イベントの送信は `publish` を通じて行い、
/// その背後のプロセスを `relay_connection` が切断検知のために監視する。
pub type Client =
  Subject(stratus.InternalMessage(Msg))

/// 開くべき購読を生成するサンク。接続と張り直しのたびに評価するため、時刻に
/// 依存するフィルター（`since` など）が常に最新に保たれる。定義を得られないとき
/// （署名者の問い合わせの失敗など）は `Error`。`Ok([])` は「購読しない」を意味し、
/// 開いている購読を閉じる。
pub type Subscriptions =
  fn() -> Result(List(#(String, Filter)), Nil)

/// 照合の契機。
pub type Trigger {
  /// 接続直後の照合か、張り直しの依頼。
  Requested
  /// 予約した再試行のタイマー。generation はそのタイマーを予約したときの世代。
  Retried(generation: Int)
}

/// 購読の照合の状態。stratus のプロセスが持つ。
pub type SubscriptionState {
  SubscriptionState(
    /// 開いている購読 id。
    open: Set(String),
    /// 予約中の再試行の世代。予約が無ければ None。予約は常に 1 つだけにする。
    retry: Option(Int),
    /// 次に予約するときに使う世代。予約するたびに 1 つ進める。
    next_generation: Int,
    /// 次に予約するときの、ジッターを掛ける前の待ち時間。
    delay_ms: Int,
  )
}

/// 新たに予約する再試行の世代と、ジッターを掛ける前の待ち時間。
/// `SubscriptionState.retry`（予約中の世代だけ）と区別するため `Retry` という
/// 名前にしない。
pub type Reservation {
  Reservation(generation: Int, delay_ms: Int)
}

/// 照合 1 回の結果。
pub type Sync {
  Sync(
    /// 次の状態。
    state: SubscriptionState,
    /// 送る REQ と CLOSE。
    messages: List(message.ClientMessage),
    /// 新たに予約する再試行。予約しなければ None。
    schedule_retry: Option(Reservation),
  )
}

/// stratus のプロセスの状態。
type Session {
  Session(
    subscriptions: SubscriptionState,
    /// 再試行のタイマーの宛先。stratus の initialiser（stratus のプロセスの中で
    /// 動く）で作り、セレクターに入れる。
    inbox: Subject(Msg),
  )
}

/// 購読の定義を得られなかったときの本番の再試行の待ち時間。初期値はバンカーの
/// 署名者の問い合わせのタイムアウト（5000ms）と同じにし、上限はバンカーの読み込みの
/// 再試行と同じ 2 分にする。
pub const subscription_retry_delay = backoff.Backoff(
  initial_ms: 5000,
  max_ms: 120_000,
)

/// ハンドシェイクに許す時間。`start` は呼び出し元を最大でこの時間（さらに
/// stratus が上乗せする 100ms）ブロックする。呼び出し元はスーパーバイザー配下の
/// アクターであり、ブロック中はスーパーバイザーの停止要求に応答できないため、
/// この値はワーカーの停止タイムアウト 5000ms（`relay_connection.supervised` を
/// 参照）より小さくしておく必要がある。さもないと、応答しないリレーを待っている
/// 接続の停止が強制 kill で終わる。
const connect_timeout_ms = 3000

/// リレー URL を stratus が期待する http(s) リクエストに変換する。gleam_http は
/// http(s) スキームしかパースせず、stratus は Https を wss/TLS に対応付ける。
pub fn to_request(url: String) -> Result(Request(String), Nil) {
  case string.split_once(url, "://") {
    Ok(#("wss", rest)) -> request.to("https://" <> rest)
    Ok(#("ws", rest)) -> request.to("http://" <> rest)
    _ -> request.to(url)
  }
}

/// スキームを取り除いたリレー URL。複数の接続が開いているときに、ログ行がどの
/// リレーのものか示すために使う。
pub fn label(url: String) -> String {
  case string.split_once(url, "://") {
    Ok(#(_scheme, rest)) -> rest
    Error(_) -> url
  }
}

/// 接続直後の照合の状態。開いている購読も予約も無い。
pub fn new_subscription_state(
  retry_delay: backoff.Backoff,
) -> SubscriptionState {
  SubscriptionState(
    open: set.new(),
    retry: None,
    next_generation: 1,
    delay_ms: retry_delay.initial_ms,
  )
}

/// 指定のリレーに接続し、指定の購読を開き、id と署名を確かめたイベントを
/// `handle_event` へ渡す。検証はこの接続のプロセスの中で行う。`retry_delay` は
/// 購読の定義を得られなかったときの再試行の待ち時間。接続アクターは呼び出し元に
/// リンクされるため呼び出し元と一緒に死に、exit を trap している呼び出し元には
/// その死がメッセージとして届く。
pub fn start(
  url: String,
  subscriptions: Subscriptions,
  handle_event: fn(event.Verified) -> Nil,
  retry_delay: backoff.Backoff,
) -> Result(Client, String) {
  use req <- result.try(
    to_request(url)
    |> result.replace_error("invalid relay url: " <> url),
  )
  let prefix = log.relay_prefix(label(url))
  let builder =
    stratus.new_with_initialiser(req, fn() {
      let inbox = process.new_subject()
      Session(subscriptions: new_subscription_state(retry_delay), inbox: inbox)
      |> stratus.initialised
      |> stratus.selecting(process.new_selector() |> process.select(inbox))
      |> Ok
    })
    |> stratus.with_connect_timeout(connect_timeout_ms)
    |> stratus.on_message(fn(session, msg, conn) {
      case msg {
        stratus.User(Subscribe) ->
          synchronise(
            session,
            Requested,
            subscriptions,
            conn,
            prefix,
            retry_delay,
          )
          |> stratus.continue
        stratus.User(RetrySubscribe(generation)) ->
          synchronise(
            session,
            Retried(generation),
            subscriptions,
            conn,
            prefix,
            retry_delay,
          )
          |> stratus.continue
        stratus.User(Publish(published)) -> {
          send_message(conn, prefix, message.Publish(published))
          stratus.continue(session)
        }
        stratus.Text(text) -> {
          handle_text(prefix, text, handle_event)
          stratus.continue(session)
        }
        stratus.Binary(_) -> stratus.continue(session)
      }
    })
    |> stratus.on_close(fn(_session, reason) {
      log.println(prefix, "connection closed: " <> string.inspect(reason))
    })

  case stratus.start(builder) {
    Ok(started) -> {
      resubscribe(started.data)
      Ok(started.data)
    }
    Error(error) -> Error(describe_start_error(error))
  }
}

/// stratus のアクターを起動できなかった理由を、ログ 1 行に収まる文にする。
/// ハンドシェイクの失敗は stratus が `InitFailed` に入れた文をそのまま使う。
/// 初期化の中でプロセスが落ちたときの終了理由はスタックトレースを含み、同じ内容が
/// クラッシュレポートにも出るので、ここでは出さない。
pub fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitFailed(reason) -> reason
    actor.InitTimeout -> "WebSocket handshake timed out"
    actor.InitExited(_reason) -> "WebSocket client exited during the handshake"
  }
}

/// 購読を現在の定義に合わせるよう依頼する。
pub fn resubscribe(client: Client) -> Nil {
  process.send(client, stratus.to_user_message(Subscribe))
}

/// 接続に対し、そのソケットからイベントを送信するよう依頼する。
pub fn publish(client: Client, published: event.Event) -> Nil {
  process.send(client, stratus.to_user_message(Publish(published)))
}

/// 照合 1 回ぶんの判断。現在の予約と世代が一致しない再試行は定義を評価せずに
/// 捨てる。それ以外は定義を評価し、得られれば REQ と CLOSE を作って予約を解き、
/// 得られなければ何も送らず、予約が無ければ新しい世代で予約する。定義を得られたら
/// 待ち時間を初期値に戻し、新しく予約するたびに待ち時間を延ばす。
///
/// 定義をサンクで受け取るのは、捨てる再試行で定義を評価しない（バンカーへの
/// 問い合わせを送らない）ためである。
pub fn sync(
  state: SubscriptionState,
  trigger: Trigger,
  subscriptions: Subscriptions,
  retry_delay: backoff.Backoff,
) -> Sync {
  case trigger, state.retry {
    Requested, _ -> evaluate(state, subscriptions, retry_delay)
    // 現在の予約のタイマーは予約を消費する。
    Retried(generation), Some(reserved) if generation == reserved ->
      evaluate(
        SubscriptionState(..state, retry: None),
        subscriptions,
        retry_delay,
      )
    // 解いた予約や置き換わった予約の、遅れて届いたタイマー。
    Retried(_), _ -> Sync(state: state, messages: [], schedule_retry: None)
  }
}

/// 定義を評価して照合する。得られなかったとき、予約が残っていればそれに任せ、
/// 無ければ新しい世代で予約する。
fn evaluate(
  state: SubscriptionState,
  subscriptions: Subscriptions,
  retry_delay: backoff.Backoff,
) -> Sync {
  case subscriptions(), state.retry {
    Ok(wanted), _ -> {
      let wanted_ids = set.from_list(list.map(wanted, fn(entry) { entry.0 }))
      Sync(
        state: SubscriptionState(
          ..state,
          open: wanted_ids,
          retry: None,
          delay_ms: retry_delay.initial_ms,
        ),
        messages: reconcile(state.open, wanted, wanted_ids),
        schedule_retry: None,
      )
    }
    Error(Nil), Some(_reserved) ->
      Sync(state: state, messages: [], schedule_retry: None)
    Error(Nil), None ->
      Sync(
        state: SubscriptionState(
          ..state,
          retry: Some(state.next_generation),
          next_generation: state.next_generation + 1,
          delay_ms: backoff.next(retry_delay, state.delay_ms),
        ),
        messages: [],
        schedule_retry: Some(Reservation(
          generation: state.next_generation,
          delay_ms: state.delay_ms,
        )),
      )
  }
}

/// 定義にある購読の REQ と、開いていて定義から消えた購読の CLOSE。CLOSE は表示と
/// テストが安定するよう id の順に並べる。
fn reconcile(
  open: Set(String),
  wanted: List(#(String, Filter)),
  wanted_ids: Set(String),
) -> List(message.ClientMessage) {
  let requests = list.map(wanted, fn(entry) { message.Req(entry.0, entry.1) })
  let closes =
    set.difference(open, wanted_ids)
    |> set.to_list
    |> list.sort(string.compare)
    |> list.map(message.Close)
  list.append(requests, closes)
}

/// 照合を 1 回行い、その結果を送信と再試行の予約に移す。判断は `sync` にある。
fn synchronise(
  session: Session,
  trigger: Trigger,
  subscriptions: Subscriptions,
  conn: stratus.Connection,
  prefix: String,
  retry_delay: backoff.Backoff,
) -> Session {
  let synced = sync(session.subscriptions, trigger, subscriptions, retry_delay)
  list.each(synced.messages, send_message(conn, prefix, _))
  case synced.schedule_retry {
    None -> Nil
    Some(reservation) -> {
      let delay = backoff.jittered(reservation.delay_ms)
      log.println(
        prefix,
        "could not evaluate subscriptions; keeping the current ones and retrying in "
          <> int.to_string(delay)
          <> "ms",
      )
      let _ =
        process.send_after(
          session.inbox,
          delay,
          RetrySubscribe(reservation.generation),
        )
      Nil
    }
  }
  Session(..session, subscriptions: synced.state)
}

/// クライアントメッセージを 1 件ソケットへ書き込む。書けなかった購読や応答は
/// リレーから見れば存在しないのと同じで、黙って捨てると原因を追えないため、何を
/// 送ろうとしたかを添えてログに残す。
fn send_message(
  connection: stratus.Connection,
  prefix: String,
  outgoing: message.ClientMessage,
) -> Nil {
  let text = message.encode_client_message(outgoing)
  case stratus.send_text_message(connection, text) {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.println(
        prefix,
        "failed to send "
          <> describe_outgoing(outgoing)
          <> ": "
          <> string.inspect(reason),
      )
  }
}

/// 送信に失敗したときのログに出す、送ろうとしたものの説明。
fn describe_outgoing(outgoing: message.ClientMessage) -> String {
  case outgoing {
    message.Req(subscription_id, _filter) -> "subscription " <> subscription_id
    message.Close(subscription_id) ->
      "close of subscription " <> subscription_id
    message.Publish(published) -> "event " <> published.id
  }
}

/// リレーメッセージ 1 件の解釈の結果。`Deliver` は検証を通ったイベント、
/// `Report` は出力するログ行の本文（外部由来の値は正規化済み）、`Quiet` は
/// 何も出さない（OK の受理）。
pub type Interpretation {
  Deliver(event.Verified)
  Report(String)
  Quiet
}

/// リレーメッセージ 1 件を解釈する。EVENT は `event.verify` で id と署名を
/// 確かめ、通ったものを配送に回す。それ以外のメッセージと落としたイベントは、
/// 外部由来の値を `log.sanitize_external` で 1 行に収めたログ行の本文にする。
pub fn interpret(text: String) -> Interpretation {
  case message.decode_relay_message(text) {
    Ok(message.RelayEvent(_, received)) ->
      case event.verify(received) {
        Ok(verified) -> Deliver(verified)
        Error(error) ->
          Report(
            "dropped event with "
            <> describe_verify_error(error)
            <> ": "
            <> log.sanitize_external(received.id),
          )
      }
    Ok(message.RelayEose(subscription)) ->
      Report("end of stored events for " <> log.sanitize_external(subscription))
    Ok(message.RelayOk(id, False, reason)) ->
      Report(
        "rejected event "
        <> log.sanitize_external(id)
        <> ": "
        <> log.sanitize_external(reason),
      )
    // 受理は発行 1 件につき 1 行増えるだけで何も伝えないため、出力しない。
    Ok(message.RelayOk(_id, True, _message)) -> Quiet
    Ok(message.RelayNotice(text)) ->
      Report("notice: " <> log.sanitize_external(text))
    Ok(message.RelayClosed(subscription, reason)) ->
      Report(
        "subscription "
        <> log.sanitize_external(subscription)
        <> " closed: "
        <> log.sanitize_external(reason),
      )
    Error(_) -> Report("unrecognised message: " <> log.sanitize_external(text))
  }
}

/// リレーメッセージを 1 件処理する。解釈は `interpret` にあり、ここはその
/// 結果を配送とログ出力に移すだけである。`start` の受信ループが呼ぶほか、
/// テストが直接呼ぶ。
pub fn handle_text(
  prefix: String,
  text: String,
  handle_event: fn(event.Verified) -> Nil,
) -> Nil {
  case interpret(text) {
    Deliver(verified) -> handle_event(verified)
    Report(line) -> log.println(prefix, line)
    Quiet -> Nil
  }
}

/// 検証で落としたイベントのログに出す理由。
fn describe_verify_error(error: event.VerifyError) -> String {
  case error {
    event.InvalidId -> "invalid id"
    event.InvalidSignature -> "invalid signature"
  }
}
