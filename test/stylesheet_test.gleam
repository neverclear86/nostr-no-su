//// ビルドした管理 UI のスタイルシート（`priv/static/admin.css`）と、ページの中のスタイルの検査。

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/admin/i18n
import nostr_no_su/admin/routes
import support/admin_ui

/// 検査の対象にするページ。ページに埋め込まれる部品と、`components` にしか出ない部品の
/// 両方を通す。
fn pages() -> List(String) {
  list.append(admin_ui.all_pages(), admin_ui.components(i18n.English))
}

/// 描画しうるページのクラスは、どれもビルドした CSS に定義がある。Tailwind はソースに完全な
/// 文字列で書かれたクラスしか出力しないので、連結で組み立てたクラス、綴りの誤り、CSS の
/// ビルドし直し忘れは、ここで定義の無いクラスとして見つかる。
pub fn stylesheet_defines_every_rendered_class_test() {
  let css = admin_ui.static_file(routes.Stylesheet)
  let undefined =
    pages()
    |> list.flat_map(classes)
    |> list.unique
    |> list.filter(fn(class) { !defines(css, class) })
  assert undefined == []
}

/// ライトとダークのどちらのテーマでも、文字と地の組み合わせが WCAG 2 の AA のコントラスト比を
/// 満たす。本文（`base-content`、`muted`）と状態色の文字は面（`base-100`）とページの地
/// （`base-200`）に対して 4.5、各色の `-content` はその色の塗りに対して 4.5、入力とボタンの枠
/// （`field`）は面とページの地に対して 3 である。`accent` は飾りだけに使うので文字の色としては
/// 数えず、`base-300` は文字を載せない区切りの線なので数えない。
pub fn the_themes_meet_the_contrast_minimums_test() {
  let css = admin_ui.static_file(routes.Stylesheet)
  let surfaces = ["base-100", "base-200"]
  let text_on_surfaces =
    list.flat_map(
      [
        "base-content", "muted", "primary", "secondary", "info", "success",
        "warning", "error",
      ],
      fn(text) { list.map(surfaces, fn(surface) { #(text, surface, 4.5) }) },
    )
  let content_on_fills =
    list.map(
      [
        "primary", "secondary", "accent", "neutral", "info", "success",
        "warning", "error",
      ],
      fn(fill) { #(fill <> "-content", fill, 4.5) },
    )
  let field_on_surfaces =
    list.map(surfaces, fn(surface) { #("field", surface, 3.0) })
  let pairs =
    list.flatten([text_on_surfaces, content_on_fills, field_on_surfaces])
  let failures =
    list.flat_map(["light", "dark"], fn(theme) {
      let variables = theme_variables(css, theme)
      list.filter_map(pairs, fn(pair) {
        let #(foreground, background, minimum) = pair
        let assert Ok(fg) = dict.get(variables, "--color-" <> foreground)
        let assert Ok(bg) = dict.get(variables, "--color-" <> background)
        let ratio = contrast_ratio(fg, bg)
        case ratio <. minimum {
          True -> Ok(#(theme, foreground, background, ratio))
          False -> Error(Nil)
        }
      })
    })
  assert failures == []
}

/// ライトとダークのテーマが、デザインの半径（切り替え 999px、入力とボタン 9px、面 14px）と
/// 面の影（`shadow-lift` の 2 層）を運び、本文と等幅の文字が OS のフォントの並びである。
/// Web フォントは同梱しないので、`@font-face` は無い。
pub fn the_themes_carry_the_radii_shadow_and_fonts_test() {
  let css = admin_ui.static_file(routes.Stylesheet)
  let shadows = [
    #("light", "0 1px 2px #0e213b0f", "0 12px 28px -14px #0e213b47"),
    #("dark", "0 0 0 1px #ffffff05", "0 16px 34px -16px #000000bf"),
  ]
  list.each(shadows, fn(theme) {
    let #(name, near, far) = theme
    let variables = theme_variables(css, name)
    assert dict.get(variables, "--radius-selector") == Ok("999px")
    assert dict.get(variables, "--radius-field") == Ok("9px")
    assert dict.get(variables, "--radius-box") == Ok("14px")
    assert dict.get(variables, "--shadow-lift-near") == Ok(near)
    assert dict.get(variables, "--shadow-lift-far") == Ok(far)
  })
  assert string.contains(
    css,
    "--font-sans:\"Hiragino Sans\", \"Hiragino Kaku Gothic ProN\", \"Noto Sans CJK JP\", \"Noto Sans JP\", \"Yu Gothic UI\", Meiryo, system-ui, sans-serif;",
  )
  assert string.contains(
    css,
    "--font-mono:ui-monospace, \"SF Mono\", \"Cascadia Mono\", \"Noto Sans Mono CJK JP\", monospace;",
  )
  assert !string.contains(css, "@font-face")
}

/// フォーカスできるボタン（`a`、`button`、`summary` の `btn`）はフォーカスの輪郭を、入力欄
/// （`input` の `input`、`checkbox`、`textarea`、`select`）は枠を、`base-content` の色にする
/// （デザイン方針 6 節の規則）。daisyUI の既定では輪郭が塗りの色になり、枠は薄いので、
/// 付け忘れるとコントラストが足りなくなる。付け忘れてもクラスはほかの文字列で CSS に
/// 出力されるので、定義の検査では見つからない。フォーカスできない要素の `btn` は対象にしない。
pub fn buttons_and_inputs_follow_the_color_rules_test() {
  let violations =
    pages()
    |> list.flat_map(tagged_classes)
    |> list.unique
    |> list.filter(fn(element) {
      let #(tag, classes) = element
      case tag {
        "a" | "button" | "summary" ->
          list.contains(classes, "btn")
          && !list.contains(classes, "focus-visible:outline-base-content")
        "input" ->
          {
            list.contains(classes, "input")
            || list.contains(classes, "checkbox")
          }
          && !list.contains(classes, "border-base-content/60")
        "textarea" | "select" ->
          !list.contains(classes, "border-base-content/60")
        _ -> False
      }
    })
  assert violations == []
}

/// どのページも `<style>` 要素と `style` 属性を持たない。CSP（`style-src 'self'`）は
/// インラインのスタイルを適用させないので、書き足すと指定が黙って効かなくなる。
/// テキストと属性値はエスケープされて `<` と `"` を含まないので、`<style` は要素の
/// 開始タグで、` style="` は属性の始まりである。
pub fn pages_have_no_inline_styles_test() {
  use page <- list.each(pages())
  assert !string.contains(page, "<style")
  assert !string.contains(page, " style=\"")
}

/// 鍵の指紋の色は、テーマのブロックの明るさと彩度と、`fp` の色相の変数を oklch で合成する。ブロックの値を消すか色の式を変えると、テーマで明るさが切り替わらなくなる。
pub fn the_themes_carry_the_fingerprint_colors_test() {
  let css = admin_ui.static_file(routes.Stylesheet)
  let light = theme_variables(css, "light")
  let dark = theme_variables(css, "dark")
  assert dict.get(light, "--fp-lightness") == Ok(".57")
  assert dict.get(light, "--fp-chroma") == Ok(".14")
  assert dict.get(dark, "--fp-lightness") == Ok(".79")
  assert dict.get(dark, "--fp-chroma") == Ok(".12")
  assert string.contains(
    css,
    ".fp{color:oklch(var(--fp-lightness) var(--fp-chroma) var(--fp-hue))}",
  )
}

/// ページの `class` 属性に現れるクラス名。値はエスケープされて `"` を含まないので、次の `"` までが
/// 属性値である。
fn classes(page: String) -> List(String) {
  page
  |> string.split(" class=\"")
  |> list.drop(1)
  |> list.flat_map(fn(rest) {
    let assert Ok(#(value, _)) = string.split_once(rest, "\"")
    string.split(value, " ")
  })
}

/// ページの開始タグごとの、要素名と `class` 属性のクラス名。`class` 属性の無い要素は含めない。
/// テキストと属性値はエスケープされて `<` と `>` を含まないので、`<` から次の `>` までが
/// 開始タグである。
fn tagged_classes(page: String) -> List(#(String, List(String))) {
  page
  |> string.split("<")
  |> list.filter_map(fn(chunk) {
    use #(tag, _) <- result.try(string.split_once(chunk, ">"))
    use #(name, attributes) <- result.try(string.split_once(tag, " "))
    use #(_, rest) <- result.try(string.split_once(attributes, "class=\""))
    use #(value, _) <- result.map(string.split_once(rest, "\""))
    #(name, string.split(value, " "))
  })
}

/// CSS にクラスのセレクターがあるか。`.btn` が `.btn-sm` の先頭に一致しないよう、セレクターの
/// 直後がクラス名の続きでないものだけを数える。
fn defines(css: String, class: String) -> Bool {
  css
  |> string.split("." <> escape_selector(class))
  |> list.drop(1)
  |> list.any(fn(rest) { !continues_class_name(rest) })
}

/// Tailwind がセレクターの中でエスケープする記号を、バックスラッシュでエスケープする。
fn escape_selector(class: String) -> String {
  list.fold(
    [":", "/", "[", "]", "(", ")", ",", ".", "%", "*"],
    class,
    fn(escaped, symbol) { string.replace(escaped, symbol, "\\" <> symbol) },
  )
}

/// 文字列がクラス名の続き（英数字、`-`、`_`、エスケープ）で始まるか。
fn continues_class_name(rest: String) -> Bool {
  case string.first(rest) {
    Ok(char) ->
      string.contains(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_\\",
        char,
      )
    Error(Nil) -> False
  }
}

/// ビルドした CSS の `[data-theme=<name>]` のブロックの宣言を、変数名から値への表にする。
/// ブロックは入れ子を持たないので、開始から次の `}` までが宣言の並びである。
fn theme_variables(css: String, name: String) -> Dict(String, String) {
  let assert Ok(#(_, rest)) =
    string.split_once(css, "[data-theme=" <> name <> "]{")
  let assert Ok(#(block, _)) = string.split_once(rest, "}")
  block
  |> string.split(";")
  |> list.filter_map(fn(declaration) { string.split_once(declaration, ":") })
  |> dict.from_list
}

/// 2 つの色（`#rgb` か `#rrggbb`）の WCAG 2 のコントラスト比。明るいほうを分子に置く。
fn contrast_ratio(a: String, b: String) -> Float {
  let la = relative_luminance(a)
  let lb = relative_luminance(b)
  { float.max(la, lb) +. 0.05 } /. { float.min(la, lb) +. 0.05 }
}

/// 色（`#rgb` か `#rrggbb`）の WCAG 2 の相対輝度。
fn relative_luminance(color: String) -> Float {
  let assert "#" <> hex = color
  let channels = case string.length(hex) {
    3 -> string.to_graphemes(hex) |> list.map(fn(digit) { digit <> digit })
    6 -> [
      string.slice(hex, 0, 2),
      string.slice(hex, 2, 2),
      string.slice(hex, 4, 2),
    ]
    _ -> panic as { "not a hex color: " <> color }
  }
  let assert [r, g, b] = list.map(channels, linear_channel)
  0.2126 *. r +. 0.7152 *. g +. 0.0722 *. b
}

/// 2 桁の 16 進の値を、sRGB の成分から線形の成分に直す。
fn linear_channel(pair: String) -> Float {
  let assert Ok(value) = int.base_parse(pair, 16)
  let c = int.to_float(value) /. 255.0
  case c <=. 0.04045 {
    True -> c /. 12.92
    False -> {
      let assert Ok(linear) = float.power({ c +. 0.055 } /. 1.055, 2.4)
      linear
    }
  }
}
