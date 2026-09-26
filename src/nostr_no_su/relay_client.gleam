//// リレーへの WebSocket 接続 1 本（stratus）。
////
//// 購読は「現在の定義に合わせる」照合で開く。契機は接続直後、張り直しの依頼、
//// 予約した再試行、リレーの CLOSED である。接続は開いている購読ごとに最後に送った
//// フィルターを覚える。接続直後と張り直しの依頼では定義を評価し、開いている購読が
//// 覆わない定義の購読には REQ（同じ id は NIP-01 で置き換え）を、開いていて定義から
//// 消えた購読には CLOSE を送る。覆うのは `since` 以外が同じで、送った `since` が
//// 無いか定義の `since` 以下のときで、評価のたびに後ろへ動く `since` では送り直さない。
//// 定義を得られなかったときは開いている購読を変えずに再試行を予約し、その待ちを
//// 延ばす。定義を得るたびにこの待ちを初期値に戻す。
////
//// CLOSED の扱いは次のとおりである。
//// - 受けた id を開いている購読から外す。開いていない id の CLOSED は無視する。
//// - `blocked:`、`restricted:`、AUTH の受け口の無い接続での `auth-required:` は、
////   その購読を止め、次の再接続（この接続の状態ごと作り直す）か張り直しの依頼まで
////   張り直さない。
//// - `rate-limited:` は CLOSED の待ちを上限に上げてから、それ以外の理由はその時点の
////   CLOSED の待ちで、再試行を予約して張り直し、予約のたびに CLOSED の待ちを延ばす。
//// - CLOSED の待ちは定義を得られないときの待ちとは別に数え、張り直しの依頼で定義を
////   得たときだけ初期値に戻す。
////
//// 予約は常に 1 つだけで、予約が残っていれば新たに予約せず、世代の合わない再試行の
//// タイマーは定義を評価せずに捨てる。判断は純粋関数 `sync` にあり、stratus のループは
//// その結果を送信と予約とログに移すだけである。
//// 生存確認は一定間隔で受信の有無を確かめ、無ければ ping を送り、それでも受信が
//// 無ければ自ら接続を止めて `relay_connection` に張り直させる。
//// AUTH（NIP-42）は受け口があれば応答し、無ければ応答せずログに出す。
//// 閉じる依頼（`disconnect`）では、開いている購読の CLOSE と WebSocket の
//// close フレームを送って止まり、リレーの close フレームは待たない。期限までに
//// 止まらなければ kill する。

import gleam/dict.{type Dict}
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
import nostr_no_su/keepalive
import nostr_no_su/log
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter, Filter}
import nostr_no_su/nostr/message
import stratus

/// リレー接続に対する指示。stratus のユーザーメッセージとして送る。
pub type Msg {
  /// 購読を現在の定義に合わせる。開いている購読が覆わない定義の購読には REQ を
  /// 送り（同じ id は置き換えになる）、開いていて定義から消えた購読には CLOSE
  /// を送る。接続直後と、張り直しの依頼で送る。
  Subscribe
  /// 定義を得られなかった照合か、リレーが閉じた購読の張り直しをやり直す。
  /// relay_client が自分宛てに予約する。generation は予約の世代。
  RetrySubscribe(generation: Int)
  /// イベントを 1 件このソケットから発行する。
  Publish(event: event.Event)
  /// 生存確認の刻み。relay_client が自分宛てに予約する。
  KeepaliveTick
  /// 開いている購読の CLOSE と WebSocket の close フレームを送って接続を止める。
  /// リレーの close フレームは待たない。`disconnect` が送る。
  Disconnect
}

/// 起動済みのリレークライアント。イベントの送信は `publish` を通じて行い、
/// その背後のプロセスを `relay_connection` が切断検知のために監視する。
pub type Client =
  Subject(stratus.InternalMessage(Msg))

/// 開くべき購読を生成するサンク。接続と張り直しのたびに評価するので、時刻に
/// 依存するフィルター（`since` など）は評価のたびに新しい値になるが、開いて
/// いる購読が覆う間は REQ を送り直さない（`sync`）。定義を得られないとき
/// （署名者の問い合わせの失敗など）は `Error`。`Ok([])` は「購読しない」を意味し、
/// 開いている購読を閉じる。
pub type Subscriptions =
  fn() -> Result(List(#(String, Filter)), Nil)

/// AUTH（NIP-42）の受け口。challenge を受け取り、同じ接続へ AUTH で送る署名済みの
/// イベントを返す。得られないときは理由を `Error` で返す。
pub type Authenticator =
  fn(String) -> Result(List(event.Event), String)

/// AUTH を受けたときの結果。ログ行は `describe_auth` が作る。
pub type AuthOutcome {
  /// 受け口が無く、応答しなかった。
  NotAnswered
  /// 受け口が返したイベントを count 件、AUTH で送った。
  Answered(count: Int)
  /// 受け口が署名を得られなかった。
  Unsigned(reason: String)
}

/// 照合の契機。
pub type Trigger {
  /// 接続直後の照合か、張り直しの依頼。
  Requested
  /// 予約した再試行のタイマー。generation はそのタイマーを予約したときの世代。
  Retried(generation: Int)
  /// リレーが購読を閉じた（CLOSED）。定義は評価しない。reason は閉じた理由の
  /// 接頭辞で、開いている id なら扱いをこれで決める。
  Closed(subscription_id: String, reason: ClosedReason)
}

/// CLOSED の理由の NIP-01 の機械可読な接頭辞。`classify_closed` が読む。
pub type ClosedReason {
  /// `blocked:`。リレーがこの購読を受け付けない。
  Blocked
  /// `restricted:`。この購読に権限が無い。
  Restricted
  /// `auth-required:`。AUTH（NIP-42）を済ませれば受け付ける。
  AuthRequired
  /// `rate-limited:`。送る頻度が高すぎる。
  RateLimited
  /// 上のどれでもない理由（接頭辞が無い、`error:` など）。
  OtherReason
}

/// 購読の照合の状態。stratus のプロセスが持つ。
pub type SubscriptionState {
  SubscriptionState(
    /// 開いている購読 id と、その購読に最後に送ったフィルター。
    open: Dict(String, Filter),
    /// 予約中の再試行の世代。予約が無ければ None。予約は常に 1 つだけにする。
    retry: Option(Int),
    /// 次に予約するときに使う世代。予約するたびに 1 つ進める。
    next_generation: Int,
    /// 定義を得られなかったときに次に予約する、ジッターを掛ける前の待ち時間。
    delay_ms: Int,
    /// リレーが購読を閉じたときに次に予約する、ジッターを掛ける前の待ち時間。
    closed_delay_ms: Int,
    /// リレーが断ったので張り直さない購読 id。
    suspended: Set(String),
    /// AUTH の受け口を持つ接続か。接続の間は変わらない。
    answers_auth: Bool,
  )
}

/// 新たに予約する再試行の世代と、ジッターを掛ける前の待ち時間。
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
    /// 再試行と生存確認の刻みのタイマーの宛先。stratus の initialiser（stratus
    /// のプロセスの中で動く）で作り、セレクターに入れる。
    inbox: Subject(Msg),
    /// 生存確認の状態。
    keepalive: keepalive.Keepalive,
  )
}

/// 本番の購読の再試行の待ち時間。定義を得られなかったときと CLOSED で共用する。
/// 初期値はバンカーの署名者の問い合わせの期限に、上限はバンカーの読み込みの再試行の上限に
/// そろえる（どちらも DB の復帰を待つため）。
const subscription_retry_delay = backoff.Backoff(
  initial_ms: 5000,
  max_ms: 120_000,
)

/// 本番の生存確認の刻みの間隔（30 秒）。ping は無受信がこの 1 倍を超えて 2 倍
/// 以内に送り、切断は 2 倍を超えて 3 倍以内に起きる（`nostr_no_su/keepalive` を
/// 参照）。
const keepalive_interval_ms = 30_000

/// 接続が開く購読の定義と、受信・OK・AUTH の受け口。
pub type Handlers {
  Handlers(
    /// 開くべき購読。接続直後、張り直しの依頼、予約した再試行のたびに評価する。
    subscriptions: Subscriptions,
    /// id と署名を確かめたイベントと、保存済みイベントの終わり（EOSE）の受け口。
    handle_incoming: fn(Received) -> Nil,
    /// 発行したイベントへの OK の受け口。受理・拒否のどちらも渡す。
    handle_ok: fn(Acknowledgement) -> Nil,
    /// AUTH（NIP-42）の受け口。None の接続は AUTH に応答しない。
    authenticator: Option(Authenticator),
  )
}

/// 接続の待ちの設定。
pub type Timing {
  Timing(
    /// 購読の再試行の待ち時間の初期値と上限。
    retry_delay: backoff.Backoff,
    /// 生存確認の刻みの間隔。
    keepalive_interval_ms: Int,
  )
}

/// 本番の待ちの設定。
pub const default_timing = Timing(
  retry_delay: subscription_retry_delay,
  keepalive_interval_ms: keepalive_interval_ms,
)

/// 1 本の接続の間変わらない値。`conn` は stratus がメッセージごとに渡すので、
/// `start` の受信ループがメッセージごとに組む。
type Link {
  Link(
    conn: stratus.Connection,
    prefix: String,
    handlers: Handlers,
    timing: Timing,
  )
}

/// 生存確認の ping に送るペイロード。空にすると、上流の stratus の `send_ping`
/// がマスクを 4 ビットの値で組み立てて `let assert` に失敗する。
const ping_payload = <<"nostr-no-su">>

/// ハンドシェイクに許す時間。`start` は呼び出し元を最大でこの時間（さらに
/// stratus が上乗せする 100ms）ブロックする。接続アクター（`relay_list.connections_child`
/// の factory の子）はブロック中に factory の停止要求に応答できないため、この値は
/// factory の子の停止タイムアウト（`factory_supervisor.worker_child` の既定 5000ms）
/// より小さくしておく必要がある。さもないと、応答しないリレーを待っている接続の停止が
/// 強制 kill で終わる。
const connect_timeout_ms = 3000

/// リレー URL を stratus が期待する http(s) リクエストに変換する。受けるのは
/// `ws://` か `wss://`（小文字）で始まり、ホストが空でない URL だけで、それ以外は
/// `Error(Nil)`。gleam_http は http(s) スキームしかパースせず、stratus は Https を
/// wss/TLS に対応付けるので、`wss` を `https`、`ws` を `http` に置き換えてから
/// `request.to` に渡す。
pub fn to_request(url: String) -> Result(Request(String), Nil) {
  use http_url <- result.try(case url {
    "wss://" <> rest -> Ok("https://" <> rest)
    "ws://" <> rest -> Ok("http://" <> rest)
    _ -> Error(Nil)
  })
  case request.to(http_url) {
    Ok(req) if req.host != "" -> Ok(req)
    _ -> Error(Nil)
  }
}

/// 接続直後の照合の状態。開いている購読も予約も止めた購読も無い。
/// `answers_auth` は AUTH の受け口を持つ接続か。
pub fn new_subscription_state(
  retry_delay: backoff.Backoff,
  answers_auth: Bool,
) -> SubscriptionState {
  SubscriptionState(
    open: dict.new(),
    retry: None,
    next_generation: 1,
    delay_ms: retry_delay.initial_ms,
    closed_delay_ms: retry_delay.initial_ms,
    suspended: set.new(),
    answers_auth: answers_auth,
  )
}

/// `url` のリレーに接続し、`handlers.subscriptions` の購読を開き、受信を `handlers` の
/// 受け口へ渡す。イベントの id と署名の検証はこの接続のプロセスの中で行う。接続アクターは
/// 呼び出し元にリンクされるため呼び出し元と一緒に死に、exit を trap している呼び出し元には
/// その死がメッセージとして届く。URL を読めないときとハンドシェイクに失敗したときは、
/// 理由を `Error` で返す。
pub fn start(
  url: String,
  handlers: Handlers,
  timing: Timing,
) -> Result(Client, String) {
  use req <- result.try(
    to_request(url)
    |> result.replace_error("invalid relay url: " <> url),
  )
  let prefix = log.relay_prefix(url)
  let builder =
    stratus.new_with_initialiser(req, fn() {
      let inbox = process.new_subject()
      let _ =
        process.send_after(inbox, timing.keepalive_interval_ms, KeepaliveTick)
      Session(
        subscriptions: new_subscription_state(
          timing.retry_delay,
          option.is_some(handlers.authenticator),
        ),
        inbox: inbox,
        keepalive: keepalive.new(),
      )
      |> stratus.initialised
      |> stratus.selecting(process.new_selector() |> process.select(inbox))
      |> Ok
    })
    |> stratus.with_connect_timeout(connect_timeout_ms)
    |> stratus.on_message(fn(session, msg, conn) {
      let link = Link(conn:, prefix:, handlers:, timing:)
      let session = record_inbound(session, msg)
      case msg {
        stratus.User(KeepaliveTick) -> check_keepalive(session, link)
        stratus.User(Disconnect) -> close_gracefully(session, link)
        _ ->
          case handle_message(link, msg) {
            Some(trigger) -> synchronise(session, trigger, link)
            None -> session
          }
          |> stratus.continue
      }
    })
    |> stratus.on_close(fn(_session, reason) {
      log.write(
        log.Notice,
        prefix,
        "connection closed: " <> string.inspect(reason),
      )
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

/// 接続を閉じ、止まるのを `timeout_ms` まで待つ。呼び出し元とのリンクを解いてから
/// 接続のプロセスを監視し、開いている購読の CLOSE と WebSocket の close フレーム
/// （状態コード 1000）を送って止まるよう依頼する。期限までに止まらなければ kill
/// して戻る。すでに止まっている接続には何もしない。
pub fn disconnect(client: Client, timeout_ms: Int) -> Nil {
  case process.subject_owner(client) {
    Error(Nil) -> Nil
    Ok(pid) -> {
      process.unlink(pid)
      let monitor = process.monitor(pid)
      process.send(client, stratus.to_user_message(Disconnect))
      let stopped =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_down) { Nil })
        |> process.selector_receive(timeout_ms)
      case stopped {
        Ok(Nil) -> Nil
        Error(Nil) -> {
          process.demonitor_process(monitor)
          process.kill(pid)
        }
      }
    }
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

/// 再試行を予約する原因。原因ごとに待ち時間を別に数える。
type Cause {
  /// 定義を得られなかった。
  Unavailable
  /// リレーが購読を閉じた。
  ClosedByRelay
}

/// 照合 1 回ぶんの判断（規則はモジュール Doc）。定義は、捨てる再試行で評価しない
/// （バンカーへ問い合わせない）ようサンクで受け取る。
pub fn sync(
  state: SubscriptionState,
  trigger: Trigger,
  subscriptions: Subscriptions,
  retry_delay: backoff.Backoff,
) -> Sync {
  case trigger, state.retry {
    Requested, _ ->
      evaluate(
        SubscriptionState(..state, suspended: set.new()),
        subscriptions,
        retry_delay,
        retry_delay.initial_ms,
      )
    // 現在の予約のタイマーは予約を消費する。
    Retried(generation), Some(reserved) if generation == reserved ->
      evaluate(
        SubscriptionState(..state, retry: None),
        subscriptions,
        retry_delay,
        state.closed_delay_ms,
      )
    // 解いた予約や置き換わった予約の、遅れて届いたタイマー。
    Retried(_), _ -> Sync(state: state, messages: [], schedule_retry: None)
    Closed(subscription_id, reason), _ ->
      forget_closed(state, subscription_id, reason, retry_delay)
  }
}

/// 定義を評価して照合する。止めた購読（`suspended`）は定義にあっても REQ を
/// 送らず、開いている購読にも入れない。得られなかったとき、予約が残っていれば
/// それに任せ、無ければ新しい世代で予約する。定義を得られたときの CLOSED の
/// 次の待ちは `closed_delay_after_success`。
fn evaluate(
  state: SubscriptionState,
  subscriptions: Subscriptions,
  retry_delay: backoff.Backoff,
  closed_delay_after_success: Int,
) -> Sync {
  case subscriptions() {
    Ok(wanted) -> {
      let wanted =
        list.filter(wanted, fn(entry) {
          !set.contains(state.suspended, entry.0)
        })
      let #(open, messages) = reconcile(state.open, wanted)
      Sync(
        state: SubscriptionState(
          ..state,
          open: open,
          retry: None,
          delay_ms: retry_delay.initial_ms,
          closed_delay_ms: closed_delay_after_success,
        ),
        messages: messages,
        schedule_retry: None,
      )
    }
    Error(Nil) -> reserve(state, Unavailable, retry_delay)
  }
}

/// 予約が無ければ新しい世代で再試行を 1 つ予約し、原因の待ち時間で予約してその
/// 待ちを延ばす。予約が残っていれば原因にかかわらず何もしない。
fn reserve(
  state: SubscriptionState,
  cause: Cause,
  retry_delay: backoff.Backoff,
) -> Sync {
  case state.retry {
    Some(_reserved) -> Sync(state: state, messages: [], schedule_retry: None)
    None -> {
      let delay = case cause {
        Unavailable -> state.delay_ms
        ClosedByRelay -> state.closed_delay_ms
      }
      let grown = backoff.next(retry_delay, delay)
      let reserved =
        SubscriptionState(
          ..state,
          retry: Some(state.next_generation),
          next_generation: state.next_generation + 1,
        )
      Sync(
        state: case cause {
          Unavailable -> SubscriptionState(..reserved, delay_ms: grown)
          ClosedByRelay -> SubscriptionState(..reserved, closed_delay_ms: grown)
        },
        messages: [],
        schedule_retry: Some(Reservation(
          generation: state.next_generation,
          delay_ms: delay,
        )),
      )
    }
  }
}

/// リレーが閉じた購読を開いている購読から外し、理由の接頭辞で止めるか再試行を予約する
/// （規則はモジュール Doc）。CLOSE は送らない。
fn forget_closed(
  state: SubscriptionState,
  subscription_id: String,
  reason: ClosedReason,
  retry_delay: backoff.Backoff,
) -> Sync {
  case dict.has_key(state.open, subscription_id) {
    False -> Sync(state: state, messages: [], schedule_retry: None)
    True -> {
      let removed =
        SubscriptionState(
          ..state,
          open: dict.delete(state.open, subscription_id),
        )
      case reason, state.answers_auth {
        Blocked, _ | Restricted, _ | AuthRequired, False ->
          Sync(
            state: SubscriptionState(
              ..removed,
              suspended: set.insert(state.suspended, subscription_id),
            ),
            messages: [],
            schedule_retry: None,
          )
        RateLimited, _ ->
          reserve(
            SubscriptionState(..removed, closed_delay_ms: retry_delay.max_ms),
            ClosedByRelay,
            retry_delay,
          )
        AuthRequired, True | OtherReason, _ ->
          reserve(removed, ClosedByRelay, retry_delay)
      }
    }
  }
}

/// 定義にある購読のうち開いている購読が覆わないものの REQ と、開いていて定義から消えた
/// 購読の CLOSE（`close_messages`）と、照合の後に開いている購読。覆う購読は最後に送った
/// フィルターを残す。REQ は定義の順に並べる。
fn reconcile(
  open: Dict(String, Filter),
  wanted: List(#(String, Filter)),
) -> #(Dict(String, Filter), List(message.ClientMessage)) {
  let decided = list.map(wanted, reconcile_one(open, _))
  let next = dict.from_list(list.map(decided, fn(d) { d.0 }))
  let requests = list.filter_map(decided, fn(d) { option.to_result(d.1, Nil) })
  let closes = close_messages(dict.keys(dict.drop(open, dict.keys(next))))
  #(next, list.append(requests, closes))
}

/// 購読 id ごとの CLOSE。送る順が毎回同じになるよう id の順に並べる。
fn close_messages(ids: List(String)) -> List(message.ClientMessage) {
  ids |> list.sort(string.compare) |> list.map(message.Close)
}

/// 定義の購読 1 件の照合。開いている購読が覆えば、送ったフィルターを残して
/// 何も送らない。覆わないか開いていなければ、定義のフィルターを残してその REQ
/// を送る。
fn reconcile_one(
  open: Dict(String, Filter),
  entry: #(String, Filter),
) -> #(#(String, Filter), Option(message.ClientMessage)) {
  let #(id, wanted) = entry
  case dict.get(open, id) {
    Ok(sent) ->
      case covers(sent, wanted) {
        True -> #(#(id, sent), None)
        False -> #(entry, Some(message.Req(id, wanted)))
      }
    Error(Nil) -> #(entry, Some(message.Req(id, wanted)))
  }
}

/// 送ったフィルター `sent` の開いている購読が、定義のフィルター `wanted` の
/// 購読を覆うか。`since` 以外のフィールドが同じで、`sent` の `since` が無いか
/// `wanted` の `since` 以下なら覆う（`sent` の購読は `wanted` の範囲をすべて
/// 運ぶ）。`wanted` だけ `since` が無ければ覆わない。
fn covers(sent: Filter, wanted: Filter) -> Bool {
  let since_covered = case sent.since, wanted.since {
    None, _ -> True
    Some(sent_since), Some(wanted_since) -> sent_since <= wanted_since
    Some(_), None -> False
  }
  since_covered && Filter(..sent, since: wanted.since) == wanted
}

/// 生存確認の刻みと切断の依頼を除くメッセージ 1 件を処理し、照合の契機があれば返す。
/// 刻みと切断の依頼は `start` の受信ループが先に扱うので、ここでは何もしない。
fn handle_message(link: Link, msg: stratus.Message(Msg)) -> Option(Trigger) {
  case msg {
    stratus.User(Subscribe) -> Some(Requested)
    stratus.User(RetrySubscribe(generation)) -> Some(Retried(generation))
    stratus.User(Publish(published)) -> {
      send_message(link.conn, link.prefix, message.Publish(published))
      None
    }
    stratus.Text(text) ->
      handle_text(
        link.prefix,
        text,
        link.handlers.handle_incoming,
        link.handlers.handle_ok,
        link.handlers.authenticator,
        send_message(link.conn, link.prefix, _),
      )
    stratus.User(KeepaliveTick)
    | stratus.User(Disconnect)
    | stratus.Binary(_)
    | stratus.Pong(_) -> None
  }
}

/// 照合を 1 回行い、その結果を送信と再試行の予約に移す。照合で新しく止めた
/// 購読は 1 件ごとに Warning を 1 行出す。判断は `sync` にある。
fn synchronise(session: Session, trigger: Trigger, link: Link) -> Session {
  let synced =
    sync(
      session.subscriptions,
      trigger,
      link.handlers.subscriptions,
      link.timing.retry_delay,
    )
  list.each(synced.messages, send_message(link.conn, link.prefix, _))
  case synced.schedule_retry {
    None -> Nil
    Some(reservation) -> {
      let delay = backoff.jittered(reservation.delay_ms)
      log.write(
        reservation_log_level(trigger),
        link.prefix,
        describe_reservation(trigger, delay),
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
  list.each(
    set.to_list(set.difference(
      synced.state.suspended,
      session.subscriptions.suspended,
    )),
    fn(subscription_id) {
      log.write(
        log.Warning,
        link.prefix,
        "subscription "
          <> log.sanitize_external(subscription_id)
          <> " was refused by the relay; not resubscribing until the next connection or a change of subscriptions",
      )
    },
  )
  Session(..session, subscriptions: synced.state)
}

/// 再試行を予約したときのログの水準。張り直す CLOSED はリレーの通常の応答なので
/// Notice に、定義を得られなかった予約は異常なので Warning にする。止めた
/// CLOSED は予約しないので、ここではなく `synchronise` が Warning で出す。
fn reservation_log_level(trigger: Trigger) -> log.Level {
  case trigger {
    Closed(..) -> log.Notice
    Requested | Retried(_) -> log.Warning
  }
}

/// 再試行を予約したときのログ行の本文。CLOSED による予約と、定義を得られなかった
/// 予約を分けて書く。CLOSED の理由は `handle_text` が先に出す。
fn describe_reservation(trigger: Trigger, delay: Int) -> String {
  case trigger {
    Closed(subscription_id, _) ->
      "subscription "
      <> log.sanitize_external(subscription_id)
      <> " was closed by the relay; resubscribing in "
      <> int.to_string(delay)
      <> "ms"
    Requested | Retried(_) ->
      "could not evaluate subscriptions; keeping the current ones and retrying in "
      <> int.to_string(delay)
      <> "ms"
  }
}

/// リレーから何かを受信したら生存確認の状態に記録する。自分宛てのメッセージは
/// 受信に数えない。
fn record_inbound(session: Session, msg: stratus.Message(Msg)) -> Session {
  case msg {
    stratus.User(_) -> session
    stratus.Text(_) | stratus.Binary(_) | stratus.Pong(_) ->
      Session(..session, keepalive: keepalive.received())
  }
}

/// 生存確認の刻み 1 回。判定は `keepalive.tick` にあり、ここは ping の送信、
/// 次の刻みの予約、停止に移すだけである。
fn check_keepalive(session: Session, link: Link) -> stratus.Next(Session, Msg) {
  let #(next, verdict) = keepalive.tick(session.keepalive)
  let interval_ms = link.timing.keepalive_interval_ms
  case verdict {
    keepalive.Healthy -> continue_after_tick(session, next, interval_ms)
    keepalive.SendPing -> {
      case stratus.send_ping(link.conn, ping_payload) {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.write(
            log.Warning,
            link.prefix,
            "failed to send ping: " <> string.inspect(reason),
          )
      }
      continue_after_tick(session, next, interval_ms)
    }
    keepalive.Unresponsive -> {
      log.write(
        log.Warning,
        link.prefix,
        "no data or pong within "
          <> int.to_string(interval_ms)
          <> "ms after a ping; closing the connection",
      )
      stratus.stop()
    }
  }
}

/// `Disconnect` の処理。開いている購読の CLOSE（`close_messages`）と close フレーム
/// （状態コード 1000）を送って止まる。close フレームを書けなかったときは理由をログに残して
/// 止まる。リレーの close フレームを待たないのは、待つと `on_close` の Notice のログが
/// 問い合わせのたびに出るためである（ループが返した停止では `on_close` は呼ばれない）。
fn close_gracefully(
  session: Session,
  link: Link,
) -> stratus.Next(Session, Msg) {
  list.each(close_messages(dict.keys(session.subscriptions.open)), fn(outgoing) {
    send_message(link.conn, link.prefix, outgoing)
  })
  case stratus.close(link.conn, stratus.Normal(<<>>)) {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.write(
        log.Warning,
        link.prefix,
        "failed to send a close frame: " <> string.inspect(reason),
      )
  }
  stratus.stop()
}

/// 次の生存確認の刻みを予約し、状態を更新して continue する。
/// `Healthy` と `SendPing` の判定はどちらもこれで終わる。
fn continue_after_tick(
  session: Session,
  next_keepalive: keepalive.Keepalive,
  interval_ms: Int,
) -> stratus.Next(Session, Msg) {
  let _ = process.send_after(session.inbox, interval_ms, KeepaliveTick)
  stratus.continue(Session(..session, keepalive: next_keepalive))
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
      log.write(
        log.Warning,
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
    message.Auth(signed) -> "authentication event " <> signed.id
  }
}

/// リレーの接続からハンドラーへ渡る受信 1 件。`ReceivedEvent` は購読 id と
/// 検証済みのイベント、`ReceivedEose` は保存済みイベントの終わりを告げた
/// 購読 id。
pub type Received {
  ReceivedEvent(subscription_id: String, event: event.Verified)
  ReceivedEose(subscription_id: String)
}

/// リレーが発行したイベントに返した OK 1 件。受理・拒否のどちらも表す。値は
/// 外部由来で、正規化済み（`log.sanitize_external`）。
pub type Acknowledgement {
  Acknowledgement(event_id: String, accepted: Bool, message: String)
}

/// リレーメッセージ 1 件の解釈の結果。
pub type Interpretation {
  /// 検証を通ったイベント。購読 id は振り分けに使うので正規化しない。
  Deliver(subscription_id: String, event: event.Verified)
  /// 保存済みイベントの終わり（EOSE）。id は振り分けに使うので正規化せず、line は正規化済み。
  Ended(subscription_id: String, line: String)
  /// 出力するログ行の本文。外部由来の値は正規化済み。
  Report(String)
  /// 発行したイベントへの OK（受理・拒否とも）。値は正規化済み。
  Acknowledge(Acknowledgement)
  /// 購読の状態を変える応答（CLOSED）。契機の id は照合に使うので正規化せず、line は正規化済み。
  Synchronise(trigger: Trigger, line: String)
  /// AUTH の challenge。署名に使うので正規化しない。
  Authenticate(challenge: String)
}

/// リレーメッセージ 1 件を解釈する。EVENT は `event.verify` で id と署名を
/// 確かめ、通ったものを配送に回す。EOSE は届いた購読の id を残して `Ended`
/// にする。OK は受理・拒否とも `Acknowledge` にする。CLOSED は購読の状態を
/// 変えるため、理由の接頭辞を `classify_closed` で読んだ契機を載せて
/// `Synchronise` にする。AUTH は `Authenticate` にする。それ以外のメッセージと
/// 落としたイベントは、外部由来の値を `log.sanitize_external` で 1 行に収めた
/// ログ行の本文にする。
pub fn interpret(text: String) -> Interpretation {
  case message.decode_relay_message(text) {
    Ok(message.RelayEvent(subscription, received)) ->
      case event.verify(received) {
        Ok(verified) -> Deliver(subscription, verified)
        Error(error) ->
          Report(
            "dropped event with "
            <> describe_verify_error(error)
            <> ": "
            <> log.sanitize_external(received.id),
          )
      }
    Ok(message.RelayEose(subscription)) ->
      Ended(
        subscription,
        "end of stored events for " <> log.sanitize_external(subscription),
      )
    Ok(message.RelayOk(id, accepted, reason)) ->
      Acknowledge(Acknowledgement(
        log.sanitize_external(id),
        accepted,
        log.sanitize_external(reason),
      ))
    Ok(message.RelayNotice(text)) ->
      Report("notice: " <> log.sanitize_external(text))
    Ok(message.RelayClosed(subscription, reason)) ->
      Synchronise(
        Closed(subscription, classify_closed(reason)),
        "subscription "
          <> log.sanitize_external(subscription)
          <> " closed: "
          <> log.sanitize_external(reason),
      )
    Ok(message.RelayAuth(challenge)) -> Authenticate(challenge)
    Error(_) -> Report("unrecognised message: " <> log.sanitize_external(text))
  }
}

/// CLOSED の理由の NIP-01 の接頭辞を読む。最初の `:` の前が決まった語と一致
/// しなければ（`:` が無い、大文字違いを含む）`OtherReason`。
fn classify_closed(reason: String) -> ClosedReason {
  case string.split_once(reason, ":") {
    Ok(#("blocked", _)) -> Blocked
    Ok(#("restricted", _)) -> Restricted
    Ok(#("auth-required", _)) -> AuthRequired
    Ok(#("rate-limited", _)) -> RateLimited
    _ -> OtherReason
  }
}

/// `interpret` の結果を受け口とログと `send` に移し、照合の契機があれば返す。
pub fn handle_text(
  prefix: String,
  text: String,
  handle_incoming: fn(Received) -> Nil,
  handle_ok: fn(Acknowledgement) -> Nil,
  authenticator: Option(Authenticator),
  send: fn(message.ClientMessage) -> Nil,
) -> Option(Trigger) {
  case interpret(text) {
    Deliver(subscription_id, verified) -> {
      handle_incoming(ReceivedEvent(subscription_id, verified))
      None
    }
    Ended(subscription_id, line) -> {
      log.write(log.Notice, prefix, line)
      handle_incoming(ReceivedEose(subscription_id))
      None
    }
    Report(line) -> {
      log.write(log.Notice, prefix, line)
      None
    }
    Acknowledge(ack) -> {
      case ack.accepted {
        False ->
          log.write(
            log.Warning,
            prefix,
            "rejected event " <> ack.event_id <> ": " <> ack.message,
          )
        // 受理は発行 1 件につき 1 行増えるだけで何も伝えないため、出力しない。
        True -> Nil
      }
      handle_ok(ack)
      None
    }
    Synchronise(trigger, line) -> {
      log.write(log.Notice, prefix, line)
      Some(trigger)
    }
    Authenticate(challenge) -> {
      let #(level, line) =
        describe_auth(answer_auth(authenticator, challenge, send))
      log.write(level, prefix, line)
      None
    }
  }
}

/// 受け口に challenge を渡し、得たイベントを 1 件ずつ AUTH で送る。受け口が
/// 無ければ何もしない。
fn answer_auth(
  authenticator: Option(Authenticator),
  challenge: String,
  send: fn(message.ClientMessage) -> Nil,
) -> AuthOutcome {
  case authenticator {
    None -> NotAnswered
    Some(authenticate) ->
      case authenticate(challenge) {
        Ok(signed) -> {
          list.each(signed, fn(event) { send(message.Auth(event)) })
          Answered(list.length(signed))
        }
        Error(reason) -> Unsigned(reason)
      }
  }
}

/// AUTH を受けたときのログの水準と本文。
pub fn describe_auth(outcome: AuthOutcome) -> #(log.Level, String) {
  case outcome {
    NotAnswered -> #(
      log.Notice,
      "relay requested authentication; not answering on this connection",
    )
    Answered(count) -> #(
      log.Notice,
      "answered authentication with " <> int.to_string(count) <> " event(s)",
    )
    Unsigned(reason) -> #(
      log.Warning,
      "could not answer authentication: " <> reason,
    )
  }
}

/// 検証で落としたイベントのログに出す理由。
fn describe_verify_error(error: event.VerifyError) -> String {
  case error {
    event.InvalidId -> "invalid id"
    event.InvalidSignature -> "invalid signature"
  }
}
