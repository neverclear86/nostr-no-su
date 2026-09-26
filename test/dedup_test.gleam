//// `dedup` アクターのテスト。`Incoming` の重複排除と配送、`since` / `points` /
//// `adding_account` の応答と、落とした件数から出すログ行（`record_rejection`）を
//// 確かめる。`window` と `resume` の純粋なロジック自体はそれぞれの
//// テストで確かめている。

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

/// 同じリレーの 1 件目は `Some`（本文は `dropped events outside the monitor
/// subscriptions: <件数> so far` の形）、2 件目は `None`、別のリレーの 1 件目は
/// `Some`。件数 9、19、999 の一覧に足すと、10 は `Some`、20 は `None`、1000 は
/// `Some`。
pub fn record_rejection_test() {
  let assert #(after_first, Some(first_line)) =
    dedup.record_rejection(dict.new(), "wss://a")
  assert first_line
    == "dropped events outside the monitor subscriptions: 1 so far"

  let assert #(after_second, None) =
    dedup.record_rejection(after_first, "wss://a")

  // 別のリレーは独立に 1 件目から数える。
  let assert #(_after_third, Some(third_line)) =
    dedup.record_rejection(after_second, "wss://b")
  assert third_line
    == "dropped events outside the monitor subscriptions: 1 so far"

  // 9、19、999 件の一覧に足すと、10 と 1000 は行が出て 20 は出ない。
  let counts =
    dict.from_list([#("wss://a", 9), #("wss://b", 19), #("wss://c", 999)])
  let assert #(_ten, Some(ten_line)) = dedup.record_rejection(counts, "wss://a")
  assert ten_line
    == "dropped events outside the monitor subscriptions: 10 so far"
  let assert #(_twenty, None) = dedup.record_rejection(counts, "wss://b")
  let assert #(_thousand, Some(thousand_line)) =
    dedup.record_rejection(counts, "wss://c")
  assert thousand_line
    == "dropped events outside the monitor subscriptions: 1000 so far"
}
