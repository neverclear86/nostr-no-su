//// One supervised connection to a relay.
////
//// The actor owns the socket process: it opens the connection from its own
//// loop and, when the socket dies, schedules a reconnect instead of dying
//// with it, so a flapping relay never consumes the supervisor's restart
//// intensity. That requires trapping exits, which also turns the exit signal
//// a supervisor sends when shutting the tree down into a message: `handle`
//// tells the two apart by pid and re-raises the latter.

import gleam/erlang/process.{type ExitMessage, type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/nostr/event.{type Event}

/// How long to wait before reconnecting after a lost or refused connection.
pub const default_reconnect_delay_ms = 5000

/// A live connection: the process to watch for disconnects, and the way to
/// send events out on it.
pub type Socket {
  Socket(pid: Pid, publish: fn(Event) -> Nil)
}

/// How the socket is opened. Injected so the reconnect logic can be tested
/// without a websocket.
pub type Open =
  fn() -> Result(Socket, String)

/// Everything one connection needs: a label for its log lines, how to open
/// the socket, what to do with each fresh one, and how long to back off.
pub type Config {
  Config(
    relay: String,
    connect: Open,
    on_connect: fn(Socket) -> Nil,
    reconnect_delay_ms: Int,
  )
}

pub type Msg {
  /// Open the socket. Sent by the initialiser and by the reconnect timer.
  Connect
  /// A linked process exited: the socket, or the supervisor shutting us down.
  Exited(exit: ExitMessage)
}

type State {
  State(config: Config, parent: Pid, self: Subject(Msg), socket: Option(Pid))
}

/// A child specification for the supervision tree. The default worker
/// shutdown timeout of 5000ms applies: `connect` blocks the actor while it
/// runs, so an injected one that can block for longer than that would be
/// killed mid-handshake instead of shutting down cleanly.
pub fn supervised(config: Config) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(config) })
}

/// Start the connection actor. It starts even when the relay is unreachable,
/// so one bad URL cannot fail the whole subtree.
pub fn start(config: Config) -> actor.StartResult(Subject(Msg)) {
  // `start` runs in the process that links the actor, which under a
  // supervisor is the supervisor itself: exits from it mean "shut down".
  let parent = process.self()
  actor.new_with_initialiser(1000, fn(self) { initialise(config, parent, self) })
  |> actor.on_message(handle)
  |> actor.start
}

/// Trap exits so a dying socket arrives as a message, and queue the first
/// connection attempt: connecting here would block the supervisor's start.
fn initialise(
  config: Config,
  parent: Pid,
  self: Subject(Msg),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  process.trap_exits(True)
  process.send(self, Connect)
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select_trapped_exits(Exited)
  State(config: config, parent: parent, self: self, socket: None)
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

/// Open the socket, or react to the death of a linked process.
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Connect -> open(state)
    Exited(exit) ->
      case exit.pid == state.parent, Some(exit.pid) == state.socket {
        True, _ -> shutdown(state, exit.reason)
        _, True -> reconnect(state, "disconnected")
        // Neither: a failed handshake leaves an exit from the stratus child
        // that never became our socket, which is not a reason to react.
        False, False -> actor.continue(state)
      }
  }
}

/// Try to open the socket, handing the fresh one to `on_connect`, and
/// schedule a retry when the relay is unreachable.
fn open(state: State) -> actor.Next(State, Msg) {
  case state.config.connect() {
    Ok(socket) -> {
      state.config.on_connect(socket)
      actor.continue(State(..state, socket: Some(socket.pid)))
    }
    Error(reason) -> reconnect(state, "failed to connect: " <> reason)
  }
}

/// Log why the socket is gone and schedule the next attempt.
fn reconnect(state: State, reason: String) -> actor.Next(State, Msg) {
  let delay = state.config.reconnect_delay_ms
  io.println(
    "[relay "
    <> state.config.relay
    <> "] "
    <> reason
    <> "; reconnecting in "
    <> int.to_string(delay)
    <> "ms",
  )
  let _ = process.send_after(state.self, delay, Connect)
  actor.continue(State(..state, socket: None))
}

/// Terminate on the exit signal that asked us to. The actor loop treats a
/// trapped exit as an ordinary message, so the signal has to be re-raised
/// untrapped to exit with the reason the supervisor waits for; the socket
/// then dies with us through its link.
fn shutdown(
  state: State,
  reason: process.ExitReason,
) -> actor.Next(State, Msg) {
  process.trap_exits(False)
  case reason {
    // A normal exit is not passed along a link, so the socket would outlive
    // the actor. Supervisors ask with `shutdown` or `kill`, so this is only
    // reached when something else stops the actor.
    process.Normal -> stop_socket(state)
    process.Killed -> process.kill(process.self())
    process.Abnormal(reason) ->
      process.send_abnormal_exit(process.self(), reason)
  }
  actor.stop()
}

/// Take the socket down for the exit reasons that will not do it themselves.
fn stop_socket(state: State) -> Nil {
  case state.socket {
    Some(socket) -> process.kill(socket)
    None -> Nil
  }
}
