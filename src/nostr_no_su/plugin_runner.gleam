//// プラグイン 1 つぶんの実行プロセス。障害の隔離・実行時間の上限・過負荷時の
//// 切り捨て・連続失敗による無効化をここに閉じ込める。
////
//// - **プラグイン 1 つにつきランナー 1 つ。** 重複排除ディスパッチャーは新規と
////   判定したイベントを各ランナーへ送るだけで戻るため、プラグインの実行時間は
////   ディスパッチャーに一切載らない。
//// - **プラグインのイベント処理関数（`handle_event/1` または `/2`。どちらを
////   呼ぶかは `plugin.load` が決める）はイベント 1 件ごとの使い捨てプロセスで
////   動く。** ランナー
////   はそのワーカーと**リンクを張らず監視だけを張る**ので、プラグインの例外も
////   異常終了もランナーには伝播しない。ゆえに**プラグインの不調でスーパー
////   バイザーの再起動が起きず**、サブツリーの許容回数を消費せず、ルートの
////   `restart_tolerance(3, 60)` にも到達しない。
//// - **ワーカーの生成と監視は不可分でなければならない**（`erlang:spawn_monitor/1`。
////   `nostr_no_su_ffi:run_isolated/1`）。分けると、ワーカーが監視より先に終わった
////   ときに `noproc` の DOWN が届き、正常な実行を失敗と誤判定する。
//// - **歯止めは 2 つ。** 1 件あたりの実行時間の上限（超えたらワーカーを kill）と、
////   メールボックス長による切り捨て。切り捨ては超過分ではなく**そのとき積まれて
////   いたバックログ全体**を捨てて追いつく。
//// - **連続失敗が上限に達したプラグインは無効化する。** 以後イベントを捨てて
////   件数だけ数え、**プロセスは生かしたまま**にするので、名前は登録されたままで
////   管理 UI から状態を問い合わせられる。復帰の手段は本体の再起動か、ランナー
////   プロセスの強制終了（スーパーバイザーが作り直す）の 2 つである。
////
//// ワーカーの中では例外を捕まえるが、目的は隔離ではなく**終了理由を短い 1 行に
//// 整えること**である。隔離そのものはプロセスの境界が担っており、捕捉を外しても
//// 隔離は成立する。
////
//// リンクを張らないことの裏面として、ランナーが外部要因（強制終了やスーパー
//// バイザーによる停止）で死ぬと、そのとき実行中だったワーカーは孤児として残る。
//// 戻らないプラグインなら永久に残る。隔離を優先した意図的な判断で、次のイベント
//// は作り直されたランナーが新しいワーカーで処理する。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{
  type Down, type Monitor, type Name, type Pid, type Subject,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}

/// 実行時の歯止め。テストから小さい値を渡せるよう注入する。プラグイン固有の
/// 設定から与えられるようにする余地もここにある。
pub type Limits {
  Limits(handle_timeout_ms: Int, max_queue_len: Int, max_failures: Int)
}

/// 本番で使う既定の歯止め。
pub const default_limits: Limits = Limits(
  handle_timeout_ms: 30_000,
  max_queue_len: 1000,
  max_failures: 5,
)

/// 理由として保持する文字列の上限。ダッシュボードのセルとログ 1 行に収める。
const max_reason_chars = 120

/// ログにだけ出すスタックトレースの上限。状態には持たない。
const max_detail_chars = 400

/// 状態の問い合わせを待つ時間。ランナーは遅いプラグインを最大
/// `handle_timeout_ms` 待つが、ここを長くすると管理 UI が固まる。応答が来ない
/// ことは「状態不明」として正しく描画できるので、短く切って諦める。
const status_timeout_ms = 1000

/// プラグイン 1 つの現在の状態。ダッシュボードにもこのまま出す。
pub type Status {
  /// イベントを受け取って実行している。
  Running
  /// 未処理のイベントが多すぎるため、キューが空になるまで捨てている。
  Overloaded(dropped: Int)
  /// 連続失敗の上限に達したので無効化した。以後イベントは捨てて数えるだけ。
  Disabled(reason: String, dropped: Int)
}

/// プラグインのイベント処理関数を 1 件動かした結果。`detail` はスタックトレースで、ログに
/// だけ出す（状態には残さない。長すぎるうえ、無効化の表示に混ぜても読めない）。
pub type Outcome {
  Completed
  Failed(reason: String, detail: Option(String))
}

/// ランナーが受け取るメッセージ。
pub type Msg {
  /// 重複排除を通ったイベント 1 件。
  Handle(event: Event)
  /// 管理 UI からの状態の問い合わせ。
  GetStatus(reply: Subject(Status))
}

/// ランナーが保持する状態。`failures` は連続失敗数で、成功すると 0 に戻る。
type State {
  State(plugin: Plugin, limits: Limits, status: Status, failures: Int)
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  plugin: Plugin,
  limits: Limits,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, plugin, limits) })
}

/// プラグイン 1 つのランナーを起動する。`name` で登録するため、再起動後も
/// ディスパッチャーと管理 UI が同じ名前で到達できる。
pub fn start(
  name: Name(Msg),
  plugin: Plugin,
  limits: Limits,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(plugin: plugin, limits: limits, status: Running, failures: 0))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// イベント 1 件を全ランナーへ送る。送るだけで戻るので、ディスパッチャーは
/// プラグインの実行時間の影響を受けない。名前の宛先が居なければ `named.send`
/// がそのメッセージを捨てる（ランナーの再起動中）。
pub fn dispatch(targets: List(Name(Msg)), incoming: Event) -> Nil {
  use target <- list.each(targets)
  named.send(target, Handle(incoming))
}

/// ランナーへ現在の状態を問い合わせる。再起動中や、遅いプラグインを待っている
/// 最中は応答が無いので `None` を返す。管理 UI はそれを「unavailable」として
/// 描画する。
pub fn status(name: Name(Msg)) -> Option(Status) {
  named.call(name, status_timeout_ms, GetStatus)
}

/// メッセージ 1 件を処理する。イベントは `admit` が実行の可否を決め、実行した
/// ものは `record` が状態へ反映する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    GetStatus(reply) -> {
      process.send(reply, state.status)
      actor.continue(state)
    }
    Handle(incoming) -> {
      let #(status, should_run, note) =
        admit(state.status, message_queue_len(), state.limits)
      report(state.plugin.name, note)
      case should_run {
        False -> actor.continue(State(..state, status: status))
        True -> {
          let outcome =
            run(state.plugin, incoming, state.limits.handle_timeout_ms)
          let #(status, failures, note) =
            record(status, state.failures, outcome, state.limits)
          report(state.plugin.name, note)
          actor.continue(State(..state, status: status, failures: failures))
        }
      }
    }
  }
}

/// 遷移が求めたログ行があれば、そのプラグインの接頭辞を付けて出力する。
fn report(name: String, note: Option(String)) -> Nil {
  case note {
    None -> Nil
    Some(line) -> log.println(log.plugin_prefix(name), line)
  }
}

/// 受け取ったイベントを実行してよいか決める。返すのは次の状態・実行するか・
/// 出すログ行。
///
/// 無効化されているあいだは何もせず数える。`Running` でキューが上限を超えて
/// いれば切り捨てに移り、`Overloaded` はキューが空になった時点で復帰する。
/// 復帰条件が `queue_len == 0` なので、切り捨ては超過分だけでなくそのとき
/// 積まれていたバックログ全体に及ぶ。
pub fn admit(
  status: Status,
  queue_len: Int,
  limits: Limits,
) -> #(Status, Bool, Option(String)) {
  case status {
    Disabled(reason:, dropped:) -> #(
      Disabled(reason: reason, dropped: dropped + 1),
      False,
      None,
    )
    Running if queue_len > limits.max_queue_len -> #(
      Overloaded(dropped: 1),
      False,
      Some(
        "too slow: "
        <> int.to_string(queue_len)
        <> " events queued (limit "
        <> int.to_string(limits.max_queue_len)
        <> "); dropping until it catches up",
      ),
    )
    Running -> #(Running, True, None)
    Overloaded(dropped:) if queue_len > 0 -> #(
      Overloaded(dropped: dropped + 1),
      False,
      None,
    )
    Overloaded(dropped:) -> #(
      Running,
      True,
      Some(
        "caught up; dropped "
        <> int.to_string(dropped)
        <> " events while overloaded",
      ),
    )
  }
}

/// 実行結果を状態へ反映する。返すのは次の状態・連続失敗数・出すログ行。
///
/// `admit` が実行を許したときにしか呼ばれない。したがって `Overloaded` の間は
/// 連続失敗数が凍結し、切り捨てを抜けた最初の失敗が前回の続きから数えられる。
pub fn record(
  status: Status,
  failures: Int,
  outcome: Outcome,
  limits: Limits,
) -> #(Status, Int, Option(String)) {
  case outcome {
    Completed -> #(status, 0, None)
    Failed(reason:, detail:) -> {
      let failures = failures + 1
      case failures >= limits.max_failures {
        True -> #(
          Disabled(reason: reason, dropped: 0),
          0,
          Some(
            "disabled after "
            <> int.to_string(limits.max_failures)
            <> " consecutive failures ("
            <> reason
            <> "); events will be dropped",
          ),
        )
        False -> #(
          status,
          failures,
          Some(
            "handle_event failed ("
            <> reason
            <> "); "
            <> int.to_string(failures)
            <> "/"
            <> int.to_string(limits.max_failures)
            <> detail_suffix(detail),
          ),
        )
      }
    }
  }
}

/// 失敗のログ行に添えるスタックトレース。無ければ何も足さない。
fn detail_suffix(detail: Option(String)) -> String {
  case detail {
    None -> ""
    Some(stack) -> " at " <> stack
  }
}

/// 長い文字列を末尾に省略記号を付けて切る。プラグインが投げた理由やスタック
/// トレースは数百文字になり、ログ 1 行にもダッシュボードのセルにも収まらない。
pub fn truncate(text: String, max: Int) -> String {
  case string.length(text) > max {
    True -> string.slice(text, 0, max) <> "..."
    False -> text
  }
}

/// プラグインのイベント処理関数を使い捨てのプロセスで 1 件動かし、結果を待つ。プラグインの
/// 例外も異常終了もこのプロセスの死として観測されるだけで、ランナーには届かない
/// （リンクを張らないため）。時間内に終わらなければ打ち切る。
fn run(plugin: Plugin, incoming: Event, timeout_ms: Int) -> Outcome {
  let #(worker, watch) = run_isolated(fn() { plugin.handle(incoming) })
  let waiting =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
  case process.selector_receive(waiting, timeout_ms) {
    Ok(process.ProcessDown(reason: process.Normal, ..)) -> Completed
    Ok(down) -> failure(down)
    Error(Nil) -> {
      // 打ち切り。`demonitor_process` は flush 付きなので、kill で発生した DOWN が
      // メールボックスへ残らない。残すとアクターのループが「想定外のメッセージ」
      // として警告を出す。
      process.kill(worker)
      process.demonitor_process(watch)
      Failed(
        reason: "timed out after " <> int.to_string(timeout_ms) <> "ms",
        detail: None,
      )
    }
  }
}

/// 異常終了した DOWN を、短い理由と（あれば）スタックトレースに分ける。
fn failure(down: Down) -> Outcome {
  case down {
    process.ProcessDown(reason: process.Abnormal(reason), ..) -> {
      let #(text, stack) = describe_exit(reason)
      Failed(
        reason: truncate(text, max_reason_chars),
        detail: option.map(stack, truncate(_, max_detail_chars)),
      )
    }
    process.ProcessDown(reason: process.Killed, ..) ->
      Failed(reason: "killed", detail: None)
    // `Normal` は呼び出し側で処理済み。`PortDown` は監視対象がプロセスなので
    // 届かない。網羅のためだけの枝。
    _ -> Failed(reason: "unexpected worker exit", detail: None)
  }
}

/// プラグインのイベント処理関数を監視付きの使い捨てプロセスで動かす。生成と監視は不可分で
/// なければならない（FFI の doc コメントを参照）。
@external(erlang, "nostr_no_su_ffi", "run_isolated")
fn run_isolated(run: fn() -> Nil) -> #(Pid, Monitor)

/// 異常終了の理由を、1 行の理由と（あれば）スタックトレースに分ける。
@external(erlang, "nostr_no_su_ffi", "describe_exit")
fn describe_exit(reason: Dynamic) -> #(String, Option(String))

/// 自プロセスの未処理メッセージ数。
@external(erlang, "nostr_no_su_ffi", "message_queue_len")
fn message_queue_len() -> Int
