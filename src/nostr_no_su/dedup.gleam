//// Cross-relay event de-duplication: a pure sliding `Window` of recent event
//// ids plus a thin actor that runs the plugins for the ids the window
//// accepts. Relays redeliver events (multiple relays carry the same event;
//// reconnects replay stored events), so plugins must not see the same id
//// twice.
////
//// Memory is bounded with a two-generation window: once the current
//// generation reaches `capacity` ids it becomes the previous generation and
//// a fresh one is started, so between `capacity` and `2 * capacity` recent
//// ids are remembered at any time.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result
import gleam/set.{type Set}
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}

/// The remembered ids, in two generations so the oldest can be dropped
/// wholesale once the window is full.
pub opaque type Window {
  Window(capacity: Int, current: Set(String), previous: Set(String))
}

/// An empty window remembering at least `capacity` ids.
pub fn new(capacity: Int) -> Window {
  Window(capacity: capacity, current: set.new(), previous: set.new())
}

/// Record an id, rotating generations once the current one is full.
/// `Error(Nil)` when the window already holds the id.
pub fn insert(window: Window, id: String) -> Result(Window, Nil) {
  case set.contains(window.current, id) || set.contains(window.previous, id) {
    True -> Error(Nil)
    False -> {
      let current = set.insert(window.current, id)
      case set.size(current) >= window.capacity {
        True -> Ok(Window(..window, previous: current, current: set.new()))
        False -> Ok(Window(..window, current: current))
      }
    }
  }
}

pub type Msg {
  /// An event received on one of the monitor connections.
  Incoming(event: Event)
}

type State {
  State(plugins: List(Plugin), window: Window)
}

/// Start the dispatcher for the given plugins, remembering at least
/// `capacity` recent event ids.
pub fn start(
  plugins: List(Plugin),
  capacity: Int,
) -> Result(Subject(Msg), actor.StartError) {
  actor.new(State(plugins: plugins, window: new(capacity)))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Run the plugins for events the window has not seen, drop the rest.
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Incoming(incoming) = msg
  case insert(state.window, incoming.id) {
    Error(Nil) -> actor.continue(state)
    Ok(window) -> {
      plugin.dispatch(state.plugins, incoming)
      actor.continue(State(..state, window: window))
    }
  }
}
