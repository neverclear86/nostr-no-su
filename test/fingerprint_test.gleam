//// 公開鍵の指紋（`admin/fingerprint`）の検査。

import gleam/int
import gleam/list
import gleam/string
import lustre/element
import nostr_no_su/admin/fingerprint.{Fingerprint}

/// 期待値を独立に計算した既知の公開鍵。
const known_key = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"

/// 既知の鍵が決まった色相とマスの並びになり、同じ鍵の大文字も同じ指紋になる。
pub fn fingerprint_matches_a_known_key_test() {
  let expected =
    Fingerprint(hue: 6, cells: [
      #(0, 1),
      #(4, 1),
      #(0, 2),
      #(4, 2),
      #(0, 3),
      #(4, 3),
      #(0, 4),
      #(4, 4),
      #(1, 0),
      #(3, 0),
      #(1, 1),
      #(3, 1),
      #(1, 3),
      #(3, 3),
      #(2, 1),
      #(2, 2),
      #(2, 3),
    ])
  assert fingerprint.from_pubkey(known_key) == Ok(expected)
  assert fingerprint.from_pubkey(string.uppercase(known_key)) == Ok(expected)
}

/// どのマスも 0〜4 の範囲にあり、左右に写したマスも塗られている。
pub fn fingerprint_is_mirrored_test() {
  use key <- list.each([
    known_key,
    string.repeat("f", 64),
    string.repeat("a5", 32),
  ])
  let assert Ok(Fingerprint(cells:, ..)) = fingerprint.from_pubkey(key)
  use #(x, y) <- list.each(cells)
  assert x >= 0 && x <= 4 && y >= 0 && y <= 4
  assert list.contains(cells, #(4 - x, y))
}

/// 32 バイトの 16 進でない文字列は `Error(Nil)` になる。
pub fn fingerprint_rejects_non_pubkeys_test() {
  use text <- list.each([
    "",
    "zz",
    string.repeat("a", 63),
    string.repeat("a", 62),
    string.repeat("a", 66),
  ])
  assert fingerprint.from_pubkey(text) == Error(Nil)
}

/// 先頭のバイトが 0〜11 の鍵の SVG は、大きさのクラスの後に `fp h<番号>` のクラスを持つ。
pub fn fingerprint_svg_picks_the_hue_class_test() {
  use hue <- list.each([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
  let key =
    string.pad_start(int.to_base16(hue), 2, "0") <> string.repeat("00", 31)
  let assert Ok(print) = fingerprint.from_pubkey(key)
  let rendered =
    element.to_string(fingerprint.svg(print, fingerprint.Colored, "size-4"))
  assert string.contains(
    rendered,
    "class=\"size-4 fp h" <> int.to_string(hue) <> "\"",
  )
}

/// `Gray` の SVG は `fp fp-gray` のクラスを持ち、色相のクラスを持たない。
pub fn fingerprint_svg_draws_gray_without_a_hue_test() {
  let assert Ok(print) = fingerprint.from_pubkey(known_key)
  let rendered =
    element.to_string(fingerprint.svg(print, fingerprint.Gray, "size-4"))
  assert string.contains(rendered, "class=\"size-4 fp fp-gray\"")
  assert !string.contains(rendered, "fp h")
}
