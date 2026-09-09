//// The supervision tree.
////
//// ```
//// root (one_for_one)
//// |-- monitor (rest_for_one): dedup dispatcher, then one connection per relay
//// `-- bunker  (rest_for_one): bunker actor,     then one connection per relay
//// ```
////
//// Each subtree is `rest_for_one` so that a restart of the actor at its head
//// takes the connections behind it down too: they re-subscribe and re-install
//// their publisher on the way back up, which is how a restarted bunker gets
//// wired to live sockets again. The actors are named, so the connections
//// address them by name and never hold a subject for a dead process.

import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Builder} as supervisor
import gleam/result
import nostr_no_su/bunker
import nostr_no_su/bunker/engine.{type Engine}
import nostr_no_su/dedup
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/relay_client.{type Subscriptions}
import nostr_no_su/relay_connection.{type Socket, Socket}

/// How a relay connection is opened: `open_websocket` in production, a fake
/// socket in tests, so the whole tree can run without a network.
pub type Open =
  fn(String, Subscriptions, fn(Event) -> Nil) -> Result(Socket, String)

/// The monitoring subtree: the de-duplicating dispatcher the plugins run
/// behind, and the relays whose events feed it.
pub type Monitor {
  Monitor(
    name: Name(dedup.Msg),
    plugins: List(Plugin),
    dedup_capacity: Int,
    relay_urls: List(String),
    subscriptions: Subscriptions,
  )
}

/// The bunker subtree: the NIP-46 actor and the relays it listens and
/// replies on.
pub type Bunker {
  Bunker(
    name: Name(bunker.Msg),
    engine: Engine,
    relay_urls: List(String),
    subscriptions: Subscriptions,
  )
}

/// Which halves of the app to run, how to open their connections, and how
/// long a connection waits before reconnecting.
pub type Spec {
  Spec(
    monitor: Option(Monitor),
    bunker: Option(Bunker),
    open: Open,
    reconnect_delay_ms: Int,
  )
}

/// Start the tree. The root is `one_for_one` because the two subtrees are
/// independent: a broken bunker must not stop monitoring, and vice versa.
pub fn start(spec: Spec) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  // Deliberately tighter than the subtrees and over a longer window: a
  // subtree that keeps giving up is broken for good, and exiting hands the
  // restart to the container's restart policy instead of looping here.
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  |> add_subtree(spec.monitor, fn(config) { monitor_tree(spec, config) })
  |> add_subtree(spec.bunker, fn(config) { bunker_tree(spec, config) })
  |> supervisor.start
}

/// Open a real websocket connection to the relay and describe it as the
/// socket a connection actor watches and publishes on.
pub fn open_websocket(
  url: String,
  subscriptions: Subscriptions,
  handle_event: fn(Event) -> Nil,
) -> Result(Socket, String) {
  use connection <- result.try(relay_client.start(
    url,
    subscriptions,
    handle_event,
  ))
  use pid <- result.try(
    process.subject_owner(connection)
    |> result.replace_error("connection has no owner process"),
  )
  Ok(Socket(pid: pid, publish: relay_client.publish(connection, _)))
}

/// Add a subtree supervisor when that half of the app is configured.
fn add_subtree(
  builder: Builder,
  configured: Option(config),
  tree: fn(config) -> Builder,
) -> Builder {
  case configured {
    None -> builder
    Some(config) -> supervisor.add(builder, supervisor.supervised(tree(config)))
  }
}

/// The monitoring subtree: the dispatcher, then the connections feeding it.
fn monitor_tree(spec: Spec, config: Monitor) -> Builder {
  subtree()
  |> supervisor.add(dedup.supervised(
    config.name,
    config.plugins,
    config.dedup_capacity,
  ))
  |> add_connections(
    spec,
    config.relay_urls,
    config.subscriptions,
    fn(incoming) { send_named(config.name, dedup.Incoming(incoming)) },
    fn(_relay_url, _socket) { Nil },
  )
}

/// The bunker subtree: the actor, then the connections it answers on. Each
/// connection installs its publisher on the actor, which is why they restart
/// together with it.
fn bunker_tree(spec: Spec, config: Bunker) -> Builder {
  subtree()
  |> supervisor.add(bunker.supervised(config.name, config.engine))
  |> add_connections(
    spec,
    config.relay_urls,
    config.subscriptions,
    fn(incoming) { send_named(config.name, bunker.Incoming(incoming)) },
    fn(relay_url, socket: Socket) {
      send_named(config.name, bunker.SetPublisher(relay_url, socket.publish))
    },
  )
}

/// A subtree supervisor. The burst it tolerates is generous because one bad
/// event can take out the actor at the head and, with it, every connection
/// behind it; a relay going down is not a restart at all, as the connection
/// actor handles that itself.
fn subtree() -> Builder {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 10)
}

/// Add one supervised connection per relay url, all sharing the
/// subscriptions and handlers of their subtree.
fn add_connections(
  builder: Builder,
  spec: Spec,
  relay_urls: List(String),
  subscriptions: Subscriptions,
  handle_event: fn(Event) -> Nil,
  on_connect: fn(String, Socket) -> Nil,
) -> Builder {
  use builder, relay_url <- list.fold(relay_urls, builder)
  supervisor.add(
    builder,
    relay_connection.supervised(relay_connection.Config(
      relay: relay_client.label(relay_url),
      connect: fn() { spec.open(relay_url, subscriptions, handle_event) },
      on_connect: on_connect(relay_url, _),
      reconnect_delay_ms: spec.reconnect_delay_ms,
    )),
  )
}

/// Send to a named actor, dropping the message when nothing holds the name.
/// A named subject panics in that case, which would take a connection down
/// during the window in which its subtree is restarting.
fn send_named(name: Name(msg), message: msg) -> Nil {
  case process.named(name) {
    Ok(_pid) -> process.send(process.named_subject(name), message)
    Error(Nil) -> Nil
  }
}
