import gleam/list
import nostr_no_su/dedup.{type Window}

/// ウィンドウが新規として受理した id を、渡した順に並べたもの。
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

/// 繰り返し現れる id は最初の 1 回だけ受理される。
pub fn duplicates_are_accepted_once_test() {
  assert accepted(dedup.new(100), ["a", "a", "b", "a", "b", "c"])
    == ["a", "b", "c"]
}

/// ウィンドウから外れた id は再び受理される。
pub fn old_ids_are_forgotten_once_capacity_is_exceeded_test() {
  // capacity 1 では挿入のたびに現在の世代が埋まるため、ある id は世代交代した
  // 後にもう 1 つ別の id が届いた時点で忘れられる。
  assert accepted(dedup.new(1), ["a", "b", "a"]) == ["a", "b", "a"]
}

/// 前世代へ移った id も、引き続き重複排除の対象になる。
pub fn recent_ids_survive_a_generation_rotation_test() {
  // capacity 2 では "a" と "b" が前世代へ移り、その後も拒否される。
  assert accepted(dedup.new(2), ["a", "b", "c", "a", "b", "c"])
    == ["a", "b", "c"]
}
