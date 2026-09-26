//// NIP-46 リクエスト処理の純粋なコア。プロセスも時計も乱数も IO も持たず、現在
//// 時刻と承認トークンは引数（`Inputs`）で受け取るため、すべての経路が決定的で
//// ループバックテストによる単体検証ができる。`bunker.gleam` がこれをアクターで
//// 包む。

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import nostr_no_su/bunker/account.{type Account, privkey, pubkey_hex}
import nostr_no_su/bunker/connection_secret.{type ConnectionSecret}
import nostr_no_su/bunker/permission.{type Permission}
import nostr_no_su/bunker/rate_limit
import nostr_no_su/bunker/rpc
import nostr_no_su/crypto/nip44
import nostr_no_su/hex
import nostr_no_su/nostr/event.{type Event, type Verified, Event}
import nostr_no_su/window

/// 時計が遅れたクライアントのずれを許容するため、現在時刻からこの秒数より古い
/// リクエストまでを受け付ける。
const past_window_seconds = 600

/// 現在時刻からこの秒数より先の `created_at` を持つリクエストは受け付けない。
/// 起点（`Inputs.not_before`）の保護が効かない時計の進みの上限になるため、過去側
/// より狭くする。
const future_window_seconds = 60

/// 承認待ちの有効期間。承認も拒否もされないまま放置された要求は、これを過ぎたら
/// 無かったものとして扱う。
pub const pending_ttl_seconds = 600

/// 承認待ちの有効期間を分で表した値。
pub fn pending_ttl_minutes() -> Int {
  pending_ttl_seconds / 60
}

/// セッション内のリクエストで最終利用を書き込む最小の間隔（秒）。これより短い
/// 間隔のリクエストは書き込みを伴わない。
const last_used_granularity_seconds = 60

/// 承認・拒否しようとした承認待ちが無い（不明、失効、処理済み）ときの理由。
pub const approval_request_not_found = "unknown or expired approval request"

/// `connect` で開くセッションか承認待ちを DB に書けなかったときに、同じ id で
/// クライアントへ返すエラーの理由。書き込みの結果によらず同じ文にし、ストアの
/// 理由は含めない。
pub const connection_not_saved = "could not save the connection; try connecting again"

/// 未知の方法へ返すエラーの理由。リクエストの方法名は含めない。応答は署名して
/// kind 24133 としてリレーへ載せるので、その内容をクライアントに決めさせない
/// ためである。
pub const unsupported_method = "unsupported method"

/// リプレイ防止のために少なくとも記憶するリクエスト id の件数。件数だけで区切る理由と、
/// 押し出された id のリプレイが通ったときに起こりうることは docs/design-decisions.md の
/// 「NIP-46 の入力にはサイズと件数の上限がある」にある。
const seen_capacity = 16_384

/// 承認済みセッションの件数の上限（全署名者で 1 つ）。新しいセッションを開くと、
/// 最終利用の古い順（`sessions` の並びの末尾）に押し出す。
pub const session_capacity = 32

/// 承認待ちの件数の上限（全署名者で 1 つ）。新しい承認待ちの登録で上限を超える
/// ときは、新しい要求と同じクライアントの最も古い承認待ち（署名者は問わない）を
/// 先に押し出し、同じクライアントの承認待ちが無いときだけ全体で作成の最も古い
/// ものを押し出す。
pub const pending_capacity = 16

/// `connect` の perms を保持する上限（バイト）。超える値はカンマの境で切る
/// （`bounded_perms`）。
pub const max_perms_bytes = 512

/// バンカーが持つ状態のすべて。プロセスも時計も持たない純粋な値で、`bunker` の
/// アクターがこれを保持して受信のたびに更新する。
pub type Engine {
  Engine(
    /// 署名者 pubkey hex -> #(account, 閉じ込めた接続 secret)
    accounts: Dict(String, #(Account, ConnectionSecret)),
    /// #(署名者, クライアント) -> Session
    sessions: Dict(#(String, String), Session),
    /// リプレイ防止用: 処理済みのリクエストイベント id
    seen: window.Window,
    /// 承認待ちの接続要求: token -> Pending
    pending: Dict(String, Pending),
    /// token から承認ページの URL を組み立てる関数。None なら承認フローを使わない。
    auth_url: Option(fn(String) -> String),
    /// #(署名者, クライアント) -> 最終利用の書き込みを最後に試みた時刻。書けなかった
    /// 間も `touch` の間引きに使う。
    touch_attempts: Dict(#(String, String), Int),
    /// セッションの外のリクエストを数える上限の状態（`rate_limit`）。
    limiter: rate_limit.Limiter,
  )
}

/// 受信イベント 1 件を処理する間に、外から注入する値。`now` は現在時刻（Unix 秒）、
/// `token` は承認待ちを作るときだけ使う承認トークン、`not_before` はアクターが起動した
/// 時刻で、`created_at` がこれより前の秒のリクエストは受け付けない。起点を置く理由と
/// 残る隙は docs/design-decisions.md の「バンカー actor は起動時刻より古いリクエストを
/// 処理しない」にある。
pub type Inputs {
  Inputs(now: Int, token: String, not_before: Int)
}

/// 承認待ちの接続要求 1 件。`token` は承認ページの URL に入る値で、辞書の鍵と
/// 同じものを持つ（一覧に出すときに鍵を持ち回らずに済む）。`request_id` は承認後
/// の応答を元の `connect` と同じ id で返すために覚えておく。`perms` は
/// `params[2]` を `max_perms_bytes` で切った値（無ければ空文字列）、
/// `secret_mismatch` は空でない secret が一致しなかったかどうかを表す。
/// `pending_capacity` を超えると、その Doc の規則で押し出される。
pub type Pending {
  Pending(
    token: String,
    signer: String,
    client: String,
    request_id: String,
    perms: String,
    secret_mismatch: Bool,
    created_at: Int,
  )
}

/// 承認済みのクライアントセッション 1 件。`connect` が成功した（署名者,
/// クライアント）の組で、取り消し、アカウントの削除、`session_capacity` による
/// 押し出しまで署名を代理できる。時刻は Unix 秒。
/// `last_used_at` は作成時に `created_at` と同じ値を入れ、セッション内の
/// リクエストを処理したとき、前回から `last_used_granularity_seconds` 以上
/// 経っていれば更新する。`perms` はセッション内の `sign_event` と
/// `nip44_encrypt` / `nip44_decrypt` を照合する権限で、組を最初に承認したとき
/// の値から、管理 UI の `set_perms` でだけ変わる。空のときは既定の集合
/// （`bunker/permission` の既定）で照合する。`relays` は `nostrconnect://` で開いたときの
/// URI のリレー（URI の順）で、`bunker://` の `connect` と承認で開いたセッション
/// では空である。承認済みの組を `nostrconnect://` で開き直すと、`relays` だけが
/// 新しい URI の一覧に変わる。
pub type Session {
  Session(
    signer: String,
    client: String,
    perms: String,
    created_at: Int,
    last_used_at: Int,
    relays: List(String),
  )
}

/// 状態の変更に伴う DB への書き込み 1 件。変種は `account_store` の書き込みの
/// 関数に 1 対 1 で対応する。
pub type Write {
  /// `insert_session_evicting`。`evicted` は押し出す（署名者, クライアント）の組。
  InsertSession(session: Session, evicted: List(#(String, String)))
  /// `delete_session`。
  DeleteSession(signer: String, client: String)
  /// `touch_session`。`session` は最終利用を進めた後の行の全列。
  TouchSession(session: Session)
  /// `update_session_perms`。`session` は `perms` を差し替えた後の行の全列。
  UpdateSessionPerms(session: Session)
  /// 同じ組の古い承認待ち `replaced` と、`pending_capacity` で押し出す承認待ち
  /// `evicted` を `delete_pending` で消し、`insert_pending` で登録する
  /// （`insert_pending_replacing`）。
  InsertPending(pending: Pending, replaced: List(String), evicted: List(String))
  /// `delete_pending`（拒否）。
  DeletePending(token: String)
  /// `approve`（承認待ちの削除とセッションの挿入、押し出しの削除を 1
  /// トランザクションで）。組がすでに承認済みなら `session` はメモリに残した
  /// 最初のセッションで、`insert_session` が行を上書きしても DB の値はメモリと
  /// 揃う（`open_session` 参照）。`evicted` は `InsertSession` と同じ、押し出す組。
  ApprovePending(
    token: String,
    session: Session,
    evicted: List(#(String, String)),
  )
}

/// `handle_event` の結果。`notice` はログに出す 1 行で、出すものが無ければ
/// `None`。`outside_session` はリクエストがセッションの外（（署名者,
/// クライアント）の組が承認済みでなく、接続 secret の一致する `connect` でも
/// ない）だったかで、受理しなかったイベントと復号できなかったイベントでは
/// 偽にする。
pub type Handled {
  Handled(
    engine: Engine,
    outcome: Outcome,
    notice: Option(String),
    outside_session: Bool,
  )
}

/// 受信イベント 1 件を処理した結果。
pub type Outcome {
  /// クライアントへ送り返す応答イベント。
  Reply(response: Event)
  /// DB への書き込みが要る応答。書けたら `response` を送って `next` で続け、
  /// 書けなかったら `on_failure` を送って `handle_event` の `engine` で続ける。
  Persist(write: Write, next: Engine, response: Event, on_failure: Event)
  /// 処理済みのリクエスト。2 つ目のバンカーリレーから同じものが届いた場合など。
  /// 複数リレー構成では想定内なので、呼び出し側はログを出さない。
  Duplicate
  /// リクエストを破棄した。ログに出す理由を伴う。
  Ignore(reason: String)
  /// セッションの外のリクエストが上限（`rate_limit`）を超えたので、実行も応答の
  /// 組み立てもせずに捨てた。捨てた件数は `Handled.notice` が間引いて報告する
  /// ので、呼び出し側はログを出さない。
  Throttled
}

/// リクエストを実行した結果（暗号化の前）。状態を変える実行は必ず書き込みを
/// 伴う。
type Execution {
  /// 状態を変えずに返す応答。
  Respond(response: rpc.Response)
  /// 書き込みが要る応答。`next` は書けたときのエンジン、`on_failure` は書けな
  /// かったときの応答。
  Record(
    write: Write,
    next: Engine,
    response: rpc.Response,
    on_failure: rpc.Response,
  )
}

/// 指定したアカウント群（それぞれの接続シークレット付き）を扱うエンジン。
/// `auth_url` は承認待ちの token から承認ページの URL を組み立てる関数で、
/// `None`（管理 UI が無効）なら承認フローも無効になる。URL の形を知っているのは
/// 呼び出し側だけなので、エンジンは管理 UI のルート構造に依存しない。
pub fn new(
  accounts: List(#(Account, String)),
  auth_url: Option(fn(String) -> String),
) -> Engine {
  let empty =
    Engine(
      accounts: dict.new(),
      sessions: dict.new(),
      seen: window.new(seen_capacity),
      pending: dict.new(),
      auth_url: auth_url,
      touch_attempts: dict.new(),
      limiter: rate_limit.new(),
    )
  use engine, pair <- list.fold(accounts, empty)
  add_account(engine, pair.0, pair.1)
}

/// アカウントを 1 件足す。同じ署名者がすでにあれば、鍵と secret を置き換え、
/// セッションと承認待ちは残す。secret はここで `ConnectionSecret` に閉じ込める。
///
/// この関数と下の `remove_account` / `replace_secret` は全域にしてある。アクターは
/// DB への書き込みが成功したときだけこれらを呼ぶので、不在や重複を失敗として返しても
/// 到達しない分岐になる。
pub fn add_account(engine: Engine, account: Account, secret: String) -> Engine {
  Engine(
    ..engine,
    accounts: dict.insert(engine.accounts, pubkey_hex(account), #(
      account,
      connection_secret.new(secret),
    )),
  )
}

/// アカウントを 1 件取り除き、その署名者の承認済みセッションと承認待ちも（失効の
/// 有無に関わらず）捨てる。登録されていない署名者なら何もしない。
///
/// 処理済みのリクエスト id（`seen`）は残す。リレーは購読の張り直しで直近の
/// リクエストを再配送するので、削除してすぐ戻したときに `seen` が空だと、実行済みの
/// リクエストを再実行してしまう。削除されていた間に届いたリクエストはルーティングで
/// 破棄されて `seen` に記録されないので、戻した後に届けば初めて実行される。
pub fn remove_account(engine: Engine, signer: String) -> Engine {
  Engine(
    ..engine,
    accounts: dict.delete(engine.accounts, signer),
    sessions: dict.filter(engine.sessions, fn(key, _session) { key.0 != signer }),
    pending: dict.filter(engine.pending, fn(_token, entry) {
      entry.signer != signer
    }),
  )
}

/// 接続 secret を差し替える。承認済みセッションは残る（取り消しは `revoke` で
/// 行う）。承認待ちは secret を持たない `connect` から作られ secret と無関係なので、
/// これも残す。登録されていない署名者なら何もしない。
pub fn replace_secret(
  engine: Engine,
  signer: String,
  secret: String,
) -> Engine {
  case dict.get(engine.accounts, signer) {
    Ok(#(account, _previous)) -> add_account(engine, account, secret)
    Error(Nil) -> engine
  }
}

/// 署名者として登録されているか。
pub fn has_account(engine: Engine, signer: String) -> Bool {
  dict.has_key(engine.accounts, signer)
}

/// 署名者の公開鍵の一覧（昇順）。
pub fn signers(engine: Engine) -> List(String) {
  dict.keys(engine.accounts)
  |> list.sort(string.compare)
}

/// 登録済みのアカウントと接続 secret（署名者の昇順）。閉じ込めた secret を開くのは
/// ここだけである。
pub fn registered_accounts(engine: Engine) -> List(#(Account, String)) {
  dict.to_list(engine.accounts)
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(entry) {
    let #(account, secret) = entry.1
    #(account, connection_secret.value(secret))
  })
}

/// 署名者のアカウント。登録されていなければ `Error(Nil)`。秘密鍵の再表示に使う。
pub fn find_account(engine: Engine, signer: String) -> Result(Account, Nil) {
  dict.get(engine.accounts, signer)
  |> result.map(fn(entry) { entry.0 })
}

/// 署名者とクライアントの組の承認済みセッション。承認されていない組なら
/// `Error(Nil)`。
pub fn find_session(
  engine: Engine,
  signer: String,
  client: String,
) -> Result(Session, Nil) {
  dict.get(engine.sessions, #(signer, client))
}

/// 承認済みセッションの一覧。辞書の走査順は未定義なので、表示とテストが安定し、
/// 使われていない組が末尾に来るよう、最終利用の新しい順、作成の新しい順、
/// 署名者、クライアントの昇順に並べる。
pub fn sessions(engine: Engine) -> List(Session) {
  engine.sessions
  |> dict.values
  |> list.sort(fn(left, right) {
    int.compare(right.last_used_at, left.last_used_at)
    |> order.break_tie(int.compare(right.created_at, left.created_at))
    |> order.break_tie(string.compare(left.signer, right.signer))
    |> order.break_tie(string.compare(left.client, right.client))
  })
}

/// セッションの承認を取り消す。そのクライアントは再び `connect` を求められる。
/// 書き込みの値は削除するセッションを表す `DeleteSession`。承認されていない組
/// なら `Error(Nil)` を返す。
pub fn revoke(
  engine: Engine,
  signer: String,
  client: String,
) -> Result(#(Engine, Write), Nil) {
  let pair = #(signer, client)
  case dict.has_key(engine.sessions, pair) {
    True ->
      Ok(#(
        Engine(..engine, sessions: dict.delete(engine.sessions, pair)),
        DeleteSession(signer: signer, client: client),
      ))
    False -> Error(Nil)
  }
}

/// 承認済みセッションの権限を差し替える。`perms` は `bounded_perms` で
/// `max_perms_bytes` に収める。承認されていない組なら `Error(Nil)` を返す。
pub fn set_perms(
  engine: Engine,
  signer: String,
  client: String,
  perms: String,
) -> Result(#(Engine, Write), Nil) {
  let pair = #(signer, client)
  case dict.get(engine.sessions, pair) {
    Ok(session) -> {
      let bounded = bounded_perms(perms)
      let updated = Session(..session, perms: bounded)
      Ok(#(
        Engine(..engine, sessions: dict.insert(engine.sessions, pair, updated)),
        UpdateSessionPerms(session: updated),
      ))
    }
    Error(Nil) -> Error(Nil)
  }
}

/// 失効していない承認待ちの一覧。表示が安定し、押し出しの対象を決める元の並びに
/// なるよう、作成の新しい順、token の昇順に並べる。失効した要求は状態からすぐに
/// 消えるわけではないが、この一覧にも `find_pending` にも `approve` / `deny` にも
/// 現れず、次の登録か成功した承認・拒否のときにまとめて捨てられる。
pub fn pending(engine: Engine, now: Int) -> List(Pending) {
  live_pending(engine, now) |> newest_pending
}

/// token の失効していない承認待ち。知らない token と失効した要求は `Error(Nil)`。
pub fn find_pending(
  engine: Engine,
  token: String,
  now: Int,
) -> Result(Pending, Nil) {
  case dict.get(engine.pending, token) {
    Ok(entry) ->
      case expired(entry, now) {
        True -> Error(Nil)
        False -> Ok(entry)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// 承認待ちの辞書の値を、作成の新しい順、token の昇順に並べる。
fn newest_pending(entries: Dict(String, Pending)) -> List(Pending) {
  entries
  |> dict.values
  |> list.sort(fn(left, right) {
    int.compare(right.created_at, left.created_at)
    |> order.break_tie(string.compare(left.token, right.token))
  })
}

/// DB から読んだセッションと承認待ちで `sessions` と `pending` を置き換える。
/// DB の型に依存しないよう、値はエンジンの型（`Session`・`Pending`）で受け取る。
/// `accounts`、`seen`、`auth_url`、`limiter` は変えない。DB が正なので既存の値には足さず
/// 置き換える。署名者が登録されていないセッションと承認待ちは、
/// `remove_account` と揃えて読み飛ばす。失効した承認待ち（`expired`）も同じく
/// 読み飛ばす。`touch_attempts` は読み込んだセッションに組がある項目だけ残す
/// （書けなかった書き込みの後の読み直しで、すぐ書き直さないため）。失敗は
/// 返さない。
pub fn restore(
  engine: Engine,
  sessions: List(Session),
  pending: List(Pending),
  now: Int,
) -> Engine {
  let registered = fn(signer: String) -> Bool {
    dict.has_key(engine.accounts, signer)
  }
  let sessions =
    sessions
    |> list.filter(fn(session) { registered(session.signer) })
    |> list.map(fn(session) { #(#(session.signer, session.client), session) })
    |> dict.from_list
  let pending =
    pending
    |> list.filter(fn(entry) {
      registered(entry.signer) && !expired(entry, now)
    })
    |> list.map(fn(entry) { #(entry.token, entry) })
    |> dict.from_list
  let touch_attempts =
    dict.filter(engine.touch_attempts, fn(pair, _attempted_at) {
      dict.has_key(sessions, pair)
    })
  Engine(
    ..engine,
    sessions: sessions,
    pending: pending,
    touch_attempts: touch_attempts,
  )
}

/// 承認待ちの接続要求を承認する。（署名者, クライアント）を承認済みにして、元の
/// `connect` と同じ id の `ack` 応答イベントを返す。書き込みの値は
/// `ApprovePending`（組がすでに承認済みのときの値はその Doc を参照）。token が
/// 不明、あるいは失効していれば理由を返す。
pub fn approve(
  engine: Engine,
  token: String,
  now: Int,
) -> Result(#(Engine, Event, Write), String) {
  use #(engine, entry) <- result.try(take_pending(engine, token, now))
  let session = new_session(entry.signer, entry.client, entry.perms, [], now)
  let #(engine, kept, evicted) = open_session(engine, session)
  use reply <- result.map(respond(
    engine,
    entry.signer,
    entry.client,
    rpc.ok(entry.request_id, "ack"),
    now,
  ))
  #(
    engine,
    reply,
    ApprovePending(token: token, session: kept, evicted: evicted),
  )
}

/// クライアントが出した `nostrconnect://` に応じて、（署名者, クライアント）の組を
/// 承認済みにする。承認待ちを作らずに直接セッションを開き、URI の `secret` を
/// `result` に入れた応答イベントを返す。`perms` は `bounded_perms` で切り、
/// `relays`（URI のリレー）はセッションに持たせる。書き込みの値は
/// `InsertSession`（押し出す組つき）。組がすでに承認済みなら、既存のセッションの
/// 権限と時刻を保ち、`relays` だけを今回の値にして、書き込みの値もその値にして
/// 応答を返す（クライアントは secret の受領を待っているため）。署名者が登録
/// されていないか、会話鍵か署名を作れないときは理由を返す。
pub fn open_client_session(
  engine: Engine,
  signer: String,
  client: String,
  perms: String,
  relays: List(String),
  secret: String,
  request_id: String,
  now: Int,
) -> Result(#(Engine, Event, Write), String) {
  let session = new_session(signer, client, bounded_perms(perms), relays, now)
  let #(engine, kept, evicted) = open_session(engine, session)
  let kept = Session(..kept, relays: relays)
  let engine =
    Engine(
      ..engine,
      sessions: dict.insert(engine.sessions, #(signer, client), kept),
    )
  use reply <- result.map(respond(
    engine,
    signer,
    client,
    rpc.ok(request_id, secret),
    now,
  ))
  #(engine, reply, InsertSession(session: kept, evicted: evicted))
}

/// 承認待ちの接続要求を拒否する。承認済みにはせず、元の `connect` と同じ id の
/// エラー応答イベントを返す。書き込みの値は削除する承認待ちを表す
/// `DeletePending`。
pub fn deny(
  engine: Engine,
  token: String,
  now: Int,
) -> Result(#(Engine, Event, Write), String) {
  use #(engine, entry) <- result.try(take_pending(engine, token, now))
  use reply <- result.map(respond(
    engine,
    entry.signer,
    entry.client,
    rpc.error(entry.request_id, "connection denied"),
    now,
  ))
  #(engine, reply, DeletePending(token))
}

/// 承認待ちを 1 件取り出す。承認も拒否も 1 度きりなので取り出したものは状態から
/// 削除し、ついでに失効した要求もまとめて捨てる。
fn take_pending(
  engine: Engine,
  token: String,
  now: Int,
) -> Result(#(Engine, Pending), String) {
  let live = live_pending(engine, now)
  case dict.get(live, token) {
    Error(_) -> Error(approval_request_not_found)
    Ok(entry) ->
      Ok(#(Engine(..engine, pending: dict.delete(live, token)), entry))
  }
}

/// 失効していない承認待ちだけを残した辞書。表示・承認・登録のどこから見ても、
/// 失効した要求は存在しないものとして扱う。
fn live_pending(engine: Engine, now: Int) -> Dict(String, Pending) {
  dict.filter(engine.pending, fn(_token, entry) { !expired(entry, now) })
}

/// 承認待ちが有効期間を過ぎているかどうか。リクエストの受付ウィンドウと違い、
/// 経過した時間だけを見る片側の判定。
fn expired(entry: Pending, now: Int) -> Bool {
  entry.created_at < now - pending_ttl_seconds
}

/// 応答をクライアント宛の kind 24133 イベントにする。会話鍵は署名者の秘密鍵と
/// クライアント pubkey から導出する。
fn respond(
  engine: Engine,
  signer: String,
  client: String,
  response: rpc.Response,
  now: Int,
) -> Result(Event, String) {
  use #(account, _secret) <- result.try(
    dict.get(engine.accounts, signer)
    |> result.replace_error("no matching account for " <> signer),
  )
  use conversation_key <- result.try(client_conversation_key(account, client))
  build_reply(account, conversation_key, client, response, now)
}

/// 受信イベント 1 件を処理する。受理の判定・重複排除・ルーティングを行い、送信
/// すべき応答があれば生成する。id と署名は受信した接続のプロセスが
/// `event.verify` で確かめてあり、エンジンは検証しない。`engine` は受理した
/// イベントの id、セッションの外のリクエストを数えた上限の状態（`limiter`）、
/// `TouchSession` を書こうとした組の試行の時刻を記録したエンジンで、セッション
/// と承認待ちの変更は `Persist` の `next` に載せる。`notice` にログの 1 行を
/// 入れるのは、権限の不足で拒否したときと、上限を超えて捨てた件数を報告するとき
/// だけである。
pub fn handle_event(
  engine: Engine,
  verified: Verified,
  inputs: Inputs,
) -> Handled {
  let incoming = event.verified_event(verified)
  case accept(engine, incoming, inputs) {
    Error(outcome) ->
      Handled(
        engine: engine,
        outcome: outcome,
        notice: None,
        outside_session: False,
      )
    Ok(#(engine, account, secret)) ->
      handle_request(engine, account, secret, incoming, inputs)
  }
}

/// 受信イベントを受理するかどうかを、kind・受付ウィンドウ・アクターの起点・
/// ルーティング・重複の順に判定する。署名は接続のプロセスで確かめてあるので、
/// `seen` に残るのは署名の正しいイベントの id だけである。受理したイベントの id
/// は記録して返す。
fn accept(
  engine: Engine,
  incoming: Event,
  inputs: Inputs,
) -> Result(#(Engine, Account, ConnectionSecret), Outcome) {
  use <- bool.guard(
    incoming.kind != event.nip46_kind,
    Error(Ignore("not a nip-46 request")),
  )
  use <- bool.guard(
    !fresh(incoming.created_at, inputs.now),
    Error(Ignore("stale or future event")),
  )
  use <- bool.guard(
    incoming.created_at < inputs.not_before,
    Error(Ignore("request predates this bunker instance")),
  )
  use #(account, secret) <- result.try(
    route(engine, incoming.tags) |> result.map_error(Ignore),
  )
  use seen <- result.map(
    window.insert(engine.seen, incoming.id) |> result.replace_error(Duplicate),
  )
  #(Engine(..engine, seen: seen), account, secret)
}

/// タイムスタンプが受付ウィンドウ（過去側 `past_window_seconds`、未来側
/// `future_window_seconds`）の内側かどうか。
fn fresh(created_at: Int, now: Int) -> Bool {
  created_at >= now - past_window_seconds
  && created_at <= now + future_window_seconds
}

/// 既知のアカウントに一致する ["p", pubkey] タグへルーティングする。NIP-46 の
/// リクエストが持つ p タグは通常 1 つだが、複数あっても自分宛のものを選ぶ。
fn route(
  engine: Engine,
  tags: List(List(String)),
) -> Result(#(Account, ConnectionSecret), String) {
  case p_tag_pubkeys(tags) {
    [] -> Error("no p tag")
    pubkeys ->
      list.find_map(pubkeys, dict.get(engine.accounts, _))
      |> result.replace_error(
        "no matching account for " <> string.join(pubkeys, ", "),
      )
  }
}

/// ["p", pubkey] タグの pubkey を、現れた順に取り出す。
pub fn p_tag_pubkeys(tags: List(List(String))) -> List(String) {
  use tag <- list.filter_map(tags)
  case tag {
    ["p", pubkey, ..] -> Ok(pubkey)
    _ -> Error(Nil)
  }
}

/// リクエストを復号・デコードし、セッションの外のリクエストを上限に数えてから
/// （`admit`）実行し、実行結果を暗号化した応答にする。セッションの外かどうか
/// （`outside_session`）は実行の前のエンジンで 1 度だけ判定し、上限と
/// `Handled.outside_session` の両方に使う。上限を超えたリクエストは実行せずに
/// `Throttled` にする。
fn handle_request(
  engine: Engine,
  account: Account,
  secret: ConnectionSecret,
  incoming: Event,
  inputs: Inputs,
) -> Handled {
  let client_pk_hex = incoming.pubkey
  case decode_request(account, incoming) {
    Error(reason) ->
      Handled(
        engine: engine,
        outcome: Ignore(reason),
        notice: None,
        outside_session: False,
      )
    Ok(#(conversation_key, request)) -> {
      let outside =
        outside_session(
          engine,
          pubkey_hex(account),
          secret,
          client_pk_hex,
          request,
        )
      case admit(engine, outside, client_pk_hex, inputs.now) {
        Error(#(limited, report)) ->
          Handled(
            engine: limited,
            outcome: Throttled,
            notice: report,
            outside_session: outside,
          )
        Ok(engine) -> {
          let execution =
            execute(engine, account, secret, client_pk_hex, request, inputs)
          let build = fn(response) {
            build_reply(
              account,
              conversation_key,
              client_pk_hex,
              response,
              inputs.now,
            )
          }
          Handled(
            engine: attempted(engine, execution),
            outcome: outcome(execution, build),
            notice: denial_notice(execution, pubkey_hex(account), client_pk_hex),
            outside_session: outside,
          )
        }
      }
    }
  }
}

/// セッションの外のリクエスト（`outside` が真）を `rate_limit.admit` で
/// 数える。通すなら数えた後のエンジンを、捨てるなら数えた後のエンジンと報告の
/// 1 行を `Error` で返す。セッションの中のリクエストは数えずにそのまま通す。
fn admit(
  engine: Engine,
  outside: Bool,
  client: String,
  now: Int,
) -> Result(Engine, #(Engine, Option(String))) {
  case outside {
    False -> Ok(engine)
    True ->
      case rate_limit.admit(engine.limiter, client, now) {
        rate_limit.Admitted(limiter) -> Ok(Engine(..engine, limiter: limiter))
        rate_limit.Refused(limiter:, report:) ->
          Error(#(Engine(..engine, limiter: limiter), report))
      }
  }
}

/// セッションの外のリクエストか。（署名者, クライアント）の組が承認済みでなく、
/// 接続 secret の一致する `connect` でもなければ真。secret の一致する `connect`
/// を外すのは、上限を使い切られている間も secret を持つ利用者が接続できるように
/// するためである。
fn outside_session(
  engine: Engine,
  signer: String,
  secret: ConnectionSecret,
  client: String,
  request: rpc.Request,
) -> Bool {
  case dict.has_key(engine.sessions, #(signer, client)) {
    True -> False
    False ->
      case request.method {
        "connect" -> !offers_secret(secret, connect_secret(request.params))
        _ -> True
      }
  }
}

/// `connect` が提示した secret（`connect_secret` の値）が接続 secret と一致するか。提示が
/// 無ければ偽。
fn offers_secret(secret: ConnectionSecret, offered: Option(String)) -> Bool {
  case offered {
    Some(value) -> connection_secret.matches(secret, value)
    None -> False
  }
}

/// 書き込みが成功しなかったとき（失敗、または応答を組めず破棄したとき）に続ける
/// エンジン。`TouchSession` を書こうとした実行なら組の試行の時刻を
/// `touch_attempts` に残し、それ以外は `engine` をそのまま返す。
fn attempted(engine: Engine, execution: Execution) -> Engine {
  case execution {
    Record(write: TouchSession(session:), ..) ->
      Engine(
        ..engine,
        touch_attempts: dict.insert(
          engine.touch_attempts,
          #(session.signer, session.client),
          session.last_used_at,
        ),
      )
    _ -> engine
  }
}

/// リクエストの content を復号し、JSON-RPC としてデコードする。同じ会話鍵で応答を
/// 暗号化するため、鍵も一緒に返す。上限を超えたリクエストは `rpc` が理由を返す
/// ので、ここでは応答を組まない。
fn decode_request(
  account: Account,
  incoming: Event,
) -> Result(#(BitArray, rpc.Request), String) {
  use conversation_key <- result.try(client_conversation_key(
    account,
    incoming.pubkey,
  ))
  use plaintext <- result.try(
    nip44.decrypt(incoming.content, conversation_key)
    |> result.replace_error(undecryptable(incoming.content)),
  )
  use request <- result.map(rpc.decode_request(plaintext))
  #(conversation_key, request)
}

/// 復号できなかった content を破棄する理由。NIP-04 のペイロードは形式で見分けが
/// つくため、未対応であることが分かる理由にする。
fn undecryptable(content: String) -> String {
  case string.contains(content, "?iv=") {
    True -> "nip-04 request (unsupported)"
    False -> "undecryptable content"
  }
}

/// クライアントとの会話鍵。署名者の秘密鍵とクライアント pubkey から導出する。
fn client_conversation_key(
  account: Account,
  client_pk_hex: String,
) -> Result(BitArray, String) {
  use client_pk <- result.try(
    hex.decode(client_pk_hex) |> result.replace_error("invalid client pubkey"),
  )
  nip44.conversation_key(privkey(account), client_pk)
  |> result.replace_error("cannot derive conversation key")
}

/// 実行の結果の応答を `build` でイベントにし、Outcome にする。応答を 1 つでも組め
/// なければ送るものが無いので、書き込みごと破棄する。
fn outcome(
  execution: Execution,
  build: fn(rpc.Response) -> Result(Event, String),
) -> Outcome {
  let built = case execution {
    Respond(response) -> build(response) |> result.map(Reply)
    Record(write:, next:, response:, on_failure:) -> {
      use response <- result.try(build(response))
      use on_failure <- result.map(build(on_failure))
      Persist(write:, next:, response:, on_failure:)
    }
  }
  case built {
    Ok(outcome) -> outcome
    Error(reason) -> Ignore(reason)
  }
}

/// リクエストを 1 件実行する。`connect` と `logout` 以外は、クライアントが先に
/// 接続済みであることを条件とする。セッション内のリクエストは `touch` が
/// 最終利用を書く。
///
/// `logout` はセッションの有無によらず ack を返す。NIP-46 は応答を ack と定め、
/// クライアント（nostr-tools の `BunkerSigner`）は ack 以外の応答で購読の後
/// 始末を止めるためである。セッションが無い組では状態を変えない。
fn execute(
  engine: Engine,
  account: Account,
  secret: ConnectionSecret,
  client_pk_hex: String,
  request: rpc.Request,
  inputs: Inputs,
) -> Execution {
  let signer = pubkey_hex(account)
  case request.method {
    "connect" -> connect(engine, signer, secret, client_pk_hex, request, inputs)
    // 承認されていない組の `logout` も、状態を変えずに ack を返す（再起動や
    // 取り消しの後のクライアントを例外にしないため）。
    "logout" -> {
      let ack = rpc.ok(request.id, "ack")
      case revoke(engine, signer, client_pk_hex) {
        // 書けなくても ack を返す（クライアントの後始末を止めないため）。
        Ok(#(next, write)) ->
          Record(write:, next:, response: ack, on_failure: ack)
        Error(Nil) -> Respond(ack)
      }
    }
    _ ->
      case dict.get(engine.sessions, #(signer, client_pk_hex)) {
        Error(Nil) ->
          Respond(rpc.error(request.id, "unauthorized: send connect first"))
        Ok(session) ->
          touch(
            engine,
            session,
            execute_in_session(account, session.perms, request, inputs.now),
            inputs.now,
          )
      }
  }
}

/// セッション内の応答を、最終利用の書き込みを伴う実行にする。最終利用と
/// `touch_attempts` の試行の時刻の新しい方から `last_used_granularity_seconds`
/// 未満なら書き込まずに `Respond`。以上なら `TouchSession` を書き、書けたら
/// `last_used_at` を `now` にし組の試行の時刻を消したエンジンで続け、書けなくても
/// 同じ応答を返す（応答は DB に依存しない）。
fn touch(
  engine: Engine,
  session: Session,
  response: rpc.Response,
  now: Int,
) -> Execution {
  let pair = #(session.signer, session.client)
  let last_attempt = dict.get(engine.touch_attempts, pair) |> result.unwrap(0)
  case
    now - int.max(session.last_used_at, last_attempt)
    < last_used_granularity_seconds
  {
    True -> Respond(response)
    False -> {
      let updated = Session(..session, last_used_at: now)
      let next =
        Engine(
          ..engine,
          sessions: dict.insert(engine.sessions, pair, updated),
          touch_attempts: dict.delete(engine.touch_attempts, pair),
        )
      Record(
        write: TouchSession(session: updated),
        next:,
        response:,
        on_failure: response,
      )
    }
  }
}

/// `connect` を 1 件処理する。`params[0]` が別の署名者を指していれば、状態を
/// 変えずに拒否する。組がすでに承認済みなら、シークレットの一致を問わず状態を
/// 変えずに ack だけ返す（クライアントの再読み込みのたびに承認を求めないため）。
/// 組が無くシークレットが一致すればその場で承認する。どちらでもないときは、
/// 管理 UI が有効なら承認待ちを作って `auth_url` を返し（`pend`）、無効なら拒否する。
fn connect(
  engine: Engine,
  signer: String,
  secret: ConnectionSecret,
  client_pk_hex: String,
  request: rpc.Request,
  inputs: Inputs,
) -> Execution {
  use <- bool.guard(
    points_elsewhere(connect_signer(request.params), signer),
    Respond(rpc.error(request.id, "connect is addressed to another signer")),
  )
  use <- bool.guard(
    dict.has_key(engine.sessions, #(signer, client_pk_hex)),
    Respond(rpc.ok(request.id, "ack")),
  )
  let offered = connect_secret(request.params)
  let perms = connect_perms(request.params)
  case offers_secret(secret, offered), engine.auth_url {
    True, _ -> {
      let session = new_session(signer, client_pk_hex, perms, [], inputs.now)
      let #(next, kept, evicted) = open_session(engine, session)
      Record(
        write: InsertSession(session: kept, evicted:),
        next:,
        response: rpc.ok(request.id, "ack"),
        on_failure: rpc.error(request.id, connection_not_saved),
      )
    }
    False, None -> Respond(rpc.error(request.id, "invalid secret"))
    False, Some(auth_url) ->
      pend(
        engine,
        Pending(
          token: inputs.token,
          signer: signer,
          client: client_pk_hex,
          request_id: request.id,
          perms: perms,
          secret_mismatch: option.is_some(offered),
          created_at: inputs.now,
        ),
        auth_url(inputs.token),
      )
  }
}

/// 承認待ち `entry` を登録し、承認ページの `url` を載せた `auth_url` 応答を返す実行。
fn pend(engine: Engine, entry: Pending, url: String) -> Execution {
  let #(next, write) = record_pending(engine, entry)
  Record(
    write:,
    next:,
    response: rpc.auth_url(entry.request_id, url),
    on_failure: rpc.error(entry.request_id, connection_not_saved),
  )
}

/// （署名者, クライアント）の組を承認済みにする。組がすでにあれば、値（作成時刻
/// と権限）は変えず、何も押し出さない。無ければ、挿入の前の一覧（最終利用の
/// 新しい順）で `session_capacity - 1` 件より後ろの組を押し出してから `session`
/// を入れる。戻り値の第 2 要素は組に残ったセッション（すでにあればその値、
/// 無ければ `session`）で、書き込みの値にする。`insert_session` は同じ組の行を
/// 上書きするので、これで DB の値がメモリと揃う。第 3 要素は押し出した（署名者,
/// クライアント）の組。
fn open_session(
  engine: Engine,
  session: Session,
) -> #(Engine, Session, List(#(String, String))) {
  let key = #(session.signer, session.client)
  case dict.get(engine.sessions, key) {
    Ok(existing) -> #(engine, existing, [])
    Error(Nil) -> {
      let evicted =
        sessions(engine)
        |> list.drop(session_capacity - 1)
        |> list.map(fn(evictee) { #(evictee.signer, evictee.client) })
      let remaining = list.fold(evicted, engine.sessions, dict.delete)
      #(
        Engine(..engine, sessions: dict.insert(remaining, key, session)),
        session,
        evicted,
      )
    }
  }
}

/// `now` に作成したセッション。`last_used_at` は `created_at` と同じ値にする。
/// `relays` は `nostrconnect://` の URI のリレーで、`bunker://` の `connect` と
/// 承認で開くときは空。
fn new_session(
  signer: String,
  client: String,
  perms: String,
  relays: List(String),
  now: Int,
) -> Session {
  Session(
    signer: signer,
    client: client,
    perms: perms,
    created_at: now,
    last_used_at: now,
    relays: relays,
  )
}

/// 承認待ち `entry` を登録する。同じ（署名者, クライアント）の要求と失効した要求を捨て、
/// `pending_capacity` の規則で押し出してから入れる。書き込みの `replaced` は捨てた同じ組の
/// 失効していない token だけで、失効した行は DB に残し `restore` が読み飛ばす。
fn record_pending(engine: Engine, entry: Pending) -> #(Engine, Write) {
  let live = live_pending(engine, entry.created_at)
  let replaced =
    dict.filter(live, fn(_token, existing) {
      existing.signer == entry.signer && existing.client == entry.client
    })
    |> dict.keys
    |> list.sort(string.compare)
  let kept =
    dict.filter(live, fn(_token, existing) {
      existing.signer != entry.signer || existing.client != entry.client
    })
  let #(same_client, others) =
    list.partition(newest_pending(kept), fn(existing) {
      existing.client == entry.client
    })
  let evicted =
    list.append(others, same_client)
    |> list.drop(pending_capacity - 1)
    |> list.map(fn(evictee) { evictee.token })
  let kept = list.fold(evicted, kept, dict.delete)
  let updated = Engine(..engine, pending: dict.insert(kept, entry.token, entry))
  #(updated, InsertPending(pending: entry, replaced:, evicted:))
}

/// 接続済みクライアントからのリクエストを 1 件実行する。方法名を `permission.from_token` で
/// 読み、`sign_event` と `nip44_encrypt` / `nip44_decrypt` は `perms`（空なら既定の集合）が
/// 許すときだけ実行し、`get_public_key` と `ping` は `perms` に関わらず答える。
/// 未対応の方法（`permission.is_unsupported`）には未対応の理由を、ほかの方法には
/// `unsupported_method` を返す。
fn execute_in_session(
  account: Account,
  perms: String,
  request: rpc.Request,
  now: Int,
) -> rpc.Response {
  let granted = permission.parse(perms)
  case request.method {
    "get_public_key" -> rpc.ok(request.id, pubkey_hex(account))
    "ping" -> rpc.ok(request.id, "pong")
    method -> {
      let wanted = permission.from_token(method)
      case wanted {
        permission.SignAnyKind -> sign_event(account, granted, request, now)
        permission.Nip44Encrypt ->
          nip44_op(account, granted, wanted, request, nip44.encrypt)
        permission.Nip44Decrypt ->
          nip44_op(account, granted, wanted, request, nip44.decrypt)
        _ ->
          case permission.is_unsupported(wanted) {
            True -> rpc.error(request.id, "nip04 is not supported")
            False -> rpc.error(request.id, unsupported_method)
          }
      }
    }
  }
}

/// 指定された pubkey（`connect` の署名者、ドラフトの pubkey）が、`signer` とは
/// 別人を指しているかどうか。`None` と空文字列は「指定無し」として扱い、
/// `False` にする。`connect` と `sign_event` の両方の検査が同じ規則を使う。
fn points_elsewhere(target: Option(String), signer: String) -> Bool {
  case target {
    Some(pubkey) -> pubkey != "" && pubkey != signer
    None -> False
  }
}

/// connect リクエストが指す署名者 pubkey。`[secret]` だけを送る古い形式は
/// 指定無しとして扱う。空文字列の扱いは `points_elsewhere` が決める。
fn connect_signer(params: List(String)) -> Option(String) {
  case params {
    [signer, _, ..] -> Some(signer)
    _ -> None
  }
}

/// connect リクエストのシークレット。クライアントは [signer_pk, secret, perms]
/// を送るが、古い実装には [secret] だけを送るものもある。シークレット無しで接続
/// するクライアントは空文字列を送ってくるため、それも「無し」として扱う。
fn connect_secret(params: List(String)) -> Option(String) {
  case params {
    [_signer, secret, ..] | [secret] ->
      case secret {
        "" -> None
        secret -> Some(secret)
      }
    [] -> None
  }
}

/// connect リクエストが要求する権限（`params[2]`）を `max_perms_bytes` で切った
/// 値。無ければ空文字列。
fn connect_perms(params: List(String)) -> String {
  case params {
    [_signer, _secret, perms, ..] -> bounded_perms(perms)
    _ -> ""
  }
}

/// `perms` が `max_perms_bytes` 以下ならそのまま、超えればカンマで分けたトークン
/// を先頭から上限に収まる所まで残す。トークンの途中では切らない
/// （`sign_event:12` を `sign_event:1` にしないため）。先頭のトークンだけで上限を
/// 超える `connect` は空になり、無宣言として扱われる。
fn bounded_perms(perms: String) -> String {
  let #(kept, _) =
    string.split(perms, ",")
    |> list.fold_until(#([], -1), fn(acc, token) {
      let grown = acc.1 + 1 + string.byte_size(token)
      case grown <= max_perms_bytes {
        True -> list.Continue(#([token, ..acc.0], grown))
        False -> list.Stop(acc)
      }
    })
  kept |> list.reverse |> string.join(",")
}

/// 権限が許されていないことを示すエラーの文言の接頭辞。
const denial_prefix = "permission denied: "

/// `wanted` が許されていないことを示すエラーの文言。権限の綴りは `permission.token` で作る。
fn denial(wanted: Permission) -> String {
  denial_prefix <> permission.token(wanted)
}

/// 権限の不足で拒否した実行のログ 1 行。それ以外の結果では `None`。
fn denial_notice(
  execution: Execution,
  signer: String,
  client: String,
) -> Option(String) {
  let response = case execution {
    Respond(response:) -> response
    Record(response:, ..) -> response
  }
  case response.error {
    Some(reason) ->
      case string.starts_with(reason, denial_prefix) {
        True -> {
          let permission =
            string.drop_start(reason, string.length(denial_prefix))
          Some(
            "permission denied for client "
            <> client
            <> " on signer "
            <> signer
            <> ": "
            <> permission,
          )
        }
        False -> None
      }
    None -> None
  }
}

/// 実行の結果を、同じ id の成功応答か失敗応答にする。
fn response_of(id: String, outcome: Result(String, String)) -> rpc.Response {
  case outcome {
    Ok(value) -> rpc.ok(id, value)
    Error(reason) -> rpc.error(id, reason)
  }
}

/// リクエストに含まれるイベントドラフトをアカウントの鍵で署名する。`granted`（セッションの
/// `perms` を `permission.parse` で読んだもの）がドラフトの kind を許すとき
/// （`permission.allows`。空なら常に）署名する。別の pubkey を指すドラフトと、NIP-46 の
/// 応答と同じ kind（24133）のドラフトは、perms で宣言されていても拒否する。空の pubkey は
/// 指定無しとして扱う。
fn sign_event(
  account: Account,
  granted: List(Permission),
  request: rpc.Request,
  now: Int,
) -> rpc.Response {
  response_of(request.id, {
    use draft_json <- result.try(case request.params {
      [draft_json, ..] -> Ok(draft_json)
      [] -> Error("sign_event requires an event draft")
    })
    use draft <- result.try(
      rpc.decode_draft(draft_json)
      |> result.replace_error("invalid event draft"),
    )
    let wanted = permission.SignKind(draft.kind)
    use <- bool.guard(
      !permission.allows(granted, wanted),
      Error(denial(wanted)),
    )
    use <- bool.guard(
      points_elsewhere(draft.pubkey, pubkey_hex(account)),
      Error("event draft pubkey does not match the signer"),
    )
    use <- bool.guard(
      draft.kind == event.nip46_kind,
      Error("refusing to sign a kind 24133 event"),
    )
    sign_as(
      account,
      draft.kind,
      draft.tags,
      draft.content,
      option.unwrap(draft.created_at, now),
    )
    |> result.replace_error("failed to sign event")
    |> result.map(fn(signed) { json.to_string(event.to_json(signed)) })
  })
}

/// 第三者宛のテキストに、アカウントの鍵で `operation`（`nip44.encrypt` か `nip44.decrypt`）
/// をかける。`granted` が `wanted` を許さなければ拒否する。
fn nip44_op(
  account: Account,
  granted: List(Permission),
  wanted: Permission,
  request: rpc.Request,
  operation: fn(String, BitArray) -> Result(String, nip44.Nip44Error),
) -> rpc.Response {
  response_of(request.id, {
    use <- bool.guard(
      !permission.allows(granted, wanted),
      Error(denial(wanted)),
    )
    use #(third_party_hex, text) <- result.try(case request.params {
      [third_party_hex, text, ..] -> Ok(#(third_party_hex, text))
      _ -> Error("nip44 requires [pubkey, text]")
    })
    use third_party <- result.try(
      hex.decode(third_party_hex)
      |> result.replace_error("invalid third-party pubkey"),
    )
    use key <- result.try(
      nip44.conversation_key(privkey(account), third_party)
      |> result.replace_error("invalid third-party pubkey"),
    )
    operation(text, key)
    |> result.replace_error("nip44 operation failed")
  })
}

/// アカウントの鍵で署名したイベント。`id` と `sig` は `event.finalize` が埋める。
pub fn sign_as(
  account: Account,
  kind: Int,
  tags: List(List(String)),
  content: String,
  created_at: Int,
) -> Result(Event, Nil) {
  Event(
    id: "",
    pubkey: pubkey_hex(account),
    created_at:,
    kind:,
    tags:,
    content:,
    sig: "",
  )
  |> event.finalize(privkey(account))
}

/// 応答をクライアント宛に暗号化し、kind 24133 イベントとして署名する。
fn build_reply(
  account: Account,
  conversation_key: BitArray,
  client_pk_hex: String,
  response: rpc.Response,
  now: Int,
) -> Result(Event, String) {
  use content <- result.try(
    nip44.encrypt(rpc.encode_response(response), conversation_key)
    |> result.replace_error("failed to encrypt response"),
  )
  sign_as(account, event.nip46_kind, [["p", client_pk_hex]], content, now)
  |> result.replace_error("failed to sign response")
}
