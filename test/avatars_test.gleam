//// `avatars` のキャッシュと URL の検査のテスト。取得はほとんどを注入の `fetch` で、1 件だけループバックのリレーで確かめる。

import gleam/dict
import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/avatars
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/relay_list
import support/loopback_relay
import support/nip46_client.{account_for}
import support/poll

const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

const avatar_url = "https://x.test/a.png"

const fetch_failure = "no monitor relay is connected"

/// 作者 `pubkey`、`created_at`、`content` の kind 0。署名は検査しないので空。
fn metadata(pubkey: String, created_at: Int, content: String) -> Event {
  Event(id: "", pubkey:, created_at:, kind: 0, tags: [], content:, sig: "")
}

/// `picture` が `url` の kind 0 の content。
fn with_picture(url: String) -> String {
  json.object([#("picture", json.string(url))]) |> json.to_string
}

/// キャッシュのアクターを新しい名前で起動する。
fn start(ttl_ms: Int, retry_ms: Int) -> Name(avatars.Msg) {
  let name = process.new_name("test_avatars")
  let assert Ok(_started) = avatars.start(name, ttl_ms, retry_ms)
  name
}

/// 呼ばれるたびに渡された署名者を `calls` へ送り、`outcome` を返す取得。
fn recording(
  calls: Subject(List(String)),
  outcome: Result(List(Event), String),
) -> fn(List(String)) -> Result(List(Event), String) {
  fn(pubkeys) {
    process.send(calls, pubkeys)
    outcome
  }
}

/// 取得を、テストが開ける門で止める。取得を走らせるプロセスで作った門を `gates`
/// へ渡し、テストがそこへ `Nil` を送るまで戻らない。subject は所有するプロセスで
/// しか受信できないので、門はテストではなく呼び出し側で作る。
fn hold_until_released(gates: Subject(Subject(Nil))) -> Nil {
  let gate = process.new_subject()
  process.send(gates, gate)
  process.receive_forever(gate)
}

/// `https:` の URL をそのまま返す。
pub fn picture_accepts_an_https_url_test() {
  assert avatars.picture(metadata("a", 1, with_picture(avatar_url)))
    == Some(avatar_url)
}

/// `https:` 以外の scheme、host の無い `https://`、scheme の無い値は `None`。
pub fn picture_rejects_other_urls_test() {
  list.each(
    [
      "http://x.test/a.png",
      "data:image/png;base64,AAAA",
      "https://",
      "x.test/a.png",
      "javascript:alert(1)",
    ],
    fn(url) {
      assert avatars.picture(metadata("a", 1, with_picture(url))) == None
    },
  )
}

/// JSON でない、`picture` が無いか文字列でない content は `None`。
pub fn picture_ignores_content_without_a_picture_test() {
  list.each(["not json", "{}", "{\"picture\":1}", "[]"], fn(content) {
    assert avatars.picture(metadata("a", 1, content)) == None
  })
}

/// 1 回目は全署名者をまとめて取り、期限内の 2 回目は取らずに同じ辞書を返す。
pub fn pictures_fetch_each_pubkey_once_within_the_ttl_test() {
  let name = start(60_000, 60_000)
  let calls = process.new_subject()
  let fetch = recording(calls, Ok([metadata("a", 1, with_picture(avatar_url))]))
  let expected = dict.from_list([#("a", avatar_url)])

  assert avatars.pictures_with(name, ["a", "b"], fetch) == expected
  assert process.receive(calls, 100) == Ok(["a", "b"])
  assert avatars.pictures_with(name, ["a", "b"], fetch) == expected
  assert process.receive(calls, 100) == Error(Nil)
}

/// `ttl_ms` 0 では毎回取る。
pub fn pictures_fetch_again_after_the_ttl_test() {
  let name = start(0, 60_000)
  let calls = process.new_subject()
  let fetch = recording(calls, Ok([]))

  let _found = avatars.pictures_with(name, ["a"], fetch)
  let _found = avatars.pictures_with(name, ["a"], fetch)
  assert process.receive(calls, 100) == Ok(["a"])
  assert process.receive(calls, 100) == Ok(["a"])
}

/// 取得に失敗しても、前に取った URL を返し続ける。
pub fn pictures_keep_the_cached_picture_when_the_fetch_fails_test() {
  let name = start(0, 0)
  let failing = fn(_pubkeys) { Error(fetch_failure) }

  let _found =
    avatars.pictures_with(name, ["a"], fn(_pubkeys) {
      Ok([metadata("a", 1, with_picture(avatar_url))])
    })
  let _found = avatars.pictures_with(name, ["a"], failing)
  assert avatars.pictures_with(name, ["a"], failing)
    == dict.from_list([#("a", avatar_url)])
}

/// 間に合った取り直しで `picture` が無くなった署名者は、同じ描画から前の URL を返さない。
pub fn pictures_drop_a_removed_picture_in_the_same_lookup_test() {
  let name = start(0, 60_000)

  let _found =
    avatars.pictures_with(name, ["a"], fn(_pubkeys) {
      Ok([metadata("a", 1, with_picture(avatar_url))])
    })
  assert avatars.pictures_with(name, ["a"], fn(_pubkeys) {
      Ok([metadata("a", 2, "{}")])
    })
    == dict.new()
}

/// `retry_ms` 0 では、失敗の直後の描画で取り直す。
pub fn pictures_retry_after_a_failed_fetch_test() {
  let name = start(60_000, 0)
  let calls = process.new_subject()
  let fetch = recording(calls, Error(fetch_failure))

  let _found = avatars.pictures_with(name, ["a"], fetch)
  let _found = avatars.pictures_with(name, ["a"], fetch)
  assert process.receive(calls, 100) == Ok(["a"])
  assert process.receive(calls, 100) == Ok(["a"])
}

/// `retry_ms` が残っていれば、`ttl_ms` 0 でも失敗の直後の描画では取らない。
pub fn pictures_wait_before_retrying_a_failed_fetch_test() {
  let name = start(0, 60_000)
  let calls = process.new_subject()
  let fetch = recording(calls, Error(fetch_failure))

  let _found = avatars.pictures_with(name, ["a"], fetch)
  let _found = avatars.pictures_with(name, ["a"], fetch)
  assert process.receive(calls, 100) == Ok(["a"])
  assert process.receive(calls, 100) == Error(Nil)
}

/// 待ちの上限に間に合わなかった取得は空を返し、その結果は次の描画で出る。取得を
/// 門で止めて 1 回目が空を返した後に門を開け、取得を走らせたプロセスの終了
/// （結果を `Fetched` で送った後に来る）を待ってから 2 回目を引く。
pub fn pictures_keep_a_late_result_for_the_next_lookup_test() {
  let name = start(60_000, 60_000)
  let gates = process.new_subject()
  let gated = fn(_pubkeys) {
    hold_until_released(gates)
    Ok([metadata("a", 1, with_picture(avatar_url))])
  }

  assert avatars.pictures_with(name, ["a"], gated) == dict.new()
  let assert Ok(gate) = process.receive(gates, 2000)
  let assert Ok(pid) = process.subject_owner(gate)
  let monitor = process.monitor(pid)
  process.send(gate, Nil)
  assert process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    == Ok(process.ProcessDown(monitor, pid, process.Normal))

  assert avatars.pictures_with(name, ["a"], gated)
    == dict.from_list([#("a", avatar_url)])
  assert process.receive(gates, 0) == Error(Nil)
}

/// 監視の用途のリレーへ kind 0 を問い合わせ、署名者ごとに `created_at` が最大の 1 件の URL を返す。
/// kind 0 でないイベントは使わない。取得は `wait_ms` を超えうるので、URL が返るまで引き直す。
/// `retry_ms` 0 で、期限切れで失敗した取得も次の引き直しで取り直す。
pub fn pictures_ask_monitor_relays_for_the_newest_metadata_test() {
  let signer = account_for(signer_key)
  let pubkey = account.pubkey_hex(signer)
  let assert Ok(older) =
    engine.sign_as(signer, 0, [], with_picture("https://x.test/old.png"), 50)
  let assert Ok(newer) =
    engine.sign_as(signer, 0, [], with_picture("https://x.test/new.png"), 80)
  let assert Ok(note) =
    engine.sign_as(signer, 1, [], with_picture("https://x.test/note.png"), 90)
  let relay =
    loopback_relay.start_fetch_relay(
      process.new_subject(),
      process.new_subject(),
      [older, newer, note],
    )
  let relay_list_name = process.new_name("test_avatars_relay_list")
  let assert Ok(_started) =
    relay_list.start(
      relay_list_name,
      [
        relay_list.Entry(
          url: relay.url,
          monitor: Some(process.new_name("test_avatars_monitor")),
          bunker: None,
        ),
      ],
      relay_list.Factories(
        monitor: process.new_name("test_avatars_factory_monitor"),
        bunker: process.new_name("test_avatars_factory_bunker"),
        session: process.new_name("test_avatars_factory_session"),
      ),
    )

  let name = start(60_000, 0)
  assert poll.until(
    fn() {
      avatars.pictures(name, relay_list_name, [pubkey])
      == dict.from_list([#(pubkey, "https://x.test/new.png")])
    },
    10_000,
    50,
  )
  loopback_relay.stop_relay(relay)
}

/// アクターが居ないときは空の辞書を返し、取得しない。
pub fn pictures_without_the_cache_are_empty_test() {
  let calls = process.new_subject()

  assert avatars.pictures_with(
      process.new_name("test_avatars_missing"),
      ["a"],
      recording(calls, Ok([])),
    )
    == dict.new()
  assert process.receive(calls, 100) == Error(Nil)
}
