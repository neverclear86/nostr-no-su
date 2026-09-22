//// 製品のロゴ（板つきの SVG）の検査。

import gleam/string
import nostr_no_su/admin/view
import support/admin_ui

/// ロゴの図形の色はテーマに関係なく属性に固定で書き、暗い配色で上書きする `<style>` を持たない。
/// 体は紺、尻尾は青緑、目と歯と板は白で、板の縁は灰色である。
pub fn logo_colors_are_fixed_test() {
  let logo = view.logo_svg()
  assert string.contains(logo, "fill=\"#183965\"")
  assert string.contains(logo, "fill=\"#28B9BE\"")
  assert string.contains(logo, "fill=\"#FFFFFF\"")
  assert string.contains(logo, "stroke=\"#C3CCD8\"")
  assert !string.contains(logo, "<style")
}

/// `assets/logo/` の板つきのロゴは描画するロゴと同じ文書で、README（英日）はその 1 枚を載せる。
pub fn logo_asset_matches_the_rendered_logo_test() {
  assert admin_ui.text_file("assets/logo/nostr-no-su-plate.svg")
    == view.logo_svg() <> "\n"
  let image =
    "<img alt=\"Nostr-no-Su\" src=\"assets/logo/nostr-no-su-plate.svg\" width=\"96\">"
  assert string.contains(admin_ui.text_file("README.md"), image)
  assert string.contains(admin_ui.text_file("README.ja.md"), image)
}
