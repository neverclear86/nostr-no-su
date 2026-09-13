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
import gleam/erlang/process.{type Name, type Pid}
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import nostr_no_su
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/vault.{
  type MasterKey, type StoredAccount, StoredAccount,
}
import nostr_no_su/hex
import nostr_no_su/random
import pog
import support/postgres

/// 移行の文はすべて `IF NOT EXISTS` 付きで、途中で失敗した移行を頭から実行し直して
/// よい。
pub fn migration_statements_can_be_re_run_test() {
  let statements =
    list.flat_map(account_store.migrations, fn(migration) {
      migration.statements
    })
  assert list.all(statements, string.contains(_, "IF NOT EXISTS"))
}

/// `account_store.migrations` の版は 1 から欠番なく昇順に並ぶ。
pub fn migrations_are_numbered_from_one_without_gaps_test() {
  let versions =
    list.map(account_store.migrations, fn(migration) { migration.version })
  assert versions == list.index_map(versions, fn(_, index) { index + 1 })
}

/// 未適用の移行だけを版の順に返す。
pub fn pending_migrations_skip_recorded_versions_test() {
  let migrations = [
    account_store.Migration(version: 1, statements: ["one"]),
    account_store.Migration(version: 2, statements: ["two"]),
  ]
  assert account_store.pending_migrations(migrations, 0) == Ok(migrations)
  assert account_store.pending_migrations(migrations, 1)
    == Ok([account_store.Migration(version: 2, statements: ["two"])])
  assert account_store.pending_migrations(migrations, 2) == Ok([])
}

/// 記録された版が移行の最新の版より新しい DB は拒否する。
pub fn a_database_newer_than_the_migrations_is_refused_test() {
  let migrations = [
    account_store.Migration(version: 1, statements: ["one"]),
    account_store.Migration(version: 2, statements: ["two"]),
  ]
  assert account_store.pending_migrations(migrations, 3)
    == Error(account_store.SchemaTooNew(found: 3, supported: 2))
}

/// 版が新しい DB の説明は、見つかった版とこのビルドが対応する版の両方を含む。
pub fn a_newer_schema_is_described_with_both_versions_test() {
  assert account_store.describe(account_store.SchemaTooNew(
      found: 2,
      supported: 1,
    ))
    == "database schema version 2 is newer than this build supports (up to version 1)"
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

/// 書き込まれていることがある失敗は期限切れと例外だけで、他の失敗は書き込まれていない。
pub fn only_a_timeout_or_an_exception_may_have_been_written_test() {
  assert account_store.may_have_been_written(account_store.TimedOut)
  assert account_store.may_have_been_written(account_store.Raised("x"))
  assert !account_store.may_have_been_written(account_store.Unavailable)
  assert !account_store.may_have_been_written(account_store.AlreadyRegistered)
  assert !account_store.may_have_been_written(account_store.NotRegistered)
  assert !account_store.may_have_been_written(account_store.QueryFailed("x"))
  assert !account_store.may_have_been_written(account_store.SchemaTooNew(
    found: 2,
    supported: 1,
  ))
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

/// プールのプロセスが無いときの書き込みは、例外にならず `Unavailable` を返す。
/// pgo はチェックアウトで呼び出し側を exit させるので、クエリーは送られていない。
pub fn writes_on_a_missing_pool_are_unavailable_test() {
  let db = pog.named_connection(process.new_name("account_store_test_missing"))
  let key = random_master_key()
  let entry = random_entry("missing")
  let pubkey = account.pubkey_hex(entry.account)
  let timeouts = account_store.default_timeouts
  assert account_store.insert(db, key, entry, timeouts)
    == Error(account_store.Unavailable)
  assert account_store.delete(db, pubkey, timeouts)
    == Error(account_store.Unavailable)
  assert account_store.update_secret(db, key, pubkey, "x", timeouts)
    == Error(account_store.Unavailable)
  assert account_store.update_label(db, pubkey, "x", timeouts)
    == Error(account_store.Unavailable)
}

/// pog が写せないエラーで `pog.execute` が例外を投げた書き込みは、例外にならず、
/// 例外のクラスと発生箇所だけを持つ `Raised` を返す。
pub fn an_unmapped_pog_error_is_reported_with_its_location_test() {
  let db = pog.named_connection(start_resetting_pool())
  let key = random_master_key()
  let entry = random_entry("resetting")
  let pubkey = account.pubkey_hex(entry.account)
  let timeouts = account_store.default_timeouts
  let raised = account_store.Raised("error in pog_ffi:convert_error/1")
  assert account_store.insert(db, key, entry, timeouts) == Error(raised)
  assert account_store.delete(db, pubkey, timeouts) == Error(raised)
  assert account_store.update_secret(db, key, pubkey, "x", timeouts)
    == Error(raised)
  assert account_store.update_label(db, pubkey, "x", timeouts) == Error(raised)
  assert account_store.describe(raised)
    == "the database client raised an exception: error in pog_ffi:convert_error/1"
}

/// プールのプロセスが無いときの追加では、`pog.execute` が例外を投げてもバンカー
/// アクターは落ちず、`NotApplied` を返して続く問い合わせに応答する。
pub fn a_write_to_a_missing_pool_is_not_applied_test() {
  let #(name, pid) =
    start_bunker(process.new_name("account_store_test_missing"))
  let entry = random_entry("missing")
  assert bunker.add_account(name, entry.account, entry.label)
    == Error(
      bunker.NotApplied(account_store.describe(account_store.Unavailable)),
    )
  assert bunker.accounts(name) == Ok([])
  stop(pid)
}

/// pog が写せないエラーで `pog.execute` が例外を投げた追加では、バンカーアクターは
/// 落ちず、`MaybeApplied` を返し、読み直してから続く問い合わせに応答する。
pub fn a_write_with_an_unmapped_pog_error_may_have_been_applied_test() {
  let #(name, pid) = start_bunker(start_resetting_pool())
  let entry = random_entry("resetting")
  assert bunker.add_account(name, entry.account, entry.label)
    == Error(bunker.MaybeApplied(bunker.change_may_have_been_applied))
  assert bunker.accounts(name) == Ok([])
  stop(pid)
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
    Ok(database_url) -> round_trip(postgres.start_pool(database_url, None))
  }
}

/// 版の記録より前に作られた DB が版 1 として取り込まれ、版が新しい DB は拒否される。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_schema_version_test() {
  case envoy.get("TEST_DATABASE_URL") {
    Ok("") | Error(Nil) ->
      io.println(
        "[account_store] TEST_DATABASE_URL is not set; skipping the integration test",
      )
    Ok(database_url) -> schema_version_round_trip(database_url)
  }
}

/// 専用のスキーマでテストを行い、最後にスキーマごと消す。`CREATE SCHEMA` と
/// `DROP SCHEMA … CASCADE` は `search_path` の無い接続で、それ以外は専用スキーマへ
/// 向けた接続で実行する。版 2 の挿入を `search_path` なしの接続に流すと public の
/// `schema_version` に版 2 が残り、以後の `round_trip` の `load` が `SchemaTooNew`
/// で落ちるためである。
fn schema_version_round_trip(database_url: String) -> Nil {
  let schema = "account_store_schema_" <> random.hex(8)
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin, "CREATE SCHEMA " <> schema)
  let pool = postgres.start_pool(database_url, Some(schema))
  let db = pog.named_connection(pool)
  let key = random_master_key()

  // 版の記録より前に作られた DB を再現する。
  postgres.run_statement(db, account_store.create_accounts_table)
  let entry = random_entry("legacy")
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  // 移行の後、入れたアカウントが同じ内容で読める。
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert_same_entry(loaded, entry)

  // もう一度読んでも、移行を二重に適用しない。
  let assert Ok(_loaded) = account_store.load(pool, key, generous)
  assert recorded_versions(db) == [1]

  // 記録された版が新しい DB は拒否する。
  postgres.run_statement(db, "INSERT INTO schema_version (version) VALUES (2)")
  assert account_store.load(pool, key, generous)
    == Error(account_store.SchemaTooNew(found: 2, supported: 1))

  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// `schema_version` に記録されている版の一覧（昇順）。
fn recorded_versions(db: pog.Connection) -> List(Int) {
  let assert Ok(returned) =
    pog.query("SELECT version FROM schema_version ORDER BY version")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(on: db)
  returned.rows
}

/// 追加、読み込み、更新、改ざん、削除を一巡させ、最後に自分が入れた行を消す。
fn round_trip(pool: Name(pog.Message)) -> Nil {
  let db = pog.named_connection(pool)
  let key = random_master_key()
  let assert Ok(_loaded) = account_store.load(pool, key, generous)
  let assert Ok(_loaded) = account_store.load(pool, key, generous)

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

/// 書き込みを `pool` への実際のストアの操作で行い、読み込みは常に空を返す
/// バンカーアクターを起動し、その名前と pid を返す。アクターはテストプロセスに
/// リンクされるので、アクターが落ちればテストも落ちる。
fn start_bunker(pool: Name(pog.Message)) -> #(Name(bunker.Msg), Pid) {
  let name = process.new_name("account_store_test_bunker")
  let store =
    bunker.Store(
      ..nostr_no_su.account_store_operations(
        pool,
        random_master_key(),
        account_store.default_timeouts,
      ),
      load: fn() { Ok(vault.Loaded(accounts: [], skipped: [])) },
    )
  let assert Ok(started) =
    bunker.start(
      name,
      bunker.Settings(
        store:,
        auth_url: None,
        retry_delay: bunker.RetryDelay(initial_ms: 100, max_ms: 100),
      ),
      fn() { Nil },
    )
  #(name, started.pid)
}

/// テストで起動したアクターを、テストプロセスを巻き込まずに止める。
fn stop(pid: Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
}

/// チェックアウトの要求に `{error, econnreset}` で答える偽のプールを起動し、その
/// 名前を返す。このプールへの `pog.execute` は `function_clause` を投げる
/// （`test/support/resetting_pool.erl`）。状態を持たず、名前はテストごとに一意なので
/// 止めない。
fn start_resetting_pool() -> Name(pog.Message) {
  let name = process.new_name("account_store_test_resetting")
  let _pool = resetting_pool_start(name)
  name
}

/// `test/support/resetting_pool.erl` の `start/1`。
@external(erlang, "resetting_pool", "start")
fn resetting_pool_start(name: Name(pog.Message)) -> Pid
