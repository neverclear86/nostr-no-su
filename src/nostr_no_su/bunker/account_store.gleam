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

/// ストアの操作の期限。どちらもチェックアウトを要求した時点から数えるので、プールの
/// 接続を待つ時間（期限切れで閉じた接続の再接続を含む）もこの値に含まれる。
pub type Timeouts {
  Timeouts(
    /// 読み込み 1 回（スキーマの用意、ロック、一覧）全体の期限。
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
///   （`may_have_been_written`）。
pub const default_timeouts = Timeouts(load_ms: 3000, write_ms: 1000)

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

/// 読み込みのトランザクションの中で、ロックの待ちの上限を設定する（ミリ秒）。
/// クライアントが期限で諦めた後に、サーバーのバックエンドがロックを待ち続けないため。
const lock_timeout_sql = "SELECT set_config('lock_timeout', $1, true)"

/// 実行中の書き込み（ROW EXCLUSIVE）の終了を待つためのロック。
const lock_sql = "LOCK TABLE bunker_accounts IN SHARE MODE"

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
  /// DB に到達できない、あるいは接続を拒否された（認証の失敗や存在しないデータベース
  /// 名を含む）。プールから接続を得られなかったので、クエリーは送られていない。
  Unavailable
  /// 期限までに応答が無かった、あるいはクエリーの途中で接続が切れた。クエリーが
  /// サーバーに届いていれば、書き込みはコミットされていることがある。
  TimedOut
  /// 同じ pubkey がすでに登録されている。
  AlreadyRegistered
  /// 指定した pubkey が登録されていない。
  NotRegistered
  /// それ以外のクエリーの失敗。Postgres のエラー名など、値を含まない説明だけを
  /// 持つ。
  QueryFailed(reason: String)
}

/// 期限つきのトランザクションを実行できなかった理由。
type TransactionFailure {
  /// プールから接続を得られなかった。
  CheckoutFailed
  /// 期限で接続が閉じられた、あるいは COMMIT などが失敗した。
  Interrupted
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
pub fn ensure_schema(
  db: pog.Connection,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  use statement <- list.try_each(schema)
  pog.query(statement)
  |> pog.timeout(timeouts.load_ms)
  |> pog.execute(on: db)
  |> result.map_error(from_query_error)
}

/// スキーマを用意してから全行を読み込み、復号できた行と飛ばした行に分ける。
///
/// 一覧を読む前に `LOCK TABLE bunker_accounts IN SHARE MODE` を取る。SHARE は実行中の
/// `INSERT` / `UPDATE` / `DELETE` が持つ ROW EXCLUSIVE と衝突するので、期限を過ぎた後も
/// サーバー側で実行を続けている書き込みがあれば、その終了（コミットかロールバック）を
/// 待ってから読む。READ COMMITTED の `SELECT` は文ごとのスナップショットで読むので、
/// 待った書き込みの結果が見える。起動時の読み込みも同じ読み方にする。前のアクターが
/// 書き込みの途中で終了した後に再起動したアクターが、その書き込みより先に読むのを
/// 防ぐためである。
///
/// **残る窓**：書き込みの文がサーバーに届いてテーブルのロックを取るより先に、この
/// ロックが取られた場合（クライアントの期限の直前に送った文が、まだ転送中か
/// サーバーのプロセスの実行待ちである場合）は、書き込みはこの読み込みの後に実行され、
/// 読み込みには見えない。ローカルの Postgres で期限切れの挿入を起こした測定では、
/// コミットされた 704 件のうち読み込みに見えなかったものは 0 件だった（ロックを取らない
/// 読み込みでは 712 件中 77 件）。窓の長さは、期限の時点での転送とサーバーの
/// スケジューリングの遅れで決まる。
///
/// 全体を 1 本のトランザクションで行い、`timeouts.load_ms` の期限で打ち切る（期限は
/// pgo のプールが接続を閉じることで効くので、DB が応答しなくなっても待ちはこの値に
/// 収まる）。ロックの待ちもサーバー側で同じ値に抑える。期限で打ち切られたら
/// `TimedOut`、接続を得られなければ `Unavailable` を返す。`pool` を名前で受け取るのは、
/// 期限つきのトランザクションをプールの名前で開くためである。
pub fn load(
  pool: Name(pog.Message),
  key: MasterKey,
  timeouts: Timeouts,
) -> Result(vault.Loaded, StoreError) {
  let db = pog.named_connection(pool)
  pool_transaction(pool, timeouts.load_ms, fn() {
    use Nil <- result.try(ensure_schema(db, timeouts))
    use _set <- result.try(
      pog.query(lock_timeout_sql)
      |> pog.parameter(pog.text(int.to_string(timeouts.load_ms)))
      |> execute(db),
    )
    use _locked <- result.try(pog.query(lock_sql) |> execute(db))
    pog.query(select_sql)
    |> pog.returning(row_decoder())
    |> execute(db)
    |> result.map(fn(returned) { vault.open_rows(key, returned.rows) })
  })
  |> result.map_error(fn(failure) {
    case failure {
      CheckoutFailed -> Unavailable
      Interrupted -> TimedOut
    }
  })
  |> result.flatten
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
  |> execute_on_one_row(db, timeouts)
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
  |> execute_on_one_row(db, timeouts)
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
  |> execute_on_one_row(db, timeouts)
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
/// 切断だけが該当し、それ以外（接続を得られない、制約違反、クエリーの失敗）は書き
/// 込まれていないことが確定している。
pub fn may_have_been_written(error: StoreError) -> Bool {
  error == TimedOut
}

/// ログと画面に出す説明。pgo は認証の失敗や存在しないデータベース名も接続の
/// 失敗に畳むので、`Unavailable` の説明はそれらも含む言い方にする。
pub fn describe(error: StoreError) -> String {
  case error {
    Unavailable -> "database is unreachable or rejected the connection"
    TimedOut -> "database did not answer in time or the connection was lost"
    AlreadyRegistered -> "account is already registered"
    NotRegistered -> "account is not registered"
    QueryFailed(reason) -> reason
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
    pog.ConstraintViolated(constraint:, ..) ->
      QueryFailed("constraint violated: " <> constraint)
    pog.PostgresqlError(name:, ..) -> QueryFailed("postgres error: " <> name)
    pog.UnexpectedArgumentCount(..) -> QueryFailed("unexpected argument count")
    pog.UnexpectedArgumentType(..) -> QueryFailed("unexpected argument type")
    pog.UnexpectedResultType(_) -> QueryFailed("unexpected result type")
  }
}

/// クエリーを実行し、失敗を `StoreError` に写す。
fn execute(
  query: pog.Query(row),
  db: pog.Connection,
) -> Result(pog.Returned(row), StoreError) {
  pog.execute(query, on: db)
  |> result.map_error(from_query_error)
}

/// 1 行を対象にする書き込みを実行する。対象の行が無ければ `NotRegistered`。
fn execute_on_one_row(
  query: pog.Query(Nil),
  db: pog.Connection,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  use returned <- result.try(
    query
    |> pog.timeout(timeouts.write_ms)
    |> execute(db),
  )
  case returned.count {
    0 -> Error(NotRegistered)
    _ -> Ok(Nil)
  }
}

/// プールの接続 1 本で `run` をトランザクションとして実行し、`timeout_ms` の期限で
/// 打ち切る。`run` の中で同じプールへ送るクエリーはこの接続で実行される。
@external(erlang, "nostr_no_su_ffi", "pool_transaction")
fn pool_transaction(
  pool: Name(pog.Message),
  timeout_ms: Int,
  run: fn() -> result,
) -> Result(result, TransactionFailure)

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
