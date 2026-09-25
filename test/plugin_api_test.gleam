//// `plugin_api.publish_with`・`fetch_with`・`fetch_events_with` のテストに、
//// 取得で届くイベントを絞る `handle_incoming` のテストと、取得の接続の閉じ方の
//// テスト（`support/frame_server` の偽リレー）を加えたもの。経路のテストは
//// バンカーと監視・バンカー用途の偽リレー接続を直接組み立て、名前を渡す経路を
//// 叩く。リレーへ実際に REQ を送るテストはループバックの
//// WebSocket のリレー（`support/loopback_relay`）で REQ を数える。
//// `handle_incoming` のテストは `Received` の値を直接渡して `reply` の合図を
//// 見る（`install` はこのモジュールの対象外で、
//// `publish_event_without_install_returns_the_reason_test`・
//// `fetch_event_without_install_returns_the_reason_test`・
//// `fetch_events_without_install_returns_the_reason_test` の 3 件だけが
//// persistent_term を読む経路を確かめる。どのテストも `install` を呼ばないため、
//// 実行順によらず「置いていない」状態が保たれる）。

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/nostr/filter.{Filter}
import nostr_no_su/nostr/message
import nostr_no_su/plugin_api
import nostr_no_su/relay_client
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import support/app_tree.{start_bunker_signed_in_as, start_relay_list}
import support/frame_server
import support/loopback_relay
import support/nip46_client.{account_for}
import support/signed_event

/// テスト用の署名者の秘密鍵（16 進）。
const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

/// 2 人目の署名者の秘密鍵（16 進）。複数の公開鍵の取得のテストに使う。
const second_signer_key = "0000000000000000000000000000000000000000000000000000000000000043"

/// 登録しない鍵。未登録の公開鍵のテストに使う。
const other_key = "0000000000000000000000000000000000000000000000000000000000000077"

/// 接続の再接続の待ち時間。テストの間は再接続させないよう長く取る。
const long_reconnect_delay = Backoff(initial_ms: 60_000, max_ms: 60_000)

/// 接続アクターが接続を試みた結果の合図。
type Signal {
  Connected
  Refused
}

/// 署名者 1 名を登録したバンカーを起動し、読み込みの完了を待って名前を返す。
fn start_signed_in_bunker() -> Name(bunker.Msg) {
  start_bunker_signed_in_as([account_for(signer_key)])
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
      stable_after_ms: relay_connection.default_stable_after_ms,
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

/// テスト用の署名者の公開鍵（16 進）を、プラグイン境界の値にしたもの。
fn signer_pubkey() -> Dynamic {
  dynamic.string(account_for(signer_key) |> account.pubkey_hex)
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
      signer_pubkey(),
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
      signer_pubkey(),
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
      signer_pubkey(),
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
      signer_pubkey(),
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
      signer_pubkey(),
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
      signer_pubkey(),
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
    [matching.pubkey],
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
    plugin_api.handle_incoming(received, [wanted.pubkey], 0, reply)
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
      signer_pubkey(),
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
      signer_pubkey(),
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
      signer_pubkey(),
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
      signer_pubkey(),
      dynamic.int(0),
    )
    == Error("no monitor relay is connected")
}

/// `install` を呼ぶ前は、置いていない理由を返す。
pub fn fetch_event_without_install_returns_the_reason_test() {
  assert plugin_api.fetch_event(dynamic.string("x"), dynamic.int(0))
    == Error("the plugin API is not installed")
}

/// 複数の公開鍵の取得は、リレー 1 本につき接続 1 本・REQ 1 件にまとめる（REQ の
/// 後に届くのは、閉じるときのその購読の CLOSE だけ）。REQ の
/// `authors` は登録済みの公開鍵を問い合わせた順で重複を除いたもの、`limit` は
/// その件数。各公開鍵の要素は、その作者の `created_at` が最大の 1 件か、未登録
/// なら理由を持つ `Error`。
pub fn fetch_events_sends_one_req_per_relay_test() {
  let signer_a = account_for(signer_key)
  let signer_b = account_for(second_signer_key)
  let pubkey_a = account.pubkey_hex(signer_a)
  let pubkey_b = account.pubkey_hex(signer_b)
  let pubkey_c = account.pubkey_hex(account_for(other_key))
  let bunker_name = start_bunker_signed_in_as([signer_a, signer_b])
  let assert Ok(a_100) = engine.sign_as(signer_a, 0, [], "a", 100)
  let assert Ok(b_50) = engine.sign_as(signer_b, 0, [], "b", 50)
  let assert Ok(b_80) = engine.sign_as(signer_b, 0, [], "b", 80)
  let frames_a = process.new_subject()
  let frames_b = process.new_subject()
  let connections_a = process.new_subject()
  let connections_b = process.new_subject()
  let relay_a =
    loopback_relay.start_fetch_relay(frames_a, connections_a, [a_100, b_50])
  let relay_b =
    loopback_relay.start_fetch_relay(frames_b, connections_b, [b_80])
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(
        url: relay_a.url,
        monitor: Some(process.new_name("test_plugin_api_fetch_a")),
        bunker: None,
      ),
      relay_list.Entry(
        url: relay_b.url,
        monitor: Some(process.new_name("test_plugin_api_fetch_b")),
        bunker: None,
      ),
    ])

  let result =
    plugin_api.fetch_events_with(
      bunker_name,
      relay_list_name,
      dynamic.list([
        dynamic.string(pubkey_a),
        dynamic.string(pubkey_b),
        dynamic.string(pubkey_c),
      ]),
      dynamic.int(0),
    )

  assert result
    == Ok([
      Ok(event.to_map(a_100)),
      Ok(event.to_map(b_80)),
      Error("account is not registered"),
    ])
  let expected_req =
    message.encode_client_message(message.Req(
      plugin_api.fetch_subscription_id,
      Filter(
        ..filter.new(),
        authors: Some([pubkey_a, pubkey_b]),
        kinds: Some([0]),
        limit: Some(2),
      ),
    ))
  let expected_close =
    message.encode_client_message(message.Close(
      plugin_api.fetch_subscription_id,
    ))
  assert process.receive(connections_a, 2000) == Ok(Nil)
  assert process.receive(frames_a, 2000) == Ok(expected_req)
  assert process.receive(frames_a, 2000) == Ok(expected_close)
  assert process.receive(connections_a, 200) == Error(Nil)
  assert process.receive(frames_a, 200) == Error(Nil)
  assert process.receive(connections_b, 2000) == Ok(Nil)
  assert process.receive(frames_b, 2000) == Ok(expected_req)
  assert process.receive(frames_b, 2000) == Ok(expected_close)
  assert process.receive(connections_b, 200) == Error(Nil)
  assert process.receive(frames_b, 200) == Error(Nil)

  loopback_relay.stop_relay(relay_a)
  loopback_relay.stop_relay(relay_b)
}

/// 登録済みの公開鍵が 1 件も無い問い合わせは、リレーの一覧を引かずに要素ごとの
/// 結果を返す（登録されていない一覧の名前でも失敗しない）。空のリストは
/// `Ok([])`。
pub fn fetch_events_answers_unregistered_pubkeys_without_asking_relays_test() {
  let bunker_name = start_signed_in_bunker()
  let unregistered =
    process.new_name("test_plugin_api_fetch_events_missing_relay_list")

  assert plugin_api.fetch_events_with(
      bunker_name,
      unregistered,
      dynamic.list([
        dynamic.string(account_for(other_key) |> account.pubkey_hex),
      ]),
      dynamic.int(0),
    )
    == Ok([Error("account is not registered")])
  assert plugin_api.fetch_events_with(
      bunker_name,
      unregistered,
      dynamic.list([]),
      dynamic.int(0),
    )
    == Ok([])
}

/// `pubkeys` が文字列のリストでないときは専用の理由を返す。
pub fn fetch_events_rejects_pubkeys_that_are_not_a_list_of_strings_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.fetch_events_with(
      bunker_name,
      relay_list_name,
      dynamic.string("not-a-list"),
      dynamic.int(0),
    )
    == Error("pubkeys must be a List of Strings")
  assert plugin_api.fetch_events_with(
      bunker_name,
      relay_list_name,
      dynamic.list([dynamic.int(1)]),
      dynamic.int(0),
    )
    == Error("pubkeys must be a List of Strings")
}

/// `kind` が整数でないときは専用の理由を返す。
pub fn fetch_events_rejects_a_kind_that_is_not_an_int_test() {
  let bunker_name = start_signed_in_bunker()
  let relay_list_name = start_relay_list([])

  assert plugin_api.fetch_events_with(
      bunker_name,
      relay_list_name,
      dynamic.list([
        signer_pubkey(),
      ]),
      dynamic.string("not-an-int"),
    )
    == Error("kind must be an Int")
}

/// `install` を呼ぶ前は、置いていない理由を返す。
pub fn fetch_events_without_install_returns_the_reason_test() {
  assert plugin_api.fetch_events(dynamic.list([]), dynamic.int(0))
    == Error("the plugin API is not installed")
}

/// `fetch_with` の使い捨ての接続は、集め終えた後に購読の CLOSE と WebSocket の
/// close フレーム（状態コード 1000）を送って閉じる。
pub fn fetch_event_closes_the_subscription_and_the_websocket_test() {
  let bunker_name = start_signed_in_bunker()
  let frames = process.new_subject()
  let url =
    frame_server.start(frames, fn(text) {
      case string.starts_with(text, "[\"REQ\"") {
        True -> ["[\"EOSE\",\"nostr-no-su-plugin-fetch\"]"]
        False -> []
      }
    })
  let relay_list_name =
    start_relay_list([
      relay_list.Entry(
        url: url,
        monitor: Some(process.new_name("test_plugin_api_fetch_frame_relay")),
        bunker: None,
      ),
    ])

  assert plugin_api.fetch_with(
      bunker_name,
      relay_list_name,
      signer_pubkey(),
      dynamic.int(0),
    )
    == Ok(atom.to_dynamic(atom.create("none")))

  let assert Ok(frame_server.Frame(1, req)) = process.receive(frames, 2000)
  let assert Ok(req_text) = bit_array.to_string(req)
  assert string.starts_with(req_text, "[\"REQ\",\"nostr-no-su-plugin-fetch\",")
  assert process.receive(frames, 2000)
    == Ok(frame_server.Frame(
      1,
      bit_array.from_string("[\"CLOSE\",\"nostr-no-su-plugin-fetch\"]"),
    ))
  assert process.receive(frames, 2000) == Ok(frame_server.Frame(8, <<1000:16>>))
}
