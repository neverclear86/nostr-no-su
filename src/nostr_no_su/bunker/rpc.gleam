//// The NIP-46 JSON-RPC message layer carried inside the (encrypted) content
//// of kind-24133 events. No crypto here — this is pure serialization.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

/// A request from a connected client.
pub type Request {
  Request(id: String, method: String, params: List(String))
}

/// A response back to a client. On error, `result` is empty and `error` holds
/// the message; on success, `error` is None.
pub type Response {
  Response(id: String, result: String, error: Option(String))
}

/// The unsigned event draft carried as a JSON string in sign_event params[0].
pub type EventDraft {
  EventDraft(
    kind: Int,
    content: String,
    tags: List(List(String)),
    created_at: Option(Int),
  )
}

pub fn ok(id: String, result: String) -> Response {
  Response(id: id, result: result, error: None)
}

pub fn error(id: String, message: String) -> Response {
  Response(id: id, result: "", error: Some(message))
}

fn request_decoder() -> decode.Decoder(Request) {
  use id <- decode.field("id", decode.string)
  use method <- decode.field("method", decode.string)
  use params <- decode.optional_field("params", [], decode.list(decode.string))
  decode.success(Request(id:, method:, params:))
}

pub fn decode_request(text: String) -> Result(Request, json.DecodeError) {
  json.parse(text, request_decoder())
}

/// Encode a response. `error` is omitted entirely on success: some client
/// parsers treat any present `error` key as a failure.
pub fn encode_response(response: Response) -> String {
  let fields = case response.error {
    Some(message) -> [
      #("id", json.string(response.id)),
      #("result", json.string(response.result)),
      #("error", json.string(message)),
    ]
    None -> [
      #("id", json.string(response.id)),
      #("result", json.string(response.result)),
    ]
  }
  json.object(fields) |> json.to_string
}

fn draft_decoder() -> decode.Decoder(EventDraft) {
  use kind <- decode.field("kind", decode.int)
  use content <- decode.field("content", decode.string)
  use tags <- decode.optional_field(
    "tags",
    [],
    decode.list(decode.list(decode.string)),
  )
  use created_at <- decode.optional_field(
    "created_at",
    None,
    decode.optional(decode.int),
  )
  decode.success(EventDraft(kind:, content:, tags:, created_at:))
}

pub fn decode_draft(text: String) -> Result(EventDraft, json.DecodeError) {
  json.parse(text, draft_decoder())
}
