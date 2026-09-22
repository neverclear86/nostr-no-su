//// ビルドした管理 UI のスタイルシート（`priv/static/admin.css`）と、ページの中のスタイルの検査。

import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
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
  let css = admin_ui.static_file(view.stylesheet_segments)
  let undefined =
    pages()
    |> list.flat_map(classes)
    |> list.unique
    |> list.filter(fn(class) { !defines(css, class) })
  assert undefined == []
}

/// ビルドした CSS がロゴの 2 色（体の紺、尻尾の青緑）を運ぶ。ロゴの色がテーマに入ったことを
/// 自動で表す唯一の検査で、CSS の差分検査（`stylesheet_defines_every_rendered_class_test`）は
/// ビルドの新しさしか見ない。
pub fn the_themes_carry_the_logo_colors_test() {
  let css = admin_ui.static_file(view.stylesheet_segments)
  assert string.contains(css, "--color-primary:#183965")
  assert string.contains(css, "--color-primary:#3b70ba")
  assert string.contains(css, "--color-accent:#28b9be")
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
    [":", "/", "[", "]", "(", ")", ",", "."],
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
