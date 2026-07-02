import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/io
import gleam/result
import gleam/string
import nostr_no_su/config.{type Config, to_filter}
import nostr_no_su/nostr/event
import nostr_no_su/nostr/message
import stratus

pub type Msg {
  Subscribe
}

const subscription_id = "nostr-no-su"

/// Convert a relay URL to the http(s) request stratus expects: gleam_http
/// only parses http(s) schemes, and stratus maps Https to wss/TLS.
pub fn to_request(url: String) -> Result(Request(String), Nil) {
  url
  |> string.replace("wss://", "https://")
  |> string.replace("ws://", "http://")
  |> request.to
}

/// Connect to the configured relay and subscribe. Verified events are passed
/// to `handle_event`. Returns the subject of the connection actor; the caller
/// is responsible for monitoring it and reconnecting.
pub fn start(
  config: Config,
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
          let req_text =
            message.encode_client_message(message.Req(
              subscription_id,
              to_filter(config),
            ))
          let _ = stratus.send_text_message(conn, req_text)
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
    Ok(other) -> io.println("[relay] " <> string.inspect(other))
    Error(_) ->
      io.println("[relay] unrecognised message: " <> string.slice(text, 0, 120))
  }
}
