//// kind 24133 イベントの（暗号化された）content に載る NIP-46 JSON-RPC の
//// メッセージ層。暗号処理はここには無く、シリアライズと入力の上限の検査を担う。

import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

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
/// `pubkey` は省略でき、空でなければ署名者と一致しなければならない（検査は
/// エンジンが行う）。
pub type EventDraft {
  EventDraft(
    kind: Int,
    content: String,
    tags: List(List(String)),
    created_at: Option(Int),
    pubkey: Option(String),
  )
}

/// 復号した content の最大バイト数。JSON を解く前にここで切る。いちばん
/// 大きい入力は `sign_event` のドラフト JSON である。
pub const max_request_bytes = 65_536

/// 方法名の最大バイト数。既知の方法名でいちばん長い `get_public_key` は
/// 14 バイトである。
pub const max_method_bytes = 64

/// リクエスト id の最大バイト数。id は応答にそのまま載せ直すので、応答の
/// 大きさも抑える。
pub const max_id_bytes = 64

/// `params` の最大要素数。既知のリクエストでいちばん要素の多い `connect` は
/// 3 個である。
pub const max_params = 8

/// JSON として読めないリクエストを捨てる理由。捨てる理由はこのモジュールに
/// 集める。
pub const malformed_request = "malformed request payload"

/// 上限を超えたリクエストを捨てる理由。
pub const limit_exceeded = "request exceeds the input limits"

/// 成功応答。
pub fn ok(id: String, result: String) -> Response {
  Response(id: id, result: result, error: None)
}

/// 失敗応答。
pub fn error(id: String, message: String) -> Response {
  Response(id: id, result: "", error: Some(message))
}

/// 承認が必要なリクエストへの応答。`result` を "auth_url"、`error` を承認ページの
/// URL とする NIP-46 の取り決めで、クライアントはこの URL を開いたうえで、同じ
/// id に対する本来の応答を待ち続ける。
pub fn auth_url(id: String, url: String) -> Response {
  Response(id: id, result: "auth_url", error: Some(url))
}

/// リクエスト用のデコーダー。`params` は省略されることがある。
fn request_decoder() -> decode.Decoder(Request) {
  use id <- decode.field("id", decode.string)
  use method <- decode.field("method", decode.string)
  use params <- decode.optional_field("params", [], decode.list(decode.string))
  decode.success(Request(id:, method:, params:))
}

/// 復号済みの content を JSON-RPC リクエストとしてデコードする。検査は
/// 3 段で、全文が `max_request_bytes` を超えれば `limit_exceeded`、JSON と
/// して読めなければ `malformed_request`、`id` が `max_id_bytes` を超える・
/// `method` が `max_method_bytes` を超える・`params` の要素数が
/// `max_params` を超えれば `limit_exceeded` を返す。上限を超えた入力に
/// JSON のパースを走らせないため、全文の検査を先に置く。
pub fn decode_request(text: String) -> Result(Request, String) {
  use <- bool.guard(
    string.byte_size(text) > max_request_bytes,
    Error(limit_exceeded),
  )
  use request <- result.try(
    json.parse(text, request_decoder())
    |> result.replace_error(malformed_request),
  )
  use <- bool.guard(!within_limits(request), Error(limit_exceeded))
  Ok(request)
}

/// リクエストの各要素が上限に収まっているか。`decode_request` の 3 段目である。
fn within_limits(request: Request) -> Bool {
  string.byte_size(request.id) <= max_id_bytes
  && string.byte_size(request.method) <= max_method_bytes
  && list.length(request.params) <= max_params
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

/// イベントドラフト用のデコーダー。`tags`・`created_at`・`pubkey` は省略できる。
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
  use pubkey <- decode.optional_field(
    "pubkey",
    None,
    decode.optional(decode.string),
  )
  decode.success(EventDraft(kind:, content:, tags:, created_at:, pubkey:))
}

/// sign_event の params[0] をイベントドラフトとしてデコードする。
pub fn decode_draft(text: String) -> Result(EventDraft, json.DecodeError) {
  json.parse(text, draft_decoder())
}
