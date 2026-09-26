//// 公開鍵の指紋。16 進の公開鍵から 5 × 5 の左右対称の模様と 12 通りの色相を決め、
//// インライン SVG に描く。模様は識別の補助で、公開鍵の省略の表示とコピーの代わりにはしない。
//// 純粋で、`admin/i18n` にも `admin/dashboard` にも依存しない。
////
//// 色相は公開鍵の先頭のバイトを 12 で割った余り、模様は続く 15 ビットで決める。15 ビットを
//// 上位から順に、左の 3 列（x = 0〜2）へ列ごとに上から（y = 0〜4）割り当て、立っている
//// ビットのマスを塗る。x = 0 と 1 のマスは x = 4 − x の位置にも写す。
////
//// 色はクラスで付ける。CSP の `style-src 'self'` がインラインの `style` 属性を適用させない
//// ためである。`fp` と色相の `h0`〜`h11`、灰色の `fp-gray` の規則は `assets/admin.css` にあり、
//// 明るさと彩度はテーマのブロックの変数（`--fp-lightness`、`--fp-chroma`）でライトとダークを
//// 切り替える。

import gleam/list
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/svg
import nostr_no_su/admin/qr
import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex

/// 公開鍵 1 つの指紋。`hue` は色相の番号（0〜11）、`cells` は塗るマスの `#(x, y)`（どちらも 0〜4）である。
pub type Fingerprint {
  Fingerprint(hue: Int, cells: List(#(Int, Int)))
}

/// 指紋の塗り方。
pub type Shade {
  /// 鍵の色相で塗る。
  Colored
  /// 彩度 0 の灰色で塗る。
  Gray
}

/// 16 進の公開鍵（32 バイト。大文字と小文字は区別しない）から指紋を決める。32 バイトの 16 進でなければ `Error(Nil)` を返す。
pub fn from_pubkey(pubkey: String) -> Result(Fingerprint, Nil) {
  use bytes <- result.map(hex.decode_exact(pubkey, secp256k1.xonly_pubkey_bytes))
  let assert <<first, pattern:bits-size(15), _:bits>> = bytes
    as "a 32-byte pubkey has at least 16 bits"
  Fingerprint(hue: first % 12, cells: cells(pattern, 0))
}

/// 模様のビット列の先頭から順に、立っているビットのマスを左右に写して並べる。`index` は先頭のビットの番号である。
fn cells(pattern: BitArray, index: Int) -> List(#(Int, Int)) {
  case pattern {
    <<1:1, rest:bits>> -> list.append(mirrored(index), cells(rest, index + 1))
    <<_:1, rest:bits>> -> cells(rest, index + 1)
    _ -> []
  }
}

/// `index` 番目のビットのマスと、それを左右に写したマス。中央の列（x = 2）は 1 マスだけである。
fn mirrored(index: Int) -> List(#(Int, Int)) {
  let column = index / 5
  let row = index % 5
  case column {
    2 -> [#(2, row)]
    _ -> [#(column, row), #(4 - column, row)]
  }
}

/// 指紋を `viewBox` が `-1 -1 7 7` のインライン SVG に描く。マス（0〜4）の外周に 1 マス分の余白を取り、地の角丸の四角を不透明度 15% で、塗るマスを 1 本の `path` で、どちらも `currentColor` で塗る。`class` は大きさのクラスで、`admin/` の `.gleam` に完全な文字列で書いたものだけが CSS に出力される。飾りなので読み上げない。
pub fn svg(
  fingerprint: Fingerprint,
  shade: Shade,
  class: String,
) -> Element(msg) {
  svg.svg(
    [
      attribute.aria_hidden(True),
      attribute.attribute("viewBox", "-1 -1 7 7"),
      attribute.class(class),
      attribute.class(shade_class(fingerprint.hue, shade)),
    ],
    [
      svg.rect([
        attribute.attribute("x", "-1"),
        attribute.attribute("y", "-1"),
        attribute.attribute("width", "7"),
        attribute.attribute("height", "7"),
        attribute.attribute("rx", "1.7"),
        attribute.class("fill-current opacity-15"),
      ]),
      svg.path([
        attribute.attribute("d", qr.path_data(fingerprint.cells)),
        attribute.class("fill-current"),
      ]),
    ],
  )
}

/// 16 進の公開鍵の指紋を `svg` で描く。32 バイトの 16 進でなければ何も描かない。`shade` と `class` は `svg` に渡す。
pub fn pubkey_svg(pubkey: String, shade: Shade, class: String) -> Element(msg) {
  case from_pubkey(pubkey) {
    Ok(fingerprint) -> svg(fingerprint, shade, class)
    Error(Nil) -> element.none()
  }
}

/// 塗り方と色相の番号に当たるクラス。`hue` は `from_pubkey` が 0〜11 にするので、最後の腕は 11 に当たる（`Int` を網羅するための腕である）。
fn shade_class(hue: Int, shade: Shade) -> String {
  case shade, hue {
    Gray, _ -> "fp fp-gray"
    Colored, 0 -> "fp h0"
    Colored, 1 -> "fp h1"
    Colored, 2 -> "fp h2"
    Colored, 3 -> "fp h3"
    Colored, 4 -> "fp h4"
    Colored, 5 -> "fp h5"
    Colored, 6 -> "fp h6"
    Colored, 7 -> "fp h7"
    Colored, 8 -> "fp h8"
    Colored, 9 -> "fp h9"
    Colored, 10 -> "fp h10"
    Colored, _ -> "fp h11"
  }
}
