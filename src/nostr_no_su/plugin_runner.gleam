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
////   理由は `nostr_no_su_plugin_ffi:run_isolated/1` の Doc）。
//// - **歯止めは 2 つ。** 1 件あたりの実行時間の上限（超えたらワーカーを kill）と、
////   メールボックス長による切り捨て。切り捨ては上限を超えた時点で始め、超過分では
////   なく**キューが上限の半分以下に減るまで**続ける。
//// - **連続失敗が上限に達したプラグインは無効化する。** 以後イベントを捨てて
////   件数だけ数え、**プロセスは生かしたまま**にするので、名前は登録されたままで
////   管理 UI から状態を問い合わせられる。復帰の手段は本体の再起動か、管理 UI
////   からの再有効化の 2 つである。
//// - **ランナーが居ない間（再起動中）に送られたイベントはその場では届かない。**
////   ディスパッチャーは宛先ごとにその件数を数え、取りこぼしの始まりと、ランナーが
////   戻ったときの件数を 1 行ずつ出す（`dispatch`）。戻ったランナーは再開点からの
////   取り直しを要求し、その購読のイベントはディスパッチャーを通さずこのランナー
////   にだけ届く（`HandleCatchup`）。同じ id は `seen` のウィンドウで弾き、リレーが
////   保存済みイベントの終わりを告げたら（`CatchupEnded`）件数を出して要求を
////   落とす。
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
import gleam/result
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/resume
import nostr_no_su/time
import nostr_no_su/window.{type Window}

/// 実行時の歯止め。テストから小さい値を渡せるよう注入する。
pub type Limits {
  Limits(handle_timeout_ms: Int, max_queue_len: Int, max_failures: Int)
}

/// 本番で使う既定の歯止め。
pub const default_limits: Limits = Limits(
  handle_timeout_ms: 30_000,
  max_queue_len: 1000,
  max_failures: 5,
)

/// ログにだけ出すスタックトレースの上限。状態には持たない。
const max_detail_chars = 400

/// 状態の問い合わせと再有効化の要求を待つ時間。ランナーは遅いプラグインを最大
/// `handle_timeout_ms` 待つが、ここを長くすると管理 UI が固まる。応答が来ない
/// ことは「状態不明」として正しく描画できるので、短く切って諦める。
const status_timeout_ms = 1000

/// 取り直しの購読で届いたイベントの重複排除に使うウィンドウの容量。取り直しの
/// 購読は監視のリレーごとに張られるので、同じ範囲のイベントがリレーの数だけ
/// 大域のウィンドウを迂回して届く。
const catchup_window_capacity = 1000

/// プラグイン 1 つの現在の状態。ダッシュボードにもこのまま出す。
pub type Status {
  /// イベントを受け取って実行している。
  Running
  /// 未処理のイベントが多すぎるため、キューが上限の半分以下に減るまで捨てている。
  Overloaded(dropped: Int)
  /// 連続失敗の上限に達したので無効化した。以後イベントは捨てて数えるだけ。
  /// 管理 UI から再有効化すると `Running` に戻る。
  Disabled(reason: String, dropped: Int)
}

/// プラグインのイベント処理関数を 1 件動かした結果。`detail` はスタックトレースで、ログに
/// だけ出す（状態には残さない。長すぎるうえ、無効化の表示に混ぜても読めない）。
pub type Outcome {
  Completed
  Failed(reason: String, detail: Option(String))
}

/// プラグインの取り直しの要求 1 件。`since` はランナーのメモリの再開点で、
/// `None` なら保存済みの値を使う（`subscriptions.catchup_since`）。`until` は
/// 要求を立てた時刻で、これより後のイベントは通常の監視の購読が運ぶ。
pub type Catchup {
  Catchup(since: Option(Int), until: Int)
}

/// ランナーが受け取るメッセージ。
pub type Msg {
  /// 重複排除を通ったイベント 1 件。
  Handle(event: Event)
  /// 取り直しの購読で届いたイベント 1 件。大域の重複排除を通らないので、ここで
  /// `seen` に照らす。
  HandleCatchup(event: Event)
  /// 取り直しの購読が保存済みイベントの終わりに達したこと（EOSE）の知らせ。
  CatchupEnded
  /// 管理 UI からの状態の問い合わせ。
  GetStatus(reply: Subject(Status))
  /// 管理 UI からの再有効化の要求。応答はランナーが要求を処理したことだけを伝える。
  Reenable(reply: Subject(Nil))
  /// 再開点の保存のための、このプラグインの再開点の問い合わせ。
  GetResume(reply: Subject(Option(Int)))
  /// 購読の定義のための、このプラグインの取り直しの要求の問い合わせ。
  GetCatchup(reply: Subject(Option(Catchup)))
}

/// ディスパッチャーがイベントを送る宛先 1 つ。`plugin` はログの接頭辞に使う
/// プラグイン名、`undelivered` はランナーが居なくて届けられなかった件数で、
/// 届いた時点で 0 に戻る。
pub type Target {
  Target(plugin: String, name: Name(Msg), undelivered: Int)
}

/// ランナーが保持する状態。`failures` は連続失敗数で、成功すると 0 に戻る。
/// `resume` はこのプラグインの再開点で、処理したイベントの `created_at` で
/// 前進する（`advance`）。`catchup` は取り直しの要求で、起動時と `Disabled`
/// からの再有効化で立ち、`CatchupEnded` で落ちる。`seen` は取り直しで渡した
/// id のウィンドウ、`caught_up` は今の取り直しで渡した件数である。
type State {
  State(
    plugin: Plugin,
    limits: Limits,
    resubscribe: fn() -> Nil,
    status: Status,
    failures: Int,
    resume: Option(Int),
    catchup: Option(Catchup),
    seen: Window,
    caught_up: Int,
  )
}

/// スーパービジョンツリー用の子仕様。`resubscribe` は復帰したときに監視の
/// 購読を張り直させる操作。
pub fn supervised(
  name: Name(Msg),
  plugin: Plugin,
  resubscribe: fn() -> Nil,
  limits: Limits,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, plugin, resubscribe, limits) })
}

/// プラグイン 1 つのランナーを起動する。`name` で登録するため、再起動後も
/// ディスパッチャーと管理 UI が同じ名前で到達できる。起動は本体の再起動か
/// ランナーのクラッシュからの復帰なので、必ず取り直しを要求する。保存済みの
/// 再開点が無ければ購読は定義されない。
pub fn start(
  name: Name(Msg),
  plugin: Plugin,
  resubscribe: fn() -> Nil,
  limits: Limits,
) -> actor.StartResult(Subject(Msg)) {
  let started =
    actor.new(State(
      plugin: plugin,
      limits: limits,
      resubscribe: resubscribe,
      status: Running,
      failures: 0,
      resume: None,
      catchup: Some(Catchup(since: None, until: time.now_seconds())),
      seen: window.new(catchup_window_capacity),
      caught_up: 0,
    ))
    |> actor.named(name)
    |> actor.on_message(handle)
    |> actor.start
  case started {
    Ok(_) -> resubscribe()
    Error(_) -> Nil
  }
  started
}

/// まだ 1 件も取りこぼしていない宛先を作る。
pub fn target(plugin: String, name: Name(Msg)) -> Target {
  Target(plugin: plugin, name: name, undelivered: 0)
}

/// イベント 1 件を全ランナーへ送り、取りこぼしを数えた宛先を返す。送るだけで
/// 戻るので、ディスパッチャーはプラグインの実行時間の影響を受けない。名前の
/// 宛先が居なければ（ランナーの再起動中）そのイベントはその場では届かず、
/// `record_delivery` が数える。届けられなかった分は、戻ったランナーの取り直しの
/// 要求で後から届きうる（`catchup`）。取り直しのイベントはこの関数を通らない
/// ので、`undelivered` には数えない。
pub fn dispatch(targets: List(Target), incoming: Event) -> List(Target) {
  use target <- list.map(targets)
  let delivered = result.is_ok(named.try_send(target.name, Handle(incoming)))
  let #(target, note) = record_delivery(target, delivered)
  report(target.plugin, note)
  target
}

/// ランナーへ現在の状態を問い合わせる。再起動中や、遅いプラグインを待っている
/// 最中は応答が無いので `None` を返す。管理 UI はそれを「unavailable」として
/// 描画する。
pub fn status(name: Name(Msg)) -> Option(Status) {
  named.call(name, status_timeout_ms, GetStatus)
}

/// ランナーに再有効化を頼む。応答が無ければ `None`（再起動中など）。諦められた
/// 子は戻らない。
pub fn request_reenable(name: Name(Msg)) -> Option(Nil) {
  named.call(name, status_timeout_ms, Reenable)
}

/// このプラグインの再開点。`status` と同じく、再起動中や遅い実行の最中は応答が
/// 無く `Error(Nil)` を返す。その周期の保存にはこのプラグインを入れない。
pub fn resume(name: Name(Msg)) -> Result(Option(Int), Nil) {
  named.call(name, status_timeout_ms, GetResume)
  |> option.to_result(Nil)
}

/// このプラグインの取り直しの要求。`resume` と同じく、再起動中や遅い実行の
/// 最中は応答が無く `Error(Nil)` を返す。
pub fn catchup(name: Name(Msg)) -> Result(Option(Catchup), Nil) {
  named.call(name, status_timeout_ms, GetCatchup)
  |> option.to_result(Nil)
}

/// メッセージ 1 件を処理する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    GetStatus(reply) -> {
      process.send(reply, state.status)
      actor.continue(state)
    }
    GetResume(reply) -> {
      process.send(reply, state.resume)
      actor.continue(state)
    }
    GetCatchup(reply) -> {
      process.send(reply, state.catchup)
      actor.continue(state)
    }
    Reenable(reply) -> {
      let #(status, note) = reenable(state.status)
      report(state.plugin.name, note)
      process.send(reply, Nil)
      case state.status {
        // `Disabled` からの復帰は取り直しを要求する。`Running` と `Overloaded`
        // のままの再有効化は状態も要求も変えない。
        Disabled(..) -> {
          state.resubscribe()
          actor.continue(
            State(
              ..state,
              status: status,
              catchup: Some(Catchup(
                since: state.resume,
                until: time.now_seconds(),
              )),
            ),
          )
        }
        Running | Overloaded(..) -> actor.continue(state)
      }
    }
    Handle(incoming) -> actor.continue(run_incoming(state, incoming, None))
    HandleCatchup(incoming) ->
      case window.insert(state.seen, incoming.id) {
        Error(Nil) -> actor.continue(state)
        Ok(next) -> actor.continue(run_incoming(state, incoming, Some(next)))
      }
    CatchupEnded ->
      case state.catchup {
        None -> actor.continue(state)
        Some(_) -> {
          log.write(
            log.Notice,
            log.plugin_prefix(state.plugin.name),
            "catch-up finished; re-delivered "
              <> int.to_string(state.caught_up)
              <> " events",
          )
          let next = State(..state, caught_up: 0, catchup: None)
          state.resubscribe()
          actor.continue(next)
        }
      }
  }
}

/// イベント 1 件を処理する。`admit` が実行の可否を決め、その結果で再開点を
/// 前進させ（`advance`）、実行したものは `record` が状態へ反映する。
/// `catchup_seen` は取り直しで届いたイベントについて、id を挿したあとの
/// ウィンドウ。実行を許した（`should_run` が真の）ときだけ `seen` に反映して
/// `caught_up` を 1 増やす。無効化や過負荷で捨てた分を取り直しの完了の行に
/// 数えないためで、捨てた id は次の取り直しで再び届きうる。通常の配信
/// （`Handle`）は `None` を渡し、ウィンドウと件数に触れない。
fn run_incoming(
  state: State,
  incoming: Event,
  catchup_seen: Option(Window),
) -> State {
  let #(status, should_run, note) =
    admit(state.status, message_queue_len(), state.limits)
  report(state.plugin.name, note)
  let resume =
    advance(status, state.resume, incoming.created_at, time.now_seconds())
  case should_run {
    False -> State(..state, status: status, resume: resume)
    True -> {
      let outcome = run(state.plugin, incoming, state.limits.handle_timeout_ms)
      let #(status, failures, note) =
        record(status, state.failures, outcome, state.limits)
      report(state.plugin.name, note)
      let next = State(..state, status:, failures:, resume:)
      case catchup_seen {
        Some(seen) -> State(..next, seen:, caught_up: next.caught_up + 1)
        None -> next
      }
    }
  }
}

/// 遷移が求めたログ行があれば、そのプラグインの接頭辞を付けて出力する。
fn report(name: String, note: Option(String)) -> Nil {
  case note {
    None -> Nil
    Some(line) -> log.write(log.Warning, log.plugin_prefix(name), line)
  }
}

/// 受け取ったイベントを実行してよいか決める。返すのは次の状態・実行するか・
/// 出すログ行。
///
/// 無効化されているあいだは何もせず数える。`Running` でキューが上限を超えて
/// いれば切り捨てに移り、`Overloaded` はキューが上限の半分以下に減った時点で
/// 復帰する。空になるまで待つと、上限を 1 件超えただけのバーストでもバック
/// ログ全体を捨てる。上限まで減った時点で復帰すると、上限の前後で流入が続く
/// 間は切り捨ての開始と復帰の行が 1 件ごとに交互に出る。
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
    Overloaded(dropped:) if queue_len > limits.max_queue_len / 2 -> #(
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

/// 処理したイベントの `created_at` で再開点を前進させる。`status` には `admit`
/// が返した状態を渡す。`Disabled`（無効化の間のイベント）は捨てるだけなので
/// 前進せず `current` のまま返す。実行した（`Running`）ものも切り捨てた
/// （`Overloaded`）ものも前進させる。切り捨ては取り直しの対象外であり、失敗した
/// 実行でもそのイベントはプラグインに届いているためである。前進の規則は
/// `resume.advance` に従う。
pub fn advance(
  status: Status,
  current: Option(Int),
  created_at: Int,
  now: Int,
) -> Option(Int) {
  case status {
    Disabled(..) -> current
    Running | Overloaded(..) -> Some(resume.advance(current, created_at, now))
  }
}

/// 運用者による再有効化を状態へ反映する。返すのは次の状態と、あれば出すログ行。
///
/// `Disabled` だけを `Running` に戻す。無効化の時点で連続失敗数は 0 に戻って
/// いる（`record`）ので、ここでは触れない。`Running` と `Overloaded` は
/// ボタンの表示先ではないが、表示と送信の間に状態が変わることがあるので、その
/// ときは何もせず現状のまま返す。
pub fn reenable(status: Status) -> #(Status, Option(String)) {
  case status {
    Disabled(dropped:, ..) -> #(
      Running,
      Some(
        "re-enabled by the operator; dropped "
        <> int.to_string(dropped)
        <> " events while disabled; it will re-request them if it has a resume point",
      ),
    )
    Running | Overloaded(..) -> #(status, None)
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

/// 送信の成否を宛先へ反映する。返すのは次の宛先と出すログ行。
///
/// 行を出すのは取りこぼしの 1 件目と、ランナーが戻って最初に届いたときだけで、
/// その間は数えるだけにする。1 件ごとに出すと、ランナーが戻らない間のログの
/// 行数が流入量に比例する。
pub fn record_delivery(
  target: Target,
  delivered: Bool,
) -> #(Target, Option(String)) {
  case delivered, target.undelivered {
    True, 0 -> #(target, None)
    True, undelivered -> #(
      Target(..target, undelivered: 0),
      Some(
        "runner is back; dropped "
        <> int.to_string(undelivered)
        <> " events while it was unavailable; it will re-request them if it has a resume point",
      ),
    )
    False, 0 -> #(
      Target(..target, undelivered: 1),
      Some("runner is unavailable; dropping events until it is back"),
    )
    False, undelivered -> #(
      Target(..target, undelivered: undelivered + 1),
      None,
    )
  }
}

/// 失敗のログ行に添えるスタックトレース。無ければ何も足さない。
fn detail_suffix(detail: Option(String)) -> String {
  case detail {
    None -> ""
    Some(stack) -> " at " <> stack
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
        reason: log.sanitize(text, log.max_reason_chars),
        detail: option.map(stack, log.sanitize(_, max_detail_chars)),
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
@external(erlang, "nostr_no_su_plugin_ffi", "run_isolated")
fn run_isolated(run: fn() -> Nil) -> #(Pid, Monitor)

/// 異常終了の理由を、1 行の理由と（あれば）スタックトレースに分ける。
@external(erlang, "nostr_no_su_plugin_ffi", "describe_exit")
fn describe_exit(reason: Dynamic) -> #(String, Option(String))

/// 自プロセスの未処理メッセージ数。
@external(erlang, "nostr_no_su_plugin_ffi", "message_queue_len")
fn message_queue_len() -> Int
