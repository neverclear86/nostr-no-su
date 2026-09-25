//// 実際の Postgres を使う統合テストの補助。

import envoy
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import nostr_no_su/bunker/account_store
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
/// 期限を過ごしうる。`remaining` ミリ秒の間 50ms ごとに試し、応答しなければ `False`
/// を返す。
pub fn await_pool(db: pog.Connection, remaining: Int) -> Bool {
  let probed =
    pog.query("SELECT 1")
    |> pog.timeout(int.max(remaining, 1))
    |> account_store.execute(db)
  case probed, remaining <= 0 {
    Ok(_returned), _ -> True
    _, True -> False
    _, False -> {
      process.sleep(50)
      await_pool(db, remaining - 50)
    }
  }
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
/// ときはスキップを 1 行ログに出す（PR の CI は渡さず、手動のワークフローと
/// 手元の実行だけが渡す）。`label` はログの行頭に付ける識別子。
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
