//// リレーへの WebSocket 接続 1 本（stratus）。
////
//// 購読は「現在の定義に合わせる」照合で開く。契機は接続直後、張り直しの依頼、
//// 予約した再試行、リレーの CLOSED である。接続直後と張り直しの依頼では定義を評価し、
//// 定義にある購読には REQ（同じ id は NIP-01 で置き換え）を、開いていて定義から
//// 消えた購読には CLOSE を送る。定義を得られなかったときは開いている購読を変えずに
//// 再試行を 1 つだけ予約する。CLOSED を受けたら、その id を開いている購読から外し、
//// 理由の NIP-01 の接頭辞で扱いを分ける。`blocked:`、`restricted:`、AUTH の受け口の
//// 無い接続での `auth-required:` は、次の再接続（この接続の状態ごと作り直す）か
//// 張り直しの依頼まで張り直さない。`rate-limited:` は CLOSED の待ちを上限に上げてから、
//// それ以外はその時点の CLOSED の待ちで、再試行を予約して張り直す。判断は純粋関数
//// `sync` にあり、stratus のループはその結果を送信と予約とログに移すだけである。
//// 生存確認は一定間隔で受信の有無を確かめ、無ければ ping を送り、それでも受信が
//// 無ければ自ら接続を止めて `relay_connection` に張り直させる。
//// AUTH（NIP-42）は受け口があれば応答し、無ければ応答せずログに出す。

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
import nostr_no_su/nostr/filter.{type Filter}
import nostr_no_su/nostr/message
import stratus

/// リレー接続に対する指示。stratus のユーザーメッセージとして送る。
pub type Msg {
  /// 購読を現在の定義に合わせる。定義にある購読には REQ を送り（同じ id は置き換え
  /// になる）、開いていて定義から消えた購読には CLOSE を送る。接続直後と、張り直しの
  /// 依頼で送る。
  Subscribe
  /// 定義を得られなかった照合か、リレーが閉じた購読の張り直しをやり直す。
  /// relay_client が自分宛てに予約する。generation は予約の世代。
  RetrySubscribe(generation: Int)
  /// イベントを 1 件このソケットから発行する。
  Publish(event: event.Event)
  /// 生存確認の刻み。relay_client が自分宛てに予約する。
  KeepaliveTick
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
    /// 開いている購読 id。
    open: Set(String),
    /// 予約中の再試行の世代。予約が無ければ None。予約は常に 1 つだけにする。
    retry: Option(Int),
    /// 次に予約するときに使う世代。予約するたびに 1 つ進める。
    next_generation: Int,
    /// 定義を得られなかったときに予約する、ジッターを掛ける前の待ち時間。定義を
    /// 得るたびに初期値に戻す。
    delay_ms: Int,
    /// リレーが購読を閉じたときに予約する、ジッターを掛ける前の待ち時間。
    /// `rate-limited:` の CLOSED で上限に上げる。張り直しの依頼で定義を得た
    /// ときだけ初期値に戻す。
    closed_delay_ms: Int,
    /// リレーが断ったので張り直さない購読 id。張り直しの依頼で空にする。
    /// 再接続では状態ごと作り直すので空から始まる。
    suspended: Set(String),
    /// AUTH の受け口を持つ接続か。`auth-required:` の CLOSED で購読を止めるかを
    /// 決める。接続の間は変わらない。
    answers_auth: Bool,
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
    /// 再試行と生存確認の刻みのタイマーの宛先。stratus の initialiser（stratus
    /// のプロセスの中で動く）で作り、セレクターに入れる。
    inbox: Subject(Msg),
    /// 生存確認の状態。
    keepalive: keepalive.Keepalive,
  )
}

/// 購読の定義を得られなかったとき、およびリレーが購読を閉じたときの本番の
/// 再試行の待ち時間。2 つの原因は待ちを別々に数える。
///
/// 待ちは評価が終わってから数える（`synchronise` が `sync` の後に
/// `process.send_after` で予約する）。評価 1 回の待ちは、監視の購読ではバンカーの
/// 署名者の問い合わせ（5000ms、`bunker.gleam` の `call_timeout_ms`）、
/// ディスパッチャーの再開点（`dedup.call_timeout_ms`）、DB の再開点
/// （`resume_store` の期限）の和まで延びうるが、初期値より長くても再試行は重ならない
/// （予約は常に 1 つだけで、世代を付けて古いタイマーを捨てる）。
///
/// 初期値はバンカーの署名者の問い合わせの期限と同じにする。
/// 上限の 2 分はバンカーの読み込みの再試行の上限と同じにする。定義を得られない主な
/// 原因は、バンカーのアクターが DB で止まることと、DB の再開点を読めないことで、
/// どちらも DB の復帰を待つので、復帰の後に購読が追いつくまでの時間をそろえる。
/// CLOSED にも同じ初期値と上限を使う。恒久的に断る理由（`blocked:`、
/// `restricted:`、受け口の無い接続での `auth-required:`）の購読は再試行せず、
/// `rate-limited:` は最初から上限で待つ。それ以外の理由は一時か恒久かを区別
/// できないので、上限まで延ばして断り続けるリレーへの REQ を抑える。
pub const subscription_retry_delay = backoff.Backoff(
  initial_ms: 5000,
  max_ms: 120_000,
)

/// 本番の生存確認の刻みの間隔（30 秒）。ping は無受信がこの 1 倍を超えて 2 倍
/// 以内に送り、切断は 2 倍を超えて 3 倍以内に起きる（`nostr_no_su/keepalive` を
/// 参照）。
pub const keepalive_interval_ms = 30_000

/// 生存確認の ping に送るペイロード。空にすると、上流の stratus の `send_ping`
/// がマスクを 4 ビットの値で組み立てて `let assert` に失敗する。
const ping_payload = <<"nostr-no-su">>

/// ハンドシェイクに許す時間。`start` は呼び出し元を最大でこの時間（さらに
/// stratus が上乗せする 100ms）ブロックする。呼び出し元はスーパーバイザー配下の
/// アクターであり、ブロック中はスーパーバイザーの停止要求に応答できないため、
/// この値はワーカーの停止タイムアウト 5000ms（`relay_connection.supervised` を
/// 参照）より小さくしておく必要がある。さもないと、応答しないリレーを待っている
/// 接続の停止が強制 kill で終わる。
const connect_timeout_ms = 3000

/// リレー URL を stratus が期待する http(s) リクエストに変換する。gleam_http は
/// http(s) スキームしかパースせず、stratus は Https を wss/TLS に対応付ける。
/// ホストが空の URL（`wss://` など）は `request.to` が通すので、ここで
/// `Error(Nil)` にする。
pub fn to_request(url: String) -> Result(Request(String), Nil) {
  let parsed = case string.split_once(url, "://") {
    Ok(#("wss", rest)) -> request.to("https://" <> rest)
    Ok(#("ws", rest)) -> request.to("http://" <> rest)
    _ -> request.to(url)
  }
  case parsed {
    Ok(req) if req.host != "" -> Ok(req)
    _ -> Error(Nil)
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

/// 接続直後の照合の状態。開いている購読も予約も止めた購読も無い。
/// `answers_auth` は AUTH の受け口を持つ接続か。
pub fn new_subscription_state(
  retry_delay: backoff.Backoff,
  answers_auth: Bool,
) -> SubscriptionState {
  SubscriptionState(
    open: set.new(),
    retry: None,
    next_generation: 1,
    delay_ms: retry_delay.initial_ms,
    closed_delay_ms: retry_delay.initial_ms,
    suspended: set.new(),
    answers_auth: answers_auth,
  )
}

/// 指定のリレーに接続し、指定の購読を開き、id と署名を確かめたイベントと、
/// 保存済みイベントの終わり（EOSE）を `handle_incoming` へ渡す。発行した
/// イベントへの OK は受理・拒否とも `handle_ok` へ渡す。検証はこの接続の
/// プロセスの中で行う。`retry_delay` は購読の定義を得られなかったとき、
/// およびリレーが購読を閉じたときの再試行の待ち時間。
/// `interval_ms` は生存確認の刻みの間隔で、本番は `keepalive_interval_ms` を
/// 渡す。接続アクターは呼び出し元にリンクされるため呼び出し元と一緒に死に、
/// exit を trap している呼び出し元にはその死がメッセージとして届く。
/// リレーの AUTH には `authenticator` があれば応答し、無ければ応答せずログに出し、
/// `auth-required:` の CLOSED の購読を次の再接続か張り直しの依頼まで張り直さない。
pub fn start(
  url: String,
  subscriptions: Subscriptions,
  handle_incoming: fn(Received) -> Nil,
  handle_ok: fn(Acknowledgement) -> Nil,
  authenticator: Option(Authenticator),
  retry_delay: backoff.Backoff,
  interval_ms: Int,
) -> Result(Client, String) {
  use req <- result.try(
    to_request(url)
    |> result.replace_error("invalid relay url: " <> url),
  )
  let prefix = log.relay_prefix(label(url))
  let builder =
    stratus.new_with_initialiser(req, fn() {
      let inbox = process.new_subject()
      let _ = process.send_after(inbox, interval_ms, KeepaliveTick)
      Session(
        subscriptions: new_subscription_state(
          retry_delay,
          option.is_some(authenticator),
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
      let session = record_inbound(session, msg)
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
        stratus.User(KeepaliveTick) ->
          check_keepalive(session, conn, prefix, interval_ms)
        stratus.Text(text) ->
          case
            handle_text(
              prefix,
              text,
              handle_incoming,
              handle_ok,
              authenticator,
              send_message(conn, prefix, _),
            )
          {
            Some(trigger) ->
              synchronise(
                session,
                trigger,
                subscriptions,
                conn,
                prefix,
                retry_delay,
              )
              |> stratus.continue
            None -> stratus.continue(session)
          }
        stratus.Binary(_) -> stratus.continue(session)
        stratus.Pong(_) -> stratus.continue(session)
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

/// 照合 1 回ぶんの判断。現在の予約と世代が一致しない再試行は定義を評価せずに
/// 捨てる。CLOSED は定義を評価せず、開いている id だけ外して理由の接頭辞で
/// 扱いを決める（`forget_closed`）。それ以外は定義を評価し、得られれば止めた
/// 購読を除いて REQ と CLOSE を作って予約を解き、得られなければ何も送らず、
/// 予約が無ければ新しい世代で予約する。張り直しの依頼は評価の前に止めた購読を
/// 空にする。定義を得られたら定義失敗の待ち時間を初期値に戻し、張り直しの依頼で
/// 得たときは CLOSED の待ち時間も戻し、新しく予約するたびにその原因の待ち時間を
/// 延ばす。
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
      let wanted_ids = set.from_list(list.map(wanted, fn(entry) { entry.0 }))
      Sync(
        state: SubscriptionState(
          ..state,
          open: wanted_ids,
          retry: None,
          delay_ms: retry_delay.initial_ms,
          closed_delay_ms: closed_delay_after_success,
        ),
        messages: reconcile(state.open, wanted, wanted_ids),
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

/// リレーが閉じた購読を開いている購読から外し、理由の接頭辞で扱いを決める。
/// CLOSE は送らない。`blocked:`、`restricted:`、受け口の無い接続での
/// `auth-required:` は止めた購読に入れて予約しない（予約が残っていればそのまま
/// 残す）。`rate-limited:` は CLOSED の待ちを上限に上げてから、それ以外は
/// その時点の CLOSED の待ちで、再照合を予約する。予約が残っていればそれに
/// 任せる。開いていない id（こちらが CLOSE した購読や止めた購読への応答など）は
/// 無視する。
fn forget_closed(
  state: SubscriptionState,
  subscription_id: String,
  reason: ClosedReason,
  retry_delay: backoff.Backoff,
) -> Sync {
  case set.contains(state.open, subscription_id) {
    False -> Sync(state: state, messages: [], schedule_retry: None)
    True -> {
      let removed =
        SubscriptionState(
          ..state,
          open: set.delete(state.open, subscription_id),
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

/// 照合を 1 回行い、その結果を送信と再試行の予約に移す。照合で新しく止めた
/// 購読は 1 件ごとに Warning を 1 行出す。判断は `sync` にある。
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
      log.write(
        reservation_log_level(trigger),
        prefix,
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
        prefix,
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
      Session(..session, keepalive: keepalive.received(session.keepalive))
  }
}

/// 生存確認の刻み 1 回。判定は `keepalive.tick` にあり、ここは ping の送信、
/// 次の刻みの予約、停止に移すだけである。
fn check_keepalive(
  session: Session,
  conn: stratus.Connection,
  prefix: String,
  interval_ms: Int,
) -> stratus.Next(Session, Msg) {
  let #(next, verdict) = keepalive.tick(session.keepalive)
  case verdict {
    keepalive.Healthy -> continue_after_tick(session, next, interval_ms)
    keepalive.SendPing -> {
      case stratus.send_ping(conn, ping_payload) {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.write(
            log.Warning,
            prefix,
            "failed to send ping: " <> string.inspect(reason),
          )
      }
      continue_after_tick(session, next, interval_ms)
    }
    keepalive.Unresponsive -> {
      log.write(
        log.Warning,
        prefix,
        "no data or pong within "
          <> int.to_string(interval_ms)
          <> "ms after a ping; closing the connection",
      )
      stratus.stop()
    }
  }
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

/// リレーメッセージ 1 件の解釈の結果。`Deliver` は検証を通ったイベントと、
/// それが届いた購読の id、`Ended` は保存済みイベントの終わり（EOSE）を告げた
/// 購読の id とログ行の本文で、どちらの id も振り分けに使うため正規化しない。
/// `Report` は出力するログ行の本文（外部由来の値は正規化済み）、`Acknowledge` は
/// 発行したイベントへの OK（受理・拒否とも）、`Synchronise` は購読の状態を変える
/// 応答（CLOSED）で、ログ行の本文と照合の契機を持つ。契機の id は照合に使うため
/// 正規化しない。ログ行の本文は正規化済み。`Authenticate` は AUTH の challenge で、
/// 署名に使うため正規化しない。
pub type Interpretation {
  Deliver(subscription_id: String, event: event.Verified)
  Ended(subscription_id: String, line: String)
  Report(String)
  Acknowledge(Acknowledgement)
  Synchronise(trigger: Trigger, line: String)
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

/// リレーメッセージを 1 件処理する。解釈は `interpret` にあり、ここはその
/// 結果を配送とログ出力、`handle_ok` への通知に移すだけである。id と署名を
/// 確かめたイベントと、保存済みイベントの終わり（EOSE）を `handle_incoming`
/// へ渡す。`start` の受信ループが呼ぶほか、テストが直接呼ぶ。OK は受理・拒否
/// とも `handle_ok` に渡し、拒否だけそのリレーのログ行も出す。購読の状態を
/// 変える応答は契機を返し、ループが照合に渡す。AUTH は受け口があれば得た
/// イベントを `send` で送り、結果をログに出す。
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
