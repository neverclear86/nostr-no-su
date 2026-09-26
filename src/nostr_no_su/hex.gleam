//// 16 進文字列とバイト列の相互変換。
////
//// Nostr は鍵・イベント id・署名をすべて小文字の 16 進で表すため、出力は小文字に
//// そろえる。入力側は他の実装が大文字で書く可能性があるため、大文字・小文字の
//// どちらも受け付ける。

import gleam/bit_array
import gleam/result
import gleam/string

/// バイト列を小文字の 16 進文字列にする。
pub fn encode(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes)
  |> string.lowercase
}

/// 16 進文字列をバイト列にする。大文字・小文字は区別しない。
pub fn decode(text: String) -> Result(BitArray, Nil) {
  bit_array.base16_decode(text)
}

/// 16 進文字列を、ちょうど `byte_count` バイトのバイト列として読む。大文字・小文字は
/// 区別しない。16 進として読めないか、バイト数が違えば `Error(Nil)` を返す。
pub fn decode_exact(text: String, byte_count: Int) -> Result(BitArray, Nil) {
  use bytes <- result.try(decode(text))
  case bit_array.byte_size(bytes) == byte_count {
    True -> Ok(bytes)
    False -> Error(Nil)
  }
}
