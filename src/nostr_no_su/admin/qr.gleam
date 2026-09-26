//// QR コードの符号化と SVG への変換。純粋で、`admin/i18n` にも `admin/dashboard` にも
//// 依存しない。マスの一覧を `path` にする `path_data` は `admin/fingerprint` も使う。

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/svg

/// `text` を誤り訂正レベル L・byte モードで符号化し、静寂域を含む一辺のモジュール数と、
/// 暗モジュールの `#(x, y)` の一覧を返す。版 40 に収まらなければ `Error(Nil)`。
@external(erlang, "nostr_no_su_ffi", "qr_dark_modules")
pub fn modules(text: String) -> Result(#(Int, List(#(Int, Int))), Nil)

/// `text` を誤り訂正レベル L・byte モードで符号化し、`label` を `aria-label` に持つ
/// インライン SVG を返す。版 40 に収まらなければ `Error(Nil)`。
pub fn svg(label: String, text: String) -> Result(Element(msg), Nil) {
  use #(dimension, dark) <- result.map(modules(text))
  let side = int.to_string(dimension)
  let view_box = "0 0 " <> side <> " " <> side
  svg.svg(
    [
      attribute.role("img"),
      attribute.aria_label(label),
      attribute.attribute("viewBox", view_box),
      attribute.attribute("shape-rendering", "crispEdges"),
      attribute.class(
        "w-72 max-w-full h-auto rounded-box border border-base-300 bg-white p-2",
      ),
    ],
    [
      svg.rect([
        attribute.attribute("width", side),
        attribute.attribute("height", side),
        attribute.attribute("fill", "#fff"),
      ]),
      svg.path([
        attribute.attribute("d", path_data(dark)),
        attribute.attribute("fill", "#000"),
      ]),
    ],
  )
}

/// マスの `#(x, y)` の一覧を、1 マスずつの正方形を連ねた `path` の `d` 属性の値にする。QR コードの暗モジュールと、`admin/fingerprint` の指紋の塗るマスが使う。
pub fn path_data(modules: List(#(Int, Int))) -> String {
  modules
  |> list.map(fn(module) {
    let #(x, y) = module
    "M" <> int.to_string(x) <> " " <> int.to_string(y) <> "h1v1h-1z"
  })
  |> string.join("")
}
