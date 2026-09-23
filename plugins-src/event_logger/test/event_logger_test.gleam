import envoy
import event_logger
import event_logger/i18n
import event_logger/page
import event_logger/store
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Monitor, type Pid}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
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

/// 移行の文はすべて `IF NOT EXISTS` 付きで、途中で失敗した移行を頭から実行し直して
/// よい。
pub fn migration_statements_can_be_re_run_test() {
  let statements =
    list.flat_map(store.migrations, fn(migration) { migration.statements })
  assert list.all(statements, string.contains(_, "IF NOT EXISTS"))
}

/// `store.migrations` の版は 1 から欠番なく昇順に並ぶ。
pub fn migrations_are_numbered_from_one_without_gaps_test() {
  let versions = list.map(store.migrations, fn(migration) { migration.version })
  assert versions == list.index_map(versions, fn(_, index) { index + 1 })
}

/// 未適用の移行だけを版の順に返す。
pub fn pending_migrations_skip_recorded_versions_test() {
  let migrations = [
    store.Migration(version: 1, statements: ["one"]),
    store.Migration(version: 2, statements: ["two"]),
  ]
  assert store.pending_migrations(migrations, 0) == Ok(migrations)
  assert store.pending_migrations(migrations, 1)
    == Ok([store.Migration(version: 2, statements: ["two"])])
  assert store.pending_migrations(migrations, 2) == Ok([])
}

/// 記録された版が移行の最新の版より新しい DB は拒否する。
pub fn a_database_newer_than_the_migrations_is_refused_test() {
  let migrations = [
    store.Migration(version: 1, statements: ["one"]),
    store.Migration(version: 2, statements: ["two"]),
  ]
  assert store.pending_migrations(migrations, 3)
    == Error(store.SchemaTooNew(found: 3, supported: 2))
}

/// `monitored_accounts` の行が 0 件なら絞らず、全アカウントが対象になる。
pub fn no_monitored_rows_mean_every_account_test() {
  assert store.monitored_from_rows([]) == store.AllAccounts
  assert store.is_monitored(store.AllAccounts, "anything")
}

/// 行があれば、その pubkey だけが保存の対象になる。
pub fn monitored_rows_limit_storing_test() {
  let monitored = store.monitored_from_rows(["aa", "bb"])
  assert monitored == store.OnlyPubkeys(set.from_list(["aa", "bb"]))
  assert store.is_monitored(monitored, "aa")
  assert !store.is_monitored(monitored, "cc")
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

/// map でない設定も、子仕様を組み立てずに拒否する。
pub fn configuration_that_is_not_a_map_is_rejected_test() {
  assert rejection(event_logger.plugin_children(dynamic.string("postgres://")))
    == Ok("configuration must be a map of strings")
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
/// 分岐（`store.persist/3`）を通るので、そこで落ちる実装ならこのテストが落ちる。
pub fn the_store_survives_an_unreachable_database_test() {
  // 待ち受けの無いポートを指すプール。プロセスとしては生きているので、
  // クエリーは ConnectionUnavailable として値で返る。
  let pool_name = process.new_name("test_unreachable_pool")
  let assert Ok(_pool) =
    pog.default_config(pool_name)
    |> pog.port(1)
    |> pog.start
  let store_name = process.new_name("test_unreachable_store")
  let assert Ok(started) =
    store.start(
      store_name,
      store.postgres(pool_name),
      store.default_max_queue_len,
    )
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
  case event_logger.pending_messages(pid) {
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

/// 版がこのプラグインより新しい DB では、保存アクターが理由を 1 行出して異常終了する。
///
/// `store.start` は呼び出し側にリンクするので、テストプロセスとリンクしない仲介の
/// プロセスで起動し、その終了理由をテストプロセスへ送る。仲介プロセスは
/// `store.start` を呼ぶ前に exit を trap するので、EXIT のシグナルはメッセージとして
/// 積まれ、監視を張る前に終わる競合が無い。
pub fn a_newer_schema_stops_the_store_test() {
  let database =
    store.Database(
      ensure_schema: fn() { Error(store.SchemaTooNew(found: 2, supported: 1)) },
      insert: fn(_row) { Ok(1) },
      load_monitored: fn() { Ok([]) },
    )
  let reply = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let assert Ok(_started) =
      store.start(
        process.new_name("test_newer_schema_store"),
        database,
        store.default_max_queue_len,
      )
    let exit =
      process.new_selector()
      |> process.select_trapped_exits(fn(exit) { exit.reason })
      |> process.selector_receive(exit_timeout_ms)
    process.send(reply, exit)
  })
  let assert Ok(Ok(process.Abnormal(reason))) =
    process.receive(reply, exit_timeout_ms)
  assert string.contains(
    string.inspect(reason),
    "database schema version 2 is newer than this plugin supports (up to version 1)",
  )
}

/// 到達性と無関係な挿入エラーは、そのイベントだけの問題として保存を続ける。
/// 保存を止める実装なら、2 件目は捨てられて挿入が試みられない。
pub fn insert_failures_unrelated_to_reachability_keep_storing_test() {
  let attempts = process.new_subject()
  let assert Ok(started) =
    store.start(
      process.new_name("test_rejecting_store"),
      rejecting_database(attempts),
      store.default_max_queue_len,
    )
  let assert Ok(rejected) = store.to_row(sample_event("rejected"))
  let assert Ok(accepted) = store.to_row(sample_event("accepted"))
  process.send(started.data, store.Store(rejected))
  process.send(started.data, store.Store(accepted))
  assert await_inserted(attempts, "rejected", insert_timeout_ms)
  assert await_inserted(attempts, "accepted", insert_timeout_ms)
}

/// 挿入が遅い DB でも、保存アクターのメールボックスは上限の近くで頭打ちになる。
///
/// 上限 20 のときの最大は実測で 23 か 24（上限に、1 件の挿入の間に届く数件を
/// 足した数）で、上限の判定を外すと 245 になる。閾値を上限の 3 倍にするのは、
/// CI の共有ランナーでアクターが数十 ms 止まり、その間に送信側だけが進んで最大値が
/// 跳ねる揺れを見込むためである。3 倍でも、判定の無い実装は検出できる。
///
/// 最後に送ったイベントは、取り出した時点で残りが 0 件なので必ず保存される。
pub fn a_slow_database_keeps_the_mailbox_bounded_test() {
  let inserted = process.new_subject()
  let assert Ok(started) =
    store.start(
      process.new_name("test_slow_store"),
      slow_database(inserted),
      slow_queue_limit,
    )
  let assert Ok(row) = store.to_row(sample_event("0"))
  let longest =
    int.range(from: 1, to: flood_len + 1, with: 0, run: fn(longest, n) {
      process.send(
        started.data,
        store.Store(store.Row(..row, id: int.to_string(n))),
      )
      let assert Ok(queued) = event_logger.pending_messages(started.pid)
      process.sleep(flood_interval_ms)
      int.max(longest, queued)
    })
  assert longest <= slow_queue_limit * 3
  assert await_inserted(inserted, int.to_string(flood_len), insert_timeout_ms)
}

/// 監視対象の外の pubkey のイベントは保存されない。`insert` は対象内の 1 件
/// だけを受ける。
pub fn events_outside_the_monitored_set_are_not_stored_test() {
  let inserted = process.new_subject()
  let assert Ok(started) =
    store.start(
      process.new_name("test_monitored_store"),
      monitored_database(inserted, ["aa"]),
      store.default_max_queue_len,
    )
  let assert Ok(row) = store.to_row(sample_event("in"))
  process.send(
    started.data,
    store.Store(store.Row(..row, id: "outside", pubkey: "bb")),
  )
  process.send(
    started.data,
    store.Store(store.Row(..row, id: "inside", pubkey: "aa")),
  )
  assert process.receive(inserted, insert_timeout_ms) == Ok("inside")
}

/// `ReloadMonitored` を送ると `load_monitored` が呼ばれ、`GetMonitored` の答えが
/// 新しい集合になる。スタブの `load_monitored` は `requests` へ答えの宛先を
/// 送って問い合わせ、テストが `[]` → `["aa"]` の順に答える
/// （`process.receive` は宛先の所有プロセスでしか受けられないため、
/// `process.call` で往復させる）。
pub fn saving_monitored_accounts_reloads_the_store_test() {
  let requests = process.new_subject()
  let assert Ok(started) =
    store.start(
      process.new_name("test_reload_store"),
      store.Database(
        ensure_schema: fn() { Ok(Nil) },
        insert: fn(_row) { Ok(1) },
        load_monitored: fn() {
          Ok(
            process.call(
              requests,
              waiting: insert_timeout_ms,
              sending: fn(reply) { reply },
            ),
          )
        },
      ),
      store.default_max_queue_len,
    )
  let assert Ok(initial_reply) = process.receive(requests, insert_timeout_ms)
  process.send(initial_reply, [])

  process.send(started.data, store.ReloadMonitored)
  let assert Ok(reload_reply) = process.receive(requests, insert_timeout_ms)
  process.send(reload_reply, ["aa"])

  let answer = process.new_subject()
  process.send(started.data, store.GetMonitored(reply_to: answer))
  assert process.receive(answer, insert_timeout_ms)
    == Ok(store.OnlyPubkeys(set.from_list(["aa"])))
}

/// 遅い DB のテストで保存アクターに渡す上限。
const slow_queue_limit = 20

/// 遅い DB が 1 行の挿入にかける時間。
const slow_insert_ms = 10

/// 遅い DB のテストでイベントを送る間隔。
const flood_interval_ms = 1

/// 遅い DB のテストで送るイベント数。
const flood_len = 300

/// 偽の DB へ次の挿入が届くのを待つ上限。
const insert_timeout_ms = 1000

/// 挿入を試みた行の id を `attempts` へ知らせ、id が `rejected` の行だけを権限
/// 不足で拒否する DB。
fn rejecting_database(attempts: process.Subject(String)) -> store.Database {
  store.Database(
    ensure_schema: fn() { Ok(Nil) },
    insert: fn(row: store.Row) {
      process.send(attempts, row.id)
      case row.id {
        "rejected" -> Error(insufficient_privilege())
        _ -> Ok(1)
      }
    },
    load_monitored: fn() { Ok([]) },
  )
}

/// 1 行の挿入に `slow_insert_ms` かけ、挿入した行の id を `inserted` へ知らせる
/// DB。
fn slow_database(inserted: process.Subject(String)) -> store.Database {
  store.Database(
    ensure_schema: fn() { Ok(Nil) },
    insert: fn(row: store.Row) {
      process.sleep(slow_insert_ms)
      process.send(inserted, row.id)
      Ok(1)
    },
    load_monitored: fn() { Ok([]) },
  )
}

/// 監視対象が固定の `monitored_pubkeys` だけの DB。挿入した行の id を
/// `inserted` へ知らせる。
fn monitored_database(
  inserted: process.Subject(String),
  monitored_pubkeys: List(String),
) -> store.Database {
  store.Database(
    ensure_schema: fn() { Ok(Nil) },
    insert: fn(row: store.Row) {
      process.send(inserted, row.id)
      Ok(1)
    },
    load_monitored: fn() { Ok(monitored_pubkeys) },
  )
}

/// `id` が届くまで `inserted` を読み進める。次の id が `timeout_ms` の間に
/// 届かなければ `False` を返す。
fn await_inserted(
  inserted: process.Subject(String),
  id: String,
  timeout_ms: Int,
) -> Bool {
  case process.receive(inserted, timeout_ms) {
    Ok(received) if received == id -> True
    Ok(_other) -> await_inserted(inserted, id, timeout_ms)
    Error(Nil) -> False
  }
}

/// イベントは行に変換されて保存アクターの登録名へ届き、転送した使い捨ての
/// プロセスは正常に終わる。
pub fn events_are_forwarded_to_the_store_test() {
  let #(exit, forwarded) =
    as_store(fn() {
      spawn_handle_event(sample_event("f1"))
      |> await_forwarded(exit_timeout_ms)
    })
  assert exit == Ok(process.Normal)
  let assert Ok(store.Store(row)) = forwarded
  assert row.id == "f1"
}

/// 保存アクターの再起動の間に届いたイベントは、登録名が戻るのを待って転送する。
/// 即座に失敗させると、再起動の間の数件でプラグインごと無効になる。
pub fn events_wait_for_a_restarting_store_test() {
  assert process.named(event_logger.store_name()) == Error(Nil)
  let monitor = spawn_handle_event(sample_event("f2"))
  process.sleep(100)
  let #(exit, forwarded) =
    as_store(fn() { await_forwarded(monitor, exit_timeout_ms) })
  assert exit == Ok(process.Normal)
  let assert Ok(store.Store(row)) = forwarded
  assert row.id == "f2"
}

/// 待っても保存アクターが戻らなければ失敗させる。子を諦めた状態は、ランナーの
/// 連続失敗を経て `disabled` として見える（`docs/plugin-api.md` 第 5.4 節）。
pub fn events_fail_when_the_store_stays_away_test() {
  assert process.named(event_logger.store_name()) == Error(Nil)
  let assert Ok(process.Abnormal(reason)) =
    spawn_handle_event(sample_event("f3"))
    |> await_exit(exit_timeout_ms)
  assert string.contains(
    string.inspect(reason),
    "event_logger store is not running",
  )
}

/// イベント map として読めない値は、宛先が居ても失敗させる。
pub fn values_that_are_not_event_maps_fail_test() {
  let exit =
    as_store(fn() {
      spawn_handle_event(dynamic.string("not an event"))
      |> await_exit(exit_timeout_ms)
    })
  let assert Ok(process.Abnormal(reason)) = exit
  assert string.contains(
    string.inspect(reason),
    "event is not a valid event map",
  )
}

/// 使い捨てのプロセスの終了を待つ上限。`handle_event/1` が保存アクターを待つ
/// 1 秒より十分長く取る。
const exit_timeout_ms = 3000

/// `handle_event/1` を使い捨てのプロセスで動かし、その監視を返す。生成と監視を
/// 不可分にするため `erlang:spawn_monitor/1` を使う（先に終わると `noproc` の
/// DOWN になり、終了の理由を読めない）。
fn spawn_handle_event(event: Dynamic) -> Monitor {
  spawn_monitor(fn() { event_logger.handle_event(event) }).1
}

/// プロセスを生成し、同時に監視する。
@external(erlang, "erlang", "spawn_monitor")
fn spawn_monitor(run: fn() -> Nil) -> #(Pid, Monitor)

/// 監視しているプロセスの終了の理由を待つ。`timeout_ms` の間に終わらなければ
/// `Error(Nil)` を返す。
fn await_exit(
  monitor: Monitor,
  timeout_ms: Int,
) -> Result(process.ExitReason, Nil) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down.reason })
  |> process.selector_receive(timeout_ms)
}

/// 使い捨てのプロセスの終了を待ってから、保存アクターの登録名に届いた
/// メッセージを受け取る。終了を先に待つので、送られていれば取りこぼさない。
fn await_forwarded(
  monitor: Monitor,
  timeout_ms: Int,
) -> #(Result(process.ExitReason, Nil), Result(store.Msg, Nil)) {
  let exit = await_exit(monitor, timeout_ms)
  #(exit, process.receive(process.named_subject(event_logger.store_name()), 0))
}

/// テストプロセスを保存アクターの登録名で登録して `run` を実行し、解除してから
/// `run` の結果を返す。同じモジュールのテストは同じプロセスで動くので、名前を
/// 次のテストへ持ち越さない。解除を飛ばさないよう、検査は `run` の中ではなく
/// 戻り値に対して行う。
fn as_store(run: fn() -> a) -> a {
  let name = event_logger.store_name()
  let assert Ok(Nil) = process.register(process.self(), name)
  let result = run()
  let assert Ok(Nil) = process.unregister(name)
  result
}

/// プールの起動シムは起動結果を `{ok, Pid}` に潰し、起動に失敗すれば
/// `{error, Reason}` を返す（`started_pid/1` の両分岐）。`pgo` を止めてから起動し
/// 直すことは確かめない（README の `pgo` の節）。
pub fn the_pool_shim_flattens_the_start_result_test() {
  let config =
    pog.default_config(process.new_name("test_shim_pool"))
    |> pog.port(1)
  let assert Ok(pid) = event_logger.start_pool(config)
  assert process.is_alive(pid)
  let assert Error(reason) = event_logger.start_pool(config)
  assert string.contains(reason, "AlreadyStarted")
}

/// `masked_url` は接続先だけを残し、パスワードを落とす。
pub fn masked_url_hides_the_password_test() {
  let pool = process.new_name("test_masked_url_pool")
  assert page.masked_url(
      pool,
      "postgres://nostr:secret@db.example:5432/nostr_no_su",
      i18n.English,
    )
    == "postgres://nostr@db.example:5432/nostr_no_su"
}

/// 英語の `page.pages` は `timeline`、`settings` の順に 2 件を供給する。
pub fn pages_declares_timeline_then_settings_test() {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use title <- decode.field("title", decode.string)
    decode.success(#(key, title))
  }
  let assert Ok(entries) =
    decode.run(page.pages(i18n.English), decode.list(decoder))
  assert entries == [#("timeline", "Timeline"), #("settings", "Settings")]
}

/// `Accounts` の値（JSON 文字列）から `pubkey`・`npub`・`label` を読む。壊れた
/// JSON なら `[]`。
pub fn accounts_are_read_from_the_config_json_test() {
  let json_text =
    "[{\"pubkey\":\"aa\",\"npub\":\"npub1aa\",\"label\":\"Alice\"}]"
  assert page.accounts(json_text)
    == [page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice")]
  assert page.accounts("not json") == []
}

/// 登録アカウントの全件が選ばれていれば、絞らない状態を表す空リストになる。
pub fn selecting_every_account_stores_no_rows_test() {
  let accounts = [
    page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice"),
    page.Account(pubkey: "bb", npub: "npub1bb", label: "Bob"),
  ]
  let values = dict.from_list([#("aa", "on"), #("bb", "on")])
  assert page.selected_pubkeys(accounts, values) == Ok([])
}

/// 一部だけ選ばれていれば、選んだ pubkey だけを返す。登録に無い名前は無視する。
pub fn selecting_some_accounts_stores_them_test() {
  let accounts = [
    page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice"),
    page.Account(pubkey: "bb", npub: "npub1bb", label: "Bob"),
  ]
  let values = dict.from_list([#("aa", "on"), #("unknown", "on")])
  assert page.selected_pubkeys(accounts, values) == Ok(["aa"])
}

/// 1 件も選ばれていない送信は拒否する。
pub fn selecting_no_account_is_rejected_test() {
  let accounts = [page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice")]
  assert page.selected_pubkeys(accounts, dict.new())
    == Error("select at least one account")
}

/// `Monitored accounts` の節はアカウントごとに 1 つの `checkbox` を持つ
/// `form` を出し、`checked` は今の監視対象に一致する。
pub fn the_monitored_section_lists_every_account_test() {
  let accounts = [
    page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice"),
    page.Account(pubkey: "bb", npub: "npub1bb", label: "Bob"),
  ]
  let monitored = Ok(store.OnlyPubkeys(set.from_list(["aa"])))
  let description =
    page.content(
      "settings",
      i18n.English,
      Error(Nil),
      2,
      [],
      accounts,
      monitored,
      Ok([]),
    )
  let assert [monitored_section, ..] = page_sections(description)
  let #(title, blocks) = section_shape(monitored_section)
  assert title == "Monitored accounts"
  let assert [_text, _note, form] = blocks
  let assert Ok(#(fields, submit)) =
    decode.run(form, {
      use fields <- decode.field("fields", decode.list(decode.dynamic))
      use submit <- decode.field("submit", decode.string)
      decode.success(#(fields, submit))
    })
  assert submit == "Save"
  let assert [aa_field, bb_field] = fields
  assert checkbox_field_shape(aa_field) == #("aa", "Alice", "npub1aa", True)
  assert checkbox_field_shape(bb_field) == #("bb", "Bob", "npub1bb", False)
}

/// `checkbox` フィールドの `name`・`label`・`hint`・`checked`。
fn checkbox_field_shape(raw: Dynamic) -> #(String, String, String, Bool) {
  let assert Ok(shape) =
    decode.run(raw, {
      use name <- decode.field("name", decode.string)
      use label <- decode.field("label", decode.string)
      use hint <- decode.field("hint", decode.string)
      use checked <- decode.field("checked", decode.bool)
      decode.success(#(name, label, hint, checked))
    })
  shape
}

/// 登録アカウントが 0 件のときは、本体が出す空の状態の文に任せて `blocks` を
/// 空にする。
pub fn the_monitored_section_is_empty_without_accounts_test() {
  let description =
    page.content(
      "settings",
      i18n.English,
      Error(Nil),
      2,
      [],
      [],
      Ok(store.AllAccounts),
      Ok([]),
    )
  let assert [monitored_section, ..] = page_sections(description)
  let #(_title, blocks) = section_shape(monitored_section)
  assert blocks == []
}

/// 保存アクターへの問い合わせが届かなければ `alert`（`failure`）1 つだけになる。
pub fn the_monitored_section_reports_an_unreachable_store_test() {
  let description =
    page.content(
      "settings",
      i18n.English,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Ok([]),
    )
  let assert [monitored_section, ..] = page_sections(description)
  let #(_title, blocks) = section_shape(monitored_section)
  let assert [alert] = blocks
  let assert Ok(#(kind, text, tone)) =
    decode.run(alert, {
      use kind <- decode.field("type", decode.string)
      use text <- decode.field("text", decode.string)
      use tone <- decode.field("tone", decode.string)
      decode.success(#(kind, text, tone))
    })
  assert kind == "alert"
  assert text
    == "monitored accounts are unavailable: the store actor did not answer"
  assert tone == "failure"
}

/// `Configuration` 節の `PLUGIN_EVENT_LOGGER_DATABASE_URL` は `code` インラインの
/// マスク済みの文字列である。
pub fn page_content_shows_the_masked_database_url_test() {
  let masked = "postgres://nostr@db.example:5432/nostr_no_su"
  let description =
    page.content(
      "settings",
      i18n.English,
      Ok(masked),
      2,
      [],
      [],
      Ok(store.AllAccounts),
      Ok([]),
    )
  let assert [_monitored, configuration, ..] = page_sections(description)
  let #(title, blocks) = section_shape(configuration)
  assert title == "Configuration"
  let assert [pairs, ..] = blocks
  let assert Ok(items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  let assert Ok(#(_term, kind, text)) =
    list.find(items, fn(item) { item.0 == "PLUGIN_EVENT_LOGGER_DATABASE_URL" })
  assert kind == "code"
  assert text == masked
}

/// 居ないプロセスの行は `badge`（`failure`）と `Pending messages` の `-` になり、
/// 生きている行は `success` と件数になる。1 件でも居なければ表の後ろに
/// `alert`（`warning`）が付く。
pub fn page_content_marks_missing_processes_test() {
  let processes = [
    page.ProcessStatus(
      label: i18n.ConnectionPool,
      registered_name: "event_logger_pool",
      mailbox: Ok(3),
    ),
    page.ProcessStatus(
      label: i18n.StoreActor,
      registered_name: "event_logger_store",
      mailbox: Error(Nil),
    ),
  ]
  let description =
    page.content(
      "settings",
      i18n.English,
      Error(Nil),
      2,
      processes,
      [],
      Ok(store.AllAccounts),
      Ok([]),
    )
  let assert [_monitored, _configuration, runtime] = page_sections(description)
  let #(title, blocks) = section_shape(runtime)
  assert title == "Runtime"
  let assert [table, alert] = blocks
  let assert [pool_row, store_row] = table_rows(table)
  assert row_status(pool_row) == #("running", "success", "3")
  assert row_status(store_row) == #("not running", "failure", "-")
  let assert Ok(#(kind, tone)) =
    decode.run(alert, {
      use kind <- decode.field("type", decode.string)
      use tone <- decode.field("tone", decode.string)
      decode.success(#(kind, tone))
    })
  assert kind == "alert"
  assert tone == "warning"
}

/// 未知のキーは `alert`（`failure`）1 つだけの節を返す。
pub fn page_content_of_an_unknown_key_test() {
  let description =
    page.content(
      "nope",
      i18n.English,
      Error(Nil),
      2,
      [],
      [],
      Ok(store.AllAccounts),
      Ok([]),
    )
  let assert [only] = page_sections(description)
  let #(_title, blocks) = section_shape(only)
  let assert [alert] = blocks
  let assert Ok(#(kind, tone)) =
    decode.run(alert, {
      use kind <- decode.field("type", decode.string)
      use tone <- decode.field("tone", decode.string)
      decode.success(#(kind, tone))
    })
  assert kind == "alert"
  assert tone == "failure"
}

/// `timeline` は行ごとに 1 つの節にする。見出しは `kind <n> · <RFC 3339>`、
/// `pairs` の `id`・`pubkey` は `id` インライン、`details` は
/// `tags (n)` / `content (n bytes)` / `signature` の 3 つになる。
pub fn the_timeline_lists_stored_events_test() {
  let first =
    store.Row(
      id: "id1",
      pubkey: "pub1",
      created_at: 1_700_000_000,
      kind: 1,
      tags: "[[\"p\",\"abc\"]]",
      content: "hello",
      sig: "sig1",
    )
  let second =
    store.Row(
      id: "id2",
      pubkey: "pub2",
      created_at: 1_700_000_001,
      kind: 7,
      tags: "[]",
      content: "hi",
      sig: "sig2",
    )
  let description =
    page.content(
      "timeline",
      i18n.English,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Ok([first, second]),
    )
  let assert [first_section, second_section] = page_sections(description)
  assert_event_section(first_section, first, "tags (1)", "content (5 bytes)")
  assert_event_section(second_section, second, "tags (0)", "content (2 bytes)")
}

/// 節 1 つが `event_section/2` の形（見出し・`pairs`・`details` 3 つ）を満たす
/// ことを確かめる。
fn assert_event_section(
  raw: Dynamic,
  row: store.Row,
  tags_summary: String,
  content_summary: String,
) -> Nil {
  let #(title, blocks) = section_shape(raw)
  assert string.starts_with(title, "kind " <> int.to_string(row.kind) <> " · ")
  let assert [pairs, tags_details, content_details, sig_details] = blocks
  let assert Ok(items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert items == [#("id", "id", row.id), #("pubkey", "id", row.pubkey)]
  assert details_summary(tags_details) == tags_summary
  assert details_summary(content_details) == content_summary
  assert details_summary(sig_details) == "signature"
  Nil
}

/// `details` ブロックの `summary`。
fn details_summary(raw: Dynamic) -> String {
  let assert Ok(summary) =
    decode.run(raw, decode.field("summary", decode.string, decode.success))
  summary
}

/// 保存済みイベントが 0 件なら、本体が出す空の状態の文に任せて `blocks` を
/// 空にする。
pub fn the_timeline_is_empty_without_events_test() {
  let description =
    page.content(
      "timeline",
      i18n.English,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Ok([]),
    )
  let assert [only] = page_sections(description)
  let #(_title, blocks) = section_shape(only)
  assert blocks == []
}

/// 直近のイベントの問い合わせが失敗すると `alert`（`failure`）1 つだけになる。
pub fn the_timeline_reports_a_failed_query_test() {
  let description =
    page.content(
      "timeline",
      i18n.English,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Error(i18n.EventsUnreadable("timeout")),
    )
  let assert [only] = page_sections(description)
  let #(_title, blocks) = section_shape(only)
  let assert [alert] = blocks
  let assert Ok(#(kind, text, tone)) =
    decode.run(alert, {
      use kind <- decode.field("type", decode.string)
      use text <- decode.field("text", decode.string)
      use tone <- decode.field("tone", decode.string)
      decode.success(#(kind, text, tone))
    })
  assert kind == "alert"
  assert text == "could not read stored events: timeout"
  assert tone == "failure"
}

/// calendar の範囲外の `created_at` でも節は返り、見出しは秒をそのまま文字に
/// した値になる。
pub fn out_of_range_timestamps_fall_back_to_the_number_test() {
  let row =
    store.Row(
      id: "id1",
      pubkey: "pub1",
      created_at: 10_000_000_000_000_000,
      kind: 1,
      tags: "[]",
      content: "hi",
      sig: "sig1",
    )
  let description =
    page.content(
      "timeline",
      i18n.English,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Ok([row]),
    )
  let assert [only] = page_sections(description)
  let #(title, _blocks) = section_shape(only)
  assert title == "kind 1 · 10000000000000000"
}

/// `store.migrations` に版 3 があり、その文は `create_received_at_index` の
/// 1 件だけで、`events_received_at` を含む。
pub fn the_received_at_index_is_created_test() {
  let assert Ok(migration) =
    list.find(store.migrations, fn(migration) { migration.version == 3 })
  assert migration.statements == [store.create_received_at_index]
  assert string.contains(store.create_received_at_index, "events_received_at")
}

/// 言語のコードは `ja` だけが日本語で、`en` と知らないコードは英語になる。
pub fn language_codes_fall_back_to_english_test() {
  assert i18n.from_code("ja") == i18n.Japanese
  assert i18n.from_code("en") == i18n.English
  assert i18n.from_code("fr") == i18n.English
}

/// `plugin_pages/2` の表示名は言語のコードに従い、知らないコードでは英語になる。
/// キーと並びは言語によらない。
pub fn plugin_pages_follow_the_display_language_test() {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use title <- decode.field("title", decode.string)
    decode.success(#(key, title))
  }
  let pages = fn(code) {
    let assert Ok(entries) =
      decode.run(
        event_logger.plugin_pages(dynamic.nil(), dynamic.string(code)),
        decode.list(decoder),
      )
    entries
  }
  assert pages("ja") == [#("timeline", "タイムライン"), #("settings", "設定")]
  assert pages("en") == [#("timeline", "Timeline"), #("settings", "Settings")]
  assert pages("fr") == pages("en")
}

/// `plugin_page_content/3` は第 3 引数の言語で文言を組む。テストの VM には
/// プールも保存アクターも居ないので、タイムラインはプールの不在の `alert`、
/// 設定の表は 2 行とも居ないプロセスになる。
pub fn plugin_page_content_follows_the_display_language_test() {
  let config =
    dynamic.properties([
      #(
        dynamic.string("database_url"),
        dynamic.string("postgres://nostr:secret@db.example:5432/nostr_no_su"),
      ),
    ])
  let timeline = fn(code) {
    let description =
      event_logger.plugin_page_content(
        dynamic.string("timeline"),
        config,
        dynamic.string(code),
      )
    let assert [only] = page_sections(description)
    let #(title, blocks) = section_shape(only)
    let assert [alert] = blocks
    #(title, block_text(alert))
  }
  assert timeline("ja") == #("タイムライン", "接続プールが動いていません。")
  assert timeline("en") == #("Timeline", "connection pool is not running")
  let description =
    event_logger.plugin_page_content(
      dynamic.string("settings"),
      config,
      dynamic.string("ja"),
    )
  let assert [_monitored, _configuration, runtime] = page_sections(description)
  let #(_title, blocks) = section_shape(runtime)
  let assert [table, ..] = blocks
  assert list.map(table_rows(table), first_cell_text) == ["接続プール", "保存アクター"]
}

/// 日本語の `settings` は、節の見出し、説明とボタン、設定の語と注記、表の見出しと
/// バッジ、居ないプロセスの注意を日本語で出す。環境変数の名前は訳さない。
pub fn the_settings_page_is_in_japanese_test() {
  let accounts = [page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice")]
  let processes = [
    page.ProcessStatus(
      label: i18n.ConnectionPool,
      registered_name: "event_logger_pool",
      mailbox: Ok(0),
    ),
    page.ProcessStatus(
      label: i18n.StoreActor,
      registered_name: "event_logger_store",
      mailbox: Error(Nil),
    ),
  ]
  let description =
    page.content(
      "settings",
      i18n.Japanese,
      Error(Nil),
      2,
      processes,
      accounts,
      Ok(store.AllAccounts),
      Ok([]),
    )
  let assert [monitored, configuration, runtime] = page_sections(description)
  let #(monitored_title, monitored_blocks) = section_shape(monitored)
  assert monitored_title == "保存するアカウント"
  let assert [text, note, form] = monitored_blocks
  assert block_text(text) == "チェックしたアカウントのイベントだけを保存します。"
  assert block_text(note) == "すべてにチェックすると、あとで登録するアカウントも含めて全アカウントが対象になります。"
  let assert Ok(submit) =
    decode.run(form, decode.field("submit", decode.string, decode.success))
  assert submit == "保存する"
  let #(configuration_title, configuration_blocks) =
    section_shape(configuration)
  assert configuration_title == "接続先と上限"
  let assert [pairs, configuration_note] = configuration_blocks
  let assert Ok(items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert list.map(items, fn(item) { #(item.0, item.2) })
    == [
      #("PLUGIN_EVENT_LOGGER_DATABASE_URL", "未設定"),
      #("接続数", "2"),
      #("保存待ちの上限", int.to_string(store.default_max_queue_len)),
    ]
  assert block_text(configuration_note)
    == "上の URL は、このプラグインがパスワードを取り除いて表示しています。接続先はこの環境変数だけで決まり、このページからは変えられません。このページで選べるのは、イベントを保存するアカウントだけです。"
  let #(runtime_title, runtime_blocks) = section_shape(runtime)
  assert runtime_title == "プロセス"
  let assert [table, warning] = runtime_blocks
  let assert Ok(headers) =
    decode.run(
      table,
      decode.field("headers", decode.list(decode.string), decode.success),
    )
  assert headers == ["プロセス", "登録名", "状態", "未処理のメッセージ"]
  assert list.map(table_rows(table), fn(row) { row_status(row).0 })
    == ["動作中", "停止中"]
  assert block_text(warning)
    == "停止中のプロセスは、再起動の途中か、再起動を諦められた状態です。plugin-api.md の第 5.4 節を参照してください。"
}

/// 日本語の `alert` は、保存アクターの無応答、未知のページ、タイムラインの
/// 読み込みの失敗のどれも日本語の文になる。読み込みの失敗の詳細は訳さない。
pub fn the_alerts_are_in_japanese_test() {
  let settings =
    page.content(
      "settings",
      i18n.Japanese,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Ok([]),
    )
  let assert [monitored, ..] = page_sections(settings)
  let assert #(_title, [store_alert]) = section_shape(monitored)
  assert block_text(store_alert) == "保存アクターが応答しないため、保存するアカウントを表示できません。"
  let unknown =
    page.content(
      "nope",
      i18n.Japanese,
      Error(Nil),
      2,
      [],
      [],
      Ok(store.AllAccounts),
      Ok([]),
    )
  let assert [error_section] = page_sections(unknown)
  let assert #("エラー", [unknown_alert]) = section_shape(error_section)
  assert block_text(unknown_alert) == "このページはありません。"
  let timeline =
    page.content(
      "timeline",
      i18n.Japanese,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Error(i18n.EventsUnreadable("timeout")),
    )
  let assert [timeline_section] = page_sections(timeline)
  let assert #("タイムライン", [timeline_alert]) = section_shape(timeline_section)
  assert block_text(timeline_alert) == "保存済みのイベントを読めませんでした: timeout"
}

/// 日本語のタイムラインでも見出しと NIP-01 のフィールド名は訳さず、`details` の
/// 見出しの件数とバイト数の書き方だけが日本語になる。
pub fn the_timeline_details_are_in_japanese_test() {
  let row =
    store.Row(
      id: "id1",
      pubkey: "pub1",
      created_at: 1_700_000_000,
      kind: 1,
      tags: "[[\"p\",\"abc\"]]",
      content: "hello",
      sig: "sig1",
    )
  let description =
    page.content(
      "timeline",
      i18n.Japanese,
      Error(Nil),
      2,
      [],
      [],
      Error(Nil),
      Ok([row]),
    )
  let assert [only] = page_sections(description)
  assert_event_section(only, row, "tags（1 件）", "content（5 バイト）")
}

/// postgres の URL として読めない値の代わりの文は、表示の言語の文になる。
pub fn invalid_database_urls_are_reported_in_the_language_test() {
  let pool = process.new_name("test_invalid_url_pool")
  assert page.masked_url(pool, "not a url", i18n.Japanese)
    == "PLUGIN_EVENT_LOGGER_DATABASE_URL を postgres の URL として読めません。"
  assert page.masked_url(pool, "not a url", i18n.English)
    == "PLUGIN_EVENT_LOGGER_DATABASE_URL is not a valid postgres URL"
}

/// 記述の `sections` を取り出す。
fn page_sections(description: Dynamic) -> List(Dynamic) {
  let assert Ok(sections) =
    decode.run(
      description,
      decode.field("sections", decode.list(decode.dynamic), decode.success),
    )
  sections
}

/// 節の `title` と `blocks`。
fn section_shape(raw: Dynamic) -> #(String, List(Dynamic)) {
  let assert Ok(shape) =
    decode.run(raw, {
      use title <- decode.field("title", decode.string)
      use blocks <- decode.field("blocks", decode.list(decode.dynamic))
      decode.success(#(title, blocks))
    })
  shape
}

/// `pairs` ブロックの 1 項目。`term` と、値の `type` / `text`。
fn pair_item_decoder() -> decode.Decoder(#(String, String, String)) {
  use term <- decode.field("term", decode.string)
  use kind <- decode.subfield(["value", "type"], decode.string)
  use text <- decode.subfield(["value", "text"], decode.string)
  decode.success(#(term, kind, text))
}

/// `Runtime` の表の 1 行から `Status` のバッジの文字列と `tone`、
/// `Pending messages` の文字列を取り出す。セルの並びは `Process` /
/// `Registered name` / `Status` / `Pending messages`。
fn row_status(row: List(Dynamic)) -> #(String, String, String) {
  let assert [_label, _registered_name, status, pending] = row
  let assert Ok(#(status_text, tone)) =
    decode.run(status, {
      use text <- decode.field("text", decode.string)
      use tone <- decode.field("tone", decode.string)
      decode.success(#(text, tone))
    })
  #(status_text, tone, block_text(pending))
}

/// `table` ブロックの `rows`。
fn table_rows(table: Dynamic) -> List(List(Dynamic)) {
  let assert Ok(rows) =
    decode.run(
      table,
      decode.field(
        "rows",
        decode.list(decode.list(decode.dynamic)),
        decode.success,
      ),
    )
  rows
}

/// ブロックかインラインの `text`。
fn block_text(raw: Dynamic) -> String {
  let assert Ok(text) =
    decode.run(raw, decode.field("text", decode.string, decode.success))
  text
}

/// 表の 1 行の先頭のセルの文字列。
fn first_cell_text(row: List(Dynamic)) -> String {
  let assert [first, ..] = row
  block_text(first)
}

/// 実際の Postgres に対する統合テスト。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。スキーマの移行・挿入・
/// 重複無視・jsonb としての読み戻し・インデックスの作成・NUL を含む行の拒否を
/// 一巡して確かめる。
///
/// 同じ DB に対して `gleam test` を並行実行することは想定していない
/// （版の記録の挿入やテーブルの作成が競合しうる）。CI は専用の service を
/// 使い、ローカルでも使い捨てのコンテナーを使うこと。
pub fn postgres_round_trip_test() {
  use database_url <- with_test_database_url
  round_trip(database_url)
}

/// スキーマの移行・挿入・重複挿入・後片付け・NUL を含む行の拒否を一巡させる。
fn round_trip(database_url: String) -> Nil {
  let db = connect(database_url, None)
  // 2 回続けて実行しても失敗しない。
  let assert Ok(Nil) = store.ensure_schema(db)
  let assert Ok(Nil) = store.ensure_schema(db)
  assert index_names(db)
    == [
      "events_kind", "events_pkey", "events_pubkey_created_at",
      "events_received_at",
    ]

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

  // Postgres の text は NUL を持てず、jsonb は \u0000 を受け付けない。
  let assert Error(pog.PostgresqlError(code: "22021", ..)) =
    store.insert(db, store.Row(..stored, content: "a\u{0000}b"))
  let assert Ok(nul_tag) =
    store.to_row(event_map(random_id(), [["t", "a\u{0000}b"]]))
  let assert Error(pog.PostgresqlError(code: "22P05", ..)) =
    store.insert(db, nul_tag)
  assert count_rows(db, stored.id) == 0
}

/// 実際の Postgres に対する統合テスト。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。版の記録より前に作られた
/// テーブルが版 1 として取り込まれ、版が新しい DB は拒否されることを確かめる。
pub fn postgres_schema_version_test() {
  use database_url <- with_test_database_url
  schema_version_round_trip(database_url)
}

/// 専用のスキーマでテストを行い、最後にスキーマごと消す。`CREATE SCHEMA` と
/// `DROP SCHEMA … CASCADE` は `search_path` の無い接続で、それ以外（テーブルと
/// インデックスの直接実行、`ensure_schema`、版 4 の挿入、版の読み込み）は専用
/// スキーマへ向けた接続で実行する。
fn schema_version_round_trip(database_url: String) -> Nil {
  let schema = "event_logger_schema_" <> random_id()
  let admin = connect(database_url, None)
  run_statement(admin, "CREATE SCHEMA " <> schema)
  let db = connect(database_url, Some(schema))

  // 版の記録より前に作られた DB を再現する。
  run_statement(db, store.create_events_table)
  run_statement(db, store.create_pubkey_index)
  run_statement(db, store.create_kind_index)

  // 移行の後、もう一度実行しても版は増えない（移行を二重に適用しない）。
  let assert Ok(Nil) = store.ensure_schema(db)
  let assert Ok(Nil) = store.ensure_schema(db)
  assert recorded_versions(db) == [1, 2, 3]

  // 記録された版が新しい DB は拒否する。
  run_statement(
    db,
    "INSERT INTO event_logger_schema_version (version) VALUES (4)",
  )
  assert store.ensure_schema(db)
    == Error(store.SchemaTooNew(found: 4, supported: 3))

  run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// 実際の Postgres に対する統合テスト。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。`ensure_schema` の後に `monitored_accounts` があり、
/// `replace_monitored` で書いた pubkey が `load_monitored` で読め、
/// `replace_monitored(db, [])` で 0 件に戻ることを確かめる。
pub fn postgres_monitored_accounts_test() {
  use database_url <- with_test_database_url
  monitored_accounts_round_trip(database_url)
}

/// 専用のスキーマでテストを行い、最後にスキーマごと消す。
fn monitored_accounts_round_trip(database_url: String) -> Nil {
  let schema = "event_logger_schema_" <> random_id()
  let admin = connect(database_url, None)
  run_statement(admin, "CREATE SCHEMA " <> schema)
  let db = connect(database_url, Some(schema))

  let assert Ok(Nil) = store.ensure_schema(db)
  assert store.load_monitored(db) == Ok([])

  let assert Ok(Nil) = store.replace_monitored(db, ["aa", "bb"])
  let assert Ok(rows) = store.load_monitored(db)
  assert set.from_list(rows) == set.from_list(["aa", "bb"])

  let assert Ok(Nil) = store.replace_monitored(db, [])
  assert store.load_monitored(db) == Ok([])

  run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// 実際の Postgres に対する統合テスト。`TEST_DATABASE_URL` が設定されている
/// ときだけ実行する。専用スキーマに 21 行入れ、`recent_events(db, store.recent_limit)`
/// が直近の 20 行を返し、最初に入れた行だけが欠けることを確かめる。
pub fn postgres_recent_events_test() {
  use database_url <- with_test_database_url
  recent_events_round_trip(database_url)
}

/// 専用のスキーマでテストを行い、最後にスキーマごと消す。21 行の id は挿入順に
/// 昇順の文字列（`"00"`〜`"20"`）にする。
fn recent_events_round_trip(database_url: String) -> Nil {
  let schema = "event_logger_schema_" <> random_id()
  let admin = connect(database_url, None)
  run_statement(admin, "CREATE SCHEMA " <> schema)
  let db = connect(database_url, Some(schema))
  let assert Ok(Nil) = store.ensure_schema(db)

  let ids =
    list.repeat(Nil, 21)
    |> list.index_map(fn(_, sequence) {
      let id = case sequence < 10 {
        True -> "0" <> int.to_string(sequence)
        False -> int.to_string(sequence)
      }
      let assert Ok(row) = store.to_row(sample_event(id))
      let assert Ok(1) = store.insert(db, row)
      id
    })

  let assert Ok(rows) = store.recent_events(db, store.recent_limit)
  let returned_ids = list.map(rows, fn(row) { row.id })
  assert list.length(returned_ids) == 20
  assert !list.contains(returned_ids, "00")
  let assert [_first, ..rest] = ids
  assert list.all(rest, list.contains(returned_ids, _))

  run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// 結果を読まない文を 1 つ実行する。
fn run_statement(db: pog.Connection, statement: String) -> Nil {
  let assert Ok(_returned) =
    pog.query(statement)
    |> pog.timeout(30_000)
    |> pog.execute(on: db)
  Nil
}

/// `event_logger_schema_version` に記録されている版の一覧（昇順）。
fn recorded_versions(db: pog.Connection) -> List(Int) {
  let assert Ok(returned) =
    pog.query(
      "SELECT version FROM event_logger_schema_version ORDER BY version",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(on: db)
  returned.rows
}

/// テスト用の接続プールを起動する。プールはテストプロセスにリンクされるため、
/// テストが終われば一緒に停止する。`search_path` を指定すると、テーブル名を
/// そのスキーマで解決する。
fn connect(
  database_url: String,
  search_path: Option(String),
) -> pog.Connection {
  let assert Ok(config) =
    pog.url_config(process.new_name("test_event_logger_pool"), database_url)
  let config = case search_path {
    Some(schema) -> pog.connection_parameter(config, "search_path", schema)
    None -> config
  }
  let assert Ok(started) = pog.start(config)
  started.data
}

/// 実行のたびに違うイベント id。テストを繰り返しても前回の行と衝突しない。
fn random_id() -> String {
  int.to_base16(int.random(1_000_000_000))
}

/// `events` に張られているインデックスの名前（主キーを含む）。現在の
/// `search_path` が解決するスキーマに絞る。専用のスキーマが後片付けの失敗で
/// 残っていても、他のスキーマの同名のインデックスを拾わないためである。
fn index_names(db: pog.Connection) -> List(String) {
  let decoder = {
    use name <- decode.field(0, decode.string)
    decode.success(name)
  }
  let assert Ok(returned) =
    pog.query(
      "SELECT indexname FROM pg_indexes
WHERE tablename = 'events' AND schemaname = ANY(current_schemas(false))
ORDER BY indexname",
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

/// `TEST_DATABASE_URL` が空でなければその値で `run` を呼ぶ。未設定または空の
/// ときはスキップを 1 行ログに出す。本体の `test/support/postgres.with_test_database_url` と同じ処理だが、
/// event_logger は本体とは別の Gleam プロジェクトで import できないため、ここに
/// 重複して持つ。
fn with_test_database_url(run: fn(String) -> Nil) -> Nil {
  case envoy.get("TEST_DATABASE_URL") {
    Ok(url) if url != "" -> run(url)
    _ ->
      io.println(
        "[event_logger] TEST_DATABASE_URL is not set; skipping the integration test",
      )
  }
}
