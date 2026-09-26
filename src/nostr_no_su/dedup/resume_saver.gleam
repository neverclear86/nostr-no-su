//// 再開点を周期ごとに保存するアクター。監視の購読（リレーごと）とプラグイン
//// （プラグインごと）が共用する。写しを取る操作を注入で受け取り、前回保存した
//// 写しと違う行だけを書く。DB の遅さと障害を写しの取り先（ディスパッチャー、
//// ランナー）に持ち込まないため、写しの取り先とは別のプロセスで書く。再起動した
//// アクターは前回の写しを持たないので、最初の周期で全件を書く（保存は値を
//// 小さくしないので害は無い）。

import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/dedup/resume
import nostr_no_su/log

/// 保存の周期（ミリ秒）。再接続の間隔（`relay_connection.default_reconnect_delay`）
/// と同じ桁で、異常終了で失う再開点を数秒に抑えつつ、書き込みを「この間隔に高々
/// リレーの本数の行」にする値である。
pub const default_interval_ms = 5000

/// このアクターが受け取るメッセージ。
pub type Msg {
  /// 周期ごとの保存を促すタイマー。
  Save
}

/// アクターの状態。`points` は再開点の写しを取る操作、`save` は保存先を表す
/// 操作で、値を含まない説明で失敗を返す。`prefix` はログの接頭辞。
type State {
  State(
    points: fn() -> Result(Dict(String, Int), Nil),
    save: fn(List(#(String, Int))) -> Result(Nil, String),
    prefix: String,
    interval_ms: Int,
    self: Subject(Msg),
    saved: Dict(String, Int),
    failing: Bool,
  )
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  points: fn() -> Result(Dict(String, Int), Nil),
  save: fn(List(#(String, Int))) -> Result(Nil, String),
  prefix: String,
  interval_ms: Int,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(points, save, prefix, interval_ms) })
}

/// アクターを起動する。周期のタイマーは名前の無い自分の subject に送るため、
/// 名前付き subject へのタイマーが再起動後のアクターに届く問題（`docs/architecture.md`
/// の「アカウントの読み込み」の節にある、再試行を名前なしの subject へ予約する
/// 理由と同じ）を避ける。
pub fn start(
  points: fn() -> Result(Dict(String, Int), Nil),
  save: fn(List(#(String, Int))) -> Result(Nil, String),
  prefix: String,
  interval_ms: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send_after(self, interval_ms, Save)
    State(
      points: points,
      save: save,
      prefix: prefix,
      interval_ms: interval_ms,
      self: self,
      saved: dict.new(),
      failing: False,
    )
    |> actor.initialised
    |> actor.selecting(process.new_selector() |> process.select(self))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

/// 次の周期を予約し、写しを保存する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Save = msg
  process.send_after(state.self, state.interval_ms, Save)
  actor.continue(save_points(state))
}

/// 写しを取り、変わった行だけを保存する。写しを取る操作が失敗すれば状態を
/// 変えない。保存する対象が無ければ状態を変えない。
fn save_points(state: State) -> State {
  {
    use current <- result.map(state.points())
    let unsaved = resume.unsaved(state.saved, current)
    use <- bool.guard(unsaved == [], state)
    let outcome = state.save(unsaved)
    case save_report(state.failing, outcome, state.interval_ms) {
      Some(#(level, message)) -> log.write(level, state.prefix, message)
      None -> Nil
    }
    case outcome {
      Ok(Nil) -> State(..state, saved: current, failing: False)
      Error(_) -> State(..state, failing: True)
    }
  }
  |> result.unwrap(state)
}

/// 保存の結果に対して出すログ行。`was_failing` は直前の保存が失敗していたか、
/// `interval_ms` は保存の周期。失敗の始まりと復帰だけを報告し、失敗や成功が
/// 続く間は `None` を返す。
pub fn save_report(
  was_failing: Bool,
  outcome: Result(Nil, String),
  interval_ms: Int,
) -> Option(#(log.Level, String)) {
  case outcome, was_failing {
    Ok(Nil), True -> Some(#(log.Notice, "resume points saved again"))
    Error(reason), False ->
      Some(#(
        log.Warning,
        "could not save resume points: "
          <> reason
          <> "; retrying every "
          <> int.to_string(interval_ms)
          <> "ms",
      ))
    Ok(Nil), False | Error(_), True -> None
  }
}
