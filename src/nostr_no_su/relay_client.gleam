import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter}
import nostr_no_su/nostr/message
import stratus

pub type Msg {
  Subscribe
  Publish(event: event.Event)
}

/// A started connection. It is driven through `publish` and the process
/// behind it is what `relay_connection` watches for disconnects.
pub type Connection =
  Subject(stratus.InternalMessage(Msg))

/// A thunk producing the subscriptions to open. It is re-evaluated on every
/// (re)connection so time-relative filters (e.g. `since`) stay current.
pub type Subscriptions =
  fn() -> List(#(String, Filter))

/// How long the handshake may take. `start` blocks its caller for at most
/// this (plus the 100ms stratus adds on top of it), and that caller is a
/// supervised actor which cannot answer its supervisor's shutdown while it
/// blocks: the value has to stay below the worker shutdown timeout of 5000ms
/// (see `relay_connection.supervised`), or shutting down a connection that is
/// waiting on an unresponsive relay ends in a brutal kill.
const connect_timeout_ms = 3000

/// Convert a relay URL to the http(s) request stratus expects: gleam_http
/// only parses http(s) schemes, and stratus maps Https to wss/TLS.
pub fn to_request(url: String) -> Result(Request(String), Nil) {
  case string.split_once(url, "://") {
    Ok(#("wss", rest)) -> request.to("https://" <> rest)
    Ok(#("ws", rest)) -> request.to("http://" <> rest)
    _ -> request.to(url)
  }
}

/// The relay URL without its scheme, used to attribute log lines to a relay
/// when several connections are open.
pub fn label(url: String) -> String {
  case string.split_once(url, "://") {
    Ok(#(_scheme, rest)) -> rest
    Error(_) -> url
  }
}

/// Connect to the given relay, open the given subscriptions, and pass
/// verified events to `handle_event`. The connection actor is linked to the
/// caller, so it dies with it and its death reaches a caller that traps
/// exits as a message.
pub fn start(
  url: String,
  subscriptions: Subscriptions,
  handle_event: fn(event.Event) -> Nil,
) -> Result(Connection, String) {
  use req <- result.try(
    to_request(url)
    |> result.replace_error("invalid relay url: " <> url),
  )
  let relay = label(url)
  let builder =
    stratus.new(req, Nil)
    |> stratus.with_connect_timeout(connect_timeout_ms)
    |> stratus.on_message(fn(state, msg, conn) {
      case msg {
        stratus.User(Subscribe) -> {
          list.each(subscriptions(), fn(subscription) {
            let text =
              message.encode_client_message(message.Req(
                subscription.0,
                subscription.1,
              ))
            let _ = stratus.send_text_message(conn, text)
          })
          stratus.continue(state)
        }
        stratus.User(Publish(published)) -> {
          let text = message.encode_client_message(message.Publish(published))
          let _ = stratus.send_text_message(conn, text)
          stratus.continue(state)
        }
        stratus.Text(text) -> {
          handle_text(relay, text, handle_event)
          stratus.continue(state)
        }
        stratus.Binary(_) -> stratus.continue(state)
      }
    })
    |> stratus.on_close(fn(_state, reason) {
      io.println(
        "[relay " <> relay <> "] connection closed: " <> string.inspect(reason),
      )
    })

  case stratus.start(builder) {
    Ok(started) -> {
      process.send(started.data, stratus.to_user_message(Subscribe))
      Ok(started.data)
    }
    Error(error) -> Error(string.inspect(error))
  }
}

/// Ask the connection to publish an event on its socket.
pub fn publish(connection: Connection, published: event.Event) -> Nil {
  process.send(connection, stratus.to_user_message(Publish(published)))
}

/// Decode one relay message: verified events go to `handle_event`,
/// everything else is logged under the relay it came from.
fn handle_text(
  relay: String,
  text: String,
  handle_event: fn(event.Event) -> Nil,
) -> Nil {
  case message.decode_relay_message(text) {
    Ok(message.RelayEvent(_, received)) ->
      case event.compute_id(received) == received.id {
        True -> handle_event(received)
        False ->
          io.println(
            "[relay "
            <> relay
            <> "] dropped event with invalid id: "
            <> received.id,
          )
      }
    Ok(message.RelayEose(subscription)) ->
      io.println(
        "[relay " <> relay <> "] end of stored events for " <> subscription,
      )
    Ok(message.RelayOk(id, False, reason)) ->
      io.println(
        "[relay " <> relay <> "] rejected event " <> id <> ": " <> reason,
      )
    Ok(other) -> io.println("[relay " <> relay <> "] " <> string.inspect(other))
    Error(_) ->
      io.println(
        "[relay "
        <> relay
        <> "] unrecognised message: "
        <> string.slice(text, 0, 120),
      )
  }
}
