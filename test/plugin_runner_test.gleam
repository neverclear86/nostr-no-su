import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Monitor, type Name, type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin
import nostr_no_su/plugin_runner.{
  Completed, Disabled, Failed, Limits, Overloaded, Running,
}

/// 遷移の検証に使う歯止め。実時間に依存しないよう小さく取る。
const limits = Limits(handle_timeout_ms: 50, max_queue_len: 10, max_failures: 3)

/// 配信するイベント。ランナーは中身を見ずにプラグインへ渡すだけなので最小限。
fn test_event() -> Event {
  Event(
    id: "e1",
    pubkey: "",
    created_at: 0,
    kind: 1,
    tags: [],
    content: "",
    sig: "",
  )
}

/// 指定した `handle` を持つプラグインのランナーを起動する。名前を返すので、
/// 呼び出し側は状態を問い合わせられる。
fn start_runner(
  handle: fn(Event) -> Nil,
  limits: plugin_runner.Limits,
) -> Name(plugin_runner.Msg) {
  let name = process.new_name("test_plugin_runner")
  let assert Ok(_started) =
    plugin_runner.start(
      name,
      plugin.Plugin(name: "runner_test", children: [], handle: handle),
      limits,
    )
  name
}

/// イベントを指定した件数だけランナーへ送る。
fn deliver(name: Name(plugin_runner.Msg), count: Int) -> Nil {
  use _unit <- list.each(list.repeat(Nil, count))
  plugin_runner.dispatch([name], test_event())
}

/// `handle_event/1` を監視付きの使い捨てプロセスで動かす FFI。`plugin_runner` の
/// 内部と同じものを、スタックトレースの整形を直接見るために呼ぶ。
@external(erlang, "nostr_no_su_ffi", "run_isolated")
fn run_isolated(run: fn() -> Nil) -> #(Pid, Monitor)

/// 異常終了の理由を、1 行の理由と（あれば）スタックトレースに分ける FFI。
@external(erlang, "nostr_no_su_ffi", "describe_exit")
fn describe_exit(reason: Dynamic) -> #(String, Option(String))

/// 存在しないモジュールへの `erlang:apply/3`。本体が `handle_event/1` を呼ぶのと
/// 同じ形で、`undef` を起こす。
@external(erlang, "erlang", "apply")
fn apply(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic

/// `erlang:error/1` をそのまま呼ぶ。Gleam の `panic` は理由そのものに `file` と
/// `line` を含むため、終了理由の短さを見る回帰テストには使えない。
@external(erlang, "erlang", "error")
fn erlang_error(reason: Atom) -> a

/// キューが上限以下なら実行する。
pub fn admit_runs_while_the_queue_is_short_test() {
  assert plugin_runner.admit(Running, 10, limits) == #(Running, True, None)
}

/// キューが上限を超えたら切り捨てに移り、1 行報告する。
pub fn admit_sheds_when_the_queue_grows_test() {
  let #(status, should_run, note) = plugin_runner.admit(Running, 11, limits)
  assert status == Overloaded(dropped: 1)
  assert should_run == False
  let assert Some(line) = note
  assert line
    == "too slow: 11 events queued (limit 10); dropping until it catches up"
}

/// キューが残っている間は捨て続け、件数を数える。
pub fn admit_keeps_shedding_until_the_queue_drains_test() {
  assert plugin_runner.admit(Overloaded(dropped: 4), 1, limits)
    == #(Overloaded(dropped: 5), False, None)
}

/// キューが空になったら配信を再開し、捨てた件数を報告する。
pub fn admit_resumes_on_an_empty_queue_test() {
  let #(status, should_run, note) =
    plugin_runner.admit(Overloaded(dropped: 7), 0, limits)
  assert status == Running
  assert should_run == True
  assert note == Some("caught up; dropped 7 events while overloaded")
}

/// 無効化されている間は実行せず、捨てた件数だけを数える。
pub fn admit_drops_while_disabled_test() {
  assert plugin_runner.admit(
      Disabled(reason: "error:badarg", dropped: 2),
      0,
      limits,
    )
    == #(Disabled(reason: "error:badarg", dropped: 3), False, None)
}

/// 成功したら連続失敗数は 0 に戻り、状態も報告も変わらない。
pub fn record_resets_failures_on_success_test() {
  assert plugin_runner.record(Running, 2, Completed, limits)
    == #(Running, 0, None)
}

/// 連続失敗が上限に達したら無効化し、理由を添えて報告する。
pub fn record_disables_after_consecutive_failures_test() {
  let failure = Failed(reason: "error:badarg", detail: None)
  let #(status, failures, note) =
    plugin_runner.record(Running, 2, failure, limits)
  assert status == Disabled(reason: "error:badarg", dropped: 0)
  assert failures == 0
  assert note
    == Some(
      "disabled after 3 consecutive failures (error:badarg); events will be dropped",
    )
}

/// 打ち切りも 1 件の失敗として数える。
pub fn record_counts_a_timeout_as_a_failure_test() {
  let failure = Failed(reason: "timed out after 50ms", detail: None)
  assert plugin_runner.record(Running, 0, failure, limits)
    == #(Running, 1, Some("handle_event failed (timed out after 50ms); 1/3"))
}

/// スタックトレースはログ行にだけ出し、無効化の理由には残さない。
pub fn record_appends_the_stacktrace_to_the_log_only_test() {
  let failure =
    Failed(reason: "error:badarg", detail: Some("[{my_plugin,handle_event,1}]"))
  let #(_status, _failures, note) =
    plugin_runner.record(Running, 0, failure, limits)
  assert note
    == Some(
      "handle_event failed (error:badarg); 1/3 at [{my_plugin,handle_event,1}]",
    )

  let #(status, _failures, note) =
    plugin_runner.record(Running, 2, failure, limits)
  assert status == Disabled(reason: "error:badarg", dropped: 0)
  let assert Some(line) = note
  assert !string.contains(line, "my_plugin")
}

/// 長い文字列は省略記号を付けて切る。
pub fn truncate_caps_long_text_test() {
  let text = string.repeat("a", 20)
  assert plugin_runner.truncate(text, 5) == "aaaaa..."
}

/// 上限以内の文字列はそのまま返す。
pub fn truncate_leaves_short_text_test() {
  assert plugin_runner.truncate("short", 5) == "short"
}

/// クラッシュし続けるプラグインは無効化されるが、ランナーのプロセスは生き残る。
/// 名前が登録されたままなので、管理 UI から状態を問い合わせられる。
///
/// ワーカーが自分で例外を捕まえて短い理由で exit するため、BEAM の
/// `=ERROR REPORT=` は出ない。代わりにランナーが 1 行ログを最大 3 行出す。
pub fn crashing_plugin_is_disabled_and_stays_alive_test() {
  let name =
    start_runner(
      fn(_incoming) { panic as "boom" },
      Limits(..limits, max_failures: 3),
    )
  let assert Ok(runner) = process.named(name)
  deliver(name, 10)
  let assert Some(Disabled(reason:, dropped:)) = plugin_runner.status(name)
  assert string.length(reason) <= 123
  assert dropped == 7
  assert process.is_alive(runner)
}

/// ワーカーの終了理由は短い 1 行に整えられる。FFI のラッパーが例外クラスと理由
/// だけを取り出し、スタックトレースを混ぜない経路の回帰テスト。
pub fn crashing_plugin_reason_is_short_test() {
  let name =
    start_runner(
      fn(_incoming) { erlang_error(atom.create("badarg")) },
      Limits(..limits, max_failures: 1),
    )
  deliver(name, 1)
  assert plugin_runner.status(name)
    == Some(Disabled(reason: "error:badarg", dropped: 0))
}

/// 戻らないプラグインは打ち切られ、失敗として数えられる。ランナーは生き残る。
pub fn hanging_plugin_is_timed_out_test() {
  let name =
    start_runner(
      fn(_incoming) { process.sleep_forever() },
      Limits(..limits, handle_timeout_ms: 50, max_failures: 1),
    )
  let assert Ok(runner) = process.named(name)
  deliver(name, 1)
  assert plugin_runner.status(name)
    == Some(Disabled(reason: "timed out after 50ms", dropped: 0))
  assert process.is_alive(runner)
}

/// 何もしないプラグインは、何度実行しても失敗と数えられない。ワーカーの生成と
/// 監視を分けたときに出る `noproc` の誤判定の回帰テスト（確率的にしか検知でき
/// ないが、実行は安い）。
pub fn fast_plugin_never_reports_a_failure_test() {
  let name = start_runner(fn(_incoming) { Nil }, plugin_runner.default_limits)
  deliver(name, 500)
  assert plugin_runner.status(name) == Some(Running)
}

/// 正常なプラグインのランナーは `Running` を返す。
pub fn runner_answers_status_while_healthy_test() {
  let name = start_runner(fn(_incoming) { Nil }, plugin_runner.default_limits)
  assert plugin_runner.status(name) == Some(Running)
}

/// 打ち切ったワーカーの DOWN はメールボックスへ残さない。`process.kill` の後に
/// `demonitor_process`（`[flush]` 付き）を呼んでいないと、残留 DOWN が次の
/// イベントの時点でキュー長 1 として観測される。`max_queue_len` を 0 にして
/// おくと、その 1 件がそのまま切り捨ての判定に現れるので検出できる。
pub fn a_timed_out_worker_leaves_no_stray_down_test() {
  let name =
    start_runner(
      fn(_incoming) { process.sleep_forever() },
      Limits(handle_timeout_ms: 300, max_queue_len: 0, max_failures: 2),
    )
  // 1 件目の実行が始まってから 2 件目を積む。こうすると 1 件目の判定はキューが
  // 空の状態で行われ、2 件目の判定だけが残留 DOWN の有無で変わる。
  deliver(name, 1)
  process.sleep(100)
  deliver(name, 1)
  // 2 件目の打ち切りが終わるまで待ってから問い合わせる。実行中に問い合わせると
  // `GetStatus` 自身がキューに積まれ、残留 DOWN と区別が付かなくなる。
  process.sleep(700)
  // 2 件とも打ち切られて無効化される。残留 DOWN があると 2 件目は切り捨てられ、
  // 状態は `Overloaded` になる。
  assert plugin_runner.status(name)
    == Some(Disabled(reason: "timed out after 300ms", dropped: 0))
}

/// 呼び出しそのもので起きた例外（`undef` / `function_clause` / BIF の `badarg`）
/// では、スタックトレースの第 3 要素が実引数のリストになる。`handle_event/1` は
/// `erlang:apply/3` で呼ぶため、アリティへ正規化していないと最上位フレームに
/// イベント map が丸ごと入ってしまう。ログに残るのがスタックトレースであって
/// イベントの部分ダンプではないことを確かめる。
pub fn a_failed_call_does_not_leak_the_event_into_the_stacktrace_test() {
  let incoming =
    Event(
      id: "arity-regression-id",
      pubkey: "",
      created_at: 0,
      kind: 1,
      tags: [],
      content: "arity-regression-content",
      sig: "",
    )
  let missing = atom.create("nostr_no_su_missing_plugin")
  let #(_worker, watch) =
    run_isolated(fn() {
      let _ =
        apply(missing, atom.create("handle_event"), [
          event.to_map(incoming),
        ])
      Nil
    })
  let assert Ok(process.ProcessDown(reason: process.Abnormal(reason), ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)

  let #(text, detail) = describe_exit(reason)
  assert text == "error:undef"
  let assert Some(stack) = detail
  assert string.contains(stack, "{nostr_no_su_missing_plugin,handle_event,1}")
  assert !string.contains(stack, "arity-regression-id")
  assert !string.contains(stack, "arity-regression-content")
}
