import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/crypto/bip340
import nostr_no_su/crypto/secp256k1.{Point}
import nostr_no_su/hex
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/nostr/message
import support/signed_event

/// デコード・エンコードの確認に使う NIP-01 のイベント。
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

/// リレーから届く JSON オブジェクトを Event にデコードする。
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

/// エンコードしてデコードすると元のイベントに戻る。
pub fn encode_decode_roundtrip_test() {
  let original = sample_event()
  let encoded = event.to_json(original) |> json.to_string
  let assert Ok(decoded) = json.parse(encoded, event.decoder())
  assert decoded == original
}

/// id 計算用の正規シリアライズは NIP-01 の配列表現になる。
pub fn serialize_for_id_test() {
  assert event.serialize_for_id(sample_event())
    == "[0,\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",1700000000,1,[],\"hello nostr\"]"
}

/// タグの JSON 表現は文字列配列の配列で、タグが無ければ空配列になる。
pub fn tags_json_test() {
  assert event.tags_json(sample_event()) |> json.to_string == "[]"
  let with_tags =
    Event(..sample_event(), tags: [
      ["e", "xyz"],
      ["p", "abc", "wss://relay"],
    ])
  assert event.tags_json(with_tags) |> json.to_string
    == "[[\"e\",\"xyz\"],[\"p\",\"abc\",\"wss://relay\"]]"
}

/// 正規シリアライズの sha256 が、手で計算した id と一致する。
pub fn compute_id_synthetic_vector_test() {
  // 期待値はシェルで独立に計算したもの:
  // printf '%s' '[0,"3bf0…59d",1700000000,1,[],"hello nostr"]' | sha256sum
  assert event.compute_id(sample_event())
    == "556f29ae53faa7a9ca840c4389f4c5e19f67c2b69b6b8a029c96d43286b02385"
}

/// 署名対象のハッシュは 32 バイトの sha256 で、16 進化すると id と一致する。
pub fn hash_for_signing_test() {
  let hash = event.hash_for_signing(sample_event())
  assert bit_array.byte_size(hash) == 32
  assert hex.encode(hash)
    == "556f29ae53faa7a9ca840c4389f4c5e19f67c2b69b6b8a029c96d43286b02385"
}

/// 制御文字や引用符を含む content でも、id は正規シリアライズと一致する。
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
    hex.decode(
      "0000000000000000000000000000000000000000000000000000000000000042",
    )
  let assert Ok(pubkey_bytes) = secp256k1.xonly_pubkey(privkey)
  let pubkey = hex.encode(pubkey_bytes)
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

/// 署名したイベントは `verify` を通る。id が内容と合わなければ `InvalidId`、署名
/// だけが合わなければ `InvalidSignature` で落ちる。内容を改竄すると id も署名も
/// 合わなくなるが、署名を確かめる前に `InvalidId` で落ちる。
pub fn verify_test() {
  let signed = signed_event.new(1, "verified")
  let other = signed_event.new(1, "other")
  let assert Ok(verified) = event.verify(signed)
  assert event.verified_event(verified) == signed
  assert event.verify(Event(..signed, id: other.id)) == Error(event.InvalidId)
  assert event.verify(Event(..signed, sig: other.sig))
    == Error(event.InvalidSignature)
  assert event.verify(Event(..signed, content: "tampered"))
    == Error(event.InvalidId)
}

/// 32 バイトでない pubkey（NIP-01 の定義域の外）を持つイベントは、challenge が
/// そのバイト列を含んだ正しい署名を持っていても検証に落ちる。
pub fn verify_rejects_a_pubkey_that_is_not_32_bytes_test() {
  let key = "0000000000000000000000000000000000000000000000000000000000000003"
  let assert Ok(privkey_bytes) = hex.decode(key)
  let privkey = secp256k1.int_from_bytes(privkey_bytes)
  let assert Ok(Point(px, _py)) = secp256k1.mul_g(privkey)
  // 32 バイトの x-only pubkey の前に 00 を足した、33 バイトの pubkey。
  let pubkey_33 = <<0:size(8), secp256k1.int_to_bytes32(px):bits>>
  let draft =
    Event(
      id: "",
      pubkey: hex.encode(pubkey_33),
      created_at: 1_700_000_000,
      kind: 1,
      tags: [],
      content: "hi",
      sig: "",
    )
  let sig =
    sign_over_pubkey_bytes(privkey, pubkey_33, event.hash_for_signing(draft))
  let signed = Event(..draft, id: event.compute_id(draft), sig: hex.encode(sig))
  assert !event.verify_signature(signed)
  assert event.verify(signed) == Error(event.InvalidSignature)
}

/// 64 バイトでない sig を持つイベントは検証に落ちる。長さの検査は
/// `bip340.verify` が担うため、`verify_signature` には重ねて検査を足さない
/// という決定を固定する。
pub fn verify_signature_rejects_a_signature_that_is_not_64_bytes_test() {
  let signed = signed_event.new(1, "verified")
  assert !event.verify_signature(Event(..signed, sig: signed.sig <> "00"))
}

/// 任意のバイト列を pubkey として BIP-340 の challenge に入れて署名する。長さの
/// 検査を確かめるための、仕様外の pubkey を持つ正しい署名を作る。
/// `bip340.sign_with_aux` から乱数を除き、固定の nonce `k0 = 1` を使う。
fn sign_over_pubkey_bytes(
  privkey: Int,
  pubkey: BitArray,
  message: BitArray,
) -> BitArray {
  let assert Ok(Point(_px, py)) = secp256k1.mul_g(privkey)
  let d = case py % 2 == 0 {
    True -> privkey
    False -> secp256k1.n - privkey
  }
  let k0 = 1
  let assert Ok(Point(rx, ry)) = secp256k1.mul_g(k0)
  let k = case ry % 2 == 0 {
    True -> k0
    False -> secp256k1.n - k0
  }
  let rx_bytes = secp256k1.int_to_bytes32(rx)
  let e =
    secp256k1.int_from_bytes(
      bip340.tagged_hash("BIP0340/challenge", <<
        rx_bytes:bits,
        pubkey:bits,
        message:bits,
      >>),
    )
    % secp256k1.n
  let s = { k + e * d } % secp256k1.n
  <<rx_bytes:bits, secp256k1.int_to_bytes32(s):bits>>
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

/// binary キーのイベント map をキーと値の組から組み立てる。
fn binary_key_map(entries: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    entries |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) }),
  )
}

/// `to_map` の各キーを含む、正常なイベント map の材料。
fn valid_map_entries() -> List(#(String, Dynamic)) {
  [
    #("id", dynamic.string("abc")),
    #("pubkey", dynamic.string("def")),
    #("created_at", dynamic.int(1_700_000_000)),
    #("kind", dynamic.int(1)),
    #("tags", dynamic.list([])),
    #("content", dynamic.string("hi")),
    #("sig", dynamic.string("00")),
  ]
}

/// map に変換して戻すと元のイベントに戻る。タグの有無と非 ASCII の content を
/// 含めて確認する。
pub fn map_roundtrip_test() {
  let without_tags = Event(..sample_event(), content: "こんにちは Nostr")
  let assert Ok(decoded) = event.from_map(event.to_map(without_tags))
  assert decoded == without_tags

  let with_tags =
    Event(..sample_event(), tags: [["e", "xyz"], ["p", "abc", "wss://relay"]])
  let assert Ok(decoded_with_tags) = event.from_map(event.to_map(with_tags))
  assert decoded_with_tags == with_tags
}

/// `to_map` は binary キーの map を返す。キーを直接引いて固定する。
pub fn to_map_uses_binary_keys_test() {
  let map = event.to_map(sample_event())
  let assert Ok(1) = decode.run(map, decode.at(["kind"], decode.int))
  let assert Ok("hello nostr") =
    decode.run(map, decode.at(["content"], decode.string))
}

/// atom キーの map は受け付けない。Elixir の `%{id: ...}` をそのまま渡しても
/// 通らないことを固定する。
pub fn from_map_rejects_atom_keys_test() {
  let atom_keyed =
    dynamic.properties(
      valid_map_entries()
      |> list.map(fn(entry) {
        #(atom.to_dynamic(atom.create(entry.0)), entry.1)
      }),
    )
  assert event.from_map(atom_keyed) |> result.is_error
}

/// キーが欠けているときの失敗メッセージは、欠損であることとキー名の両方を含む。
pub fn from_map_missing_key_message_test() {
  let without_kind =
    binary_key_map(
      valid_map_entries() |> list.filter(fn(entry) { entry.0 != "kind" }),
    )
  let assert Error(reason) = event.from_map(without_kind)
  assert string.contains(reason, "missing field")
  assert string.contains(reason, "kind")
}

/// 値の型が違うときの失敗メッセージは、期待した型とキー名の両方を含む。
pub fn from_map_wrong_type_message_test() {
  let wrong_kind =
    binary_key_map(
      valid_map_entries()
      |> list.map(fn(entry) {
        case entry.0 {
          "kind" -> #("kind", dynamic.string("1"))
          _ -> entry
        }
      }),
    )
  let assert Error(reason) = event.from_map(wrong_kind)
  assert string.contains(reason, "expected")
  assert string.contains(reason, "kind")
}

/// ephemeral の範囲は 20000 以上 30000 未満で、両端の外は含まない。
pub fn is_ephemeral_test() {
  assert !event.is_ephemeral(19_999)
  assert event.is_ephemeral(20_000)
  assert event.is_ephemeral(event.nip46_kind)
  assert event.is_ephemeral(29_999)
  assert !event.is_ephemeral(30_000)
}
