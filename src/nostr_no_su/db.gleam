//// 本体の DB の基盤。接続プールの設定、インスタンスの advisory lock、ストアの操作の
//// 期限（`Timeouts`）、全テーブルの DDL と版つきの移行、期限つきのトランザクション、
//// クエリーの実行と失敗の値（`StoreError`）を持つ。テーブルごとの読み書きは持たない。
////
//// 失敗はすべて `StoreError` の値で返し、呼び出し側のプロセスを落とさない。
//// pog と pgo が投げる例外も、クエリーの実行の入口（`execute`）で値に写す。
//// エラーの説明は値（鍵、secret、ラベル、暗号文）を含まない。Postgres の制約違反の
//// `detail` は `Failing row contains (...)` の形で行の全列を含むので、写すときに
//// 捨てる。
////
//// テーブルの DDL は版つきの移行（`migrations`）として持ち、`ensure_schema` が
//// `schema_version` に記録された版より新しい移行を適用する。記録された版がこの
//// ビルドより新しければ `SchemaTooNew` を返す。移行はバンカーのアカウント
//// （`bunker_accounts`）、セッションと承認待ちのテーブル、監視の再開点のテーブル
//// （`monitor_resume`）、リレーの一覧（`relays`）、プラグインの再開点
//// （`plugin_resume`）を作る。
////
//// 同じ DB に対して動けるインスタンスは 1 つに限る。`acquire_lock` で advisory lock
//// を確かめ、別のセッションが持っていれば `HeldByAnotherInstance` を返す。

import gleam/dynamic/decode
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/result
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
    /// 書き込み 1 件と、主キーの 1 行の読み込み（`resume/store` の再開点）と
    /// `acquire_lock` の期限。
    write_ms: Int,
  )
}

/// 本番の期限。`load_ms` は読み込み 1 回全体、`write_ms` は書き込み 1 件（と主キーの
/// 1 行の読み込み、`acquire_lock`）の期限。
/// 期限を過ぎてもサーバー側で文の実行が続きうるので、書き込みの `TimedOut` は
/// 「書き込まれたかどうか分からない」を意味する（`may_have_been_written`）。
/// 値の根拠（署名者の問い合わせの 5 秒に収める予算）は docs/design-decisions.md の
/// 「DB が不調な間は NIP-46 の処理が待たされる」にある。
pub const default_timeouts = Timeouts(load_ms: 3000, write_ms: 1000)

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
/// 小さくしない（`resume/store`）。
pub const create_monitor_resume_table = "CREATE TABLE IF NOT EXISTS monitor_resume (
  relay_url text PRIMARY KEY,
  since bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
)"

/// 承認済みのセッションを保存するテーブル。主キーは（signer, client）。`perms` は
/// セッションの権限のトークンをカンマで区切った値で、空文字列は無宣言（既定の集合で照合する。
/// `bunker/permission`）を表す。`signer` は `bunker_accounts(pubkey)` を
/// `ON DELETE CASCADE` で参照するので、アカウントの削除でその署名者のセッションも消える。
/// 時刻は Unix 秒。新しい組では `created_at` と `last_used_at` が同じ値で入る（`engine` の
/// `new_session`）。`last_used_at` は `account_store.touch_session` で進める。行の MAC の列
/// `mac` は版 6 の移行（`add_row_macs`）で足す。URI のリレーの列 `relays` は版 7 の移行
/// （`add_session_relays`）で足す。
const create_sessions_table = "CREATE TABLE IF NOT EXISTS bunker_sessions (
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
const create_pending_table = "CREATE TABLE IF NOT EXISTS bunker_pending (
  token text PRIMARY KEY,
  signer text NOT NULL REFERENCES bunker_accounts (pubkey) ON DELETE CASCADE,
  client text NOT NULL,
  request_id text NOT NULL,
  perms text NOT NULL,
  secret_mismatch boolean NOT NULL,
  created_at bigint NOT NULL
)"

/// 監視とバンカーのリレーを保存するテーブル。`observe`（監視）と `bunker` の組は Gleam 側で
/// `relay_list.Roles` に写し、どちらも false の行は `relay_store.list` が読まない。順は `id`。
const create_relays_table = "CREATE TABLE IF NOT EXISTS relays (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  url text NOT NULL CONSTRAINT relays_url_key UNIQUE,
  observe boolean NOT NULL,
  bunker boolean NOT NULL
)"

/// プラグインごとの再開点を保存するテーブル。`since` は Unix 秒。主キーは
/// プラグイン名（`plugin_name/0` の値）。書き込みは値を小さくしない
/// （`resume/store`）。
const create_plugin_resume_table = "CREATE TABLE IF NOT EXISTS plugin_resume (
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
/// 読み込みで頭から実行し直される。
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
pub const create_version_table = "CREATE TABLE IF NOT EXISTS schema_version (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
)"

/// 記録された版の読み込み。
const select_versions_sql = "SELECT version FROM schema_version"

/// 版の記録。
const insert_version_sql = "INSERT INTO schema_version (version) VALUES ($1)"

/// セッション単位の advisory lock を取る（待たない）。
const try_lock_sql = "SELECT pg_try_advisory_lock($1)"

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
  /// 同じキーの行がすでにある。どの一意制約の違反が重複を意味するかは、テーブルを
  /// 知っている呼び出し側が `duplicate_on` で決める。
  Duplicate
  /// 対象の行が無い。
  NotFound
  /// 制約に違反した。`constraint` は制約の名前だけで、行の値を含みうる `message` と
  /// `detail` は持たない。一意制約の違反も、呼び出し側が `duplicate_on` で写すまでは
  /// この値である。
  ConstraintRejected(constraint: String)
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
/// 新しい移行の文を順に実行して、移行ごとに版を記録する。`transaction` の中で呼ぶ。
/// 文の期限は `pool_transaction` の期限が効く。
pub fn ensure_schema(db: pog.Connection) -> Result(Nil, StoreError) {
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

/// `pool_transaction` の `TransactionFailure` を `StoreError` に写す。`run` の
/// `Error` はそのまま返り、期限で打ち切られたら `TimedOut`、接続を得られなければ
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

/// 書き込みの失敗のうち、実際には書き込まれていることがあるものか。期限切れと途中の
/// 切断（`TimedOut`）と例外（`Raised`）が該当し、それ以外（接続を得られない、制約違反、
/// クエリーの失敗）は書き込まれていないことが確定している。
pub fn may_have_been_written(error: StoreError) -> Bool {
  case error {
    TimedOut | Raised(_) -> True
    Unavailable
    | Duplicate
    | NotFound
    | ConstraintRejected(_)
    | QueryFailed(_)
    | SchemaTooNew(..)
    | HeldByAnotherInstance(..) -> False
  }
}

/// ログと画面に出す説明。pgo は認証の失敗や存在しないデータベース名も接続の
/// 失敗に畳むので、`Unavailable` の説明はそれらも含む言い方にする。`Duplicate` と
/// `NotFound` はテーブルを名指さない。テーブルの語を添えた説明は呼び出し側が作る
/// （`account_store.describe`）。
pub fn describe(error: StoreError) -> String {
  case error {
    Unavailable -> "database is unreachable or rejected the connection"
    TimedOut -> "database did not answer in time or the connection was lost"
    Raised(exception) ->
      "the database client raised an exception: " <> exception
    Duplicate -> "row already exists"
    NotFound -> "row does not exist"
    ConstraintRejected(constraint) -> "constraint violated: " <> constraint
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

/// 一意制約 `constraint` の違反（`ConstraintRejected`）を `Duplicate` に写し、それ以外は
/// そのまま返す。どの制約が重複を意味するかは、テーブルを知っている呼び出し側が渡す。
pub fn duplicate_on(error: StoreError, constraint: String) -> StoreError {
  case error {
    ConstraintRejected(rejected) if rejected == constraint -> Duplicate
    _ -> error
  }
}

/// pog のエラーを `StoreError` に写す。Postgres が返す `message` と `detail` は
/// 値を含みうるので捨て、制約名やエラー名のような識別子だけを残す。
pub fn from_query_error(error: pog.QueryError) -> StoreError {
  case error {
    pog.ConnectionUnavailable -> Unavailable
    pog.QueryTimeout -> TimedOut
    pog.ConstraintViolated(constraint:, ..) -> ConstraintRejected(constraint)
    pog.PostgresqlError(name:, ..) -> QueryFailed("postgres error: " <> name)
    pog.UnexpectedArgumentCount(..) -> QueryFailed("unexpected argument count")
    pog.UnexpectedArgumentType(..) -> QueryFailed("unexpected argument type")
    pog.UnexpectedResultType(_) -> QueryFailed("unexpected result type")
  }
}

/// クエリーを実行し、失敗を `StoreError` に写す。本体のクエリーはすべてここを
/// 通す（`resume/store` を含む）。`execute_catching` が `pog.execute` の例外も値に
/// 写すので、プールが未登録のとき pgo が呼び出し側を `noproc` で exit させる問題も
/// この経路で `Unavailable` になる。
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
@external(erlang, "nostr_no_su_store_ffi", "execute_catching")
fn execute_catching(
  query: pog.Query(row),
  db: pog.Connection,
) -> Result(Result(pog.Returned(row), pog.QueryError), StoreError)

/// 書き込みを `timeouts.write_ms` の期限で実行する。対象の行の数は見ず、成功なら
/// `Nil` を返す。
pub fn execute_write(
  query: pog.Query(Nil),
  db: pog.Connection,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  execute_counting(query, db, timeouts)
  |> result.replace(Nil)
}

/// 書き込みを `timeouts.write_ms` の期限で実行し、対象になった行の数を返す。
fn execute_counting(
  query: pog.Query(Nil),
  db: pog.Connection,
  timeouts: Timeouts,
) -> Result(Int, StoreError) {
  query
  |> pog.timeout(timeouts.write_ms)
  |> execute(db)
  |> result.map(fn(returned) { returned.count })
}

/// 1 行を対象にする書き込みを実行する。対象の行が無ければ `NotFound`。
pub fn execute_on_one_row(
  query: pog.Query(Nil),
  db: pog.Connection,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  use count <- result.try(execute_counting(query, db, timeouts))
  case count {
    0 -> Error(NotFound)
    _ -> Ok(Nil)
  }
}

/// `pool` の接続 1 本で `run` を `timeout_ms` の期限つきトランザクションとして実行する FFI。
@external(erlang, "nostr_no_su_store_ffi", "pool_transaction")
fn pool_transaction(
  pool: Name(pog.Message),
  timeout_ms: Int,
  run: fn() -> Result(a, e),
) -> Result(Result(a, e), TransactionFailure)
