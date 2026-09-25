//// 実際の Postgres を使う統合テストの補助。

import envoy
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import nostr_no_su/bunker/account_store
import nostr_no_su/random
import nostr_no_su/task.{type Deadline}
import nostr_no_su/time
import pog

/// 接続プールを起動し、クエリーに応答するまで待ってからその名前を返す。
/// `search_path` を指定すると、テーブル名をそのスキーマで解決する。プールはテスト
/// プロセスにリンクされる。
pub fn start_pool(
  database_url: String,
  search_path: Option(String),
) -> Name(pog.Message) {
  let name = process.new_name("test_postgres_pool")
  let assert Ok(config) = pog.url_config(name, database_url)
  let config = case search_path {
    Some(schema) -> pog.connection_parameter(config, "search_path", schema)
    None -> config
  }
  let assert Ok(_started) = pog.start(pog.pool_size(config, 2))
  assert await_pool(pog.named_connection(name), 10_000)
  name
}

/// プールがクエリーに応答するまで待つ。pog のプールは起動と同時には接続を張らず
/// 非同期で張るので、スーパービジョンツリーの起動直後に書き込むと接続の待ち行列で
/// 期限を過ごしうる。`timeout_ms` ミリ秒の間 50ms ごとに試し、応答しなければ `False`
/// を返す。
pub fn await_pool(db: pog.Connection, timeout_ms: Int) -> Bool {
  probe_until(db, task.deadline_in(timeout_ms))
}

/// 期限まで `SELECT 1` を試す。pog の問い合わせの期限は接続の待ち行列の待ちを
/// 含まないので、各回を別プロセスで走らせて期限までだけ待ち、問い合わせが待たされても
/// 期限を越えて待たない。
fn probe_until(db: pog.Connection, deadline: Deadline) -> Bool {
  let probed =
    task.start(fn() {
      pog.query("SELECT 1")
      |> pog.timeout(int.max(ms_left(deadline), 1))
      |> account_store.execute(db)
    })
    |> task.await(deadline)
  case probed, ms_left(deadline) {
    Ok(Ok(_returned)), _ -> True
    _, left if left <= 0 -> False
    _, left -> {
      process.sleep(int.min(50, left))
      probe_until(db, deadline)
    }
  }
}

/// 期限までの残りのミリ秒。過ぎていれば 0 以下。
fn ms_left(deadline: Deadline) -> Int {
  deadline.at_ms - time.monotonic_ms()
}

/// 結果を読まない文を 1 つ実行する。
pub fn run_statement(db: pog.Connection, statement: String) -> Nil {
  let assert Ok(_returned) =
    pog.query(statement)
    |> pog.timeout(30_000)
    |> pog.execute(on: db)
  Nil
}

/// `TEST_DATABASE_URL` が空でなければその値で `run` を呼ぶ。未設定または空の
/// ときは失敗せず、スキップを 1 行ログに出す（CI の `test` ジョブは Postgres を
/// 立てて渡す）。`label` はログの行頭に付ける識別子。
pub fn with_test_database_url(label: String, run: fn(String) -> Nil) -> Nil {
  case envoy.get("TEST_DATABASE_URL") {
    Ok(url) if url != "" -> run(url)
    _ ->
      io.println(
        "["
        <> label
        <> "] TEST_DATABASE_URL is not set; skipping the integration test",
      )
  }
}

/// バンカーと同じ設定（`account_store.pool_config` と `lock_pool_config`）でロック
/// 専用の 1 本のプールを起動し、クエリーに応答するまで待ってからその名前を返す。
/// プールはテストプロセスにリンクされる。`start_pool` は `pog.url_config` を直接
/// 使い本数を 2 に固定するので、ロックの 1 本のプールには流用しない。本番の設定の
/// 関数を通すことで、テストのロックのプールが本番と同じ本数（1）になる。
pub fn start_lock_pool(database_url: String) -> Name(pog.Message) {
  let name = process.new_name("test_postgres_lock_pool")
  let assert Ok(pool_config) = account_store.pool_config(name, database_url)
  let assert Ok(_started) =
    account_store.lock_pool_config(name, pool_config) |> pog.start
  assert await_pool(pog.named_connection(name), 10_000)
  name
}

/// 専用のスキーマを作り、`search_path` をそのスキーマにしたプールとその接続で
/// `run` を呼んで、終わったらスキーマごと消す。スキーマの名前が要るときは
/// `with_named_schema` を使う。
pub fn with_schema(
  database_url: String,
  run: fn(Name(pog.Message), pog.Connection) -> Nil,
) -> Nil {
  use _schema, pool, db <- with_named_schema(database_url)
  run(pool, db)
}

/// 専用のスキーマを作り、その名前と、`search_path` をそのスキーマにしたプールと
/// その接続で `run` を呼んで、終わったらスキーマごと消す。スキーマの作成と削除も
/// そのプールで行い、テストが同時に持つ接続を 1 プールぶんにする（`search_path` は
/// 文の実行時に解決される）。名前は、スキーマで修飾したトリガーを作るのに使う。
pub fn with_named_schema(
  database_url: String,
  run: fn(String, Name(pog.Message), pog.Connection) -> Nil,
) -> Nil {
  let schema = "test_schema_" <> random.hex(8)
  let pool = start_pool(database_url, Some(schema))
  let db = pog.named_connection(pool)
  run_statement(db, "CREATE SCHEMA " <> schema)
  run(schema, pool, db)
  run_statement(db, "DROP SCHEMA " <> schema <> " CASCADE")
}
