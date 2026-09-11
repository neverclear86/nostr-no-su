//// `bunker/account_store` のテスト。純粋な部分は常に、実際の Postgres に対する
//// 統合テストは `TEST_DATABASE_URL` があるときだけ実行する。
////
//// 同じテーブルには過去の実行が残した行（別の乱数のマスターキーで暗号化された
//// もの）がありうるので、読み込みの結果はどれも自分が入れた pubkey に絞ってから
//// 比べる。

import envoy
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Name}
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/vault.{
  type MasterKey, type StoredAccount, StoredAccount,
}
import nostr_no_su/hex
import nostr_no_su/random
import pog

/// DDL はすべて `IF NOT EXISTS` 付きで、起動のたびに実行してよい。
pub fn schema_statements_are_idempotent_test() {
  assert list.all(account_store.schema, string.contains(_, "IF NOT EXISTS"))
}

/// Postgres の URL からプールの設定を作り、本数を 2 に絞る。`pog.Config` は
/// パスワードを持つので、表示も比較もせず本数だけを確かめる。
pub fn pool_config_accepts_postgres_urls_test() {
  let assert Ok(config) =
    account_store.pool_config(
      process.new_name("account_store_test_pool"),
      "postgres://user:pw-marker@host:5432/db",
    )
  assert config.pool_size == 2
}

/// データベース名の無い URL や Postgres 以外の URL は拒否し、理由に URL（パス
/// ワードを含みうる）を含めない。
pub fn pool_config_rejects_invalid_urls_without_echoing_them_test() {
  let urls = [
    "postgres://user:pw-marker@host:5432",
    "mysql://user:pw-marker@host/db",
  ]
  use url <- list.each(urls)
  let assert Error(reason) =
    account_store.pool_config(process.new_name("account_store_test_pool"), url)
  assert reason == "DATABASE_URL is not a valid postgres URL"
  assert !string.contains(reason, "pw-marker")
}

/// 接続を得られないエラーは `Unavailable`、期限切れは `TimedOut`、主キーの制約違反は
/// `AlreadyRegistered` になる。
pub fn query_errors_map_to_store_errors_test() {
  assert account_store.from_query_error(pog.ConnectionUnavailable)
    == account_store.Unavailable
  assert account_store.from_query_error(pog.QueryTimeout)
    == account_store.TimedOut
  assert account_store.from_query_error(pog.ConstraintViolated(
      message: "duplicate key value violates unique constraint",
      constraint: "bunker_accounts_pkey",
      detail: "Key (pubkey)=(abc) already exists.",
    ))
    == account_store.AlreadyRegistered
}

/// 制約違反の `detail` と `message` は行の値を含みうるので、説明に残さない。
pub fn constraint_details_are_not_described_test() {
  let error =
    pog.ConstraintViolated(
      message: "new row violates check constraint (message-marker)",
      constraint: "bunker_accounts_encrypted_secret_check",
      detail: "Failing row contains (detail-marker, main, \\x00)",
    )
  let described = account_store.describe(account_store.from_query_error(error))
  assert described
    == "constraint violated: bunker_accounts_encrypted_secret_check"
  assert !string.contains(described, "detail-marker")
  assert !string.contains(described, "message-marker")
}

/// 書き込まれていることがある失敗は期限切れだけで、他の失敗は書き込まれていない。
pub fn only_a_timeout_may_have_been_written_test() {
  assert account_store.may_have_been_written(account_store.TimedOut)
  assert !account_store.may_have_been_written(account_store.Unavailable)
  assert !account_store.may_have_been_written(account_store.AlreadyRegistered)
  assert !account_store.may_have_been_written(account_store.NotRegistered)
  assert !account_store.may_have_been_written(account_store.QueryFailed("x"))
}

/// 削除で行が見つからなかったことは成功に写し、それ以外の失敗はそのまま返す。
pub fn deleted_or_absent_treats_a_missing_row_as_deleted_test() {
  assert account_store.deleted_or_absent(Error(account_store.NotRegistered))
    == Ok(Nil)
  assert account_store.deleted_or_absent(Error(account_store.Unavailable))
    == Error(account_store.Unavailable)
  assert account_store.deleted_or_absent(Ok(Nil)) == Ok(Nil)
}

/// 到達できないプールへの読み込みは、例外にならず `Unavailable` を返す。
pub fn loading_from_an_unreachable_database_is_a_value_test() {
  let name = process.new_name("account_store_test_unreachable")
  let assert Ok(_pool) =
    pog.default_config(name)
    |> pog.port(1)
    |> pog.start
  assert account_store.load(
      name,
      random_master_key(),
      account_store.default_timeouts,
    )
    |> result.replace(Nil)
    == Error(account_store.Unavailable)
}

/// 実際の Postgres に対する統合テスト。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。同じ DB に対して `gleam test` を並行実行することは想定して
/// いない。
pub fn postgres_round_trip_test() {
  case envoy.get("TEST_DATABASE_URL") {
    Ok("") | Error(Nil) ->
      io.println(
        "[account_store] TEST_DATABASE_URL is not set; skipping the integration test",
      )
    Ok(database_url) -> round_trip(connect(database_url))
  }
}

/// 追加、読み込み、更新、改ざん、削除を一巡させ、最後に自分が入れた行を消す。
fn round_trip(pool: Name(pog.Message)) -> Nil {
  let db = pog.named_connection(pool)
  let key = random_master_key()
  let assert Ok(Nil) = account_store.ensure_schema(db, generous)
  let assert Ok(Nil) = account_store.ensure_schema(db, generous)

  let first = random_entry("first")
  let second = random_entry("second")
  let first_pubkey = account.pubkey_hex(first.account)
  let second_pubkey = account.pubkey_hex(second.account)
  let assert Ok(Nil) = account_store.insert(db, key, first, generous)
  let assert Ok(Nil) = account_store.insert(db, key, second, generous)
  assert account_store.insert(db, key, first, generous)
    == Error(account_store.AlreadyRegistered)

  // 入れた行が同じ内容で戻る。
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert_same_entry(loaded, first)
  assert_same_entry(loaded, second)

  // DB の行に平文は残らない。
  let #(encrypted_privkey, encrypted_secret) = raw_boxes(db, first_pubkey)
  assert !contains_bytes(encrypted_privkey, account.privkey(first.account))
  assert !contains_bytes(encrypted_secret, bit_array.from_string(first.secret))

  // secret とラベルを差し替えると、次の読み込みに反映される。
  let assert Ok(Nil) =
    account_store.update_secret(
      db,
      key,
      second_pubkey,
      "rotated-secret",
      generous,
    )
  let assert Ok(Nil) =
    account_store.update_label(db, second_pubkey, "renamed", generous)
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert_same_entry(
    loaded,
    StoredAccount(..second, secret: "rotated-secret", label: "renamed"),
  )
  let unknown = account.pubkey_hex(random_entry("unknown").account)
  assert account_store.update_secret(db, key, unknown, "x", generous)
    == Error(account_store.NotRegistered)
  assert account_store.update_secret(db, key, "not-hex", "x", generous)
    == Error(account_store.NotRegistered)
  assert account_store.update_label(db, unknown, "x", generous)
    == Error(account_store.NotRegistered)

  // 別のマスターキーでは、自分が入れた行はすべて飛ばされる。
  let assert Ok(other) = account_store.load(pool, random_master_key(), generous)
  assert skipped_reasons(other, [first_pubkey, second_pubkey])
    == [
      #(first_pubkey, vault.UndecryptablePrivateKey),
      #(second_pubkey, vault.UndecryptablePrivateKey),
    ]

  // 暗号文の 1 バイトを書き換えた行だけが飛ばされ、他の行は読み込まれる。
  flip_privkey_byte(db, first_pubkey)
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert skipped_reasons(loaded, [first_pubkey, second_pubkey])
    == [#(first_pubkey, vault.UndecryptablePrivateKey)]
  assert loaded_pubkeys(loaded, [first_pubkey, second_pubkey])
    == [second_pubkey]

  // 削除した行は現れず、2 回目の削除は `NotRegistered`。
  let assert Ok(Nil) = account_store.delete(db, second_pubkey, generous)
  assert account_store.delete(db, second_pubkey, generous)
    == Error(account_store.NotRegistered)
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert loaded_pubkeys(loaded, [second_pubkey]) == []
  assert skipped_reasons(loaded, [second_pubkey]) == []

  let assert Ok(Nil) = account_store.delete(db, first_pubkey, generous)
  Nil
}

/// 統合テストの期限。実際の DB との往復は負荷の高い環境で本番の期限（書き込み
/// 1000ms）を超えうるので、テストが期限の長さに依存しないよう長く取る。
const generous = account_store.Timeouts(load_ms: 30_000, write_ms: 30_000)

/// テスト用の接続プールを起動し、その名前を返す。プールはテストプロセスにリンク
/// される。
fn connect(database_url: String) -> Name(pog.Message) {
  let name = process.new_name("account_store_test_db")
  let assert Ok(config) = pog.url_config(name, database_url)
  let assert Ok(_started) = pog.start(config)
  name
}

/// 実行のたびに違うマスターキー。
fn random_master_key() -> MasterKey {
  let assert Ok(key) =
    vault.master_key_from_hex(hex.encode(crypto.strong_random_bytes(32)))
  key
}

/// 実行のたびに違う鍵と secret を持つアカウント。
fn random_entry(label: String) -> StoredAccount {
  let assert Ok(signer) = account.from_privkey(crypto.strong_random_bytes(32))
  StoredAccount(account: signer, secret: random.hex(16), label: label)
}

/// 読み込みの結果に、期待したアカウントが同じ内容で入っていることを確かめる。
fn assert_same_entry(loaded: vault.Loaded, expected: StoredAccount) -> Nil {
  let pubkey = account.pubkey_hex(expected.account)
  let assert Ok(found) =
    list.find(loaded.accounts, fn(entry) {
      account.pubkey_hex(entry.account) == pubkey
    })
  assert account.privkey(found.account) == account.privkey(expected.account)
  assert found.secret == expected.secret
  assert found.label == expected.label
}

/// 読み込めた行のうち、指定した pubkey のもの。
fn loaded_pubkeys(loaded: vault.Loaded, own: List(String)) -> List(String) {
  loaded.accounts
  |> list.map(fn(entry) { account.pubkey_hex(entry.account) })
  |> list.filter(list.contains(own, _))
}

/// 飛ばした行のうち、指定した pubkey のものと、その理由。
fn skipped_reasons(
  loaded: vault.Loaded,
  own: List(String),
) -> List(#(String, vault.RowError)) {
  loaded.skipped
  |> list.filter(fn(entry) { list.contains(own, entry.pubkey) })
  |> list.map(fn(entry) { #(entry.pubkey, entry.reason) })
}

/// 生の `SELECT` で読んだ暗号文の列。
fn raw_boxes(db: pog.Connection, pubkey: String) -> #(BitArray, BitArray) {
  let decoder = {
    use encrypted_privkey <- decode.field(0, decode.bit_array)
    use encrypted_secret <- decode.field(1, decode.bit_array)
    decode.success(#(encrypted_privkey, encrypted_secret))
  }
  let assert Ok(pog.Returned(rows: [boxes], ..)) =
    pog.query(
      "SELECT encrypted_privkey, encrypted_secret FROM bunker_accounts WHERE pubkey = $1",
    )
    |> pog.parameter(pog.text(pubkey))
    |> pog.returning(decoder)
    |> pog.execute(on: db)
  boxes
}

/// 秘密鍵の暗号文の 1 バイトを書き換える。
fn flip_privkey_byte(db: pog.Connection, pubkey: String) -> Nil {
  let assert Ok(pog.Returned(count: 1, ..)) =
    pog.query(
      "UPDATE bunker_accounts
SET encrypted_privkey = set_byte(encrypted_privkey, 20, get_byte(encrypted_privkey, 20) # 1)
WHERE pubkey = $1",
    )
    |> pog.parameter(pog.text(pubkey))
    |> pog.execute(on: db)
  Nil
}

/// `haystack` が `needle` を部分列として含むかどうか。
fn contains_bytes(haystack: BitArray, needle: BitArray) -> Bool {
  string.contains(hex.encode(haystack), hex.encode(needle))
}
