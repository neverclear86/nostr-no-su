//// 実際のリレーの上で `plugin_api.fetch_with` と `fetch_events_with` を
//// 往復させる E2E。
////
//// `TEST_RELAY_URL` があるときだけ走る。PR の CI は渡すので走り、手元では未設定
//// ならスキップする。Postgres は使わない（バンカーは偽ストアで起動する）。

import envoy
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/io
import gleam/option.{None, Some}
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin_api
import nostr_no_su/random
import nostr_no_su/relay_client
import nostr_no_su/relay_list
import nostr_no_su/time
import support/app_tree.{start_bunker_signed_in_as, start_relay_list}
import support/nip46_client.{account_for}

/// 発行したイベントへの OK を待つ時間。
const ack_timeout_ms = 5000

/// リレーに書いたイベントが `fetch_with` で読み返せる。
pub fn fetch_event_returns_the_latest_event_from_the_relay_test() {
  use relay_url <- with_test_relay_url
  let signer = account_for(random.hex(32))
  let bunker_name = start_bunker_signed_in_as([signer])
  let relay_list_name = start_relay_list([monitor_entry(relay_url)])
  let published = seed_profile(relay_url, signer, "{\"name\":\"lina\"}")

  let assert Ok(result) =
    plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account.pubkey_hex(signer)),
      dynamic.int(0),
    )
  let assert Ok(decoded) = event.from_map(result)
  assert decoded.id == published.id
  assert decoded.content == "{\"name\":\"lina\"}"
}

/// 書いていない kind を問い合わせると `{ok, none}`。
pub fn fetch_event_returns_none_when_the_relay_has_no_event_test() {
  use relay_url <- with_test_relay_url
  let signer = account_for(random.hex(32))
  let bunker_name = start_bunker_signed_in_as([signer])
  let relay_list_name = start_relay_list([monitor_entry(relay_url)])

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account.pubkey_hex(signer)),
      dynamic.int(9999),
    )
    == Ok(atom.to_dynamic(atom.create("none")))
}

/// 複数の公開鍵の取得は、リレーにある作者ごとの最新の 1 件を、問い合わせた
/// 公開鍵の順に返す。イベントを書いていない登録アカウントは `{ok, none}`。
pub fn fetch_events_returns_the_latest_event_per_pubkey_from_the_relay_test() {
  use relay_url <- with_test_relay_url
  let signer_a = account_for(random.hex(32))
  let signer_b = account_for(random.hex(32))
  let signer_c = account_for(random.hex(32))
  let bunker_name = start_bunker_signed_in_as([signer_a, signer_b, signer_c])
  let relay_list_name = start_relay_list([monitor_entry(relay_url)])
  let published_a = seed_profile(relay_url, signer_a, "{\"name\":\"a\"}")
  let published_b = seed_profile(relay_url, signer_b, "{\"name\":\"b\"}")

  let assert Ok(results) =
    plugin_api.fetch_events_with(
      bunker_name,
      relay_list_name,
      dynamic.list([
        dynamic.string(account.pubkey_hex(signer_a)),
        dynamic.string(account.pubkey_hex(signer_b)),
        dynamic.string(account.pubkey_hex(signer_c)),
      ]),
      dynamic.int(0),
    )
  let assert [Ok(map_a), Ok(map_b), Ok(none_c)] = results
  let assert Ok(decoded_a) = event.from_map(map_a)
  let assert Ok(decoded_b) = event.from_map(map_b)
  assert decoded_a.id == published_a.id
  assert decoded_a.content == "{\"name\":\"a\"}"
  assert decoded_b.id == published_b.id
  assert decoded_b.content == "{\"name\":\"b\"}"
  assert none_c == atom.to_dynamic(atom.create("none"))
}

/// `relay_url` を監視の用途で持つ一覧の行。`fetch_with` は URL しか使わないので、
/// 接続アクターは起動せずダミーの名前を置く。
fn monitor_entry(relay_url: String) -> relay_list.Entry {
  relay_list.Entry(
    url: relay_url,
    monitor: Some(process.new_name("plugin_fetch_relay_dummy")),
    bunker: None,
  )
}

/// `relay_url` へ直接つなぎ、`signer` の名義で kind 0 を 1 件発行する。OK の受理を
/// 待ってから接続を閉じ、発行したイベントを返す。
fn seed_profile(relay_url: String, signer: Account, content: String) -> Event {
  let acks = process.new_subject()
  let assert Ok(connection) =
    relay_client.start(
      relay_url,
      fn() { Ok([]) },
      fn(_received) { Nil },
      fn(ack) { process.send(acks, ack) },
      None,
      relay_client.subscription_retry_delay,
      relay_client.keepalive_interval_ms,
    )
  let assert Ok(signed) =
    engine.sign_as(signer, 0, [], content, time.now_seconds())
  relay_client.publish(connection, signed)
  let assert Ok(ack) = process.receive(acks, ack_timeout_ms)
  assert ack.accepted

  let assert Ok(pid) = process.subject_owner(connection)
  process.unlink(pid)
  process.kill(pid)
  signed
}

/// 空でない `TEST_RELAY_URL` で `run` を呼ぶ。未設定ならスキップの 1 行を出す。
fn with_test_relay_url(run: fn(String) -> Nil) -> Nil {
  case envoy.get("TEST_RELAY_URL") {
    Ok(url) if url != "" -> run(url)
    _ ->
      io.println(
        "[plugin_fetch_relay] TEST_RELAY_URL is not set; skipping the integration test",
      )
  }
}
