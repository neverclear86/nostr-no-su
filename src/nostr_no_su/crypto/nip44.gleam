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

pub type Nip44Error {
  InvalidKey
  InvalidPlaintextLength
  InvalidPayload
  UnsupportedVersion
  MacVerificationFailed
}

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

/// パディング後の平文のバイト数（先頭 2 バイトの長さプレフィックスを除く）。
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

fn bit_length(x: Int) -> Int {
  case x <= 0 {
    True -> 0
    False -> 1 + bit_length(int.bitwise_shift_right(x, 1))
  }
}

/// HKDF-expand で 76 バイトの message key を導出する:
/// chacha_key(32) || nonce(12) || hmac_key(32)。
fn message_keys(conversation_key: BitArray, nonce: BitArray) -> BitArray {
  let t1 = crypto.hmac(<<nonce:bits, 1>>, crypto.Sha256, conversation_key)
  let t2 =
    crypto.hmac(<<t1:bits, nonce:bits, 2>>, crypto.Sha256, conversation_key)
  let t3 =
    crypto.hmac(<<t2:bits, nonce:bits, 3>>, crypto.Sha256, conversation_key)
  // HMAC-SHA256 を 3 回連結した 96 バイトから、先頭 76 バイトを取る。
  let assert <<keys:bytes-size(76), _rest:bits>> = <<t1:bits, t2:bits, t3:bits>>
    as "hkdf-expand output must be 96 bytes"
  keys
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
  case len >= 1 && len <= 65_535 {
    False -> Error(InvalidPlaintextLength)
    True ->
      case message_keys(conversation_key, nonce) {
        <<
          chacha_key:bytes-size(32),
          chacha_nonce:bytes-size(12),
          hmac_key:bytes-size(32),
        >> -> {
          let pad_bytes = calc_padded_len(len) - len
          let padded = <<len:size(16), pt:bits, 0:size(pad_bytes)-unit(8)>>
          let ciphertext = ffi_chacha20(chacha_key, chacha_nonce, padded)
          let mac =
            crypto.hmac(
              <<nonce:bits, ciphertext:bits>>,
              crypto.Sha256,
              hmac_key,
            )
          Ok(bit_array.base64_encode(
            <<2, nonce:bits, ciphertext:bits, mac:bits>>,
            True,
          ))
        }
        _ -> Error(InvalidKey)
      }
  }
}

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

fn decrypt_bytes(
  decoded: BitArray,
  conversation_key: BitArray,
) -> Result(String, Nip44Error) {
  let total = bit_array.byte_size(decoded)
  case total >= 99 && total <= 65_603 {
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

fn decrypt_verified(
  conversation_key: BitArray,
  nonce: BitArray,
  ciphertext: BitArray,
  mac: BitArray,
) -> Result(String, Nip44Error) {
  case message_keys(conversation_key, nonce) {
    <<
      chacha_key:bytes-size(32),
      chacha_nonce:bytes-size(12),
      hmac_key:bytes-size(32),
    >> -> {
      let expected_mac =
        crypto.hmac(<<nonce:bits, ciphertext:bits>>, crypto.Sha256, hmac_key)
      case crypto.secure_compare(mac, expected_mac) {
        False -> Error(MacVerificationFailed)
        True -> unpad(ffi_chacha20(chacha_key, chacha_nonce, ciphertext))
      }
    }
    _ -> Error(InvalidKey)
  }
}

fn unpad(padded: BitArray) -> Result(String, Nip44Error) {
  case padded {
    <<unpadded_len:size(16), rest:bits>> -> {
      let rest_len = bit_array.byte_size(rest)
      let valid =
        unpadded_len >= 1
        && unpadded_len <= 65_535
        && unpadded_len <= rest_len
        && bit_array.byte_size(padded) == 2 + calc_padded_len(unpadded_len)
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
    _ -> Error(InvalidPayload)
  }
}
