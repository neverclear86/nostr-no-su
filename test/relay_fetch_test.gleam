//// `relay_fetch` の、取得で届くイベントを絞る判断（`newest`・`handle_incoming`）の
//// テスト。接続とリレーは立てずに関数を直接呼ぶ。

import gleam/erlang/process
import gleam/option.{None, Some}
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/relay_client
import nostr_no_su/relay_fetch
import support/nip46_client.{account_for}
import support/signed_event

/// 問い合わせに含めない作者の秘密鍵（16 進）。
const other_key =
  "0000000000000000000000000000000000000000000000000000000000000077"

/// テスト用の最小のイベント。`newest` は `created_at` しか見ない。
fn event_with(id: String, created_at: Int) -> Event {
  Event(
    id: id,
    pubkey: "p",
    created_at: created_at,
    kind: 0,
    tags: [],
    content: "",
    sig: "",
  )
}

/// `created_at` が最大のものを返し、空リストでは `None`。同じ `created_at` が
/// 複数あるときはリストで先に現れたものを返す。
pub fn newest_picks_the_greatest_created_at_test() {
  let oldest = event_with("a", 10)
  let first_newest = event_with("b", 30)
  let second_newest = event_with("c", 30)

  assert relay_fetch.newest([oldest, first_newest, second_newest])
    == Some(first_newest)
  assert relay_fetch.newest([]) == None
}

/// 問い合わせた `pubkey` と `kind` の両方に一致するイベントは `Found` になる。
pub fn fetch_event_keeps_an_event_matching_the_query_test() {
  let reply = process.new_subject()
  let matching = signed_event.new(0, "matching")

  relay_fetch.handle_incoming(
    relay_client.ReceivedEvent("sub", signed_event.verified(matching)),
    [matching.pubkey],
    0,
    reply,
  )

  assert process.receive(reply, 0) == Ok(relay_fetch.Found(matching))
}

/// 問い合わせたものと違う kind のイベントは、作者が一致しても捨てる。
pub fn fetch_event_drops_an_event_with_a_different_kind_test() {
  let reply = process.new_subject()
  let other_kind = signed_event.new(1, "other kind")

  relay_fetch.handle_incoming(
    relay_client.ReceivedEvent("sub", signed_event.verified(other_kind)),
    [other_kind.pubkey],
    0,
    reply,
  )

  assert process.receive(reply, 0) == Error(Nil)
}

/// 他人の作者のイベントは捨てる。問い合わせた kind と同じ kind 0 で、正しい
/// イベントより大きい `created_at` を付けても `Found` にしないので、`newest`
/// の候補に入らない。
pub fn fetch_event_drops_an_event_from_another_author_test() {
  let reply = process.new_subject()
  let wanted = signed_event.new(0, "wanted")
  // 正しいイベントより大きい `created_at` の、他人の作者の kind 0。
  let assert Ok(attacker) =
    engine.sign_as(
      account_for(other_key),
      0,
      [],
      "attacker",
      wanted.created_at + 1,
    )
  let handle = fn(received) {
    relay_fetch.handle_incoming(received, [wanted.pubkey], 0, reply)
  }

  handle(relay_client.ReceivedEvent("sub", signed_event.verified(attacker)))
  handle(relay_client.ReceivedEvent("sub", signed_event.verified(wanted)))

  // `Found` になるのは正しいイベントだけで、他人のイベントは届かない。
  assert process.receive(reply, 0) == Ok(relay_fetch.Found(wanted))
  assert process.receive(reply, 0) == Error(Nil)
}
