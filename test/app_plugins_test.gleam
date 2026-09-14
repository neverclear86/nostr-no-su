//// 偽リレーの上のツリーで、監視の接続とリレーの増減、プラグイン（ランナー、
//// プラグインの子）の障害の分離を確かめるテスト。

import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/vault
import nostr_no_su/dedup
import nostr_no_su/hex
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/message
import nostr_no_su/plugin
import nostr_no_su/plugin_children
import nostr_no_su/plugin_runner
import nostr_no_su/random
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/time
import pog
import support/app_tree.{
  type Report, type SubscriptionReport, Opened, Published, Retrying, Subscribed,
  accounts_only, authenticator_recording_open, await_connection, bunker_spec,
  call_counter, connect_request, deliver_and_expect, discard_resume_points,
  drain_subscriptions, event_labels, fake_open, fixed_retry_delay,
  forwarding_spec, idle_monitor, load_signer, memory_store, monotonic_ms,
  named_relay, note, other_signer_key, receive_until, secret, signer_key,
  start_tree, stop_tree, store_failure, store_with_load, test_relay,
  test_relay_url,
}
import support/erl.{is_registered, unique_integer}
import support/nip46_client.{account_for}
import support/postgres
import support/signed_event

/// 実行時のリレーの増減のテストで、3 人目として追加する署名者の鍵。
const third_signer_key = "0000000000000000000000000000000000000000000000000000000000000099"

/// 監視とプラグインのテストのツリーに載せる、リレーを持たないバンカー。ツリーは常に
/// バンカーを含むので載せるが、テストはバンカーを使わない。リレーを持たせないのは、
/// バンカーの接続が同じ `reports` へ `Opened` を送り、監視の接続の報告と区別できなく
/// なるためである。
fn idle_bunker() -> app.Bunker {
  bunker_spec(
    process.new_name("test_bunker"),
    store_with_load(fn() { Ok(accounts_only([])) }),
    [],
    fixed_retry_delay,
  )
}

/// どのリレーにも `stored` を返す、再開点の読み込みの操作。
fn fixed_resume_point(
  stored: Result(Option(Int), String),
) -> fn(String) -> Result(Option(Int), String) {
  fn(_relay_url) { stored }
}

/// 偽リレー 1 本の上で監視だけを動かすツリー。受信したイベントは `seen` に
/// 転送するプラグインへ渡る。
fn start_monitor_tree(
  reports: Subject(Report),
  seen: Subject(Event),
  name: Name(dedup.Msg),
  excludes_kind: fn(Int) -> Bool,
) -> Pid {
  start_monitor_tree_with_open(
    seen,
    name,
    excludes_kind,
    fake_open(reports, None),
  )
}

/// `start_monitor_tree` から接続の開き方だけを差し替えられるようにした版。
/// AUTH の受け口など `fake_open` が捨てる引数を確かめるテストが使う。
fn start_monitor_tree_with_open(
  seen: Subject(Event),
  name: Name(dedup.Msg),
  excludes_kind: fn(Int) -> Bool,
  open: app.Open,
) -> Pid {
  start_tree(app.Spec(
    plugins: [forwarding_spec(process.new_name("test_plugin_forwarding"), seen)],
    monitor: app.Monitor(
      name: name,
      dedup_capacity: 8,
      relays: [test_relay()],
      subscriptions: fn(_relay_url) { fn() { Ok([]) } },
      save_resume: discard_resume_points,
      excludes_kind: excludes_kind,
    ),
    bunker: idle_bunker(),
    admin: None,
    open: open,
    reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    relay_list: process.new_name("test_relay_list"),
  ))
}

/// ephemeral イベント（kind 20000〜29999。バンカー自身の NIP-46 通信を含む）
/// は監視の対象外。同じ購読で届いても、プラグインには渡らず後続の非 ephemeral
/// イベントだけが渡る。
pub fn monitor_drops_ephemeral_events_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let tree =
    start_monitor_tree(
      reports,
      seen,
      process.new_name("test_dedup"),
      event.is_ephemeral,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let below_range = signed_event.new(19_999, "below-range")
  let above_range = signed_event.new(30_000, "above-range")
  deliver(signed_event.new(20_000, "lower-bound"))
  deliver(signed_event.new(event.nip46_kind, "nip46"))
  deliver(signed_event.new(29_999, "upper-bound"))
  deliver(below_range)
  deliver(above_range)
  // 送信順に処理されるため、ephemeral の 3 件がすべて落ちていれば範囲外の
  // 2 件だけがこの順で届く。
  assert process.receive(seen, 2000) == Ok(below_range)
  assert process.receive(seen, 2000) == Ok(above_range)
  stop_tree(tree)
}

/// `excludes_kind` は `Monitor` の仕様から渡した述語がそのまま効き、既定の
/// ephemeral 判定に固定されていない。
pub fn monitor_uses_configured_excluded_kinds_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let tree =
    start_monitor_tree(reports, seen, process.new_name("test_dedup"), fn(kind) {
      kind == 1
    })
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let nip46 = signed_event.new(event.nip46_kind, "nip46")
  deliver(note("dropped"))
  deliver(nip46)
  // kind 1 を落とす述語なので、kind 1 のイベントは届かず kind 24133 が届く。
  assert process.receive(seen, 2000) == Ok(nip46)
  stop_tree(tree)
}

/// 監視接続で受信したイベントはプラグインに届き、経由するディスパッチャーを kill
/// した後も届き続ける。
pub fn monitor_dispatcher_survives_being_killed_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let name = process.new_name("test_dedup")
  let tree = start_monitor_tree(reports, seen, name, event.is_ephemeral)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let first = note("first")
  deliver(first)
  assert process.receive(seen, 2000) == Ok(first)

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let second = note("second")
  deliver(second)
  assert process.receive(seen, 2000) == Ok(second)
  stop_tree(tree)
}

/// 常にクラッシュするプラグインの仕様。
fn crashing_spec(
  name: Name(plugin_runner.Msg),
  limits: plugin_runner.Limits,
) -> app.PluginSpec {
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(name: "crashing", children: [], handle: fn(_incoming) {
      panic as "boom"
    }),
    limits: limits,
  )
}

/// 決して戻らないプラグインの仕様。1 件目の実行が打ち切られるまでランナーは
/// 次のイベントを読まない。
fn hanging_spec(
  name: Name(plugin_runner.Msg),
  limits: plugin_runner.Limits,
) -> app.PluginSpec {
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(name: "hanging", children: [], handle: fn(_incoming) {
      process.sleep_forever()
    }),
    limits: limits,
  )
}

/// プラグインを載せた監視ツリー。イベントは偽リレー経由で流し込む。
fn start_plugins_tree(
  reports: Subject(Report),
  dedup_name: Name(dedup.Msg),
  plugins: List(app.PluginSpec),
) -> Pid {
  start_tree(app.Spec(
    plugins: plugins,
    monitor: app.Monitor(
      name: dedup_name,
      dedup_capacity: 64,
      relays: [test_relay()],
      subscriptions: fn(_relay_url) { fn() { Ok([]) } },
      save_resume: discard_resume_points,
      excludes_kind: event.is_ephemeral,
    ),
    bunker: idle_bunker(),
    admin: None,
    open: fake_open(reports, None),
    reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    relay_list: process.new_name("test_relay_list"),
  ))
}

/// 名前が新しいプロセスへ再登録されるのを待つ。`named.send` は名前が未登録の
/// あいだメッセージを捨てるため、再登録を待たずに配信すると取りこぼす。
fn await_restart(
  name: Name(plugin_runner.Msg),
  previous: Pid,
  remaining: Int,
) -> Pid {
  case process.named(name), remaining {
    Ok(pid), _ if pid != previous -> pid
    _, 0 -> panic as "the plugin runner was not restarted"
    _, _ -> {
      process.sleep(20)
      await_restart(name, previous, remaining - 1)
    }
  }
}

/// クラッシュし続けるプラグインは監視を巻き添えにしない。ランナーは死なないので
/// スーパーバイザーの再起動が起きず、無効化されるまで自分のプロセスの中で完結
/// する。ディスパッチャーも監視接続も他のプラグインも影響を受けない。
///
/// ワーカーが自分で例外を捕まえて短い理由で exit するため、**このテストでも
/// BEAM の `=ERROR REPORT=` は出ない**。代わりにランナーが 1 行ログ
/// （`handle_event failed (...); n/5`）を最大 5 行出す。
pub fn crashing_plugin_does_not_take_down_the_monitor_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let crashing = process.new_name("test_plugin_crashing")
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      crashing_spec(crashing, plugin_runner.default_limits),
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let assert Opened(_relay_url, connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(crashing)
  let assert Ok(dedup_before) = process.named(dedup_name)

  deliver_and_expect(deliver, seen, event_labels("crash", 20), 2000)

  // ランナーの pid が不変であることが、「スーパーバイザーの再起動が 1 度も
  // 起きていない」という主張そのものである。ワーカーとリンクを張る実装では
  // ここで pid が変わる。
  assert process.named(crashing) == Ok(runner_before)
  // 連続失敗が数え上がって無効化まで到達している。リンクを張る実装ではランナー
  // ごと再起動するため、状態は `Running` に戻ってしまう。
  let assert Some(plugin_runner.Disabled(..)) = plugin_runner.status(crashing)
  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  // 接続が張り直されていない（`rest_for_one` が発火していない）。
  assert process.receive(reports, 300) == Error(Nil)
  assert process.is_alive(tree)
  stop_tree(tree)
}

/// crashing と forwarding を載せたツリーを起動し、crashing を無効にする。呼び出し側が
/// 続きを検証できるよう、ツリー、仕様の一覧、配信関数、転送先、ランナーの名前と無効化
/// 前の pid を返す。
fn start_tree_with_a_disabled_plugin() -> #(
  Pid,
  List(app.PluginSpec),
  fn(Event) -> Nil,
  Subject(Event),
  Name(plugin_runner.Msg),
  Pid,
) {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let crashing = process.new_name("test_plugin_crashing")
  let specs = [
    crashing_spec(crashing, plugin_runner.default_limits),
    forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
  ]
  let tree = start_plugins_tree(reports, process.new_name("test_dedup"), specs)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(crashing)

  deliver_and_expect(deliver, seen, event_labels("crash", 20), 2000)
  let assert Some(plugin_runner.Disabled(..)) = plugin_runner.status(crashing)

  #(tree, specs, deliver, seen, crashing, runner_before)
}

/// 無効化されたプラグインがいても、他のプラグインにはイベントが届き続ける。
pub fn disabled_plugin_keeps_the_others_running_test() {
  let #(tree, _specs, deliver, seen, crashing, runner_before) =
    start_tree_with_a_disabled_plugin()

  deliver_and_expect(deliver, seen, event_labels("after", 5), 2000)
  assert process.named(crashing) == Ok(runner_before)
  stop_tree(tree)
}

/// 管理 UI の再有効化は名前でランナーを引き、無効化されたプラグインを
/// `Running` に戻す。ランナーのプロセスは不変である。
pub fn reenable_plugin_finds_the_runner_by_name_test() {
  let #(tree, specs, _deliver, _seen, crashing, runner_before) =
    start_tree_with_a_disabled_plugin()

  assert app.reenable_plugin(specs, "crashing") == Ok(Nil)
  assert plugin_runner.status(crashing) == Some(plugin_runner.Running)
  assert process.named(crashing) == Ok(runner_before)
  stop_tree(tree)
}

/// 名前に一致するプラグインが無ければ `PluginNotFound` を返す。
pub fn reenable_plugin_with_an_unknown_name_is_not_found_test() {
  assert app.reenable_plugin([], "missing")
    == Error(admin.PluginNotFound("plugin not found"))
}

/// 決して戻らないプラグインがいても、他のプラグインは待たされない。遅い側は
/// 自分のランナーの中で打ち切られる。
///
/// 打ち切りまでの時間（5000ms）は受信窓（1000ms）より意図的に長く取る。こうする
/// と、ランナーごとに打ち切りを同期で待つ実装ではこのテストが通らない。
pub fn slow_plugin_does_not_block_other_plugins_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      hanging_spec(
        process.new_name("test_plugin_hanging"),
        plugin_runner.Limits(
          handle_timeout_ms: 5000,
          max_queue_len: 1000,
          max_failures: 5,
        ),
      ),
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver_and_expect(deliver, seen, event_labels("slow", 3), 1000)
  stop_tree(tree)
}

/// ランナーを強制終了するとスーパーバイザーが作り直し、次のイベントから配信が
/// 再開する。安全網の確認であり、無効化されたプラグインを再有効化する唯一の
/// 運用手段の確認でもある。
pub fn plugin_runner_is_restarted_when_killed_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let forwarding = process.new_name("test_plugin_forwarding")
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      forwarding_spec(forwarding, seen),
    ])
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver_and_expect(deliver, seen, ["before"], 2000)

  let assert Ok(killed) = process.named(forwarding)
  process.kill(killed)
  let restarted = await_restart(forwarding, killed, 100)
  assert restarted != killed
  deliver_and_expect(deliver, seen, ["after"], 2000)
  stop_tree(tree)
}

/// 子仕様を持つプラグインのテストで使う一意な登録名。BEAM の登録名は VM 全体で
/// 共有なので、テストごとに作り直す。
fn unique_store() -> Atom {
  atom.create(
    "app_test_store_"
    <> int.to_string(unique_integer([atom.create("positive")])),
  )
}

/// fixture の子仕様を本番と同じ経路（`plugin_children.from_dynamic`）で変換する。
fn resolved_children(kinds: List(#(String, Atom))) -> List(Dynamic) {
  use pair <- list.map(kinds)
  child_spec_map(atom.create(pair.0), pair.1)
}

/// 子仕様を申告し、イベントごとに store を 1 つ数え上げるプラグインの仕様。
/// **`!` で送るのは、store が居ないことをランナーに失敗として観測させるため。**
/// `gen_server:cast` 相当だと宛先が居なくても成功し、障害が黙って消える。
fn counting_spec(
  name: Name(plugin_runner.Msg),
  store: Atom,
  kinds: List(#(String, Atom)),
) -> app.PluginSpec {
  let assert Ok(children) =
    plugin_children.from_dynamic(
      dynamic.list(resolved_children(kinds)),
      "counting",
      0,
    )
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(
      name: "counting",
      children: children,
      handle: fn(_incoming) {
        store_bump(store)
        Nil
      },
    ),
    limits: plugin_runner.default_limits,
  )
}

/// 登録名が使われる（あるいは解放される）まで待つ。
fn await_registered(store: Atom, registered: Bool, remaining: Int) -> Bool {
  case is_registered(store) == registered, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_registered(store, registered, remaining - 10)
    }
  }
}

/// store が数えた件数が期待どおりになるまで待つ。
fn await_count(store: Atom, expected: Int, remaining: Int) -> Bool {
  case is_registered(store) && store_count(store) == expected, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_count(store, expected, remaining - 10)
    }
  }
}

/// 子仕様を申告したプラグインの子はツリーに載り、`handle_event/1` から名前で
/// 到達できる。状態は呼び出しをまたいで残る。
pub fn stateful_plugin_children_run_in_the_tree_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      counting_spec(process.new_name("test_plugin_counting"), store, [
        #("store", store),
      ]),
    ])
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert is_registered(store)

  list.each(event_labels("counted", 3), fn(label) { deliver(note(label)) })
  assert await_count(store, 3, 2000)
  stop_tree(tree)
}

/// 子を kill すると専用のスーパーバイザーが作り直し、プラグインは同じ名前で
/// 到達し続ける。作り直された子は状態を失うので 0 から数え直す。監視サブツリーは
/// 巻き添えにならない。
pub fn killed_plugin_child_is_restarted_and_the_plugin_recovers_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      counting_spec(process.new_name("test_plugin_counting"), store, [
        #("store", store),
      ]),
    ])
  let assert Opened(_relay_url, connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(dedup_before) = process.named(dedup_name)
  let before = whereis_name(store)

  kill_registered(store)
  assert await_restarted(store, before, 2000)
  deliver(note("after_kill"))
  assert await_count(store, 1, 2000)

  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  // 監視接続が張り直されていない（`rest_for_one` が発火していない）。
  assert process.receive(reports, 300) == Error(Nil)
  assert process.is_alive(tree)
  stop_tree(tree)
}

/// クラッシュループする子はプラグイン専用のスーパーバイザーの中で完結する。
/// 許容回数を超えると**そのプラグインの子だけ**がまとめて諦められ、親は再起動も
/// 許容回数の消費もしない。ランナーは生き続け、宛先を失った `handle_event/1` が
/// 連続失敗して `disabled` になる。他のプラグインと監視は影響を受けない。
///
/// このテストは BEAM の `=CRASH REPORT=` / `=SUPERVISOR REPORT=` を出す。
/// **検証したい振る舞いそのもの**なので抑制しない。
pub fn crash_looping_plugin_child_does_not_take_down_the_app_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let store = unique_store()
  let counting = process.new_name("test_plugin_counting")
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      counting_spec(counting, store, [
        #("store", store),
        #("flaky", unique_store()),
      ]),
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let assert Opened(_relay_url, connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(counting)
  let assert Ok(dedup_before) = process.named(dedup_name)

  // 専用のスーパーバイザーが諦めると、store も一緒に落ちて名前が解放される。
  assert await_registered(store, False, 5000)
  assert process.is_alive(tree)
  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  assert process.named(counting) == Ok(runner_before)

  // 宛先を失ったプラグインは連続失敗で無効化され、他のプラグインには届き続ける。
  deliver_and_expect(deliver, seen, event_labels("orphan", 5), 2000)
  let assert Some(plugin_runner.Disabled(..)) = plugin_runner.status(counting)
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// プラグイン専用のスーパーバイザーを外から繰り返し強制終了しても、親は再起動を
/// 消費しない。**`Temporary` を選んだ根拠 (b) の回帰テスト**（`app.gleam` 冒頭の
/// doc を参照）。
///
/// Temporary の子は決して再起動されないので、1 度目の kill でその子仕様ごと消え、
/// 以後は kill する対象すら残らない。`Transient` にすると kill のたびに再起動が
/// 起き、その再起動が `plugins`（5/10）の許容回数を消費して、やがてサブツリーが
/// 落ちてランナーが作り直される。下の「ランナーの pid が不変」がその差を捉える。
pub fn killed_plugin_children_supervisor_is_not_restarted_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let counting = process.new_name("test_plugin_counting")
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      counting_spec(counting, store, [#("store", store)]),
    ])
  let assert Opened(_relay_url, connection, _socket, _deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(counting)
  let assert Ok(dedup_before) = process.named(dedup_name)

  kill_children_supervisor(store, 8)

  assert process.is_alive(tree)
  assert process.named(counting) == Ok(runner_before)
  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  // 監視接続が張り直されていない（サブツリーが再起動していない）。
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// store のスーパーバイザーを、生きているあいだ繰り返し強制終了する。Temporary
/// なら 1 度目で対象が消えるので、残りの回は空振りして待つだけになる。
fn kill_children_supervisor(store: Atom, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      case is_registered(store) {
        True -> process.kill(supervisor_of(store))
        False -> Nil
      }
      process.sleep(20)
      kill_children_supervisor(store, remaining - 1)
    }
  }
}

/// 子の起動に失敗してもアプリの起動は止まらない。理由は 1 行ログに出て、
/// プラグインは子なしで動き続ける（ダッシュボードにも出る）。
pub fn plugin_children_that_fail_to_start_do_not_stop_the_tree_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let counting = process.new_name("test_plugin_counting")
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      counting_spec(counting, store, [#("failing", store)]),
    ])
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert process.is_alive(tree)
  let assert Ok(_runner) = process.named(counting)
  let assert Some(plugin_runner.Running) = plugin_runner.status(counting)
  stop_tree(tree)
}

/// 登録名が別のプロセスに付け替わるまで待つ。
fn await_restarted(store: Atom, previous: Dynamic, remaining: Int) -> Bool {
  case is_registered(store) && whereis_name(store) != previous, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_restarted(store, previous, remaining - 10)
    }
  }
}

/// 検証を通る子仕様。
@external(erlang, "child_fixture", "spec")
fn child_spec_map(kind: Atom, name: Atom) -> Dynamic

/// 登録名が指すプロセス（未登録なら atom の `undefined`）。
@external(erlang, "child_fixture", "whereis_name")
fn whereis_name(name: Atom) -> Dynamic

/// store の現在の件数。宛先が居なければ落ちる。
@external(erlang, "child_fixture", "count")
fn store_count(name: Atom) -> Int

/// store を 1 つ数え上げる。宛先が居なければ落ちる。
@external(erlang, "child_fixture", "bump")
fn store_bump(name: Atom) -> Dynamic

/// store を監視しているプラグイン専用のスーパーバイザー。
@external(erlang, "child_fixture", "supervisor_of")
fn supervisor_of(name: Atom) -> Pid

/// 登録名が指すプロセスを強制終了する。
@external(erlang, "child_fixture", "kill_registered")
fn kill_registered(name: Atom) -> Nil

// --- 監視の購読 ---

/// バンカーにリレーを持たせず、監視だけがリレー接続を持つツリー。購読は本番と
/// 同じ `nostr_no_su.monitor_subscriptions` から組み立てる。バンカーにリレーを
/// 持たせないのは、購読の報告（`subscribed`）がすべて監視の接続のものになる
/// ようにするためである。
fn monitored_accounts_spec(
  reports: Subject(Report),
  subscribed: Subject(SubscriptionReport),
  bunker_name: Name(bunker.Msg),
  store: bunker.Store,
  relays: List(relay_list.Connection),
  load_resume: fn(String) -> Result(Option(Int), String),
) -> app.Spec {
  let dedup_name = process.new_name("test_dedup")
  app.Spec(
    plugins: [],
    monitor: app.Monitor(
      name: dedup_name,
      dedup_capacity: 64,
      relays: relays,
      subscriptions: nostr_no_su.monitor_subscriptions(
        bunker_name,
        dedup_name,
        load_resume,
        _,
      ),
      save_resume: discard_resume_points,
      excludes_kind: event.is_ephemeral,
    ),
    bunker: bunker_spec(bunker_name, store, [], fixed_retry_delay),
    admin: None,
    open: fake_open(reports, Some(subscribed)),
    reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    relay_list: process.new_name("test_relay_list"),
  )
}

/// 報告が、指定したリレーの接続の REQ 1 件か。
fn requests_on(report: SubscriptionReport, relay_url: String) -> Bool {
  case report {
    Subscribed(url, [message.Req(..)]) -> url == relay_url
    _ -> False
  }
}

/// 起動直後の監視の購読は、読み込みに時間がかかっても読み込み済みの署名者を含み、
/// 読み込みの成功による張り直しで同じ内容の REQ が 1 回余計に送られる（決定 11）。
pub fn the_first_monitor_subscription_includes_the_loaded_signers_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_tree(monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() {
        // 読み込みが接続の最初の評価より遅れて終わることを模す。
        process.sleep(300)
        load_signer(signer_key)
      }),
      [test_relay()],
      fixed_resume_point(Ok(Some(1234))),
    ))
  let assert Ok(Subscribed(_relay_url, [message.Req("nostr-no-su", filter)])) =
    process.receive(subscribed, 2000)
  assert filter.authors == Some([signer])
  assert filter.since == Some(1234)

  let #(_skipped, second) =
    receive_until(subscribed, requests_on(_, test_relay_url), 2000)
  assert second
    == Ok(Subscribed(test_relay_url, [message.Req("nostr-no-su", filter)]))
  stop_tree(tree)
}

/// 監視の購読は、登録アカウントの追加・削除に合わせて張り直される。追加の時刻は
/// 追加の呼び出しの前後の現在時刻の範囲に収まり、以後の張り直しでも遡らない。
pub fn the_monitor_subscription_follows_account_changes_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let other_signer = account.pubkey_hex(account_for(other_signer_key))
  let spec =
    monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      memory_store(calls, [], False),
      [test_relay()],
      fixed_resume_point(Ok(None)),
    )
  let tree = start_tree(spec)
  assert process.receive(subscribed, 2000) == Ok(Subscribed(test_relay_url, []))

  let before_first_add = time.now_seconds()
  assert app.add_account(spec, account_for(signer_key), "main") == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, first_filter)])) =
    process.receive(subscribed, 2000)
  assert first_filter.authors == Some([signer])
  let assert Some(since_after_first_add) = first_filter.since
  assert since_after_first_add >= before_first_add
  assert since_after_first_add <= time.now_seconds()

  assert app.add_account(spec, account_for(other_signer_key), "second")
    == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, second_filter)])) =
    process.receive(subscribed, 2000)
  assert second_filter.authors
    == Some(list.sort([signer, other_signer], string.compare))
  let assert Some(since_after_second_add) = second_filter.since
  assert since_after_second_add >= since_after_first_add

  assert bunker.remove_account(bunker_name, other_signer) == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, third_filter)])) =
    process.receive(subscribed, 2000)
  assert third_filter.authors == Some([signer])
  assert third_filter.since == Some(since_after_second_add)

  assert bunker.remove_account(bunker_name, signer) == Ok(Nil)
  assert process.receive(subscribed, 2000)
    == Ok(Subscribed(test_relay_url, [message.Close("nostr-no-su")]))
  stop_tree(tree)
}

/// 再接続したリレーは、切断前にそのリレーで受け取った最新イベントの `created_at`
/// から購読し直す。イベントを受け取っていないリレーは保存済みの再開点（無ければ
/// `None`）から購読する。
pub fn a_reconnected_monitor_relay_resumes_from_its_latest_event_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let first = named_relay("ws://first.test")
  let second = named_relay("ws://second.test")
  let tree =
    start_tree(monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() { load_signer(signer_key) }),
      [first, second],
      fixed_resume_point(Ok(None)),
    ))
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(first_socket, second_socket, deliver_first) = case
    first_url == first.url
  {
    True -> #(socket_1, socket_2, deliver_1)
    False -> #(socket_2, socket_1, deliver_2)
  }
  // 接続直後の評価（起動時の読み込みによる張り直しの分を含む、決定 11）を
  // 読み捨ててから、切断後の張り直しだけを見る。
  drain_subscriptions(subscribed, 300)

  let received = note("received")
  deliver_first(received)

  process.kill(first_socket)
  let #(_skipped, first_requested) =
    receive_until(subscribed, requests_on(_, first.url), 2000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, first_after_kill)])) =
    first_requested
  assert first_after_kill.since == Some(received.created_at)

  process.kill(second_socket)
  let #(_skipped, second_requested) =
    receive_until(subscribed, requests_on(_, second.url), 2000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, second_after_kill)])) =
    second_requested
  assert second_after_kill.since == None
  stop_tree(tree)
}

/// 再開点を読めない間は、監視の購読を張らずに再試行を続ける（開いている購読を
/// 閉じない）。
pub fn an_unreadable_resume_point_keeps_the_monitor_relay_unsubscribed_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let tree =
    start_tree(monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() { load_signer(signer_key) }),
      [test_relay()],
      fixed_resume_point(Error("unavailable")),
    ))
  let assert Ok(first) = process.receive(subscribed, 2000)
  assert first == Retrying(test_relay_url)
  assert_never_requests(subscribed, monotonic_ms() + 500)
  stop_tree(tree)
}

/// `deadline`（`monotonic_ms` の単位）まで、`subscribed` に届く報告が `Retrying` か
/// 空の `Subscribed` だけであることを検査する。
fn assert_never_requests(
  subscribed: Subject(SubscriptionReport),
  deadline: Int,
) -> Nil {
  case process.receive(subscribed, int.max(deadline - monotonic_ms(), 0)) {
    Error(Nil) -> Nil
    Ok(report) -> {
      assert report == Retrying(test_relay_url)
        || report == Subscribed(test_relay_url, [])
      assert_never_requests(subscribed, deadline)
    }
  }
}

// --- 登録されたリレー ---

/// 仕様の `relays: []` の Bunker でも、最初の読み込みで届いた `Snapshot.relays`
/// から接続が開く。
pub fn registered_relays_open_after_the_first_load_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let url = "ws://registered.test"
  let store =
    store_with_load(fn() {
      use snapshot <- result.try(load_signer(signer_key))
      Ok(
        bunker.Snapshot(..snapshot, relays: [
          relay_list.Registered(
            url: url,
            roles: relay_list.Roles(monitor: False, bunker: True),
          ),
        ]),
      )
    })
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(name, store, [], fixed_retry_delay),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
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
        _ -> {
          use snapshot <- result.try(load_signer(signer_key))
          Ok(
            bunker.Snapshot(..snapshot, relays: [
              relay_list.Registered(
                url: url,
                roles: relay_list.Roles(monitor: False, bunker: True),
              ),
            ]),
          )
        }
      }
    })
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(
        name,
        store,
        [],
        Backoff(initial_ms: 300, max_ms: 300),
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
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
/// 用途を使っていて接続があれば `status` の結果を、無ければ未接続を、用途を
/// 使っていなければ `None` を返す。
pub fn merged_relay_rows_follow_the_store_test() {
  let monitor_a = process.new_name("test_merge_monitor_a")
  let bunker_a = process.new_name("test_merge_bunker_a")
  let relays = [
    relay_store.Relay(
      id: 1,
      url: "wss://a",
      roles: relay_list.Roles(monitor: True, bunker: True),
    ),
    relay_store.Relay(
      id: 2,
      url: "wss://b",
      roles: relay_list.Roles(monitor: True, bunker: False),
    ),
    relay_store.Relay(
      id: 3,
      url: "wss://c",
      roles: relay_list.Roles(monitor: False, bunker: True),
    ),
  ]
  let entries = [
    relay_list.Entry(
      url: "wss://a",
      monitor: Some(monitor_a),
      bunker: Some(bunker_a),
    ),
    relay_list.Entry(
      url: "wss://only-in-relay-list",
      monitor: Some(process.new_name("test_merge_extra")),
      bunker: None,
    ),
  ]
  let status = fn(name) {
    case name == monitor_a, name == bunker_a {
      True, _ -> relay_connection.Connected
      _, True -> relay_connection.Disconnected
      _, _ -> panic as "unexpected name"
    }
  }
  assert app.merge_relay_rows(relays, entries, status)
    == [
      dashboard.RelayRow(
        id: 1,
        url: "wss://a",
        monitor: Some(relay_connection.Connected),
        bunker: Some(relay_connection.Disconnected),
      ),
      dashboard.RelayRow(
        id: 2,
        url: "wss://b",
        monitor: Some(relay_connection.Disconnected),
        bunker: None,
      ),
      dashboard.RelayRow(
        id: 3,
        url: "wss://c",
        monitor: None,
        bunker: Some(relay_connection.Disconnected),
      ),
    ]
}

/// `relay_list` が応答しなければ、DB を読まずにその理由を返す。
pub fn relay_rows_without_the_relay_list_test() {
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: idle_bunker(),
      admin: None,
      open: fake_open(process.new_subject(), None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list_unanswered"),
    )
  assert app.relay_rows(spec) == Error("relay list did not answer")
}

/// 監視のリレー 0 本の木で `open_relay` を呼ぶと、後から足したリレーで受信した
/// イベントもプラグインに届く。
pub fn a_monitor_relay_opened_at_runtime_delivers_events_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let spec =
    app.Spec(
      plugins: [
        forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
      ],
      monitor: idle_monitor(),
      bunker: idle_bunker(),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Ok(Nil) =
    app.open_relay(
      spec,
      test_relay_url,
      relay_list.Roles(monitor: True, bunker: False),
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver_and_expect(deliver, seen, event_labels("runtime", 3), 2000)
  stop_tree(tree)
}

/// `app.add_relay` は DB に挿入してから接続を開く。同じ URL の 2 回目は
/// `DuplicateRelay`、`relay_list` にすでにある URL への追加は `ConnectionsNotConfirmed`
/// になるが、どちらも先に挿入は確かめる。`TEST_DATABASE_URL` があるときだけ実行する
/// （CI では未設定なら失敗する）。
pub fn add_relay_saves_the_row_before_opening_test() {
  use database_url <- postgres.with_test_database_url("app")
  let schema = "app_relay_schema_" <> random.hex(8)
  let admin_db = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin_db, "CREATE SCHEMA " <> schema)

  // 移行を実行する。
  let assert Ok(_loaded) =
    account_store.load(
      postgres.start_pool(database_url, Some(schema)),
      random_master_key(),
      account_store.default_timeouts,
    )

  let assert Ok(config) =
    pog.url_config(process.new_name("test_app_relay_pool"), database_url)
  let config = pog.connection_parameter(config, "search_path", schema)
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: app.Bunker(..idle_bunker(), pool: config),
      admin: None,
      open: fake_open(process.new_subject(), None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_app_relay_add"),
    )
  let tree = start_tree(spec)
  let db = pog.named_connection(config.pool_name)

  let assert Ok(Nil) =
    app.add_relay(
      spec,
      "ws://added.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
  assert role_url_pairs(spec) == [#(relay_list.Monitor, "ws://added.test")]
  let assert Ok(rows) = relay_store.list(db, account_store.default_timeouts)
  assert list.map(rows, fn(row) { row.url }) == ["ws://added.test"]

  assert app.add_relay(
      spec,
      "ws://added.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
    == Error(admin.DuplicateRelay)

  let assert Ok(Nil) =
    app.open_relay(
      spec,
      "ws://listed.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
  assert app.add_relay(
      spec,
      "ws://listed.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
    == Error(admin.ConnectionsNotConfirmed)
  let assert Ok(rows_after) =
    relay_store.list(db, account_store.default_timeouts)
  assert list.map(rows_after, fn(row) { row.url })
    == ["ws://added.test", "ws://listed.test"]

  stop_tree(tree)
  postgres.run_statement(admin_db, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// `app.update_relay_roles` と `app.delete_relay` は DB に書いてから接続を変えるので、
/// 再起動なしで `registered_relays` と `relay_list` の両方に反映される。行を消した後は、
/// 同じ行への変更と削除がどちらも `UnregisteredRelay` になる。`TEST_DATABASE_URL` が
/// あるときだけ実行する（CI では未設定なら失敗する）。
pub fn update_and_delete_relay_write_the_row_then_the_connections_test() {
  use database_url <- postgres.with_test_database_url("app")
  let schema = "app_relay_update_schema_" <> random.hex(8)
  let admin_db = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin_db, "CREATE SCHEMA " <> schema)

  let assert Ok(_loaded) =
    account_store.load(
      postgres.start_pool(database_url, Some(schema)),
      random_master_key(),
      account_store.default_timeouts,
    )

  let assert Ok(config) =
    pog.url_config(process.new_name("test_app_relay_update_pool"), database_url)
  let config = pog.connection_parameter(config, "search_path", schema)
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: app.Bunker(..idle_bunker(), pool: config),
      admin: None,
      open: fake_open(process.new_subject(), None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_app_relay_update"),
    )
  let tree = start_tree(spec)

  let assert Ok(Nil) =
    app.add_relay(
      spec,
      "ws://update.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
  let assert Ok([relay]) = app.registered_relays(spec)
  assert relay.url == "ws://update.test"
  assert relay.roles == relay_list.Roles(monitor: True, bunker: False)

  let assert Ok(Nil) =
    app.update_relay_roles(
      spec,
      relay,
      relay_list.Roles(monitor: False, bunker: True),
    )
  let assert Ok([updated]) = app.registered_relays(spec)
  assert updated.roles == relay_list.Roles(monitor: False, bunker: True)
  assert role_url_pairs(spec) == [#(relay_list.Bunker, "ws://update.test")]

  let assert Ok(Nil) = app.delete_relay(spec, updated)
  assert app.registered_relays(spec) == Ok([])
  assert role_url_pairs(spec) == []

  assert app.update_relay_roles(
      spec,
      updated,
      relay_list.Roles(monitor: True, bunker: True),
    )
    == Error(admin.UnregisteredRelay)
  assert app.delete_relay(spec, updated) == Error(admin.UnregisteredRelay)

  stop_tree(tree)
  postgres.run_statement(admin_db, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// 乱数のマスターキー。実行のたびに違う鍵を使う。
fn random_master_key() -> vault.MasterKey {
  let assert Ok(key) =
    vault.master_key_from_hex(hex.encode(crypto.strong_random_bytes(32)))
  key
}

/// `open_relay` / `change_relay_roles` / `close_relay` の直後、`relay_list` の
/// 一覧と `relay=` は一覧の順のまま反映される。
pub fn runtime_relay_changes_are_listed_in_order_test() {
  let reports = process.new_subject()
  let a = "ws://a.test"
  let b = "ws://b.test"
  let c = "ws://c.test"
  let signer = account.pubkey_hex(account_for(signer_key))
  let spec =
    app.Spec(
      plugins: [],
      monitor: app.Monitor(
        name: process.new_name("test_dedup"),
        dedup_capacity: 8,
        relays: [named_relay(a)],
        subscriptions: fn(_relay_url) { fn() { Ok([]) } },
        save_resume: discard_resume_points,
        excludes_kind: event.is_ephemeral,
      ),
      bunker: bunker_spec(
        process.new_name("test_bunker"),
        store_with_load(fn() { load_signer(signer_key) }),
        [named_relay(b)],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, a),
      #(relay_list.Bunker, b),
    ]

  let assert Ok(Nil) =
    app.open_relay(spec, c, relay_list.Roles(monitor: True, bunker: True))
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, a),
      #(relay_list.Monitor, c),
      #(relay_list.Bunker, b),
      #(relay_list.Bunker, c),
    ]

  let assert Ok(Nil) =
    app.change_relay_roles(
      spec,
      a,
      relay_list.Roles(monitor: False, bunker: True),
    )
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

  let assert Ok(rows) = app.account_rows(spec)
  let assert [row] = rows
  assert row.uri == account.bunker_uri(signer, [a, b], Some(secret))
  stop_tree(tree)
}

/// バンカーのリレーを閉じると、送信手段がバンカーの送信先から外れて再起動も
/// されない。閉じていない側のリレーは応答を送り続ける。
pub fn a_closed_bunker_relay_is_unpublished_and_not_restarted_test() {
  let reports = process.new_subject()
  let x = named_relay("ws://x.test")
  let y = named_relay("ws://y.test")
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(
        process.new_name("test_bunker"),
        store_with_load(fn() { load_signer(signer_key) }),
        [x, y],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      // 再接続で送信手段が戻ってこないよう、テストより十分に長く取る。
      reconnect_delay: Backoff(initial_ms: 60_000, max_ms: 60_000),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(socket_y, deliver_y) = case first_url == x.url {
    True -> #(socket_2, deliver_2)
    False -> #(socket_1, deliver_1)
  }

  let assert Ok(Nil) = app.close_relay(spec, x.url)
  assert process.named(x.name) == Error(Nil)
  // 300ms 待っても x は再起動されない（新しい `Opened` が届かない）。
  assert process.receive(reports, 300) == Error(Nil)
  assert process.named(x.name) == Error(Nil)

  deliver_y(connect_request("c1", secret))
  let assert Ok(Published(answered_on, _ack)) = process.receive(reports, 2000)
  assert answered_on == socket_y
  // 死んだ x の送信手段には送られないので、続く応答は来ない。
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// 実行時に足した監視のリレーは、アカウントの変更に合わせて購読が張り直され、
/// アカウントの追加の再開点の対象になる。閉じたリレーは対象から外れる。
pub fn a_runtime_monitor_relay_follows_account_changes_and_resume_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let other_signer = account.pubkey_hex(account_for(other_signer_key))
  let spec =
    monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() { load_signer(signer_key) }),
      [],
      fixed_resume_point(Ok(None)),
    )
  let tree = start_tree(spec)
  let r = "ws://runtime-monitor.test"
  let assert Ok(Nil) =
    app.open_relay(spec, r, relay_list.Roles(monitor: True, bunker: False))
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, opened_filter)])) =
    receive_until(subscribed, requests_on(_, r), 2000).1
  assert opened_filter.authors == Some([signer])

  assert app.add_account(spec, account_for(other_signer_key), "second")
    == Ok(Nil)
  // 張り直しの評価は、変更前の一覧を含む古い内容が 1 回余計に届きうる
  // （読み込みの成功による張り直しで同じ内容の REQ が 1 回余計に送られるのと
  // 同じ理由である）。両方揃った内容が届くまで読み飛ばす。
  let both_signers = Some(list.sort([signer, other_signer], string.compare))
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, added_filter)])) =
    receive_until(
      subscribed,
      fn(report) {
        case report {
          Subscribed(url, [message.Req(_, filter)]) ->
            url == r && filter.authors == both_signers
          _ -> False
        }
      },
      2000,
    ).1
  assert added_filter.authors == both_signers
  let assert Ok(Some(_)) = dedup.since(spec.monitor.name, r)

  let assert Ok(Nil) = app.close_relay(spec, r)
  assert bunker.remove_account(bunker_name, other_signer) == Ok(Nil)
  // r は閉じられているので、以降のアカウントの変更で REQ は届かない。
  assert process.receive(subscribed, 300) == Error(Nil)

  let r2 = "ws://runtime-monitor-2.test"
  let assert Ok(Nil) =
    app.open_relay(spec, r2, relay_list.Roles(monitor: True, bunker: False))
  let assert Ok(Nil) = app.close_relay(spec, r2)
  assert app.add_account(spec, account_for(third_signer_key), "third")
    == Ok(Nil)
  // r2 は、監視の一覧に居た間に一度もアカウントの追加を知らされていない。
  assert dedup.since(spec.monitor.name, r2) == Ok(None)
  stop_tree(tree)
}

/// バンカーのリレーを実行時に足すと、バンカーアクターが再起動して
/// `connections` の factory ごと落ちても、`connections` の起動のたびに
/// `relay_list` へ送られる `Repopulate` が未登録の接続を起動し直す。
pub fn runtime_relays_are_reopened_when_the_bunker_restarts_test() {
  let reports = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(
        bunker_name,
        store_with_load(fn() { load_signer(signer_key) }),
        [],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Ok(Nil) =
    app.open_relay(
      spec,
      "ws://z.test",
      relay_list.Roles(monitor: False, bunker: True),
    )
  let assert Opened("ws://z.test", _connection, _socket, _deliver) =
    await_connection(reports)

  let assert Ok(bunker_pid) = process.named(bunker_name)
  process.kill(bunker_pid)
  let assert Opened("ws://z.test", _connection_2, _socket_2, _deliver_2) =
    await_connection(reports)
  stop_tree(tree)
}

/// 監視の接続は AUTH の受け口を受けない。
pub fn monitor_connections_do_not_answer_authentication_test() {
  let reports = process.new_subject()
  let authenticators = process.new_subject()
  let tree =
    start_monitor_tree_with_open(
      process.new_subject(),
      process.new_name("test_dedup"),
      event.is_ephemeral,
      authenticator_recording_open(reports, authenticators),
    )
  let assert Ok(#(relay_url, None)) = process.receive(authenticators, 2000)
  assert relay_url == test_relay_url
  stop_tree(tree)
}
