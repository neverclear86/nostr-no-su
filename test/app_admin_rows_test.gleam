//// 管理 UI へ渡すものを確かめるテスト。登録されたリレーの起動後の接続と実行時の増減、
//// リレーとプラグインの行を締め切りまでに組むこと、アカウントの行へ写真の URL を
//// 入れること、ページの送信を受けるプラグインの口を名前で引くことを扱う。

import gleam/dict
import gleam/dynamic
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/connection_uri
import nostr_no_su/db
import nostr_no_su/plugin
import nostr_no_su/plugin_config
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/task
import nostr_no_su/time
import pog
import support/app_tree.{
  type Report, Opened, Published, await_connection, base_spec, bunker_spec,
  call_counter, connect_request, connection_name, deliver_and_expect,
  event_labels, fixed_retry_delay, forwarding_spec, idle_bunker, idle_plugin,
  load_signer, plugin_spec, secret, signer_key, signer_store, start_tree,
  start_tree_with_relays, stop_tree, store_failure, store_with_load,
  test_relay_url,
}
import support/nip46_client.{account_for}
import support/poll
import support/postgres
import support/random_account.{random_master_key}

/// 管理 UI のページの中身の取得は、表示の言語のコードをプラグインの `content` に
/// 渡す。ツリーを起動しない。
pub fn plugin_page_content_passes_the_language_test() {
  let spec =
    plugin_spec(
      process.new_name("echo"),
      plugin.Plugin(
        ..idle_plugin("echo"),
        ui: Some(plugin.PluginUi(
          pages: [plugin.PluginPage(key: "status", title: "Status")],
          content: fn(key, language, _accounts) {
            Ok(dynamic.string(key <> ":" <> language))
          },
          action: None,
        )),
      ),
    )
  assert app.plugin_page_content([spec], "echo", "status", "ja", [])
    == Ok(dynamic.string("status:ja"))
}

/// 名前が `name` で、管理 UI のページの定義が `ui` のプラグインの仕様。ツリーには
/// 載せず、名前でプラグインを引く関数に一覧として渡す。
fn page_plugin(name: String, ui: Option(plugin.PluginUi)) -> app.PluginSpec {
  plugin_spec(
    process.new_name(name),
    plugin.Plugin(..idle_plugin(name), ui: ui),
  )
}

/// `status` のページを 1 つ持ち、フォームの送信の口が `action` の UI。中身の取得は
/// 使わないので空の文字列を返す。
fn page_ui(
  action: Option(
    fn(String, List(#(String, String)), List(plugin_config.PageAccount)) ->
      Result(Nil, String),
  ),
) -> Option(plugin.PluginUi) {
  Some(plugin.PluginUi(
    pages: [plugin.PluginPage(key: "status", title: "Status")],
    content: fn(_key, _language, _accounts) { Ok(dynamic.string("")) },
    action: action,
  ))
}

/// `plugin_page_action` は名前でプラグインを引き、返す関数はそのプラグインの `action`
/// を、ページのキーと送信の値と `page_accounts` の一覧で呼ぶ。`page_accounts` は
/// バンカーの登録アカウントを `PageAccount` に写す。一覧の先頭の別名のプラグインは
/// 呼ばれない。
pub fn plugin_page_action_calls_the_named_plugin_with_the_key_test() {
  let received = process.new_subject()
  let spec = signer_spec(process.new_subject())
  let tree = start_tree(spec)
  let plugins = [
    page_plugin(
      "other",
      page_ui(Some(fn(_key, _values, _accounts) { panic as "wrong plugin" })),
    ),
    page_plugin(
      "echo",
      page_ui(
        Some(fn(key, values, accounts) {
          process.send(received, #(key, values, accounts))
          Ok(Nil)
        }),
      ),
    ),
  ]
  let assert Ok(accounts) = app.page_accounts(spec)
  let signer = account_for(signer_key)
  assert accounts
    == [
      plugin_config.PageAccount(
        pubkey: account.pubkey_hex(signer),
        npub: account.npub(signer),
        label: "",
      ),
    ]

  let assert Some(run) = app.plugin_page_action(plugins, "echo", "status")
  assert run([#("note", "hi")], accounts) == Ok(Nil)
  assert process.receive(received, 100)
    == Ok(#("status", [#("note", "hi")], accounts))
  stop_tree(tree)
}

/// 名前に一致するプラグインが無ければ `None`。一覧のプラグインには `action` を持たせ、
/// 名前で引かずに先頭を取る誤りでは `Some` になるようにしてある。
pub fn plugin_page_action_without_the_plugin_is_none_test() {
  let plugins = [
    page_plugin("echo", page_ui(Some(fn(_key, _values, _accounts) { Ok(Nil) }))),
  ]
  assert app.plugin_page_action(plugins, "missing", "status") == None
}

/// 管理 UI のページを持たないプラグインは `None`。
pub fn plugin_page_action_without_pages_is_none_test() {
  let plugins = [page_plugin("echo", None)]
  assert app.plugin_page_action(plugins, "echo", "status") == None
}

/// ページはあってもフォームの送信の口を持たないプラグインは `None`。
pub fn plugin_page_action_without_the_action_is_none_test() {
  let plugins = [page_plugin("echo", page_ui(None))]
  assert app.plugin_page_action(plugins, "echo", "status") == None
}

// --- 登録されたリレー ---

/// `signer_key` のアカウントと、`url` の `BunkerOnly` のリレーを持つ読み込みの結果。
fn load_signer_with_relay(url: String) -> Result(bunker.Snapshot, String) {
  use snapshot <- result.try(load_signer(signer_key))
  Ok(
    bunker.Snapshot(..snapshot, relays: [
      relay_list.Registered(url: url, roles: relay_list.BunkerOnly),
    ]),
  )
}

/// リレーを開かずに起動したツリーでも、最初の読み込みで届いた `Snapshot.relays`
/// から接続が開く。
pub fn registered_relays_open_after_the_first_load_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let url = "ws://registered.test"
  let store = store_with_load(fn() { load_signer_with_relay(url) })
  let spec =
    app.Spec(
      ..base_spec(reports),
      bunker: bunker_spec(name, store, fixed_retry_delay),
    )
  let tree = start_tree(spec)
  let assert Opened(opened_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert opened_url == url
  assert role_url_pairs(spec) == [#(relay_list.Bunker, url)]
  stop_tree(tree)
}

/// 読み込みが失敗している間はリレーを開かず、ストアが復旧して読み込みに成功した
/// 後に開く。
pub fn registered_relays_open_after_the_store_recovers_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let url = "ws://registered-after-recovery.test"
  let next_load = call_counter()
  let store =
    store_with_load(fn() {
      case next_load() {
        0 -> Error(store_failure())
        _ -> load_signer_with_relay(url)
      }
    })
  let spec =
    app.Spec(
      ..base_spec(reports),
      bunker: bunker_spec(name, store, Backoff(initial_ms: 300, max_ms: 300)),
    )
  let tree = start_tree(spec)
  // 最初の読み込みが失敗している間は開かない。
  assert process.receive(reports, 100) == Error(Nil)
  let assert Opened(opened_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert opened_url == url
  stop_tree(tree)
}

// --- 実行時のリレーの増減 ---

/// `relay_list` の一覧を、監視、バンカーの順の `#(用途, URL)` にする。
fn role_url_pairs(spec: app.Spec) -> List(#(relay_list.Role, String)) {
  let assert Ok(entries) = relay_list.entries(spec.relay_list)
  [relay_list.Monitor, relay_list.Bunker]
  |> list.flat_map(fn(role) {
    list.map(relay_list.urls(entries, role), fn(url) { #(role, url) })
  })
}

/// `merge_relay_rows` は DB の行の順を保ち、`relay_list` にだけある URL を出さない。
/// 用途を使っていて接続があれば `status` の結果（`None` なら `Unanswered`）を、
/// 無ければ未接続を、用途を使っていなければ `Unused` を返す。
pub fn merged_relay_rows_follow_the_store_test() {
  let monitor_a = process.new_name("test_merge_monitor_a")
  let bunker_a = process.new_name("test_merge_bunker_a")
  let monitor_d = process.new_name("test_merge_monitor_d")
  let relays = [
    relay_store.Relay(id: 1, url: "wss://a", roles: relay_list.Both),
    relay_store.Relay(id: 2, url: "wss://b", roles: relay_list.MonitorOnly),
    relay_store.Relay(id: 3, url: "wss://c", roles: relay_list.BunkerOnly),
    relay_store.Relay(id: 4, url: "wss://d", roles: relay_list.MonitorOnly),
  ]
  let entries = [
    relay_list.Entry(
      url: "wss://a",
      monitor: Some(monitor_a),
      bunker: Some(bunker_a),
    ),
    relay_list.Entry(url: "wss://d", monitor: Some(monitor_d), bunker: None),
    relay_list.Entry(
      url: "wss://only-in-relay-list",
      monitor: Some(process.new_name("test_merge_extra")),
      bunker: None,
    ),
  ]
  let status = fn(name) {
    case name == monitor_a, name == bunker_a, name == monitor_d {
      True, _, _ -> Some(relay_connection.Connected)
      _, True, _ -> Some(relay_connection.Disconnected)
      _, _, True -> None
      _, _, _ -> panic as "unexpected name"
    }
  }
  assert app.merge_relay_rows(relays, entries, status)
    == [
      dashboard.RelayRow(
        id: 1,
        url: "wss://a",
        monitor: dashboard.Reported(relay_connection.Connected),
        bunker: dashboard.Reported(relay_connection.Disconnected),
      ),
      dashboard.RelayRow(
        id: 2,
        url: "wss://b",
        monitor: dashboard.Reported(relay_connection.Disconnected),
        bunker: dashboard.Unused,
      ),
      dashboard.RelayRow(
        id: 3,
        url: "wss://c",
        monitor: dashboard.Unused,
        bunker: dashboard.Reported(relay_connection.Disconnected),
      ),
      dashboard.RelayRow(
        id: 4,
        url: "wss://d",
        monitor: dashboard.Unanswered,
        bunker: dashboard.Unused,
      ),
    ]
}

/// `relay_list` が応答しなければ、DB を読まずにその理由を返す。
pub fn relay_rows_without_the_relay_list_test() {
  assert app.relay_rows(
      base_spec(process.new_subject()),
      task.deadline_in(5000),
    )
    == Error("relay list did not answer")
}

/// `relay_rows` は DB の行の順に、用途ごとの接続の状態を入れる。両方の用途で開いた
/// 行は両方 `Connected`、DB にだけある行は使う用途が未接続で使わない用途が `Unused`
/// になり、`relay_list` にだけある URL は出ない。`TEST_DATABASE_URL` があるとき
/// だけ実行する。
pub fn relay_rows_report_each_role_of_the_registered_relays_test() {
  use spec, db <- with_relay_store_tree()

  let assert Ok(Nil) = app.add_relay(spec, "ws://both.test", relay_list.Both)
  let assert Ok(unopened) =
    relay_store.insert(
      db,
      "ws://unopened.test",
      relay_list.MonitorOnly,
      db.default_timeouts,
    )
  let assert Ok(Nil) =
    app.open_relay(spec, "ws://unregistered.test", relay_list.MonitorOnly)

  let assert Ok([both, _unopened]) = app.registered_relays(spec)
  assert app.relay_rows(spec, task.deadline_in(5000))
    == Ok([
      dashboard.RelayRow(
        id: both.id,
        url: "ws://both.test",
        monitor: dashboard.Reported(relay_connection.Connected),
        bunker: dashboard.Reported(relay_connection.Connected),
      ),
      dashboard.RelayRow(
        id: unopened.id,
        url: "ws://unopened.test",
        monitor: dashboard.Reported(relay_connection.Disconnected),
        bunker: dashboard.Unused,
      ),
    ])
}

/// 名前 `name` を登録して 2 秒眠るだけのプロセスを起動し、登録を待つ。問い合わせを
/// 無視し続けるので、`relay_connection.status`（5 秒）や `plugin_runner.status`（1 秒）の
/// 待ちより短い締め切りの問い合わせは間に合わない。
fn spawn_unanswering(name: Name(a)) -> Nil {
  process.spawn_unlinked(fn() {
    let assert Ok(Nil) = process.register(process.self(), name)
    process.sleep(2000)
  })
  await_named_registration(name, 1000)
}

/// 名前が登録されるまで待つ。期限までに登録されなければ落ちる。
fn await_named_registration(name: Name(a), timeout_ms: Int) -> Nil {
  assert poll.until(fn() { result.is_ok(process.named(name)) }, timeout_ms, 10)
}

/// 応答しない接続を 4 本、300ms の期限で問い合わせると、全て `None`（応答なし）
/// になり、名前を持つプロセスの無いものは即座に `Some(Disconnected)` になる。
/// 合計の経過は締め切りに収まる（1 秒未満）。
pub fn relay_statuses_give_up_on_unanswering_connections_test() {
  let unanswering = [
    process.new_name("test_relay_statuses_unanswering_1"),
    process.new_name("test_relay_statuses_unanswering_2"),
    process.new_name("test_relay_statuses_unanswering_3"),
    process.new_name("test_relay_statuses_unanswering_4"),
  ]
  list.each(unanswering, spawn_unanswering)
  let unregistered = process.new_name("test_relay_statuses_unregistered")
  let started_at = time.monotonic_ms()
  let results =
    app.relay_statuses([unregistered, ..unanswering], task.deadline_in(300))
  assert time.monotonic_ms() - started_at < 1000
  let assert Ok(unregistered_status) = list.key_find(results, unregistered)
  assert unregistered_status == Some(relay_connection.Disconnected)
  use name <- list.each(unanswering)
  let assert Ok(status) = list.key_find(results, name)
  assert status == None
}

/// `app.plugin_rows` は答えたランナーの状態と、プラグインの UI が供給するページを
/// 行に入れる。
pub fn plugin_rows_carry_the_runner_status_and_pages_test() {
  let name = process.new_name("test_plugin_rows_runner")
  let paged =
    plugin.Plugin(
      ..idle_plugin("paged"),
      ui: Some(plugin.PluginUi(
        pages: [plugin.PluginPage(key: "status", title: "Status")],
        content: fn(_key, _language, _accounts) { Ok(dynamic.string("")) },
        action: None,
      )),
    )
  let assert Ok(_) =
    plugin_runner.start(name, paged, fn() { Nil }, plugin_runner.default_limits)
  assert app.plugin_rows([plugin_spec(name, paged)], task.deadline_in(1000))
    == [
      dashboard.PluginRow(
        name: "paged",
        status: Some(plugin_runner.Running),
        pages: [plugin.PluginPage(key: "status", title: "Status")],
      ),
    ]
}

/// 締め切りまでに答えないランナーの行は状態を `None`（応答なし）にし、UI を持たない
/// プラグインの行のページは空にする。ランナーへは並行に問い合わせるので、2 本とも
/// 答えなくても経過は `plugin_runner.status` の待ち（1 秒）に収まる。
pub fn plugin_rows_give_up_on_unanswering_runners_test() {
  let unanswering = [
    process.new_name("test_plugin_rows_unanswering_1"),
    process.new_name("test_plugin_rows_unanswering_2"),
  ]
  list.each(unanswering, spawn_unanswering)
  let specs = list.map(unanswering, plugin_spec(_, idle_plugin("silent")))
  let started_at = time.monotonic_ms()
  let rows = app.plugin_rows(specs, task.deadline_in(300))
  assert time.monotonic_ms() - started_at < 1000
  assert rows
    == [
      dashboard.PluginRow(name: "silent", status: None, pages: []),
      dashboard.PluginRow(name: "silent", status: None, pages: []),
    ]
}

/// 監視のリレー 0 本の木で `open_relay` を呼ぶと、後から足したリレーで受信した
/// イベントもプラグインに届く。
pub fn a_monitor_relay_opened_at_runtime_delivers_events_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let spec =
    app.Spec(..base_spec(reports), plugins: [
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let tree = start_tree(spec)
  let assert Ok(Nil) =
    app.open_relay(spec, test_relay_url, relay_list.MonitorOnly)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver_and_expect(deliver, seen, event_labels("runtime", 3), 2000)
  stop_tree(tree)
}

/// `TEST_DATABASE_URL` があるときだけ、専用のスキーマに移行を当て、バンカーのプールの
/// `search_path` をそのスキーマにしたツリーを起動する。バンカーのプールが応答してから、
/// 仕様とそのプールの接続で `run` を呼び、終わったらツリーを止めてスキーマごと消す。
fn with_relay_store_tree(run: fn(app.Spec, pog.Connection) -> Nil) -> Nil {
  use database_url <- postgres.with_test_database_url("app")
  use schema, schema_pool, _schema_db <- postgres.with_named_schema(
    database_url,
  )

  // 移行を実行する。
  let assert Ok(_loaded) =
    postgres.load_stored(schema_pool, random_master_key(), db.default_timeouts)

  let assert Ok(config) =
    pog.url_config(process.new_name("test_app_relay_pool"), database_url)
  let config = pog.connection_parameter(config, "search_path", schema)
  let spec =
    app.Spec(
      ..base_spec(process.new_subject()),
      bunker: app.Bunker(..idle_bunker(), pool: config),
    )
  let tree = start_tree(spec)
  let db = pog.named_connection(config.pool_name)
  assert postgres.await_pool(db, 10_000)

  run(spec, db)
  stop_tree(tree)
}

/// `app.add_relay` は DB に挿入してから接続を開く。同じ URL の 2 回目は
/// `DuplicateRelay`、`relay_list` にすでにある URL への追加は `ConnectionsNotConfirmed`
/// になるが、どちらも先に挿入は確かめる。`TEST_DATABASE_URL` があるときだけ実行する。
pub fn add_relay_saves_the_row_before_opening_test() {
  use spec, db <- with_relay_store_tree()

  let assert Ok(Nil) =
    app.add_relay(spec, "ws://added.test", relay_list.MonitorOnly)
  assert role_url_pairs(spec) == [#(relay_list.Monitor, "ws://added.test")]
  let assert Ok(rows) = relay_store.list(db, db.default_timeouts)
  assert list.map(rows, fn(row) { row.url }) == ["ws://added.test"]

  assert app.add_relay(spec, "ws://added.test", relay_list.MonitorOnly)
    == Error(admin.DuplicateRelay)

  let assert Ok(Nil) =
    app.open_relay(spec, "ws://listed.test", relay_list.MonitorOnly)
  assert app.add_relay(spec, "ws://listed.test", relay_list.MonitorOnly)
    == Error(admin.ConnectionsNotConfirmed)
  let assert Ok(rows_after) = relay_store.list(db, db.default_timeouts)
  assert list.map(rows_after, fn(row) { row.url })
    == ["ws://added.test", "ws://listed.test"]
}

/// `app.update_relay_roles` と `app.delete_relay` は DB に書いてから接続を変えるので、
/// 再起動なしで `registered_relays` と `relay_list` の両方に反映される。行を消した後は、
/// 同じ行への変更と削除がどちらも `UnregisteredRelay` になる。`TEST_DATABASE_URL` が
/// あるときだけ実行する。
pub fn update_and_delete_relay_write_the_row_then_the_connections_test() {
  use spec, _db <- with_relay_store_tree()

  let assert Ok(Nil) =
    app.add_relay(spec, "ws://update.test", relay_list.MonitorOnly)
  let assert Ok([relay]) = app.registered_relays(spec)
  assert relay.url == "ws://update.test"
  assert relay.roles == relay_list.MonitorOnly

  let assert Ok(Nil) =
    app.update_relay_roles(spec, relay, relay_list.BunkerOnly)
  let assert Ok([updated]) = app.registered_relays(spec)
  assert updated.roles == relay_list.BunkerOnly
  assert role_url_pairs(spec) == [#(relay_list.Bunker, "ws://update.test")]

  let assert Ok(Nil) = app.delete_relay(spec, updated)
  assert app.registered_relays(spec) == Ok([])
  assert role_url_pairs(spec) == []

  assert app.update_relay_roles(spec, updated, relay_list.Both)
    == Error(admin.UnregisteredRelay)
  assert app.delete_relay(spec, updated) == Error(admin.UnregisteredRelay)
}

/// `signer_key` を読み込むバンカーを載せた仕様。リレーは起動後に開く。
fn signer_spec(reports: Subject(Report)) -> app.Spec {
  app.Spec(
    ..base_spec(reports),
    bunker: bunker_spec(
      process.new_name("test_bunker"),
      signer_store(),
      fixed_retry_delay,
    ),
  )
}

/// `account_rows` は全行の署名者を 1 度 `pictures` へ渡し、引いた URL を行の `picture` に入れる。
pub fn account_rows_carry_the_looked_up_picture_test() {
  let reports = process.new_subject()
  let a = "ws://a.test"
  let b = "ws://b.test"
  let signer = account.pubkey_hex(account_for(signer_key))
  let spec = signer_spec(reports)
  let tree = start_tree_with_relays(spec, [a], [b])
  let asked = process.new_subject()
  let assert Ok([row]) =
    app.account_rows(spec, fn(signers) {
      process.send(asked, signers)
      dict.from_list([#(signer, "https://x.test/a.png")])
    })
  assert row.picture == Some("https://x.test/a.png")
  assert process.receive(asked, 100) == Ok([signer])
  stop_tree(tree)
}

/// `open_relay` / `change_relay_roles` / `close_relay` の直後、`relay_list` の
/// 一覧と `relay=` は一覧の順のまま反映される。
pub fn runtime_relay_changes_are_listed_in_order_test() {
  let reports = process.new_subject()
  let a = "ws://a.test"
  let b = "ws://b.test"
  let c = "ws://c.test"
  let signer = account.pubkey_hex(account_for(signer_key))
  let spec = signer_spec(reports)
  let tree = start_tree_with_relays(spec, [a], [b])
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, a),
      #(relay_list.Bunker, b),
    ]

  let assert Ok(Nil) = app.open_relay(spec, c, relay_list.Both)
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, a),
      #(relay_list.Monitor, c),
      #(relay_list.Bunker, b),
      #(relay_list.Bunker, c),
    ]

  let assert Ok(Nil) = app.change_relay_roles(spec, a, relay_list.BunkerOnly)
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, c),
      #(relay_list.Bunker, a),
      #(relay_list.Bunker, b),
      #(relay_list.Bunker, c),
    ]

  let assert Ok(Nil) = app.close_relay(spec, c)
  assert role_url_pairs(spec)
    == [
      #(relay_list.Bunker, a),
      #(relay_list.Bunker, b),
    ]

  let assert Ok(rows) = app.account_rows(spec, fn(_signers) { dict.new() })
  let assert [row] = rows
  assert row.uri == connection_uri.bunker_uri(signer, [a, b], Some(secret))
  assert row.auth_uri == connection_uri.bunker_uri(signer, [a, b], None)
  assert row.uri_camera_text
    == connection_uri.camera_copy_text(signer, [a, b], Some(secret))
  assert row.auth_uri_camera_text
    == connection_uri.camera_copy_text(signer, [a, b], None)
  stop_tree(tree)
}

/// バンカーのリレーを閉じると、送信手段がバンカーの送信先から外れて再起動も
/// されない。閉じていない側のリレーは応答を送り続ける。
pub fn a_closed_bunker_relay_is_unpublished_and_not_restarted_test() {
  let reports = process.new_subject()
  let x = "ws://x.test"
  let y = "ws://y.test"
  let spec =
    app.Spec(
      ..signer_spec(reports),
      // 再接続で送信手段が戻ってこないよう、テストより十分に長く取る。
      reconnect_delay: Backoff(initial_ms: 60_000, max_ms: 60_000),
    )
  let tree = start_tree_with_relays(spec, [], [x, y])
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(socket_y, deliver_y) = case first_url == x {
    True -> #(socket_2, deliver_2)
    False -> #(socket_1, deliver_1)
  }

  let x_name = connection_name(spec, x, relay_list.Bunker)
  let assert Ok(Nil) = app.close_relay(spec, x)
  assert process.named(x_name) == Error(Nil)
  // 300ms 待っても x は再起動されない（新しい `Opened` が届かない）。
  assert process.receive(reports, 300) == Error(Nil)
  assert process.named(x_name) == Error(Nil)

  deliver_y(connect_request("c1", secret))
  let assert Ok(Published(answered_on, _ack)) = process.receive(reports, 2000)
  assert answered_on == socket_y
  // 死んだ x の送信手段には送られないので、続く応答は来ない。
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// バンカーのリレーを実行時に足すと、バンカーアクターが再起動して
/// `connections` の factory ごと落ちても、`connections` の起動のたびに
/// `relay_list` へ送られる `Repopulate` が未登録の接続を起動し直す。
pub fn runtime_relays_are_reopened_when_the_bunker_restarts_test() {
  let reports = process.new_subject()
  let spec = signer_spec(reports)
  let tree = start_tree(spec)
  let assert Ok(Nil) =
    app.open_relay(spec, "ws://z.test", relay_list.BunkerOnly)
  let assert Opened("ws://z.test", _connection, _socket, _deliver) =
    await_connection(reports)

  let assert Ok(bunker_pid) = process.named(spec.bunker.name)
  process.kill(bunker_pid)
  let assert Opened("ws://z.test", _connection_2, _socket_2, _deliver_2) =
    await_connection(reports)
  stop_tree(tree)
}
