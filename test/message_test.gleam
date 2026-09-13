import gleam/option.{Some}
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/nostr/filter.{Filter}
import nostr_no_su/nostr/message.{RelayClosed, RelayEose, RelayNotice, RelayOk}

/// EVENT メッセージは購読 id とイベントに分解される。
pub fn decode_event_message_test() {
  let raw =
    "[\"EVENT\",\"sub1\",{\"id\":\"abc\",\"pubkey\":\"def\","
    <> "\"created_at\":1700000000,\"kind\":1,\"tags\":[],"
    <> "\"content\":\"hi\",\"sig\":\"00\"}]"
  let assert Ok(message.RelayEvent("sub1", received)) =
    message.decode_relay_message(raw)
  assert received.id == "abc"
  assert received.kind == 1
}

/// EOSE メッセージは購読 id を持つ。
pub fn decode_eose_test() {
  assert message.decode_relay_message("[\"EOSE\",\"sub1\"]")
    == Ok(RelayEose("sub1"))
}

/// OK メッセージはイベント id・受理の可否・理由を持つ。
pub fn decode_ok_test() {
  assert message.decode_relay_message("[\"OK\",\"abc\",true,\"\"]")
    == Ok(RelayOk("abc", True, ""))
}

/// NOTICE メッセージは本文だけを持つ。
pub fn decode_notice_test() {
  assert message.decode_relay_message("[\"NOTICE\",\"slow down\"]")
    == Ok(RelayNotice("slow down"))
}

/// CLOSED メッセージは購読 id と理由を持つ。
pub fn decode_closed_test() {
  assert message.decode_relay_message("[\"CLOSED\",\"sub1\",\"reason\"]")
    == Ok(RelayClosed("sub1", "reason"))
}

/// 未対応のタグ（COUNT など）はデコードに失敗する。
pub fn decode_unknown_tag_test() {
  let assert Error(_) = message.decode_relay_message("[\"COUNT\",\"sub1\"]")
}

/// AUTH メッセージは challenge だけを持つ。
pub fn decode_auth_test() {
  assert message.decode_relay_message("[\"AUTH\",\"c1\"]")
    == Ok(message.RelayAuth("c1"))
}

/// JSON として読めないもの、配列でないものはデコードに失敗する。
pub fn decode_garbage_test() {
  let assert Error(_) = message.decode_relay_message("not json")
  let assert Error(_) = message.decode_relay_message("{\"not\":\"an array\"}")
}

/// REQ は購読 id とフィルターの配列になる。
pub fn encode_req_test() {
  let query = Filter(..filter.new(), authors: Some(["abc"]), limit: Some(10))
  assert message.encode_client_message(message.Req("sub1", query))
    == "[\"REQ\",\"sub1\",{\"authors\":[\"abc\"],\"limit\":10}]"
}

/// CLOSE は購読 id だけの配列になる。
pub fn encode_close_test() {
  assert message.encode_client_message(message.Close("sub1"))
    == "[\"CLOSE\",\"sub1\"]"
}

/// EVENT はイベントをそのまま載せた配列になる。
pub fn encode_publish_test() {
  let event =
    Event(
      id: "abc",
      pubkey: "def",
      created_at: 1_700_000_000,
      kind: 1,
      tags: [],
      content: "hi",
      sig: "00",
    )
  assert message.encode_client_message(message.Publish(event))
    == "[\"EVENT\",{\"id\":\"abc\",\"pubkey\":\"def\",\"created_at\":1700000000,"
    <> "\"kind\":1,\"tags\":[],\"content\":\"hi\",\"sig\":\"00\"}]"
}

/// AUTH はイベントをそのまま載せた配列になる。
pub fn encode_auth_test() {
  let event =
    Event(
      id: "abc",
      pubkey: "def",
      created_at: 1_700_000_000,
      kind: 22_242,
      tags: [],
      content: "",
      sig: "00",
    )
  assert message.encode_client_message(message.Auth(event))
    == "[\"AUTH\",{\"id\":\"abc\",\"pubkey\":\"def\",\"created_at\":1700000000,"
    <> "\"kind\":22242,\"tags\":[],\"content\":\"\",\"sig\":\"00\"}]"
}
