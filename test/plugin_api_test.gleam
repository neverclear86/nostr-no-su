//// `plugin_api.publish_with` と `fetch_with` のテストに、取得で届くイベントを
//// 絞る `handle_incoming` のテストを加えたもの。経路のテストはバンカーと監視・
//// バンカー用途の偽リレー接続を直接組み立て、名前を渡す経路を叩き、
//// `handle_incoming` のテストは `Received` の値を直接渡して `reply` の合図を見る
//// （`install` はこのモジュールの対象外で、
//// `publish_event_without_install_returns_the_reason_test`
//// と `fetch_event_without_install_returns_the_reason_test` の 2 件だけが
//// persistent_term を読む経路を確かめる。どのテストも `install` を呼ばないため、
//// 実行順によらず「置いていない」状態が保たれる）。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{Loaded, StoredAccount}
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin_api
import nostr_no_su/relay_client
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import support/nip46_client.{account_for}
import support/signed_event

/// テスト用の署名者の秘密鍵（16 進）。
const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

/// 登録しない鍵。未登録の公開鍵のテストに使う。
const other_key = "0000000000000000000000000000000000000000000000000000000000000077"

/// 起動と再試行を待たせないための、読み込みの再試行の待ち時間。
const fixed_retry_delay = Backoff(initial_ms: 100, max_ms: 100)

/// 接続の再接続の待ち時間。テストの間は再接続させないよう長く取る。
const long_reconnect_delay = Backoff(initial_ms: 60_000, max_ms: 60_000)

/// 接続アクターが接続を試みた結果の合図。
type Signal {
  Connected
  Refused
}

/// 署名者 1 名を登録したバンカーを起動し、読み込みの完了を待って名前を返す。
fn start_signed_in_bunker() -> Name(bunker.Msg) {
  let name = process.new_name("test_plugin_api_bunker")
  let stored =
    StoredAccount(account: account_for(signer_key), secret: "s3cret", label: "")
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
  // 読み込みの完了を待つ。`bunker_test.gleam` と同じ理由で `accounts` を使う。
  let assert Ok([_]) = bunker.accounts(name)
  name
}

/// リレーへの接続を開いたことにする偽ソケット。送信されたイベントを
/// `published` へ転送する。
fn spawn_socket(published: Subject(event.Event)) -> relay_connection.Socket {
  let pid = process.spawn(fn() { process.sleep_forever() })
  relay_connection.Socket(
    pid: pid,
    publish: fn(sent) { process.send(published, sent) },
    resubscribe: fn() { Nil },
  )
}

/// 常に接続に成功する connect 関数。
fn connects(
  ready: Subject(Signal),
  published: Subject(event.Event),
) -> relay_connection.Connector {
  fn() {
    let socket = spawn_socket(published)
    process.send(ready, Connected)
    Ok(socket)
  }
}

/// 常に拒否される connect 関数。ソケットを持たない接続を作る。
fn refuses(ready: Subject(Signal)) -> relay_connection.Connector {
  fn() {
    process.send(ready, Refused)
    Error("connection refused")
  }
}

/// 指定した名前と connect 関数で接続アクターを起動する。
fn start_connection(
  name: Name(relay_connection.Msg),
  connect: relay_connection.Connector,
) -> Pid {
  let assert Ok(started) =
    relay_connection.start(relay_connection.Settings(
      name: name,
      relay: "wss://relay.test",
      connect: connect,
      on_connect: fn(_socket) { Nil },
      on_disconnect: fn() { Nil },
      reconnect_delay: long_reconnect_delay,
    ))
  started.pid
}

/// 生きたソケットを持つ監視の用途の接続を 1 本起動する。
fn start_connected_monitor(
  published: Subject(event.Event),
) -> Name(relay_connection.Msg) {
  let ready = process.new_subject()
  let name = process.new_name("test_plugin_api_relay")
  start_connection(name, connects(ready, published))
  let assert Ok(Connected) = process.receive(ready, 1000)
  name
}

/// 一覧を持つだけのリレー一覧アクターを起動する。factory は使わないので
/// ダミーの名前でよい。
fn start_relay_list(entries: List(relay_list.Entry)) -> Name(relay_list.Msg) {
  let name = process.new_name("test_plugin_api_relay_list")
  let assert Ok(_started) =
    relay_list.start(
      name,
      entries,
      relay_list.Factories(
        monitor: process.new_name("test_plugin_api_factory_monitor"),
        bunker: process.new_name("test_plugin_api_factory_bunker"),
      ),
    )
  name
}

/// `kind` / `tags` / `content` を持つ、プラグイン境界の draft の map。
fn valid_draft() -> Dynamic {
  dynamic.properties([
    #(dynamic.string("kind"), dynamic.int(1)),
    #(dynamic.string("tags"), dynamic.list([])),
    #(dynamic.string("content"), dynamic.string("hello")),
  ])
}

/// 公開鍵とアカウントが署名済みで、1 本以上の監視接続へ届く。戻り値の `id` が
/// 署名済みイベントと一致する。
pub fn publish_event_sends_the_signed_event_to_every_monitor_connection_test() {
  let bunker_name = start_signed_in_bunker()
  let published_a = process.new_subject()
  let published_b = process.new_subject()
  let relay_a = start_connected_monitor(published_a)
  let relay_b = start_connected_monitor(published_b)
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(url: "wss://a", monitor: Some(relay_a), bunker: None),
      relay_list.Entry(url: "wss://b", monitor: Some(relay_b), bunker: None),
    ])

  let assert Ok(result) =
    plugin_api.publish_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      valid_draft(),
    )
  let assert Ok(decoded) = event.from_map(result)
  assert decoded.pubkey == account_for(signer_key) |> account.pubkey_hex
  let assert Ok(_verified) = event.verify(decoded)

  let assert Ok(sent_a) = process.receive(published_a, 1000)
  let assert Ok(sent_b) = process.receive(published_b, 1000)
  assert sent_a.id == decoded.id
  assert sent_b.id == decoded.id
}

/// バンカーの用途だけの接続には届かない。
pub fn publish_event_does_not_send_to_bunker_connections_test() {
  let bunker_name = start_signed_in_bunker()
  let published_monitor = process.new_subject()
  let published_bunker = process.new_subject()
  let monitor_relay = start_connected_monitor(published_monitor)
  let bunker_relay_name = process.new_name("test_plugin_api_bunker_relay")
  start_connection(
    bunker_relay_name,
    connects(process.new_subject(), published_bunker),
  )
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(
        url: "wss://m",
        monitor: Some(monitor_relay),
        bunker: None,
      ),
      relay_list.Entry(
        url: "wss://b",
        monitor: None,
        bunker: Some(bunker_relay_name),
      ),
    ])

  let assert Ok(_result) =
    plugin_api.publish_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      valid_draft(),
    )

  let assert Ok(_sent) = process.receive(published_monitor, 1000)
  assert process.receive(published_bunker, 200) == Error(Nil)
}

/// 未登録の公開鍵は理由を返し、どの接続にも届かない。
pub fn publish_event_rejects_an_unregistered_pubkey_test() {
  let bunker_name = start_signed_in_bunker()
  let published = process.new_subject()
  let monitor_relay = start_connected_monitor(published)
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(
        url: "wss://a",
        monitor: Some(monitor_relay),
        bunker: None,
      ),
    ])

  assert plugin_api.publish_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(other_key) |> account.pubkey_hex),
      valid_draft(),
    )
    == Error("account is not registered")
  assert process.receive(published, 200) == Error(Nil)
}

/// `kind` が binary の記述は `Error` になり、理由に `"kind"` が入る。
pub fn publish_event_rejects_a_malformed_draft_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])
  let bad_draft =
    dynamic.properties([
      #(dynamic.string("kind"), dynamic.string("not-a-number")),
      #(dynamic.string("tags"), dynamic.list([])),
      #(dynamic.string("content"), dynamic.string("hello")),
    ])

  let assert Error(reason) =
    plugin_api.publish_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      bad_draft,
    )
  assert string.contains(reason, "kind")
}

/// `pubkey` が文字列でないときは専用の理由を返す。
pub fn publish_event_rejects_a_pubkey_that_is_not_a_string_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.publish_with(
      bunker_name,
      relay_list_name,
      dynamic.int(1),
      valid_draft(),
    )
    == Error("pubkey must be a String")
}

/// 登録されていない `Name` を渡すと理由を返す。
pub fn publish_event_rejects_when_the_relay_list_does_not_answer_test() {
  let bunker_name = start_signed_in_bunker()
  let unregistered = process.new_name("test_plugin_api_missing_relay_list")

  assert plugin_api.publish_with(
      bunker_name,
      unregistered,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      valid_draft(),
    )
    == Error("the relay list is not responding")
}

/// 監視の用途のリレーが一覧に無いときは理由を返す。
pub fn publish_event_rejects_when_no_monitor_relay_is_registered_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.publish_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      valid_draft(),
    )
    == Error("no monitor relay is registered")
}

/// 監視の用途のリレーはあるが、生きたソケットに渡せないときは理由を返す。
pub fn publish_event_rejects_when_no_monitor_relay_is_connected_test() {
  let bunker_name = start_signed_in_bunker()
  let ready = process.new_subject()
  let name = process.new_name("test_plugin_api_refusing_relay")
  start_connection(name, refuses(ready))
  let assert Ok(Refused) = process.receive(ready, 1000)
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(url: "wss://a", monitor: Some(name), bunker: None),
    ])

  assert plugin_api.publish_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      valid_draft(),
    )
    == Error("no monitor relay is connected")
}

/// `install` を呼ぶ前は、置いていない理由を返す。
pub fn publish_event_without_install_returns_the_reason_test() {
  assert plugin_api.publish_event(dynamic.string("x"), valid_draft())
    == Error("the plugin API is not installed")
}

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

  assert plugin_api.newest([oldest, first_newest, second_newest])
    == Some(first_newest)
  assert plugin_api.newest([]) == None
}

/// 問い合わせた `pubkey` と `kind` の両方に一致するイベントは `Found` になる。
pub fn fetch_event_keeps_an_event_matching_the_query_test() {
  let reply = process.new_subject()
  let matching = signed_event.new(0, "matching")

  plugin_api.handle_incoming(
    relay_client.ReceivedEvent("sub", signed_event.verified(matching)),
    matching.pubkey,
    0,
    reply,
  )

  assert process.receive(reply, 0) == Ok(plugin_api.Found(matching))
}

/// 問い合わせたものと違う kind のイベントは、作者が一致しても捨てる。
pub fn fetch_event_drops_an_event_with_a_different_kind_test() {
  let reply = process.new_subject()
  let other_kind = signed_event.new(1, "other kind")

  plugin_api.handle_incoming(
    relay_client.ReceivedEvent("sub", signed_event.verified(other_kind)),
    other_kind.pubkey,
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
    plugin_api.handle_incoming(received, wanted.pubkey, 0, reply)
  }

  handle(relay_client.ReceivedEvent("sub", signed_event.verified(attacker)))
  handle(relay_client.ReceivedEvent("sub", signed_event.verified(wanted)))

  // `Found` になるのは正しいイベントだけで、他人のイベントは届かない。
  assert process.receive(reply, 0) == Ok(plugin_api.Found(wanted))
  assert process.receive(reply, 0) == Error(Nil)
}

/// 未登録の公開鍵は理由を返す。
pub fn fetch_event_rejects_an_unregistered_pubkey_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(other_key) |> account.pubkey_hex),
      dynamic.int(0),
    )
    == Error("account is not registered")
}

/// `pubkey` が文字列でないときは専用の理由を返す。
pub fn fetch_event_rejects_a_pubkey_that_is_not_a_string_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.int(1),
      dynamic.int(0),
    )
    == Error("pubkey must be a String")
}

/// `kind` が整数でないときは専用の理由を返す。
pub fn fetch_event_rejects_a_kind_that_is_not_an_int_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      dynamic.string("not-an-int"),
    )
    == Error("kind must be an Int")
}

/// 登録されていない `Name` を渡すと理由を返す。
pub fn fetch_event_rejects_when_the_relay_list_does_not_answer_test() {
  let bunker_name = start_signed_in_bunker()
  let unregistered =
    process.new_name("test_plugin_api_fetch_missing_relay_list")

  assert plugin_api.fetch_with(
      bunker_name,
      unregistered,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      dynamic.int(0),
    )
    == Error("the relay list is not responding")
}

/// 監視の用途のリレーが一覧に無いときは理由を返す。
pub fn fetch_event_rejects_when_no_monitor_relay_is_registered_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      dynamic.int(0),
    )
    == Error("no monitor relay is registered")
}

/// 監視の用途のリレーはあるが、どの 1 本とも接続できないときは理由を返す。
pub fn fetch_event_rejects_when_no_monitor_relay_is_reachable_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(
        url: "ws://127.0.0.1:1",
        monitor: Some(process.new_name("test_plugin_api_fetch_unreachable")),
        bunker: None,
      ),
    ])

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      dynamic.string(account_for(signer_key) |> account.pubkey_hex),
      dynamic.int(0),
    )
    == Error("no monitor relay is connected")
}

/// `install` を呼ぶ前は、置いていない理由を返す。
pub fn fetch_event_without_install_returns_the_reason_test() {
  assert plugin_api.fetch_event(dynamic.string("x"), dynamic.int(0))
    == Error("the plugin API is not installed")
}
