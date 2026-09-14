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
import nostr_no_su/bunker/rpc
import nostr_no_su/crypto/nip44
import nostr_no_su/dedup/window
import nostr_no_su/hex
import nostr_no_su/nostr/event.{type Event, type Verified, Event}

/// 時計が遅れたクライアントのずれを許容するため、現在時刻からこの秒数より古い
/// リクエストまでを受け付ける。
const past_window_seconds = 600

/// 現在時刻からこの秒数より先の `created_at` を持つリクエストは受け付けない。
/// 起点（`Inputs.not_before`）の保護が効かない時計の進みの上限になるため、過去側
/// より狭くする。
const future_window_seconds = 60

/// 承認待ちの有効期間。承認も拒否もされないまま放置された要求は、これを過ぎたら
/// 無かったものとして扱う。
const pending_ttl_seconds = 600

/// セッション内のリクエストで最終利用を書き込む最小の間隔（秒）。これより短い
/// 間隔のリクエストは書き込みを伴わない。
const last_used_granularity_seconds = 60

/// 承認・拒否しようとした承認待ちが無い（不明、失効、処理済み）ときの理由。管理 UI も、
/// 承認待ちの一覧に無いトークンに同じ理由を出す。
pub const approval_request_not_found = "unknown or expired approval request"

/// `connect` で開くセッションか承認待ちを DB に書けなかったときに、同じ id で
/// クライアントへ返すエラーの理由。書き込みの結果によらず同じ文にし、ストアの
/// 理由は含めない。
pub const connection_not_saved = "could not save the connection; try connecting again"

/// リプレイ防止のために記憶するリクエスト id の件数。
///
/// `accept` は復号も認可も済ませる前に id を記録するため、自分宛の p タグを付けて
/// 署名しただけの kind 24133 であれば、未認可のクライアントからでも 1 件を占める。
/// つまり流入量は運用者の負荷ではなく送信者が決められるもので、署名検証 1 件が
/// ミリ秒単位である以上、受付ウィンドウ（`past_window_seconds` と
/// `future_window_seconds`）の間に容量を超える件数を送り込むことは攻撃者にとって
/// 現実的である。
///
/// 押し出された id のリプレイが通ったときに起こりうることは限られる。応答は元の
/// クライアント宛に NIP-44 で暗号化されるため攻撃者は読めず、`logout` の再送で
/// セッションが切れる、secret 無しの `connect` の再送で承認待ちが再登録される
/// （承認しても認可されるのは元のクライアント）といった範囲にとどまり、鍵や署名が
/// 漏れる経路は無い。この範囲を受容したうえで、記憶領域を確実に有界にすることを
/// 優先して件数のみで区切っている。
const seen_capacity = 16_384

/// 承認済みセッションの件数の上限（全署名者で 1 つ）。新しいセッションを開くと、
/// 最終利用の古い順（`sessions` の並びの末尾）に押し出す。
pub const session_capacity = 32

/// 承認待ちの件数の上限（全署名者で 1 つ）。新しい承認待ちを登録すると、作成の
/// 古い順（`pending` の並びの末尾）に押し出す。
pub const pending_capacity = 16

/// バンカーが持つ状態のすべて。プロセスも時計も持たない純粋な値で、`bunker` の
/// アクターがこれを保持して受信のたびに更新する。
pub type Engine {
  Engine(
    // 署名者 pubkey hex -> #(account, 閉じ込めた接続 secret)
    accounts: Dict(String, #(Account, ConnectionSecret)),
    // #(署名者, クライアント) -> Session
    sessions: Dict(#(String, String), Session),
    // リプレイ防止用: 処理済みのリクエストイベント id
    seen: window.Window,
    // 承認待ちの接続要求: token -> Pending
    pending: Dict(String, Pending),
    // token から承認ページの URL を組み立てる関数。None なら承認フローを使わない。
    auth_url: Option(fn(String) -> String),
    // #(署名者, クライアント) -> 最終利用の書き込みを最後に試みた時刻。書けなかった
    // 間も `touch` の間引きに使う。
    touch_attempts: Dict(#(String, String), Int),
  )
}

/// 受信イベント 1 件を処理する間に、外から注入する値。時刻も乱数もエンジンの外で
/// 決めることで、エンジンは純粋なまま保たれる。`token` は承認待ちを作るときだけ
/// 使う。
///
/// `not_before` はこのバンカーを動かしているアクターが起動した時刻で、これより
/// 古いリクエストは受け付けない。リプレイ防止の `seen` はアクターの寿命に閉じて
/// いるため、アクターが再起動すると、それ以前に処理したリクエストを新規として
/// 実行してしまう（kind 24133 を保存するリレーは再購読で再配送する）。起点を
/// 設けることで、記憶していないリクエストは実行せずに捨てる。
///
/// `created_at` は秒までしか持たないため、判定は起動した秒より前かどうかで行い、
/// 起動と同じ秒のリクエストは通す。起動直後に届いた正当なリクエストを落とすと、
/// クライアントは応答を待ったまま失敗する。再起動が同じ秒に収まった場合は、その秒
/// のリクエストが再実行されうる。これは判定の粒度による残りである。
///
/// 判定に使うのはクライアントが自己申告する `created_at` なので、時計が進んでいる
/// クライアントには保護が効かない。ずれが D 秒あると、リレーがそのリクエストを
/// 再配送しうるのは送信から「D + 購読の猶予」の間で、そのうち最初の D 秒に入った
/// 再起動では、アクターの起点がリクエストの `created_at` に届かず落とせない（D の
/// 上限は受付ウィンドウの未来側 `future_window_seconds`）。逆に時計が遅れている
/// クライアントのリクエストは、アクターの起動直後、そのずれの秒数ぶんだけ弾かれうる。
pub type Inputs {
  Inputs(now: Int, token: String, not_before: Int)
}

/// 承認待ちの接続要求 1 件。`token` は承認ページの URL に入る値で、辞書の鍵と
/// 同じものを持つ（一覧に出すときに鍵を持ち回らずに済む）。`request_id` は承認後
/// の応答を元の `connect` と同じ id で返すために覚えておく。`perms` は `connect` の
/// `params[2]`（無ければ空文字列）、`secret_mismatch` は空でない secret が一致
/// しなかったかどうかを表す。`pending_capacity` を超えると作成の古い順に押し出さ
/// れる。
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
/// 経っていれば更新する。
pub type Session {
  Session(
    signer: String,
    client: String,
    perms: String,
    created_at: Int,
    last_used_at: Int,
  )
}

/// 状態の変更に伴う DB への書き込み 1 件。変種は `account_store` の書き込みの
/// 関数に 1 対 1 で対応する。
pub type Write {
  /// `insert_session_evicting`。`evicted` は押し出す（署名者, クライアント）の組。
  InsertSession(session: Session, evicted: List(#(String, String)))
  /// `delete_session`。
  DeleteSession(signer: String, client: String)
  /// `touch_session`。組の最終利用を `last_used_at` に進める。
  TouchSession(signer: String, client: String, last_used_at: Int)
  /// 同じ組の古い承認待ち `replaced` と、`pending_capacity` で押し出す承認待ち
  /// `evicted` を `delete_pending` で消し、`insert_pending` で登録する
  /// （`insert_pending_replacing`）。
  InsertPending(pending: Pending, replaced: List(String), evicted: List(String))
  /// `delete_pending`（拒否）。
  DeletePending(token: String)
  /// `approve`（承認待ちの削除とセッションの挿入、押し出しの削除を 1
  /// トランザクションで）。組がすでに承認済みでも `session` は承認の時刻と
  /// 承認待ちの `perms` を持つ。`insert_session` は `ON CONFLICT DO NOTHING`
  /// なので、DB でも最初に開いたときの値が残り、メモリの値（`open_session`
  /// 参照）と揃う。`evicted` は `InsertSession` と同じ、押し出す組。
  ApprovePending(
    token: String,
    session: Session,
    evicted: List(#(String, String)),
  )
}

/// 受信イベント 1 件を処理した結果。
pub type Outcome {
  /// クライアントへ送り返す応答イベント。
  Reply(response: Event)
  /// DB への書き込みが要る応答。書けたら `response` を送って `next` で続け、
  /// 書けなかったら `on_failure` を送って `handle_event` の第 1 要素で続ける。
  Persist(write: Write, next: Engine, response: Event, on_failure: Event)
  /// 処理済みのリクエスト。2 つ目のバンカーリレーから同じものが届いた場合など。
  /// 複数リレー構成では想定内なので、呼び出し側はログを出さない。
  Duplicate
  /// リクエストを破棄した。ログに出す理由を伴う。
  Ignore(reason: String)
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

/// 署名者として登録されているか。変更の前の所属の検査に使う。
pub fn has_account(engine: Engine, signer: String) -> Bool {
  dict.has_key(engine.accounts, signer)
}

/// 署名者の公開鍵の一覧（昇順）。購読の #p と、署名者の集合の比較に使う。
pub fn signers(engine: Engine) -> List(String) {
  dict.keys(engine.accounts)
  |> list.sort(string.compare)
}

/// 登録済みのアカウントと接続 secret（署名者の昇順）。閉じ込めた secret を
/// 開くのはここだけで、管理 UI への一覧に使う。
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

/// 失効していない承認待ちの一覧。表示が安定し、押し出される要求が末尾に来るよう、
/// 作成の新しい順、token の昇順に並べる。失効した要求は状態からすぐに消えるわけ
/// ではないが、この一覧にも `approve` / `deny` にも現れず、次の登録か成功した
/// 承認・拒否のときにまとめて捨てられる。
pub fn pending(engine: Engine, now: Int) -> List(Pending) {
  live_pending(engine, now) |> newest_pending
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
/// `accounts`、`seen`、`auth_url` は変えない。DB が正なので既存の値には足さず
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
  let session = new_session(entry.signer, entry.client, entry.perms, now)
  let #(engine, evicted) = open_session(engine, session)
  use #(engine, reply) <- result.map(respond(
    engine,
    entry,
    rpc.ok(entry.request_id, "ack"),
    now,
  ))
  #(
    engine,
    reply,
    ApprovePending(token: token, session: session, evicted: evicted),
  )
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
  use #(engine, reply) <- result.map(respond(
    engine,
    entry,
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

/// 承認・拒否の結果を、待たせているクライアント宛の応答イベントにする。会話鍵は
/// 署名者の秘密鍵とクライアント pubkey から導出し直す。
fn respond(
  engine: Engine,
  entry: Pending,
  response: rpc.Response,
  now: Int,
) -> Result(#(Engine, Event), String) {
  use #(account, _secret) <- result.try(
    dict.get(engine.accounts, entry.signer)
    |> result.replace_error("no matching account for " <> entry.signer),
  )
  use conversation_key <- result.try(client_conversation_key(
    account,
    entry.client,
  ))
  use reply <- result.map(build_reply(
    account,
    conversation_key,
    entry.client,
    response,
    now,
  ))
  #(engine, reply)
}

/// 受信イベント 1 件を処理する。受理の判定・重複排除・ルーティングを行い、送信
/// すべき応答があれば生成する。id と署名は受信した接続のプロセスが
/// `event.verify` で確かめてあり、エンジンは検証しない。第 1 要素は受理した
/// イベントの id と、`TouchSession` を書こうとした組の試行の時刻を記録した
/// エンジンで、セッションと承認待ちの変更は `Persist` の `next` に載せる。
pub fn handle_event(
  engine: Engine,
  verified: Verified,
  inputs: Inputs,
) -> #(Engine, Outcome) {
  let incoming = event.verified_event(verified)
  case accept(engine, incoming, inputs) {
    Error(outcome) -> #(engine, outcome)
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

/// リクエストを復号・デコードし、実行結果を暗号化した応答にする。
fn handle_request(
  engine: Engine,
  account: Account,
  secret: ConnectionSecret,
  incoming: Event,
  inputs: Inputs,
) -> #(Engine, Outcome) {
  let client_pk_hex = incoming.pubkey
  case decode_request(account, incoming) {
    Error(reason) -> #(engine, Ignore(reason))
    Ok(#(conversation_key, request)) -> {
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
      #(attempted(engine, execution), outcome(execution, build))
    }
  }
}

/// 書き込みが成功しなかったとき（失敗、または応答を組めず破棄したとき）に続ける
/// エンジン。`TouchSession` を書こうとした実行なら組の試行の時刻を
/// `touch_attempts` に残し、それ以外は `engine` をそのまま返す。
fn attempted(engine: Engine, execution: Execution) -> Engine {
  case execution {
    Record(write: TouchSession(signer:, client:, last_used_at:), ..) ->
      Engine(
        ..engine,
        touch_attempts: dict.insert(
          engine.touch_attempts,
          #(signer, client),
          last_used_at,
        ),
      )
    _ -> engine
  }
}

/// リクエストの content を復号し、JSON-RPC としてデコードする。同じ会話鍵で応答を
/// 暗号化するため、鍵も一緒に返す。
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
  use request <- result.map(
    rpc.decode_request(plaintext)
    |> result.replace_error("malformed request payload"),
  )
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
            execute_in_session(account, request, inputs.now),
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
      let next =
        Engine(
          ..engine,
          sessions: dict.insert(
            engine.sessions,
            pair,
            Session(..session, last_used_at: now),
          ),
          touch_attempts: dict.delete(engine.touch_attempts, pair),
        )
      Record(
        write: TouchSession(
          signer: session.signer,
          client: session.client,
          last_used_at: now,
        ),
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
/// 管理 UI が有効なら承認待ちを作って `auth_url` を返し、無効なら従来どおり
/// 拒否する。
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
  let pair = #(signer, client_pk_hex)
  case dict.has_key(engine.sessions, pair) {
    True -> Respond(rpc.ok(request.id, "ack"))
    False -> {
      let offered = connect_secret(request.params)
      let perms = connect_perms(request.params)
      let offered_matches = case offered {
        Some(value) -> connection_secret.matches(secret, value)
        None -> False
      }
      let not_saved = rpc.error(request.id, connection_not_saved)
      case offered_matches {
        True -> {
          let session = new_session(signer, client_pk_hex, perms, inputs.now)
          let #(next, evicted) = open_session(engine, session)
          Record(
            write: InsertSession(session:, evicted:),
            next:,
            response: rpc.ok(request.id, "ack"),
            on_failure: not_saved,
          )
        }
        False ->
          case engine.auth_url {
            None -> Respond(rpc.error(request.id, "invalid secret"))
            Some(auth_url) -> {
              let #(next, write) =
                record_pending(
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
                )
              Record(
                write:,
                next:,
                response: rpc.auth_url(request.id, auth_url(inputs.token)),
                on_failure: not_saved,
              )
            }
          }
      }
    }
  }
}

/// （署名者, クライアント）の組を承認済みにする。組がすでにあれば、値（作成時刻
/// と権限）は変えずそのまま返し、何も押し出さない（DB の `ON CONFLICT DO
/// NOTHING` と揃える）。無ければ、挿入の前の一覧（最終利用の新しい順）で
/// `session_capacity - 1` 件より後ろの組を押し出してから新しい組を入れる。
/// 戻り値の第 2 要素は押し出した（署名者, クライアント）の組。
fn open_session(
  engine: Engine,
  session: Session,
) -> #(Engine, List(#(String, String))) {
  let key = #(session.signer, session.client)
  case dict.has_key(engine.sessions, key) {
    True -> #(engine, [])
    False -> {
      let evicted =
        sessions(engine)
        |> list.drop(session_capacity - 1)
        |> list.map(fn(evictee) { #(evictee.signer, evictee.client) })
      let kept = list.fold(evicted, engine.sessions, dict.delete)
      #(Engine(..engine, sessions: dict.insert(kept, key, session)), evicted)
    }
  }
}

/// `now` に作成したセッション。`last_used_at` は `created_at` と同じ値にする
/// （`insert_session` と揃える）。
fn new_session(
  signer: String,
  client: String,
  perms: String,
  now: Int,
) -> Session {
  Session(
    signer: signer,
    client: client,
    perms: perms,
    created_at: now,
    last_used_at: now,
  )
}

/// 承認待ちを 1 件登録する。同じ（署名者, クライアント）の古い要求と、失効した
/// 要求は同時に捨てる。承認前にクライアントが再読み込みすると `connect` が届き
/// 直すため、最新の要求だけを残さないと、承認の応答が誰も待っていないリクエスト
/// id で送られてしまう。失効の基準になる現在時刻は、いま作った要求の作成時刻が
/// そのまま使える。書き込みの `replaced` には、消える同じ組の失効していない
/// token だけを載せる（失効した要求の削除は書き込みに出さない。DB に残った
/// 失効行は `restore` が読み飛ばす）。同じ組と失効した要求を除いた後の一覧
/// （作成の新しい順）で `pending_capacity - 1` 件より後ろの要求を押し出し、その
/// token を `evicted` に載せる。
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
  let evicted =
    newest_pending(kept)
    |> list.drop(pending_capacity - 1)
    |> list.map(fn(evictee) { evictee.token })
  let kept = list.fold(evicted, kept, dict.delete)
  let updated = Engine(..engine, pending: dict.insert(kept, entry.token, entry))
  #(updated, InsertPending(pending: entry, replaced:, evicted:))
}

/// 接続済みクライアントからのリクエストを 1 件実行する。
fn execute_in_session(
  account: Account,
  request: rpc.Request,
  now: Int,
) -> rpc.Response {
  case request.method {
    "get_public_key" -> rpc.ok(request.id, pubkey_hex(account))
    "ping" -> rpc.ok(request.id, "pong")
    "sign_event" -> sign_event(account, request, now)
    "nip44_encrypt" -> nip44_op(account, request, True)
    "nip44_decrypt" -> nip44_op(account, request, False)
    "nip04_encrypt" | "nip04_decrypt" ->
      rpc.error(request.id, "nip04 is not supported")
    method -> rpc.error(request.id, "unsupported method: " <> method)
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

/// connect リクエストが要求する権限（`params[2]`）。無ければ空文字列。
fn connect_perms(params: List(String)) -> String {
  case params {
    [_signer, _secret, perms, ..] -> perms
    _ -> ""
  }
}

/// リクエストに含まれるイベントドラフトをアカウントの鍵で署名する。
fn sign_event(
  account: Account,
  request: rpc.Request,
  now: Int,
) -> rpc.Response {
  case request.params {
    [draft_json, ..] -> {
      let signed = {
        use draft <- result.try(
          rpc.decode_draft(draft_json)
          |> result.replace_error("invalid event draft"),
        )
        use unsigned <- result.try(unsigned_event(
          draft,
          pubkey_hex(account),
          now,
        ))
        event.finalize(unsigned, privkey(account))
        |> result.replace_error("failed to sign event")
      }
      case signed {
        Ok(signed) -> rpc.ok(request.id, json.to_string(event.to_json(signed)))
        Error(reason) -> rpc.error(request.id, reason)
      }
    }
    [] -> rpc.error(request.id, "sign_event requires an event draft")
  }
}

/// ドラフトを署名者の未署名イベントにする。別の pubkey を指すドラフトと、
/// NIP-46 の応答と同じ kind（24133）のドラフトは拒否する。空の pubkey は
/// 指定無しとして扱う。
fn unsigned_event(
  draft: rpc.EventDraft,
  signer: String,
  now: Int,
) -> Result(Event, String) {
  use <- bool.guard(
    points_elsewhere(draft.pubkey, signer),
    Error("event draft pubkey does not match the signer"),
  )
  use <- bool.guard(
    draft.kind == event.nip46_kind,
    Error("refusing to sign a kind 24133 event"),
  )
  Ok(Event(
    id: "",
    pubkey: signer,
    created_at: option.unwrap(draft.created_at, now),
    kind: draft.kind,
    tags: draft.tags,
    content: draft.content,
    sig: "",
  ))
}

/// 第三者宛のテキストをアカウントの鍵で暗号化または復号する。
fn nip44_op(
  account: Account,
  request: rpc.Request,
  encrypting: Bool,
) -> rpc.Response {
  case request.params {
    [third_party_hex, text, ..] ->
      case hex.decode(third_party_hex) {
        Error(_) -> rpc.error(request.id, "invalid third-party pubkey")
        Ok(third_party) ->
          case nip44.conversation_key(privkey(account), third_party) {
            Error(_) -> rpc.error(request.id, "invalid third-party pubkey")
            Ok(key) -> {
              let outcome = case encrypting {
                True -> nip44.encrypt(text, key)
                False -> nip44.decrypt(text, key)
              }
              case outcome {
                Ok(result) -> rpc.ok(request.id, result)
                Error(_) -> rpc.error(request.id, "nip44 operation failed")
              }
            }
          }
      }
    _ -> rpc.error(request.id, "nip44 requires [pubkey, text]")
  }
}

/// 応答をクライアント宛に暗号化し、kind 24133 イベントとして署名する。
fn build_reply(
  account: Account,
  conversation_key: BitArray,
  client_pk_hex: String,
  response: rpc.Response,
  now: Int,
) -> Result(Event, String) {
  case nip44.encrypt(rpc.encode_response(response), conversation_key) {
    Error(_) -> Error("failed to encrypt response")
    Ok(content) -> {
      let unsigned =
        Event(
          id: "",
          pubkey: pubkey_hex(account),
          created_at: now,
          kind: event.nip46_kind,
          tags: [["p", client_pk_hex]],
          content: content,
          sig: "",
        )
      case event.finalize(unsigned, privkey(account)) {
        Ok(signed) -> Ok(signed)
        Error(_) -> Error("failed to sign response")
      }
    }
  }
}
