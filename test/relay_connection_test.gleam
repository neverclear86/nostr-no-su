import gleam/erlang/process.{type Pid, type Subject}
import nostr_no_su/relay_connection.{type Socket, Socket}

/// A short delay keeps the reconnect tests quick while staying long enough
/// to tell "scheduled" apart from "immediate".
const delay_ms = 300

/// What the fake connect function and `on_connect` report to the test.
type Report {
  /// A connection attempt that produced a live fake socket.
  Connected(socket: Pid)
  /// A connection attempt that the relay refused.
  Refused
  /// `on_connect` ran for a fresh socket.
  Rewired
}

/// A fake socket: an idle process linked to the connection actor, as the
/// stratus process would be. Killing it looks exactly like a disconnect.
fn spawn_socket() -> Socket {
  let pid = process.spawn(fn() { process.sleep_forever() })
  Socket(pid: pid, publish: fn(_event) { Nil })
}

/// A connect function that always hands back a fresh socket and reports it.
fn connects(reports: Subject(Report)) -> relay_connection.Open {
  fn() {
    let socket = spawn_socket()
    process.send(reports, Connected(socket.pid))
    Ok(socket)
  }
}

/// A connect function standing in for an unreachable relay.
fn refuses(reports: Subject(Report)) -> relay_connection.Open {
  fn() {
    process.send(reports, Refused)
    Error("connection refused")
  }
}

/// Start a connection actor with the given connect function, reporting each
/// rewiring, and stop it when the test ends.
fn start(reports: Subject(Report), connect: relay_connection.Open) -> Pid {
  let assert Ok(started) =
    relay_connection.start(relay_connection.Config(
      relay: "relay.test",
      connect: connect,
      on_connect: fn(_socket) { process.send(reports, Rewired) },
      reconnect_delay_ms: delay_ms,
    ))
  started.pid
}

/// Stop a connection actor. It is linked to the test process, so the exit
/// has to be unlinked before it kills the test along with the actor.
fn stop(actor: Pid) -> Nil {
  process.unlink(actor)
  process.kill(actor)
}

/// Whether the process is gone within the given number of milliseconds.
fn died_within(pid: Pid, timeout_ms: Int) -> Bool {
  case process.is_alive(pid), timeout_ms <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(10)
      died_within(pid, timeout_ms - 10)
    }
  }
}

/// The actor connects on start, without being asked to.
pub fn connects_on_start_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(_socket)) = process.receive(reports, 1000)
  assert process.receive(reports, 1000) == Ok(Rewired)
  stop(actor)
}

/// A dead socket does not take the actor with it: it reconnects after the
/// configured delay, and rewires the caller onto the new socket.
pub fn reconnects_after_the_socket_dies_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  process.kill(socket)
  // Nothing happens before the delay has passed...
  assert process.receive(reports, delay_ms / 3) == Error(Nil)
  // ...and then a second connection is made and rewired.
  let assert Ok(Connected(_reconnected)) = process.receive(reports, 2000)
  assert process.receive(reports, 1000) == Ok(Rewired)
  assert process.is_alive(actor)
  stop(actor)
}

/// A relay that refuses the connection is retried, not given up on.
pub fn keeps_retrying_after_a_failed_connect_test() {
  let reports = process.new_subject()
  let actor = start(reports, refuses(reports))
  assert process.receive(reports, 1000) == Ok(Refused)
  assert process.receive(reports, 2000) == Ok(Refused)
  assert process.receive(reports, 2000) == Ok(Refused)
  assert process.is_alive(actor)
  stop(actor)
}

/// A failed handshake leaves an exit from the stratus child that never
/// became the socket. It must be ignored rather than read as a disconnect or
/// as the supervisor shutting the actor down.
pub fn exit_from_an_unrelated_process_is_ignored_test() {
  let reports = process.new_subject()
  let connect = fn() {
    // A linked process that dies before the socket is handed over.
    process.kill(process.spawn(fn() { process.sleep_forever() }))
    let socket = spawn_socket()
    process.send(reports, Connected(socket.pid))
    Ok(socket)
  }
  let actor = start(reports, connect)
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  // Nothing reconnects: the exit was not read as the socket dying.
  assert process.receive(reports, delay_ms * 2) == Error(Nil)
  // Still watching the right process, so killing the socket does reconnect.
  assert process.is_alive(actor)
  process.kill(socket)
  let assert Ok(Connected(_reconnected)) = process.receive(reports, 2000)
  stop(actor)
}

/// A normal exit is not passed along the link to the socket, so the actor
/// stops it by hand on the way out.
pub fn a_normal_exit_stops_the_socket_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  // A normal exit signal from the process the actor is linked to: this test.
  process.send_exit(actor)
  assert died_within(actor, 1000)
  assert died_within(socket, 1000)
}

/// The actor terminates when the process it is linked to does, so a
/// supervisor's shutdown is not something it can sit through.
pub fn stops_when_its_parent_exits_test() {
  let started = process.new_subject()
  let parent =
    process.spawn_unlinked(fn() {
      let reports = process.new_subject()
      process.send(started, start(reports, connects(reports)))
      process.sleep_forever()
    })
  let assert Ok(actor) = process.receive(started, 1000)
  process.kill(parent)
  assert died_within(actor, 1000)
}
