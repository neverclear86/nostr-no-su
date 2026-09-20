import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin
import nostr_no_su/plugin_runner.{
  Completed, Disabled, Failed, Limits, Overloaded, Running, Target,
}

/// 遷移の検証に使う歯止め。実時間に依存しないよう小さく取る。
const limits = Limits(handle_timeout_ms: 50, max_queue_len: 10, max_failures: 3)

/// 配信するイベント。ランナーは中身を見ずにプラグインへ渡すだけなので、区別に
/// 使う `id` 以外は最小限。
fn test_event(id: String) -> Event {
  Event(
    id: id,
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
  start_named_runner(name, handle, limits)
  name
}

/// 指定した `handle` を持つプラグインのランナーを、呼び出し側が作った名前で
/// 起動する。ランナーより先に名前へ送るテストが使う。
fn start_named_runner(
  name: Name(plugin_runner.Msg),
  handle: fn(Event) -> Nil,
  limits: plugin_runner.Limits,
) -> Nil {
  let assert Ok(_started) =
    plugin_runner.start(
      name,
      plugin.Plugin(name: "runner_test", children: [], handle: handle),
      limits,
    )
  Nil
}

/// イベントを指定した件数だけランナーへ送る。
fn deliver(name: Name(plugin_runner.Msg), count: Int) -> Nil {
  let targets = [plugin_runner.target("runner_test", name)]
  use _unit <- list.each(list.repeat(Nil, count))
  plugin_runner.dispatch(targets, test_event("e1"))
}

/// 取りこぼしの集計を確かめる宛先。名前にプロセスは居なくてよい。
fn test_target() -> plugin_runner.Target {
  plugin_runner.target("runner_test", process.new_name("test_plugin_runner"))
}

/// `last` の id を受け取るまで、プラグインが転送した id を数える。
fn count_until(handled: Subject(String), last: String, count: Int) -> Int {
  let assert Ok(id) = process.receive(handled, 5000)
  case id == last {
    True -> count + 1
    False -> count_until(handled, last, count + 1)
  }
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

/// キューが上限の半分を超えている間は捨て続け、件数を数える。
pub fn admit_keeps_shedding_above_half_the_limit_test() {
  assert plugin_runner.admit(Overloaded(dropped: 4), 6, limits)
    == #(Overloaded(dropped: 5), False, None)
}

/// キューが上限の半分まで減ったら配信を再開し、捨てた件数を報告する。
pub fn admit_resumes_at_half_the_limit_test() {
  let #(status, should_run, note) =
    plugin_runner.admit(Overloaded(dropped: 7), 5, limits)
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

/// 実行したイベントの `created_at` で再開点が前進する。小さい `created_at` では
/// 下がらず、`now` より未来の `created_at` は `now` に切り詰める。
pub fn advance_moves_the_resume_point_forward_test() {
  assert plugin_runner.advance(Running, None, 100, 1000) == Some(100)
  assert plugin_runner.advance(Running, Some(100), 50, 1000) == Some(100)
  assert plugin_runner.advance(Running, Some(100), 2000, 1000) == Some(1000)
}

/// 切り捨てたイベントでも再開点は前進する（切り捨ては取り直しの対象外）。
pub fn an_overloaded_runner_advances_the_resume_point_test() {
  assert plugin_runner.advance(Overloaded(dropped: 1), None, 100, 1000)
    == Some(100)
}

/// 無効化の間のイベントは捨てるだけなので、再開点は前進しない。
pub fn a_disabled_runner_does_not_advance_the_resume_point_test() {
  let status = Disabled(reason: "error:badarg", dropped: 1)
  assert plugin_runner.advance(status, Some(100), 200, 1000) == Some(100)
  assert plugin_runner.advance(status, None, 200, 1000) == None
}

/// 届いている間は宛先も変えず、何も出さない。
pub fn record_delivery_is_silent_while_delivered_test() {
  let target = test_target()
  assert plugin_runner.record_delivery(target, True) == #(target, None)
}

/// 取りこぼしの 1 件目で数え始め、1 行報告する。
pub fn record_delivery_reports_the_first_miss_test() {
  let target = test_target()
  assert plugin_runner.record_delivery(target, False)
    == #(
      Target(..target, undelivered: 1),
      Some("runner is unavailable; dropping events until it is back"),
    )
}

/// 2 件目以降の取りこぼしは数えるだけで、何も出さない。
pub fn record_delivery_counts_later_misses_silently_test() {
  let target = Target(..test_target(), undelivered: 3)
  assert plugin_runner.record_delivery(target, False)
    == #(Target(..target, undelivered: 4), None)
}

/// ランナーに再び届いたら件数を 0 に戻し、取りこぼした件数を報告する。
pub fn record_delivery_reports_the_count_when_the_runner_is_back_test() {
  let target = Target(..test_target(), undelivered: 4)
  assert plugin_runner.record_delivery(target, True)
    == #(
      Target(..target, undelivered: 0),
      Some("runner is back; dropped 4 events while it was unavailable"),
    )
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

/// 無効化されたプラグインは再有効化で `Running` に戻り、捨てた件数を報告する。
pub fn reenable_returns_a_disabled_plugin_to_running_test() {
  assert plugin_runner.reenable(Disabled(reason: "error:badarg", dropped: 12))
    == #(
      Running,
      Some("re-enabled by the operator; dropped 12 events while disabled"),
    )
}

/// `Disabled` 以外はそのままで、何も報告しない。
pub fn reenable_leaves_other_states_test() {
  assert plugin_runner.reenable(Running) == #(Running, None)
  assert plugin_runner.reenable(Overloaded(dropped: 3))
    == #(Overloaded(dropped: 3), None)
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

/// 再有効化するとランナーは `Running` に戻り、イベントを再び処理する。プロセスは
/// 無効化の前後で同じままである。
pub fn a_reenabled_runner_handles_events_again_test() {
  let handled = process.new_subject()
  let name =
    start_runner(
      fn(incoming: Event) {
        case incoming.id {
          "bad" -> panic as "boom"
          id -> process.send(handled, id)
        }
      },
      Limits(..limits, max_failures: 3),
    )
  let assert Ok(runner_before) = process.named(name)
  let targets = [plugin_runner.target("runner_test", name)]
  list.each(list.repeat(Nil, 3), fn(_unit) {
    plugin_runner.dispatch(targets, test_event("bad"))
  })
  let assert Some(Disabled(..)) = plugin_runner.status(name)

  assert plugin_runner.request_reenable(name) == Some(Nil)
  assert plugin_runner.status(name) == Some(Running)
  assert process.named(name) == Ok(runner_before)

  plugin_runner.dispatch(targets, test_event("ok"))
  assert process.receive(handled, 1000) == Ok("ok")
}

/// 名前にランナーが居なければ再有効化の要求も応答が無い。
pub fn request_reenable_without_a_runner_is_none_test() {
  let name = process.new_name("test_plugin_runner")
  assert plugin_runner.request_reenable(name) == None
}

/// ランナーが処理したイベントの `created_at` が再開点になる。起動直後は
/// 再開点を持たない。
pub fn a_handled_event_advances_the_runner_resume_point_test() {
  let name = start_runner(fn(_incoming) { Nil }, limits)
  assert plugin_runner.resume(name) == Ok(None)
  let targets = [plugin_runner.target("runner_test", name)]
  plugin_runner.dispatch(
    targets,
    Event(..test_event("e1"), created_at: 1_700_000_000),
  )
  assert plugin_runner.resume(name) == Ok(Some(1_700_000_000))
}

/// 名前にランナーが居なければ再開点の問い合わせも応答が無い。再起動中の
/// ランナーがその周期の保存の対象にならないことの根拠である。
pub fn a_missing_runner_has_no_resume_point_test() {
  let name = process.new_name("test_plugin_runner")
  assert plugin_runner.resume(name) == Error(Nil)
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

/// 上限を 1 件超えたバーストで捨てるのは、積まれたイベントの半分である。
///
/// 1 件目の実行を止めている間に上限 + 2 件（1002 件）を積む。ランナーがキュー長
/// を見るのはメッセージを 1 件取り出した後なので、止めを外した直後の判定は
/// 1001 件で、上限を超えて捨て始める。キュー長 1001 から 501 までの 501 件を
/// 捨て、500 件になった 1 件から再開し、残りを全部実行する。復帰条件が
/// `queue_len == 0` だった版では、実行されるのは最後の 1 件だけだった。
pub fn a_burst_just_over_the_limit_loses_half_test() {
  let gates = process.new_subject()
  let handled = process.new_subject()
  let name =
    start_runner(
      fn(incoming: Event) {
        case incoming.id {
          "gate" -> {
            let release = process.new_subject()
            process.send(gates, release)
            let _ = process.receive(release, 5000)
            Nil
          }
          id -> process.send(handled, id)
        }
      },
      plugin_runner.default_limits,
    )
  let targets = [plugin_runner.target("runner_test", name)]
  plugin_runner.dispatch(targets, test_event("gate"))
  let assert Ok(release) = process.receive(gates, 1000)
  let burst = plugin_runner.default_limits.max_queue_len + 2
  deliver(name, burst - 1)
  plugin_runner.dispatch(targets, test_event("last"))
  process.send(release, Nil)
  let lost = burst - count_until(handled, "last", 0)
  assert lost == burst / 2
}

/// ランナーが居ない間に送ったイベントは宛先ごとに数え、届くようになったら 0 に
/// 戻す。
pub fn dispatch_counts_events_while_the_runner_is_missing_test() {
  let handled = process.new_subject()
  let name = process.new_name("test_plugin_runner")
  let missing = [plugin_runner.target("runner_test", name)]
  let missing = plugin_runner.dispatch(missing, test_event("missed"))
  let missing = plugin_runner.dispatch(missing, test_event("missed"))
  assert missing == [Target(plugin: "runner_test", name: name, undelivered: 2)]

  start_named_runner(
    name,
    fn(incoming) { process.send(handled, incoming.id) },
    limits,
  )
  assert plugin_runner.dispatch(missing, test_event("delivered"))
    == [plugin_runner.target("runner_test", name)]
  assert process.receive(handled, 1000) == Ok("delivered")
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
