import gleam/option.{None, Some}
import nostr_no_su/bunker/rpc.{EventDraft, Request}

pub fn decode_request_test() {
  let assert Ok(request) =
    rpc.decode_request(
      "{\"id\":\"x1\",\"method\":\"connect\",\"params\":[\"pk\",\"secret\"]}",
    )
  assert request
    == Request(id: "x1", method: "connect", params: ["pk", "secret"])
}

pub fn decode_request_without_params_test() {
  let assert Ok(request) =
    rpc.decode_request("{\"id\":\"x2\",\"method\":\"ping\"}")
  assert request == Request(id: "x2", method: "ping", params: [])
}

pub fn decode_request_rejects_garbage_test() {
  let assert Error(_) = rpc.decode_request("not json")
  let assert Error(_) = rpc.decode_request("{\"method\":\"ping\"}")
}

pub fn encode_success_omits_error_test() {
  assert rpc.encode_response(rpc.ok("x1", "ack"))
    == "{\"id\":\"x1\",\"result\":\"ack\"}"
}

pub fn encode_error_test() {
  assert rpc.encode_response(rpc.error("x1", "invalid secret"))
    == "{\"id\":\"x1\",\"result\":\"\",\"error\":\"invalid secret\"}"
}

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
    )
}

pub fn decode_draft_defaults_test() {
  let assert Ok(draft) = rpc.decode_draft("{\"kind\":1,\"content\":\"hi\"}")
  assert draft == EventDraft(kind: 1, content: "hi", tags: [], created_at: None)
}
