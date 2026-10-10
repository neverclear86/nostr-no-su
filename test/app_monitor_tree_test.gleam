//// 偽リレーの上のツリーで、監視の接続がイベントを選り分けてプラグインへ渡し、AUTH に
//// 応答しないことと、プラグイン（ランナー、プラグインの子）の障害がほかのプラグインと
//// 監視へ及ばず、落ちたものが作り直されることを確かめるテスト。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/admin
import nostr_no_su/app
import nostr_no_su/dedup
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin
import nostr_no_su/plugin_children
import nostr_no_su/plugin_runner
import support/app_tree.{
  type Report, Opened, authenticator_recording_open, await_connection,
  await_restart, base_spec, deliver_and_expect, event_labels, fake_open,
  forwarding_spec, idle_monitor, idle_plugin, note, plugin_spec,
  start_tree_with_relays, stop_tree, test_relay_url,
}
import support/erl.{is_registered, unique_integer}
import support/poll
import support/signed_event

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
  start_tree_with_relays(
    app.Spec(
      ..base_spec(process.new_subject()),
      plugins: [
        forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
      ],
      monitor: app.Monitor(
        ..idle_monitor(),
        name: name,
        excludes_kind: excludes_kind,
      ),
      open: open,
    ),
    [test_relay_url],
    [],
  )
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
fn crashing_spec(name: Name(plugin_runner.Msg)) -> app.PluginSpec {
  plugin_spec(
    name,
    plugin.Plugin(..idle_plugin("crashing"), handle: fn(_incoming) {
      panic as "boom"
    }),
  )
}

/// 決して戻らないプラグインの仕様。1 件目の実行が打ち切られるまでランナーは
/// 次のイベントを読まない。
fn hanging_spec(
  name: Name(plugin_runner.Msg),
  limits: plugin_runner.Limits,
) -> app.PluginSpec {
  app.PluginSpec(
    ..plugin_spec(
      name,
      plugin.Plugin(..idle_plugin("hanging"), handle: fn(_incoming) {
        process.sleep_forever()
      }),
    ),
    limits: limits,
  )
}

/// プラグインを載せた監視ツリー。イベントは偽リレー経由で流し込む。
fn start_plugins_tree(
  reports: Subject(Report),
  dedup_name: Name(dedup.Msg),
  plugins: List(app.PluginSpec),
) -> Pid {
  start_tree_with_relays(
    app.Spec(
      ..base_spec(reports),
      plugins: plugins,
      monitor: app.Monitor(
        ..idle_monitor(),
        name: dedup_name,
        dedup_capacity: 64,
      ),
    ),
    [test_relay_url],
    [],
  )
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
      crashing_spec(crashing),
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
    crashing_spec(crashing),
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
  assert app.reenable_plugin([], "missing") == Error(admin.PluginNotFound)
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
  assert await_restart(forwarding, killed, 2000)
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
  plugin_spec(
    name,
    plugin.Plugin(
      ..idle_plugin("counting"),
      children: children,
      handle: fn(_incoming) {
        store_bump(store)
        Nil
      },
    ),
  )
}

/// 登録名が使われる（あるいは解放される）まで待つ。
fn await_registered(store: Atom, registered: Bool, timeout_ms: Int) -> Bool {
  poll.until(fn() { is_registered(store) == registered }, timeout_ms, 10)
}

/// store が数えた件数が期待どおりになるまで待つ。
fn await_count(store: Atom, expected: Int, timeout_ms: Int) -> Bool {
  poll.until(
    fn() { is_registered(store) && store_count(store) == expected },
    timeout_ms,
    10,
  )
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
/// 消費しない。**`Temporary` を選んだ根拠（許容回数の超過以外の理由で落ちても
/// 再起動されない）の回帰テスト**（`docs/design-decisions.md` の「プラグインが申告した
/// 子プロセスは Temporary で載せる」を参照）。
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
fn await_restarted(store: Atom, previous: Dynamic, timeout_ms: Int) -> Bool {
  poll.until(
    fn() { is_registered(store) && whereis_name(store) != previous },
    timeout_ms,
    10,
  )
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
