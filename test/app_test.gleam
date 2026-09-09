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

/// What the fake relay reports back to the test.
type Report {
  /// A connection was opened: the actor that owns it, the socket process it
  /// watches, and the handler that feeds events into the subtree the way a
  /// real socket would.
  Opened(connection: Pid, socket: Pid, deliver: fn(Event) -> Nil)
  /// An event was published on the socket.
  Published(event: Event)
}

/// A fake relay: it reports every connection, hands the tree an idle process
/// to watch instead of a websocket, and forwards published events back.
fn fake_open(reports: Subject(Report)) -> app.Open {
  fn(_relay_url, _subscriptions, handle_event) {
    let socket = process.spawn(fn() { process.sleep_forever() })
    process.send(reports, Opened(process.self(), socket, handle_event))
    Ok(
      relay_connection.Socket(pid: socket, publish: fn(published) {
        process.send(reports, Published(published))
      }),
    )
  }
}

/// Start a tree, failing the test if it does not come up.
fn start_tree(spec: app.Spec) -> Pid {
  let assert Ok(started) = app.start(spec)
  started.pid
}

/// A tree running only the bunker, on one fake relay.
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
    open: fake_open(reports),
    reconnect_delay_ms: 100,
  ))
}

/// Stop a tree the way its parent would: an exit signal the root supervisor
/// turns into an orderly shutdown of the whole tree. The link is dropped
/// first so a failure to shut down cannot fail the test process with it.
fn stop_tree(tree: Pid) -> Nil {
  process.unlink(tree)
  process.send_exit(tree)
}

/// Wait for the next connection the tree opens, then let its actor settle:
/// once it answers a system message it has finished wiring itself to the
/// actor at the head of its subtree.
fn await_connection(reports: Subject(Report)) -> Report {
  let assert Ok(Opened(connection, socket, deliver)) =
    process.receive(reports, 2000)
  let _state = system.get_state(connection)
  Opened(connection, socket, deliver)
}

/// Wait for a monitored process to go down.
fn await_down(monitor: process.Monitor, timeout_ms: Int) -> Result(Down, Nil) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(timeout_ms)
}

/// The account for one of the hex test keys.
fn account_for(key_hex: String) -> Account {
  let assert Ok(account) = account.from_hex(key_hex)
  account
}

/// A `connect` request, encrypted and signed exactly as a client sends it.
fn connect_request(id: String) -> Event {
  let signer = account_for(signer_key)
  request(
    id,
    "connect",
    "[\"" <> signer.pubkey_hex <> "\",\"" <> secret <> "\"]",
  )
}

/// A JSON-RPC request with the given params, encrypted to the signer and
/// signed by the client, exactly as a client sends it.
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

/// The JSON-RPC body of a response event, as the client would read it.
fn response_body(response: Event) -> String {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let assert Ok(key) = nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(text) = nip44.decrypt(response.content, key)
  text
}

/// A minimal event with the given id: the dispatcher only looks at the id.
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

/// A request delivered on a connection is answered on it.
pub fn bunker_replies_on_its_connection_test() {
  let reports = process.new_subject()
  let tree = start_bunker_tree(reports, process.new_name("test_bunker"))
  let assert Opened(_connection, _socket, deliver) = await_connection(reports)
  deliver(connect_request("c1"))
  let assert Ok(Published(response)) = process.receive(reports, 2000)
  assert string.contains(response_body(response), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// Killing the bunker actor is survivable: the supervisor starts a
/// replacement under the same name, and the connection restarted behind it
/// re-installs its publisher, so the round trip works again.
pub fn bunker_survives_being_killed_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_connection, _socket, _deliver) = await_connection(reports)
  let assert Ok(killed) = process.named(name)
  process.kill(killed)

  let assert Opened(_connection, _socket, deliver) = await_connection(reports)
  let assert Ok(restarted) = process.named(name)
  assert restarted != killed
  deliver(connect_request("c2"))
  let assert Ok(Published(response)) = process.receive(reports, 2000)
  assert string.contains(response_body(response), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// The connections restarted behind the bunker exit with the reason the
/// supervisor asks for. Trapping exits without acting on them would instead
/// leave them running until the supervisor's shutdown timeout kills them.
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
  // The socket goes with it, through the link the connection actor keeps.
  let assert Ok(_socket_down) = await_down(socket_monitor, 1000)
  stop_tree(tree)
}

/// Session state lives in the bunker actor, not in the connection, so it
/// survives a reconnect: the client stays authorized without connecting
/// again.
pub fn session_survives_a_reconnect_test() {
  let reports = process.new_subject()
  let tree = start_bunker_tree(reports, process.new_name("test_bunker"))
  let assert Opened(_connection, socket, deliver) = await_connection(reports)
  deliver(connect_request("c1"))
  let assert Ok(Published(ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")

  process.kill(socket)
  let assert Opened(_connection, _socket, deliver) = await_connection(reports)
  // No second `connect`: only an authorized client is answered with a pong.
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  stop_tree(tree)
}

/// Events received on a monitor connection reach the plugins, and keep doing
/// so after the dispatcher they pass through has been killed.
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
