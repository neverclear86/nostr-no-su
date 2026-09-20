//// `dedup/resume_saver` のテスト。ディスパッチャーは本物を起動し、DB の代わりに
//// メモリ上の保存の操作を渡す。

import gleam/erlang/process
import nostr_no_su/dedup
import nostr_no_su/dedup/resume_saver
import nostr_no_su/named
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
    resume_saver.start(
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
    resume_saver.start(
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
