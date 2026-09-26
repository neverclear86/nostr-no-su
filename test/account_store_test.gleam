//// `bunker/account_store` のテスト。純粋な部分は常に、実際の Postgres に対する
//// 統合テストは `TEST_DATABASE_URL` があるときだけ実行する。
////
//// 同じテーブルには過去の実行が残した行（別の乱数のマスターキーで暗号化された
//// もの）がありうるので、読み込みの結果はどれも自分が入れた pubkey に絞ってから
//// 比べる。

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Pid}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import nostr_no_su
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{type StoredAccount, StoredAccount}
import nostr_no_su/dedup/resume_store
import nostr_no_su/named
import nostr_no_su/nostr/event
import nostr_no_su/plugin_resume_store
import nostr_no_su/random
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/time
import pog
import support/log_capture
import support/nip46_client
import support/postgres
import support/random_account.{random_entry, random_master_key}
import support/signed_event
import support/vector.{contains_bytes}

/// 移行の文はすべて `IF NOT EXISTS` 付きか `DELETE FROM` で、途中で失敗した移行を
/// 頭から実行し直してよい。
pub fn migration_statements_can_be_re_run_test() {
  let statements =
    list.flat_map(account_store.migrations, fn(migration) {
      migration.statements
    })
  assert list.all(statements, fn(statement) {
    string.contains(statement, "IF NOT EXISTS")
    || string.starts_with(statement, "DELETE FROM ")
  })
}

/// `account_store.migrations` の版は 1 から欠番なく昇順に並ぶ。
pub fn migrations_are_numbered_from_one_without_gaps_test() {
  let versions = migration_versions()
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

/// 別のセッションが持つロックの説明はロックの番号を含み、書き込みは無かったことに
/// なる。
pub fn a_lock_held_elsewhere_is_described_without_values_test() {
  let error =
    account_store.HeldByAnotherInstance(account_store.instance_lock_key)
  assert string.contains(account_store.describe(error), "7237235")
  assert !account_store.may_have_been_written(error)
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

/// ロックのプールの設定は本数を 1 に絞り、名前を差し替え、それ以外はアカウントの
/// プールと変わらない。
pub fn lock_pool_config_uses_one_connection_test() {
  let assert Ok(pool) =
    account_store.pool_config(
      process.new_name("account_store_test_lock_pool_base"),
      "postgres://user:pw-marker@host:5432/db",
    )
  let name = process.new_name("account_store_test_lock_pool")
  let lock_pool = account_store.lock_pool_config(name, pool)
  assert lock_pool.pool_size == 1
  assert lock_pool.pool_name == name
  assert lock_pool.host == pool.host
  assert lock_pool.database == pool.database
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

/// 到達できないポートを指すプールを起動し、その名前を返す。待ち行列の目標と間隔は
/// 既定（50ms と 1000ms）より短くして、接続の無いプールがチェックアウトを諦める
/// までの待ち（既定では 2〜3 秒）を縮める。諦めたときの失敗の写し方は変わらない。
fn start_unreachable_pool(label: String) -> Name(pog.Message) {
  let name = process.new_name(label)
  let assert Ok(_pool) =
    pog.default_config(name)
    |> pog.port(1)
    |> pog.queue_target(10)
    |> pog.queue_interval(100)
    |> pog.start
  name
}

/// 到達できないプールへの読み込みは、例外にならず `Unavailable` を返す。
pub fn loading_from_an_unreachable_database_is_a_value_test() {
  let name = start_unreachable_pool("account_store_test_unreachable")
  assert account_store.load(
      name,
      random_master_key(),
      account_store.default_timeouts,
    )
    |> result.replace(Nil)
    == Error(account_store.Unavailable)
}

/// 到達できないプールでのロックの取得は、例外にならず `Unavailable` を返す。
pub fn acquiring_a_lock_on_an_unreachable_database_is_a_value_test() {
  let name = start_unreachable_pool("account_store_test_unreachable_lock")
  assert account_store.acquire_lock(
      pog.named_connection(name),
      account_store.instance_lock_key,
      account_store.default_timeouts,
    )
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
    start_bunker(
      process.new_name("account_store_test_missing"),
      random_master_key(),
    )
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
  let #(name, pid) = start_bunker(start_resetting_pool(), random_master_key())
  let entry = random_entry("resetting")
  assert bunker.add_account(name, entry.account, entry.label)
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert bunker.accounts(name) == Ok([])
  stop(pid)
}

/// バンカーアクターが動いていなければ、アカウントの変更はどれも
/// `MaybeApplied(BunkerDidNotRespond)` を返す（打ち切った後にアクターが処理し
/// うるため）。
pub fn account_changes_without_a_bunker_are_not_answered_test() {
  let name = process.new_name("account_store_test_missing_bunker")
  let entry = random_entry("missing-bunker")
  assert bunker.add_account(name, entry.account, entry.label)
    == Error(bunker.MaybeApplied(bunker.BunkerDidNotRespond))
  assert bunker.remove_account(name, "signer")
    == Error(bunker.MaybeApplied(bunker.BunkerDidNotRespond))
  assert bunker.rotate_secret(name, "signer")
    == Error(bunker.MaybeApplied(bunker.BunkerDidNotRespond))
  assert bunker.update_label(name, "signer", "label")
    == Error(bunker.MaybeApplied(bunker.BunkerDidNotRespond))
}

/// 実際の Postgres に対する統合テスト。追加、読み込み、更新、改ざん、削除を
/// 一巡させ、最後に自分が入れた行を消す。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。同じ DB に対して `gleam test` を並行実行することは想定して
/// いない。
pub fn postgres_round_trip_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  let pool = postgres.start_pool(database_url, None)
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

/// 版の記録より前に作られた DB が版 1 として取り込まれ、版が新しい DB は拒否される。
/// 専用のスキーマで行い、ビルドより新しい版の挿入もそのスキーマの接続に流す。
/// public の `schema_version` にその版が残ると、以後の `postgres_round_trip_test` の
/// 読み込みが `SchemaTooNew` で落ちるためである。`TEST_DATABASE_URL` があるとき
/// だけ実行する。
pub fn postgres_schema_version_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
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
  assert recorded_versions(db) == migration_versions()

  // 記録された版が新しい DB は拒否する。
  let assert Ok(latest) = list.last(migration_versions())
  postgres.run_statement(
    db,
    "INSERT INTO schema_version (version) VALUES ("
      <> int.to_string(latest + 1)
      <> ")",
  )
  assert account_store.load(pool, key, generous)
    == Error(account_store.SchemaTooNew(found: latest + 1, supported: latest))
}

/// 同じ番号の advisory lock は、同じセッションからは再入で取れ、別のセッションから
/// は取れない。セッションが解放すると別のセッションが取れる。セッション A、B は
/// `postgres.start_lock_pool` で起動した 1 本のプールの接続で、番号は乱数にし、他の
/// 統合テストが取る本番の番号（`account_store.instance_lock_key`）と衝突しない
/// ようにする。`TEST_DATABASE_URL` があるときだけ実行する。同じ DB に対して
/// `gleam test` を並行実行することは想定していない。
pub fn postgres_instance_lock_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  let key = int.random(1_000_000_000)
  let a = pog.named_connection(postgres.start_lock_pool(database_url))
  let b = pog.named_connection(postgres.start_lock_pool(database_url))

  assert account_store.acquire_lock(a, key, generous) == Ok(Nil)
  assert account_store.acquire_lock(a, key, generous) == Ok(Nil)
  assert account_store.acquire_lock(b, key, generous)
    == Error(account_store.HeldByAnotherInstance(key))

  postgres.run_statement(
    a,
    "DO $$ BEGIN PERFORM pg_advisory_unlock_all(); END $$",
  )
  assert account_store.acquire_lock(b, key, generous) == Ok(Nil)

  postgres.run_statement(
    b,
    "DO $$ BEGIN PERFORM pg_advisory_unlock_all(); END $$",
  )
}

/// 監視の購読の再開点は、DB からの読み込みと保存を一巡できる。移行の後に読み書き
/// できることは、`monitor_resume` が版 2 の移行で作られることの確認を兼ねる。
pub fn postgres_resume_store_test() {
  use database_url <- postgres.with_test_database_url("resume_store")
  use pool, db <- postgres.with_schema(database_url)

  // 移行を実行する。
  let assert Ok(_loaded) =
    account_store.load(pool, random_master_key(), generous)

  assert resume_store.load(db, "wss://a") == Ok(None)
  let assert Ok(Nil) = resume_store.save(db, [#("wss://a", 200)])
  assert resume_store.load(db, "wss://a") == Ok(Some(200))

  // 値を小さくする保存は無視する（GREATEST）。
  let assert Ok(Nil) = resume_store.save(db, [#("wss://a", 100)])
  assert resume_store.load(db, "wss://a") == Ok(Some(200))

  let assert Ok(Nil) = resume_store.save(db, [#("wss://a", 300)])
  assert resume_store.load(db, "wss://a") == Ok(Some(300))
}

/// プラグインごとの再開点は、DB からの読み込みと保存を一巡できる。移行の後に
/// 読み書きできることは、`plugin_resume` が版 5 の移行で作られることの確認を
/// 兼ねる。`TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_plugin_resume_store_test() {
  use database_url <- postgres.with_test_database_url("plugin_resume_store")
  use pool, db <- postgres.with_schema(database_url)

  // 移行を実行する。
  let assert Ok(_loaded) =
    account_store.load(pool, random_master_key(), generous)

  assert plugin_resume_store.load(db, "logger") == Ok(None)
  let assert Ok(Nil) = plugin_resume_store.save(db, [#("logger", 200)])
  assert plugin_resume_store.load(db, "logger") == Ok(Some(200))

  // 値を小さくする保存は無視する（GREATEST）。
  let assert Ok(Nil) = plugin_resume_store.save(db, [#("logger", 100)])
  assert plugin_resume_store.load(db, "logger") == Ok(Some(200))

  let assert Ok(Nil) = plugin_resume_store.save(db, [#("logger", 300)])
  assert plugin_resume_store.load(db, "logger") == Ok(Some(300))
}

/// 版 2 の DB（`bunker_accounts` と `monitor_resume` はあるがセッションと承認待ちの
/// テーブルは無い）に版 3 の移行が適用でき、読み込んだ `sessions` と `pending` は
/// 空になる。`TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_migrates_a_version_two_database_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)

  // 版 2 の DB を再現する。
  postgres.run_statement(db, account_store.create_version_table)
  postgres.run_statement(db, account_store.create_accounts_table)
  postgres.run_statement(db, account_store.create_monitor_resume_table)
  postgres.run_statement(
    db,
    "INSERT INTO schema_version (version) VALUES (1), (2)",
  )

  let assert Ok(loaded) =
    account_store.load(pool, random_master_key(), generous)
  assert recorded_versions(db) == migration_versions()
  assert loaded.sessions == []
  assert loaded.pending == []
}

/// セッションと承認待ちの読み書きを一巡させる。空の DB への版 3 の適用、書いた値を
/// 読み直すと同じ内容で戻ること、同じ主キーの 2 回の挿入がエラーにならないこと、
/// `approve`、アカウントの削除でその署名者の行が消えることを確かめる。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_bunker_state_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let now = 1_700_000_000

  // 1. 空のスキーマで load が Ok を返し、版が移行の版の一覧と同じになる。
  let assert Ok(empty) = account_store.load(pool, key, generous)
  assert recorded_versions(db) == migration_versions()
  assert empty.sessions == []
  assert empty.pending == []

  // 2. A, B を登録し、それぞれにセッションと承認待ちを 1 件ずつ挿す。同じ引数の
  // 挿入をもう一度呼んでも Ok（セッションは ON CONFLICT DO UPDATE、承認待ちは DO NOTHING）。
  let a = random_entry("a")
  let b = random_entry("b")
  let a_pubkey = account.pubkey_hex(a.account)
  let b_pubkey = account.pubkey_hex(b.account)
  let assert Ok(Nil) = account_store.insert(db, key, a, generous)
  let assert Ok(Nil) = account_store.insert(db, key, b, generous)

  let pa =
    account_store.StoredPending(
      token: "token-a",
      signer: a_pubkey,
      client: "pending-client-a",
      request_id: "req-a",
      perms: "",
      secret_mismatch: False,
      created_at: now,
    )
  let pb =
    account_store.StoredPending(
      token: "token-b",
      signer: b_pubkey,
      client: "pending-client-b",
      request_id: "req-b",
      perms: "sign_event:1",
      secret_mismatch: True,
      created_at: now + 1,
    )
  let insert_a_and_b = fn() {
    let assert Ok(Nil) =
      account_store.insert_session(
        db,
        key,
        generous,
        session: account_store.StoredSession(
          signer: a_pubkey,
          client: "client-a",
          perms: "",
          created_at: now,
          last_used_at: now,
          relays: [],
        ),
      )
    let assert Ok(Nil) =
      account_store.insert_session(
        db,
        key,
        generous,
        session: account_store.StoredSession(
          signer: b_pubkey,
          client: "client-b",
          perms: "sign_event:1",
          created_at: now + 1,
          last_used_at: now + 1,
          relays: [],
        ),
      )
    let assert Ok(Nil) = account_store.insert_pending(db, key, pa, generous)
    let assert Ok(Nil) = account_store.insert_pending(db, key, pb, generous)
    Nil
  }
  insert_a_and_b()
  // 同じ引数でもう一度呼んでも、セッションは ON CONFLICT DO UPDATE、承認待ちは DO NOTHING で Ok になる。
  insert_a_and_b()

  // 3. load の sessions が A, B の 2 件、pending が [pa, pb]。
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert loaded.sessions
    == [
      account_store.StoredSession(
        signer: a_pubkey,
        client: "client-a",
        perms: "",
        created_at: now,
        last_used_at: now,
        relays: [],
      ),
      account_store.StoredSession(
        signer: b_pubkey,
        client: "client-b",
        perms: "sign_event:1",
        created_at: now + 1,
        last_used_at: now + 1,
        relays: [],
      ),
    ]
  assert loaded.pending == [pa, pb]

  // 4. 行があるときの削除: A に 2 件目のセッションと承認待ちを挿してから消すと、
  // load が手順 3 と同じになる。
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      key,
      generous,
      session: account_store.StoredSession(
        signer: a_pubkey,
        client: "client-a-2",
        perms: "",
        created_at: now + 2,
        last_used_at: now + 2,
        relays: [],
      ),
    )
  let pa2 =
    account_store.StoredPending(
      token: "token-a2",
      signer: a_pubkey,
      client: "pending-client-a2",
      request_id: "req-a2",
      perms: "",
      secret_mismatch: False,
      created_at: now + 2,
    )
  let assert Ok(Nil) = account_store.insert_pending(db, key, pa2, generous)
  let assert Ok(Nil) =
    account_store.delete_session(
      db,
      generous,
      signer: a_pubkey,
      client: "client-a-2",
    )
  let assert Ok(Nil) =
    account_store.delete_pending(db, generous, token: pa2.token)
  let assert Ok(after_row_delete) = account_store.load(pool, key, generous)
  assert after_row_delete.sessions == loaded.sessions
  assert after_row_delete.pending == loaded.pending

  // 5. 行が無いときの削除も Ok。
  let assert Ok(Nil) =
    account_store.delete_session(
      db,
      generous,
      signer: a_pubkey,
      client: "client-a-2",
    )
  let assert Ok(Nil) =
    account_store.delete_pending(db, generous, token: pa2.token)

  // 6. approve: 承認待ちの行が消え、セッションが増える。
  let pa3 =
    account_store.StoredPending(
      token: "token-a3",
      signer: a_pubkey,
      client: "client-a3",
      request_id: "req-a3",
      perms: "sign_event:0,sign_event:1",
      secret_mismatch: False,
      created_at: now + 3,
    )
  let assert Ok(Nil) = account_store.insert_pending(db, key, pa3, generous)
  let assert Ok(Nil) =
    account_store.approve(
      pool,
      key,
      generous,
      token: pa3.token,
      session: account_store.StoredSession(
        signer: a_pubkey,
        client: pa3.client,
        perms: pa3.perms,
        created_at: now + 4,
        last_used_at: now + 4,
        relays: [],
      ),
      evicted: [],
    )
  let assert Ok(after_approve) = account_store.load(pool, key, generous)
  assert after_approve.pending == [pa, pb]
  assert after_approve.sessions
    == [
      account_store.StoredSession(
        signer: a_pubkey,
        client: "client-a",
        perms: "",
        created_at: now,
        last_used_at: now,
        relays: [],
      ),
      account_store.StoredSession(
        signer: b_pubkey,
        client: "client-b",
        perms: "sign_event:1",
        created_at: now + 1,
        last_used_at: now + 1,
        relays: [],
      ),
      account_store.StoredSession(
        signer: a_pubkey,
        client: pa3.client,
        perms: pa3.perms,
        created_at: now + 4,
        last_used_at: now + 4,
        relays: [],
      ),
    ]

  // 7. アカウントの削除: A のセッションと承認待ちが消え、B だけ残る。
  let assert Ok(Nil) = account_store.delete(db, a_pubkey, generous)
  let assert Ok(after_account_delete) = account_store.load(pool, key, generous)
  assert after_account_delete.sessions
    == [
      account_store.StoredSession(
        signer: b_pubkey,
        client: "client-b",
        perms: "sign_event:1",
        created_at: now + 1,
        last_used_at: now + 1,
        relays: [],
      ),
    ]
  assert after_account_delete.pending == [pb]
}

/// MAC の合わない行は読み込みに使われず `Stored.rejected` に分けられ、
/// `load_snapshot` が 1 行ずつ warning で出す。列の改ざん、別の行の MAC の移植、
/// MAC の無い行（移行前の行が残ったときの形）はどれも使われない。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_rows_with_a_mismatched_mac_are_not_loaded_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let mark = random.hex(8)
  let assert Ok(_migrated) = account_store.load(pool, key, generous)
  let entry = random_entry("mac")
  let signer = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  // 正しい MAC の行と、あとで MAC が合わなくなる行 2 件を入れる。
  let ok_session =
    account_store.StoredSession(
      signer:,
      client: "client-ok-" <> mark,
      perms: "",
      created_at: 1,
      last_used_at: 1,
      relays: [],
    )
  let assert Ok(Nil) =
    account_store.insert_session(db, key, generous, session: ok_session)
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      key,
      generous,
      session: account_store.StoredSession(
        signer:,
        client: "client-tampered-" <> mark,
        perms: "",
        created_at: 2,
        last_used_at: 2,
        relays: [],
      ),
    )
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      key,
      generous,
      session: account_store.StoredSession(
        signer:,
        client: "client-copied-" <> mark,
        perms: "",
        created_at: 3,
        last_used_at: 3,
        relays: [],
      ),
    )
  // 列の値を書き換えると、残っている MAC と合わなくなる。
  postgres.run_statement(
    db,
    "UPDATE bunker_sessions SET perms = 'forged' WHERE client = 'client-tampered-"
      <> mark
      <> "'",
  )
  // 別の行の MAC を移植しても、その行の値とは合わない。
  postgres.run_statement(
    db,
    "UPDATE bunker_sessions SET mac = (SELECT mac FROM bunker_sessions WHERE client = 'client-ok-"
      <> mark
      <> "') WHERE client = 'client-copied-"
      <> mark
      <> "'",
  )
  // 移行前の行が残ったときの形（MAC が無い）を再現する。
  postgres.run_statement(
    db,
    "INSERT INTO bunker_pending (token, signer, client, request_id, perms, secret_mismatch, created_at, mac) VALUES ('token-"
      <> mark
      <> "', '"
      <> signer
      <> "', 'client-pending-"
      <> mark
      <> "', 'req-"
      <> mark
      <> "', '', false, 4, ''::bytea)",
  )

  let capture = log_capture.install()
  let assert Ok(_snapshot) = nostr_no_su.load_snapshot(pool, key, generous)
  let lines = log_capture.lines(capture)
  log_capture.remove(capture)
  assert list.length(list.filter(lines, string.contains(_, mark))) == 3

  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert loaded.sessions == [ok_session]
  assert loaded.pending == []
  assert loaded.rejected
    == [
      vault.SessionMacRow(
        signer:,
        client: "client-tampered-" <> mark,
        perms: "forged",
        created_at: 2,
        last_used_at: 2,
        relays: [],
      ),
      vault.SessionMacRow(
        signer:,
        client: "client-copied-" <> mark,
        perms: "",
        created_at: 3,
        last_used_at: 3,
        relays: [],
      ),
      vault.PendingMacRow(
        token: "token-" <> mark,
        signer:,
        client: "client-pending-" <> mark,
        request_id: "req-" <> mark,
        perms: "",
        secret_mismatch: False,
        created_at: 4,
      ),
    ]
}

/// MAC の合わない行が主キーを塞いでいても、承認は正しい値で上書きする
/// （`insert_session` の `ON CONFLICT DO UPDATE`）。`TEST_DATABASE_URL` がある
/// ときだけ実行する。
pub fn postgres_an_approval_replaces_a_row_with_a_mismatched_mac_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)
  let entry = random_entry("approve-mac")
  let signer = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      key,
      generous,
      session: account_store.StoredSession(
        signer:,
        client: "client",
        perms: "a",
        created_at: 1,
        last_used_at: 1,
        relays: [],
      ),
    )
  postgres.run_statement(
    db,
    "UPDATE bunker_sessions SET perms = 'forged' WHERE client = 'client'",
  )
  let session =
    account_store.StoredSession(
      signer:,
      client: "client",
      perms: "b",
      created_at: 5,
      last_used_at: 7,
      relays: [],
    )
  let assert Ok(Nil) =
    account_store.approve(
      pool,
      key,
      generous,
      token: "token",
      session:,
      evicted: [],
    )
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert loaded.sessions == [session]
  assert loaded.pending == []
  assert loaded.rejected == []
}

/// アカウントを消すとその署名者のセッションと承認待ちも消える（ON DELETE
/// CASCADE）ので、マスターキーを変えて登録し直しても、別の鍵で書かれた行は
/// 残らない。`TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_sessions_are_read_after_the_master_key_is_changed_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let old_key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, old_key, generous)
  let entry = random_entry("rekey")
  let signer = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, old_key, entry, generous)
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      old_key,
      generous,
      session: account_store.StoredSession(
        signer:,
        client: "old-client",
        perms: "",
        created_at: 1,
        last_used_at: 1,
        relays: [],
      ),
    )
  let assert Ok(Nil) =
    account_store.insert_pending(
      db,
      old_key,
      account_store.StoredPending(
        token: "old-token",
        signer:,
        client: "old-client",
        request_id: "req",
        perms: "",
        secret_mismatch: False,
        created_at: 1,
      ),
      generous,
    )

  // アカウントを消すと、その署名者のセッションと承認待ちも消える。
  let assert Ok(Nil) = account_store.delete(db, signer, generous)
  let new_key = random_master_key()
  let assert Ok(Nil) = account_store.insert(db, new_key, entry, generous)
  let session =
    account_store.StoredSession(
      signer:,
      client: "client",
      perms: "sign_event:1",
      created_at: 2,
      last_used_at: 2,
      relays: [],
    )
  let assert Ok(Nil) =
    account_store.insert_session(db, new_key, generous, session: session)

  let assert Ok(loaded) = account_store.load(pool, new_key, generous)
  assert loaded.sessions == [session]
  assert loaded.pending == []
  assert loaded.rejected == []
}

/// 版 6 の移行は、MAC を持たない既存のセッションと承認待ちの行を消してから
/// `mac` 列を足す。移行の後は MAC つきの行を書き込み、読み込める。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_migration_clears_sessions_and_pending_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()

  // 版 5 の DB を再現する。
  postgres.run_statement(db, account_store.create_version_table)
  account_store.migrations
  |> list.filter(fn(migration) { migration.version <= 5 })
  |> list.each(fn(migration) {
    list.each(migration.statements, postgres.run_statement(db, _))
  })
  postgres.run_statement(
    db,
    "INSERT INTO schema_version (version) VALUES (1), (2), (3), (4), (5)",
  )
  let entry = random_entry("migrate")
  let signer = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)
  postgres.run_statement(
    db,
    "INSERT INTO bunker_sessions (signer, client, perms, created_at, last_used_at) VALUES ('"
      <> signer
      <> "', 'client', '', 1, 1)",
  )
  postgres.run_statement(
    db,
    "INSERT INTO bunker_pending (token, signer, client, request_id, perms, secret_mismatch, created_at) VALUES ('token', '"
      <> signer
      <> "', 'client', 'req', '', false, 1)",
  )

  // 版 6 の移行が既存の行を消してから `mac` 列を足す。
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert recorded_versions(db) == migration_versions()
  assert loaded.sessions == []
  assert loaded.pending == []
  assert loaded.rejected == []

  // 移行の後は MAC つきで書き込みと読み込みができる。
  let session =
    account_store.StoredSession(
      signer:,
      client: "client",
      perms: "",
      created_at: 2,
      last_used_at: 2,
      relays: [],
    )
  let assert Ok(Nil) =
    account_store.insert_session(db, key, generous, session: session)
  let assert Ok(after) = account_store.load(pool, key, generous)
  assert after.sessions == [session]
}

/// 版 7 の移行は既存のセッションの行を消さずに `relays` 列を足し、版 6 で MAC を
/// 付けた行は空の一覧のまま、同じ MAC で読める。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_migration_keeps_sessions_with_empty_relays_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()

  // 版 6 の DB を再現する。
  postgres.run_statement(db, account_store.create_version_table)
  account_store.migrations
  |> list.filter(fn(migration) { migration.version <= 6 })
  |> list.each(fn(migration) {
    list.each(migration.statements, postgres.run_statement(db, _))
  })
  postgres.run_statement(
    db,
    "INSERT INTO schema_version (version) VALUES (1), (2), (3), (4), (5), (6)",
  )
  let entry = random_entry("relays")
  let signer = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)
  let mac =
    vault.row_mac(
      key,
      vault.SessionMacRow(
        signer:,
        client: "client",
        perms: "sign_event",
        created_at: 1,
        last_used_at: 2,
        relays: [],
      ),
    )
  postgres.run_statement(
    db,
    "INSERT INTO bunker_sessions (signer, client, perms, created_at, last_used_at, mac) VALUES ('"
      <> signer
      <> "', 'client', 'sign_event', 1, 2, decode('"
      <> bit_array.base16_encode(mac)
      <> "', 'hex'))",
  )

  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert recorded_versions(db) == migration_versions()
  assert loaded.rejected == []
  assert loaded.sessions
    == [
      account_store.StoredSession(
        signer:,
        client: "client",
        perms: "sign_event",
        created_at: 1,
        last_used_at: 2,
        relays: [],
      ),
    ]
}

/// トランザクションの中の `run` が `Error` を返すと、先に行った書き込みが残らない。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_transaction_rolls_back_on_error_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()

  let entry = random_entry("rollback")
  let pubkey = account.pubkey_hex(entry.account)
  // 移行を実行してから、外部キーの対象になるアカウントを 1 件登録する。
  let assert Ok(_loaded) = account_store.load(pool, key, generous)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let outcome =
    account_store.transaction(pool, generous.write_ms, fn(db) {
      use Nil <- result.try(account_store.insert_session(
        db,
        key,
        generous,
        session: account_store.StoredSession(
          signer: pubkey,
          client: "client",
          perms: "",
          created_at: 1,
          last_used_at: 1,
          relays: [],
        ),
      ))
      Error(account_store.QueryFailed("forced"))
    })
  assert outcome == Error(account_store.QueryFailed("forced"))

  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert loaded.sessions == []
}

/// `relay_store` の一覧・追加・用途の更新・削除。`TEST_DATABASE_URL` があるときだけ
/// 実行する。
pub fn postgres_relay_store_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)

  // 移行を実行する。
  let assert Ok(_loaded) =
    account_store.load(pool, random_master_key(), generous)

  assert relay_store.list(db, generous) == Ok([])

  // 追加は id の順に戻り、`observe` は監視の用途に写る。
  let assert Ok(a) =
    relay_store.insert(db, "wss://a", relay_list.MonitorOnly, generous)
  let assert Ok(b) =
    relay_store.insert(db, "wss://b", relay_list.BunkerOnly, generous)
  assert relay_store.list(db, generous) == Ok([a, b])
  assert a.roles == relay_list.MonitorOnly

  // 同じ URL の追加は他の DB の失敗と区別できる値で返る。
  assert relay_store.insert(db, "wss://a", relay_list.Both, generous)
    == Error(account_store.RelayAlreadyRegistered)

  // 用途の更新が反映される。
  let assert Ok(Nil) =
    relay_store.update_roles(db, a.id, relay_list.Both, generous)
  let assert Ok([updated_a, _updated_b]) = relay_store.list(db, generous)
  assert updated_a.roles == relay_list.Both

  // 無い id の更新と削除は区別できる値で返る。
  assert relay_store.update_roles(db, -1, relay_list.Both, generous)
    == Error(account_store.RelayNotRegistered)
  assert relay_store.delete(db, -1, generous)
    == Error(account_store.RelayNotRegistered)

  // 削除で消える。
  let assert Ok(Nil) = relay_store.delete(db, a.id, generous)
  assert relay_store.list(db, generous) == Ok([b])
}

/// `observe` と `bunker` がどちらも false の行は `relay_store.list` が読まない。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_relay_store_list_skips_roleless_rows_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)

  // 移行を実行する。
  let assert Ok(_loaded) =
    account_store.load(pool, random_master_key(), generous)

  postgres.run_statement(
    db,
    "INSERT INTO relays (url, observe, bunker) VALUES ('wss://none', false, false)",
  )
  assert relay_store.list(db, generous) == Ok([])
}

/// `nostr_no_su.load_snapshot` は移行を含む読み込みと同じトランザクションで
/// `relays` を読み、登録の順に並べる。advisory lock を通す
/// `account_store_operations` の `load` はロックが取れなければ VM を止めるので
/// （`nostr_no_su.gleam` の `halt_if_cannot_continue`）ここでは使わない。
/// `TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_load_snapshot_reads_relays_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()

  // 移行を実行してから行を足す。
  let assert Ok(_loaded) = account_store.load(pool, key, generous)
  let assert Ok(_a) =
    relay_store.insert(db, "wss://a", relay_list.MonitorOnly, generous)
  let assert Ok(_b) =
    relay_store.insert(db, "wss://b", relay_list.BunkerOnly, generous)

  let assert Ok(snapshot) = nostr_no_su.load_snapshot(pool, key, generous)
  assert snapshot.relays
    == [
      relay_list.Registered(url: "wss://a", roles: relay_list.MonitorOnly),
      relay_list.Registered(url: "wss://b", roles: relay_list.BunkerOnly),
    ]
}

/// テストのクライアントから署名者宛の、本文 `body` のリクエストを検証済みイベント
/// にする。`bunker.Incoming` の入力に使う。
fn client_request(
  client: account.Account,
  signer: account.Account,
  body: String,
) -> event.Verified {
  let assert Ok(verified) =
    event.verify(nip46_client.request_event(
      client,
      signer,
      body,
      time.now_seconds(),
    ))
  verified
}

/// `StoredSession` から作成・最終利用時刻とリレーを除いた組。行の内容だけを
/// 比べるために使う。
fn session_tuple(
  session: account_store.StoredSession,
) -> #(String, String, String) {
  #(session.signer, session.client, session.perms)
}

/// 実際の Postgres に対する統合テスト。`connect`（セッションと承認待ち、
/// 再登録）、`logout`、承認・拒否・取り消しが成功したときだけ `account_store` の
/// 行が書かれる（`start_bunker` の経路）。`TEST_DATABASE_URL` があるときだけ
/// 実行する。
pub fn postgres_bunker_session_writes_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, _db <- postgres.with_schema(database_url)
  let key = random_master_key()
  // 移行してから、書き込みが実際のストアの操作を使うアクターを起動する。
  let assert Ok(_migrated) = account_store.load(pool, key, generous)
  let #(name, pid) = start_bunker(pool, key)

  let entry = random_entry("writes")
  let signer = entry.account
  let signer_hex = account.pubkey_hex(signer)
  assert bunker.add_account(name, signer, entry.label) == Ok(Nil)
  let assert Ok([bunker.Listing(secret:, ..)]) = bunker.accounts(name)
  let connect = fn(client, secret_arg, id) {
    named.send(
      name,
      bunker.Incoming(client_request(
        client,
        signer,
        nip46_client.connect_body(signer, secret_arg, id),
      )),
    )
  }

  // クライアント 1: 承認待ちの登録と承認。
  let assert Ok(client1) = account.from_privkey(crypto.strong_random_bytes(32))
  let client1_hex = account.pubkey_hex(client1)
  connect(client1, "", "c1")
  let assert Ok([pending1]) = bunker.pending(name)
  let assert Ok(after_connect) = account_store.load(pool, key, generous)
  assert list.map(after_connect.pending, fn(row) { row.token })
    == [pending1.token]
  assert bunker.approve(name, pending1.token) == Ok(Nil)

  let assert Ok(after_approve) = account_store.load(pool, key, generous)
  assert after_approve.pending == []
  assert list.map(after_approve.sessions, session_tuple)
    == [#(signer_hex, client1_hex, "")]

  // クライアント 2: 承認待ちの再登録（replaced）と拒否。
  let assert Ok(client2) = account.from_privkey(crypto.strong_random_bytes(32))
  connect(client2, "", "c2")
  let assert Ok([_first]) = bunker.pending(name)
  connect(client2, "", "c2-again")
  let assert Ok([pending2]) = bunker.pending(name)
  let assert Ok(after_reconnect) = account_store.load(pool, key, generous)
  assert list.map(after_reconnect.pending, fn(row) { row.token })
    == [pending2.token]
  assert bunker.deny(name, pending2.token) == Ok(Nil)

  let assert Ok(after_deny) = account_store.load(pool, key, generous)
  assert after_deny.pending == []
  assert list.map(after_deny.sessions, session_tuple)
    == [#(signer_hex, client1_hex, "")]

  // クライアント 3: secret の一致でセッションを開き、logout で閉じる。
  let assert Ok(client3) = account.from_privkey(crypto.strong_random_bytes(32))
  let client3_hex = account.pubkey_hex(client3)
  connect(client3, secret, "c3")
  let assert Ok([_, _]) = bunker.sessions(name)
  let assert Ok(after_open) = account_store.load(pool, key, generous)
  let after_open_tuples = list.map(after_open.sessions, session_tuple)
  assert list.length(after_open_tuples) == 2
  assert list.contains(after_open_tuples, #(signer_hex, client1_hex, ""))
  assert list.contains(after_open_tuples, #(signer_hex, client3_hex, ""))
  named.send(
    name,
    bunker.Incoming(client_request(
      client3,
      signer,
      nip46_client.request_body("l3", "logout", "[]"),
    )),
  )
  let assert Ok([_]) = bunker.sessions(name)
  let assert Ok(after_logout) = account_store.load(pool, key, generous)
  assert list.map(after_logout.sessions, session_tuple)
    == [#(signer_hex, client1_hex, "")]

  // 取り消し。
  assert bunker.revoke(name, signer_hex, client1_hex) == Ok(Nil)
  let assert Ok(after_revoke) = account_store.load(pool, key, generous)
  assert after_revoke.sessions == []

  stop(pid)
}

/// 実際の Postgres に対する統合テスト。`InsertPending` の写しは、`replaced` の
/// 削除と挿入を 1 トランザクションで行う。`TEST_DATABASE_URL` があるときだけ
/// 実行する。
pub fn postgres_replacing_a_pending_request_is_one_transaction_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)

  let entry = random_entry("replacing")
  let signer_hex = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let write = store_write(pool, key)

  let old_pending =
    engine.Pending(
      token: "old",
      signer: signer_hex,
      client: "client",
      request_id: "req-old",
      perms: "",
      secret_mismatch: False,
      created_at: 1,
    )
  assert write(
      engine.InsertPending(pending: old_pending, replaced: [], evicted: []),
    )
    == Ok(Nil)
  let new_pending =
    engine.Pending(
      token: "new",
      signer: signer_hex,
      client: "client",
      request_id: "req-new",
      perms: "",
      secret_mismatch: False,
      created_at: 2,
    )
  assert write(
      engine.InsertPending(pending: new_pending, replaced: ["old"], evicted: []),
    )
    == Ok(Nil)
  let assert Ok(after_replace) = account_store.load(pool, key, generous)
  assert list.map(after_replace.pending, fn(row) { row.token }) == ["new"]

  // 未登録の署名者への差し替えは外部キー違反で失敗し、削除だけが残らない
  // （1 トランザクション）。
  let unregistered_pending =
    engine.Pending(
      token: "unregistered",
      signer: account.pubkey_hex(random_entry("unregistered").account),
      client: "client",
      request_id: "req-unregistered",
      perms: "",
      secret_mismatch: False,
      created_at: 3,
    )
  let assert Error(bunker.NotWritten(_reason)) =
    write(
      engine.InsertPending(
        pending: unregistered_pending,
        replaced: ["new"],
        evicted: [],
      ),
    )

  let assert Ok(after_failed_replace) = account_store.load(pool, key, generous)
  assert list.map(after_failed_replace.pending, fn(row) { row.token })
    == ["new"]
}

/// `touch_session` は最終利用を進め、後退させず、行が無くても `Ok`。
pub fn postgres_touching_a_session_moves_its_last_use_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)

  let entry = random_entry("touch")
  let signer_hex = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let write = store_write(pool, key)
  let session = fn(client: String, last_used_at: Int) {
    engine.Session(
      signer: signer_hex,
      client: client,
      perms: "",
      created_at: 1000,
      last_used_at: last_used_at,
      relays: [],
    )
  }

  assert write(
      engine.InsertSession(session: session("client", 1000), evicted: []),
    )
    == Ok(Nil)
  assert write(engine.TouchSession(session: session("client", 1060))) == Ok(Nil)
  // 後退はしない。
  assert write(engine.TouchSession(session: session("client", 1030))) == Ok(Nil)
  // 無い組は何もせず Ok。
  assert write(engine.TouchSession(session: session("no-such-client", 1090)))
    == Ok(Nil)

  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert list.map(loaded.sessions, fn(session) {
      #(session.client, session.created_at, session.last_used_at)
    })
    == [#("client", 1000, 1060)]
}

/// `nostrconnect://` で開いたセッションの URI のリレーは、`InsertSession` と
/// `TouchSession` の書き込みの後も、`nostr_no_su.load_snapshot` で読み直した
/// セッションに同じ順で残る。`TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_session_relays_survive_a_reload_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)
  let entry = random_entry("reload")
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let write = store_write(pool, key)
  let session =
    engine.Session(
      signer: account.pubkey_hex(entry.account),
      client: "client",
      perms: "",
      created_at: 1000,
      last_used_at: 1000,
      relays: ["wss://b.example", "wss://a.example"],
    )
  assert write(engine.InsertSession(session: session, evicted: [])) == Ok(Nil)
  let touched = engine.Session(..session, last_used_at: 1060)
  assert write(engine.TouchSession(session: touched)) == Ok(Nil)

  let assert Ok(snapshot) = nostr_no_su.load_snapshot(pool, key, generous)
  assert snapshot.sessions == [touched]
}

/// `update_session_perms` は `perms` を差し替え、行が無くても `Ok`。
pub fn postgres_updating_session_perms_writes_the_new_value_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)

  let entry = random_entry("update-perms")
  let signer_hex = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let write = store_write(pool, key)
  let session = fn(client: String, perms: String) {
    engine.Session(
      signer: signer_hex,
      client: client,
      perms: perms,
      created_at: 1000,
      last_used_at: 1000,
      relays: [],
    )
  }

  assert write(
      engine.InsertSession(session: session("client", ""), evicted: []),
    )
    == Ok(Nil)
  assert write(
      engine.UpdateSessionPerms(session: session(
        "client",
        "sign_event:1,sign_event:10002",
      )),
    )
    == Ok(Nil)
  // 無い組は何もせず Ok。
  assert write(
      engine.UpdateSessionPerms(session: session("no-such-client", "sign_event")),
    )
    == Ok(Nil)

  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert list.map(loaded.sessions, fn(session) {
      #(session.client, session.perms)
    })
    == [#("client", "sign_event:1,sign_event:10002")]
}

/// `pool` に向けた `nostr_no_su.account_store_operations` の `write` を、期限
/// `generous` で返す。`write` はロックのプールを使わないので、ロックには起動して
/// いないプールの名前を渡す。
fn store_write(
  pool: Name(pog.Message),
  key: vault.MasterKey,
) -> fn(engine.Write) -> Result(Nil, bunker.WriteFailure) {
  nostr_no_su.account_store_operations(
    pool,
    process.new_name("account_store_test_unreachable_lock"),
    key,
    generous,
  ).write
}

/// エンジンだけで `count` 件の別々のクライアント鍵からの `connect`（secret は
/// `secret_arg`）を順に処理し、`Persist` の書き込みをそのつど `write` で DB に
/// 反映して次のエンジンで続ける。n 件目は時刻 1000 + n、token `tok-<n>` で送る。
fn connect_clients(
  state: engine.Engine,
  write: fn(engine.Write) -> Result(Nil, bunker.WriteFailure),
  entry: StoredAccount,
  secret_arg: String,
  count: Int,
) -> engine.Engine {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) { index + 1 })
  |> list.fold(state, fn(state, n) {
    let client = nip46_client.account_for(nip46_client.padded_hex(n))
    let incoming =
      nip46_client.request_event(
        client,
        entry.account,
        nip46_client.connect_body(entry.account, secret_arg, "c1"),
        1000 + n,
      )
    let engine.Handled(engine: _seen, outcome:, ..) =
      engine.handle_event(
        state,
        signed_event.verified(incoming),
        engine.Inputs(
          now: 1000 + n,
          token: "tok-" <> int.to_string(n),
          not_before: 0,
        ),
      )
    let assert engine.Persist(write: change, next:, ..) = outcome
    let assert Ok(Nil) = write(change)
    next
  })
}

/// 実際の Postgres に対する統合テスト。上限ちょうどより 1 件多いクライアントが
/// 順に `connect` すると、DB の行数も `session_capacity` で頭打ちになり、行の
/// クライアントの集合はエンジンのセッションと一致する。`TEST_DATABASE_URL` が
/// あるときだけ実行する。
pub fn postgres_sessions_stay_within_the_capacity_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)

  let entry = random_entry("capacity")
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let write = store_write(pool, key)

  let final_engine =
    connect_clients(
      engine.new([#(entry.account, entry.secret)], None),
      write,
      entry,
      entry.secret,
      engine.session_capacity + 1,
    )

  let assert Ok(after) = account_store.load(pool, key, generous)
  assert list.length(after.sessions) == engine.session_capacity
  assert list.map(after.sessions, fn(row) { row.client })
    |> list.sort(string.compare)
    == engine.sessions(final_engine)
    |> list.map(fn(session) { session.client })
    |> list.sort(string.compare)
}

/// 実際の Postgres に対する統合テスト。上限ちょうどより 1 件多いクライアントが
/// secret 無しで順に `connect` すると、DB の承認待ちの行数も `pending_capacity`
/// で頭打ちになり、最も古い `tok-1` を含まず、行の token の集合はエンジンの
/// 承認待ちと一致する。`TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_pending_stays_within_the_capacity_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use pool, db <- postgres.with_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)

  let entry = random_entry("pending-capacity")
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let write = store_write(pool, key)

  let final_engine =
    connect_clients(
      engine.new([#(entry.account, entry.secret)], Some(fn(token) { token })),
      write,
      entry,
      "",
      engine.pending_capacity + 1,
    )

  let assert Ok(after) = account_store.load(pool, key, generous)
  assert list.length(after.pending) == engine.pending_capacity
  assert !list.any(after.pending, fn(row) { row.token == "tok-1" })
  assert list.map(after.pending, fn(row) { row.token })
    |> list.sort(string.compare)
    == engine.pending(final_engine, 1017)
    |> list.map(fn(pending) { pending.token })
    |> list.sort(string.compare)
}

/// セッションの削除を拒むトリガー。`{schema}` は専用のスキーマの名前に置き換える。
const reject_session_delete = [
  "CREATE FUNCTION {schema}.reject_session_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'delete rejected for test';
END
$$",
  "CREATE TRIGGER reject_session_delete BEFORE DELETE ON {schema}.bunker_sessions
FOR EACH ROW EXECUTE FUNCTION {schema}.reject_session_delete()",
]

/// 実際の Postgres に対する統合テスト。押し出しの削除が失敗すると、`InsertSession`
/// と `ApprovePending` はどちらも挿入だけを残さず、行は書き込み前のままになる
/// （1 トランザクション）。`TEST_DATABASE_URL` があるときだけ実行する。
pub fn postgres_a_failed_eviction_leaves_no_inserted_session_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  use schema, pool, db <- postgres.with_named_schema(database_url)
  let key = random_master_key()
  let assert Ok(_migrated) = account_store.load(pool, key, generous)

  let entry = random_entry("eviction")
  let signer_hex = account.pubkey_hex(entry.account)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)

  let write = store_write(pool, key)

  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      key,
      generous,
      session: account_store.StoredSession(
        signer: signer_hex,
        client: "old",
        perms: "",
        created_at: 1000,
        last_used_at: 1000,
        relays: [],
      ),
    )
  let pending =
    account_store.StoredPending(
      token: "tok",
      signer: signer_hex,
      client: "new",
      request_id: "req",
      perms: "",
      secret_mismatch: False,
      created_at: 1000,
    )
  let assert Ok(Nil) = account_store.insert_pending(db, key, pending, generous)

  list.each(reject_session_delete, fn(statement) {
    postgres.run_statement(db, string.replace(statement, "{schema}", schema))
  })

  let assert Error(bunker.NotWritten(_reason)) =
    write(
      engine.InsertSession(
        session: engine.Session(
          signer: signer_hex,
          client: "another",
          perms: "",
          created_at: 1001,
          last_used_at: 1001,
          relays: [],
        ),
        evicted: [#(signer_hex, "old")],
      ),
    )
  let assert Ok(after_insert) = account_store.load(pool, key, generous)
  assert list.map(after_insert.sessions, fn(row) { row.client }) == ["old"]

  let assert Error(bunker.NotWritten(_reason)) =
    write(
      engine.ApprovePending(
        token: "tok",
        session: engine.Session(
          signer: signer_hex,
          client: "new",
          perms: "",
          created_at: 1002,
          last_used_at: 1002,
          relays: [],
        ),
        evicted: [#(signer_hex, "old")],
      ),
    )
  let assert Ok(after_approve) = account_store.load(pool, key, generous)
  assert list.map(after_approve.sessions, fn(row) { row.client }) == ["old"]
  assert list.map(after_approve.pending, fn(row) { row.token }) == ["tok"]
}

/// `account_store.migrations` の版の一覧（定義の順）。
fn migration_versions() -> List(Int) {
  list.map(account_store.migrations, fn(migration) { migration.version })
}

/// `schema_version` に記録されている版の一覧（昇順）。
fn recorded_versions(db: pog.Connection) -> List(Int) {
  let assert Ok(returned) =
    pog.query("SELECT version FROM schema_version ORDER BY version")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(on: db)
  returned.rows
}

/// 統合テストの期限。実際の DB との往復は負荷の高い環境で本番の期限（書き込み
/// 1000ms）を超えうるので、テストが期限の長さに依存しないよう長く取る。
const generous = account_store.Timeouts(load_ms: 30_000, write_ms: 30_000)

/// 読み込みの結果に、期待したアカウントが同じ内容で入っていることを確かめる。
fn assert_same_entry(
  loaded: account_store.Stored,
  expected: StoredAccount,
) -> Nil {
  let pubkey = account.pubkey_hex(expected.account)
  let assert Ok(found) =
    list.find(loaded.accounts.accounts, fn(entry) {
      account.pubkey_hex(entry.account) == pubkey
    })
  assert account.privkey(found.account) == account.privkey(expected.account)
  assert found.secret == expected.secret
  assert found.label == expected.label
}

/// 読み込めた行のうち、指定した pubkey のもの。
fn loaded_pubkeys(
  loaded: account_store.Stored,
  own: List(String),
) -> List(String) {
  loaded.accounts.accounts
  |> list.map(fn(entry) { account.pubkey_hex(entry.account) })
  |> list.filter(list.contains(own, _))
}

/// 飛ばした行のうち、指定した pubkey のものと、その理由。
fn skipped_reasons(
  loaded: account_store.Stored,
  own: List(String),
) -> List(#(String, vault.RowError)) {
  loaded.accounts.skipped
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

/// 書き込みを `pool` への実際のストアの操作で行い、読み込みは常に空を返す
/// バンカーアクターを起動し、その名前と pid を返す。アクターはテストプロセスに
/// リンクされるので、アクターが落ちればテストも落ちる。承認フローを使う
/// （`auth_url` を `Some` にする）。
fn start_bunker(
  pool: Name(pog.Message),
  key: vault.MasterKey,
) -> #(Name(bunker.Msg), Pid) {
  let name = process.new_name("account_store_test_bunker")
  let store =
    bunker.Store(
      ..nostr_no_su.account_store_operations(
        pool,
        process.new_name("account_store_test_unreachable_lock"),
        key,
        account_store.default_timeouts,
      ),
      load: fn() {
        Ok(bunker.Snapshot(vault.Loaded(accounts: [], skipped: []), [], [], []))
      },
    )
  let assert Ok(started) =
    bunker.start(
      name,
      bunker.Settings(
        store:,
        auth_url: Some(fn(token) { "http://admin.test/approve/" <> token }),
        retry_delay: backoff.Backoff(initial_ms: 100, max_ms: 100),
      ),
      fn() { Nil },
      fn(_relays) { Nil },
      fn(_urls) { Nil },
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
