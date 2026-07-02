import gleam/option.{Some}
import nostr_no_su/nostr/filter.{Filter}
import nostr_no_su/nostr/message.{RelayClosed, RelayEose, RelayNotice, RelayOk}

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

pub fn decode_eose_test() {
  assert message.decode_relay_message("[\"EOSE\",\"sub1\"]")
    == Ok(RelayEose("sub1"))
}

pub fn decode_ok_test() {
  assert message.decode_relay_message("[\"OK\",\"abc\",true,\"\"]")
    == Ok(RelayOk("abc", True, ""))
}

pub fn decode_notice_test() {
  assert message.decode_relay_message("[\"NOTICE\",\"slow down\"]")
    == Ok(RelayNotice("slow down"))
}

pub fn decode_closed_test() {
  assert message.decode_relay_message("[\"CLOSED\",\"sub1\",\"reason\"]")
    == Ok(RelayClosed("sub1", "reason"))
}

pub fn decode_unknown_tag_test() {
  let assert Error(_) = message.decode_relay_message("[\"AUTH\",\"challenge\"]")
}

pub fn decode_garbage_test() {
  let assert Error(_) = message.decode_relay_message("not json")
  let assert Error(_) = message.decode_relay_message("{\"not\":\"an array\"}")
}

pub fn encode_req_test() {
  let query = Filter(..filter.new(), authors: Some(["abc"]), limit: Some(10))
  assert message.encode_client_message(message.Req("sub1", query))
    == "[\"REQ\",\"sub1\",{\"authors\":[\"abc\"],\"limit\":10}]"
}

pub fn encode_close_test() {
  assert message.encode_client_message(message.Close("sub1"))
    == "[\"CLOSE\",\"sub1\"]"
}
