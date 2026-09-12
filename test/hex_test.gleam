//// 16 進文字列とバイト列の相互変換のテスト。

import gleam/string
import nostr_no_su/hex
import qcheck

/// バイト列を小文字の 16 進文字列にする。空のバイト列は空文字列になる。
pub fn encode_lowercase_test() {
  assert hex.encode(<<0x01, 0xab, 0xff>>) == "01abff"
  assert hex.encode(<<>>) == ""
}

/// 大文字と小文字が混ざった文字列も読む。
pub fn decode_ignores_case_test() {
  assert hex.decode("01AbfF") == Ok(<<0x01, 0xab, 0xff>>)
}

/// 桁数が奇数の文字列と、16 進でない文字を含む文字列は読まない。
pub fn decode_rejects_invalid_text_test() {
  assert hex.decode("abc") == Error(Nil)
  assert hex.decode("zz") == Error(Nil)
}

/// 任意のバイト列は小文字だけの文字列になり、その文字列も、大文字にした文字列も、
/// 読むと元のバイト列に戻る。
pub fn round_trip_property_test() {
  use bytes <- qcheck.given(qcheck.byte_aligned_bit_array())
  let text = hex.encode(bytes)
  assert text == string.lowercase(text)
  assert hex.decode(text) == Ok(bytes)
  assert hex.decode(string.uppercase(text)) == Ok(bytes)
}
