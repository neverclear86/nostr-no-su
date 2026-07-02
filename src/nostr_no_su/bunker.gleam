//// A thin actor around the pure `engine`. It holds the session state across
//// relay reconnections (the relay client is restarted on every disconnect, so
//// session state cannot live there) and adapts the engine to the plugin
//// interface. All decision logic stays in `engine`.

import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/otp/actor
import gleam/result
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin, Plugin}
import nostr_no_su/time

pub type Msg {
  Incoming(event: Event)
  /// Install the function used to publish response events. The main loop
  /// re-sends this after each reconnect so responses go out on the live socket.
  SetPublisher(publish: fn(Event) -> Nil)
}

type State {
  State(engine: engine.Engine, publish: fn(Event) -> Nil)
}

pub fn start(initial: engine.Engine) -> Result(Subject(Msg), actor.StartError) {
  actor.new(State(engine: initial, publish: fn(_) { Nil }))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    SetPublisher(publish) -> actor.continue(State(..state, publish: publish))
    Incoming(incoming) -> {
      let #(next, outcome) =
        engine.handle_event(state.engine, incoming, time.now_seconds())
      case outcome {
        engine.Reply(response) -> state.publish(response)
        engine.Ignore(reason) -> io.println("[bunker] ignored: " <> reason)
      }
      actor.continue(State(..state, engine: next))
    }
  }
}

/// Adapt the bunker to the plugin interface: every monitored event is forwarded
/// to the actor as an `Incoming` message.
pub fn plugin(subject: Subject(Msg)) -> Plugin {
  Plugin(name: "bunker", handle: fn(incoming) {
    process.send(subject, Incoming(incoming))
  })
}
