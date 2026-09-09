import gleam/erlang/process.{type Pid}
import gleam/http
import gleam/option.{Some}
import gleam/otp/actor
import nostr_no_su/relay_client

/// Start a linked actor that never stops on its own, standing in for a
/// healthy relay connection.
fn spawn_idle_connection() -> Pid {
  let assert Ok(started) =
    actor.new(Nil)
    |> actor.on_message(fn(state, _msg: Nil) { actor.continue(state) })
    |> actor.start
  started.pid
}

/// A failed `start` leaves an EXIT from its linked child in the mailbox. The
/// wait must skip it instead of reporting the live connection as dead, which
/// would make the reconnect loop stack up a second connection.
pub fn stale_exit_from_a_failed_start_is_skipped_test() {
  let live = process.new_subject()
  let returned = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    // Nothing listens on this port, so the handshake fails and the linked
    // connection actor exits, leaving an EXIT message behind.
    let assert Error(_) =
      relay_client.start("ws://127.0.0.1:1", fn() { [] }, fn(_event) { Nil })
    let pid = spawn_idle_connection()
    process.send(live, pid)
    relay_client.wait_until_dead(pid)
    process.send(returned, Nil)
  })
  let assert Ok(pid) = process.receive(live, 2000)
  assert process.receive(returned, 200) == Error(Nil)
  assert process.is_alive(pid)
  process.kill(pid)
  assert process.receive(returned, 2000) == Ok(Nil)
}

/// The wait returns once the connection it was given actually dies.
pub fn wait_returns_when_the_connection_dies_test() {
  let live = process.new_subject()
  let returned = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let pid = spawn_idle_connection()
    process.send(live, pid)
    relay_client.wait_until_dead(pid)
    process.send(returned, Nil)
  })
  let assert Ok(pid) = process.receive(live, 2000)
  process.kill(pid)
  assert process.receive(returned, 2000) == Ok(Nil)
}

/// Only the leading scheme is stripped, not later occurrences of "://".
pub fn label_strips_only_the_scheme_test() {
  assert relay_client.label("ws://127.0.0.1:7777") == "127.0.0.1:7777"
  assert relay_client.label("wss://relay.example/wss://x")
    == "relay.example/wss://x"
  assert relay_client.label("relay.example") == "relay.example"
}

/// `wss` becomes the https request stratus turns back into a TLS socket.
pub fn to_request_maps_wss_to_https_test() {
  let assert Ok(req) = relay_client.to_request("wss://relay.example/path")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
  assert req.path == "/path"
}

/// `ws` becomes a plain http request, port and all.
pub fn to_request_maps_ws_to_http_test() {
  let assert Ok(req) = relay_client.to_request("ws://127.0.0.1:7777")
  assert req.scheme == http.Http
  assert req.host == "127.0.0.1"
  assert req.port == Some(7777)
}

/// Any other scheme is passed through untouched.
pub fn to_request_leaves_other_schemes_alone_test() {
  let assert Ok(req) = relay_client.to_request("https://relay.example")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
}
