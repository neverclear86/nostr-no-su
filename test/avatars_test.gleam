//// `avatars` のキャッシュの判定（`claim` と `record`）、URL の検査、アクターの配線のテスト。
//// 判定は `now` を渡して純粋に確かめ、アクターは注入の `fetch` で、1 件だけループバックの
//// リレーで確かめる。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/avatars
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/relay_list
import support/app_tree.{signer_key, start_relay_list}
import support/hold
import support/loopback_relay
import support/nip46_client.{account_for}
import support/poll

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

/// URL の無い、`refresh_at` に取り直す時刻を置いた記録。
fn claimed_at(refresh_at: Int) -> avatars.Cached {
  avatars.Cached(picture: None, refresh_at:)
}

/// `cache` に対して `now` に `claim` したときの、署名者 "a" の `stale`。
fn stale_at(
  cache: Dict(String, avatars.Cached),
  now: Int,
  ttl_ms: Int,
) -> List(String) {
  let #(claimed, _cache) = avatars.claim(cache, ["a"], now, ttl_ms)
  claimed.stale
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

/// 記録の無い署名者は古く、取得中にした記録は `ttl_ms` の後に取り直す時刻が来る。
pub fn claim_marks_an_unknown_pubkey_stale_and_pushes_its_refresh_time_test() {
  let #(claimed, cache) = avatars.claim(dict.new(), ["a", "b"], 1000, 500)

  assert claimed == avatars.Claimed(known: dict.new(), stale: ["a", "b"])
  assert cache
    == dict.from_list([#("a", claimed_at(1500)), #("b", claimed_at(1500))])
}

/// 取り直す時刻（`refresh_at`）の 1ms 前は古くなく、その時刻から古い。`ttl_ms` 0 は毎回古い。
pub fn claim_goes_stale_from_the_refresh_time_test() {
  let cache = dict.from_list([#("a", claimed_at(1500))])

  list.each([#(1499, []), #(1500, ["a"]), #(1501, ["a"])], fn(row) {
    let #(now, stale) = row
    assert stale_at(cache, now, 500) == stale
  })
  let #(_claimed, claimed_cache) = avatars.claim(dict.new(), ["a"], 1000, 0)
  assert stale_at(claimed_cache, 1000, 0) == ["a"]
}

/// 古い署名者にも前の URL を `known` に返し、取得中にした記録にも残す。古くない署名者の記録は変えない。
/// 同じ署名者を何度渡しても `stale` は 1 回。
pub fn claim_keeps_the_previous_picture_of_a_stale_pubkey_test() {
  let cache =
    dict.from_list([
      #("a", avatars.Cached(picture: Some(avatar_url), refresh_at: 100)),
      #("b", avatars.Cached(picture: Some(avatar_url), refresh_at: 9000)),
    ])

  let #(claimed, claimed_cache) =
    avatars.claim(cache, ["a", "a", "b", "c"], 200, 500)

  assert claimed
    == avatars.Claimed(
      known: dict.from_list([#("a", avatar_url), #("b", avatar_url)]),
      stale: ["a", "c"],
    )
  assert claimed_cache
    == dict.from_list([
      #("a", avatars.Cached(picture: Some(avatar_url), refresh_at: 700)),
      #("b", avatars.Cached(picture: Some(avatar_url), refresh_at: 9000)),
      #("c", claimed_at(700)),
    ])
}

/// 取得に成功すると、URL の無い署名者の URL を捨て、`refresh_at` は取得中にしたときのまま残す。
/// 取得の対象でない署名者は変えない。
pub fn record_a_fetch_replaces_the_pictures_and_keeps_the_refresh_time_test() {
  let old =
    avatars.Cached(picture: Some("https://x.test/old.png"), refresh_at: 1500)
  let cache = dict.from_list([#("a", old), #("b", old), #("c", old)])

  assert avatars.record(
      cache,
      ["a", "b"],
      Ok(dict.from_list([#("a", avatar_url)])),
      1100,
      500,
      300,
    )
    == dict.from_list([
      #("a", avatars.Cached(picture: Some(avatar_url), refresh_at: 1500)),
      #("b", claimed_at(1500)),
      #("c", old),
    ])
}

/// 取得に失敗すると、前の URL を残し、`retry_ms` の後に取り直す。記録の無い署名者も同じ。
pub fn record_a_failed_fetch_keeps_the_picture_and_retries_after_retry_ms_test() {
  let cache =
    dict.from_list([
      #("a", avatars.Cached(picture: Some(avatar_url), refresh_at: 1500)),
    ])

  assert avatars.record(cache, ["a", "b"], Error(Nil), 1100, 500, 300)
    == dict.from_list([
      #("a", avatars.Cached(picture: Some(avatar_url), refresh_at: 1400)),
      #("b", claimed_at(1400)),
    ])
}

/// 取得中にした記録が無い署名者の結果（アクターの再起動の後に届いた結果）は、`ttl_ms` の後に
/// 取り直す記録として入れる。
pub fn record_a_result_without_a_claim_expires_after_ttl_ms_test() {
  assert avatars.record(
      dict.new(),
      ["a"],
      Ok(dict.from_list([#("a", avatar_url)])),
      1100,
      500,
      300,
    )
    == dict.from_list([
      #("a", avatars.Cached(picture: Some(avatar_url), refresh_at: 1600)),
    ])
}

/// 時計の上で `ttl_ms` が過ぎると、同じ署名者をまた取る。時計を読んで渡す配線を確かめるので、
/// 取り直しが起きるまで引き直す。
pub fn pictures_fetch_again_once_the_ttl_has_elapsed_test() {
  let name = start(20, 60_000)
  let calls = process.new_subject()
  let fetch = recording(calls, Ok([]))

  let _found = avatars.pictures_with(name, ["a"], fetch)
  assert process.receive(calls, 100) == Ok(["a"])
  assert poll.until(
    fn() {
      let _found = avatars.pictures_with(name, ["a"], fetch)
      process.receive(calls, 0) == Ok(["a"])
    },
    2000,
    20,
  )
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

/// 失敗した取得は `retry_ms` の後に取り直し、`ttl_ms` 0 でも失敗の直後の描画では取らない。
pub fn pictures_wait_before_retrying_a_failed_fetch_test() {
  let name = start(0, 60_000)
  let calls = process.new_subject()
  let fetch = recording(calls, Error(fetch_failure))

  let _found = avatars.pictures_with(name, ["a"], fetch)
  let _found = avatars.pictures_with(name, ["a"], fetch)
  assert process.receive(calls, 100) == Ok(["a"])
  assert process.receive(calls, 100) == Error(Nil)
}

/// 取得中の署名者は、取得が終わる前の別の描画では取らない。取得を門で止めて 1 回目が空を返した後に
/// 2 回目を引く。
pub fn pictures_do_not_fetch_a_pubkey_already_being_fetched_test() {
  let name = start(60_000, 60_000)
  let gates = process.new_subject()
  let calls = process.new_subject()
  let gated = fn(_pubkeys) {
    hold.until_released(gates)
    Ok([])
  }

  assert avatars.pictures_with(name, ["a"], gated) == dict.new()
  assert avatars.pictures_with(name, ["a"], recording(calls, Ok([])))
    == dict.new()
  assert process.receive(calls, 100) == Error(Nil)

  let assert Ok(gate) = process.receive(gates, 2000)
  process.send(gate, Nil)
}

/// 待ちの上限に間に合わなかった取得は空を返し、その結果は次の描画で出る。取得を
/// 門で止めて 1 回目が空を返した後に門を開け、取得を走らせたプロセスの終了
/// （結果を `Fetched` で送った後に来る）を待ってから 2 回目を引く。
pub fn pictures_keep_a_late_result_for_the_next_lookup_test() {
  let name = start(60_000, 60_000)
  let gates = process.new_subject()
  let gated = fn(_pubkeys) {
    hold.until_released(gates)
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
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(
        url: relay.url,
        monitor: Some(process.new_name("test_avatars_monitor")),
        bunker: None,
      ),
    ])

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
