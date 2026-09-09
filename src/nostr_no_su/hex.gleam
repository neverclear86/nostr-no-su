//// 16 進文字列とバイト列の相互変換。
////
//// Nostr は鍵・イベント id・署名をすべて小文字の 16 進で表すため、出力は小文字に
//// そろえる。入力側は他の実装が大文字で書く可能性があるため、大文字・小文字の
//// どちらも受け付ける。

import gleam/bit_array
import gleam/string

/// バイト列を小文字の 16 進文字列にする。
pub fn encode(bytes: BitArray) -> String {
  bit_array.base16_encode(bytes)
  |> string.lowercase
}

/// 16 進文字列をバイト列にする。大文字・小文字は区別しない。
pub fn decode(text: String) -> Result(BitArray, Nil) {
  bit_array.base16_decode(string.uppercase(text))
}
