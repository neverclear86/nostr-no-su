import gleam/erlang/atom
import gleam/erlang/process.{type Down, type Name, type Pid, type Subject}
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/crypto/nip44
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin
import nostr_no_su/relay_connection
import nostr_no_su/time

const secret = "s3cr3t-token"

const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

/// 偽リレーがテストへ報告する内容。
type Report {
  /// 接続が開かれた。所有するアクター、監視対象のソケットプロセス、そして実際の
  /// ソケットと同じようにサブツリーへイベントを流し込むハンドラーを伴う。
  Opened(connection: Pid, socket: Pid, deliver: fn(Event) -> Nil)
  /// イベントが送信された。送信に使われたソケットを伴う。
  Published(socket: Pid, event: Event)
}

/// 偽リレー。接続をすべて報告し、WebSocket の代わりに監視用の待機プロセスを
/// ツリーへ渡し、送信されたイベントをテストへ転送する。
fn fake_open(reports: Subject(Report)) -> app.Open {
  fn(_relay_url, _subscriptions, handle_event) {
    let socket = process.spawn(fn() { process.sleep_forever() })
    process.send(reports, Opened(process.self(), socket, handle_event))
    Ok(
      relay_connection.Socket(pid: socket, publish: fn(published) {
        process.send(reports, Published(socket, published))
      }),
    )
  }
}

/// ツリーを起動する。起動できなければテストを失敗させる。
fn start_tree(spec: app.Spec) -> Pid {
  let assert Ok(started) = app.start(spec)
  started.pid
}

/// 偽リレー 1 本の上でバンカーだけを動かすツリー。
fn start_bunker_tree(reports: Subject(Report), name: Name(bunker.Msg)) -> Pid {
  start_tree(app.Spec(
    monitor: None,
    bunker: Some(
      app.Bunker(
        name: name,
        engine: engine.new([#(account_for(signer_key), secret)]),
        relay_urls: ["ws://relay.test"],
        subscriptions: fn() { [] },
      ),
    ),
    storage: None,
    open: fake_open(reports),
    reconnect_delay_ms: 100,
  ))
}

/// 親プロセスと同じ方法でツリーを停止する。ルートスーパーバイザーは exit
/// シグナルをツリー全体の順序立った停止に変換する。先にリンクを解除するのは、
/// 停止に失敗してもテストプロセスを巻き込まないようにするため。
fn stop_tree(tree: Pid) -> Nil {
  process.unlink(tree)
  process.send_exit(tree)
}

/// ツリーが次に開く接続を待ち、そのアクターが落ち着くのを待つ。システム
/// メッセージに応答した時点で、サブツリー先頭のアクターへの配線は完了している。
fn await_connection(reports: Subject(Report)) -> Report {
  let assert Ok(Opened(connection, socket, deliver)) =
    process.receive(reports, 2000)
  let _state = system.get_state(connection)
  Opened(connection, socket, deliver)
}

/// 監視中のプロセスが停止するのを待つ。
fn await_down(monitor: process.Monitor, timeout_ms: Int) -> Result(Down, Nil) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(timeout_ms)
}

/// テスト用 16 進鍵に対応するアカウント。
fn account_for(key_hex: String) -> Account {
  let assert Ok(account) = account.from_hex(key_hex)
  account
}

/// 実際のクライアントと同じ手順で暗号化・署名した `connect` リクエスト。
fn connect_request(id: String) -> Event {
  let signer = account_for(signer_key)
  request(
    id,
    "connect",
    "[\"" <> signer.pubkey_hex <> "\",\"" <> secret <> "\"]",
  )
}

/// 指定した params を持つ JSON-RPC リクエスト。実際のクライアントと同じく
/// 署名者宛に暗号化し、クライアントの鍵で署名する。
fn request(id: String, method: String, params_json: String) -> Event {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body =
    "{\"id\":\""
    <> id
    <> "\",\"method\":\""
    <> method
    <> "\",\"params\":"
    <> params_json
    <> "}"
  let assert Ok(key) = nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(content) = nip44.encrypt(body, key)
  let unsigned =
    Event(
      id: "",
      pubkey: client.pubkey_hex,
      created_at: time.now_seconds(),
      kind: 24_133,
      tags: [["p", signer.pubkey_hex]],
      content: content,
      sig: "",
    )
  let assert Ok(signed) = event.finalize(unsigned, client.privkey)
  signed
}

/// 応答イベントの JSON-RPC 本文。クライアントが読むのと同じ形で取り出す。
fn response_body(response: Event) -> String {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let assert Ok(key) = nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(text) = nip44.decrypt(response.content, key)
  text
}

/// 指定した id を持つ最小限のイベント。ディスパッチャーは id しか見ない。
fn event_with_id(id: String) -> Event {
  Event(
    id: id,
    pubkey: "",
    created_at: 0,
    kind: 1,
    tags: [],
    content: "",
    sig: "",
  )
}

/// ある接続で届いたリクエストには、その接続で応答する。
pub fn bunker_replies_on_its_connection_test() {
  let reports = process.new_subject()
  let tree = start_bunker_tree(reports, process.new_name("test_bunker"))
  let assert Opened(_connection, socket, deliver) = await_connection(reports)
  deliver(connect_request("c1"))
  let assert Ok(Published(answered_on, response)) =
    process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(response), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// バンカーアクターを kill しても復帰できる。スーパーバイザーが同じ名前で代替を
/// 起動し、その後ろで再起動した接続が publisher を登録し直すため、往復が再び
/// 成立する。
pub fn bunker_survives_being_killed_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_connection, _socket, _deliver) = await_connection(reports)
  let assert Ok(killed) = process.named(name)
  process.kill(killed)

  let assert Opened(_connection, socket, deliver) = await_connection(reports)
  let assert Ok(restarted) = process.named(name)
  assert restarted != killed
  deliver(connect_request("c2"))
  let assert Ok(Published(answered_on, response)) =
    process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(response), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// バンカーの後ろで再起動する接続は、スーパーバイザーが要求した理由で終了する。
/// exit を trap したまま何もしないと、スーパーバイザーの停止タイムアウトで kill
/// されるまで動き続けてしまう。
pub fn connections_shut_down_when_the_bunker_restarts_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(connection, socket, _deliver) = await_connection(reports)
  let connection_monitor = process.monitor(connection)
  let socket_monitor = process.monitor(socket)
  let assert Ok(killed) = process.named(name)
  process.kill(killed)

  let assert Ok(process.ProcessDown(reason: reason, ..)) =
    await_down(connection_monitor, 1000)
  assert reason == process.Abnormal(atom.to_dynamic(atom.create("shutdown")))
  // ソケットは接続アクターが保持するリンクを通じて一緒に落ちる。
  let assert Ok(_socket_down) = await_down(socket_monitor, 1000)
  stop_tree(tree)
}

/// セッション状態は接続ではなくバンカーアクターが保持するため、再接続後も残る。
/// クライアントは再度 connect しなくても認可されたままになる。
pub fn session_survives_a_reconnect_test() {
  let reports = process.new_subject()
  let tree = start_bunker_tree(reports, process.new_name("test_bunker"))
  let assert Opened(_connection, socket, deliver) = await_connection(reports)
  deliver(connect_request("c1"))
  let assert Ok(Published(answered_on, ack)) = process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(ack), "\"result\":\"ack\"")

  process.kill(socket)
  let assert Opened(_connection, reconnected, deliver) =
    await_connection(reports)
  assert reconnected != socket
  // 2 度目の `connect` は送らない。pong が返るのは認可済みクライアントだけで、
  // 応答は死んだソケットを置き換えた新しいソケットから出ていく。
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(pong_on, pong)) = process.receive(reports, 2000)
  assert pong_on == reconnected
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  stop_tree(tree)
}

/// 監視接続で受信したイベントはプラグインに届き、経由するディスパッチャーを kill
/// した後も届き続ける。
pub fn monitor_dispatcher_survives_being_killed_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let name = process.new_name("test_dedup")
  let tree =
    start_tree(app.Spec(
      monitor: Some(
        app.Monitor(
          name: name,
          plugins: [
            plugin.Plugin(name: "test", handle: process.send(seen, _)),
          ],
          dedup_capacity: 8,
          relay_urls: ["ws://relay.test"],
          subscriptions: fn() { [] },
        ),
      ),
      bunker: None,
      storage: None,
      open: fake_open(reports),
      reconnect_delay_ms: 100,
    ))
  let assert Opened(_connection, _socket, deliver) = await_connection(reports)
  deliver(event_with_id("first"))
  assert process.receive(seen, 2000) == Ok(event_with_id("first"))

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_connection, _socket, deliver) = await_connection(reports)
  deliver(event_with_id("second"))
  assert process.receive(seen, 2000) == Ok(event_with_id("second"))
  stop_tree(tree)
}
