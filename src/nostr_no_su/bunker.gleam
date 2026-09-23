//// 純粋な `engine` を包む薄いアクター。リレーの再接続をまたいでセッション状態を
//// 保持する（リレークライアントは切断のたびに再起動されるため、そこにセッション
//// 状態を置けない）。判断ロジックはすべて `engine` 側に残す。
////
//// アカウントは起動時にストアから読み込む。読み込みは initialiser が自分宛に
//// 積むメッセージ（`LoadAccounts`）で行い、initialiser 自身は DB に触らない。DB が
//// 応答しなくても初期化のタイムアウトに当たらず、サブツリーの起動は失敗しない。
//// 読み込みに失敗したら理由をログに出して再試行を予約するだけで、アクターは
//// 落ちない。再試行の待ち時間は失敗のたびに倍にし、上限で頭打ちにする
//// （`backoff.Backoff`）。待ち時間は読み込めていない状態（`Loading`）だけが持つので、
//// 読み込みに成功した後の失敗は初期値から数え直す。
////
//// **読み込みの順序に関する不変条件**：`LoadAccounts` は initialiser が送るので、
//// アクターのメールボックスで必ず最初のメッセージになる。接続は `rest_for_one` で
//// アクターの後に起動するので、接続が購読のために送る `GetSigners` は必ずその後に
//// 処理される。DB が起動時に到達可能なら、どの接続も読み込み済みの署名者で購読
//// する。**`LoadAccounts` の最初の送信を initialiser 以外へ移さないこと。**
////
//// 読み込んだアカウントは、メモリの署名者と突き合わせて合わせる（`reconcile`）。
//// ストアに無い署名者を取り除き、読み込んだアカウントを足すか置き換える。その後、
//// 読み込んだセッションと承認待ちでエンジンのものを置き換える。起動時の読み込みでは
//// メモリが空なので、読み込んだアカウントをそのまま足すことになる。
////
//// **アカウントの変更**（追加、削除、secret の作り直し、ラベルの差し替え）は、
//// アクターの中でストアへ書き込み、書き込みが成功したときだけメモリの状態を変える。
//// 書き込まれていないことが確定した失敗では、メモリを変えずに理由を返す。書き込みが
//// 期限を過ぎたときや途中で接続が切れたときは、サーバー側でまだ実行中か、すでに
//// コミットされていることがあるので、メモリを変えずにストアから読み直して合わせ、
//// 呼び出し側には反映されたかもしれない旨を返す（`MaybeApplied(StoreDidNotConfirm)`）。
//// ストアの読み込みは、実行中の書き込みの終了をテーブルのロックで待ってから読む
//// （`account_store.load`）。読み直しは起動時の読み込みと同じ `LoadAccounts` の経路で
//// 行い（契機は結果が曖昧な書き込みの後と管理 UI からの要求）、失敗すれば同じく
//// 名前なしの subject へ再試行を予約する。読み直しが成功する
//// までの間はメモリが DB と食い違っていることがあり、その間の変更は起動時の読み込みの
//// 前と同じく `accounts are not loaded yet` で拒否し、一覧は理由を返す。NIP-46 の処理は
//// その間もメモリのアカウントで続け、`connect`、`logout`、セッション内のリクエストの
//// 最終利用の書き込みも行う（読み直しは積み増さない）。
////
//// 保証するのは次のことである。メモリは、成功した書き込みと成功した読み込みの結果
//// だけで変わる。結果が曖昧な書き込みの後は、読み直しに成功した時点で、その書き込みの
//// 結果を含めて DB と一致する。例外は、書き込みの文がサーバーに届いてテーブルのロックを
//// 取るより先に読み直しがロックを取った場合（`account_store.load` の「残る窓」）で、その
//// 書き込みは読み直しに見えず、メモリは次の読み込みまで DB より遅れる。この場合も、
//// 追加はもう一度追加すれば、ストアが登録済みを返したときに応答の前に読み直すので
//// 一致し、secret の作り直しはもう一度作り直せば一致する。読み込みで飛ばされる行
//// （別のマスターキーで暗号化されているなど）の公開鍵の追加は、読み直してもメモリに
//// 入らず、登録済みとして拒否される。その行は管理 UI のダッシュボードの
//// 「読み込めなかったアカウント」の枠から削除できる。`pubkey` の列を読めない
//// 行（`MalformedPubkey`）は画面からは消せず、DB から直接消す。
////
//// **待ち**：書き込みと読み込みの間は NIP-46 の処理が待たされる（届いたリクエストは
//// メールボックスに積まれて捨てられない）。書き込み 1 件は最長で約 3 秒（DB に到達
//// できないときのチェックアウトの失敗）、読み込み 1 回は読み込みの期限の 3 秒で打ち
//// 切る。DB を一時停止した測定では、読み込みは 3000ms、2950ms、2000ms で失敗して返った。
//// 結果が曖昧な書き込みの後に読み直しが失敗し続けると、再試行のたびに最長 3 秒ずつ
//// 待ちが生じ、読み直しが成功するまで続く。読み直しが失敗し続けても、承認済み
//// セッションは失われない。
////
//// **承認・拒否・取り消し**も同じく、エンジンで判断した後にストアへ書き込み、
//// 書き込みが成功したときだけ状態に反映し、応答イベントを発行する（取り消しは
//// 発行しない）。結果が曖昧な書き込みの後は、アカウントの変更と同じ `LoadAccounts`
//// の読み直しに移り、読み直しで承認待ちとセッションも DB の内容に置き換わる。
//// 書けていなければ行が残るので、利用者はダッシュボードからやり直せる。承認の
//// `MaybeWritten` の後は、この読み直しの後にも `ack` を発行しない（書けていれば
//// 承認待ちは消え、クライアントは接続し直す）。NIP-46 の `connect`、`logout`、セッション
//// 内のリクエストの最終利用（組ごとに `last_used_granularity_seconds` に 1 回まで）も、
//// 書き込みが成功したときだけ状態に反映する。書き込みが失敗したときはメモリの
//// セッションと承認待ちを変えず、`connect` には `connection_not_saved` のエラーを返し、
//// `logout` にはクライアントの後始末を止めないため `ack` を返し、セッション内の
//// リクエストには成功時と同じ応答を返す（試行の時刻はエンジンの `touch_attempts` に
//// 残し、次の書き込みまでの間隔に数える）。結果が曖昧な書き込みの後は同じ読み直しに
//// 移る。
////
//// 状態の遷移はすべて `transition` を通し、署名者の集合が変わったときだけ、監視が
//// 作者の照合に読む写し（`is_signer`）を置き直して購読の張り直しを依頼する。追加と
//// 削除のほか、読み込みの失敗からの復帰でも張り直しが起き、secret やラベルの差し替え
//// では起きない。セッションのリレーと署名者の対応が変わったときは、URL の一覧を
//// `session_relays` へ渡す。メモリはこのアクター経由の変更だけで変わるので、DB の
//// 行を外から直接変えた場合は次の起動まで反映されない。

import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import nostr_no_su/backoff
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine.{type Pending, type Session}
import nostr_no_su/bunker/rate_limit
import nostr_no_su/bunker/vault
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event, type Verified}
import nostr_no_su/random
import nostr_no_su/relay_client.{type Acknowledgement}
import nostr_no_su/relay_list
import nostr_no_su/time

/// バンカーが出すログ行の接頭辞。
pub const log_prefix = "bunker"

/// 本番の読み込みの再試行の待ち時間。5 秒から倍に延ばし、2 分で頭打ちにする。DB に
/// 到達できないとき、読み込み 1 回は最長 3 秒かかり、その間アクターは次のメッセージを
/// 処理しない。間隔を延ばすのは、DB が長く止まっている間にこの待ちが起きる回数を
/// 抑えるためである。
pub const default_retry_delay = backoff.Backoff(
  initial_ms: 5000,
  max_ms: 120_000,
)

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

/// OK を待つ期間（秒）。OK は通常すぐ返るので、発行からこの秒数で返らない OK は
/// 返らないとみなす（値は判定の取りこぼしと保持量の兼ね合いで選んだ）。
const acknowledgement_timeout_seconds = 60

/// `rate-limited:` の OK を返したリレーへ、セッションの外の応答を止める期間
/// （秒）。NIP-01 の `rate-limited:` は再開の時刻を持たないので、報告の間隔
/// （`rate_limit.report_interval_seconds`）と同じ長さにする。
pub const rate_limited_pause_seconds = 60

/// 承認ページの URL に入るトークンのバイト数。承認・拒否そのものは管理 UI の
/// 認証が守るが、トークンは保留の識別子なので、認証を通った管理者が別の要求を
/// 取り違えないよう推測できない長さにする。
const token_bytes = 16

/// 接続 secret のバイト数。secret は `bunker://` URI で署名を委任する資格なので、
/// 推測できない長さにする。
const connection_secret_bytes = 16

/// 読み込みか読み直しが終わっていないときの理由。
const accounts_not_loaded = "accounts are not loaded yet"

/// 署名者がメモリに無いときの理由。
const account_not_registered = "account is not registered"

/// 問い合わせに応答が無いときの理由。
const query_not_answered = "bunker is not responding"

/// `engine.sign_as` が失敗した（`bip340.sign` が失敗した）ときの理由。
const sign_failed = "failed to sign the event"

/// 取り消す（署名者, クライアント）が承認済みのセッションに無いときの理由。
const session_not_approved = "session is not approved"

/// 結果が曖昧な書き込みの後のログ行に添える文言。`change_line` の `MaybeWritten`
/// の枝もこれを使い、同じ文言を 2 か所に持たない。
const reloading_after_unconfirmed_write = "; the change may have been applied, reloading the accounts from the store"

/// アカウントの変更が成功しなかった理由。`NotApplied` と `NotReady` の理由は値
/// （鍵、secret、ラベル）を含まない固定の英文、`MaybeApplied` は原因を
/// `NotConfirmed` で表す。登録済みと未登録は、管理 UI が表示の言語の文言に写せるよう
/// 理由を持たない構築子で返す。管理 UI は型で応答を分け、理由は本文に出すだけにする。
pub type ChangeFailure {
  /// 変更は反映されていない（書き込まれていないことが確定したストアの失敗。DB に行が
  /// 無い更新の `account is not registered` を含む）。
  NotApplied(reason: String)
  /// 追加しようとした公開鍵が登録済み（メモリにあるか、DB に行がある）。変更は反映されて
  /// いない。
  AccountAlreadyRegistered
  /// 変更の対象の署名者が登録されていない（secret の作り直しとラベルの差し替えはメモリに
  /// 無い、削除はメモリにも読み込みで飛ばされた行にも無い）。変更は反映されていない。
  AccountNotRegistered
  /// 変更を受け付けられる状態に無い（読み込み前、結果が曖昧な書き込みの後の読み直しの
  /// 前）。時間をおけば同じ変更を受け付けうる。
  NotReady(reason: String)
  /// 反映されたかどうか分からない（書き込みの期限切れや途中の切断、DB のクライアントの
  /// 例外、アクターが期限内に応答しない）。
  MaybeApplied(cause: NotConfirmed)
}

/// 変更が反映されたかを確かめられなかった原因。管理 UI が言語ごとの文言に写す。
pub type NotConfirmed {
  /// アクターが期限内に応答しなかった。
  BunkerDidNotRespond
  /// ストアへの書き込みの結果が曖昧だった。
  StoreDidNotConfirm
}

/// 承認・拒否・取り消しが成功しなかった理由。理由の文字列は値（pubkey、token）を含まない
/// 固定の英文。管理 UI は型で応答を分け、理由は本文に出すだけにする。
pub type SessionFailure {
  /// 対象が無い（不明、失効、処理済み、承認済みでない組）。
  SessionNotFound(reason: String)
  /// 書き込まれていないことが確定した（`NotWritten`、`AlreadyStored`）。
  SessionNotApplied(reason: String)
  /// 読み込みか読み直しの前。時間をおけば受け付けうる。
  SessionNotReady(reason: String)
  /// 反映されたか分からない（`MaybeWritten`、アクターの無応答）。
  SessionMaybeApplied(cause: NotConfirmed)
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

/// ストアから読み込んだバンカーの状態。セッションと承認待ちはエンジンの型で持つ。
pub type Snapshot {
  Snapshot(
    accounts: vault.Loaded,
    sessions: List(Session),
    pending: List(Pending),
    /// 登録されたリレー。アクターは持たず `open_relays` へ渡すだけ。
    relays: List(relay_list.Registered),
  )
}

/// アカウントストアの操作。起動処理がプールとマスターキーを閉じ込めて渡すので、
/// アクターの状態を表示してもキーが出ず、テストは DB なしで偽の操作を渡せる。
/// 失敗の理由は値（鍵、secret、ラベル）を含まない固定の文言。
pub type Store {
  Store(
    /// アカウント、セッション、承認待ち、登録されたリレーを読み込む。
    load: fn() -> Result(Snapshot, String),
    /// アカウントを 1 件追加する。
    insert: fn(vault.StoredAccount) -> Result(Nil, WriteFailure),
    /// 署名者を削除する。登録されていなければ成功として `Ok(Nil)` を返す（削除は
    /// 行が無い状態にすることが目的のため）。
    delete: fn(String) -> Result(Nil, WriteFailure),
    /// 署名者の接続 secret を差し替える。
    update_secret: fn(String, String) -> Result(Nil, WriteFailure),
    /// 署名者のラベルを差し替える。
    update_label: fn(String, String) -> Result(Nil, WriteFailure),
    /// セッションと承認待ちの書き込み 1 件（`engine.Write`）を行う。
    write: fn(engine.Write) -> Result(Nil, WriteFailure),
  )
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
    retry_delay: backoff.Backoff,
  )
}

/// 管理 UI に渡すアカウント 1 件。秘密鍵（`Account`）を持たない。secret を含むので
/// 認証済みページ以外に出さない。`npub` は画面でアカウントを識別するための表記。
pub type Listing {
  Listing(signer: String, npub: String, label: String, secret: String)
}

/// バンカーの接続が受け持つ範囲。
pub type RelayScope {
  /// 基本のバンカーリレー（`relay_list` のバンカーの用途の項目）の接続。全署名者の
  /// `#p` を購読し、全アカウントで AUTH し、すべての応答を出す。
  BaseRelay
  /// 基本のバンカーリレーに無い、セッションのリレー（接続の前の取り置きを含む）の
  /// 接続。その URL を持つセッションと取り置きの署名者だけで購読と AUTH を行い、
  /// そのセッションへの応答だけを出す。
  SessionRelay
}

/// バンカーアクターが受け取るメッセージ。
pub type Msg {
  /// バンカー接続のいずれかで受信したイベント。id と署名は接続のプロセスで
  /// 確かめてある。
  Incoming(event: Verified)
  /// 1 本のリレー接続で応答イベントを送信するための関数を、接続の範囲と一緒に
  /// 登録する。各接続アクターは再接続のたびに `on_connect` からこれを送り直す
  /// ため、応答は生きたソケットから出ていく。応答は基本の接続と、応答先の
  /// セッションのリレーの接続へ送信する（`response_relays`。`rate-limited:` を
  /// 返したリレーへのセッションの外の応答だけは `publish` が止める）。クライアント
  /// は URI の `relay=` ヒントすべてを待ち受けており、重複配信の排除はクライアント
  /// 側の責務（こちら側の重複は `engine` が排除する）なので、生きたリレーが 1 つ
  /// あれば往復は成立する。
  SetPublisher(relay_url: String, scope: RelayScope, publish: fn(Event) -> Nil)
  /// 1 本のリレー接続の送信手段を取り下げる。接続アクターが `on_disconnect` から
  /// 送るため、死んだソケットへ応答を渡し続けることがない。接続アクター自身が
  /// クラッシュした場合は `on_disconnect` を経ないため、再起動した接続が
  /// `SetPublisher` で上書きするまでは古い送信手段が残る。登録済みの送信手段の
  /// 範囲が `scope` と違えば何もしない（同じ URL の接続が範囲を移ったとき、止めた
  /// 側の取り下げが新しい側を消さないため）。
  RemovePublisher(relay_url: String, scope: RelayScope)
  /// バンカーリレーの接続が、発行した応答への OK を知らせる。拒否の理由が
  /// `rate-limited:` なら、そのリレーへのセッションの外の応答をしばらく
  /// 止める（`pause_on_rate_limit`）。
  Acknowledged(relay_url: String, ack: Acknowledgement)
  /// 承認済みセッションの一覧を問い合わせる。読み込み前、読み直しの前は理由を返す。
  GetSessions(reply: Subject(Result(List(Session), String)))
  /// `relay_url` を持つセッションと取り置きの署名者を問い合わせる。セッションの
  /// リレーの接続の購読が使う。
  GetSessionSigners(relay_url: String, reply: Subject(List(String)))
  /// `nostrconnect://` の接続の前に、（署名者, クライアント）の組に URI のリレーを
  /// 取り置く。取り置いたリレーはセッションのリレーと同じく `relay_map` に入り、
  /// その署名者で購読と AUTH を行う接続が開く。同じ組を取り置き直すと一覧を
  /// 置き換える。
  ReserveSessionRelays(signer: String, client: String, relays: List(String))
  /// 組の取り置きを外す。取り置きが無ければ何もしない。同じリレーを持つセッションが
  /// あれば、そのリレーの接続は残る。
  ReleaseSessionRelays(signer: String, client: String)
  /// セッションを 1 件取り消す（`logout` 相当）。書き込みが成功したときだけ状態から
  /// 消し、取り消し後の画面が古い一覧を読まないよう完了を待てるように応答する。
  /// 読み込み前は `SessionNotReady`、読み込み済みで承認済みでない組なら
  /// `SessionNotFound`、書き込みの結果が曖昧なときは `SessionMaybeApplied`、
  /// 書き込まれていないことが確定したら `SessionNotApplied` を返す。
  Revoke(
    signer: String,
    client: String,
    reply: Subject(Result(Nil, SessionFailure)),
  )
  /// 承認済みセッションの権限を差し替える。書き込みが成功したときだけ状態に
  /// 反映して応答する。読み込み前は `SessionNotReady`、読み込み済みで承認済みで
  /// ない組なら `SessionNotFound`、書き込みの結果が曖昧なときは
  /// `SessionMaybeApplied`、書き込まれていないことが確定したら
  /// `SessionNotApplied` を返す。
  UpdatePerms(
    signer: String,
    client: String,
    perms: String,
    reply: Subject(Result(Nil, SessionFailure)),
  )
  /// 承認待ちの接続要求の一覧を問い合わせる。読み込み前、読み直しの前は理由を返す。
  GetPending(reply: Subject(Result(List(Pending), String)))
  /// 承認待ちの接続要求を承認する。書き込みが成功したときだけ状態に反映し、
  /// 登録済みの接続へ応答イベントを送る。要求が見つからない、読み込み前、あるいは
  /// 書き込みが成功しなかったときは `SessionFailure` で理由を返す。
  Approve(token: String, reply: Subject(Result(Nil, SessionFailure)))
  /// 承認待ちの接続要求を拒否する。書き込みが成功したときだけ状態に反映するほかは
  /// `Approve` と同じ。
  Deny(token: String, reply: Subject(Result(Nil, SessionFailure)))
  /// 解釈済みの `nostrconnect://` の情報から（署名者, クライアント）のセッションを
  /// 開く。書き込みが成功したときだけ状態に反映し、登録済みの接続へ応答イベントを
  /// 送る。読み込み前、署名者が未登録、あるいは書き込みが成功しなかったときは
  /// `SessionFailure` で理由を返す。
  OpenClientSession(
    signer: String,
    client: String,
    perms: String,
    relays: List(String),
    secret: String,
    reply: Subject(Result(Nil, SessionFailure)),
  )
  /// ストアからアカウントを読み込む。initialiser と再試行のタイマーが、アクター
  /// ごとに作る名前なしの subject へ送る。名前付き subject へは誰も送らない。
  LoadAccounts
  /// 管理 UI からの読み直しの要求。読み込み済みなら読み直しを積み、読み込めていなければ
  /// 何もしない。どちらも `Nil` で応答する。
  ReloadAccounts(reply: Subject(Nil))
  /// 現在の署名者 pubkey の一覧を問い合わせる。バンカーリレーの購読が使う。
  GetSigners(reply: Subject(List(String)))
  /// 応答の発行先として配られているリレーの URL を問い合わせる。
  GetPublishers(reply: Subject(List(String)))
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
  /// 読み込みで飛ばされた行の一覧を問い合わせる。読み込み前、読み直しの前は理由を
  /// 返す。
  GetSkipped(reply: Subject(Result(List(vault.Skipped), String)))
  /// 署名者の秘密鍵を nsec の文字列で問い合わせる。管理 UI の再表示だけが使う。
  /// 要求は公開鍵と返信先しか持たないので、処理の途中で落ちてもクラッシュレポートに
  /// 秘密は出ない。
  GetNsec(signer: String, reply: Subject(Result(String, String)))
  /// リレーの AUTH（NIP-42）に返す署名済みイベントを問い合わせる。`BaseRelay` の
  /// 接続は登録アカウントごと、`SessionRelay` の接続はその URL を持つセッションと
  /// 取り置きの署名者ごとに署名する。バンカーリレーの接続が challenge を受けたときに
  /// 使う。
  Authenticate(
    relay_url: String,
    scope: RelayScope,
    challenge: String,
    reply: Subject(Result(List(Event), String)),
  )
  /// プラグインからの取得の口（`plugin_api`）が使う、公開鍵が登録アカウントかどうか
  /// の確認。読み込み前は理由を返す。
  CheckAccount(signer: String, reply: Subject(Result(Nil, String)))
  /// プラグインからの複数の公開鍵の取得（`plugin_api`）が使う、公開鍵ごとの登録の
  /// 確認。読み込み前は全体の理由を返す。
  CheckAccounts(
    signers: List(String),
    reply: Subject(Result(List(Result(Nil, String)), String)),
  )
  /// プラグインからの送信の口（`plugin_api`）が使う、登録アカウントの鍵で署名した
  /// イベントの要求。NIP-46 の `sign_event` と違い、セッションの `perms` は見ない
  /// （要求元はクライアントではなく同じ VM のプラグインである）。アカウントの
  /// 読み込み前は理由を返す。
  SignEvent(
    signer: String,
    kind: Int,
    tags: List(List(String)),
    content: String,
    reply: Subject(Result(Event, String)),
  )
}

/// バンカーが保持する承認済みセッションの一覧。読み込み前、読み直しの前、
/// アクターが応答しないときは理由を返す。
pub fn sessions(name: Name(Msg)) -> Result(List(Session), String) {
  named.call(name, call_timeout_ms, GetSessions)
  |> option.unwrap(Error(query_not_answered))
}

/// セッションを 1 件取り消し、反映されるまで待つ。読み込み前は `SessionNotReady`、
/// 読み込み済みで承認済みでない組なら `SessionNotFound`、書き込まれていないことが
/// 確定したら `SessionNotApplied`、書き込みの結果が曖昧なときとアクターが応答
/// しないときは `SessionMaybeApplied` を返す。
pub fn revoke(
  name: Name(Msg),
  signer: String,
  client: String,
) -> Result(Nil, SessionFailure) {
  call_session_change(name, Revoke(signer, client, _))
}

/// 承認済みセッションの権限を差し替え、反映されるまで待つ。読み込み前は
/// `SessionNotReady`、読み込み済みで承認済みでない組なら `SessionNotFound`、
/// 書き込まれていないことが確定したら `SessionNotApplied`、書き込みの結果が
/// 曖昧なときとアクターが応答しないときは `SessionMaybeApplied` を返す。
pub fn update_perms(
  name: Name(Msg),
  signer: String,
  client: String,
  perms: String,
) -> Result(Nil, SessionFailure) {
  call_session_change(name, UpdatePerms(signer, client, perms, _))
}

/// 承認待ちの接続要求の一覧。読み込み前、読み直しの前、アクターが応答しないときは
/// 理由を返す。
pub fn pending(name: Name(Msg)) -> Result(List(Pending), String) {
  named.call(name, call_timeout_ms, GetPending)
  |> option.unwrap(Error(query_not_answered))
}

/// 接続要求を 1 件承認し、書き込みが成功したときだけ応答イベントを送り出すまで
/// 待つ。読み込み前は `SessionNotReady`、要求が見つからなければ `SessionNotFound`、
/// 書き込まれていないことが確定したら `SessionNotApplied`、書き込みの結果が
/// 曖昧なときとアクターが応答しないときは `SessionMaybeApplied` を返す。
pub fn approve(name: Name(Msg), token: String) -> Result(Nil, SessionFailure) {
  call_session_change(name, Approve(token, _))
}

/// 接続要求を 1 件拒否し、書き込みが成功したときだけ応答イベントを送り出すまで
/// 待つ。ほかは `approve` と同じ。
pub fn deny(name: Name(Msg), token: String) -> Result(Nil, SessionFailure) {
  call_session_change(name, Deny(token, _))
}

/// 解釈済みの `nostrconnect://` の情報からセッションを開き、書き込みが成功した
/// ときだけ応答イベントを送り出すまで待つ。`relays` は URI のリレーで、
/// セッションに保存する。読み込み前は `SessionNotReady`、署名者が登録されて
/// いなければ `SessionNotFound`、書き込みの失敗は `approve` と同じ。
pub fn open_client_session(
  name: Name(Msg),
  signer: String,
  client: String,
  perms: String,
  relays: List(String),
  secret: String,
) -> Result(Nil, SessionFailure) {
  call_session_change(name, OpenClientSession(
    signer,
    client,
    perms,
    relays,
    secret,
    _,
  ))
}

/// 現在の署名者 pubkey の一覧。読み込みの前は空。アクターが応答しなければ
/// `None` を返し、署名者が 0 件であることと区別する（購読は応答が無いときに開いて
/// いる購読を閉じてはならない）。
pub fn signers(name: Name(Msg)) -> Option(List(String)) {
  named.call(name, call_timeout_ms, GetSigners)
}

/// `relay_url` を持つ承認済みセッションと取り置きの署名者（昇順）。読み込みの前は
/// 取り置きの署名者だけ。アクターが応答しなければ `None` を返し、0 件と区別する
/// （`signers` と同じく、購読は応答が無いときに開いている購読を閉じてはならない）。
pub fn session_signers(
  name: Name(Msg),
  relay_url: String,
) -> Option(List(String)) {
  named.call(name, call_timeout_ms, GetSessionSigners(relay_url, _))
}

/// `ReserveSessionRelays` を送る。送るだけで待たない。同じプロセスが後に送る
/// 問い合わせより先に処理される。
pub fn reserve_session_relays(
  name: Name(Msg),
  signer: String,
  client: String,
  relays: List(String),
) -> Nil {
  named.send(name, ReserveSessionRelays(signer, client, relays))
}

/// `ReleaseSessionRelays` を送る。送るだけで待たない。
pub fn release_session_relays(
  name: Name(Msg),
  signer: String,
  client: String,
) -> Nil {
  named.send(name, ReleaseSessionRelays(signer, client))
}

/// `pubkey` が `name` のアクターの署名者か。アクターへ問い合わせず、署名者の集合が
/// 変わるたびに `transition` が置き直す写しを読むので、監視のイベント 1 件ごとに
/// 呼べる。写しは `signers` と同じ集合である。署名者が 1 件以上になるまでは写しが
/// 無く、偽を返す。アクターが再起動しても写しは残り、読み込みで集合が変わったときに
/// 置き直される。
pub fn is_signer(name: Name(Msg), pubkey: String) -> Bool {
  set.contains(persistent_term_get(signers_key(name), set.new()), pubkey)
}

/// `name` のアクターの署名者の集合の写しを置く persistent_term のキー。テストは
/// アクターごとに別の名前を使うので、写しも名前ごとに分ける。
fn signers_key(name: Name(Msg)) -> #(Atom, Name(Msg)) {
  #(atom.create("nostr_no_su_bunker_signers"), name)
}

/// 応答の発行先として配られているリレーの URL。アクターが応答しなければ `None`
/// を返し、発行先が 0 件であることと区別する。
pub fn publisher_urls(name: Name(Msg)) -> Option(List(String)) {
  named.call(name, call_timeout_ms, GetPublishers)
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

/// DB からの読み直しを要求する。読み込めていない間は既に読み直しが進んでいるので
/// 何もしない。アクターが応答しないときは理由を返す。
pub fn reload_accounts(name: Name(Msg)) -> Result(Nil, String) {
  named.call(name, call_timeout_ms, ReloadAccounts)
  |> option.to_result(query_not_answered)
}

/// 直近の読み込みで飛ばされた行の一覧。読み込めていない、あるいはアクターが
/// 応答しないときは理由を返す。
pub fn skipped(name: Name(Msg)) -> Result(List(vault.Skipped), String) {
  named.call(name, call_timeout_ms, GetSkipped)
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

/// リレーの AUTH に返す、署名済みの kind 22242。`BaseRelay` の接続は登録アカウント
/// ごと、`SessionRelay` の接続はその URL を持つセッションと取り置きの署名者ごとに
/// 署名する。アクターが応答しないときは理由を返す。`relay_client.Authenticator` と
/// して接続に渡す。
pub fn authenticate(
  name: Name(Msg),
  relay_url: String,
  scope: RelayScope,
  challenge: String,
) -> Result(List(Event), String) {
  named.call(name, call_timeout_ms, Authenticate(relay_url, scope, challenge, _))
  |> option.unwrap(Error(query_not_answered))
}

/// 登録アカウントの鍵で署名したイベント。プラグインからの送信の口（`plugin_api`）
/// が使う。アカウントの読み込み前、署名者が未登録、署名に失敗、あるいはアクターが
/// 応答しないときは理由を返す。
pub fn sign_event(
  name: Name(Msg),
  signer: String,
  kind: Int,
  tags: List(List(String)),
  content: String,
) -> Result(Event, String) {
  named.call(name, call_timeout_ms, SignEvent(signer, kind, tags, content, _))
  |> option.unwrap(Error(query_not_answered))
}

/// `signer` が登録アカウントか。プラグインからの取得の口（`plugin_api`）が使う。
/// 読み込み前、未登録、あるいはアクターが応答しないときは理由を返す。
pub fn check_account(name: Name(Msg), signer: String) -> Result(Nil, String) {
  named.call(name, call_timeout_ms, CheckAccount(signer, _))
  |> option.unwrap(Error(query_not_answered))
}

/// `signers` のそれぞれが登録アカウントか。結果は `signers` と同じ順で、未登録の
/// 署名者は理由を持つ。1 回の問い合わせで確かめるので、件数によらずアクターを
/// 1 度しか待たない。読み込み前、あるいはアクターが応答しないときは全体の理由を
/// 返す。
pub fn check_accounts(
  name: Name(Msg),
  signers: List(String),
) -> Result(List(Result(Nil, String)), String) {
  named.call(name, call_timeout_ms, CheckAccounts(signers, _))
  |> option.unwrap(Error(query_not_answered))
}

/// 承認・拒否・取り消しをアクターへ送って結果を待つ。応答が無ければ、打ち切った
/// 後にアクターが処理しうるので `SessionMaybeApplied(BunkerDidNotRespond)` を
/// 返す。承認したつもりのまま待たせ続けるより、UI に失敗として出す方がよい。
fn call_session_change(
  name: Name(Msg),
  request: fn(Subject(Result(Nil, SessionFailure))) -> Msg,
) -> Result(Nil, SessionFailure) {
  named.call(name, call_timeout_ms, request)
  |> option.unwrap(Error(SessionMaybeApplied(BunkerDidNotRespond)))
}

/// アカウントの変更をアクターへ送って結果を待つ。
fn call_change(
  name: Name(Msg),
  request: fn(Subject(Result(Nil, ChangeFailure))) -> Msg,
) -> Result(Nil, ChangeFailure) {
  named.call(name, change_timeout_ms, request)
  |> option.unwrap(Error(MaybeApplied(BunkerDidNotRespond)))
}

/// メモリがストアの内容を反映しているかどうか。
type Accounts {
  /// ストアの内容を読み込めていない。起動直後の読み込みの前か、結果が曖昧な書き込みの
  /// 後の読み直しの前、または管理 UI からの読み直しの要求の前。`LoadAccounts` の
  /// 送信か再試行のタイマーが、常にちょうど 1 つ
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

/// 承認・拒否・取り消し・権限の編集と、NIP-46 の `connect`（セッションを開く、
/// 承認待ちを登録する）・`logout`・セッション内のリクエストの最終利用の書き込み
/// の種類。失敗のログ行の言い回しを決める。前の 4 つは `admin.SessionChange` と
/// 同じ区分だが、`bunker` は管理 UI に依存できないので別に持つ。
type SessionChange {
  Approval
  Denial
  Revocation
  PermissionsUpdate
  SessionOpening
  PendingRecording
  SessionClosing
  SessionUse
}

/// OK を待っている応答の一覧。キーは応答 id。
pub opaque type Deliveries {
  Deliveries(Dict(String, Delivery))
}

/// 発行した応答 1 件の追跡。`client` は宛先のクライアント pubkey、`awaiting` は
/// まだ OK を返していないリレーの URL、`rejections` は `#(relay_url, reason)` を
/// 届いた逆順に積んだ拒否、`published_at` は発行時刻（秒）。
type Delivery {
  Delivery(
    client: String,
    awaiting: Set(String),
    rejections: List(#(String, String)),
    published_at: Int,
  )
}

/// 何も待っていない一覧。
pub fn new_deliveries() -> Deliveries {
  Deliveries(dict.new())
}

/// 応答を `relay_urls` に発行したことを記録する。記録の前に、発行から
/// `acknowledgement_timeout_seconds` 以上経った項目を捨てる。
pub fn track(
  deliveries: Deliveries,
  response: Event,
  relay_urls: List(String),
  now: Int,
) -> Deliveries {
  let Deliveries(entries) = deliveries
  let fresh =
    dict.filter(entries, fn(_id, delivery) {
      delivery.published_at + acknowledgement_timeout_seconds > now
    })
  Deliveries(dict.insert(
    fresh,
    response.id,
    Delivery(
      client: recipient(response),
      awaiting: set.from_list(relay_urls),
      rejections: [],
      published_at: now,
    ),
  ))
}

/// OK 1 件を反映し、送った先の全リレーが拒否し終えたら出すログ行を返す。id が
/// 一覧に無ければ（掃除済み、監視と無関係の OK）そのまま返す。受理は項目を消す。
/// 拒否は未応答からそのリレーを外して積み、未応答が空になった時点で項目を消して
/// ログ行を返す。すでに未応答に無いリレーからの拒否（同じリレーからの 2 度目）は
/// 数えない。
pub fn acknowledge(
  deliveries: Deliveries,
  relay_url: String,
  ack: Acknowledgement,
) -> #(Deliveries, Option(String)) {
  let Deliveries(entries) = deliveries
  case dict.get(entries, ack.event_id), ack.accepted {
    Error(Nil), _ -> #(deliveries, None)
    Ok(_delivery), True -> #(
      Deliveries(dict.delete(entries, ack.event_id)),
      None,
    )
    Ok(delivery), False ->
      case set.contains(delivery.awaiting, relay_url) {
        False -> #(deliveries, None)
        True -> {
          let remaining = set.delete(delivery.awaiting, relay_url)
          let updated =
            Delivery(..delivery, awaiting: remaining, rejections: [
              #(relay_url, ack.message),
              ..delivery.rejections
            ])
          case set.is_empty(remaining) {
            False -> #(
              Deliveries(dict.insert(entries, ack.event_id, updated)),
              None,
            )
            True -> #(
              Deliveries(dict.delete(entries, ack.event_id)),
              Some(rejected_line(ack.event_id, updated)),
            )
          }
        }
      }
  }
}

/// 応答の宛先のクライアント pubkey。最初の `["p", pubkey, ..]` タグから取り、
/// 無ければ `unknown`。
fn recipient(response: Event) -> String {
  case engine.p_tag_pubkeys(response.tags) {
    [pubkey, ..] -> pubkey
    [] -> "unknown"
  }
}

/// 全リレーに拒否された応答の行。拒否は届いた順に並べる。
fn rejected_line(id: String, delivery: Delivery) -> String {
  let reasons =
    delivery.rejections
    |> list.reverse
    |> list.map(fn(rejection) {
      let #(relay_url, reason) = rejection
      relay_client.label(relay_url) <> ": " <> reason
    })
    |> string.join("; ")
  "response "
  <> id
  <> " to "
  <> delivery.client
  <> " was rejected by every relay: "
  <> reasons
}

/// セッションの外の応答を止めているリレーの一覧。キーはリレーの URL。
pub opaque type Pauses {
  Pauses(Dict(String, Pause))
}

/// リレー 1 本の停止。`until` は止める期限（秒、この時刻から再開する）、
/// `dropped` は最後の報告の後にこのリレーへ出さなかった応答の件数、
/// `reported_at` は最後に報告した時刻。
type Pause {
  Pause(until: Int, dropped: Int, reported_at: Int)
}

/// どのリレーも止めていない一覧。
pub fn new_pauses() -> Pauses {
  Pauses(dict.new())
}

/// OK 1 件を反映する。拒否の理由が `rate-limited:` で始まれば、`relay_url` への
/// セッションの外の応答を `now` から `rate_limited_pause_seconds` 秒止める。
/// 一覧にあるリレーは期限が過ぎていても期限だけを更新し、件数と報告の時刻を
/// 引き継ぐ。一覧に無いリレーは、最初に出さなかった 1 件をすぐ報告する状態で
/// 足す。それ以外の OK では変えない。
pub fn pause_on_rate_limit(
  pauses: Pauses,
  relay_url: String,
  ack: Acknowledgement,
  now: Int,
) -> Pauses {
  let Pauses(entries) = pauses
  case ack.accepted, string.starts_with(ack.message, "rate-limited:") {
    False, True -> {
      let until = now + rate_limited_pause_seconds
      let pause = case dict.get(entries, relay_url) {
        Ok(paused) -> Pause(..paused, until: until)
        Error(Nil) ->
          Pause(
            until: until,
            dropped: 0,
            reported_at: now - rate_limit.report_interval_seconds,
          )
      }
      Pauses(dict.insert(entries, relay_url, pause))
    }
    _, _ -> pauses
  }
}

/// 応答 1 件を送るリレーを `relay_urls` の順に選ぶ。戻り値は数えた後の一覧、
/// 送るリレー、ログの行。セッションの外の応答（`outside_session` が真）は、
/// 期限が `now` より後の止めたリレーを飛ばして件数を数え、そのリレーの前の
/// 報告から `rate_limit.report_interval_seconds` 以上経っていれば件数を報告
/// して数え直す。セッションの中の応答は `relay_urls` のすべてへ送る。
pub fn recipients(
  pauses: Pauses,
  relay_urls: List(String),
  outside_session: Bool,
  now: Int,
) -> #(Pauses, List(String), List(String)) {
  use #(Pauses(entries), sent, lines), relay_url <- list.fold(
    list.reverse(relay_urls),
    #(pauses, [], []),
  )
  case outside_session, dict.get(entries, relay_url) {
    True, Ok(paused) if paused.until > now -> {
      let dropped = paused.dropped + 1
      let #(kept, reported) = case
        now - paused.reported_at >= rate_limit.report_interval_seconds
      {
        True -> #(Pause(..paused, dropped: 0, reported_at: now), [
          pause_report(relay_url, dropped),
        ])
        False -> #(Pause(..paused, dropped: dropped), [])
      }
      #(
        Pauses(dict.insert(entries, relay_url, kept)),
        sent,
        list.append(reported, lines),
      )
    }
    _, _ -> #(Pauses(entries), [relay_url, ..sent], lines)
  }
}

/// （署名者, リレーの一覧）の組から、リレーの URL ごとにその URL を持つセッションの
/// 署名者を重複なしの昇順で並べた写像を作る。リレーの無いセッションは何も足さない。
/// URL は文字列のまま比べる。
pub fn session_relay_signers(
  sessions: List(#(String, List(String))),
) -> Dict(String, List(String)) {
  sessions
  |> list.fold(dict.new(), fn(acc, session) {
    let #(signer, relays) = session
    use acc, relay_url <- list.fold(relays, acc)
    dict.upsert(acc, relay_url, fn(current) {
      [signer, ..option.unwrap(current, [])]
    })
  })
  |> dict.map_values(fn(_relay_url, signers) {
    signers |> list.unique |> list.sort(string.compare)
  })
}

/// 応答 1 件を出すリレーの URL を `publishers` の順に選ぶ。`BaseRelay` はすべて、
/// `SessionRelay` は応答先のセッションのリレー（`session_relays`）にあるものだけを
/// 選ぶ。
pub fn response_relays(
  publishers: List(#(String, RelayScope)),
  session_relays: List(String),
) -> List(String) {
  use #(relay_url, scope) <- list.filter_map(publishers)
  case scope, list.contains(session_relays, relay_url) {
    BaseRelay, _ | SessionRelay, True -> Ok(relay_url)
    SessionRelay, False -> Error(Nil)
  }
}

/// 承認済みのセッションと取り置き（`reserved`）の `session_relay_signers`。
fn relay_map(state: State) -> Dict(String, List(String)) {
  engine.sessions(state.engine)
  |> list.map(fn(session) { #(session.signer, session.relays) })
  |> list.append(
    dict.to_list(state.reserved)
    |> list.map(fn(reservation) {
      let #(#(signer, _client), relays) = reservation
      #(signer, relays)
    }),
  )
  |> session_relay_signers
}

/// `relay_url` を持つ承認済みセッションと取り置きの署名者（昇順）。無ければ空。
fn session_relay_signers_of(state: State, relay_url: String) -> List(String) {
  dict.get(relay_map(state), relay_url) |> result.unwrap([])
}

/// 応答の（署名者, 宛先）の組のセッションを `engines` の順に探し、最初に見つかった
/// もののリレーを返す。どれにも無ければ空。
fn response_session_relays(
  engines: List(engine.Engine),
  response: Event,
) -> List(String) {
  let client = recipient(response)
  engines
  |> list.find_map(fn(eng) {
    engine.sessions(eng)
    |> list.find(fn(session) {
      session.signer == response.pubkey && session.client == client
    })
  })
  |> result.map(fn(session) { session.relays })
  |> result.unwrap([])
}

/// 止めたリレーへ出さなかった応答の件数を報告するログの 1 行。
pub fn pause_report(relay_url: String, dropped: Int) -> String {
  "dropped "
  <> int.to_string(dropped)
  <> " responses without a session to "
  <> relay_client.label(relay_url)
  <> " while it is rate-limiting"
}

/// バンカーアクターが保持する状態。判断は `engine` が行い、アクターはその状態と、
/// 署名者ごとのラベルと、生きた接続の送信手段とその範囲と、接続の前に取り置いた
/// セッションのリレーと、自分が起動した時刻と、読み込みの進み具合と、直近の読み込みで
/// 飛ばされた行と、OK を待っている応答の一覧と、セッションの外の応答を止めている
/// リレーの一覧だけを持つ。`not_before` はエンジンではなくここに置き、アクターの
/// 起動時刻を刻む。
type State {
  State(
    /// このアクターの登録名。署名者の集合の写し（`is_signer`）のキーに使う。
    name: Name(Msg),
    engine: engine.Engine,
    /// 署名者ごとのラベル。鍵はエンジンのアカウントと同じ集合に保つ。ラベルは
    /// NIP-46 のどの判断にも使わないのでエンジンに入れない。2 つを同じ集合に保つ
    /// 責任は `with_account` と `without_account` だけが負う。
    labels: Dict(String, String),
    publishers: Dict(String, Publisher),
    not_before: Int,
    settings: Settings,
    /// このアクターのプロセスだけが持つ、読み込み用の名前なしの subject。
    retry: Subject(Msg),
    accounts: Accounts,
    /// 署名者の集合が変わったときに購読の張り直しを依頼する関数。送るだけで待たない。宛先の接続はツリーを組む側が決める。
    resubscribe: fn() -> Nil,
    /// 読み込みに成功するたびに、登録されたリレーを渡す関数。送るだけで待たない。
    open_relays: fn(List(relay_list.Registered)) -> Nil,
    /// セッションのリレーの URL の一覧が変わるたびに、昇順の一覧を渡す関数。送る
    /// だけで待たない。
    session_relays: fn(List(String)) -> Nil,
    /// OK を待っている応答の一覧。
    deliveries: Deliveries,
    /// セッションの外の応答を止めているリレーの一覧。
    pauses: Pauses,
    /// 直近の読み込みで飛ばされた行。読み込みのたびに入れ替わり、書き込みでは
    /// 変わらない。
    skipped: List(vault.Skipped),
    /// 接続の前に取り置いた（署名者, クライアント）ごとの URI のリレー。セッションの
    /// リレーと合わせて `relay_map` を作る。
    reserved: Dict(#(String, String), List(String)),
  )
}

/// リレー 1 本の送信手段と、その接続の範囲。
type Publisher {
  Publisher(scope: RelayScope, publish: fn(Event) -> Nil)
}

/// スーパービジョンツリー用の子仕様。`resubscribe` は署名者の集合が変わったときに
/// 呼ぶ関数、`open_relays` は読み込みに成功するたびに登録されたリレーを渡す関数、
/// `session_relays` はセッションのリレーの一覧が変わったときにその一覧を渡す関数で、
/// どれもツリーを組む側が配線する。
pub fn supervised(
  name: Name(Msg),
  settings: Settings,
  resubscribe: fn() -> Nil,
  open_relays: fn(List(relay_list.Registered)) -> Nil,
  session_relays: fn(List(String)) -> Nil,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() {
    start(name, settings, resubscribe, open_relays, session_relays)
  })
}

/// バンカーアクターを起動する。`name` で登録するため、接続は起動時に生きていた
/// プロセスではなく、現在その名前を保持しているプロセスに到達する。
///
/// スーパーバイザーは再起動のたびにこれを呼ぶため、アクターはリプレイ防止の
/// `seen` を引き継がない（セッションと承認待ちは読み込みでストアから戻る）。
/// 記憶していないリクエストを再実行しないよう、ここで起動時刻を刻み、それより
/// 古いリクエストはエンジンが受け付けない。
/// アカウントは仕様のスナップショットではなく、起動のたびにストアの最新から読む。
pub fn start(
  name: Name(Msg),
  settings: Settings,
  resubscribe: fn() -> Nil,
  open_relays: fn(List(relay_list.Registered)) -> Nil,
  session_relays: fn(List(String)) -> Nil,
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(init_timeout_ms, fn(self) {
    initialise(name, settings, resubscribe, open_relays, session_relays, self)
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
  name: Name(Msg),
  settings: Settings,
  resubscribe: fn() -> Nil,
  open_relays: fn(List(relay_list.Registered)) -> Nil,
  session_relays: fn(List(String)) -> Nil,
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
    name: name,
    engine: engine.new([], settings.auth_url),
    labels: dict.new(),
    publishers: dict.new(),
    not_before: time.now_seconds(),
    settings: settings,
    retry: retry,
    accounts: loading(settings),
    resubscribe: resubscribe,
    open_relays: open_relays,
    session_relays: session_relays,
    deliveries: new_deliveries(),
    pauses: new_pauses(),
    skipped: [],
    reserved: dict.new(),
  )
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

/// アカウントの読み込みと変更、読み直しの要求、publisher の登録、セッションの
/// リレーの取り置きと取り外し、署名者・セッションのリレーの署名者・アカウント・
/// 飛ばされた行・セッション・承認待ちの照会、セッションの取り消し、承認待ちの承認と
/// 拒否、受信イベント 1 件をエンジンに通して生成された応答の送信、発行した
/// 応答への OK の反映と `rate-limited:` を返したリレーの停止、リレーの AUTH に返す
/// 認証イベントの署名を行う。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    LoadAccounts -> actor.continue(load_accounts(state))
    ReloadAccounts(reply) -> {
      let next = case state.accounts {
        Ready -> reload(state)
        Loading(..) -> state
      }
      process.send(reply, Nil)
      actor.continue(next)
    }
    GetSigners(reply) -> {
      process.send(reply, engine.signers(state.engine))
      actor.continue(state)
    }
    GetPublishers(reply) -> {
      process.send(reply, dict.keys(state.publishers))
      actor.continue(state)
    }
    GetAccounts(reply) -> {
      process.send(reply, listings(state))
      actor.continue(state)
    }
    GetSkipped(reply) -> {
      process.send(reply, when_loaded(state, fn() { state.skipped }))
      actor.continue(state)
    }
    GetNsec(signer:, reply:) -> {
      process.send(reply, private_key_nsec(state, signer))
      actor.continue(state)
    }
    Authenticate(relay_url:, scope:, challenge:, reply:) -> {
      let signers = case scope {
        BaseRelay -> engine.signers(state.engine)
        SessionRelay -> session_relay_signers_of(state, relay_url)
      }
      let accounts =
        list.filter_map(signers, engine.find_account(state.engine, _))
      process.send(
        reply,
        authentication_events(
          accounts,
          relay_url,
          challenge,
          time.now_seconds(),
        ),
      )
      actor.continue(state)
    }
    CheckAccount(signer:, reply:) -> {
      process.send(reply, registered(state, signer))
      actor.continue(state)
    }
    CheckAccounts(signers:, reply:) -> {
      let answer = case state.accounts {
        Loading(..) -> Error(accounts_not_loaded)
        Ready -> Ok(list.map(signers, registered(state, _)))
      }
      process.send(reply, answer)
      actor.continue(state)
    }
    SignEvent(signer:, kind:, tags:, content:, reply:) -> {
      process.send(reply, sign_for(state, signer, kind, tags, content))
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
        require_registered_or_skipped(state, signer),
        fn() { state.settings.store.delete(signer) },
        fn(current) { without_account(current, signer) |> drop_skipped(signer) },
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
      process.send(
        reply,
        when_loaded(state, fn() {
          engine.pending(state.engine, time.now_seconds())
        }),
      )
      actor.continue(state)
    }
    Approve(token, reply) ->
      apply_decision(state, reply, Approval, token, engine.approve)
    Deny(token, reply) ->
      apply_decision(state, reply, Denial, token, engine.deny)
    OpenClientSession(signer:, client:, perms:, relays:, secret:, reply:) ->
      open_client_session_for(
        state,
        reply,
        signer,
        client,
        perms,
        relays,
        secret,
      )
    GetSessions(reply) -> {
      process.send(
        reply,
        when_loaded(state, fn() { engine.sessions(state.engine) }),
      )
      actor.continue(state)
    }
    GetSessionSigners(relay_url:, reply:) -> {
      process.send(reply, session_relay_signers_of(state, relay_url))
      actor.continue(state)
    }
    ReserveSessionRelays(signer:, client:, relays:) ->
      actor.continue(transition(
        state,
        State(
          ..state,
          reserved: dict.insert(state.reserved, #(signer, client), relays),
        ),
      ))
    ReleaseSessionRelays(signer:, client:) ->
      actor.continue(transition(
        state,
        State(..state, reserved: dict.delete(state.reserved, #(signer, client))),
      ))
    Revoke(signer:, client:, reply:) ->
      revoke_session(state, reply, signer, client)
    UpdatePerms(signer:, client:, perms:, reply:) ->
      update_session_perms(state, reply, signer, client, perms)
    SetPublisher(relay_url, scope, publish) ->
      actor.continue(
        State(
          ..state,
          publishers: dict.insert(
            state.publishers,
            relay_url,
            Publisher(scope, publish),
          ),
        ),
      )
    RemovePublisher(relay_url, scope) -> {
      let publishers = case dict.get(state.publishers, relay_url) {
        Ok(Publisher(scope: current, ..)) if current == scope ->
          dict.delete(state.publishers, relay_url)
        _ -> state.publishers
      }
      actor.continue(State(..state, publishers: publishers))
    }
    Incoming(incoming) -> {
      // トークンは受信のたびに引く。使うのは承認待ちを作るときだけだが、そう
      // することでエンジンは乱数を持たずに済む。
      let inputs =
        engine.Inputs(
          now: time.now_seconds(),
          token: random.hex(token_bytes),
          not_before: state.not_before,
        )
      let engine.Handled(engine: accepted, outcome:, notice:, outside_session:) =
        engine.handle_event(state.engine, incoming, inputs)
      case notice {
        Some(line) -> log.write(log.Notice, log_prefix, line)
        None -> Nil
      }
      let #(published, next) = case outcome {
        engine.Reply(response) -> #(
          publish(
            state,
            response,
            outside_session,
            response_session_relays([accepted], response),
          ),
          accepted,
        )
        engine.Persist(write:, next:, response:, on_failure:) -> {
          let #(change, target) = incoming_write_change(write)
          case write_session_change(state, change, target, write) {
            #(written, Ok(Nil)) -> #(
              publish(
                written,
                response,
                outside_session,
                response_session_relays([next, accepted], response),
              ),
              next,
            )
            #(written, Error(_failure)) -> #(
              publish(
                written,
                on_failure,
                outside_session,
                response_session_relays([accepted], on_failure),
              ),
              accepted,
            )
          }
        }
        engine.Duplicate | engine.Throttled -> #(state, accepted)
        engine.Ignore(reason) -> {
          log.write(
            log.Notice,
            log_prefix,
            "ignored: " <> log.sanitize_external(reason),
          )
          #(state, accepted)
        }
      }
      actor.continue(transition(state, State(..published, engine: next)))
    }
    Acknowledged(relay_url, ack) -> {
      let #(deliveries, line) = acknowledge(state.deliveries, relay_url, ack)
      case line {
        Some(text) -> log.write(log.Warning, log_prefix, text)
        None -> Nil
      }
      actor.continue(
        State(
          ..state,
          deliveries: deliveries,
          pauses: pause_on_rate_limit(
            state.pauses,
            relay_url,
            ack,
            time.now_seconds(),
          ),
        ),
      )
    }
  }
}

/// ストアからアカウント、セッション、承認待ちを読み込む。成功したらメモリを
/// 読み込んだ内容に合わせて読み込み済みに移り、失敗したら再試行を予約して次の
/// 待ち時間を延ばす。読み込み済みなら何もしない（`LoadAccounts` を積むのは
/// 読み込めていない状態に移るときだけで、読み込み用の subject はこのプロセスの
/// 外に出ないので、通常は起きない）。
fn load_accounts(state: State) -> State {
  case state.accounts {
    Ready -> state
    Loading(failure:, retry_delay_ms:) -> {
      let outcome = state.settings.store.load()
      let level = case outcome {
        Ok(_) -> log.Notice
        Error(_) -> log.Warning
      }
      load_report(
        failure,
        result.map(outcome, fn(snapshot) { snapshot.accounts }),
        retry_delay_ms,
      )
      |> list.each(log.write(level, log_prefix, _))
      case outcome {
        Ok(snapshot) -> {
          state.open_relays(snapshot.relays)
          reconcile(
            State(..state, accounts: Ready),
            snapshot,
            time.now_seconds(),
          )
          |> transition(state, _)
        }
        Error(reason) -> {
          let _ = process.send_after(state.retry, retry_delay_ms, LoadAccounts)
          State(
            ..state,
            accounts: Loading(
              failure: Some(reason),
              retry_delay_ms: backoff.next(
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

/// アカウントごとに、リレーの AUTH に返す kind 22242 を組み立てて署名する。
/// 署名に失敗したアカウントがあれば理由を返す。
pub fn authentication_events(
  accounts: List(Account),
  relay_url: String,
  challenge: String,
  now: Int,
) -> Result(List(Event), String) {
  use signer <- list.try_map(accounts)
  event.Event(
    id: "",
    pubkey: account.pubkey_hex(signer),
    created_at: now,
    kind: event.auth_kind,
    tags: [["relay", relay_url], ["challenge", challenge]],
    content: "",
    sig: "",
  )
  |> event.finalize(account.privkey(signer))
  |> result.replace_error("failed to sign authentication event")
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
  when_loaded(state, fn() {
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
  })
}

/// 読み込み済みなら `read` の値を、読み込みか読み直しが終わっていなければ一覧の
/// 代わりの理由を返す。アカウント、飛ばされた行、承認待ち、セッションの一覧が使う。
fn when_loaded(state: State, read: fn() -> a) -> Result(a, String) {
  case state.accounts {
    Ready -> Ok(read())
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

/// `signer` が登録アカウントか。読み込み前は `accounts_not_loaded`、未登録なら
/// `account_not_registered` を返す。
fn registered(state: State, signer: String) -> Result(Nil, String) {
  case state.accounts {
    Loading(..) -> Error(accounts_not_loaded)
    Ready ->
      engine.find_account(state.engine, signer)
      |> result.replace_error(account_not_registered)
      |> result.replace(Nil)
  }
}

/// `signer` の鍵で署名したイベント。読み込み前は `accounts_not_loaded`、署名者が
/// 未登録なら `account_not_registered`、署名に失敗したら `sign_failed` を返す。
fn sign_for(
  state: State,
  signer: String,
  kind: Int,
  tags: List(List(String)),
  content: String,
) -> Result(Event, String) {
  case state.accounts {
    Loading(..) -> Error(accounts_not_loaded)
    Ready -> {
      use account <- result.try(
        engine.find_account(state.engine, signer)
        |> result.replace_error(account_not_registered),
      )
      engine.sign_as(account, kind, tags, content, time.now_seconds())
      |> result.replace_error(sign_failed)
    }
  }
}

/// ストアから読み込んだアカウントにメモリを合わせる（ストアに無い署名者を取り除き、
/// 読み込んだアカウントを足す。登録済みの署名者なら鍵・secret・ラベルを置き換える）。
/// アカウントを合わせた後、読み込んだセッションと承認待ちでエンジンのものを置き換える
/// （`engine.restore`。登録済みの署名者のものと失効していない承認待ちだけが残る）。
/// `restore` は登録済みの署名者で絞るので、アカウントを先に合わせる。
fn reconcile(state: State, snapshot: Snapshot, now: Int) -> State {
  let loaded = snapshot.accounts
  let stored =
    list.map(loaded.accounts, fn(entry) { account.pubkey_hex(entry.account) })
  let state =
    engine.signers(state.engine)
    |> list.filter(fn(signer) { !list.contains(stored, signer) })
    |> list.fold(state, without_account)
    |> list.fold(loaded.accounts, _, with_account)
  State(
    ..state,
    engine: engine.restore(
      state.engine,
      snapshot.sessions,
      snapshot.pending,
      now,
    ),
    skipped: loaded.skipped,
  )
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

/// 削除が書き込まれた行を、直近の読み込みで飛ばされた行の一覧から外す。
fn drop_skipped(state: State, signer: String) -> State {
  State(
    ..state,
    skipped: list.filter(state.skipped, fn(row) { row.pubkey != signer }),
  )
}

/// 追加の前の検査。登録済みの公開鍵ならストアへの往復を省いて拒否する。
fn require_unregistered(
  state: State,
  signer: String,
) -> Result(Nil, ChangeFailure) {
  case engine.has_account(state.engine, signer) {
    True -> Error(AccountAlreadyRegistered)
    False -> Ok(Nil)
  }
}

/// secret の作り直し・ラベルの差し替えの前の検査。署名者は呼び出し側が渡す文字列
/// なので、メモリに無い署名者はストアにもログにも渡さずに拒否する。
fn require_registered(
  state: State,
  signer: String,
) -> Result(Nil, ChangeFailure) {
  case engine.has_account(state.engine, signer) {
    True -> Ok(Nil)
    False -> Error(AccountNotRegistered)
  }
}

/// 削除の前の検査。登録済みの署名者か、読み込みで飛ばされて状態に残っている行の
/// 公開鍵なら通す。署名者は呼び出し側が渡す文字列なので、どちらにも無い値は
/// ストアにもログにも渡さずに拒否する。
fn require_registered_or_skipped(
  state: State,
  signer: String,
) -> Result(Nil, ChangeFailure) {
  case engine.has_account(state.engine, signer) {
    True -> Ok(Nil)
    False ->
      case list.any(state.skipped, fn(row) { row.pubkey == signer }) {
        True -> Ok(Nil)
        False -> Error(AccountNotRegistered)
      }
  }
}

/// 読み込み済みで、かつ `check` が `Ok` のときだけストアへ書き込み、成功したら
/// 状態を変えてから応答する。読み込みの前は `NotReady`、`check` の拒否はその失敗、
/// 書き込まれていないことが確定した失敗のときは `NotApplied` で、状態を変えずに返す。
/// DB に行があった追加（`AlreadyStored`）は、読み直しを積んでから
/// `AccountAlreadyRegistered` を返す。
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
      let level = case written {
        Ok(_) -> log.Notice
        Error(_) -> log.Warning
      }
      log.write(level, log_prefix, change_line(change, signer, written))
      case written {
        Ok(Nil) -> #(transition(state, update(state)), Ok(Nil))
        Error(NotWritten(reason)) -> #(state, Error(NotApplied(reason)))
        // 読み直しに見えなかった書き込みがあればメモリに入る。読み込みで飛ばされる
        // 行ならメモリには入らないが、どちらでも行が DB にあることは確かなので、
        // 登録済みとして応答する。読み直しを応答の前に済ませるので、応答を受けた
        // 管理 UI は読み直した後の一覧を読む。
        Error(AlreadyStored(_reason)) -> #(
          load_accounts(State(..state, accounts: loading(state.settings))),
          Error(AccountAlreadyRegistered),
        )
        Error(MaybeWritten(_reason)) -> #(
          reload(state),
          Error(MaybeApplied(StoreDidNotConfirm)),
        )
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
      failed <> reason <> reloading_after_unconfirmed_write
  }
}

/// 読み直しの `LoadAccounts` を積み、読み込めていない状態に移る。読み込み済みの
/// 状態からだけ呼ぶ（`write_session_change` は `Loading` の間は呼ばない）。
/// 読み込みの系列は 1 本のままになる。`apply_change` の `MaybeWritten` の枝と
/// `ReloadAccounts` の枝もこれを使う。
fn reload(state: State) -> State {
  process.send(state.retry, LoadAccounts)
  State(..state, accounts: loading(state.settings))
}

/// 次の状態に移る。署名者の集合が変わっていれば、その写しを `is_signer` が読む
/// persistent_term に置き直してから、購読の張り直しを依頼する。写しを先に置くので、
/// 張り直した購読で届くイベントは変更後の署名者で照合される。依頼は接続アクターへ
/// 送るだけで待たないので、接続が張り直しで送る `GetSigners` はこの処理が返った後に
/// 処理され、変更後の署名者を読む。セッションのリレーと署名者の対応（`relay_map`）が
/// 変わっていれば、URL の昇順の一覧を `session_relays` へ渡す。
fn transition(from: State, to: State) -> State {
  case engine.signers(from.engine) == engine.signers(to.engine) {
    True -> Nil
    False -> {
      persistent_term_put(
        signers_key(to.name),
        set.from_list(engine.signers(to.engine)),
      )
      to.resubscribe()
    }
  }
  let relays = relay_map(to)
  case relay_map(from) == relays {
    True -> Nil
    False -> to.session_relays(dict.keys(relays) |> list.sort(string.compare))
  }
  to
}

/// token の承認待ちの（署名者, クライアント）。失効・不明なら `None`。
fn pending_target(
  eng: engine.Engine,
  token: String,
  now: Int,
) -> Option(#(String, String)) {
  engine.pending(eng, now)
  |> list.find(fn(entry) { entry.token == token })
  |> option.from_result
  |> option.map(fn(entry) { #(entry.signer, entry.client) })
}

/// 承認済みのセッションにある組ならその組、無ければ `None`（フォームの値を
/// ログに出さないため）。
fn session_target(
  eng: engine.Engine,
  signer: String,
  client: String,
) -> Option(#(String, String)) {
  list.find(engine.sessions(eng), fn(session) {
    session.signer == signer && session.client == client
  })
  |> option.from_result
  |> option.map(fn(_found) { #(signer, client) })
}

/// 失敗 1 件のログ行。値は署名者とクライアントの公開鍵と固定の文言の理由だけで、
/// 承認ページのトークンを含めない。
fn session_failure_line(
  change: SessionChange,
  signer: String,
  client: String,
  reason: String,
) -> String {
  let verb = case change {
    Approval -> "approve the connection of"
    Denial -> "deny the connection of"
    Revocation -> "revoke the session of"
    PermissionsUpdate -> "update the permissions of the session of"
    SessionOpening -> "open the session of"
    PendingRecording -> "record the pending connection of"
    SessionClosing -> "close the session of"
    SessionUse -> "record the use of the session of"
  }
  "failed to "
  <> verb
  <> " client "
  <> client
  <> " to signer "
  <> signer
  <> ": "
  <> reason
}

/// 対象がメモリにあるときだけ、失敗 1 件を `log.Warning` で出す。フォームの値を
/// そのままログに渡さないため、対象が無ければ黙る。
fn log_session_failure(
  change: SessionChange,
  target: Option(#(String, String)),
  reason: String,
) -> Nil {
  case target {
    Some(#(signer, client)) ->
      log.write(
        log.Warning,
        log_prefix,
        session_failure_line(change, signer, client, reason),
      )
    None -> Nil
  }
}

/// セッションと承認待ちの書き込み 1 件を行い、失敗ならログを出す。`MaybeWritten`
/// なら、読み込み済みのときは読み直しに移った状態を、読み込めていないときは状態を
/// そのまま返す（`Loading` で届くのは NIP-46 の書き込みだけで、未処理の読み込みが
/// 同じ保証を持つ）。成功ではログを出さない（管理 UI の変更の成功の行は管理 UI が
/// 出し、NIP-46 の書き込みの成功は行を出さない）。
fn write_session_change(
  state: State,
  change: SessionChange,
  target: Option(#(String, String)),
  write: engine.Write,
) -> #(State, Result(Nil, WriteFailure)) {
  let written = state.settings.store.write(write)
  case written {
    Ok(Nil) -> #(state, written)
    // セッションと承認待ちの書き込みでは作られないが、書き込まれていない失敗である。
    Error(NotWritten(reason)) | Error(AlreadyStored(reason)) -> {
      log_session_failure(change, target, reason)
      #(state, written)
    }
    Error(MaybeWritten(reason)) -> {
      log_session_failure(
        change,
        target,
        reason <> reloading_after_unconfirmed_write,
      )
      case state.accounts {
        Ready -> #(reload(state), written)
        Loading(..) -> #(state, written)
      }
    }
  }
}

/// セッションと承認待ちの書き込みの失敗を、管理 UI が応答に使う `SessionFailure`
/// の区分に写す。`NotWritten`、`AlreadyStored` は書き込まれていないことが確定した
/// 失敗、`MaybeWritten` は結果が曖昧な失敗である。
fn session_write_failure(failure: WriteFailure) -> SessionFailure {
  case failure {
    NotWritten(reason) | AlreadyStored(reason) -> SessionNotApplied(reason)
    MaybeWritten(_reason) -> SessionMaybeApplied(StoreDidNotConfirm)
  }
}

/// `handle_event` の `Persist` の書き込みの種類と、失敗のログに出す
/// （署名者, クライアント）。組は `Write` の値から取る（`connect` の書き込みの前は
/// 組がメモリに無いので `session_target` で引かない）。`handle_event` が載せるのは
/// `InsertSession`、`InsertPending`、`DeleteSession`、`TouchSession` だけで、残りは
/// 管理 UI と同じ区分に写す。承認待ちの token は返さない。
fn incoming_write_change(
  write: engine.Write,
) -> #(SessionChange, Option(#(String, String))) {
  case write {
    engine.InsertSession(session:, ..) -> #(
      SessionOpening,
      Some(#(session.signer, session.client)),
    )
    engine.TouchSession(session:) -> #(
      SessionUse,
      Some(#(session.signer, session.client)),
    )
    engine.UpdateSessionPerms(session:) -> #(
      PermissionsUpdate,
      Some(#(session.signer, session.client)),
    )
    engine.InsertPending(pending:, ..) -> #(
      PendingRecording,
      Some(#(pending.signer, pending.client)),
    )
    engine.DeleteSession(signer:, client:) -> #(
      SessionClosing,
      Some(#(signer, client)),
    )
    engine.ApprovePending(session:, ..) -> #(
      Approval,
      Some(#(session.signer, session.client)),
    )
    engine.DeletePending(..) -> #(Denial, None)
  }
}

/// 読み込み済みのときだけエンジンで承認・拒否し、書き込みが成功したときだけ応答を
/// 発行して反映する。読み込み前は状態を変えずに `SessionNotReady` を返す。対象が
/// 無ければ `SessionNotFound`、書き込みの失敗は `session_write_failure` が
/// `SessionFailure` に写す（`MaybeWritten` の後は、`write_session_change` が返した
/// 読み直し後の状態で続ける。承認の `MaybeWritten` の後は、読み直しの後にも `ack` を
/// 送らない）。
fn apply_decision(
  state: State,
  reply: Subject(Result(Nil, SessionFailure)),
  change: SessionChange,
  token: String,
  decide: fn(engine.Engine, String, Int) ->
    Result(#(engine.Engine, Event, engine.Write), String),
) -> actor.Next(State, Msg) {
  let now = time.now_seconds()
  let target = pending_target(state.engine, token, now)
  case state.accounts {
    Loading(..) -> {
      log_session_failure(change, target, accounts_not_loaded)
      process.send(reply, Error(SessionNotReady(accounts_not_loaded)))
      actor.continue(state)
    }
    Ready ->
      case decide(state.engine, token, now) {
        Error(reason) -> {
          process.send(reply, Error(SessionNotFound(reason)))
          actor.continue(state)
        }
        Ok(#(next, response, write)) ->
          apply_session_write(
            state,
            reply,
            change,
            target,
            next,
            response,
            write,
          )
      }
  }
}

/// 読み込み済みのときだけエンジンで（署名者, クライアント）のセッションを開き、
/// 書き込みが成功したときだけ応答を発行する。読み込み前は `SessionNotReady`、
/// 署名者が登録されていなければ `SessionNotFound`、書き込みの失敗は
/// `session_write_failure` が `SessionFailure` に写す。
fn open_client_session_for(
  state: State,
  reply: Subject(Result(Nil, SessionFailure)),
  signer: String,
  client: String,
  perms: String,
  relays: List(String),
  secret: String,
) -> actor.Next(State, Msg) {
  case state.accounts {
    Loading(..) -> {
      log_session_failure(
        SessionOpening,
        session_target(state.engine, signer, client),
        accounts_not_loaded,
      )
      process.send(reply, Error(SessionNotReady(accounts_not_loaded)))
      actor.continue(state)
    }
    Ready ->
      case
        engine.open_client_session(
          state.engine,
          signer,
          client,
          perms,
          relays,
          secret,
          random.hex(token_bytes),
          time.now_seconds(),
        )
      {
        Error(reason) -> {
          process.send(reply, Error(SessionNotFound(reason)))
          actor.continue(state)
        }
        Ok(#(next, response, write)) ->
          apply_session_write(
            state,
            reply,
            SessionOpening,
            Some(#(signer, client)),
            next,
            response,
            write,
          )
      }
  }
}

/// 書き込みが成功したときだけ応答を発行し、成功を返す。失敗は
/// `session_write_failure` に写す。
fn apply_session_write(
  state: State,
  reply: Subject(Result(Nil, SessionFailure)),
  change: SessionChange,
  target: Option(#(String, String)),
  next: engine.Engine,
  response: Event,
  write: engine.Write,
) -> actor.Next(State, Msg) {
  let #(written_state, outcome) =
    write_session_change(state, change, target, write)
  case outcome {
    Ok(Nil) -> {
      let published =
        publish(
          written_state,
          response,
          False,
          response_session_relays([next], response),
        )
      process.send(reply, Ok(Nil))
      actor.continue(transition(state, State(..published, engine: next)))
    }
    Error(failure) -> {
      process.send(reply, Error(session_write_failure(failure)))
      actor.continue(written_state)
    }
  }
}

/// 読み込み済みのときだけエンジンで取り消し、書き込みが成功したときだけ状態から
/// セッションを消す。読み込み前は `SessionNotReady`、読み込み済みで承認済みでない
/// 組なら `SessionNotFound`、書き込みの失敗は `session_write_failure` が
/// `SessionFailure` に写す。
fn revoke_session(
  state: State,
  reply: Subject(Result(Nil, SessionFailure)),
  signer: String,
  client: String,
) -> actor.Next(State, Msg) {
  let target = session_target(state.engine, signer, client)
  case state.accounts {
    Loading(..) -> {
      log_session_failure(Revocation, target, accounts_not_loaded)
      process.send(reply, Error(SessionNotReady(accounts_not_loaded)))
      actor.continue(state)
    }
    Ready ->
      case engine.revoke(state.engine, signer, client) {
        Error(Nil) -> {
          process.send(reply, Error(SessionNotFound(session_not_approved)))
          actor.continue(state)
        }
        Ok(#(next, write)) -> {
          let #(written_state, outcome) =
            write_session_change(state, Revocation, target, write)
          case outcome {
            Ok(Nil) -> {
              process.send(reply, Ok(Nil))
              actor.continue(transition(
                state,
                State(..written_state, engine: next),
              ))
            }
            Error(failure) -> {
              process.send(reply, Error(session_write_failure(failure)))
              actor.continue(written_state)
            }
          }
        }
      }
  }
}

/// 読み込み済みのときだけエンジンで権限を差し替え、書き込みが成功したときだけ
/// 状態に反映する。読み込み前は `SessionNotReady`、読み込み済みで承認済みでない
/// 組なら `SessionNotFound`、書き込みの失敗は `session_write_failure` が
/// `SessionFailure` に写す。
fn update_session_perms(
  state: State,
  reply: Subject(Result(Nil, SessionFailure)),
  signer: String,
  client: String,
  perms: String,
) -> actor.Next(State, Msg) {
  let target = session_target(state.engine, signer, client)
  case state.accounts {
    Loading(..) -> {
      log_session_failure(PermissionsUpdate, target, accounts_not_loaded)
      process.send(reply, Error(SessionNotReady(accounts_not_loaded)))
      actor.continue(state)
    }
    Ready ->
      case engine.set_perms(state.engine, signer, client, perms) {
        Error(Nil) -> {
          process.send(reply, Error(SessionNotFound(session_not_approved)))
          actor.continue(state)
        }
        Ok(#(next, write)) -> {
          let #(written_state, outcome) =
            write_session_change(state, PermissionsUpdate, target, write)
          case outcome {
            Ok(Nil) -> {
              process.send(reply, Ok(Nil))
              actor.continue(transition(
                state,
                State(..written_state, engine: next),
              ))
            }
            Error(failure) -> {
              process.send(reply, Error(session_write_failure(failure)))
              actor.continue(written_state)
            }
          }
        }
      }
  }
}

/// 応答イベントを、基本の接続と、応答先のセッションのリレー（`session_relays`）の
/// 接続へ発行する（`response_relays`）。セッションの外の応答
/// （`outside_session` が真）は、`rate-limited:` を返して止めているリレーを
/// 飛ばし（`recipients`）、飛ばした件数を間引いてログに出す。出せる接続が 1 本も
/// 生きていなければ送る先が無いので、応答を落としたことをログに残す
/// （クライアントは接続が戻ったあとの再送で回復する）。送った先があれば、
/// 送った先を `deliveries` に記録する。
fn publish(
  state: State,
  response: Event,
  outside_session: Bool,
  session_relays: List(String),
) -> State {
  let relay_urls =
    state.publishers
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(relay_url, Publisher(scope:, ..)) = entry
      #(relay_url, scope)
    })
    |> response_relays(session_relays)
  case relay_urls {
    [] -> {
      log.write(
        log.Warning,
        log_prefix,
        "no live relay connection; response dropped",
      )
      state
    }
    _ -> {
      let now = time.now_seconds()
      let #(pauses, sent, lines) =
        recipients(state.pauses, relay_urls, outside_session, now)
      list.each(lines, log.write(log.Notice, log_prefix, _))
      dict.each(dict.take(state.publishers, sent), fn(_relay_url, publisher) {
        publisher.publish(response)
      })
      let deliveries = case sent {
        [] -> state.deliveries
        _ -> track(state.deliveries, response, sent, now)
      }
      State(..state, deliveries: deliveries, pauses: pauses)
    }
  }
}

/// `persistent_term:put/2` の型を付けた薄いラッパー。
@external(erlang, "persistent_term", "put")
fn persistent_term_put(key: #(Atom, Name(Msg)), value: Set(String)) -> Atom

/// `persistent_term:get/2` の型を付けた薄いラッパー。既定値の版を使うので、
/// キーが無いときも `badarg` で落ちない。
@external(erlang, "persistent_term", "get")
fn persistent_term_get(
  key: #(Atom, Name(Msg)),
  default: Set(String),
) -> Set(String)
