//// QR コードの符号化（`admin/qr`）の検査。

import gleam/list
import gleam/string
import lustre/element
import nostr_no_su/admin/qr

/// 既知の URI を符号化した SVG が、期待する属性と `path` 1 本を持つ。
pub fn qr_encodes_a_known_uri_test() {
  let assert Ok(svg) = qr.svg("Connection URI", "bunker://ab")
  let markup = element.to_string(svg)
  assert string.contains(markup, "viewBox=\"0 0 29 29\"")
  assert string.contains(markup, "shape-rendering=\"crispEdges\"")
  assert string.contains(markup, "role=\"img\"")
  assert string.contains(markup, "aria-label=\"Connection URI\"")
  assert list.length(string.split(markup, "<path")) == 2
}

/// 静寂域（一辺 4 モジュール分）には暗モジュールが無い。
pub fn qr_keeps_the_quiet_zone_test() {
  let assert Ok(#(dimension, dark)) = qr.modules("bunker://ab")
  let in_quiet_zone =
    list.any(dark, fn(module) {
      let #(x, y) = module
      x < 4 || y < 4 || x >= dimension - 4 || y >= dimension - 4
    })
  assert !in_quiet_zone
}

/// 左上・右上・左下の位置検出パターンの 7 × 7 の枠と 3 × 3 の芯がすべて暗モジュールに
/// 含まれる。
pub fn qr_places_the_finder_patterns_test() {
  let assert Ok(#(dimension, dark)) = qr.modules("bunker://ab")
  let corners = [#(4, 4), #(dimension - 11, 4), #(4, dimension - 11)]
  list.each(corners, fn(corner) {
    list.each(finder_pattern_modules(corner), fn(module) {
      assert list.contains(dark, module)
    })
  })
}

/// 0 から 6 までの辺の位置と、0 から 2 までの芯の位置。
const edge = [0, 1, 2, 3, 4, 5, 6]

const core_offset = [0, 1, 2]

/// 位置検出パターン 1 個ぶんの座標（7 × 7 の枠と 3 × 3 の芯）。
fn finder_pattern_modules(corner: #(Int, Int)) -> List(#(Int, Int)) {
  let #(x0, y0) = corner
  let border =
    list.flat_map(edge, fn(i) {
      [#(x0 + i, y0), #(x0 + i, y0 + 6), #(x0, y0 + i), #(x0 + 6, y0 + i)]
    })
  let core =
    list.flat_map(core_offset, fn(dx) {
      list.map(core_offset, fn(dy) { #(x0 + 2 + dx, y0 + 2 + dy) })
    })
  list.append(border, core)
}

/// 版 40 に収まらない長さの入力は符号化できない。
pub fn qr_encoding_fails_for_a_too_long_uri_test() {
  assert qr.svg("Connection URI", string.repeat("0", 3000)) == Error(Nil)
}
