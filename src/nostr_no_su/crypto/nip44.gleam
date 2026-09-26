//// NIP-44 v2 のペイロード暗号化。
////
//// 暗号プリミティブは OTP/OpenSSL 由来のものを使う。ECDH は `secp256k1.ecdh_x`、
//// SHA-256/HMAC は `gleam_crypto`、ChaCha20 は FFI ラッパー経由。本モジュールは
//// その上に、仕様が定める HKDF の鍵導出・パディング・ペイロード構造を組み立てる
//// だけ。

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/string
import nostr_no_su/crypto/secp256k1

/// 平文のバイト数の上限。
const max_plaintext_bytes = 4_294_967_295

/// 拡張長さプレフィックスに切り替わる平文のバイト数。これ以上の平文は 2 バイトの
/// 0 に続く u32 で長さを表す。
const extended_prefix_threshold = 65_536

/// ペイロード（`version || nonce || ciphertext || mac`）のバイト数の下限。
const min_payload_bytes = 99

/// ペイロード（`version || nonce || ciphertext || mac`）のバイト数の上限。
const max_payload_bytes = 4_294_967_367

/// 暗号化・復号を拒否した理由。
pub type Nip44Error {
  InvalidKey
  InvalidPlaintextLength
  InvalidPayload
  UnsupportedVersion
  MacVerificationFailed
}

/// HKDF-expand で導いた 3 つの message key。
pub type MessageKeys {
  MessageKeys(chacha_key: BitArray, chacha_nonce: BitArray, hmac_key: BitArray)
}

/// ブロックカウンター 0、12 バイト nonce の ChaCha20。ストリーム暗号なので
/// 暗号化と復号のどちらにも同じ呼び出しを使う。
@external(erlang, "nostr_no_su_ffi", "chacha20")
fn ffi_chacha20(key: BitArray, nonce: BitArray, data: BitArray) -> BitArray

/// 2 者間で共有する長期の conversation key を導出する。
pub fn conversation_key(
  privkey: BitArray,
  pubkey_xonly: BitArray,
) -> Result(BitArray, Nip44Error) {
  case secp256k1.ecdh_x(privkey, pubkey_xonly) {
    Error(_) -> Error(InvalidKey)
    // hkdf-extract: ソルト "nip44-v2" を HMAC 鍵、ECDH の x をデータとして使う。
    Ok(shared_x) ->
      Ok(crypto.hmac(shared_x, crypto.Sha256, <<"nip44-v2":utf8>>))
  }
}

/// パディング後の平文のバイト数（先頭の長さプレフィックスを除く）。
pub fn calc_padded_len(unpadded_len: Int) -> Int {
  case unpadded_len <= 32 {
    True -> 32
    False -> {
      let next_power = int.bitwise_shift_left(1, bit_length(unpadded_len - 1))
      let chunk = int.max(32, next_power / 8)
      chunk * { { unpadded_len + chunk - 1 } / chunk }
    }
  }
}

/// 正の整数を表すのに必要なビット数。0 以下は 0。
fn bit_length(x: Int) -> Int {
  case x <= 0 {
    True -> 0
    False -> 1 + bit_length(int.bitwise_shift_right(x, 1))
  }
}

/// HKDF-expand で `MessageKeys`（chacha_key 32 バイト、chacha_nonce 12 バイト、
/// hmac_key 32 バイト）を導出する。テストが公式ベクターの
/// `valid.get_message_keys` と照合するため公開する。
pub fn message_keys(
  conversation_key: BitArray,
  nonce: BitArray,
) -> MessageKeys {
  let t1 = crypto.hmac(<<nonce:bits, 1>>, crypto.Sha256, conversation_key)
  let t2 =
    crypto.hmac(<<t1:bits, nonce:bits, 2>>, crypto.Sha256, conversation_key)
  let t3 =
    crypto.hmac(<<t2:bits, nonce:bits, 3>>, crypto.Sha256, conversation_key)
  // HMAC-SHA256 を 3 回連結した 96 バイトから、先頭 76 バイトの message key を取る。
  let assert <<
    chacha_key:bytes-size(32),
    chacha_nonce:bytes-size(12),
    hmac_key:bytes-size(32),
    _rest:bits,
  >> = <<t1:bits, t2:bits, t3:bits>>
    as "hkdf-expand output must be 96 bytes"
  MessageKeys(chacha_key:, chacha_nonce:, hmac_key:)
}

/// 新たに生成したランダムな nonce で暗号化する。
pub fn encrypt(
  plaintext: String,
  conversation_key: BitArray,
) -> Result(String, Nip44Error) {
  encrypt_with_nonce(
    plaintext,
    conversation_key,
    crypto.strong_random_bytes(32),
  )
}

/// 決定的に暗号化するための差し込み口。`nonce` は 32 バイトの nonce。テスト
/// ベクターは nonce を固定するため、テストはこちらを直接呼ぶ。
pub fn encrypt_with_nonce(
  plaintext: String,
  conversation_key: BitArray,
  nonce: BitArray,
) -> Result(String, Nip44Error) {
  let pt = <<plaintext:utf8>>
  let len = bit_array.byte_size(pt)
  case len >= 1 && len <= max_plaintext_bytes {
    False -> Error(InvalidPlaintextLength)
    True -> {
      let MessageKeys(chacha_key:, chacha_nonce:, hmac_key:) =
        message_keys(conversation_key, nonce)
      let pad_bytes = calc_padded_len(len) - len
      let prefix = case len < extended_prefix_threshold {
        True -> <<len:size(16)>>
        False -> <<0:size(16), len:size(32)>>
      }
      let padded = <<prefix:bits, pt:bits, 0:size(pad_bytes)-unit(8)>>
      let ciphertext = ffi_chacha20(chacha_key, chacha_nonce, padded)
      let mac = mac(hmac_key, nonce, ciphertext)
      Ok(bit_array.base64_encode(
        <<2, nonce:bits, ciphertext:bits, mac:bits>>,
        True,
      ))
    }
  }
}

/// base64 のペイロードを復号する。先頭が `#` のものは NIP-44 v0 の予約表現で、
/// 対応しないバージョンとして拒否する。
pub fn decrypt(
  payload: String,
  conversation_key: BitArray,
) -> Result(String, Nip44Error) {
  case string.starts_with(payload, "#") {
    True -> Error(UnsupportedVersion)
    False ->
      case bit_array.base64_decode(payload) {
        Error(_) -> Error(InvalidPayload)
        Ok(decoded) -> decrypt_bytes(decoded, conversation_key)
      }
  }
}

/// 復号したバイト列を `version || nonce || ciphertext || mac` として読む。
/// 長さが仕様の範囲外のものはここで弾く。
fn decrypt_bytes(
  decoded: BitArray,
  conversation_key: BitArray,
) -> Result(String, Nip44Error) {
  let total = bit_array.byte_size(decoded)
  case total >= min_payload_bytes && total <= max_payload_bytes {
    False -> Error(InvalidPayload)
    True ->
      case decoded {
        <<version, nonce:bytes-size(32), ct_and_mac:bits>> ->
          case version == 2 {
            False -> Error(UnsupportedVersion)
            True -> {
              let ct_len = bit_array.byte_size(ct_and_mac) - 32
              case
                bit_array.slice(ct_and_mac, 0, ct_len),
                bit_array.slice(ct_and_mac, ct_len, 32)
              {
                Ok(ciphertext), Ok(mac) ->
                  decrypt_verified(conversation_key, nonce, ciphertext, mac)
                _, _ -> Error(InvalidPayload)
              }
            }
          }
        _ -> Error(InvalidPayload)
      }
  }
}

/// MAC を検証してから本文を復号する。MAC が一致しないものは復号しない。
fn decrypt_verified(
  conversation_key: BitArray,
  nonce: BitArray,
  ciphertext: BitArray,
  received_mac: BitArray,
) -> Result(String, Nip44Error) {
  let MessageKeys(chacha_key:, chacha_nonce:, hmac_key:) =
    message_keys(conversation_key, nonce)
  case crypto.secure_compare(received_mac, mac(hmac_key, nonce, ciphertext)) {
    False -> Error(MacVerificationFailed)
    True -> unpad(ffi_chacha20(chacha_key, chacha_nonce, ciphertext))
  }
}

/// NIP-44 の MAC。`hmac_key` で `nonce || ciphertext` の HMAC-SHA256 を取る。
fn mac(hmac_key: BitArray, nonce: BitArray, ciphertext: BitArray) -> BitArray {
  crypto.hmac(<<nonce:bits, ciphertext:bits>>, crypto.Sha256, hmac_key)
}

/// 長さプレフィックス付きのパディングを外す。先頭 2 バイトが 0 のものは 6 バイト
/// の拡張プレフィックスとして読む。
fn unpad(padded: BitArray) -> Result(String, Nip44Error) {
  case padded {
    <<0:size(16), unpadded_len:size(32), rest:bits>> ->
      unpad_body(padded, rest, unpadded_len, 6, extended_prefix_threshold)
    <<unpadded_len:size(16), rest:bits>> ->
      unpad_body(padded, rest, unpadded_len, 2, 1)
    _ -> Error(InvalidPayload)
  }
}

/// プレフィックスを読んだ後の検証と取り出し。宣言された長さが `min_len` 以上で、
/// パディング後の全長が仕様どおりであることを確かめる。
fn unpad_body(
  padded: BitArray,
  rest: BitArray,
  unpadded_len: Int,
  prefix_bytes: Int,
  min_len: Int,
) -> Result(String, Nip44Error) {
  let rest_len = bit_array.byte_size(rest)
  let valid =
    unpadded_len >= min_len
    && unpadded_len <= max_plaintext_bytes
    && unpadded_len <= rest_len
    && bit_array.byte_size(padded)
    == prefix_bytes + calc_padded_len(unpadded_len)
  case valid {
    False -> Error(InvalidPayload)
    True ->
      case bit_array.slice(rest, 0, unpadded_len) {
        Ok(message) ->
          case bit_array.to_string(message) {
            Ok(text) -> Ok(text)
            Error(_) -> Error(InvalidPayload)
          }
        Error(_) -> Error(InvalidPayload)
      }
  }
}
