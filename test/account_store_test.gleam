//// `bunker/account_store` のテスト。純粋な部分は常に、実際の Postgres に対する
//// 統合テストは `TEST_DATABASE_URL` があるときだけ実行する（CI では未設定なら
//// 失敗する）。
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
import nostr_no_su/bunker/vault.{
  type MasterKey, type StoredAccount, StoredAccount,
}
import nostr_no_su/dedup/resume_store
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

/// 到達できないプールでのロックの取得は、例外にならず `Unavailable` を返す。
pub fn acquiring_a_lock_on_an_unreachable_database_is_a_value_test() {
  let name = process.new_name("account_store_test_unreachable_lock")
  let assert Ok(_pool) =
    pog.default_config(name)
    |> pog.port(1)
    |> pog.start
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
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert bunker.accounts(name) == Ok([])
  stop(pid)
}

/// 実際の Postgres に対する統合テスト。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。CI では未設定なら失敗する。同じ DB に対して `gleam test`
/// を並行実行することは想定していない。
pub fn postgres_round_trip_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  round_trip(postgres.start_pool(database_url, None))
}

/// 版の記録より前に作られた DB が版 1 として取り込まれ、版が新しい DB は拒否される。
/// `TEST_DATABASE_URL` があるときだけ実行する。CI では未設定なら失敗する。
pub fn postgres_schema_version_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  schema_version_round_trip(database_url)
}

/// 同じ番号の advisory lock は、同じセッションからは再入で取れ、別のセッションから
/// は取れない。セッションが解放すると別のセッションが取れる。`TEST_DATABASE_URL`
/// があるときだけ実行する。CI では未設定なら失敗する。同じ DB に対して
/// `gleam test` を並行実行することは想定していない。
pub fn postgres_instance_lock_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  instance_lock_round_trip(database_url)
}

/// 専用のスキーマでテストを行い、最後にスキーマごと消す。`CREATE SCHEMA` と
/// `DROP SCHEMA … CASCADE` は `search_path` の無い接続で、それ以外は専用スキーマへ
/// 向けた接続で実行する。ビルドより新しい版の挿入を `search_path` なしの接続に流すと
/// public の `schema_version` にその版が残り、以後の `round_trip` の `load` が
/// `SchemaTooNew` で落ちるためである。
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
  assert recorded_versions(db) == [1, 2, 3]

  // 記録された版が新しい DB は拒否する。
  postgres.run_statement(db, "INSERT INTO schema_version (version) VALUES (4)")
  assert account_store.load(pool, key, generous)
    == Error(account_store.SchemaTooNew(found: 4, supported: 3))

  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// 監視の購読の再開点は、DB からの読み込みと保存を一巡できる。移行の後に読み書き
/// できることは、`monitor_resume` が版 2 の移行で作られることの確認を兼ねる。
pub fn postgres_resume_store_test() {
  use database_url <- postgres.with_test_database_url("resume_store")
  let schema = "resume_store_schema_" <> random.hex(8)
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin, "CREATE SCHEMA " <> schema)
  let pool = postgres.start_pool(database_url, Some(schema))
  let db = pog.named_connection(pool)

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

  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// 版 2 の DB（`bunker_accounts` と `monitor_resume` はあるがセッションと承認待ちの
/// テーブルは無い）に版 3 の移行が適用でき、読み込んだ `sessions` と `pending` は
/// 空になる。`TEST_DATABASE_URL` があるときだけ実行する。CI では未設定なら失敗する。
pub fn postgres_migrates_a_version_two_database_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  let schema = "account_store_schema_" <> random.hex(8)
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin, "CREATE SCHEMA " <> schema)
  let pool = postgres.start_pool(database_url, Some(schema))
  let db = pog.named_connection(pool)

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
  assert recorded_versions(db) == [1, 2, 3]
  assert loaded.sessions == []
  assert loaded.pending == []

  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// セッションと承認待ちの読み書きを一巡させる。空の DB への版 3 の適用、書いた値を
/// 読み直すと同じ内容で戻ること、同じ主キーの 2 回の挿入がエラーにならないこと、
/// `approve`、アカウントの削除でその署名者の行が消えることを確かめる。
/// `TEST_DATABASE_URL` があるときだけ実行する。CI では未設定なら失敗する。
pub fn postgres_bunker_state_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  bunker_state_round_trip(database_url)
}

fn bunker_state_round_trip(database_url: String) -> Nil {
  let schema = "account_store_schema_" <> random.hex(8)
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin, "CREATE SCHEMA " <> schema)
  let pool = postgres.start_pool(database_url, Some(schema))
  let db = pog.named_connection(pool)
  let key = random_master_key()
  let now = 1_700_000_000

  // 1. 空のスキーマで load が Ok を返し、版が [1, 2, 3] になる。
  let assert Ok(empty) = account_store.load(pool, key, generous)
  assert recorded_versions(db) == [1, 2, 3]
  assert empty.sessions == []
  assert empty.pending == []

  // 2. A, B を登録し、それぞれにセッションと承認待ちを 1 件ずつ挿す。同じ引数の
  // 挿入をもう一度呼んでも Ok（ON CONFLICT DO NOTHING）。
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
        generous,
        signer: a_pubkey,
        client: "client-a",
        perms: "",
        now: now,
      )
    let assert Ok(Nil) =
      account_store.insert_session(
        db,
        generous,
        signer: b_pubkey,
        client: "client-b",
        perms: "sign_event:1",
        now: now + 1,
      )
    let assert Ok(Nil) = account_store.insert_pending(db, pa, generous)
    let assert Ok(Nil) = account_store.insert_pending(db, pb, generous)
    Nil
  }
  insert_a_and_b()
  // 同じ引数でもう一度呼んでも、ON CONFLICT DO NOTHING で Ok になる。
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
      ),
      account_store.StoredSession(
        signer: b_pubkey,
        client: "client-b",
        perms: "sign_event:1",
        created_at: now + 1,
        last_used_at: now + 1,
      ),
    ]
  assert loaded.pending == [pa, pb]

  // 4. 行があるときの削除: A に 2 件目のセッションと承認待ちを挿してから消すと、
  // load が手順 3 と同じになる。
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      generous,
      signer: a_pubkey,
      client: "client-a-2",
      perms: "",
      now: now + 2,
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
  let assert Ok(Nil) = account_store.insert_pending(db, pa2, generous)
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
  let assert Ok(Nil) = account_store.insert_pending(db, pa3, generous)
  let assert Ok(Nil) =
    account_store.approve(
      pool,
      generous,
      token: pa3.token,
      signer: a_pubkey,
      client: pa3.client,
      perms: pa3.perms,
      now: now + 4,
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
      ),
      account_store.StoredSession(
        signer: b_pubkey,
        client: "client-b",
        perms: "sign_event:1",
        created_at: now + 1,
        last_used_at: now + 1,
      ),
      account_store.StoredSession(
        signer: a_pubkey,
        client: pa3.client,
        perms: pa3.perms,
        created_at: now + 4,
        last_used_at: now + 4,
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
      ),
    ]
  assert after_account_delete.pending == [pb]

  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// トランザクションの中の `run` が `Error` を返すと、先に行った書き込みが残らない。
/// `TEST_DATABASE_URL` があるときだけ実行する。CI では未設定なら失敗する。
pub fn postgres_transaction_rolls_back_on_error_test() {
  use database_url <- postgres.with_test_database_url("account_store")
  transaction_rolls_back_on_error(database_url)
}

fn transaction_rolls_back_on_error(database_url: String) -> Nil {
  let schema = "account_store_schema_" <> random.hex(8)
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin, "CREATE SCHEMA " <> schema)
  let pool = postgres.start_pool(database_url, Some(schema))
  let db = pog.named_connection(pool)
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
        generous,
        signer: pubkey,
        client: "client",
        perms: "",
        now: 1,
      ))
      Error(account_store.QueryFailed("forced"))
    })
  assert outcome == Error(account_store.QueryFailed("forced"))

  let assert Ok(loaded) = account_store.load(pool, key, generous)
  assert loaded.sessions == []

  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// セッション A がロックを取り（再入で 2 回とも成功）、セッション B は取れない。
/// A がロックを手放すと B が取れる。番号は乱数にし、他の統合テストが取る本番の
/// 番号（`account_store.instance_lock_key`）と衝突しないようにする。A、B は
/// `postgres.start_lock_pool` で起動した 1 本のプールの接続である。
fn instance_lock_round_trip(database_url: String) -> Nil {
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
        process.new_name("account_store_test_unreachable_lock"),
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
        retry_delay: backoff.Backoff(initial_ms: 100, max_ms: 100),
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
