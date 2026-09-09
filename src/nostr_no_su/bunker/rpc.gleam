//// kind 24133 イベントの（暗号化された）content に載る NIP-46 JSON-RPC の
//// メッセージ層。暗号処理はここには無く、シリアライズのみを担う。

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

/// 接続済みクライアントからのリクエスト。
pub type Request {
  Request(id: String, method: String, params: List(String))
}

/// クライアントへ返す応答。エラー時は `result` が空で `error` にメッセージが
/// 入り、成功時は `error` が None になる。
pub type Response {
  Response(id: String, result: String, error: Option(String))
}

/// sign_event の params[0] に JSON 文字列として載る未署名イベントのドラフト。
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

/// 応答をエンコードする。成功時は `error` キー自体を出力しない。`error` キーが
/// 存在するだけで失敗とみなすクライアント実装があるため。
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
