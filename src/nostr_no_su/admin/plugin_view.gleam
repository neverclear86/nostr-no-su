//// プラグインが返す管理 UI のページの記述を `admin/view` の部品に変換する、純粋な
//// 変換モジュール。
////
//// 記述の型（段ごとに閉じた種別と、各種別の必須・任意のキー）は `docs/plugin-api.md` の
//// 13.3 節にある。深さのカウンターは持たない。ある段に合わない種別を置くと、その段を読む
//// decoder が失敗するため、深すぎる入れ子は構造的に `Error` になる。
////
//// **プラグインが選べるのは文字列・種別・`tone`・`variant`・真偽値だけである。** クラス名も
//// `href` も `id` も持ち込めない（`assets/admin.css` の方針）。描画は必ず
//// `admin/view` の部品を経由し、このモジュール自身が持つ生のクラス文字列は
//// `table` のセルの `code` インラインだけである。`form` の宛先は本体が決め
//// （`Context.form_action`）、プラグインは指定できない。`image` の `url` も
//// 同じで、`http` / `https` 以外の scheme は描かずに代替文だけを出す。
////
//// プラグイン由来の文字列（節の見出しとブロックの中身）はすべて
//// `Context.plugin_language` の `lang` を持つ祖先 1 つで包む。表示の言語を
//// 受け取らないプラグインでは `en` である。翻訳した文のうち、節の `blocks` が 0 件のときの案内は
//// その外に置き、`pairs` の `items` が 0 件のときの案内と、`pairs` の値の
//// `id` が出すコピーのラベルと案内（`view.identifier_cell`）と、インライン `kind` の名前と
//// `time` の相対時刻と、`image` の `url` を描かないときの理由（`view.plugin_image_placeholder`）は、
//// その祖先の中で表示の言語の `lang` を持つ要素で上書きする。`image` の代替文は
//// プラグイン由来の文字列なので上書きせず、祖先の `lang` を引き継ぐ。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view
import nostr_no_su/plugin_term.{BinaryKey}

/// 節の描画に要る文脈。`plugin_language` はプラグイン由来の文字列が書かれている
/// 言語のコード（`plugin.text_language`）。`page_href` は同じプラグインのページの
/// キーからパスを組み立てる（`link` ブロック用）。キーがそのプラグインのページ
/// 一覧に無ければ `Error(Nil)`。`form_action` は今開いているページ自身への POST の
/// 宛先（`form` ブロック用）。`now` は描画時点の Unix 秒（`time` インライン用）。
pub type Context {
  Context(
    language: Language,
    plugin_language: String,
    page_href: fn(String) -> Result(String, Nil),
    form_action: String,
    now: Int,
  )
}

/// 記述の最上位を読み、節の記述の並びをそのまま返す。最上位が map でない・
/// `sections` が無い・リストでないときは `Error`。
pub fn sections(description: Dynamic) -> Result(List(Dynamic), String) {
  decode.run(
    description,
    decode.field("sections", decode.list(decode.dynamic), decode.success),
  )
  |> result.replace_error(
    "top level: must be a map with a List field \"sections\", got "
    <> dynamic.classify(description),
  )
}

/// 節 1 つを `view.card` の要素にする。`type` は `"section"` でなければならない。任意の
/// `meta` はインラインのリストで、見出しの題の後ろに並べる（`meta_heading`）。`blocks` が
/// 空なら空の状態の文を出す。未知の種別、型の合わない値、深すぎる入れ子はこの節ひとつ
/// ぶんの `Error` になり、他の節の描画は止めない。
pub fn section(raw: Dynamic, context: Context) -> Result(Element(msg), String) {
  use kind <- result.try(text_field(raw, "type"))
  use _ <- result.try(case kind {
    "section" -> Ok(Nil)
    other -> Error("unknown type \"" <> other <> "\"")
  })
  use title <- result.try(text_field(raw, "title"))
  let label = "section \"" <> title <> "\""
  use heading <- result.try(
    meta_heading(raw, title, context)
    |> result.map_error(fn(reason) { label <> ": " <> reason }),
  )
  use blocks_raw <- result.try(list_field(raw, "blocks"))
  case blocks_raw {
    [] ->
      Ok(
        view.card([
          html.div([attribute.lang(context.plugin_language)], [
            heading,
          ]),
          section_empty_state(context.language),
        ]),
      )
    blocks -> {
      use elements <- result.try(
        try_map_numbered(blocks, label <> ": block", block(_, context)),
      )
      Ok(
        view.card([
          html.div([attribute.lang(context.plugin_language)], [
            heading,
            ..elements
          ]),
        ]),
      )
    }
  }
}

/// 節の見出し。`meta` が無ければ題だけの `view.heading`、あれば各項目を `inline` で描いて
/// `view.heading_with_meta` に渡す。`meta` がリストでなければ `meta must be a List, got <classify>`、
/// 項目の誤りは `meta #<添字>: <理由>`。
fn meta_heading(
  raw: Dynamic,
  title: String,
  context: Context,
) -> Result(Element(msg), String) {
  use meta <- result.try(plugin_term.optional_field(
    raw,
    BinaryKey,
    "meta",
    "a List",
    decode.list(decode.dynamic),
  ))
  case meta {
    None -> Ok(view.heading(title))
    Some(meta_raw) -> {
      use items <- result.try(
        try_map_numbered(meta_raw, "meta", inline(_, context)),
      )
      Ok(view.heading_with_meta(title, items))
    }
  }
}

/// ブロック 1 つを対応する部品にする。`pairs` の `items` が 0 件のときは空の
/// 状態の文にする。`image` の見た目は `variant` で選ぶ（`image_shape`）。`image` の
/// `url` の scheme が `http` / `https` でなければ、見た目に関係なく、画像の代わりに
/// 代替文だけの枠にする。
fn block(raw: Dynamic, context: Context) -> Result(Element(msg), String) {
  use kind <- result.try(text_field(raw, "type"))
  case kind {
    "text" -> {
      use text <- result.try(text_field(raw, "text"))
      Ok(view.paragraph(text))
    }
    "note" -> {
      use text <- result.try(text_field(raw, "text"))
      Ok(view.hint(text))
    }
    "pairs" -> {
      use items_raw <- result.try(list_field(raw, "items"))
      use items <- result.try(
        try_map_numbered(items_raw, "item", pair(_, context)),
      )
      case items {
        [] ->
          Ok(
            html.div([attribute.lang(i18n.code(context.language))], [
              section_empty_state(context.language),
            ]),
          )
        _ -> Ok(view.detail_list(items))
      }
    }
    "table" -> {
      use headers <- result.try(plugin_term.field(
        raw,
        BinaryKey,
        "headers",
        "a List of strings",
        decode.list(decode.string),
      ))
      use rows_raw <- result.try(list_field(raw, "rows"))
      use rows <- result.try(
        try_map_numbered(rows_raw, "row", fn(row_raw) {
          use cells_raw <- result.try(
            decode.run(row_raw, decode.list(decode.dynamic))
            |> result.replace_error("must be a List"),
          )
          list.try_map(cells_raw, fn(cell) {
            use element <- result.try(inline(cell, context))
            Ok(html.td([], [element]))
          })
        }),
      )
      Ok(view.table(headers, rows))
    }
    "alert" -> {
      use text <- result.try(text_field(raw, "text"))
      use alert_tone <- result.try(choice_field(raw, "tone", view.Info, tone))
      Ok(view.alert(alert_tone, [html.text(text)]))
    }
    "link" -> {
      use page_key <- result.try(text_field(raw, "page"))
      use text <- result.try(text_field(raw, "text"))
      case context.page_href(page_key) {
        Ok(href) ->
          Ok(view.button_link(href, view.TextFace(text), view.GhostButton))
        Error(Nil) -> Error("unknown page \"" <> page_key <> "\"")
      }
    }
    "form" -> {
      use fields_raw <- result.try(list_field(raw, "fields"))
      use submit <- result.try(text_field(raw, "submit"))
      case fields_raw {
        [] -> Error("fields must not be empty")
        _ -> {
          use fields <- result.try(try_map_numbered(
            fields_raw,
            "field",
            form_field,
          ))
          Ok(view.post_form(
            context.form_action,
            fields,
            submit,
            view.PrimaryButton,
            view.InForm,
          ))
        }
      }
    }
    "details" -> {
      use summary <- result.try(text_field(raw, "summary"))
      use text <- result.try(text_field(raw, "text"))
      Ok(view.details_panel(summary, [view.preformatted(text)]))
    }
    "image" -> {
      use url <- result.try(text_field(raw, "url"))
      use alt <- result.try(text_field(raw, "alt"))
      use shape <- result.try(choice_field(
        raw,
        "variant",
        view.ContainedImage,
        image_shape,
      ))
      case image_source_allowed(url) {
        True -> Ok(view.plugin_image(url, alt, shape))
        False ->
          Ok(view.plugin_image_placeholder(
            context.language,
            i18n.text(context.language, i18n.PluginImageNotShown),
            alt,
          ))
      }
    }
    other -> Error("unknown type \"" <> other <> "\"")
  }
}

/// 画像の `url` を `<img>` で読ませてよいか。`http` と `https` だけを許し、別の
/// scheme も scheme の無い URL も解釈できない文字列も許さない。
fn image_source_allowed(url: String) -> Bool {
  case uri.parse(url) {
    Ok(uri.Uri(scheme: Some("http"), ..)) -> True
    Ok(uri.Uri(scheme: Some("https"), ..)) -> True
    _ -> False
  }
}

/// `form` の欄 1 つ。`checkbox` は真偽値、`text` は 1 行、`textarea` は複数行の文字列の欄
/// にする。種別を共通の欄（`name`・`label`・`hint`）より先に照合するので、未知の種別は
/// ほかの欄の誤りより先に `unknown type "<種別>"` の `Error` になる。
fn form_field(raw: Dynamic) -> Result(Element(msg), String) {
  use kind <- result.try(text_field(raw, "type"))
  use finish <- result.try(case kind {
    "checkbox" -> Ok(checkbox_input)
    "text" -> Ok(text_input(view.plugin_text_field))
    "textarea" -> Ok(text_input(view.plugin_textarea_field))
    other -> Error("unknown type \"" <> other <> "\"")
  })
  use name <- result.try(field_name(raw))
  use label <- result.try(text_field(raw, "label"))
  use hint <- result.try(optional_text_field(raw, "hint"))
  finish(raw, name, label, hint)
}

/// `checkbox` の欄の、共通の欄より後ろ。任意の `checked` を読み、無ければ未チェックにする。
fn checkbox_input(
  raw: Dynamic,
  name: String,
  label: String,
  hint: Option(String),
) -> Result(Element(msg), String) {
  use checked <- result.try(plugin_term.optional_field(
    raw,
    BinaryKey,
    "checked",
    "a Bool",
    decode.bool,
  ))
  Ok(view.plugin_checkbox_row(name, label, hint, option.unwrap(checked, False)))
}

/// `text` と `textarea` の欄の、共通の欄より後ろを `draw` で描く関数を返す。任意の `value` を
/// 読み、無ければ空文字列を初期値にする。
fn text_input(
  draw: fn(String, String, Option(String), String) -> Element(msg),
) -> fn(Dynamic, String, String, Option(String)) -> Result(Element(msg), String) {
  fn(raw, name, label, hint) {
    use value <- result.try(optional_text_field(raw, "value"))
    Ok(draw(name, label, hint, option.unwrap(value, "")))
  }
}

/// 欄の `name` を読み、`field_name_alphabet` だけからなることを確かめる。外れていれば
/// `name "<name>" must match [A-Za-z0-9_-]+`。
fn field_name(raw: Dynamic) -> Result(String, String) {
  use name <- result.try(text_field(raw, "name"))
  case plugin_term.consists_of(name, field_name_alphabet) {
    True -> Ok(name)
    False -> Error("name \"" <> name <> "\" must match [A-Za-z0-9_-]+")
  }
}

/// 欄の `name` に許す文字。`plugin_term.consists_of` に渡す。
const field_name_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"

/// `key` の任意の値を String として読む。規則は `plugin_term.optional_field` と同じ。
fn optional_text_field(
  raw: Dynamic,
  key: String,
) -> Result(Option(String), String) {
  plugin_term.optional_field(raw, BinaryKey, key, "a String", decode.string)
}

/// `key` の任意の値を文字列として読み、`parse` で値に写す。無ければ `default`、文字列で
/// なければ `<key> must be a String, got <classify>`、写せなければ `parse` の `Error`。
fn choice_field(
  raw: Dynamic,
  key: String,
  default: a,
  parse: fn(String) -> Result(a, String),
) -> Result(a, String) {
  use name <- result.try(optional_text_field(raw, key))
  case name {
    None -> Ok(default)
    Some(name) -> parse(name)
  }
}

/// `key` の必須の値を、要素の型を問わないリストとして読む。誤りの文は `plugin_term.field` と同じ。
fn list_field(raw: Dynamic, key: String) -> Result(List(Dynamic), String) {
  plugin_term.field(raw, BinaryKey, key, "a List", decode.list(decode.dynamic))
}

/// 要素を先頭から `f` で検証し、最初の誤りで止める。誤りの理由には `<name> #<添字>: ` を
/// 前置する（添字は 0 起点）。
fn try_map_numbered(
  items: List(a),
  name: String,
  f: fn(a) -> Result(b, String),
) -> Result(List(b), String) {
  plugin_term.try_map_indexed(items, fn(item, index) {
    f(item)
    |> result.map_error(fn(reason) {
      name <> " #" <> int.to_string(index) <> ": " <> reason
    })
  })
}

/// 節や `pairs` に表示する中身が無いときの空の状態の文（`i18n.PluginSectionEmpty`）。
fn section_empty_state(language: Language) -> Element(msg) {
  view.empty_state(
    view.puzzle_icon(),
    i18n.text(language, i18n.PluginSectionEmpty),
    [],
  )
}

/// `pairs` の 1 件。値は `text`・`code`・`id`・`kind`・`time` のインラインだけを許す
/// （`badge` は `table` のセルと節の `meta` だけに置ける）。`kind` と `time` は `inline` で描き、
/// `dd` で包む。
fn pair(
  raw: Dynamic,
  context: Context,
) -> Result(#(String, Element(msg)), String) {
  use term <- result.try(text_field(raw, "term"))
  use value_raw <- result.try(
    plugin_term.lookup(raw, BinaryKey, "value")
    |> option.to_result("missing value"),
  )
  use kind <- result.try(text_field(value_raw, "type"))
  case kind {
    "text" -> {
      use text <- result.try(text_field(value_raw, "text"))
      Ok(#(term, view.value_cell(view.Plain(text))))
    }
    "code" -> {
      use text <- result.try(text_field(value_raw, "text"))
      Ok(#(term, view.value_cell(view.Code(text))))
    }
    "id" -> {
      use text <- result.try(text_field(value_raw, "text"))
      Ok(#(
        term,
        view.identifier_cell(
          context.language,
          text,
          i18n.text(context.language, i18n.Copy),
        ),
      ))
    }
    "kind" | "time" -> {
      use element <- result.try(inline(value_raw, context))
      Ok(#(term, html.dd([], [element])))
    }
    "badge" ->
      Error(
        "value: type \"badge\" is only allowed in table cells and section meta",
      )
    other -> Error("value: unknown type \"" <> other <> "\"")
  }
}

/// `table` のセルと節の `meta` の 1 件。`text`・`code`・`badge`・`kind`・`time` のいずれかで、
/// `id` はここでは使えない。`kind` は `i18n.EventKind` の名前、`time` は `view.relative_time` の
/// 相対時刻を、UTC の時刻（`view.utc_time`）を `title` に持たせて出し、どちらも表示の言語の
/// `lang` を持つ `span` にする。`value` は 0 以上の整数である。`pairs` の値の `kind` と `time` も
/// ここで描く。
fn inline(raw: Dynamic, context: Context) -> Result(Element(msg), String) {
  use kind <- result.try(text_field(raw, "type"))
  case kind {
    "text" -> {
      use text <- result.try(text_field(raw, "text"))
      Ok(html.text(text))
    }
    "code" -> {
      use text <- result.try(text_field(raw, "text"))
      Ok(
        html.span([attribute.class("font-mono text-xs break-all")], [
          html.text(text),
        ]),
      )
    }
    "badge" -> {
      use text <- result.try(text_field(raw, "text"))
      use badge_tone <- result.try(choice_field(raw, "tone", view.Neutral, tone))
      Ok(view.status_chip(view.ToneChip(badge_tone), text))
    }
    "kind" -> {
      use kind <- result.try(non_negative_int_field(raw, "value"))
      Ok(view.in_language(
        i18n.code(context.language),
        i18n.text(context.language, i18n.EventKind(kind)),
      ))
    }
    "time" -> {
      use at <- result.try(non_negative_int_field(raw, "value"))
      Ok(
        html.span(
          [
            attribute.lang(i18n.code(context.language)),
            attribute.title(view.utc_time(at)),
          ],
          [
            html.text(i18n.text(
              context.language,
              view.relative_time(context.now, at),
            )),
          ],
        ),
      )
    }
    "id" -> Error("type \"id\" is only allowed in pairs values")
    other -> Error("unknown type \"" <> other <> "\"")
  }
}

/// `image` の `variant` の文字列を見た目に写す。`icon` と `banner` 以外は
/// `unknown variant "<値>"`。
fn image_shape(name: String) -> Result(view.ImageShape, String) {
  case name {
    "icon" -> Ok(view.IconImage)
    "banner" -> Ok(view.BannerImage)
    other -> Error("unknown variant \"" <> other <> "\"")
  }
}

/// `tone` の文字列を `view.Tone` の 5 値に写す。それ以外は `unknown tone "<値>"`。
fn tone(name: String) -> Result(view.Tone, String) {
  case name {
    "neutral" -> Ok(view.Neutral)
    "success" -> Ok(view.Success)
    "warning" -> Ok(view.Warning)
    "failure" -> Ok(view.Failure)
    "info" -> Ok(view.Info)
    other -> Error("unknown tone \"" <> other <> "\"")
  }
}

/// `key` の値を 0 以上の整数として読む。欠けていれば `missing <key>`、整数でなければ
/// `<key> must be an Int, got <classify>`、負なら `<key> must not be negative, got <値>`。
fn non_negative_int_field(raw: Dynamic, key: String) -> Result(Int, String) {
  use value <- result.try(plugin_term.field(
    raw,
    BinaryKey,
    key,
    "an Int",
    decode.int,
  ))
  case value < 0 {
    True -> Error(key <> " must not be negative, got " <> int.to_string(value))
    False -> Ok(value)
  }
}

/// `key` の値を String として読む。欠けていれば `missing <key>`、型が合わなけ
/// れば `<key> must be a String, got <classify>`。
fn text_field(raw: Dynamic, key: String) -> Result(String, String) {
  plugin_term.field(raw, BinaryKey, key, "a String", decode.string)
}
