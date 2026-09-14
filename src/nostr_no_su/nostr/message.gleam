//// リレーとやり取りする NIP-01 と NIP-42 のメッセージの符号化と復号。
////
//// 送るのは `REQ`、`CLOSE`、`EVENT`、`AUTH`、受け取るのは `EVENT`、`EOSE`、
//// `OK`、`NOTICE`、`CLOSED`、`AUTH` で、未知のタグはデコードのエラーにする。
//// WebSocket の接続と再接続は `nostr_no_su/relay_connection` が担う。

import gleam/dynamic/decode
import gleam/json
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/filter.{type Filter}

/// 本クライアントからリレーへ送るメッセージ（NIP-01、NIP-42 の AUTH）。
pub type ClientMessage {
  Req(subscription_id: String, filter: Filter)
  Close(subscription_id: String)
  Publish(event: Event)
  Auth(event: Event)
}

/// リレーから本クライアントへ送られるメッセージ（NIP-01、NIP-42 の AUTH）。
pub type RelayMessage {
  RelayEvent(subscription_id: String, event: Event)
  RelayEose(subscription_id: String)
  RelayOk(event_id: String, accepted: Bool, message: String)
  RelayNotice(message: String)
  RelayClosed(subscription_id: String, message: String)
  RelayAuth(challenge: String)
}

/// クライアントメッセージを、リレーへ送る JSON 配列の文字列にする。
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
    Publish(event) ->
      json.preprocessed_array([json.string("EVENT"), event.to_json(event)])
    Auth(event) ->
      json.preprocessed_array([json.string("AUTH"), event.to_json(event)])
  }
  |> json.to_string
}

/// リレーメッセージは先頭要素をタグとする異種混在の JSON 配列で、たとえば
/// `["EVENT", subscription_id, {...}]` の形をとる。整数キーはデコード後の
/// リストの添字を指す。
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
    "AUTH" -> {
      use challenge <- decode.field(1, decode.string)
      decode.success(RelayAuth(challenge))
    }
    _ -> decode.failure(RelayNotice(""), "RelayMessage")
  }
}

/// リレーから届いた 1 行をデコードする。未知のタグや配列でない JSON は
/// エラーになる。
pub fn decode_relay_message(
  text: String,
) -> Result(RelayMessage, json.DecodeError) {
  json.parse(text, relay_message_decoder())
}
