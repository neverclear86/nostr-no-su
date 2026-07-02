import gleam/dynamic/decode
import gleam/json
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/filter.{type Filter}

/// Messages sent from this client to a relay (NIP-01).
pub type ClientMessage {
  Req(subscription_id: String, filter: Filter)
  Close(subscription_id: String)
}

/// Messages sent from a relay to this client (NIP-01).
pub type RelayMessage {
  RelayEvent(subscription_id: String, event: Event)
  RelayEose(subscription_id: String)
  RelayOk(event_id: String, accepted: Bool, message: String)
  RelayNotice(message: String)
  RelayClosed(subscription_id: String, message: String)
}

pub fn encode_client_message(client_message: ClientMessage) -> String {
  case client_message {
    Req(subscription_id, query) ->
      json.preprocessed_array([
        json.string("REQ"),
        json.string(subscription_id),
        filter.to_json(query),
      ])
    Close(subscription_id) ->
      json.preprocessed_array([
        json.string("CLOSE"),
        json.string(subscription_id),
      ])
  }
  |> json.to_string
}

/// Relay messages are heterogeneous JSON arrays tagged by their first
/// element, e.g. `["EVENT", subscription_id, {...}]`. Integer keys index
/// into the decoded list.
pub fn relay_message_decoder() -> decode.Decoder(RelayMessage) {
  use tag <- decode.field(0, decode.string)
  case tag {
    "EVENT" -> {
      use subscription_id <- decode.field(1, decode.string)
      use received <- decode.field(2, event.decoder())
      decode.success(RelayEvent(subscription_id, received))
    }
    "EOSE" -> {
      use subscription_id <- decode.field(1, decode.string)
      decode.success(RelayEose(subscription_id))
    }
    "OK" -> {
      use event_id <- decode.field(1, decode.string)
      use accepted <- decode.field(2, decode.bool)
      use text <- decode.field(3, decode.string)
      decode.success(RelayOk(event_id, accepted, text))
    }
    "NOTICE" -> {
      use text <- decode.field(1, decode.string)
      decode.success(RelayNotice(text))
    }
    "CLOSED" -> {
      use subscription_id <- decode.field(1, decode.string)
      use text <- decode.field(2, decode.string)
      decode.success(RelayClosed(subscription_id, text))
    }
    _ -> decode.failure(RelayNotice(""), "RelayMessage")
  }
}

pub fn decode_relay_message(
  text: String,
) -> Result(RelayMessage, json.DecodeError) {
  json.parse(text, relay_message_decoder())
}
