import envoy
import event_logger
import event_logger/store
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import pog

/// テストランナー。`gleam test` はこのモジュールの `main` から始まる。
pub fn main() -> Nil {
  gleeunit.main()
}

/// 変換のテストに使うイベント map（プラグイン境界の形。キーはすべて binary）。
/// タグは入れ子配列で、jsonb 列へ渡す形を確かめる。
fn sample_event(id: String) -> Dynamic {
  event_map(id, [["p", "abcdef"], ["e", "123456", "wss://relay.example"]])
}

/// イベント map を組み立てる。
fn event_map(id: String, tags: List(List(String))) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("id"), dynamic.string(id)),
    #(dynamic.string("pubkey"), dynamic.string("0f1e2d")),
    #(dynamic.string("created_at"), dynamic.int(1_700_000_000)),
    #(dynamic.string("kind"), dynamic.int(1)),
    #(
      dynamic.string("tags"),
      dynamic.list(
        list.map(tags, fn(tag) { dynamic.list(list.map(tag, dynamic.string)) }),
      ),
    ),
    #(dynamic.string("content"), dynamic.string("hello")),
    #(dynamic.string("sig"), dynamic.string("beef")),
  ])
}

/// イベントは列ごとの値へそのまま移り、タグだけが JSON 文字列になる。
pub fn event_becomes_a_row_test() {
  assert store.to_row(sample_event("a1"))
    == Ok(store.Row(
      id: "a1",
      pubkey: "0f1e2d",
      created_at: 1_700_000_000,
      kind: 1,
      tags: "[[\"p\",\"abcdef\"],[\"e\",\"123456\",\"wss://relay.example\"]]",
      content: "hello",
      sig: "beef",
    ))
}

/// タグが無いイベントでも jsonb として妥当な空配列になる。
pub fn events_without_tags_become_an_empty_json_array_test() {
  let assert Ok(row) = store.to_row(event_map("a2", []))
  assert row.tags == "[]"
}

/// 知らないキーは無視する（プラグイン API v1 第 3 章）。将来イベント map に
/// キーが増えても変換は壊れない。
pub fn unknown_event_keys_are_ignored_test() {
  let extended =
    dynamic.properties([
      #(dynamic.string("future_key"), dynamic.string("whatever")),
      #(dynamic.string("id"), dynamic.string("a3")),
      #(dynamic.string("pubkey"), dynamic.string("0f1e2d")),
      #(dynamic.string("created_at"), dynamic.int(1_700_000_000)),
      #(dynamic.string("kind"), dynamic.int(1)),
      #(dynamic.string("tags"), dynamic.list([])),
      #(dynamic.string("content"), dynamic.string("hello")),
      #(dynamic.string("sig"), dynamic.string("beef")),
    ])
  let assert Ok(row) = store.to_row(extended)
  assert row.id == "a3"
}

/// DDL はすべて `IF NOT EXISTS` 付きで、起動のたびに実行してよい。
pub fn schema_statements_are_idempotent_test() {
  assert list.all(store.schema, string.contains(_, "IF NOT EXISTS"))
}

/// 挿入する列とプレースホルダーが、`insert` がパラメーターを積む順序と対応して
/// いる。`tags` だけが jsonb へのキャストを伴う。
pub fn the_insert_lists_columns_in_parameter_order_test() {
  assert string.contains(
    store.insert_sql,
    "(id, pubkey, created_at, kind, tags, content, sig)",
  )
  assert string.contains(
    store.insert_sql,
    "VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)",
  )
}

/// 挿入は重複した id を黙って読み飛ばす。
pub fn inserts_ignore_duplicate_ids_test() {
  assert string.contains(store.insert_sql, "ON CONFLICT (id) DO NOTHING")
}

/// 権限不足のような自然に直らないエラーの例。
fn insufficient_privilege() -> pog.QueryError {
  pog.PostgresqlError(
    code: "42501",
    name: "insufficient_privilege",
    message: "permission denied for schema public",
  )
}

/// DB に到達できないことによる停止は、復帰するまでに 1 回だけ報告する。復帰時に
/// `resume` が破棄件数とあわせて報告するため、再試行のたびには出さない。
pub fn unreachable_databases_are_reported_once_test() {
  assert store.suspension_message(pog.ConnectionUnavailable, False, 0)
    == Some(
      "database unavailable: ConnectionUnavailable; retrying every 5000ms",
    )
  assert store.suspension_message(pog.QueryTimeout, True, 3) == None
}

/// 到達性と無関係な失敗（設定の不備など）は復帰の報告が出ないため、再試行の
/// たびに理由と、そこまでに捨てた件数を出して黙り込まない。
pub fn other_schema_failures_are_reported_every_time_test() {
  let reason =
    "schema setup failed: PostgresqlError(\"42501\", \"insufficient_privilege\", \"permission denied for schema public\"); retrying in 5000ms"
  assert store.suspension_message(insufficient_privilege(), False, 0)
    == Some(reason <> " (dropped 0 events so far)")
  // すでに報告済みでも抑止されず、捨てた件数が増えていく。
  assert store.suspension_message(insufficient_privilege(), True, 7)
    == Some(reason <> " (dropped 7 events so far)")
}

/// `{error, Reason}` として返された理由。子仕様のリストなら `Error(Nil)`。
fn rejection(children: Dynamic) -> Result(String, Nil) {
  let decoder = {
    use tag <- decode.field(0, atom.decoder())
    use reason <- decode.field(1, decode.string)
    decode.success(#(tag, reason))
  }
  case decode.run(children, decoder) {
    Ok(#(tag, reason)) ->
      case tag == atom.create("error") {
        True -> Ok(reason)
        False -> Error(Nil)
      }
    Error(_errors) -> Error(Nil)
  }
}

/// 設定が空なら、子仕様を組み立てずに設定を拒否する。本体はこの 1 行を出して
/// このプラグインだけを読み込まない。
pub fn missing_configuration_is_rejected_test() {
  assert rejection(event_logger.plugin_children(dynamic.properties([])))
    == Ok("PLUGIN_EVENT_LOGGER_DATABASE_URL is required")
}

/// Postgres の URL として読めない値も、子を起こす前に拒否する。読み込み時に
/// 弾かないと「子の起動失敗 → イベント処理の連続失敗 → disabled」という遠回りな
/// 症状になる。
pub fn invalid_urls_are_rejected_test() {
  let config =
    dynamic.properties([
      #(dynamic.string("database_url"), dynamic.string("not a url")),
    ])
  assert rejection(event_logger.plugin_children(config))
    == Ok("PLUGIN_EVENT_LOGGER_DATABASE_URL is not a valid postgres URL")
}

/// 子仕様の `shutdown`。有限のミリ秒か、`infinity` のような atom。
type Shutdown {
  Milliseconds(Int)
  Named(Atom)
}

/// 子仕様 1 件から、`id` と `type` と `shutdown` を読む。本体の
/// `plugin_children.from_dynamic` は使えないので map のキーを直接見る。
fn child_shape(spec: Dynamic) -> Result(#(String, Atom, Shutdown), Nil) {
  let decoder = {
    use id <- decode.field(atom.create("id"), decode.string)
    use kind <- decode.field(atom.create("type"), atom.decoder())
    use shutdown <- decode.field(atom.create("shutdown"), shutdown_decoder())
    decode.success(#(id, kind, shutdown))
  }
  decode.run(spec, decoder) |> result.replace_error(Nil)
}

/// `shutdown` の値を読むデコーダー。
fn shutdown_decoder() -> decode.Decoder(Shutdown) {
  decode.one_of(decode.int |> decode.map(Milliseconds), [
    atom.decoder() |> decode.map(Named),
  ])
}

/// 設定が揃っていれば、プールと保存アクターの 2 件を申告する。プールは
/// `pog.supervised/1` に合わせて `supervisor` で、本体が有限の shutdown を
/// 拒否するため `infinity` である。
pub fn valid_configuration_declares_a_pool_and_a_store_test() {
  let config =
    dynamic.properties([
      #(
        dynamic.string("database_url"),
        dynamic.string("postgres://user:pass@localhost:5432/db"),
      ),
    ])
  let assert Ok(specs) =
    decode.run(
      event_logger.plugin_children(config),
      decode.list(decode.dynamic),
    )
  let assert [pool, store_spec] = specs
  assert child_shape(pool)
    == Ok(#("pool", atom.create("supervisor"), Named(atom.create("infinity"))))
  assert child_shape(store_spec)
    == Ok(#("store", atom.create("worker"), Milliseconds(5000)))
}

/// 到達できない DB でも保存アクターは落ちない。DB が落ちている間に落ち続ける
/// 子は、専用スーパーバイザーの歯止めを使い切って本体の再起動まで戻らなくなる
/// （`docs/plugin-api.md` 第 5.4 節）。イベントは数えて捨てるだけにする。
///
/// **数百 ms 待つだけでは足りない。** 初期化で送る `EnsureSchema` が接続の
/// チェックアウト待ちでブロックするため、`Unavailable` へ遷移するまでアクターは
/// メッセージを 1 件も処理しない。到達できないポートに対する実測では、500ms と
/// 1500ms の時点でメールボックスに `Store` が残ったままで、遷移が済んで空になる
/// のは 5.5 秒あたりである。ブロック中のプロセスも生きてはいるので、その時点の
/// `is_alive` は `Unavailable` の分岐が正しいことを何も示さない。
///
/// そこで**メールボックスが空になるまで待って**遷移を確認し、**そのうえで
/// さらに `Store` を送る。** 2 度目の送信は必ず `Unavailable` の「数えて捨てる」
/// 分岐（`store.persist/2`）を通るので、そこで落ちる実装ならこのテストが落ちる。
pub fn the_store_survives_an_unreachable_database_test() {
  // 待ち受けの無いポートを指すプール。プロセスとしては生きているので、
  // クエリーは ConnectionUnavailable として値で返る。
  let pool_name = process.new_name("test_unreachable_pool")
  let assert Ok(_pool) =
    pog.default_config(pool_name)
    |> pog.port(1)
    |> pog.start
  let store_name = process.new_name("test_unreachable_store")
  let assert Ok(started) = store.start(store_name, pool_name)
  let assert Ok(row) = store.to_row(sample_event("a4"))
  let send_three = fn() {
    list.each([row, row, row], fn(row) {
      process.send(started.data, store.Store(row))
    })
  }

  // 1 度目。遷移が済むまでは処理されない。
  send_three()
  assert await_drained(started.pid, unavailable_transition_timeout_ms)

  // 2 度目。ここは必ず Unavailable の破棄分岐を通る。
  send_three()
  assert await_drained(started.pid, drop_timeout_ms)
  assert process.is_alive(started.pid)
}

/// `Unavailable` への遷移を待つ上限。実測では 5.5 秒あたりで遷移するので、
/// 揺らぎを見込んで少し多く取る。
const unavailable_transition_timeout_ms = 10_000

/// 遷移後に送ったイベントが捨てられるのを待つ上限。DB を触らないので即座に
/// 終わるが、テストがハングしないように上限を置く。
const drop_timeout_ms = 1000

/// メールボックスが空になるまで待つ。プロセスが死んだら即座に `False` を返す
/// （落ちない性質を見るテストなので、待ち続けても意味がない）。
fn await_drained(pid: Pid, remaining: Int) -> Bool {
  case message_queue_len(pid) {
    Error(Nil) -> False
    Ok(0) -> True
    Ok(_pending) ->
      case remaining <= 0 {
        True -> False
        False -> {
          process.sleep(50)
          await_drained(pid, remaining - 50)
        }
      }
  }
}

/// 未処理メッセージの件数。プロセスが死んでいれば `Error(Nil)`。
/// `erlang:process_info/2` は生きていれば `{message_queue_len, N}`、死んでいれば
/// `undefined` を返すので、タプルの 2 要素目を読めるかどうかで振り分ける。
fn message_queue_len(pid: Pid) -> Result(Int, Nil) {
  decode.run(process_info(pid, atom.create("message_queue_len")), {
    use length <- decode.field(1, decode.int)
    decode.success(length)
  })
  |> result.replace_error(Nil)
}

/// プロセスの情報を 1 項目だけ問い合わせる。テストからしか使わない。
@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, key: Atom) -> Dynamic

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
        "[event_logger] TEST_DATABASE_URL is not set; skipping the integration test",
      )
    Ok(database_url) -> round_trip(database_url)
  }
}

/// スキーマ作成・挿入・重複挿入・後片付けを一巡させる。
fn round_trip(database_url: String) -> Nil {
  let db = connect(database_url)
  // 2 回続けて実行しても失敗しない。
  let assert Ok(Nil) = store.ensure_schema(db)
  let assert Ok(Nil) = store.ensure_schema(db)
  assert index_names(db)
    == ["events_kind", "events_pkey", "events_pubkey_created_at"]

  let assert Ok(stored) = store.to_row(sample_event(random_id()))
  assert store.insert(db, stored) == Ok(1)
  assert count_rows(db, stored.id) == 1
  // タグが jsonb として保存されていれば、Postgres 側から要素を取り出せる。
  assert first_tag_name(db, stored.id) == Ok("p")

  // 同じイベントを別のリレーから受け直しても行は増えない。
  assert store.insert(db, stored) == Ok(0)
  assert count_rows(db, stored.id) == 1

  delete_row(db, stored.id)
  assert count_rows(db, stored.id) == 0
}

/// テスト用の接続プールを起動する。プールはテストプロセスにリンクされるため、
/// テストが終われば一緒に停止する。
fn connect(database_url: String) -> pog.Connection {
  let assert Ok(config) =
    pog.url_config(process.new_name("test_event_logger_pool"), database_url)
  let assert Ok(started) = pog.start(config)
  started.data
}

/// 実行のたびに違うイベント id。テストを繰り返しても前回の行と衝突しない。
fn random_id() -> String {
  int.to_base16(int.random(1_000_000_000))
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
