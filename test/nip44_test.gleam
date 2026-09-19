//// NIP-44 v2 のペイロード暗号化のテスト。
////
//// 公式のテストベクターは `test/vectors/nip44.vectors.json` に置き、全区分の全要素を
//// 回す。取得元は paulmillr/nip44 の commit 1f8dba1707d065b39329b75012a13a6d1d8124f5 の
//// `nip44.vectors.json`（このファイルを最後に変えた commit）で、NIP-44 の「Tests and
//// code」の節が掲げる SHA-256 と一致する。
//// https://raw.githubusercontent.com/paulmillr/nip44/1f8dba1707d065b39329b75012a13a6d1d8124f5/nip44.vectors.json

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import nostr_no_su/crypto/nip44
import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex
import qcheck
import support/vector.{bytes}

/// 取得元のファイルの SHA-256。NIP-44 の本文に載っている値と同じ。
const vectors_sha256 = "269ed0f69e4c192512cc779e78c555090cebc7c785b609e338a62afc3ce25040"

/// ベクターのファイルから、`v2` の下の 1 区分を読む。
fn section(path: List(String), decoder: decode.Decoder(a)) -> a {
  let text = vector.read("nip44.vectors.json", vectors_sha256)
  let assert Ok(value) = json.parse(text, decode.at(["v2", ..path], decoder))
  value
}

/// 16 進の文字列をバイト列として読むデコーダー。
fn hex_bytes() -> decode.Decoder(BitArray) {
  decode.map(decode.string, bytes)
}

/// 文字列の UTF-8 表現の SHA-256 を 16 進にする。
fn sha256_hex(text: String) -> String {
  hex.encode(crypto.hash(crypto.Sha256, bit_array.from_string(text)))
}

/// ブロックカウンター 0、12 バイト nonce の ChaCha20。`nip44.message_keys` から
/// 得た鍵で、非正規のペイロードを組み立てるために直接呼ぶ。
@external(erlang, "nostr_no_su_ffi", "chacha20")
fn chacha20(key: BitArray, nonce: BitArray, data: BitArray) -> BitArray

/// valid.get_conversation_key: 秘密鍵と公開鍵から同じ conversation key を導く。
pub fn conversation_key_vectors_test() {
  let vectors =
    section(
      ["valid", "get_conversation_key"],
      decode.list({
        use sec1 <- decode.field("sec1", hex_bytes())
        use pub2 <- decode.field("pub2", hex_bytes())
        use key <- decode.field("conversation_key", hex_bytes())
        decode.success(#(sec1, pub2, key))
      }),
    )
  use #(sec1, pub2, key) <- list.each(vectors)
  assert #(pub2, nip44.conversation_key(sec1, pub2)) == #(pub2, Ok(key))
}

/// valid.get_message_keys: conversation key と nonce から、ChaCha20 の鍵と nonce、
/// HMAC の鍵を導く。
pub fn message_keys_vectors_test() {
  let key =
    section(["valid", "get_message_keys", "conversation_key"], hex_bytes())
  let vectors =
    section(
      ["valid", "get_message_keys", "keys"],
      decode.list({
        use nonce <- decode.field("nonce", hex_bytes())
        use chacha_key <- decode.field("chacha_key", hex_bytes())
        use chacha_nonce <- decode.field("chacha_nonce", hex_bytes())
        use hmac_key <- decode.field("hmac_key", hex_bytes())
        let keys = nip44.MessageKeys(chacha_key:, chacha_nonce:, hmac_key:)
        decode.success(#(nonce, keys))
      }),
    )
  use #(nonce, keys) <- list.each(vectors)
  assert #(nonce, nip44.message_keys(key, nonce)) == #(nonce, keys)
}

/// valid.calc_padded_len: パディング後の長さが表と一致する。
pub fn calc_padded_len_vectors_test() {
  let vectors =
    section(["valid", "calc_padded_len"], decode.list(decode.list(decode.int)))
  use pair <- list.each(vectors)
  let assert [unpadded, padded] = pair
  assert #(unpadded, nip44.calc_padded_len(unpadded)) == #(unpadded, padded)
}

/// valid.encrypt_decrypt: 仕様の手順どおり、双方の鍵から同じ conversation key を
/// 導き、同じ nonce でペイロードを再現し、復号で平文に戻す。
pub fn encrypt_decrypt_vectors_test() {
  let vectors =
    section(
      ["valid", "encrypt_decrypt"],
      decode.list({
        use sec1 <- decode.field("sec1", hex_bytes())
        use sec2 <- decode.field("sec2", hex_bytes())
        use key <- decode.field("conversation_key", hex_bytes())
        use nonce <- decode.field("nonce", hex_bytes())
        use plaintext <- decode.field("plaintext", decode.string)
        use payload <- decode.field("payload", decode.string)
        decode.success(#(sec1, sec2, key, nonce, plaintext, payload))
      }),
    )
  use #(sec1, sec2, key, nonce, plaintext, payload) <- list.each(vectors)
  let assert Ok(pub1) = secp256k1.xonly_pubkey(sec1)
  let assert Ok(pub2) = secp256k1.xonly_pubkey(sec2)
  assert #(payload, nip44.conversation_key(sec1, pub2)) == #(payload, Ok(key))
  assert #(payload, nip44.conversation_key(sec2, pub1)) == #(payload, Ok(key))
  assert #(payload, nip44.encrypt_with_nonce(plaintext, key, nonce))
    == #(payload, Ok(payload))
  assert #(payload, nip44.decrypt(payload, key)) == #(payload, Ok(plaintext))
}

/// valid.encrypt_decrypt_long_msg: 長い平文でも、平文とペイロードの SHA-256 が
/// ベクターと一致し、復号で平文に戻る。
pub fn encrypt_decrypt_long_msg_vectors_test() {
  let vectors =
    section(
      ["valid", "encrypt_decrypt_long_msg"],
      decode.list({
        use key <- decode.field("conversation_key", hex_bytes())
        use nonce <- decode.field("nonce", hex_bytes())
        use pattern <- decode.field("pattern", decode.string)
        use repeat <- decode.field("repeat", decode.int)
        use plaintext_sha256 <- decode.field("plaintext_sha256", decode.string)
        use payload_sha256 <- decode.field("payload_sha256", decode.string)
        decode.success(#(
          key,
          nonce,
          string.repeat(pattern, repeat),
          plaintext_sha256,
          payload_sha256,
        ))
      }),
    )
  use #(key, nonce, plaintext, plaintext_sha256, payload_sha256) <- list.each(
    vectors,
  )
  assert sha256_hex(plaintext) == plaintext_sha256
  let assert Ok(payload) = nip44.encrypt_with_nonce(plaintext, key, nonce)
  assert sha256_hex(payload) == payload_sha256
  assert nip44.decrypt(payload, key) == Ok(plaintext)
}

/// invalid.encrypt_msg_lengths: ベクターが挙げる長さのうち 1 バイト未満のものは
/// 拒否する。65536 以上の 3 件は拡張長さプレフィックスで暗号化でき、復号で元に
/// 戻る。上流のベクターは拡張長さプレフィックスの導入に追従しておらず、これらを
/// いまだ invalid として挙げている。
pub fn encrypt_msg_lengths_vectors_test() {
  let lengths =
    section(["invalid", "encrypt_msg_lengths"], decode.list(decode.int))
  use length <- list.each(lengths)
  let plaintext = string.repeat("a", length)
  case length >= 1 {
    False -> {
      let result = nip44.encrypt_with_nonce(plaintext, <<1:256>>, <<1:256>>)
      assert #(length, result) == #(length, Error(nip44.InvalidPlaintextLength))
    }
    True -> {
      let assert Ok(payload) =
        nip44.encrypt_with_nonce(plaintext, <<1:256>>, <<1:256>>)
      assert #(length, nip44.decrypt(payload, <<1:256>>))
        == #(length, Ok(plaintext))
    }
  }
}

/// NIP-44 の「Extended length prefix test vectors」の表。2 バイトと 6 バイトの
/// プレフィックスの境目で、padded_len と平文・ペイロードの SHA-256 が表と一致
/// する。取得元は `nostr-protocol/nips` の commit
/// `733a0471804116e1e3958a895435c2f08ce800fa`（`44.md` を最後に変えた commit）の
/// `44.md` の「Extended length prefix test vectors」の節、URL は
/// https://raw.githubusercontent.com/nostr-protocol/nips/733a0471804116e1e3958a895435c2f08ce800fa/44.md、
/// そのファイルの SHA-256 は
/// `b5f89374e4e1dbdee7881e8573b4313b6a89430a9c8d518471599ae0660cf0e2`。
pub fn extended_length_prefix_vectors_test() {
  let key =
    bytes("c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d")
  let nonce =
    bytes("0000000000000000000000000000000000000000000000000000000000000001")
  let rows = [
    #(
      65_535,
      65_536,
      "6e1bebca6a8229364a162a72ef064826c4cd7457bf54f190ef782bd9deff3e42",
      "6d8c2810d1e870fbaa1f0a0937126cca837a15f9260e27060c331d70a3c0bc84",
    ),
    #(
      65_536,
      65_536,
      "bf718b6f653bebc184e1479f1935b8da974d701b893afcf49e701f3e2f9f9c5a",
      "b7b4edb36ba92e267d322d56d9aebc22e7fa96ff52e3c12adc07f07a43cbc616",
    ),
    #(
      65_537,
      81_920,
      "008ffc88d3c96a9f307524eb361e47c5222a887fc45fa0c1fb8d429c5c23b430",
      "eeb7c7c5373894ea2c1547cfd3ccb15d5a0b2d619da852e5c79df792dcc9e435",
    ),
  ]
  use #(length, padded_len, plaintext_sha256, payload_sha256) <- list.each(rows)
  let plaintext = string.repeat("a", length)
  assert #(length, sha256_hex(plaintext)) == #(length, plaintext_sha256)
  assert #(length, nip44.calc_padded_len(length)) == #(length, padded_len)
  let assert Ok(payload) = nip44.encrypt_with_nonce(plaintext, key, nonce)
  assert #(length, sha256_hex(payload)) == #(length, payload_sha256)
  assert #(length, nip44.decrypt(payload, key)) == #(length, Ok(plaintext))
}

/// 65536 未満の長さを 6 バイトの拡張プレフィックスで表した非正規のペイロードは、
/// 全長が calc_padded_len と合っていても復号しない。
pub fn decrypt_rejects_non_canonical_extended_prefix_test() {
  let key = <<1:256>>
  let nonce = <<1:256>>
  let nip44.MessageKeys(chacha_key:, chacha_nonce:, hmac_key:) =
    nip44.message_keys(key, nonce)
  let padded_len = nip44.calc_padded_len(100)
  let pad_bytes = padded_len - 100
  let padded = <<
    0:size(16),
    100:size(32),
    string.repeat("a", 100):utf8,
    0:size(pad_bytes)-unit(8),
  >>
  let ciphertext = chacha20(chacha_key, chacha_nonce, padded)
  let mac =
    crypto.hmac(<<nonce:bits, ciphertext:bits>>, crypto.Sha256, hmac_key)
  let payload =
    bit_array.base64_encode(<<2, nonce:bits, ciphertext:bits, mac:bits>>, True)
  assert nip44.decrypt(payload, key) == Error(nip44.InvalidPayload)
}

/// invalid.get_conversation_key: 範囲外の秘密鍵や、曲線上に無い公開鍵からは
/// conversation key を導かない。
pub fn conversation_key_rejects_invalid_vectors_test() {
  let vectors =
    section(
      ["invalid", "get_conversation_key"],
      decode.list({
        use sec1 <- decode.field("sec1", hex_bytes())
        use pub2 <- decode.field("pub2", hex_bytes())
        use note <- decode.field("note", decode.string)
        decode.success(#(sec1, pub2, note))
      }),
    )
  use #(sec1, pub2, note) <- list.each(vectors)
  assert #(note, nip44.conversation_key(sec1, pub2))
    == #(note, Error(nip44.InvalidKey))
}

/// invalid.decrypt: 不正なペイロードを、ベクターの note が示す理由で拒否する。
pub fn decrypt_rejects_invalid_vectors_test() {
  let vectors =
    section(
      ["invalid", "decrypt"],
      decode.list({
        use key <- decode.field("conversation_key", hex_bytes())
        use payload <- decode.field("payload", decode.string)
        use note <- decode.field("note", decode.string)
        decode.success(#(key, payload, note))
      }),
    )
  use #(key, payload, note) <- list.each(vectors)
  assert #(note, nip44.decrypt(payload, key))
    == #(note, Error(expected_decrypt_error(note)))
}

/// invalid.decrypt の note を、`nip44.decrypt` が返すエラーに対応づける。
/// ファイルは SHA-256 で固定しているので、知らない note はテストの誤りとして扱う。
fn expected_decrypt_error(note: String) -> nip44.Nip44Error {
  case note {
    "unknown encryption version" <> _ -> nip44.UnsupportedVersion
    "invalid MAC" -> nip44.MacVerificationFailed
    "invalid base64" | "invalid padding" | "invalid payload length: " <> _ ->
      nip44.InvalidPayload
    _ -> panic as { "unknown invalid.decrypt note: " <> note }
  }
}

/// 任意の平文（1 文字以上）と conversation key で、乱数の nonce で暗号化したものを
/// 復号すると元の平文に戻る。
pub fn encrypt_decrypt_round_trip_property_test() {
  let generator =
    qcheck.tuple2(
      qcheck.non_empty_string(),
      qcheck.fixed_size_byte_aligned_bit_array(32),
    )
  use #(plaintext, key) <- qcheck.given(generator)
  let assert Ok(payload) = nip44.encrypt(plaintext, key)
  assert nip44.decrypt(payload, key) == Ok(plaintext)
}
