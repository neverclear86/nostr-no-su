//// AES-256-GCM で「nonce || 暗号文 || タグ」の箱を作って開く。
////
//// 乱数を持たず、nonce は引数で受け取る。暗号化と復号は OTP の `crypto`
//// （OpenSSL）を FFI 経由で使う。FFI は例外をすべて `{error, nil}` に写すので、
//// 鍵や平文が例外の引数としてクラッシュレポートに載ることはない。
////
//// 長さの検査は Gleam 側でも行う。OTP は 12 バイト以外の nonce でも暗号化に
//// 成功し、16 バイトより短いタグでも復号に成功するため、形式（先頭 12 バイトが
//// nonce、末尾 16 バイトがタグ）を守る検査はこのモジュールだけが担う。

import gleam/bit_array
import gleam/bool

/// 鍵のバイト数。
pub const key_bytes = 32

/// nonce のバイト数。
pub const nonce_bytes = 12

/// 認証タグのバイト数。
pub const tag_bytes = 16

/// OTP の AES-256-GCM による暗号化。暗号文とタグの組を返す。
@external(erlang, "nostr_no_su_ffi", "aes_256_gcm_seal")
fn ffi_seal(
  key: BitArray,
  nonce: BitArray,
  plaintext: BitArray,
  aad: BitArray,
) -> Result(#(BitArray, BitArray), Nil)

/// OTP の AES-256-GCM による復号。タグが一致しなければ Error。
@external(erlang, "nostr_no_su_ffi", "aes_256_gcm_open")
fn ffi_open(
  key: BitArray,
  nonce: BitArray,
  ciphertext: BitArray,
  aad: BitArray,
  tag: BitArray,
) -> Result(BitArray, Nil)

/// 平文を暗号化し、nonce || 暗号文 || タグ を返す。鍵が 32 バイトでないか、
/// nonce が 12 バイトでなければ Error(Nil)。
pub fn seal(
  key: BitArray,
  nonce: BitArray,
  plaintext: BitArray,
  aad: BitArray,
) -> Result(BitArray, Nil) {
  use <- bool.guard(!valid_lengths(key, nonce), Error(Nil))
  case ffi_seal(key, nonce, plaintext, aad) {
    Ok(#(ciphertext, tag)) -> Ok(<<nonce:bits, ciphertext:bits, tag:bits>>)
    Error(Nil) -> Error(Nil)
  }
}

/// nonce || 暗号文 || タグ を開く。長さ不足、タグ不一致、鍵長違いはすべて
/// Error(Nil)。タグは末尾の 16 バイトに固定し、短いタグとして解釈する経路を
/// 作らない。
pub fn open(
  key: BitArray,
  sealed: BitArray,
  aad: BitArray,
) -> Result(BitArray, Nil) {
  case sealed {
    <<nonce:bytes-size(nonce_bytes), rest:bytes>> -> {
      let ciphertext_bytes = bit_array.byte_size(rest) - tag_bytes
      use <- bool.guard(
        ciphertext_bytes < 0 || !valid_lengths(key, nonce),
        Error(Nil),
      )
      case rest {
        <<ciphertext:bytes-size(ciphertext_bytes), tag:bytes-size(tag_bytes)>> ->
          ffi_open(key, nonce, ciphertext, aad, tag)
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// 鍵と nonce が形式どおりの長さかどうか。
fn valid_lengths(key: BitArray, nonce: BitArray) -> Bool {
  bit_array.byte_size(key) == key_bytes
  && bit_array.byte_size(nonce) == nonce_bytes
}
