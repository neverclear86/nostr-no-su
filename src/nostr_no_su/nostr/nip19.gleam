//// NIP-19 の鍵（npub / nsec）と bech32 文字列の相互変換。
////
//// 扱うのは 32 バイトの裸の鍵だけで、`nprofile` などの TLV 形式は扱わない。
//// NIP-19 は bech32m ではなく bech32（BIP-173）を使うと定めているので、
//// チェックサムの定数は 1 とする。文字列の長さの上限は BIP-173 の 90 文字とする。
////
//// BIP-173 の Disclosures（2024 年追記）は、5 文字未満の連続した挿入や削除を
//// チェックサムが常に検出できるとは限らないとしている。32 バイトの鍵になるのは
//// 5 ビット値がちょうど 52 個のときだけなので、文字数が変わる改変は
//// `InvalidPadding` か `InvalidLength` で拒否される。
////
//// エラーには入力の一部（文字や位置を含む）を持たせない。nsec を扱うため、
//// エラーを画面やログに出しても秘密鍵の手がかりにならないようにする。

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// NIP-19 で扱う bech32 の接頭辞（HRP）。
pub type Prefix {
  Npub
  Nsec
}

/// 符号化または復号を拒否した理由。どの値も入力の一部を持たない。
pub type Nip19Error {
  TooLong
  InvalidCharacter
  MixedCase
  MissingSeparator
  EmptyPrefix
  TooShort
  InvalidChecksum
  PrefixMismatch(expected: Prefix)
  InvalidPadding
  InvalidLength
}

/// bech32 のデータ部の文字集合。位置がそのまま 5 ビット値になる。
const charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

/// BIP-173 が定める bech32 文字列全体の長さの上限。
const max_length = 90

/// チェックサムを成す 5 ビット値の個数。
const checksum_length = 6

/// 鍵のビット長（32 バイト）。
const key_bits = 256

/// BCH 符号の生成多項式の係数（BIP-173）。
const generator = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

/// 32 バイトの鍵を、指定した接頭辞の bech32 文字列にする。
pub fn encode(key: BitArray, prefix: Prefix) -> Result(String, Nip19Error) {
  use <- bool.guard(bit_array.bit_size(key) != key_bits, Error(InvalidLength))
  let hrp = prefix_text(prefix)
  let data = to_groups(key)
  let text =
    list.append(data, checksum(hrp, data))
    |> list.map(value_to_char)
    |> string.concat
  Ok(hrp <> "1" <> text)
}

/// 指定した接頭辞の bech32 文字列を 32 バイトの鍵にする。
/// 前後の空白（`string.trim` が除く文字）は取り除く。
pub fn decode(text: String, prefix: Prefix) -> Result(BitArray, Nip19Error) {
  let text = string.trim(text)
  use <- bool.guard(string.byte_size(text) > max_length, Error(TooLong))
  use <- bool.guard(
    !list.all(string.to_utf_codepoints(text), is_visible_ascii),
    Error(InvalidCharacter),
  )
  let lower = string.lowercase(text)
  use <- bool.guard(
    lower != text && string.uppercase(text) != text,
    Error(MixedCase),
  )
  use #(hrp, data) <- result.try(split_at_separator(lower))
  use <- bool.guard(hrp == "", Error(EmptyPrefix))
  use <- bool.guard(string.length(data) < checksum_length, Error(TooShort))
  use values <- result.try(list.try_map(
    string.to_graphemes(data),
    char_to_value,
  ))
  use <- bool.guard(
    polymod(list.append(expand_prefix(hrp), values)) != 1,
    Error(InvalidChecksum),
  )
  use <- bool.guard(
    hrp != prefix_text(prefix),
    Error(PrefixMismatch(expected: prefix)),
  )
  use key <- result.try(
    from_groups(list.take(values, list.length(values) - checksum_length)),
  )
  use <- bool.guard(bit_array.bit_size(key) != key_bits, Error(InvalidLength))
  Ok(key)
}

/// エラーの理由を、画面やログに出せる固定の英文にする。
pub fn describe(error: Nip19Error) -> String {
  case error {
    TooLong -> "bech32 string is too long"
    InvalidCharacter -> "invalid bech32 character"
    MixedCase -> "bech32 string mixes upper and lower case"
    MissingSeparator -> "missing bech32 separator"
    EmptyPrefix -> "empty bech32 prefix"
    TooShort -> "bech32 data part is shorter than the checksum"
    InvalidChecksum -> "invalid bech32 checksum"
    PrefixMismatch(expected) ->
      "expected " <> prefix_text(expected) <> " prefix"
    InvalidPadding -> "invalid bech32 padding"
    InvalidLength -> "key must be 32 bytes"
  }
}

/// 接頭辞を bech32 の HRP の文字列にする。管理 UI が理由を訳すときにも使う。
pub fn prefix_text(prefix: Prefix) -> String {
  case prefix {
    Npub -> "npub"
    Nsec -> "nsec"
  }
}

/// US-ASCII の 33〜126（BIP-173 が HRP に許す範囲）の文字かどうか。
fn is_visible_ascii(codepoint: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(codepoint)
  code >= 33 && code <= 126
}

/// 最後の `1` で HRP とデータ部に分ける。HRP 自体が `1` を含みうるため最後を使う。
fn split_at_separator(text: String) -> Result(#(String, String), Nip19Error) {
  case list.reverse(string.split(text, "1")) {
    [] | [_] -> Error(MissingSeparator)
    [data, ..hrp_parts] ->
      Ok(#(hrp_parts |> list.reverse |> string.join("1"), data))
  }
}

/// データ部の 1 文字を 5 ビット値にする。文字集合に無い文字は拒否する。
fn char_to_value(char: String) -> Result(Int, Nip19Error) {
  case string.split_once(charset, char) {
    Ok(#(before, _)) -> Ok(string.length(before))
    Error(Nil) -> Error(InvalidCharacter)
  }
}

/// 5 ビット値をデータ部の 1 文字にする。
fn value_to_char(value: Int) -> String {
  string.slice(charset, value, 1)
}

/// BIP-173 のチェックサムの剰余を計算する。正しい文字列では 1 になる。
fn polymod(values: List(Int)) -> Int {
  use state, value <- list.fold(values, 1)
  let top = int.bitwise_shift_right(state, 25)
  let shifted =
    int.bitwise_and(state, 0x1ffffff)
    |> int.bitwise_shift_left(5)
    |> int.bitwise_exclusive_or(value)
  use acc, coefficient, index <- list.index_fold(generator, shifted)
  case int.bitwise_and(int.bitwise_shift_right(top, index), 1) {
    1 -> int.bitwise_exclusive_or(acc, coefficient)
    _ -> acc
  }
}

/// HRP をチェックサムの計算に使う値の列にする。各文字の上位 3 ビット、0、
/// 各文字の下位 5 ビットの順に並べる。
fn expand_prefix(hrp: String) -> List(Int) {
  let codes =
    string.to_utf_codepoints(hrp)
    |> list.map(string.utf_codepoint_to_int)
  list.flatten([
    list.map(codes, int.bitwise_shift_right(_, 5)),
    [0],
    list.map(codes, int.bitwise_and(_, 31)),
  ])
}

/// HRP とデータ部の 5 ビット値から、6 個の 5 ビット値のチェックサムを作る。
fn checksum(hrp: String, data: List(Int)) -> List(Int) {
  let value =
    list.flatten([expand_prefix(hrp), data, list.repeat(0, checksum_length)])
    |> polymod
    |> int.bitwise_exclusive_or(1)
  to_groups(<<value:size({ checksum_length * 5 })>>)
}

/// ビット列を上位から 5 ビットずつの値にする。末尾が 5 ビットに満たなければ
/// 0 を足す。
fn to_groups(bits: BitArray) -> List(Int) {
  case bits {
    <<>> -> []
    <<group:size(5), rest:bits>> -> [group, ..to_groups(rest)]
    _ -> to_groups(<<bits:bits, 0:size({ 5 - bit_array.bit_size(bits) })>>)
  }
}

/// 5 ビット値の列をバイト列にする。余りが 5 ビット以上か、余りのビットが 0 で
/// なければ拒否する。
fn from_groups(groups: List(Int)) -> Result(BitArray, Nip19Error) {
  let bits =
    list.fold(groups, <<>>, fn(acc, group) { <<acc:bits, group:size(5)>> })
  let body_size = bit_array.bit_size(bits) / 8
  let rest = bit_array.bit_size(bits) % 8
  case bits {
    <<body:bytes-size(body_size), 0:size(rest)>> if rest < 5 -> Ok(body)
    _ -> Error(InvalidPadding)
  }
}
