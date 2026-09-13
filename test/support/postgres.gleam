//// 実際の Postgres を使う統合テストの補助。

import envoy
import gleam/erlang/process.{type Name}
import gleam/io
import gleam/option.{type Option, None, Some}
import pog

/// 接続プールを起動し、その名前を返す。`search_path` を指定すると、テーブル名を
/// そのスキーマで解決する。プールはテストプロセスにリンクされる。
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
  name
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
/// とき、`CI` が空でなければ panic し、そうでなければスキップを 1 行ログに
/// 出す。`label` はログと panic の行頭に付ける識別子。
pub fn with_test_database_url(label: String, run: fn(String) -> Nil) -> Nil {
  case envoy.get("TEST_DATABASE_URL"), envoy.get("CI") {
    Ok(url), _ if url != "" -> run(url)
    _, Ok(ci) if ci != "" ->
      panic as { "[" <> label <> "] TEST_DATABASE_URL is not set on CI" }
    _, _ ->
      io.println(
        "["
        <> label
        <> "] TEST_DATABASE_URL is not set; skipping the integration test",
      )
  }
}
