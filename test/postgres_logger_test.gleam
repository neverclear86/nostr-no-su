import envoy
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/string
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugins/postgres_logger
import pog

/// 変換のテストに使うイベント。タグは入れ子配列で、jsonb 列へ渡す形を確かめる。
fn sample_event(id: String) -> Event {
  Event(
    id: id,
    pubkey: "0f1e2d",
    created_at: 1_700_000_000,
    kind: 1,
    tags: [["p", "abcdef"], ["e", "123456", "wss://relay.example"]],
    content: "hello",
    sig: "beef",
  )
}

/// イベントは列ごとの値へそのまま移り、タグだけが JSON 文字列になる。
pub fn event_becomes_a_row_test() {
  assert postgres_logger.to_row(sample_event("a1"))
    == postgres_logger.Row(
      id: "a1",
      pubkey: "0f1e2d",
      created_at: 1_700_000_000,
      kind: 1,
      tags: "[[\"p\",\"abcdef\"],[\"e\",\"123456\",\"wss://relay.example\"]]",
      content: "hello",
      sig: "beef",
    )
}

/// タグが無いイベントでも jsonb として妥当な空配列になる。
pub fn events_without_tags_become_an_empty_json_array_test() {
  let without_tags = Event(..sample_event("a2"), tags: [])
  assert postgres_logger.to_row(without_tags).tags == "[]"
}

/// DDL はすべて `IF NOT EXISTS` 付きで、起動のたびに実行してよい。
pub fn schema_statements_are_idempotent_test() {
  assert list.all(postgres_logger.schema, string.contains(_, "IF NOT EXISTS"))
}

/// 挿入する列とプレースホルダーが、`insert` がパラメーターを積む順序と対応して
/// いる。`tags` だけが jsonb へのキャストを伴う。
pub fn the_insert_lists_columns_in_parameter_order_test() {
  assert string.contains(
    postgres_logger.insert_sql,
    "(id, pubkey, created_at, kind, tags, content, sig)",
  )
  assert string.contains(
    postgres_logger.insert_sql,
    "VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)",
  )
}

/// 挿入は重複した id を黙って読み飛ばす。
pub fn inserts_ignore_duplicate_ids_test() {
  assert string.contains(
    postgres_logger.insert_sql,
    "ON CONFLICT (id) DO NOTHING",
  )
}

/// 実際の Postgres に対する統合テスト。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。スキーマ作成の冪等性・挿入・重複無視・jsonb としての
/// 読み戻し・インデックスの作成を一巡して確かめる。
///
/// 同じ DB に対して `gleam test` を並行実行することは想定していない
/// （`CREATE TABLE IF NOT EXISTS` 同士が競合しうる）。CI は専用の service を
/// 使い、ローカルでも使い捨てのコンテナーを使うこと。
pub fn postgres_round_trip_test() {
  case envoy.get("TEST_DATABASE_URL") {
    Ok("") | Error(Nil) ->
      io.println(
        "[postgres_logger] TEST_DATABASE_URL is not set; skipping the integration test",
      )
    Ok(database_url) -> round_trip(database_url)
  }
}

/// スキーマ作成・挿入・重複挿入・後片付けを一巡させる。
fn round_trip(database_url: String) -> Nil {
  let db = connect(database_url)
  // 2 回続けて実行しても失敗しない。
  let assert Ok(Nil) = postgres_logger.ensure_schema(db)
  let assert Ok(Nil) = postgres_logger.ensure_schema(db)
  assert index_names(db)
    == ["events_kind", "events_pkey", "events_pubkey_created_at"]

  let stored = sample_event(random_id())
  assert postgres_logger.insert(db, stored) == Ok(1)
  assert count_rows(db, stored.id) == 1
  // タグが jsonb として保存されていれば、Postgres 側から要素を取り出せる。
  assert first_tag_name(db, stored.id) == Ok("p")

  // 同じイベントを別のリレーから受け直しても行は増えない。
  assert postgres_logger.insert(db, stored) == Ok(0)
  assert count_rows(db, stored.id) == 1

  delete_row(db, stored.id)
  assert count_rows(db, stored.id) == 0
}

/// テスト用の接続プールを起動する。プールはテストプロセスにリンクされるため、
/// テストが終われば一緒に停止する。
fn connect(database_url: String) -> pog.Connection {
  let assert Ok(config) =
    pog.url_config(process.new_name("test_postgres_logger_pool"), database_url)
  let assert Ok(started) = pog.start(config)
  started.data
}

/// 実行のたびに違うイベント id。テストを繰り返しても前回の行と衝突しない。
fn random_id() -> String {
  crypto.strong_random_bytes(32)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// `events` に張られているインデックスの名前（主キーを含む）。
fn index_names(db: pog.Connection) -> List(String) {
  let decoder = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT indexname FROM pg_indexes WHERE tablename = 'events' ORDER BY indexname",
    )
    |> pog.returning(decoder)
    |> pog.execute(on: db)
  returned.rows
}

/// 指定した id で保存されている行数。
fn count_rows(db: pog.Connection, id: String) -> Int {
  let assert Ok(returned) =
    pog.query("SELECT id FROM events WHERE id = $1")
    |> pog.parameter(pog.text(id))
    |> pog.execute(on: db)
  returned.count
}

/// 保存された tags の 1 つ目のタグ名。jsonb 列として問い合わせる。
fn first_tag_name(db: pog.Connection, id: String) -> Result(String, Nil) {
  let decoder = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }
  let assert Ok(returned) =
    pog.query("SELECT tags->0->>0 FROM events WHERE id = $1")
    |> pog.parameter(pog.text(id))
    |> pog.returning(decoder)
    |> pog.execute(on: db)
  case returned.rows {
    [name] -> Ok(name)
    _ -> Error(Nil)
  }
}

/// テストが入れた行を消す。
fn delete_row(db: pog.Connection, id: String) -> Nil {
  let assert Ok(_deleted) =
    pog.query("DELETE FROM events WHERE id = $1")
    |> pog.parameter(pog.text(id))
    |> pog.execute(on: db)
  Nil
}
