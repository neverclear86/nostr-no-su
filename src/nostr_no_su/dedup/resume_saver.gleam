//// 監視の購読の再開点を周期ごとに保存するアクター。ディスパッチャーから写しを
//// 取り、前回保存した写しと違うリレーだけを書く。DB の遅さと障害をディスパッチャー
//// に持ち込まないため、ディスパッチャーとは別のプロセスで書く。再起動したアクター
//// は前回の写しを持たないので、最初の周期で全リレーを書く（保存は値を小さくしない
//// ので害は無い）。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/dedup
import nostr_no_su/dedup/resume
import nostr_no_su/log

/// 保存の周期（ミリ秒）。再接続の間隔（`relay_connection.default_reconnect_delay`）
/// と同じ桁で、異常終了で失う再開点を数秒に抑えつつ、書き込みを「この間隔に高々
/// リレーの本数の行」にする値である。
pub const default_interval_ms = 5000

/// ログの接頭辞。
const log_prefix = "resume_saver"

/// このアクターが受け取るメッセージ。
pub type Msg {
  /// 周期ごとの保存を促すタイマー。
  Save
}

/// アクターの状態。`save` は保存先を表す操作で、値を含まない説明で失敗を返す。
type State {
  State(
    dedup: Name(dedup.Msg),
    save: fn(List(#(String, Int))) -> Result(Nil, String),
    interval_ms: Int,
    self: Subject(Msg),
    saved: Dict(String, Int),
    failing: Bool,
  )
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  dedup: Name(dedup.Msg),
  save: fn(List(#(String, Int))) -> Result(Nil, String),
  interval_ms: Int,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(dedup, save, interval_ms) })
}

/// アクターを起動する。周期のタイマーは名前の無い自分の subject に送るため、
/// 名前付き subject へのタイマーが再起動後のアクターに届く問題
/// （`docs/architecture.md` の「名前なしの subject」の節）を避ける。
pub fn start(
  dedup: Name(dedup.Msg),
  save: fn(List(#(String, Int))) -> Result(Nil, String),
  interval_ms: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send_after(self, interval_ms, Save)
    State(
      dedup: dedup,
      save: save,
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

/// ディスパッチャーから写しを取り、変わったリレーだけを保存する。ディスパッチャー
/// が応答しなければ状態を変えない。保存する対象が無ければ状態を変えない。
fn save_points(state: State) -> State {
  case dedup.points(state.dedup) {
    Error(Nil) -> state
    Ok(current) ->
      case resume.unsaved(state.saved, current) {
        [] -> state
        unsaved ->
          case state.save(unsaved) {
            Ok(Nil) -> {
              case state.failing {
                True -> log.println(log_prefix, "resume points saved again")
                False -> Nil
              }
              State(..state, saved: current, failing: False)
            }
            Error(reason) -> {
              case state.failing {
                False ->
                  log.println(
                    log_prefix,
                    "could not save resume points: "
                      <> reason
                      <> "; retrying every "
                      <> int.to_string(state.interval_ms)
                      <> "ms",
                  )
                True -> Nil
              }
              State(..state, failing: True)
            }
          }
      }
  }
}
