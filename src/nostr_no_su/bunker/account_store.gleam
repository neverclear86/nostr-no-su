//// バンカーアカウントを Postgres の `bunker_accounts` テーブルに保存する。
////
//// SQL と pog の呼び出しだけを持ち、暗号化と行の検証は `vault` に任せる。nonce の
//// 乱数はこの層で引く。DB へ送るのは暗号文だけで、平文もマスターキーも DB へは
//// 出ない。
////
//// 失敗はすべて `StoreError` の値で返し、呼び出し側のプロセスを落とさない。
//// エラーの説明は値（鍵、secret、ラベル、暗号文）を含まない。Postgres の制約違反の
//// `detail` は `Failing row contains (...)` の形で行の全列を含むので、写すときに
//// 捨てる。

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/result
import nostr_no_su/bunker/vault.{type MasterKey}
import nostr_no_su/crypto/aes_gcm
import nostr_no_su/hex
import pog

/// 接続プールの本数。書き込み手はバンカーアクター 1 つで逐次なので少なく保つ。
/// 1 本だと再接続の間は完全に使えなくなるので 2 本にする。
const pool_size = 2

/// 読み込みの経路のクエリーのタイムアウト。DDL と一覧の `SELECT` を 2000ms ずつに
/// すると、成功する経路の最悪でも約 4 秒で、`named.call` の 5000ms に収まる。
/// DB に到達できないときの失敗はこの値に依らず 2〜3 秒で返る（pgo の待ち行列の
/// 設定で決まる）。
const load_timeout_ms = 2000

/// 書き込みの経路のクエリーのタイムアウト。書き込みはバンカーアクターの中で行う
/// ので、この間は NIP-46 の処理が待たされる。主キーで 1 行を書く操作は通常ミリ秒の
/// 単位で終わる。DB に到達できて遅いときの待ちをこの値で打ち切り、書き込みが積まれて
/// も後ろの署名者の問い合わせ（5000ms）が収まるようにする。DB に到達できないときの
/// 失敗はこの値に依らず 2〜3 秒で返る。
const write_timeout_ms = 1000

/// 主キーの制約名。これに違反した挿入は、同じ公開鍵の登録済みを意味する。
const primary_key_constraint = "bunker_accounts_pkey"

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

/// 読み込みの最初に実行する DDL。すべて `IF NOT EXISTS` なので何度実行してもよい。
pub const schema = [create_accounts_table]

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

/// ストア操作の失敗。説明は値（鍵、secret、ラベル、暗号文）を含まない。
pub type StoreError {
  /// DB に到達できない、接続を拒否された（認証の失敗や存在しないデータベース名を
  /// 含む）、あるいはタイムアウトした。
  Unavailable
  /// 同じ pubkey がすでに登録されている。
  AlreadyRegistered
  /// 指定した pubkey が登録されていない。
  NotRegistered
  /// それ以外のクエリーの失敗。Postgres のエラー名など、値を含まない説明だけを
  /// 持つ。
  QueryFailed(reason: String)
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

/// テーブルを作成する。すでにあれば何もしない。
pub fn ensure_schema(db: pog.Connection) -> Result(Nil, StoreError) {
  use statement <- list.try_each(schema)
  pog.query(statement)
  |> pog.timeout(load_timeout_ms)
  |> pog.execute(on: db)
  |> result.map_error(from_query_error)
}

/// スキーマを用意してから全行を読み込み、復号できた行と飛ばした行に分ける。
/// スキーマの用意に失敗したら、一覧の取得へ進まずにその失敗を返す。DB に到達
/// できないとき、1 回の読み込みで待つチェックアウトを 1 回に抑えるためである。
pub fn load(
  db: pog.Connection,
  key: MasterKey,
) -> Result(vault.Loaded, StoreError) {
  use Nil <- result.try(ensure_schema(db))
  pog.query(select_sql)
  |> pog.returning(row_decoder())
  |> pog.timeout(load_timeout_ms)
  |> pog.execute(on: db)
  |> result.map(fn(returned) { vault.open_rows(key, returned.rows) })
  |> result.map_error(from_query_error)
}

/// アカウントを 1 件追加する。
pub fn insert(
  db: pog.Connection,
  key: MasterKey,
  entry: vault.StoredAccount,
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
  |> pog.timeout(write_timeout_ms)
  |> pog.execute(on: db)
  |> result.map_error(from_query_error)
  |> result.replace(Nil)
}

/// アカウントを 1 件削除する。
pub fn delete(db: pog.Connection, pubkey: String) -> Result(Nil, StoreError) {
  pog.query(delete_sql)
  |> pog.parameter(pog.text(pubkey))
  |> execute_on_one_row(db)
}

/// 接続 secret を差し替える。`pubkey` が 16 進として読めないときは、列の制約上
/// その行は存在しえないので `NotRegistered` にする。
pub fn update_secret(
  db: pog.Connection,
  key: MasterKey,
  pubkey: String,
  secret: String,
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
  |> execute_on_one_row(db)
}

/// ラベルを差し替える。
pub fn update_label(
  db: pog.Connection,
  pubkey: String,
  label: String,
) -> Result(Nil, StoreError) {
  pog.query(update_label_sql)
  |> pog.parameter(pog.text(pubkey))
  |> pog.parameter(pog.text(label))
  |> execute_on_one_row(db)
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

/// ログと画面に出す説明。pgo は認証の失敗や存在しないデータベース名も接続の
/// 失敗に畳むので、`Unavailable` の説明はそれらも含む言い方にする。
pub fn describe(error: StoreError) -> String {
  case error {
    Unavailable ->
      "database is unreachable, rejected the connection, or timed out"
    AlreadyRegistered -> "account is already registered"
    NotRegistered -> "account is not registered"
    QueryFailed(reason) -> reason
  }
}

/// pog のエラーを `StoreError` に写す。Postgres が返す `message` と `detail` は
/// 値を含みうるので捨て、制約名やエラー名のような識別子だけを残す。
pub fn from_query_error(error: pog.QueryError) -> StoreError {
  case error {
    pog.ConnectionUnavailable | pog.QueryTimeout -> Unavailable
    pog.ConstraintViolated(constraint:, ..)
      if constraint == primary_key_constraint
    -> AlreadyRegistered
    pog.ConstraintViolated(constraint:, ..) ->
      QueryFailed("constraint violated: " <> constraint)
    pog.PostgresqlError(name:, ..) -> QueryFailed("postgres error: " <> name)
    pog.UnexpectedArgumentCount(..) -> QueryFailed("unexpected argument count")
    pog.UnexpectedArgumentType(..) -> QueryFailed("unexpected argument type")
    pog.UnexpectedResultType(_) -> QueryFailed("unexpected result type")
  }
}

/// 1 行を対象にする書き込みを実行する。対象の行が無ければ `NotRegistered`。
fn execute_on_one_row(
  query: pog.Query(Nil),
  db: pog.Connection,
) -> Result(Nil, StoreError) {
  use returned <- result.try(
    query
    |> pog.timeout(write_timeout_ms)
    |> pog.execute(on: db)
    |> result.map_error(from_query_error),
  )
  case returned.count {
    0 -> Error(NotRegistered)
    _ -> Ok(Nil)
  }
}

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
