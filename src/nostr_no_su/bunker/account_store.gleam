//// バンカーアカウントを Postgres の `bunker_accounts` テーブルに保存する。
////
//// SQL と pog の呼び出しだけを持ち、暗号化と行の検証は `vault` に任せる。nonce の
//// 乱数はこの層で引く。DB へ送るのは暗号文だけで、平文もマスターキーも DB へは
//// 出ない。承認済みのセッション（`bunker_sessions`）と承認待ちの接続要求
//// （`bunker_pending`）も同じ DB に保存し、`load` が同じトランザクションで読む。
//// この 2 表の行には書き込みのたびに `vault.row_mac` の MAC を付け、読み込みでは
//// MAC の合わない行を使わずに `Stored.rejected` に分ける。
////
//// 失敗はすべて `StoreError` の値で返し、呼び出し側のプロセスを落とさない。
//// pog と pgo が投げる例外も、クエリーの実行の入口（`execute`）で値に写す。
//// エラーの説明は値（鍵、secret、ラベル、暗号文）を含まない。Postgres の制約違反の
//// `detail` は `Failing row contains (...)` の形で行の全列を含むので、写すときに
//// 捨てる。
////
//// テーブルの DDL は版つきの移行（`migrations`）として持ち、`load` のたびに
//// `schema_version` に記録された版より新しい移行を適用する。記録された版がこの
//// ビルドより新しければ `SchemaTooNew` を返す。移行は `bunker_accounts` のほかに、
//// 監視の再開点のテーブル（`monitor_resume`）、セッションと承認待ちのテーブル、
//// リレーの一覧（`relays`）、プラグインの再開点（`plugin_resume`）も作る。
////
//// 同じ DB に対して動けるインスタンスは 1 つに限る。`acquire_lock` で advisory lock
//// を確かめ、別のセッションが持っていれば `HeldByAnotherInstance` を返す。

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/result
import nostr_no_su/bunker/vault.{type MasterKey}
import nostr_no_su/crypto/aes_gcm
import nostr_no_su/hex
import pog

/// 接続プールの本数。書き込み手はバンカーアクター 1 つで逐次なので少なく保つ。
/// 1 本だと再接続の間は完全に使えなくなるので 2 本にする。
const pool_size = 2

/// 同じ DB に 1 インスタンスだけを許すための advisory lock の番号。ASCII の
/// `nns`（`nostr-no-su`）を 16 進にした値。
pub const instance_lock_key = 7_237_235

/// ストアの操作の期限。どちらもチェックアウトを要求した時点から数えるので、プールの
/// 接続を待つ時間（期限切れで閉じた接続の再接続を含む）もこの値に含まれる。
pub type Timeouts {
  Timeouts(
    /// 読み込み 1 回（スキーマの移行、テーブルのロック、一覧）全体の期限。
    load_ms: Int,
    /// 書き込み 1 件の期限。
    write_ms: Int,
  )
}

/// 本番の期限。
///
/// 読み込みも書き込みもバンカーアクターの中で行うので、その間は NIP-46 の処理が
/// 待たされる。DB に到達できないときの失敗はどちらもこの値を上限に 2〜3 秒で返る
/// （pgo の待ち行列の設定で決まる）。
///
/// - 読み込み 3000ms：DB が応答しなくなっても、読み込み 1 回の待ちはこの値に収まる
///   （`load` を参照）。署名者の問い合わせの 5000ms に収まり、期限を過ぎた書き込みの
///   残りの実行をロックで待つ余裕を取った値。
/// - 書き込み 1000ms：主キーで 1 行を書く操作は通常ミリ秒の単位で終わる。DB に到達
///   できて遅いときの待ちをこの値で打ち切り、書き込みが積まれても後ろの署名者の
///   問い合わせが収まるようにする。期限を過ぎたとき、クエリーがすでにサーバーに届いて
///   いれば、サーバーはクライアントの切断を検出せずに文を実行し終えてコミットしうる。
///   そのため書き込みの `TimedOut` は「書き込まれたかどうか分からない」を意味する
///   （`may_have_been_written`）。`acquire_lock` の期限もこの値を使う。`load` の前に
///   呼ぶので、ロックと読み込み（3000ms）を合わせても署名者の問い合わせの 5000ms に
///   収まる。
pub const default_timeouts = Timeouts(load_ms: 3000, write_ms: 1000)

/// 主キーの制約名。これに違反した挿入は、同じ公開鍵の登録済みを意味する。
const primary_key_constraint = "bunker_accounts_pkey"

/// `relays.url` の一意制約の名前。これに違反した挿入は、同じ URL の登録済みを
/// 意味する。
const relay_url_constraint = "relays_url_key"

/// アカウントを保存するテーブル。`pubkey` は小文字 16 進に固定し、表記の揺れで
/// 同じ鍵が二重に登録されるのを防ぐ。暗号文の長さの検査は、秘密鍵が
/// 12 + 32 + 16 = 60 バイト、secret が空でない（12 + 1 以上 + 16）ことを表す。
pub const create_accounts_table = "CREATE TABLE IF NOT EXISTS bunker_accounts (
  pubkey text PRIMARY KEY CHECK (pubkey ~ '^[0-9a-f]{64}$'),
  label text NOT NULL DEFAULT '',
  encrypted_privkey bytea NOT NULL CHECK (octet_length(encrypted_privkey) = 60),
  encrypted_secret bytea NOT NULL CHECK (octet_length(encrypted_secret) > 28),
  created_at timestamptz NOT NULL DEFAULT now()
)"

/// 監視の購読の再開点を保存するテーブル。`since` は Unix 秒。書き込みは値を
/// 小さくしない（`dedup/resume_store`）。
pub const create_monitor_resume_table = "CREATE TABLE IF NOT EXISTS monitor_resume (
  relay_url text PRIMARY KEY,
  since bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
)"

/// 承認済みのセッションを保存するテーブル。主キーは（signer, client）。`perms` は
/// `connect` が要求した値をそのまま保存し、空文字列は要求なしを表す。`signer` は
/// `bunker_accounts(pubkey)` を `ON DELETE CASCADE` で参照するので、アカウントの
/// 削除でその署名者のセッションも消える。時刻は Unix 秒。新しい組では
/// `created_at` と `last_used_at` が同じ値で入る（`engine` の `new_session`）。
/// `last_used_at` は `touch_session` で進める。行の MAC の列 `mac` は版 6 の移行
/// （`add_row_macs`）で足す。URI のリレーの列 `relays` は版 7 の移行
/// （`add_session_relays`）で足す。
pub const create_sessions_table = "CREATE TABLE IF NOT EXISTS bunker_sessions (
  signer text NOT NULL REFERENCES bunker_accounts (pubkey) ON DELETE CASCADE,
  client text NOT NULL,
  perms text NOT NULL,
  created_at bigint NOT NULL,
  last_used_at bigint NOT NULL,
  PRIMARY KEY (signer, client)
)"

/// 承認待ちの接続要求を保存するテーブル。`token` が主キーで、承認ページの URL に
/// 入る値である。`signer` は `bunker_accounts(pubkey)` を `ON DELETE CASCADE` で
/// 参照するので、アカウントの削除でその署名者の承認待ちも消える。時刻は
/// Unix 秒。長さの `CHECK` は置かない。行の MAC の列 `mac` は版 6 の移行
/// （`add_row_macs`）で足す。
pub const create_pending_table = "CREATE TABLE IF NOT EXISTS bunker_pending (
  token text PRIMARY KEY,
  signer text NOT NULL REFERENCES bunker_accounts (pubkey) ON DELETE CASCADE,
  client text NOT NULL,
  request_id text NOT NULL,
  perms text NOT NULL,
  secret_mismatch boolean NOT NULL,
  created_at bigint NOT NULL
)"

/// 監視とバンカーのリレーを保存するテーブル。`observe` は Gleam 側で
/// `relay_list.Roles.monitor` に写す。順は `id`。
pub const create_relays_table = "CREATE TABLE IF NOT EXISTS relays (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  url text NOT NULL CONSTRAINT relays_url_key UNIQUE,
  observe boolean NOT NULL,
  bunker boolean NOT NULL
)"

/// プラグインごとの再開点を保存するテーブル。`since` は Unix 秒。主キーは
/// プラグイン名（`plugin_name/0` の値）。書き込みは値を小さくしない
/// （`plugin_resume_store`）。
pub const create_plugin_resume_table = "CREATE TABLE IF NOT EXISTS plugin_resume (
  plugin text PRIMARY KEY,
  since bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
)"

/// 版 6 の移行。既存のセッションと承認待ちの行を消してから、行の MAC の列を
/// 足す。版 5 までの行は MAC を持たないので、残すと読み込みで使えない行になる。
/// 消したセッションのクライアントは接続と承認をやり直す。`DELETE FROM` は何度
/// 実行してもよく、表が空なので `NOT NULL` の列を既定値なしで足せる。
const add_row_macs = [
  "DELETE FROM bunker_pending",
  "DELETE FROM bunker_sessions",
  "ALTER TABLE bunker_sessions ADD COLUMN IF NOT EXISTS mac bytea NOT NULL",
  "ALTER TABLE bunker_pending ADD COLUMN IF NOT EXISTS mac bytea NOT NULL",
]

/// 版 7 の移行。セッションの行に、`nostrconnect://` の URI に現れたリレーの
/// 一覧の列を足す。既存の行は空の一覧になり、空の一覧は MAC の入力に含めない
/// （`vault.mac_input`）ので、版 6 で付けた MAC のまま読める。
const add_session_relays = "ALTER TABLE bunker_sessions ADD COLUMN IF NOT EXISTS relays text[] NOT NULL DEFAULT '{}'"

/// スキーマの版 1 つぶんの移行。`statements` を順に実行した後に `version` を
/// `schema_version` に記録する。
pub type Migration {
  Migration(version: Int, statements: List(String))
}

/// 本体のスキーマの移行。版は 1 から欠番なく昇順に並べ、足すときは末尾に置く。
///
/// 移行の文は何度実行してもよい形（`IF NOT EXISTS` か、表を空にする
/// `DELETE FROM`）で書く。途中で失敗した移行は版が記録されないので、次の
/// 読み込みで頭から実行し直される。この 2 つの形で書けない文を足すときは、
/// `migration_statements_can_be_re_run_test` の条件を見直す。
pub const migrations = [
  Migration(version: 1, statements: [create_accounts_table]),
  Migration(version: 2, statements: [create_monitor_resume_table]),
  Migration(
    version: 3,
    statements: [create_sessions_table, create_pending_table],
  ),
  Migration(version: 4, statements: [create_relays_table]),
  Migration(version: 5, statements: [create_plugin_resume_table]),
  Migration(version: 6, statements: add_row_macs),
  Migration(version: 7, statements: [add_session_relays]),
]

/// 適用した移行の版を 1 行ずつ記録するテーブル。最大の `version` を現在の版とする。
/// `pub` にしているのは、版 2 の DB をテストで再現するため（`create_accounts_table`、
/// `create_monitor_resume_table` と同じ扱い）。
pub const create_version_table = "CREATE TABLE IF NOT EXISTS schema_version (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
)"

/// 記録された版の読み込み。
const select_versions_sql = "SELECT version FROM schema_version"

/// 版の記録。
const insert_version_sql = "INSERT INTO schema_version (version) VALUES ($1)"

/// 読み込みのトランザクションの中で、ロックの待ちの上限を設定する（ミリ秒）。
/// クライアントが期限で諦めた後に、サーバーのバックエンドがロックを待ち続けないため。
const lock_timeout_sql = "SELECT set_config('lock_timeout', $1, true)"

/// 実行中の書き込み（ROW EXCLUSIVE）の終了を待つためのロック。PostgreSQL は列挙の
/// 順に 1 つずつロックを取るので、書き手の順に合わせる。アカウントの削除
/// （連鎖を含む）は下の 2 表に触る前に `bunker_accounts` の ROW EXCLUSIVE を持つので
/// 先頭に置き、`approve` は `bunker_pending` の DELETE の後に `bunker_sessions` へ
/// INSERT・DELETE するので、その順に並べる。逆にすると、この読み込みが
/// `bunker_sessions` を持って `bunker_pending` を待ち、`approve` が `bunker_sessions`
/// を待つデッドロックになる。
const lock_sql = "LOCK TABLE bunker_accounts, bunker_pending, bunker_sessions IN SHARE MODE"

/// セッション単位の advisory lock を取る（待たない）。
const try_lock_sql = "SELECT pg_try_advisory_lock($1)"

/// 全行の読み込み。表示とテストが安定するよう登録順に並べる。
const select_sql = "SELECT pubkey, label, encrypted_privkey, encrypted_secret
FROM bunker_accounts
ORDER BY created_at, pubkey"

/// 1 行の挿入。
const insert_sql = "INSERT INTO bunker_accounts (pubkey, label, encrypted_privkey, encrypted_secret)
VALUES ($1, $2, $3, $4)"

/// 1 行の削除。
const delete_sql = "DELETE FROM bunker_accounts WHERE pubkey = $1"

/// 接続 secret の差し替え。
const update_secret_sql = "UPDATE bunker_accounts SET encrypted_secret = $2 WHERE pubkey = $1"

/// ラベルの差し替え。
const update_label_sql = "UPDATE bunker_accounts SET label = $2 WHERE pubkey = $1"

/// セッションの一覧。テストの安定のための順。
const select_sessions_sql = "SELECT signer, client, perms, created_at, last_used_at, mac, relays
FROM bunker_sessions
ORDER BY created_at, signer, client"

/// 承認待ちの一覧。テストの安定のための順。
const select_pending_sql = "SELECT token, signer, client, request_id, perms, secret_mismatch, created_at, mac
FROM bunker_pending
ORDER BY created_at, token"

/// セッションの挿入。同じ（signer, client）があれば全列と MAC をこの値で
/// 上書きする。
const insert_session_sql = "INSERT INTO bunker_sessions (signer, client, perms, created_at, last_used_at, mac, relays)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (signer, client) DO UPDATE
SET perms = EXCLUDED.perms, created_at = EXCLUDED.created_at, last_used_at = EXCLUDED.last_used_at, mac = EXCLUDED.mac, relays = EXCLUDED.relays"

/// 最終利用の更新。時刻が進むときだけ、全列と MAC を書き換える。
const touch_session_sql = "UPDATE bunker_sessions SET perms = $3, created_at = $4, last_used_at = $5, mac = $6, relays = $7 WHERE signer = $1 AND client = $2 AND last_used_at < $5"

/// 権限の更新。全列と MAC を書き換える。
const update_session_perms_sql = "UPDATE bunker_sessions SET perms = $3, created_at = $4, last_used_at = $5, mac = $6, relays = $7 WHERE signer = $1 AND client = $2"

/// セッションの削除。
const delete_session_sql = "DELETE FROM bunker_sessions WHERE signer = $1 AND client = $2"

/// 承認待ちの挿入。同じ token があれば何もしない。
const insert_pending_sql = "INSERT INTO bunker_pending (token, signer, client, request_id, perms, secret_mismatch, created_at, mac)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (token) DO NOTHING"

/// 承認待ちの削除。
const delete_pending_sql = "DELETE FROM bunker_pending WHERE token = $1"

/// 承認済みのセッション 1 件。
pub type StoredSession {
  StoredSession(
    /// 署名者の公開鍵（16 進、小文字）。
    signer: String,
    /// クライアントの公開鍵（16 進、小文字）。
    client: String,
    /// 要求された権限。空文字列は要求なし。
    perms: String,
    /// 作成した Unix 秒。
    created_at: Int,
    /// 最後に使った Unix 秒。新しい組では `created_at` と同じ値。
    last_used_at: Int,
    /// `nostrconnect://` の URI に現れたリレー（URI の順）。`bunker://` の
    /// `connect` と承認で開いたセッションは空。
    relays: List(String),
  )
}

/// 承認待ちの接続要求 1 件。
pub type StoredPending {
  StoredPending(
    /// 承認ページの URL に入るトークン。
    token: String,
    /// 署名者の公開鍵（16 進、小文字）。
    signer: String,
    /// クライアントの公開鍵（16 進、小文字）。
    client: String,
    /// 元の `connect` リクエストの id。
    request_id: String,
    /// 要求された権限。空文字列は要求なし。
    perms: String,
    /// secret が一致しなかったか。
    secret_mismatch: Bool,
    /// 作成した Unix 秒。
    created_at: Int,
  )
}

/// `load` が 1 つのトランザクションで読み込んだ全体。
pub type Stored {
  Stored(
    /// 復号できたアカウントと、復号できずに飛ばした行。
    accounts: vault.Loaded,
    /// 承認済みのセッション（`created_at`、`signer`、`client` の順）。
    sessions: List(StoredSession),
    /// 承認待ちの接続要求（`created_at`、`token` の順）。
    pending: List(StoredPending),
    /// MAC の合わない行（セッション、承認待ちの順）。どちらも元の行の順序を保つ。
    rejected: List(vault.MacRow),
  )
}

/// ストア操作の失敗。説明は値（鍵、secret、ラベル、暗号文）を含まない。
pub type StoreError {
  /// DB に到達できない、あるいは接続を拒否された（認証の失敗や存在しないデータベース
  /// 名、プールのプロセスが無いことを含む）。プールから接続を得られなかったので、
  /// クエリーは送られていない。
  Unavailable
  /// 期限までに応答が無かった、あるいはクエリーの途中で接続が切れた。クエリーが
  /// サーバーに届いていれば、書き込みはコミットされていることがある。
  TimedOut
  /// `pog.execute` が例外を投げた（pog が写せないエラーの項や、pgo の中の例外）。
  /// `exception` は例外のクラスと発生箇所（例: `error in pog_ffi:convert_error/1`）
  /// だけで、理由の項（値を含みうる）は含まない。クエリーを送った後にも起きうるので、
  /// 書き込みはコミットされていることがある。
  Raised(exception: String)
  /// 同じ pubkey がすでに登録されている。
  AlreadyRegistered
  /// 指定した pubkey が登録されていない。
  NotRegistered
  /// 同じ URL のリレーがすでに登録されている。
  RelayAlreadyRegistered
  /// 指定した id のリレーが登録されていない。
  RelayNotRegistered
  /// それ以外のクエリーの失敗。Postgres のエラー名など、値を含まない説明だけを
  /// 持つ。
  QueryFailed(reason: String)
  /// DB に記録されたスキーマの版（`found`）が、このビルドの移行の最新の版
  /// （`supported`）より新しい。再試行しても変わらない。
  SchemaTooNew(found: Int, supported: Int)
  /// 同じ DB の advisory lock `key` を別のセッションが持っている。別のインスタンス
  /// が動いているので、再試行しても変わらない。
  HeldByAnotherInstance(key: Int)
}

/// 期限つきのトランザクションを実行できなかった理由。
type TransactionFailure {
  /// プールから接続を得られなかった。
  CheckoutFailed
  /// 期限で接続が閉じられた、あるいは途中で接続が切れた。
  Interrupted
  /// それ以外の例外（プールが無い、`run` の中の panic など）。
  Failed
}

/// `DATABASE_URL` から接続プールの設定を作る。理由の文字列は URL（パスワードを
/// 含みうる）を含まない。
pub fn pool_config(
  name: Name(pog.Message),
  database_url: String,
) -> Result(pog.Config, String) {
  pog.url_config(name, database_url)
  |> result.map(pog.pool_size(_, pool_size))
  |> result.replace_error("DATABASE_URL is not a valid postgres URL")
}

/// ロック専用の 1 本のプールの設定。本数を 1 にするのは、ロックを取った接続と次に
/// 確かめる接続を同じにするためである。
pub fn lock_pool_config(
  name: Name(pog.Message),
  pool: pog.Config,
) -> pog.Config {
  pog.Config(..pool, pool_name: name, pool_size: 1)
}

/// 版 `current` の DB に適用する移行を、`migrations` の並びのまま返す。`current` が
/// `migrations` の最新の版より新しければ `SchemaTooNew` を返す。
pub fn pending_migrations(
  migrations: List(Migration),
  current: Int,
) -> Result(List(Migration), StoreError) {
  let supported =
    list.fold(migrations, 0, fn(latest, migration) {
      int.max(latest, migration.version)
    })
  case current > supported {
    True -> Error(SchemaTooNew(found: current, supported: supported))
    False ->
      Ok(list.filter(migrations, fn(migration) { migration.version > current }))
  }
}

/// セッション単位の advisory lock `key` を `db` のセッションで取る。同じセッション
/// がすでに持っていれば再入で成功し、解放はしない（セッションの終わりで外れる）。
/// 別のセッションが持っていれば `HeldByAnotherInstance(key)`。`db` は 1 本のプール
/// （`lock_pool_config`）で、トランザクションの外で呼ぶ（`pgo:query/3` はトランザク
/// ション中に別のプールを指すと例外を投げる）。
pub fn acquire_lock(
  db: pog.Connection,
  key: Int,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  use returned <- result.try(
    pog.query(try_lock_sql)
    |> pog.parameter(pog.int(key))
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.timeout(timeouts.write_ms)
    |> execute(db),
  )
  case returned.rows {
    [True] -> Ok(Nil)
    [False] -> Error(HeldByAnotherInstance(key))
    _ -> Error(QueryFailed("unexpected lock result"))
  }
}

/// スキーマを `migrations` の最新の版にする。版のテーブルを用意し、記録された版より
/// 新しい移行の文を順に実行して、移行ごとに版を記録する。`load` のトランザクションの
/// 中で呼ぶので、文の期限は `pool_transaction` の期限が効く。
fn ensure_schema(db: pog.Connection) -> Result(Nil, StoreError) {
  use _created <- result.try(pog.query(create_version_table) |> execute(db))
  use recorded <- result.try(
    pog.query(select_versions_sql)
    |> pog.returning(decode.at([0], decode.int))
    |> execute(db),
  )
  use pending <- result.try(pending_migrations(
    migrations,
    list.fold(recorded.rows, 0, int.max),
  ))
  use migration <- list.try_each(pending)
  use Nil <- result.try(
    list.try_each(migration.statements, fn(statement) {
      pog.query(statement) |> execute(db)
    }),
  )
  pog.query(insert_version_sql)
  |> pog.parameter(pog.int(migration.version))
  |> execute(db)
}

/// プールの接続 1 本で `run` をトランザクションとして実行し、`timeout_ms` の期限で
/// 打ち切る（期限は pgo のプールが接続を閉じることで効くので、DB が応答しなくなっても
/// 待ちはこの値に収まる）。`run` の中で同じプールへ送るクエリーはこの接続で実行
/// される。`run` が `Error` を返したらロールバックし、その値をそのまま返す
/// （`pool_transaction`）。期限で打ち切られたら `TimedOut`、接続を得られなければ
/// `Unavailable`、それ以外の例外（プールが無い、`run` の中の panic など）は
/// `QueryFailed("the transaction failed")` を返す。`pool` を名前で受け取るのは、
/// 期限つきのトランザクションをプールの名前で開くためである。
pub fn transaction(
  pool: Name(pog.Message),
  timeout_ms: Int,
  run: fn(pog.Connection) -> Result(a, StoreError),
) -> Result(a, StoreError) {
  let db = pog.named_connection(pool)
  pool_transaction(pool, timeout_ms, fn() { run(db) })
  |> result.map_error(fn(failure) {
    case failure {
      CheckoutFailed -> Unavailable
      Interrupted -> TimedOut
      Failed -> QueryFailed("the transaction failed")
    }
  })
  |> result.flatten
}

/// スキーマを最新の版に移行してから、アカウント、承認済みのセッション、承認待ちの
/// 接続要求を読み込む。アカウントは復号できた行と飛ばした行に分ける
/// （`vault.open_rows`）。セッションと承認待ちは行の MAC を `key` で検証し、
/// 合わない行（列を書き換えた行、別の行の MAC を移した行、空の MAC の行）は
/// `sessions` と `pending` に入れずに `rejected` に分ける。3 つのうちどれかの
/// 読み込みが `Error` なら全体を `Error` にする。`transaction` の中で呼ぶ
/// （`load`）。`nostr_no_su.load_snapshot` が同じトランザクションで
/// `relay_store.list` も読むために公開する。
///
/// 一覧を読む前に `LOCK TABLE bunker_accounts, bunker_pending, bunker_sessions
/// IN SHARE MODE` を取る（`lock_sql`）。SHARE は実行中の `INSERT` / `UPDATE` /
/// `DELETE` が持つ ROW EXCLUSIVE と衝突するので、期限を過ぎた後もサーバー側で実行を
/// 続けている書き込みがあれば、その終了（コミットかロールバック）を待ってから読む。
/// READ COMMITTED の `SELECT` は文ごとのスナップショットで読むので、待った書き込みの
/// 結果が見える。起動時の読み込みも同じ読み方にする。前のアクターが書き込みの途中で
/// 終了した後に再起動したアクターが、その書き込みより先に読むのを防ぐためである。
/// `relays` はここではロックしない。このロックはバンカー自身の期限切れの書き込みを
/// 待つためのもので、`relays` の書き手はバンカーではないためである。
///
/// **残る窓**：書き込みの文がサーバーに届いてテーブルのロックを取るより先に、この
/// ロックが取られた場合（クライアントの期限の直前に送った文が、まだ転送中か
/// サーバーのプロセスの実行待ちである場合）は、書き込みはこの読み込みの後に実行され、
/// 読み込みには見えない。ローカルの Postgres で期限切れの挿入を起こした測定では、
/// コミットされた 704 件のうち読み込みに見えなかったものは 0 件だった（ロックを取らない
/// 読み込みでは 712 件中 77 件）。窓の長さは、期限の時点での転送とサーバーの
/// スケジューリングの遅れで決まる。
pub fn load_within(
  db: pog.Connection,
  key: MasterKey,
  timeouts: Timeouts,
) -> Result(Stored, StoreError) {
  use _set <- result.try(
    pog.query(lock_timeout_sql)
    |> pog.parameter(pog.text(int.to_string(timeouts.load_ms)))
    |> execute(db),
  )
  use Nil <- result.try(ensure_schema(db))
  use _locked <- result.try(pog.query(lock_sql) |> execute(db))
  use accounts <- result.try(
    pog.query(select_sql)
    |> pog.returning(row_decoder())
    |> execute(db),
  )
  use sessions <- result.try(
    pog.query(select_sessions_sql)
    |> pog.returning(session_decoder())
    |> execute(db),
  )
  use pending <- result.try(
    pog.query(select_pending_sql)
    |> pog.returning(pending_decoder())
    |> execute(db),
  )
  let #(sessions_list, rejected_sessions) =
    split_by_mac(key, sessions.rows, session_mac_row)
  let #(pending_list, rejected_pending) =
    split_by_mac(key, pending.rows, pending_mac_row)
  Ok(Stored(
    accounts: vault.open_rows(key, accounts.rows),
    sessions: sessions_list,
    pending: pending_list,
    rejected: list.append(rejected_sessions, rejected_pending),
  ))
}

/// `load_within` を 1 本のトランザクションで行い、`timeouts.load_ms` の期限で
/// 打ち切る（`transaction`）。移行の文とロックの待ちもサーバー側で同じ値に抑える。
/// トランザクションの中のクエリーで `pog.execute` が例外を投げたら、発生箇所を持つ
/// `Raised` を返す（`execute`）。記録された版がこのビルドより新しければ
/// `SchemaTooNew` を返す（`ensure_schema`）。
pub fn load(
  pool: Name(pog.Message),
  key: MasterKey,
  timeouts: Timeouts,
) -> Result(Stored, StoreError) {
  transaction(pool, timeouts.load_ms, load_within(_, key, timeouts))
}

/// アカウントを 1 件追加する。
pub fn insert(
  db: pog.Connection,
  key: MasterKey,
  entry: vault.StoredAccount,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  // ストアは 12 バイトの nonce しか作らず、マスターキーは 32 バイトであることが
  // 構築時に保証されているので、暗号化は失敗しない。失敗しても表示されるのは
  // Error(Nil) と下の文言だけで、鍵も平文も含まない。
  let assert Ok(row) =
    vault.seal_row(key, entry, random_nonce(), random_nonce())
    as "a 12-byte random nonce is always accepted"
  pog.query(insert_sql)
  |> pog.parameter(pog.text(row.pubkey))
  |> pog.parameter(pog.text(row.label))
  |> pog.parameter(pog.bytea(row.encrypted_privkey))
  |> pog.parameter(pog.bytea(row.encrypted_secret))
  |> pog.timeout(timeouts.write_ms)
  |> execute(db)
  |> result.replace(Nil)
}

/// アカウントを 1 件削除する。
pub fn delete(
  db: pog.Connection,
  pubkey: String,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(delete_sql)
  |> pog.parameter(pog.text(pubkey))
  |> execute_on_one_row(db, timeouts, NotRegistered)
}

/// 接続 secret を差し替える。`pubkey` が 16 進として読めないときは、列の制約上
/// その行は存在しえないので `NotRegistered` にする。
pub fn update_secret(
  db: pog.Connection,
  key: MasterKey,
  pubkey: String,
  secret: String,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  use pubkey_bytes <- result.try(
    hex.decode(pubkey) |> result.replace_error(NotRegistered),
  )
  // `insert` と同じ理由で、暗号化は失敗しない。
  let assert Ok(encrypted_secret) =
    vault.seal(
      key,
      vault.ConnectionSecret,
      pubkey_bytes,
      bit_array.from_string(secret),
      random_nonce(),
    )
    as "a 12-byte random nonce is always accepted"
  pog.query(update_secret_sql)
  |> pog.parameter(pog.text(pubkey))
  |> pog.parameter(pog.bytea(encrypted_secret))
  |> execute_on_one_row(db, timeouts, NotRegistered)
}

/// ラベルを差し替える。
pub fn update_label(
  db: pog.Connection,
  pubkey: String,
  label: String,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(update_label_sql)
  |> pog.parameter(pog.text(pubkey))
  |> pog.parameter(pog.text(label))
  |> execute_on_one_row(db, timeouts, NotRegistered)
}

/// セッション `session` を 1 件追加する。同じ（signer, client）の組がすでに
/// あれば、全列と MAC をこの値で上書きする。MAC の合わない行が主キーを塞いで
/// 正しい承認が保存されなくなるのを防ぐためで、2 インスタンスが並ぶ窓で両方が
/// 同じ値を挿す場合も吸収する。
pub fn insert_session(
  db: pog.Connection,
  key: MasterKey,
  timeouts: Timeouts,
  session session: StoredSession,
) -> Result(Nil, StoreError) {
  write_session_row(db, key, timeouts, insert_session_sql, session)
}

/// セッションの最終利用を `session.last_used_at` に進め、行の全列と MAC を
/// `session` の値にする。行が無いか、すでに `session.last_used_at` 以上なら
/// 何もせず `Ok`（2 インスタンスが並ぶ窓で後退させない）。
pub fn touch_session(
  db: pog.Connection,
  key: MasterKey,
  timeouts: Timeouts,
  session session: StoredSession,
) -> Result(Nil, StoreError) {
  write_session_row(db, key, timeouts, touch_session_sql, session)
}

/// セッションの権限を `session.perms` に差し替え、行の全列と MAC を `session` の
/// 値にする。行が無ければ何もせず `Ok`。
pub fn update_session_perms(
  db: pog.Connection,
  key: MasterKey,
  timeouts: Timeouts,
  session session: StoredSession,
) -> Result(Nil, StoreError) {
  write_session_row(db, key, timeouts, update_session_perms_sql, session)
}

/// `sql`（`insert_session_sql`、`touch_session_sql`、`update_session_perms_sql`
/// のどれか）で、（signer, client）の行の全列と MAC を `session` の値にする。
fn write_session_row(
  db: pog.Connection,
  key: MasterKey,
  timeouts: Timeouts,
  sql: String,
  session: StoredSession,
) -> Result(Nil, StoreError) {
  pog.query(sql)
  |> pog.parameter(pog.text(session.signer))
  |> pog.parameter(pog.text(session.client))
  |> pog.parameter(pog.text(session.perms))
  |> pog.parameter(pog.int(session.created_at))
  |> pog.parameter(pog.int(session.last_used_at))
  |> pog.parameter(pog.bytea(vault.row_mac(key, session_mac_row(session))))
  |> pog.parameter(pog.array(pog.text, session.relays))
  |> pog.timeout(timeouts.write_ms)
  |> execute(db)
  |> result.replace(Nil)
}

/// セッションを 1 件取り消す。行が無くても `Ok`。
pub fn delete_session(
  db: pog.Connection,
  timeouts: Timeouts,
  signer signer: String,
  client client: String,
) -> Result(Nil, StoreError) {
  pog.query(delete_session_sql)
  |> pog.parameter(pog.text(signer))
  |> pog.parameter(pog.text(client))
  |> pog.timeout(timeouts.write_ms)
  |> execute(db)
  |> result.replace(Nil)
}

/// `pairs` の（signer, client）の組をすべて `delete_session` で消す。行が無くても
/// `Ok`。
fn delete_sessions(
  db: pog.Connection,
  timeouts: Timeouts,
  pairs: List(#(String, String)),
) -> Result(Nil, StoreError) {
  list.try_each(pairs, fn(pair) {
    delete_session(db, timeouts, signer: pair.0, client: pair.1)
  })
}

/// セッション `session` を 1 件追加し（同じ組があれば上書きする。
/// `insert_session`）、`evicted` の組を消す。1 トランザクションで行うので、
/// 挿入だけが残ることは無い。
pub fn insert_session_evicting(
  pool: Name(pog.Message),
  key: MasterKey,
  timeouts: Timeouts,
  session session: StoredSession,
  evicted evicted: List(#(String, String)),
) -> Result(Nil, StoreError) {
  transaction(pool, timeouts.write_ms, fn(db) {
    use Nil <- result.try(insert_session(db, key, timeouts, session: session))
    delete_sessions(db, timeouts, evicted)
  })
}

/// 承認待ちの接続要求を 1 件追加する。同じ `token` がすでにあれば何もしない
/// （2 インスタンスが並ぶ窓を吸収する）。
pub fn insert_pending(
  db: pog.Connection,
  key: MasterKey,
  pending: StoredPending,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(insert_pending_sql)
  |> pog.parameter(pog.text(pending.token))
  |> pog.parameter(pog.text(pending.signer))
  |> pog.parameter(pog.text(pending.client))
  |> pog.parameter(pog.text(pending.request_id))
  |> pog.parameter(pog.text(pending.perms))
  |> pog.parameter(pog.bool(pending.secret_mismatch))
  |> pog.parameter(pog.int(pending.created_at))
  |> pog.parameter(pog.bytea(vault.row_mac(key, pending_mac_row(pending))))
  |> pog.timeout(timeouts.write_ms)
  |> execute(db)
  |> result.replace(Nil)
}

/// 承認待ちの接続要求を 1 件取り除く。行が無くても `Ok`。
pub fn delete_pending(
  db: pog.Connection,
  timeouts: Timeouts,
  token token: String,
) -> Result(Nil, StoreError) {
  pog.query(delete_pending_sql)
  |> pog.parameter(pog.text(token))
  |> pog.timeout(timeouts.write_ms)
  |> execute(db)
  |> result.replace(Nil)
}

/// 承認待ちの接続要求 `token` を承認する。1 トランザクションでその行を消し、
/// セッション `session` を追加し（同じ組があれば上書きする。`insert_session`）、
/// `evicted` の組を消す。承認の値の出どころはエンジンのメモリなので、消した行から
/// 読み返さない。`DELETE … RETURNING` で拾うと、2 インスタンスが並ぶ窓で別の
/// インスタンスが先に消していた場合にセッションを作れなくなるためである。承認待ちの
/// 行が無くても追加する。
pub fn approve(
  pool: Name(pog.Message),
  key: MasterKey,
  timeouts: Timeouts,
  token token: String,
  session session: StoredSession,
  evicted evicted: List(#(String, String)),
) -> Result(Nil, StoreError) {
  transaction(pool, timeouts.write_ms, fn(db) {
    use Nil <- result.try(delete_pending(db, timeouts, token: token))
    use Nil <- result.try(insert_session(db, key, timeouts, session: session))
    delete_sessions(db, timeouts, evicted)
  })
}

/// 同じ組の古い承認待ち `replaced` と、上限で押し出す承認待ち `evicted` を消し、
/// `pending` を登録する。1 トランザクションで行うので、削除だけが残ることは無い。
pub fn insert_pending_replacing(
  pool: Name(pog.Message),
  key: MasterKey,
  timeouts: Timeouts,
  pending pending: StoredPending,
  replaced replaced: List(String),
  evicted evicted: List(String),
) -> Result(Nil, StoreError) {
  transaction(pool, timeouts.write_ms, fn(db) {
    use Nil <- result.try(
      list.try_each(list.append(replaced, evicted), delete_pending(
        db,
        timeouts,
        token: _,
      )),
    )
    insert_pending(db, key, pending, timeouts)
  })
}

/// 削除の結果で、行が無かったこと（`NotRegistered`）を成功に写す。削除は行が無い
/// 状態にすることが目的なので、タイムアウトした削除がサーバー側でコミットされて
/// いた場合や、DB の外で行を消した場合にも、呼び出し側が削除を完了できるようにする。
pub fn deleted_or_absent(
  result: Result(Nil, StoreError),
) -> Result(Nil, StoreError) {
  case result {
    Error(NotRegistered) -> Ok(Nil)
    other -> other
  }
}

/// 書き込みの失敗のうち、実際には書き込まれていることがあるものか。期限切れと途中の
/// 切断（`TimedOut`）と例外（`Raised`）が該当し、それ以外（接続を得られない、制約違反、
/// クエリーの失敗）は書き込まれていないことが確定している。
pub fn may_have_been_written(error: StoreError) -> Bool {
  case error {
    TimedOut | Raised(_) -> True
    Unavailable
    | AlreadyRegistered
    | NotRegistered
    | RelayAlreadyRegistered
    | RelayNotRegistered
    | QueryFailed(_)
    | SchemaTooNew(..)
    | HeldByAnotherInstance(..) -> False
  }
}

/// ログと画面に出す説明。pgo は認証の失敗や存在しないデータベース名も接続の
/// 失敗に畳むので、`Unavailable` の説明はそれらも含む言い方にする。
pub fn describe(error: StoreError) -> String {
  case error {
    Unavailable -> "database is unreachable or rejected the connection"
    TimedOut -> "database did not answer in time or the connection was lost"
    Raised(exception) ->
      "the database client raised an exception: " <> exception
    AlreadyRegistered -> "account is already registered"
    NotRegistered -> "account is not registered"
    RelayAlreadyRegistered -> "relay is already registered"
    RelayNotRegistered -> "relay is not registered"
    QueryFailed(reason) -> reason
    SchemaTooNew(found:, supported:) ->
      "database schema version "
      <> int.to_string(found)
      <> " is newer than this build supports (up to version "
      <> int.to_string(supported)
      <> ")"
    HeldByAnotherInstance(key:) ->
      "another instance is using this database (advisory lock "
      <> int.to_string(key)
      <> " is held by another session)"
  }
}

/// pog のエラーを `StoreError` に写す。Postgres が返す `message` と `detail` は
/// 値を含みうるので捨て、制約名やエラー名のような識別子だけを残す。
pub fn from_query_error(error: pog.QueryError) -> StoreError {
  case error {
    pog.ConnectionUnavailable -> Unavailable
    pog.QueryTimeout -> TimedOut
    pog.ConstraintViolated(constraint:, ..)
      if constraint == primary_key_constraint
    -> AlreadyRegistered
    pog.ConstraintViolated(constraint:, ..)
      if constraint == relay_url_constraint
    -> RelayAlreadyRegistered
    pog.ConstraintViolated(constraint:, ..) ->
      QueryFailed("constraint violated: " <> constraint)
    pog.PostgresqlError(name:, ..) -> QueryFailed("postgres error: " <> name)
    pog.UnexpectedArgumentCount(..) -> QueryFailed("unexpected argument count")
    pog.UnexpectedArgumentType(..) -> QueryFailed("unexpected argument type")
    pog.UnexpectedResultType(_) -> QueryFailed("unexpected result type")
  }
}

/// クエリーを実行し、失敗を `StoreError` に写す。本体のクエリーはすべてここを
/// 通す（`dedup/resume_store` を含む）。`pog.execute` が例外を投げたときも値で
/// 返す（`execute_catching`）。プールが未登録のとき pgo が呼び出し側を `noproc`
/// で exit させる問題（`src/nostr_no_su/app.gleam` の doc）も、この経路で
/// `Unavailable` になる（`execute_catching` の doc）。
pub fn execute(
  query: pog.Query(row),
  db: pog.Connection,
) -> Result(pog.Returned(row), StoreError) {
  use executed <- result.try(execute_catching(query, db))
  result.map_error(executed, from_query_error)
}

/// `pog.execute` を実行し、例外を値に写す。プールから接続を得る前の例外（プールの
/// プロセスが無いなど）は `Unavailable`、それ以外の例外は `Raised` にする。`Raised` には
/// 送る前に起きた例外（pgo_pool のチェックアウトが返す文字列の理由を pog が写せない
/// 場合）も含まれ、送った後の例外と区別しない。
@external(erlang, "nostr_no_su_ffi", "execute_catching")
fn execute_catching(
  query: pog.Query(row),
  db: pog.Connection,
) -> Result(Result(pog.Returned(row), pog.QueryError), StoreError)

/// 1 行を対象にする書き込みを実行する。対象の行が無ければ `missing`。
pub fn execute_on_one_row(
  query: pog.Query(Nil),
  db: pog.Connection,
  timeouts: Timeouts,
  missing: StoreError,
) -> Result(Nil, StoreError) {
  use returned <- result.try(
    query
    |> pog.timeout(timeouts.write_ms)
    |> execute(db),
  )
  case returned.count {
    0 -> Error(missing)
    _ -> Ok(Nil)
  }
}

/// プールの接続 1 本で `run` をトランザクションとして実行し、`timeout_ms` の期限で
/// 打ち切る。`run` の中で同じプールへ送るクエリーはこの接続で実行される。`run` が
/// `Error` を返したらロールバックする。
@external(erlang, "nostr_no_su_ffi", "pool_transaction")
fn pool_transaction(
  pool: Name(pog.Message),
  timeout_ms: Int,
  run: fn() -> Result(a, e),
) -> Result(Result(a, e), TransactionFailure)

/// 暗号化 1 回ぶんの nonce。
fn random_nonce() -> BitArray {
  crypto.strong_random_bytes(aes_gcm.nonce_bytes)
}

/// `bunker_accounts` の 1 行を読むデコーダー。列の順序は `select_sql` と同じ。
fn row_decoder() -> decode.Decoder(vault.Row) {
  use pubkey <- decode.field(0, decode.string)
  use label <- decode.field(1, decode.string)
  use encrypted_privkey <- decode.field(2, decode.bit_array)
  use encrypted_secret <- decode.field(3, decode.bit_array)
  decode.success(vault.Row(
    pubkey: pubkey,
    label: label,
    encrypted_privkey: encrypted_privkey,
    encrypted_secret: encrypted_secret,
  ))
}

/// `bunker_sessions` の 1 行を、値と MAC の組にして読むデコーダー。列の順序は
/// `select_sessions_sql` と同じ。
fn session_decoder() -> decode.Decoder(#(StoredSession, BitArray)) {
  use signer <- decode.field(0, decode.string)
  use client <- decode.field(1, decode.string)
  use perms <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.int)
  use last_used_at <- decode.field(4, decode.int)
  use mac <- decode.field(5, decode.bit_array)
  use relays <- decode.field(6, decode.list(decode.string))
  decode.success(#(
    StoredSession(signer:, client:, perms:, created_at:, last_used_at:, relays:),
    mac,
  ))
}

/// `bunker_pending` の 1 行を、値と MAC の組にして読むデコーダー。列の順序は
/// `select_pending_sql` と同じ。
fn pending_decoder() -> decode.Decoder(#(StoredPending, BitArray)) {
  use token <- decode.field(0, decode.string)
  use signer <- decode.field(1, decode.string)
  use client <- decode.field(2, decode.string)
  use request_id <- decode.field(3, decode.string)
  use perms <- decode.field(4, decode.string)
  use secret_mismatch <- decode.field(5, decode.bool)
  use created_at <- decode.field(6, decode.int)
  use mac <- decode.field(7, decode.bit_array)
  decode.success(#(
    StoredPending(
      token:,
      signer:,
      client:,
      request_id:,
      perms:,
      secret_mismatch:,
      created_at:,
    ),
    mac,
  ))
}

/// 読んだ行（値と MAC の組）を、MAC の合う値と、合わない行の MAC の対象に
/// 分ける。どちらも元の順序を保つ。
fn split_by_mac(
  key: MasterKey,
  rows: List(#(row, BitArray)),
  mac_row: fn(row) -> vault.MacRow,
) -> #(List(row), List(vault.MacRow)) {
  let #(matching, rejected) =
    list.partition(rows, fn(pair) {
      vault.verify_row_mac(key, mac_row(pair.0), pair.1)
    })
  #(
    list.map(matching, fn(pair) { pair.0 }),
    list.map(rejected, fn(pair) { mac_row(pair.0) }),
  )
}

/// セッションの行の MAC の対象。
fn session_mac_row(session: StoredSession) -> vault.MacRow {
  vault.SessionMacRow(
    signer: session.signer,
    client: session.client,
    perms: session.perms,
    created_at: session.created_at,
    last_used_at: session.last_used_at,
    relays: session.relays,
  )
}

/// 承認待ちの行の MAC の対象。
fn pending_mac_row(pending: StoredPending) -> vault.MacRow {
  vault.PendingMacRow(
    token: pending.token,
    signer: pending.signer,
    client: pending.client,
    request_id: pending.request_id,
    perms: pending.perms,
    secret_mismatch: pending.secret_mismatch,
    created_at: pending.created_at,
  )
}
