import gleam/erlang/process
import gleam/list
import nostr_no_su/dedup
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin.{type Plugin, Plugin}

/// A minimal event whose only meaningful field is its id.
fn test_event(id: String) -> Event {
  Event(
    id: id,
    pubkey: "pubkey",
    created_at: 0,
    kind: 1,
    tags: [],
    content: "",
    sig: "sig",
  )
}

/// A plugin that reports every event id it handles to the test process.
fn recorder(inbox: process.Subject(String)) -> Plugin {
  Plugin(name: "recorder", handle: fn(incoming: Event) {
    process.send(inbox, incoming.id)
  })
}

/// Send one event per id to the dispatcher, in order.
fn dispatch_all(subject: process.Subject(dedup.Msg), ids: List(String)) -> Nil {
  list.each(ids, fn(id) {
    process.send(subject, dedup.Dispatch(test_event(id)))
  })
}

/// Drain the ids the recorder plugin reported, in the order they arrived.
fn received_ids(inbox: process.Subject(String)) -> List(String) {
  case process.receive(inbox, 100) {
    Ok(id) -> [id, ..received_ids(inbox)]
    Error(_) -> []
  }
}

/// Repeated ids reach the plugins only the first time.
pub fn duplicates_are_dispatched_once_test() {
  let inbox = process.new_subject()
  let assert Ok(subject) = dedup.start([recorder(inbox)], 100)
  dispatch_all(subject, ["a", "a", "b", "a", "b", "c"])
  assert received_ids(inbox) == ["a", "b", "c"]
}

/// Ids that fall out of the window are dispatched again.
pub fn old_ids_are_forgotten_once_capacity_is_exceeded_test() {
  let inbox = process.new_subject()
  // Capacity 1: every insert fills the current generation, so an id is
  // forgotten as soon as one more distinct id arrives after it rotated out.
  let assert Ok(subject) = dedup.start([recorder(inbox)], 1)
  dispatch_all(subject, ["a", "b", "a"])
  assert received_ids(inbox) == ["a", "b", "a"]
}

/// Ids in the previous generation are still deduplicated.
pub fn recent_ids_survive_a_generation_rotation_test() {
  let inbox = process.new_subject()
  // Capacity 2: "a" and "b" rotate into the previous generation and are
  // still deduplicated afterwards.
  let assert Ok(subject) = dedup.start([recorder(inbox)], 2)
  dispatch_all(subject, ["a", "b", "c", "a", "b", "c"])
  assert received_ids(inbox) == ["a", "b", "c"]
}
