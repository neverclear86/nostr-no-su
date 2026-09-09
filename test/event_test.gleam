import gleam/bit_array
import gleam/json
import gleam/string
import nostr_no_su/crypto/secp256k1
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/nostr/message

fn sample_event() -> event.Event {
  Event(
    id: "556f29ae53faa7a9ca840c4389f4c5e19f67c2b69b6b8a029c96d43286b02385",
    pubkey: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    created_at: 1_700_000_000,
    kind: 1,
    tags: [],
    content: "hello nostr",
    sig: "",
  )
}

pub fn decode_test() {
  let raw =
    "{\"id\":\"abc\",\"pubkey\":\"def\",\"created_at\":1700000000,"
    <> "\"kind\":1,\"tags\":[[\"e\",\"xyz\"]],\"content\":\"hi\",\"sig\":\"00\"}"
  let assert Ok(decoded) = json.parse(raw, event.decoder())
  assert decoded
    == Event(
      id: "abc",
      pubkey: "def",
      created_at: 1_700_000_000,
      kind: 1,
      tags: [["e", "xyz"]],
      content: "hi",
      sig: "00",
    )
}

pub fn encode_decode_roundtrip_test() {
  let original = sample_event()
  let encoded = event.to_json(original) |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, event.decoder())
  assert decoded == original
}

pub fn serialize_for_id_test() {
  assert event.serialize_for_id(sample_event())
    == "[0,\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",1700000000,1,[],\"hello nostr\"]"
}

pub fn compute_id_synthetic_vector_test() {
  // 期待値はシェルで独立に計算したもの:
  // printf '%s' '[0,"3bf0…59d",1700000000,1,[],"hello nostr"]' | sha256sum
  assert event.compute_id(sample_event())
    == "556f29ae53faa7a9ca840c4389f4c5e19f67c2b69b6b8a029c96d43286b02385"
}

pub fn escaping_test() {
  let escaped =
    Event(
      id: "",
      pubkey: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
      created_at: 1_700_000_001,
      kind: 1,
      tags: [["t", "test"]],
      content: "line1\nline2 \"quoted\" \\ 日本語",
      sig: "",
    )
  // NIP-01 は \n, \", \\ を 2 文字のエスケープとし、UTF-8 はそのまま出力する。
  assert event.serialize_for_id(escaped)
    == "[0,\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",1700000001,1,[[\"t\",\"test\"]],\"line1\\nline2 \\\"quoted\\\" \\\\ 日本語\"]"
  // printf '%s' '<上記の正規シリアライズ文字列>' | sha256sum
  assert event.compute_id(escaped)
    == "8e84a9f722b367f45b2240f00937a466c000123deb6d1d999b2f7bbcaf12a57f"
}

/// `finalize` が `id` と `sig` を埋め、`verify_signature` がそれを受理し、改竄を
/// 検出することを確認する。
pub fn finalize_and_verify_test() {
  let assert Ok(privkey) =
    bit_array.base16_decode(string.uppercase(
      "0000000000000000000000000000000000000000000000000000000000000042",
    ))
  let assert Ok(pubkey_bytes) = secp256k1.xonly_pubkey(privkey)
  let pubkey = string.lowercase(bit_array.base16_encode(pubkey_bytes))
  let draft =
    Event(
      id: "",
      pubkey: pubkey,
      created_at: 1_700_000_000,
      kind: 1,
      tags: [["t", "test"]],
      content: "signed by the bunker",
      sig: "",
    )
  let assert Ok(signed) = event.finalize(draft, privkey)
  // id は内容と一致し、署名は検証でき、どちらも小文字 16 進である。
  assert signed.id == event.compute_id(draft)
  assert event.verify_signature(signed)
  // 改竄すると検証は失敗する。
  assert !event.verify_signature(Event(..signed, content: "tampered"))
}

/// wss://relay.damus.io からそのまま取得した実イベント。id は別の実装が計算した
/// ものなので、このテストは本実装の正規シリアライズ（エスケープ、UTF-8、
/// フィールド順）をエコシステムに対して固定する。
pub fn compute_id_real_event_test() {
  let raw =
    ""
    <> "[\"EVENT\",\"capture\",{\"content\":\"✈️ Atmospheric Dispersion Schedul"
    <> "e\\n\\nPlease specify a city in your message — for example:\\n  Wha"
    <> "t's the chemtrail schedule for London?\\n  Tokyo chemtrails today"
    <> "?\\n  Dispersion schedule for New York\",\"created_at\":1782968535,\""
    <> "id\":\"c7597860ffd1dffc12dcdd304ede1e998b6e9f73896f98ac225444b017b"
    <> "176dd\",\"kind\":1,\"pubkey\":\"674b5c51d5fddd358a2b081e0818f48f550f3b"
    <> "7fbf8a1211b9e2f74b9802404b\",\"sig\":\"8d6690e77bfcbc3de6d0fc8abf5e8"
    <> "b9072f5e7d8146b15308d0632c4396f1517009bd5d60b85a3a3908658772e010"
    <> "b2941412bc39ce9e464a6e9da3599dee0a0\",\"tags\":[[\"e\",\"8dc0cb50fa93c"
    <> "6565ef281b8884c6ee42051c89217ea08dc19f2cf657da7803f\",\"\",\"reply\","
    <> "\"9b1b577dd8bde32a80e0017d65c08c193994e882b1c8639910a303d10a37c33"
    <> "b\"],[\"p\",\"9b1b577dd8bde32a80e0017d65c08c193994e882b1c8639910a303"
    <> "d10a37c33b\"]]}]"
  let assert Ok(message.RelayEvent("capture", received)) =
    message.decode_relay_message(raw)
  assert event.compute_id(received) == received.id
  assert received.id
    == "c7597860ffd1dffc12dcdd304ede1e998b6e9f73896f98ac225444b017b176dd"
}
