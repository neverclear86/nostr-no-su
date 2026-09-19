//// `dedup` アクターのテスト。`Incoming` の重複排除と配送、`since` / `points` /
//// `adding_account` の応答を確かめる。`dedup/window` と `dedup/resume` の純粋な
//// ロジック自体はそれぞれのテストで確かめている。

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import nostr_no_su/dedup
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import support/signed_event

/// 受け取ったイベントを渡した順に `delivered` へ送るだけの配送先を持つ
/// ディスパッチャーを起動する。
fn start_recording() -> #(process.Name(dedup.Msg), Subject(Event)) {
  let name = process.new_name("test_dedup")
  let delivered = process.new_subject()
  let assert Ok(_started) =
    dedup.start(
      name,
      delivered,
      fn(subject, event) {
        process.send(subject, event)
        subject
      },
      64,
    )
  #(name, delivered)
}

/// 同じ id のイベントは、別のリレーから届いても最初の 1 回しか配送しない。
pub fn a_duplicate_event_is_delivered_once_test() {
  let #(name, delivered) = start_recording()
  let event = signed_event.new(1, "note")

  named.send(name, dedup.Incoming("wss://a", event))
  named.send(name, dedup.Incoming("wss://b", event))

  assert process.receive(delivered, 500) == Ok(event)
  assert process.receive(delivered, 100) == Error(Nil)
}

/// id が異なるイベントはどちらも配送する。
pub fn distinct_events_are_both_delivered_test() {
  let #(name, delivered) = start_recording()
  let a = signed_event.new(1, "a")
  let b = signed_event.new(1, "b")

  named.send(name, dedup.Incoming("wss://a", a))
  named.send(name, dedup.Incoming("wss://a", b))

  assert process.receive(delivered, 500) == Ok(a)
  assert process.receive(delivered, 500) == Ok(b)
}

/// リレーの再開点は、そのリレーから受け取った直近のイベントの `created_at`。
/// 受け取っていないリレーは `None`。
pub fn since_reflects_the_latest_received_event_test() {
  let #(name, _delivered) = start_recording()
  assert dedup.since(name, "wss://a") == Ok(None)

  let event = signed_event.new(1, "note")
  named.send(name, dedup.Incoming("wss://a", event))

  assert dedup.since(name, "wss://a") == Ok(Some(event.created_at))
}

/// 保存用の再開点の写しには、受け取ったリレーぶんが入る。
pub fn points_lists_every_observed_relay_test() {
  let #(name, _delivered) = start_recording()
  let event = signed_event.new(1, "note")

  named.send(name, dedup.Incoming("wss://a", event))
  named.send(name, dedup.Incoming("wss://b", event))

  assert dedup.points(name)
    == Ok(
      dict.from_list([
        #("wss://a", event.created_at),
        #("wss://b", event.created_at),
      ]),
    )
}

/// アカウント追加の通知は、渡したリレーの再開点を未記録（`None`）から記録済みへ
/// 進める。
pub fn adding_account_sets_a_resume_point_for_its_relays_test() {
  let #(name, _delivered) = start_recording()
  assert dedup.since(name, "wss://a") == Ok(None)

  dedup.adding_account(name, ["wss://a"])

  let assert Ok(Some(_since)) = dedup.since(name, "wss://a")
}
