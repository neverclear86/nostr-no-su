import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/config.{type Config}
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter}
import nostr_no_su/nostr/message
import stratus

pub type Msg {
  Subscribe
  Publish(event: event.Event)
}

/// A thunk producing the subscriptions to open. It is re-evaluated on every
/// (re)connection so time-relative filters (e.g. `since`) stay current.
pub type Subscriptions =
  fn() -> List(#(String, Filter))

/// Convert a relay URL to the http(s) request stratus expects: gleam_http
/// only parses http(s) schemes, and stratus maps Https to wss/TLS.
pub fn to_request(url: String) -> Result(Request(String), Nil) {
  url
  |> string.replace("wss://", "https://")
  |> string.replace("ws://", "http://")
  |> request.to
}

/// Connect to the configured relay, open the given subscriptions, and pass
/// verified events to `handle_event`. Returns the connection subject; the
/// caller monitors it and reconnects.
pub fn start(
  config: Config,
  subscriptions: Subscriptions,
  handle_event: fn(event.Event) -> Nil,
) -> Result(Subject(stratus.InternalMessage(Msg)), String) {
  use req <- result.try(
    to_request(config.relay_url)
    |> result.replace_error("invalid relay url: " <> config.relay_url),
  )
  let builder =
    stratus.new(req, Nil)
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
          handle_text(text, handle_event)
          stratus.continue(state)
        }
        stratus.Binary(_) -> stratus.continue(state)
      }
    })
    |> stratus.on_close(fn(_state, reason) {
      io.println("[relay] connection closed: " <> string.inspect(reason))
    })

  case stratus.start(builder) {
    Ok(started) -> {
      process.send(started.data, stratus.to_user_message(Subscribe))
      Ok(started.data)
    }
    Error(error) -> Error(string.inspect(error))
  }
}

fn handle_text(text: String, handle_event: fn(event.Event) -> Nil) -> Nil {
  case message.decode_relay_message(text) {
    Ok(message.RelayEvent(_, received)) ->
      case event.compute_id(received) == received.id {
        True -> handle_event(received)
        False ->
          io.println("[relay] dropped event with invalid id: " <> received.id)
      }
    Ok(message.RelayEose(subscription)) ->
      io.println("[relay] end of stored events for " <> subscription)
    Ok(message.RelayOk(id, False, reason)) ->
      io.println("[relay] rejected event " <> id <> ": " <> reason)
    Ok(other) -> io.println("[relay] " <> string.inspect(other))
    Error(_) ->
      io.println("[relay] unrecognised message: " <> string.slice(text, 0, 120))
  }
}
