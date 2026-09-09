//// Cross-relay event de-duplication. Every monitor connection feeds its
//// events through this actor, which dispatches each distinct event id to the
//// plugins exactly once. Relays redeliver events (multiple relays carry the
//// same event; reconnects replay stored events), so plugins must not see the
//// same id twice.
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

pub type Msg {
  /// Hand one received event to the plugins unless its id was seen before.
  Dispatch(event: Event)
}

type State {
  State(
    plugins: List(Plugin),
    capacity: Int,
    current: Set(String),
    previous: Set(String),
  )
}

/// Start the dispatcher for the given plugins, remembering at least
/// `capacity` recent event ids.
pub fn start(
  plugins: List(Plugin),
  capacity: Int,
) -> Result(Subject(Msg), actor.StartError) {
  actor.new(State(
    plugins: plugins,
    capacity: capacity,
    current: set.new(),
    previous: set.new(),
  ))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Drop events whose id is already remembered, dispatch the rest.
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Dispatch(incoming) = msg
  case seen(state, incoming.id) {
    True -> actor.continue(state)
    False -> {
      plugin.dispatch(state.plugins, incoming)
      actor.continue(remember(state, incoming.id))
    }
  }
}

/// Whether the id is in either generation of the window.
fn seen(state: State, id: String) -> Bool {
  set.contains(state.current, id) || set.contains(state.previous, id)
}

/// Add the id to the current generation, rotating generations once it is
/// full so the oldest ids are forgotten.
fn remember(state: State, id: String) -> State {
  let current = set.insert(state.current, id)
  case set.size(current) >= state.capacity {
    True -> State(..state, previous: current, current: set.new())
    False -> State(..state, current: current)
  }
}
