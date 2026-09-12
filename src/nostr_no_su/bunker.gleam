//// 純粋な `engine` を包む薄いアクター。リレーの再接続をまたいでセッション状態を
//// 保持する（リレークライアントは切断のたびに再起動されるため、そこにセッション
//// 状態を置けない）。判断ロジックはすべて `engine` 側に残す。
////
//// アカウントは起動時にストアから読み込む。読み込みは initialiser が自分宛に
//// 積むメッセージ（`LoadAccounts`）で行い、initialiser 自身は DB に触らない。DB が
//// 応答しなくても初期化のタイムアウトに当たらず、サブツリーの起動は失敗しない。
//// 読み込みに失敗したら理由をログに出して再試行を予約するだけで、アクターは
//// 落ちない。再試行の待ち時間は失敗のたびに倍にし、上限で頭打ちにする
//// （`RetryDelay`）。待ち時間は読み込めていない状態（`Loading`）だけが持つので、
//// 読み込みに成功した後の失敗は初期値から数え直す。
////
//// **読み込みの順序に関する不変条件**：`LoadAccounts` は initialiser が送るので、
//// アクターのメールボックスで必ず最初のメッセージになる。接続は `rest_for_one` で
//// アクターの後に起動するので、接続が購読のために送る `GetSigners` は必ずその後に
//// 処理される。DB が起動時に到達可能なら、どの接続も読み込み済みの署名者で購読
//// する。**`LoadAccounts` の最初の送信を initialiser 以外へ移さないこと。**
////
//// 読み込んだアカウントは、メモリの署名者と突き合わせて合わせる（`reconcile`）。
//// ストアに無い署名者を取り除き、読み込んだアカウントを足すか置き換えるので、ストアに
//// 残っている署名者のセッションと承認待ちは残る。起動時の読み込みではメモリが空なので、
//// 読み込んだアカウントをそのまま足すことになる。
////
//// **アカウントの変更**（追加、削除、secret の作り直し、ラベルの差し替え）は、
//// アクターの中でストアへ書き込み、書き込みが成功したときだけメモリの状態を変える。
//// 書き込まれていないことが確定した失敗では、メモリを変えずに理由を返す。書き込みが
//// 期限を過ぎたときや途中で接続が切れたときは、サーバー側でまだ実行中か、すでに
//// コミットされていることがあるので、メモリを変えずにストアから読み直して合わせ、
//// 呼び出し側には反映されたかもしれない旨を返す（`change_may_have_been_applied`）。
//// ストアの読み込みは、実行中の書き込みの終了をテーブルのロックで待ってから読む
//// （`account_store.load`）。読み直しは起動時の読み込みと同じ `LoadAccounts` の経路で
//// 行い、失敗すれば同じく名前なしの subject へ再試行を予約する。読み直しが成功する
//// までの間はメモリが DB と食い違っていることがあり、その間の変更は起動時の読み込みの
//// 前と同じく `accounts are not loaded yet` で拒否し、一覧は理由を返す。NIP-46 の処理は
//// その間もメモリのアカウントで続ける。
////
//// 保証するのは次のことである。メモリは、成功した書き込みと成功した読み込みの結果
//// だけで変わる。結果が曖昧な書き込みの後は、読み直しに成功した時点で、その書き込みの
//// 結果を含めて DB と一致する。例外は、書き込みの文がサーバーに届いてテーブルのロックを
//// 取るより先に読み直しがロックを取った場合（`account_store.load` の「残る窓」）で、その
//// 書き込みは読み直しに見えず、メモリは次の読み込みまで DB より遅れる。この場合も、
//// 追加はもう一度追加すれば、ストアが登録済みを返したときに応答の前に読み直すので
//// 一致し、secret の作り直しはもう一度作り直せば一致する。読み込みで飛ばされる行
//// （別のマスターキーで暗号化されているなど）の公開鍵の追加は、読み直してもメモリに
//// 入らず、登録済みとして拒否される。その行は DB から直接消す必要がある。
////
//// **待ち**：書き込みと読み込みの間は NIP-46 の処理が待たされる（届いたリクエストは
//// メールボックスに積まれて捨てられない）。書き込み 1 件は最長で約 3 秒（DB に到達
//// できないときのチェックアウトの失敗）、読み込み 1 回は読み込みの期限の 3 秒で打ち
//// 切る。DB を一時停止した測定では、読み込みは 3000ms、2950ms、2000ms で失敗して返った。
//// 結果が曖昧な書き込みの後に読み直しが失敗し続けると、再試行のたびに最長 3 秒ずつ
//// 待ちが生じ、読み直しが成功するまで続く。変更でアクターは再起動しないので、
//// 承認済みセッションは残る。
////
//// 状態の遷移はすべて `transition` を通し、署名者の集合が変わったときだけ購読の
//// 張り直しを依頼する。追加と削除のほか、読み込みの失敗からの復帰でも張り直しが
//// 起き、secret やラベルの差し替えでは起きない。メモリはこのアクター経由の変更
//// だけで変わるので、DB の行を外から直接変えた場合は次の起動まで反映されない。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine.{type Pending, type Session}
import nostr_no_su/bunker/vault
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event, type Verified}
import nostr_no_su/random
import nostr_no_su/time

/// バンカーが出すログ行の接頭辞。
pub const log_prefix = "bunker"

/// 本番の読み込みの再試行の待ち時間。5 秒から倍に延ばし、2 分で頭打ちにする。読み込み
/// 1 回は DB に到達できないとき最長 3 秒ループを止めるので、DB が長く止まっている間の
/// 試行の回数を抑える。
pub const default_retry_delay = RetryDelay(initial_ms: 5000, max_ms: 120_000)

/// 問い合わせの応答を待つ時間。アクターの処理はどれも数ミリ秒で終わるため、
/// これを超えるのはアクターが詰まっているときだけ。アカウントの読み込みは最長で
/// 3 秒ループを止めうる（`account_store.default_timeouts`）が、この値に収まる。
const call_timeout_ms = 5000

/// アカウントの変更の応答を待つ時間。書き込み 1 件がループを止めるのは最長で約
/// 3 秒（DB に到達できないときのチェックアウトの失敗）で、読み込み 1 回は期限の
/// 3 秒で打ち切られる。結果が曖昧な変更の後は読み直し（最長 3 秒）が続き、その間に
/// 届いた変更は読み直しの後にストアを呼ばずに拒否される。登録済みの行への追加は、
/// 書き込みの失敗の後に続けて読み直す（最長で約 3 + 3 秒）。したがって、先に積まれた
/// 変更 1 件の書き込みと読み直し（約 6 秒）の後に自分の変更が拒否される場合も、先に
/// 積まれた書き込み 1 件（約 3 秒）の後に自分の変更が書き込みと読み直しを行う場合
/// （約 9 秒）も、この値に収まる。
const change_timeout_ms = 10_000

/// 初期化に許す時間。initialiser は DB に触らないので短くてよい。
const init_timeout_ms = 1000

/// 承認ページの URL に入るトークンのバイト数。承認・拒否そのものは管理 UI の
/// 認証が守るが、トークンは保留の識別子なので、認証を通った管理者が別の要求を
/// 取り違えないよう推測できない長さにする。
const token_bytes = 16

/// 接続 secret のバイト数。secret は `bunker://` URI で署名を委任する資格なので、
/// 推測できない長さにする。
const connection_secret_bytes = 16

/// 変更がアクターの応答を得られなかったときの理由。タイムアウトした後にアクターが
/// 書き込みを終えて反映することがあるので、確かめ直すよう促す。変更の失敗のページは
/// POST の応答で、再読み込みは変更の再送になるため、ダッシュボードで確かめるよう促す。
const change_not_answered = "the bunker did not respond; check the dashboard to see whether the change was applied"

/// 書き込みの結果が曖昧だった変更の理由。コミットされていることがあるので、単なる
/// 失敗としては見せず、ストアから読み直した一覧で確かめるよう促す。管理 UI はこの
/// 文言をそのまま表示してよい。POST の応答のページに出るので、再読み込み（変更の
/// 再送）ではなくダッシュボードを開くよう促す。
pub const change_may_have_been_applied = "the store did not confirm the change; it may have been applied, so open the dashboard to check"

/// 読み込みか読み直しが終わっていないときの理由。
const accounts_not_loaded = "accounts are not loaded yet"

/// 署名者がメモリに無いときの理由。
const account_not_registered = "account is not registered"

/// 公開鍵がすでに登録されているときの理由。
const account_already_registered = "account is already registered"

/// 問い合わせに応答が無いときの理由。
const query_not_answered = "bunker is not responding"

/// アカウントの変更が成功しなかった理由。理由は値（鍵、secret、ラベル）を含まない
/// 固定の英文。管理 UI は型で応答を分け、理由は本文に出すだけにする。
pub type ChangeFailure {
  /// 変更は反映されていない（登録済み、未登録、書き込まれていないことが確定した
  /// ストアの失敗）。
  NotApplied(reason: String)
  /// 変更を受け付けられる状態に無い（読み込み前、結果が曖昧な書き込みの後の読み直しの
  /// 前）。時間をおけば同じ変更を受け付けうる。
  NotReady(reason: String)
  /// 反映されたかどうか分からない（書き込みの期限切れや途中の切断、DB のクライアントの
  /// 例外、アクターが期限内に応答しない）。
  MaybeApplied(reason: String)
}

/// ストアへの書き込みの失敗。理由は値（鍵、secret、ラベル）を含まない固定の文言。
pub type WriteFailure {
  /// 書き込まれていないことが確定している（接続を得られない、制約違反など）。
  NotWritten(reason: String)
  /// 追加しようとした公開鍵の行が、すでに DB にある。バンカーはメモリに無い公開鍵
  /// にだけ追加を書き込むので、DB がメモリより先行している（読み直しに見えなかった
  /// 書き込みがある）か、読み込みで飛ばされた行（別のマスターキーで暗号化されている
  /// など）がある。この追加は書き込まれていない。
  AlreadyStored(reason: String)
  /// 書き込まれたかどうか分からない（期限切れ、途中の切断、DB のクライアントの例外）。
  MaybeWritten(reason: String)
}

/// アカウントストアの操作。起動処理がプールとマスターキーを閉じ込めて渡すので、
/// アクターの状態を表示してもキーが出ず、テストは DB なしで偽の操作を渡せる。
/// 失敗の理由は値（鍵、secret、ラベル）を含まない固定の文言。
pub type Store {
  Store(
    /// アカウントを読み込む。
    load: fn() -> Result(vault.Loaded, String),
    /// アカウントを 1 件追加する。
    insert: fn(vault.StoredAccount) -> Result(Nil, WriteFailure),
    /// 署名者を削除する。登録されていなければ成功として `Ok(Nil)` を返す（削除は
    /// 行が無い状態にすることが目的のため）。
    delete: fn(String) -> Result(Nil, WriteFailure),
    /// 署名者の接続 secret を差し替える。
    update_secret: fn(String, String) -> Result(Nil, WriteFailure),
    /// 署名者のラベルを差し替える。
    update_label: fn(String, String) -> Result(Nil, WriteFailure),
  )
}

/// 読み込みに失敗したときの再試行の待ち時間。最初の失敗の後は `initial_ms` 待ち、
/// 失敗が続くたびに倍にして `max_ms` で頭打ちにする。
pub type RetryDelay {
  RetryDelay(initial_ms: Int, max_ms: Int)
}

/// バンカーアクターの設定。設定から決まるものだけを持つ。購読の張り直しの宛先は
/// ツリーを組む側しか知らないので、ここには入れず `start` の引数で受け取る。
pub type Settings {
  Settings(
    /// アカウントストアの操作。
    store: Store,
    /// 承認ページの URL を組み立てる関数。`None` なら承認フローを使わない。
    auth_url: Option(fn(String) -> String),
    /// 読み込みに失敗したときの再試行の待ち時間。
    retry_delay: RetryDelay,
  )
}

/// 管理 UI に渡すアカウント 1 件。秘密鍵（`Account`）を持たない。secret を含むので
/// 認証済みページ以外に出さない。`npub` は画面でアカウントを識別するための表記。
pub type Listing {
  Listing(signer: String, npub: String, label: String, secret: String)
}

/// バンカーアクターが受け取るメッセージ。
pub type Msg {
  /// バンカー接続のいずれかで受信したイベント。id と署名は接続のプロセスで
  /// 確かめてある。
  Incoming(event: Verified)
  /// 1 本のリレー接続で応答イベントを送信するための関数を登録する。各接続
  /// アクターは再接続のたびに `on_connect` からこれを送り直すため、応答は生きた
  /// ソケットから出ていく。応答はすべてのバンカーリレーへ送信する。クライアント
  /// は URI の `relay=` ヒントすべてを待ち受けており、重複配信の排除はクライアント
  /// 側の責務（こちら側の重複は `engine` が排除する）なので、生きたリレーが 1 つ
  /// あれば往復は成立する。
  SetPublisher(relay_url: String, publish: fn(Event) -> Nil)
  /// 1 本のリレー接続の送信手段を取り下げる。接続アクターが `on_disconnect` から
  /// 送るため、死んだソケットへ応答を渡し続けることがない。接続アクター自身が
  /// クラッシュした場合は `on_disconnect` を経ないため、再起動した接続が
  /// `SetPublisher` で上書きするまでは古い送信手段が残る。
  RemovePublisher(relay_url: String)
  /// 承認済みセッションの一覧を問い合わせる。
  GetSessions(reply: Subject(List(Session)))
  /// セッションを 1 件取り消す（`logout` 相当）。取り消し後の画面が古い一覧を
  /// 読まないよう、完了を待てるように応答する。
  Revoke(signer: String, client: String, reply: Subject(Nil))
  /// 承認待ちの接続要求の一覧を問い合わせる。
  GetPending(reply: Subject(List(Pending)))
  /// 承認待ちの接続要求を承認する。承認を状態に反映し、登録済みの接続へ応答
  /// イベントを送る。要求が見つからなければ理由を返す。
  Approve(token: String, reply: Subject(Result(Nil, String)))
  /// 承認待ちの接続要求を拒否する。
  Deny(token: String, reply: Subject(Result(Nil, String)))
  /// ストアからアカウントを読み込む。initialiser と再試行のタイマーが、アクター
  /// ごとに作る名前なしの subject へ送る。名前付き subject へは誰も送らない。
  LoadAccounts
  /// 現在の署名者 pubkey の一覧を問い合わせる。バンカーリレーの購読が使う。
  GetSigners(reply: Subject(List(String)))
  /// アカウントを追加する。secret はアクターが生成する。
  AddAccount(
    account: Account,
    label: String,
    reply: Subject(Result(Nil, ChangeFailure)),
  )
  /// アカウントを削除する。その署名者のセッションと承認待ちも消える。
  RemoveAccount(signer: String, reply: Subject(Result(Nil, ChangeFailure)))
  /// 接続 secret を作り直す。承認済みセッションは残る。
  RotateSecret(signer: String, reply: Subject(Result(Nil, ChangeFailure)))
  /// ラベルを差し替える。
  UpdateLabel(
    signer: String,
    label: String,
    reply: Subject(Result(Nil, ChangeFailure)),
  )
  /// 管理 UI に出すアカウントの一覧を問い合わせる。
  GetAccounts(reply: Subject(Result(List(Listing), String)))
  /// 署名者の秘密鍵を nsec の文字列で問い合わせる。管理 UI の再表示だけが使う。
  /// 要求は公開鍵と返信先しか持たないので、処理の途中で落ちてもクラッシュレポートに
  /// 秘密は出ない。
  GetNsec(signer: String, reply: Subject(Result(String, String)))
}

/// バンカーが保持する承認済みセッションの一覧。アクターが動いていなければ空。
pub fn sessions(name: Name(Msg)) -> List(Session) {
  named.call(name, call_timeout_ms, GetSessions)
  |> option.unwrap([])
}

/// セッションを 1 件取り消し、反映されるまで待つ。アクターが動いていなければ
/// 何もしない。
pub fn revoke(name: Name(Msg), signer: String, client: String) -> Nil {
  named.call(name, call_timeout_ms, Revoke(signer, client, _))
  |> option.unwrap(Nil)
}

/// 承認待ちの接続要求の一覧。アクターが動いていなければ空。
pub fn pending(name: Name(Msg)) -> List(Pending) {
  named.call(name, call_timeout_ms, GetPending)
  |> option.unwrap([])
}

/// 接続要求を 1 件承認し、応答イベントを送り出すまで待つ。
pub fn approve(name: Name(Msg), token: String) -> Result(Nil, String) {
  call_decision(name, Approve(token, _))
}

/// 接続要求を 1 件拒否し、応答イベントを送り出すまで待つ。
pub fn deny(name: Name(Msg), token: String) -> Result(Nil, String) {
  call_decision(name, Deny(token, _))
}

/// 現在の署名者 pubkey の一覧。読み込みの前は空。アクターが応答しなければ
/// `None` を返し、署名者が 0 件であることと区別する（購読は応答が無いときに開いて
/// いる購読を閉じてはならない）。
pub fn signers(name: Name(Msg)) -> Option(List(String)) {
  named.call(name, call_timeout_ms, GetSigners)
}

/// アカウントを追加し、反映されるまで待つ。
pub fn add_account(
  name: Name(Msg),
  account: Account,
  label: String,
) -> Result(Nil, ChangeFailure) {
  call_change(name, AddAccount(account, label, _))
}

/// アカウントを削除し、反映されるまで待つ。
pub fn remove_account(
  name: Name(Msg),
  signer: String,
) -> Result(Nil, ChangeFailure) {
  call_change(name, RemoveAccount(signer, _))
}

/// 接続 secret を作り直し、反映されるまで待つ。
pub fn rotate_secret(
  name: Name(Msg),
  signer: String,
) -> Result(Nil, ChangeFailure) {
  call_change(name, RotateSecret(signer, _))
}

/// ラベルを差し替え、反映されるまで待つ。
pub fn update_label(
  name: Name(Msg),
  signer: String,
  label: String,
) -> Result(Nil, ChangeFailure) {
  call_change(name, UpdateLabel(signer, label, _))
}

/// アカウントの一覧。読み込めていない、あるいはアクターが応答しないときは理由を
/// 返す。
pub fn accounts(name: Name(Msg)) -> Result(List(Listing), String) {
  named.call(name, call_timeout_ms, GetAccounts)
  |> option.unwrap(Error(query_not_answered))
}

/// 署名者の秘密鍵の nsec。読み込み前、読み直しの前、未登録、アクターが応答しない
/// ときは理由を返す。
///
/// **`Ok` の値は秘密鍵そのものである。** 成功も失敗も `String` なので型では取り違えを
/// 検出できない。結果を丸ごと `string.inspect` やログに渡さず、`Ok` と `Error` を
/// 分けてから使うこと。応答は alias の `named.call` で受けるので、タイムアウトの後に
/// 届いた nsec はランタイムが捨てる。
pub fn nsec(name: Name(Msg), signer: String) -> Result(String, String) {
  named.call(name, call_timeout_ms, GetNsec(signer, _))
  |> option.unwrap(Error(query_not_answered))
}

/// 承認・拒否をアクターへ送って結果を待つ。アクターが動いていなければエラーに
/// する。承認したつもりのまま待たせ続けるより、UI に失敗として出す方がよい。
fn call_decision(
  name: Name(Msg),
  request: fn(Subject(Result(Nil, String))) -> Msg,
) -> Result(Nil, String) {
  named.call(name, call_timeout_ms, request)
  |> option.unwrap(Error("bunker is not running"))
}

/// アカウントの変更をアクターへ送って結果を待つ。
fn call_change(
  name: Name(Msg),
  request: fn(Subject(Result(Nil, ChangeFailure))) -> Msg,
) -> Result(Nil, ChangeFailure) {
  named.call(name, change_timeout_ms, request)
  |> option.unwrap(Error(MaybeApplied(change_not_answered)))
}

/// メモリがストアの内容を反映しているかどうか。
type Accounts {
  /// ストアの内容を読み込めていない。起動直後の読み込みの前か、結果が曖昧な書き込みの
  /// 後の読み直しの前。`LoadAccounts` の送信か再試行のタイマーが、常にちょうど 1 つ
  /// 未処理で残っている。`failure` は最後の失敗の理由（まだ失敗していなければ
  /// `None`）、`retry_delay_ms` はこの状態での読み込みが失敗したときの、次の再試行
  /// までの待ち時間。
  Loading(failure: Option(String), retry_delay_ms: Int)
  /// 読み込めた。
  Ready
}

/// アカウントの変更の種類。ログ行の言い回しを決める。
type Change {
  Added
  Removed
  SecretRotated
  LabelUpdated
}

/// バンカーアクターが保持する状態。判断は `engine` が行い、アクターはその状態と、
/// 署名者ごとのラベルと、生きた接続の送信手段と、自分が起動した時刻と、読み込みの
/// 進み具合だけを持つ。`not_before` はエンジンではなくここに置き、アクターの起動
/// 時刻を刻む。
type State {
  State(
    engine: engine.Engine,
    /// 署名者ごとのラベル。鍵はエンジンのアカウントと同じ集合に保つ。ラベルは
    /// NIP-46 のどの判断にも使わないのでエンジンに入れない。2 つを同じ集合に保つ
    /// 責任は `with_account` と `without_account` だけが負う。
    labels: Dict(String, String),
    publishers: Dict(String, fn(Event) -> Nil),
    not_before: Int,
    settings: Settings,
    /// このアクターのプロセスだけが持つ、読み込み用の名前なしの subject。
    retry: Subject(Msg),
    accounts: Accounts,
    /// バンカーリレーの購読の張り直しを依頼する関数。送るだけで待たない。
    resubscribe: fn() -> Nil,
  )
}

/// スーパービジョンツリー用の子仕様。`resubscribe` は署名者の集合が変わったときに
/// 呼ぶ関数で、ツリーを組む側がバンカーリレーの接続へ配線する。
pub fn supervised(
  name: Name(Msg),
  settings: Settings,
  resubscribe: fn() -> Nil,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, settings, resubscribe) })
}

/// バンカーアクターを起動する。`name` で登録するため、接続は起動時に生きていた
/// プロセスではなく、現在その名前を保持しているプロセスに到達する。
///
/// スーパーバイザーは再起動のたびにこれを呼ぶため、アクターは承認済みセッション
/// もリプレイ防止の `seen` も引き継がない。記憶していないリクエストを再実行しない
/// よう、ここで起動時刻を刻み、それより古いリクエストはエンジンが受け付けない。
/// アカウントは仕様のスナップショットではなく、起動のたびにストアの最新から読む。
pub fn start(
  name: Name(Msg),
  settings: Settings,
  resubscribe: fn() -> Nil,
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(init_timeout_ms, fn(self) {
    initialise(settings, resubscribe, self)
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// 読み込みをメッセージとして積み、名前付き subject と読み込み用の subject の
/// 両方を選択する。DB には触らない。
///
/// 読み込みと再試行を名前なしの subject へ送るのは、再起動したアクターに古い
/// タイマーを届けないためである。名前付き subject への `send_after` は名前宛ての
/// タイマーになり、同じ名前で起動し直したアクターに届いて再試行の系列が再起動の
/// たびに増える。名前なしの subject は pid 宛てなので、プロセスが終了すると
/// ランタイムがタイマーを取り消す。
fn initialise(
  settings: Settings,
  resubscribe: fn() -> Nil,
  self: Subject(Msg),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  let retry = process.new_subject()
  process.send(retry, LoadAccounts)
  // `selecting` を使うと既定の subject は選択されないので、名前付き subject も
  // 明示的に入れる。入れ忘れると問い合わせが届かない。
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select(retry)
  State(
    engine: engine.new([], settings.auth_url),
    labels: dict.new(),
    publishers: dict.new(),
    not_before: time.now_seconds(),
    settings: settings,
    retry: retry,
    accounts: loading(settings),
    resubscribe: resubscribe,
  )
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

/// アカウントの読み込みと変更、publisher の登録、署名者・アカウント・セッション・
/// 承認待ちの照会、セッションの取り消し、承認待ちの承認と拒否、あるいは受信イベント
/// 1 件をエンジンに通して生成された応答を全接続へ送信する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    LoadAccounts -> actor.continue(load_accounts(state))
    GetSigners(reply) -> {
      process.send(reply, engine.signers(state.engine))
      actor.continue(state)
    }
    GetAccounts(reply) -> {
      process.send(reply, listings(state))
      actor.continue(state)
    }
    GetNsec(signer:, reply:) -> {
      process.send(reply, private_key_nsec(state, signer))
      actor.continue(state)
    }
    AddAccount(account: added, label:, reply:) -> {
      let signer = account.pubkey_hex(added)
      let stored =
        vault.StoredAccount(
          account: added,
          secret: random.hex(connection_secret_bytes),
          label: label,
        )
      apply_change(
        state,
        reply,
        Added,
        signer,
        require_unregistered(state, signer),
        fn() { state.settings.store.insert(stored) },
        with_account(_, stored),
      )
    }
    RemoveAccount(signer:, reply:) ->
      apply_change(
        state,
        reply,
        Removed,
        signer,
        require_registered(state, signer),
        fn() { state.settings.store.delete(signer) },
        without_account(_, signer),
      )
    RotateSecret(signer:, reply:) -> {
      let secret = random.hex(connection_secret_bytes)
      apply_change(
        state,
        reply,
        SecretRotated,
        signer,
        require_registered(state, signer),
        fn() { state.settings.store.update_secret(signer, secret) },
        fn(current) {
          State(
            ..current,
            engine: engine.replace_secret(current.engine, signer, secret),
          )
        },
      )
    }
    UpdateLabel(signer:, label:, reply:) ->
      apply_change(
        state,
        reply,
        LabelUpdated,
        signer,
        require_registered(state, signer),
        fn() { state.settings.store.update_label(signer, label) },
        fn(current) {
          State(..current, labels: dict.insert(current.labels, signer, label))
        },
      )
    GetPending(reply) -> {
      process.send(reply, engine.pending(state.engine, time.now_seconds()))
      actor.continue(state)
    }
    Approve(token, reply) ->
      apply_decision(state, reply, engine.approve(state.engine, token, _))
    Deny(token, reply) ->
      apply_decision(state, reply, engine.deny(state.engine, token, _))
    GetSessions(reply) -> {
      process.send(reply, engine.sessions(state.engine))
      actor.continue(state)
    }
    Revoke(signer, client, reply) -> {
      let next = engine.revoke(state.engine, signer, client)
      process.send(reply, Nil)
      actor.continue(State(..state, engine: next))
    }
    SetPublisher(relay_url, publish) ->
      actor.continue(
        State(
          ..state,
          publishers: dict.insert(state.publishers, relay_url, publish),
        ),
      )
    RemovePublisher(relay_url) ->
      actor.continue(
        State(..state, publishers: dict.delete(state.publishers, relay_url)),
      )
    Incoming(incoming) -> {
      // トークンは受信のたびに引く。使うのは承認待ちを作るときだけだが、そう
      // することでエンジンは乱数を持たずに済む。
      let inputs =
        engine.Inputs(
          now: time.now_seconds(),
          token: random.hex(token_bytes),
          not_before: state.not_before,
        )
      let #(next, outcome) = engine.handle_event(state.engine, incoming, inputs)
      case outcome {
        engine.Reply(response) -> publish(state, response)
        engine.Duplicate -> Nil
        engine.Ignore(reason) -> log.println(log_prefix, "ignored: " <> reason)
      }
      actor.continue(State(..state, engine: next))
    }
  }
}

/// ストアからアカウントを読み込む。成功したらメモリを読み込んだ内容に合わせて
/// 読み込み済みに移り、失敗したら再試行を予約して次の待ち時間を延ばす。読み込み
/// 済みなら何もしない（`LoadAccounts` を積むのは読み込めていない状態に移るときだけ
/// で、読み込み用の subject はこのプロセスの外に出ないので、通常は起きない）。
fn load_accounts(state: State) -> State {
  case state.accounts {
    Ready -> state
    Loading(failure:, retry_delay_ms:) -> {
      let outcome = state.settings.store.load()
      load_report(failure, outcome, retry_delay_ms)
      |> list.each(log.println(log_prefix, _))
      case outcome {
        Ok(loaded) ->
          reconcile(State(..state, accounts: Ready), loaded)
          |> transition(state, _)
        Error(reason) -> {
          let _ = process.send_after(state.retry, retry_delay_ms, LoadAccounts)
          State(
            ..state,
            accounts: Loading(
              failure: Some(reason),
              retry_delay_ms: next_retry_delay(
                state.settings.retry_delay,
                retry_delay_ms,
              ),
            ),
          )
        }
      }
    }
  }
}

/// 読み込めていない状態の始まり。待ち時間は初期値から数える。
fn loading(settings: Settings) -> Accounts {
  Loading(failure: None, retry_delay_ms: settings.retry_delay.initial_ms)
}

/// `delay_ms` 待った後の読み込みも失敗したときの、次の待ち時間。倍にして上限で
/// 頭打ちにする。
pub fn next_retry_delay(retry: RetryDelay, delay_ms: Int) -> Int {
  int.min(delay_ms * 2, retry.max_ms)
}

/// 読み込みの結果に対して出すログ行。`previous_failure` は直前の失敗の理由
/// （まだ失敗していなければ `None`）、`retry_delay_ms` は次の再試行までの待ち時間。
///
/// 失敗は始まったときと理由が変わったときだけ報告し、同じ理由の再試行では黙る。
/// 復帰したときはその旨を報告する。
pub fn load_report(
  previous_failure: Option(String),
  outcome: Result(vault.Loaded, String),
  retry_delay_ms: Int,
) -> List(String) {
  case outcome, previous_failure {
    Ok(loaded), None -> [loaded_line(loaded), ..skipped_lines(loaded)]
    Ok(loaded), Some(_) -> [
      "account store is back; " <> loaded_line(loaded),
      ..skipped_lines(loaded)
    ]
    Error(reason), Some(previous) if reason == previous -> []
    Error(reason), _ -> [
      "account store unavailable: "
      <> reason
      <> "; retrying in "
      <> int.to_string(retry_delay_ms)
      <> "ms",
    ]
  }
}

/// 読み込みの完了行。飛ばした行があれば全体の件数も添え、全行がマスターキー違いで
/// 飛んだ状況をひと目で分かるようにする。
fn loaded_line(loaded: vault.Loaded) -> String {
  let count = int.to_string(list.length(loaded.accounts))
  case loaded.skipped {
    [] -> "loaded " <> count <> " account(s)"
    skipped ->
      "loaded "
      <> count
      <> " of "
      <> int.to_string(list.length(loaded.accounts) + list.length(skipped))
      <> " account(s)"
  }
}

/// 飛ばした行ごとのログ行。
fn skipped_lines(loaded: vault.Loaded) -> List(String) {
  list.map(loaded.skipped, vault.describe_skipped)
}

/// 管理 UI に出すアカウントの一覧。並びは署名者の昇順。ラベルが無ければ空文字列
/// （DB の列の既定値と同じ）にする。読み込めていなければ理由を返す。npub はメモリの
/// `Account` から作るので、`account.npub` の前提（32 バイトの公開鍵）が型で保たれる。
fn listings(state: State) -> Result(List(Listing), String) {
  case state.accounts {
    Ready ->
      engine.registered_accounts(state.engine)
      |> list.map(fn(entry) {
        let #(registered, secret) = entry
        let signer = account.pubkey_hex(registered)
        Listing(
          signer: signer,
          npub: account.npub(registered),
          label: dict.get(state.labels, signer) |> result.unwrap(""),
          secret: secret,
        )
      })
      |> Ok
    Loading(failure: None, ..) -> Error("accounts are being loaded")
    Loading(failure: Some(reason), ..) ->
      Error("account store unavailable: " <> reason)
  }
}

/// 秘密鍵の再表示の問い合わせへの応答。状態を変えず、ストアもログも使わない。読み直しの
/// 前も拒否するのは、その間メモリが DB と食い違っていることがあるからで、変更と一覧の
/// 扱いに合わせる。
fn private_key_nsec(state: State, signer: String) -> Result(String, String) {
  case state.accounts {
    Loading(..) -> Error(accounts_not_loaded)
    Ready ->
      engine.find_account(state.engine, signer)
      |> result.map(account.nsec)
      |> result.replace_error(account_not_registered)
  }
}

/// ストアから読み込んだアカウントにメモリを合わせる。ストアに無い署名者を取り除き、
/// 読み込んだアカウントを足す（登録済みの署名者なら鍵・secret・ラベルを置き換える）。
/// エンジンを作り直さないので、ストアに残っている署名者のセッションと承認待ちは残る。
fn reconcile(state: State, loaded: vault.Loaded) -> State {
  let stored =
    list.map(loaded.accounts, fn(entry) { account.pubkey_hex(entry.account) })
  engine.signers(state.engine)
  |> list.filter(fn(signer) { !list.contains(stored, signer) })
  |> list.fold(state, without_account)
  |> list.fold(loaded.accounts, _, with_account)
}

/// 読み込みか追加で得たアカウントを、エンジンとラベルの両方に入れる。
fn with_account(state: State, stored: vault.StoredAccount) -> State {
  State(
    ..state,
    engine: engine.add_account(state.engine, stored.account, stored.secret),
    labels: dict.insert(
      state.labels,
      account.pubkey_hex(stored.account),
      stored.label,
    ),
  )
}

/// 署名者を、エンジンとラベルの両方から取り除く。
fn without_account(state: State, signer: String) -> State {
  State(
    ..state,
    engine: engine.remove_account(state.engine, signer),
    labels: dict.delete(state.labels, signer),
  )
}

/// 追加の前の検査。登録済みの公開鍵ならストアへの往復を省いて拒否する。
fn require_unregistered(
  state: State,
  signer: String,
) -> Result(Nil, ChangeFailure) {
  case engine.has_account(state.engine, signer) {
    True -> Error(NotApplied(account_already_registered))
    False -> Ok(Nil)
  }
}

/// 削除・secret の作り直し・ラベルの差し替えの前の検査。署名者は呼び出し側が渡す
/// 文字列なので、メモリに無い署名者はストアにもログにも渡さずに拒否する。
fn require_registered(
  state: State,
  signer: String,
) -> Result(Nil, ChangeFailure) {
  case engine.has_account(state.engine, signer) {
    True -> Ok(Nil)
    False -> Error(NotApplied(account_not_registered))
  }
}

/// 読み込み済みで、かつ `check` が `Ok` のときだけストアへ書き込み、成功したら
/// 状態を変えてから応答する。読み込みの前は `NotReady`、拒否や、書き込まれていない
/// ことが確定した失敗のときは `NotApplied` で、状態を変えずに理由を返す。
///
/// 書き込まれたかどうか分からない失敗のときは、メモリを変えずに読み込めていない状態へ
/// 移り、読み直しの `LoadAccounts` を積んでから `MaybeApplied` で応答する。応答を
/// 受けた管理 UI が続けて送る問い合わせは読み直しの後に処理されるので、読み直しに
/// 成功していれば DB と一致した一覧を読む。読み込み済みの状態には未処理の読み込みも
/// 再試行のタイマーも無いので、読み込みの系列は 1 本のままである。
///
/// ログはストアを呼んだときだけ出す。`check` を通った署名者はメモリの一覧にある
/// 公開鍵なので、ログに出るのはその値だけになる。
fn apply_change(
  state: State,
  reply: Subject(Result(Nil, ChangeFailure)),
  change: Change,
  signer: String,
  check: Result(Nil, ChangeFailure),
  write: fn() -> Result(Nil, WriteFailure),
  update: fn(State) -> State,
) -> actor.Next(State, Msg) {
  let #(next, outcome) = case state.accounts, check {
    Loading(..), _ -> #(state, Error(NotReady(accounts_not_loaded)))
    Ready, Error(failure) -> #(state, Error(failure))
    Ready, Ok(Nil) -> {
      let written = write()
      log.println(log_prefix, change_line(change, signer, written))
      case written {
        Ok(Nil) -> #(transition(state, update(state)), Ok(Nil))
        Error(NotWritten(reason)) -> #(state, Error(NotApplied(reason)))
        // 読み直しに見えなかった書き込みがあればメモリに入る。読み込みで飛ばされる
        // 行ならメモリには入らないが、どちらでも行が DB にあることは確かなので、
        // 登録済みとして応答する。読み直しを応答の前に済ませるので、応答を受けた
        // 管理 UI は読み直した後の一覧を読む。
        Error(AlreadyStored(reason)) -> #(
          load_accounts(State(..state, accounts: loading(state.settings))),
          Error(NotApplied(reason)),
        )
        Error(MaybeWritten(_reason)) -> {
          process.send(state.retry, LoadAccounts)
          #(
            State(..state, accounts: loading(state.settings)),
            Error(MaybeApplied(change_may_have_been_applied)),
          )
        }
      }
    }
  }
  process.send(reply, outcome)
  actor.continue(next)
}

/// 変更 1 件のログ行。値は公開鍵と固定の文言の理由だけで、ラベル（利用者の入力で、
/// 改行を含みうる）も secret も含めない。
fn change_line(
  change: Change,
  signer: String,
  written: Result(Nil, WriteFailure),
) -> String {
  let #(done, attempted) = case change {
    Added -> #("added account", "add account")
    Removed -> #("removed account", "remove account")
    SecretRotated -> #(
      "rotated the connection secret of",
      "rotate the connection secret of",
    )
    LabelUpdated -> #("updated the label of", "update the label of")
  }
  let failed = "failed to " <> attempted <> " " <> signer <> ": "
  case written {
    Ok(Nil) -> done <> " " <> signer
    Error(NotWritten(reason)) -> failed <> reason
    Error(AlreadyStored(reason)) ->
      failed <> reason <> "; reloading the accounts from the store"
    Error(MaybeWritten(reason)) ->
      failed
      <> reason
      <> "; the change may have been applied, reloading the accounts from the store"
  }
}

/// 次の状態に移る。署名者の集合が変わっていれば購読の張り直しを依頼する。依頼は
/// 接続アクターへ送るだけで待たないので、接続が張り直しで送る `GetSigners` は
/// この処理が返った後に処理され、変更後の署名者を読む。
fn transition(from: State, to: State) -> State {
  case engine.signers(from.engine) == engine.signers(to.engine) {
    True -> Nil
    False -> to.resubscribe()
  }
  to
}

/// 承認・拒否の結果を状態に反映し、待たせているクライアントへ応答イベントを
/// 発行する。token が不明・失効していれば状態は変えずに理由を返す。
fn apply_decision(
  state: State,
  reply: Subject(Result(Nil, String)),
  decision: fn(Int) -> Result(#(engine.Engine, Event), String),
) -> actor.Next(State, Msg) {
  case decision(time.now_seconds()) {
    Error(reason) -> {
      process.send(reply, Error(reason))
      actor.continue(state)
    }
    Ok(#(next, response)) -> {
      publish(state, response)
      process.send(reply, Ok(Nil))
      actor.continue(State(..state, engine: next))
    }
  }
}

/// 応答イベントを全バンカーリレーへ発行する。接続が 1 本も生きていなければ送る
/// 先が無いので、応答を落としたことをログに残す（クライアントは接続が戻った
/// あとの再送で回復する）。
fn publish(state: State, response: Event) -> Nil {
  case dict.is_empty(state.publishers) {
    True ->
      log.println(log_prefix, "no live relay connection; response dropped")
    False ->
      dict.each(state.publishers, fn(_relay_url, publish) { publish(response) })
  }
}
