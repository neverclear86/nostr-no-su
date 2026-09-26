//// `resume/saver` のテスト。アクターを試すものはディスパッチャーを本物で起動するか
//// 写しの操作を直接渡し、DB の代わりにメモリ上の保存の操作を渡す。

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/dedup
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/resume/saver
import support/log_capture
import support/signed_event

/// テスト用の保存の操作。受け取った一覧を `saves` へ送るだけで、`fail` なら常に
/// 失敗する。
fn recording_save(
  saves: process.Subject(List(#(String, Int))),
  fail: Bool,
) -> fn(List(#(String, Int))) -> Result(Nil, String) {
  fn(points: List(#(String, Int))) {
    process.send(saves, points)
    case fail {
      True -> Error("save failed")
      False -> Ok(Nil)
    }
  }
}

/// ディスパッチャーが受け取ったイベントの再開点が、周期ごとに保存される。次の
/// 周期は変化が無いので保存されない。
pub fn received_events_are_saved_as_resume_points_test() {
  let dedup_name = process.new_name("test_dedup_resume_saver")
  let assert Ok(_dedup) =
    dedup.start(dedup_name, Nil, fn(targets, _event) { targets }, 64)
  let saves = process.new_subject()
  let assert Ok(_saver) =
    saver.start(
      fn() { dedup.points(dedup_name) },
      recording_save(saves, False),
      "resume_saver",
      50,
    )

  let event = signed_event.new(1, "note")
  named.send(dedup_name, dedup.Incoming("wss://a", event))

  assert process.receive(saves, 500) == Ok([#("wss://a", event.created_at)])
  assert process.receive(saves, 200) == Error(Nil)
}

/// 保存に失敗しても、状態は変わらないので次の周期にも同じ内容が届く。
pub fn a_failed_save_is_retried_on_the_next_interval_test() {
  let dedup_name = process.new_name("test_dedup_resume_saver_failing")
  let assert Ok(_dedup) =
    dedup.start(dedup_name, Nil, fn(targets, _event) { targets }, 64)
  let saves = process.new_subject()
  let assert Ok(_saver) =
    saver.start(
      fn() { dedup.points(dedup_name) },
      recording_save(saves, True),
      "resume_saver",
      50,
    )

  let event = signed_event.new(1, "note")
  named.send(dedup_name, dedup.Incoming("wss://a", event))

  assert process.receive(saves, 500) == Ok([#("wss://a", event.created_at)])
  assert process.receive(saves, 200) == Ok([#("wss://a", event.created_at)])
}

/// 失敗し始めた保存は、その旨と保存の周期を Warning で報告する。
pub fn save_report_warns_when_saving_starts_to_fail_test() {
  assert saver.save_report(False, Error("save failed"), 5000)
    == Some(#(
      log.Warning,
      "could not save resume points: save failed; retrying every 5000ms",
    ))
}

/// 失敗が続く間はログを出さない。
pub fn save_report_is_silent_while_saving_keeps_failing_test() {
  assert saver.save_report(True, Error("save failed"), 5000) == None
}

/// 失敗から復帰した保存は、その旨を Notice で報告する。
pub fn save_report_notes_when_saving_recovers_test() {
  assert saver.save_report(True, Ok(Nil), 5000)
    == Some(#(log.Notice, "resume points saved again"))
}

/// 成功が続く間はログを出さない。
pub fn save_report_is_silent_while_saving_succeeds_test() {
  assert saver.save_report(False, Ok(Nil), 5000) == None
}

/// 失敗し続ける保存は、失敗の始まりの 1 行だけを出す。
pub fn a_failing_save_is_reported_once_test() {
  let capture = log_capture.install()
  let saves = process.new_subject()
  let assert Ok(_saver) =
    saver.start(
      fn() { Ok(dict.from_list([#("wss://a", 1)])) },
      recording_save(saves, True),
      "resume_saver_reported_once",
      50,
    )

  assert process.receive(saves, 500) == Ok([#("wss://a", 1)])
  assert process.receive(saves, 500) == Ok([#("wss://a", 1)])
  assert process.receive(saves, 500) == Ok([#("wss://a", 1)])

  let reported =
    list.count(log_capture.lines(capture), fn(line) {
      string.contains(
        line,
        "[resume_saver_reported_once] could not save resume points",
      )
    })
  assert reported == 1
  log_capture.remove(capture)
}
