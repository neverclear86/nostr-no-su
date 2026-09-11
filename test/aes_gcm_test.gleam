//// `crypto/aes_gcm` のテスト。既知解ベクターと、箱の形式を守る長さの検査を
//// 確かめる。

import gleam/bit_array
import gleam/int
import nostr_no_su/crypto/aes_gcm
import support/vector.{bytes}

/// McGrew と Viega の GCM 仕様書 Test Case 16 の鍵。
const tc16_key = "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"

/// Test Case 16 の 96 ビット IV。
const tc16_nonce = "cafebabefacedbaddecaf888"

/// Test Case 16 の AAD（20 バイト）。
const tc16_aad = "feedfacedeadbeeffeedfacedeadbeefabaddad2"

/// Test Case 16 の平文（60 バイト）。
const tc16_plaintext = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39"

/// Test Case 16 の暗号文。
const tc16_ciphertext = "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662"

/// Test Case 16 の認証タグ。
const tc16_tag = "76fc6ece0f4e1768cddf8853bb2d551b"

/// Test Case 16 の入力で作った箱。
fn tc16_sealed() -> BitArray {
  let assert Ok(sealed) =
    aes_gcm.seal(
      bytes(tc16_key),
      bytes(tc16_nonce),
      bytes(tc16_plaintext),
      bytes(tc16_aad),
    )
  sealed
}

/// 指定した位置のバイトの最下位ビットを反転する。
fn flip_bit(data: BitArray, index: Int) -> BitArray {
  let assert <<head:bytes-size(index), byte, tail:bytes>> = data
  <<head:bits, { int.bitwise_exclusive_or(byte, 1) }, tail:bits>>
}

/// Test Case 16 の入力から、仕様書の nonce || 暗号文 || タグ が得られる。
pub fn seal_matches_gcm_spec_test_case_16_test() {
  assert tc16_sealed()
    == bit_array.concat([
      bytes(tc16_nonce),
      bytes(tc16_ciphertext),
      bytes(tc16_tag),
    ])
}

/// 作った箱は同じ鍵と AAD で開ける。空の平文も往復する。
pub fn open_round_trips_test() {
  let key = bytes(tc16_key)
  let aad = bytes(tc16_aad)
  assert aes_gcm.open(key, tc16_sealed(), aad) == Ok(bytes(tc16_plaintext))
  let assert Ok(empty) = aes_gcm.seal(key, bytes(tc16_nonce), <<>>, aad)
  assert aes_gcm.open(key, empty, aad) == Ok(<<>>)
}

/// 鍵、AAD、nonce、暗号文、タグのどれが違っても開けない。
pub fn open_rejects_any_tampering_test() {
  let key = bytes(tc16_key)
  let aad = bytes(tc16_aad)
  let sealed = tc16_sealed()
  let last = bit_array.byte_size(sealed) - 1
  assert aes_gcm.open(flip_bit(key, 0), sealed, aad) == Error(Nil)
  assert aes_gcm.open(key, sealed, flip_bit(aad, 0)) == Error(Nil)
  // 先頭は nonce、12 バイト目からは暗号文、末尾はタグ。
  assert aes_gcm.open(key, flip_bit(sealed, 0), aad) == Error(Nil)
  assert aes_gcm.open(key, flip_bit(sealed, 12), aad) == Error(Nil)
  assert aes_gcm.open(key, flip_bit(sealed, last), aad) == Error(Nil)
}

/// タグを 8 バイトに切り詰めた箱は開けない。OTP は短いタグでも復号に成功する
/// ため、タグを末尾 16 バイトに固定していることの回帰テストである。
pub fn open_rejects_a_truncated_tag_test() {
  let sealed = tc16_sealed()
  let assert Ok(truncated) =
    bit_array.slice(sealed, 0, bit_array.byte_size(sealed) - 8)
  assert aes_gcm.open(bytes(tc16_key), truncated, bytes(tc16_aad)) == Error(Nil)
}

/// 28 バイト未満の箱、長さの違う鍵、11 バイトの nonce は、例外にならず
/// Error(Nil) になる。
pub fn wrong_lengths_are_errors_not_exceptions_test() {
  let key = bytes(tc16_key)
  let nonce = bytes(tc16_nonce)
  let aad = bytes(tc16_aad)
  let assert Ok(short_key) = bit_array.slice(key, 0, 31)
  let long_key = <<key:bits, 0>>
  let assert Ok(short_nonce) = bit_array.slice(nonce, 0, 11)
  let assert Ok(short_box) = bit_array.slice(tc16_sealed(), 0, 27)

  assert aes_gcm.open(key, short_box, aad) == Error(Nil)
  assert aes_gcm.open(short_key, tc16_sealed(), aad) == Error(Nil)
  assert aes_gcm.open(long_key, tc16_sealed(), aad) == Error(Nil)
  assert aes_gcm.seal(short_key, nonce, <<1>>, aad) == Error(Nil)
  assert aes_gcm.seal(long_key, nonce, <<1>>, aad) == Error(Nil)
  // OTP は 11 バイトの nonce でも暗号化に成功するので、Gleam 側の検査だけが
  // これを Error にする。
  assert aes_gcm.seal(key, short_nonce, <<1>>, aad) == Error(Nil)
}
