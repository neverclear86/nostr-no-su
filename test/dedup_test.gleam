import gleam/list
import nostr_no_su/dedup.{type Window}

/// The ids the window accepted as new, in the order they were offered.
fn accepted(window: Window, ids: List(String)) -> List(String) {
  let #(_window, seen) =
    list.fold(ids, #(window, []), fn(acc, id) {
      let #(window, seen) = acc
      case dedup.insert(window, id) {
        Ok(next) -> #(next, [id, ..seen])
        Error(Nil) -> #(window, seen)
      }
    })
  list.reverse(seen)
}

/// Repeated ids are accepted only the first time.
pub fn duplicates_are_accepted_once_test() {
  assert accepted(dedup.new(100), ["a", "a", "b", "a", "b", "c"])
    == ["a", "b", "c"]
}

/// Ids that fall out of the window are accepted again.
pub fn old_ids_are_forgotten_once_capacity_is_exceeded_test() {
  // Capacity 1: every insert fills the current generation, so an id is
  // forgotten as soon as one more distinct id arrives after it rotated out.
  assert accepted(dedup.new(1), ["a", "b", "a"]) == ["a", "b", "a"]
}

/// Ids that rotated into the previous generation are still deduplicated.
pub fn recent_ids_survive_a_generation_rotation_test() {
  // Capacity 2: "a" and "b" rotate into the previous generation and are
  // still rejected afterwards.
  assert accepted(dedup.new(2), ["a", "b", "c", "a", "b", "c"])
    == ["a", "b", "c"]
}
