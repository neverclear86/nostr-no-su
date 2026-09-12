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
        let keys = <<chacha_key:bits, chacha_nonce:bits, hmac_key:bits>>
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

/// invalid.encrypt_msg_lengths: 1〜65535 バイトの範囲外の平文は暗号化しない。
pub fn encrypt_rejects_invalid_length_vectors_test() {
  let lengths =
    section(["invalid", "encrypt_msg_lengths"], decode.list(decode.int))
  use length <- list.each(lengths)
  let result =
    nip44.encrypt_with_nonce(string.repeat("a", length), <<1:256>>, <<1:256>>)
  assert #(length, result) == #(length, Error(nip44.InvalidPlaintextLength))
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
