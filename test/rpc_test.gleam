import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/bunker/rpc.{EventDraft, Request}

/// リクエストは id・メソッド・params に分解される。
pub fn decode_request_test() {
  let assert Ok(request) =
    rpc.decode_request(
      "{\"id\":\"x1\",\"method\":\"connect\",\"params\":[\"pk\",\"secret\"]}",
    )
  assert request
    == Request(id: "x1", method: "connect", params: ["pk", "secret"])
}

/// `params` は省略でき、その場合は空リストになる。
pub fn decode_request_without_params_test() {
  let assert Ok(request) =
    rpc.decode_request("{\"id\":\"x2\",\"method\":\"ping\"}")
  assert request == Request(id: "x2", method: "ping", params: [])
}

/// JSON として読めないもの、`id` が無いものはデコードに失敗する。
pub fn decode_request_rejects_garbage_test() {
  let assert Error(_) = rpc.decode_request("not json")
  let assert Error(_) = rpc.decode_request("{\"method\":\"ping\"}")
}

/// 全文が `max_request_bytes` を超える content は、JSON を解く前に捨てる。
pub fn decode_request_rejects_oversized_payload_test() {
  let body =
    "{\"id\":\"x1\",\"method\":\"sign_event\",\"params\":[\""
    <> string.repeat("c", rpc.max_request_bytes + 1)
    <> "\"]}"
  assert rpc.decode_request(body) == Error(rpc.limit_exceeded)
}

/// `method` が `max_method_bytes` を超えるリクエストは捨てる。
pub fn decode_request_rejects_long_method_test() {
  let body =
    "{\"id\":\"x1\",\"method\":\""
    <> string.repeat("m", rpc.max_method_bytes + 1)
    <> "\"}"
  assert rpc.decode_request(body) == Error(rpc.limit_exceeded)
}

/// `id` が `max_id_bytes` を超えるリクエストは捨てる。
pub fn decode_request_rejects_long_id_test() {
  let body =
    "{\"id\":\""
    <> string.repeat("i", rpc.max_id_bytes + 1)
    <> "\",\"method\":\"ping\"}"
  assert rpc.decode_request(body) == Error(rpc.limit_exceeded)
}

/// `params` の要素数が `max_params` を超えるリクエストは捨てる。
pub fn decode_request_rejects_too_many_params_test() {
  let params_json =
    list.repeat("p", rpc.max_params + 1)
    |> list.map(fn(param) { "\"" <> param <> "\"" })
    |> string.join(",")
  let body =
    "{\"id\":\"x1\",\"method\":\"ping\",\"params\":[" <> params_json <> "]}"
  assert rpc.decode_request(body) == Error(rpc.limit_exceeded)
}

/// 成功応答には `error` キーを出さない。キーの存在だけで失敗とみなす実装が
/// あるため。
pub fn encode_success_omits_error_test() {
  assert rpc.encode_response(rpc.ok("x1", "ack"))
    == "{\"id\":\"x1\",\"result\":\"ack\"}"
}

/// 失敗応答は空の `result` と `error` を持つ。
pub fn encode_error_test() {
  assert rpc.encode_response(rpc.error("x1", "invalid secret"))
    == "{\"id\":\"x1\",\"result\":\"\",\"error\":\"invalid secret\"}"
}

/// イベントドラフトは kind・content・tags・created_at・pubkey に分解される。
pub fn decode_draft_test() {
  let assert Ok(draft) =
    rpc.decode_draft(
      "{\"kind\":1,\"content\":\"hi\",\"tags\":[[\"t\",\"x\"]],\"created_at\":123}",
    )
  assert draft
    == EventDraft(
      kind: 1,
      content: "hi",
      tags: [["t", "x"]],
      created_at: Some(123),
      pubkey: None,
    )
}

/// `tags`・`created_at`・`pubkey` は省略でき、既定値になる。
pub fn decode_draft_defaults_test() {
  let assert Ok(draft) = rpc.decode_draft("{\"kind\":1,\"content\":\"hi\"}")
  assert draft
    == EventDraft(
      kind: 1,
      content: "hi",
      tags: [],
      created_at: None,
      pubkey: None,
    )
}

/// `pubkey` を指定したドラフトは `Some` にデコードされる。
pub fn decode_draft_with_pubkey_test() {
  let assert Ok(draft) =
    rpc.decode_draft("{\"kind\":1,\"content\":\"hi\",\"pubkey\":\"ab\"}")
  assert draft.pubkey == Some("ab")
}
