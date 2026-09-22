//// 実際のリレーの上で `plugin_api.fetch_with` を往復させる E2E。
////
//// `TEST_RELAY_URL` があるときだけ走る。PR の CI は渡すので走り、手元では未設定
//// ならスキップする。Postgres は使わない（バンカーは偽ストアで起動する）。

import envoy
import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/io
import gleam/option.{None, Some}
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{Loaded, StoredAccount}
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin_api
import nostr_no_su/random
import nostr_no_su/relay_client
import nostr_no_su/relay_list
import nostr_no_su/time
import support/nip46_client.{account_for}

/// 起動と再試行を待たせないための、読み込みの再試行の待ち時間。
const fixed_retry_delay = Backoff(initial_ms: 100, max_ms: 100)

/// 発行したイベントへの OK を待つ時間。
const ack_timeout_ms = 5000

/// リレーに書いたイベントが `fetch_with` で読み返せる。
pub fn fetch_event_returns_the_latest_event_from_the_relay_test() {
  use relay_url <- with_test_relay_url
  let signer = account_for(random.hex(32))
  let bunker_name = start_signed_in_bunker(signer)
  let relay_list_name = start_relay_list(relay_url)
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
  let bunker_name = start_signed_in_bunker(signer)
  let relay_list_name = start_relay_list(relay_url)

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account.pubkey_hex(signer)),
      dynamic.int(9999),
    )
    == Ok(atom.to_dynamic(atom.create("none")))
}

/// 偽のストアで、署名者 1 名を登録したバンカーを起動する。読み込みの完了を待って
/// 名前を返す。
fn start_signed_in_bunker(signer: Account) -> process.Name(bunker.Msg) {
  let name = process.new_name("plugin_fetch_relay_bunker")
  let stored = StoredAccount(account: signer, secret: "s3cret", label: "")
  let assert Ok(_started) =
    bunker.start(
      name,
      bunker.Settings(
        store: bunker.Store(
          load: fn() { Ok(bunker.Snapshot(Loaded([stored], []), [], [], [])) },
          insert: fn(_account) { Ok(Nil) },
          delete: fn(_signer) { Ok(Nil) },
          update_secret: fn(_signer, _secret) { Ok(Nil) },
          update_label: fn(_signer, _label) { Ok(Nil) },
          write: fn(_write) { Ok(Nil) },
        ),
        auth_url: None,
        retry_delay: fixed_retry_delay,
      ),
      fn() { Nil },
      fn(_relays) { Nil },
    )
  let assert Ok([_]) = bunker.accounts(name)
  name
}

/// `relay_url` を監視の用途で持つだけの一覧。`fetch_with` は URL しか使わないので
/// 接続アクターは起動しない（ダミーの名前を置くだけ）。
fn start_relay_list(relay_url: String) -> process.Name(relay_list.Msg) {
  let name = process.new_name("plugin_fetch_relay_relay_list")
  let assert Ok(_started) =
    relay_list.start(
      name,
      [
        relay_list.Entry(
          url: relay_url,
          monitor: Some(process.new_name("plugin_fetch_relay_dummy")),
          bunker: None,
        ),
      ],
      relay_list.Factories(
        monitor: process.new_name("plugin_fetch_relay_factory_monitor"),
        bunker: process.new_name("plugin_fetch_relay_factory_bunker"),
      ),
    )
  name
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
