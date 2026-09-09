//// A thin actor around the pure `engine`. It holds the session state across
//// relay reconnections (the relay client is restarted on every disconnect, so
//// session state cannot live there). All decision logic stays in `engine`.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/otp/actor
import gleam/result
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/time

pub type Msg {
  /// A kind 24133 event received on one of the bunker connections.
  Incoming(event: Event)
  /// Install the function used to publish response events on one relay
  /// connection. Each bunker relay loop re-sends this after reconnecting so
  /// responses go out on its live socket. Responses are published on every
  /// bunker relay: the client listens on all `relay=` hints of the URI, and
  /// duplicate deliveries are its problem to dedupe (as ours are the
  /// engine's), so any live relay is enough for the round-trip.
  SetPublisher(relay_url: String, publish: fn(Event) -> Nil)
}

type State {
  State(engine: engine.Engine, publishers: Dict(String, fn(Event) -> Nil))
}

/// Start the bunker actor with the given engine state.
pub fn start(initial: engine.Engine) -> Result(Subject(Msg), actor.StartError) {
  actor.new(State(engine: initial, publishers: dict.new()))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

/// Register a publisher, or run one incoming event through the engine and
/// broadcast the response it produced.
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    SetPublisher(relay_url, publish) ->
      actor.continue(
        State(
          ..state,
          publishers: dict.insert(state.publishers, relay_url, publish),
        ),
      )
    Incoming(incoming) -> {
      let #(next, outcome) =
        engine.handle_event(state.engine, incoming, time.now_seconds())
      case outcome {
        engine.Reply(response) ->
          dict.each(state.publishers, fn(_relay_url, publish) {
            publish(response)
          })
        engine.Duplicate -> Nil
        engine.Ignore(reason) -> io.println("[bunker] ignored: " <> reason)
      }
      actor.continue(State(..state, engine: next))
    }
  }
}
