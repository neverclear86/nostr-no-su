//// 実際の Postgres を使う統合テストの補助。

import gleam/erlang/process.{type Name}
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
