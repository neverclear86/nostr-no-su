//// プラグインが返す管理 UI のページの記述を `admin/view` の部品に変換する、純粋な
//// 変換モジュール。
////
//// 記述は **段ごとに種別を閉じた 3 段の binary キーの Erlang map** である
//// （`docs/plugin-api.md` の第 13 章）。
////
//// - 最上位: `#{<<"sections">> => [節, ...]}`
//// - 節（`section`）: `title`（binary）、`blocks`（ブロックのリスト）
//// - ブロック: `text` / `note` / `pairs` / `table` / `alert` / `link` / `form` /
////   `details` / `image` のいずれか
//// - インライン（`pairs` の値、`table` のセル）: `text` / `code` / `badge` / `id`
////   のいずれか（`badge` は `table` のセルだけ、`id` は `pairs` の値だけ）
//// - `form` の欄: `checkbox` / `text` / `textarea` のいずれか
////
//// 深さのカウンターは持たない。ある段に合わない種別を置くと、その段を読む
//// decoder が失敗するため、深すぎる入れ子は構造的に `Error` になる。
////
//// **プラグインが選べるのは文字列・種別・`tone`・真偽値だけである。** クラス名も
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
//// `id` が出すコピーのラベルと案内（`view.identifier_cell`）と、`image` の
//// `url` を描かないときの理由（`view.plugin_image_placeholder`）は、
//// その祖先の中で表示の言語の `lang` を持つ要素で上書きする。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view

/// 節の描画に要る文脈。`page_href` は同じプラグインのページのキーからパスを
/// 組み立てる（`link` ブロック用）。キーがそのプラグインのページ一覧に無ければ
/// `Error(Nil)`。`form_action` は今開いているページ自身への POST の宛先
/// （`form` ブロック用）。
pub type Context {
  Context(
    language: Language,
    plugin_language: String,
    page_href: fn(String) -> Result(String, Nil),
    form_action: String,
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

/// 節 1 つを `view.card` の要素にする。`type` は `"section"` でなければならない
/// （決めたこと 10）。`blocks` が空なら空の状態の文を出す。未知の種別、型の合わ
/// ない値、深すぎる入れ子はこの節ひとつぶんの `Error` になり、他の節の描画は
/// 止めない。
pub fn section(raw: Dynamic, context: Context) -> Result(Element(msg), String) {
  use kind <- result.try(text_field(raw, "type"))
  use _ <- result.try(case kind {
    "section" -> Ok(Nil)
    other -> Error("unknown type \"" <> other <> "\"")
  })
  use title <- result.try(text_field(raw, "title"))
  let label = "section \"" <> title <> "\""
  use blocks_raw <- result.try(typed_field(
    raw,
    "blocks",
    decode.list(decode.dynamic),
    "a List",
  ))
  case blocks_raw {
    [] ->
      Ok(
        view.card([
          html.div([attribute.lang(context.plugin_language)], [
            view.heading(title),
          ]),
          view.empty_state(
            view.puzzle_icon(),
            i18n.text(context.language, i18n.PluginSectionEmpty),
            [],
          ),
        ]),
      )
    blocks -> {
      use elements <- result.try(
        blocks
        |> list.index_map(fn(raw_block, index) { #(raw_block, index) })
        |> list.try_map(fn(pair) {
          block(pair.0, context)
          |> result.map_error(fn(reason) {
            label <> ": block #" <> int.to_string(pair.1) <> ": " <> reason
          })
        }),
      )
      Ok(
        view.card([
          html.div([attribute.lang(context.plugin_language)], [
            view.heading(title),
            ..elements
          ]),
        ]),
      )
    }
  }
}

/// ブロック 1 つを対応する部品にする。`pairs` の `items` が 0 件のときは空の
/// 状態の文にする。`image` の `url` の scheme が `http` / `https` でなければ、
/// 画像の代わりに代替文だけの枠にする。
fn block(raw: Dynamic, context: Context) -> Result(Element(msg), String) {
  use kind <- result.try(text_field(raw, "type"))
  case kind {
    "text" -> {
      use text <- result.try(text_field(raw, "text"))
      Ok(view.form_description(text))
    }
    "note" -> {
      use text <- result.try(text_field(raw, "text"))
      Ok(view.hint(text))
    }
    "pairs" -> {
      use items_raw <- result.try(typed_field(
        raw,
        "items",
        decode.list(decode.dynamic),
        "a List",
      ))
      use items <- result.try(
        items_raw
        |> list.index_map(fn(raw_item, index) { #(raw_item, index) })
        |> list.try_map(fn(indexed) {
          pair(indexed.0, context)
          |> result.map_error(fn(reason) {
            "item #" <> int.to_string(indexed.1) <> ": " <> reason
          })
        }),
      )
      case items {
        [] ->
          Ok(
            html.div([attribute.lang(i18n.code(context.language))], [
              view.empty_state(
                view.puzzle_icon(),
                i18n.text(context.language, i18n.PluginSectionEmpty),
                [],
              ),
            ]),
          )
        _ -> Ok(view.detail_list(items))
      }
    }
    "table" -> {
      use headers <- result.try(typed_field(
        raw,
        "headers",
        decode.list(decode.string),
        "a List of strings",
      ))
      use rows_raw <- result.try(typed_field(
        raw,
        "rows",
        decode.list(decode.dynamic),
        "a List",
      ))
      use rows <- result.try(
        rows_raw
        |> list.index_map(fn(row_raw, index) { #(row_raw, index) })
        |> list.try_map(fn(indexed) {
          let #(row_raw, index) = indexed
          {
            use cells_raw <- result.try(
              decode.run(row_raw, decode.list(decode.dynamic))
              |> result.replace_error("must be a List"),
            )
            list.try_map(cells_raw, fn(cell) {
              use element <- result.try(inline(cell))
              Ok(html.td([], [element]))
            })
          }
          |> result.map_error(fn(reason) {
            "row #" <> int.to_string(index) <> ": " <> reason
          })
        }),
      )
      Ok(view.table(headers, rows))
    }
    "alert" -> {
      use text <- result.try(text_field(raw, "text"))
      use alert_tone <- result.try(tone(raw, view.Info))
      Ok(view.alert(alert_tone, [html.text(text)]))
    }
    "link" -> {
      use page_key <- result.try(text_field(raw, "page"))
      use text <- result.try(text_field(raw, "text"))
      case context.page_href(page_key) {
        Ok(href) -> Ok(view.button_link(href, text, view.GhostButton))
        Error(Nil) -> Error("unknown page \"" <> page_key <> "\"")
      }
    }
    "form" -> {
      use fields_raw <- result.try(typed_field(
        raw,
        "fields",
        decode.list(decode.dynamic),
        "a List",
      ))
      use submit <- result.try(text_field(raw, "submit"))
      case fields_raw {
        [] -> Error("fields must not be empty")
        _ -> {
          use fields <- result.try(
            fields_raw
            |> list.index_map(fn(raw_field, index) { #(raw_field, index) })
            |> list.try_map(fn(indexed) {
              form_field(indexed.0)
              |> result.map_error(fn(reason) {
                "field #" <> int.to_string(indexed.1) <> ": " <> reason
              })
            }),
          )
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
      case image_source_allowed(url) {
        True -> Ok(view.plugin_image(url, alt))
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
/// にする。ほかの種別はその節ひとつぶんの `Error` にする。
fn form_field(raw: Dynamic) -> Result(Element(msg), String) {
  use kind <- result.try(text_field(raw, "type"))
  case kind {
    "checkbox" -> {
      use name <- result.try(field_name(raw))
      use label <- result.try(text_field(raw, "label"))
      use hint <- result.try(optional_text_field(raw, "hint"))
      use checked <- result.try(bool_field(raw, "checked", False))
      Ok(view.plugin_checkbox_row(name, label, hint, checked))
    }
    "text" -> {
      use name <- result.try(field_name(raw))
      use label <- result.try(text_field(raw, "label"))
      use hint <- result.try(optional_text_field(raw, "hint"))
      use value <- result.try(optional_text_field(raw, "value"))
      Ok(view.plugin_text_field(name, label, hint, option.unwrap(value, "")))
    }
    "textarea" -> {
      use name <- result.try(field_name(raw))
      use label <- result.try(text_field(raw, "label"))
      use hint <- result.try(optional_text_field(raw, "hint"))
      use value <- result.try(optional_text_field(raw, "value"))
      Ok(view.plugin_textarea_field(name, label, hint, option.unwrap(value, "")))
    }
    other -> Error("unknown type \"" <> other <> "\"")
  }
}

/// 欄の `name` を読み、`field_name_alphabet` だけからなることを確かめる。外れていれば
/// `name "<name>" must match [A-Za-z0-9_-]+`。
fn field_name(raw: Dynamic) -> Result(String, String) {
  use name <- result.try(text_field(raw, "name"))
  case field_name_ok(name) {
    True -> Ok(name)
    False -> Error("name \"" <> name <> "\" must match [A-Za-z0-9_-]+")
  }
}

/// 欄の `name` に許す文字。`plugin_config` の `normalize` と同じ考え方で、許す文字を
/// 並べた定数と `string.contains` で判定する。
const field_name_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"

/// `name` が `field_name_alphabet` だけからなり、空でないこと。
fn field_name_ok(name: String) -> Bool {
  name != ""
  && name
  |> string.to_graphemes
  |> list.all(fn(character) { string.contains(field_name_alphabet, character) })
}

/// `key` の値。無ければ `default`、真偽値でなければ
/// `<key> must be a Bool, got <classify>`。
fn bool_field(
  raw: Dynamic,
  key: String,
  default: Bool,
) -> Result(Bool, String) {
  case lookup(raw, key) {
    None -> Ok(default)
    Some(value) ->
      decode.run(value, decode.bool)
      |> result.replace_error(
        key <> " must be a Bool, got " <> dynamic.classify(value),
      )
  }
}

/// `key` の任意の値を String として読む。無ければ `None`、型が合わなければ
/// `<key> must be a String, got <classify>`。
fn optional_text_field(
  raw: Dynamic,
  key: String,
) -> Result(Option(String), String) {
  case lookup(raw, key) {
    None -> Ok(None)
    Some(value) ->
      decode.run(value, decode.string)
      |> result.map(Some)
      |> result.replace_error(
        key <> " must be a String, got " <> dynamic.classify(value),
      )
  }
}

/// `pairs` の 1 件。値は `text`・`code`・`id` のインラインだけを許す
/// （`badge` は `table` のセルだけに置ける）。
fn pair(
  raw: Dynamic,
  context: Context,
) -> Result(#(String, Element(msg)), String) {
  use term <- result.try(text_field(raw, "term"))
  use value_raw <- result.try(field(raw, "value", "missing value"))
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
    "badge" -> Error("value: type \"badge\" is only allowed in table cells")
    other -> Error("value: unknown type \"" <> other <> "\"")
  }
}

/// `table` のセル 1 つ。`text`・`code`・`badge` のいずれか。`badge` はここでだけ
/// 使え、`id` はここでは使えない。
fn inline(raw: Dynamic) -> Result(Element(msg), String) {
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
      use badge_tone <- result.try(tone(raw, view.Neutral))
      Ok(view.status_chip(view.ToneChip(badge_tone), text))
    }
    "id" -> Error("type \"id\" is only allowed in pairs values")
    other -> Error("unknown type \"" <> other <> "\"")
  }
}

/// `tone` フィールド。無ければ `default`。`view.Tone` の 5 値以外は `Error`。
fn tone(raw: Dynamic, default: view.Tone) -> Result(view.Tone, String) {
  case lookup(raw, "tone") {
    None -> Ok(default)
    Some(value) ->
      case decode.run(value, decode.string) {
        Error(_) ->
          Error("tone must be a String, got " <> dynamic.classify(value))
        Ok("neutral") -> Ok(view.Neutral)
        Ok("success") -> Ok(view.Success)
        Ok("warning") -> Ok(view.Warning)
        Ok("failure") -> Ok(view.Failure)
        Ok("info") -> Ok(view.Info)
        Ok(other) -> Error("unknown tone \"" <> other <> "\"")
      }
  }
}

/// `key` の値を String として読む。欠けていれば `missing <key>`、型が合わなけ
/// れば `<key> must be a String, got <classify>`。
fn text_field(raw: Dynamic, key: String) -> Result(String, String) {
  typed_field(raw, key, decode.string, "a String")
}

/// `key` の値を `decoder` で読む。欠けていれば `missing <key>`、型が合わなけ
/// れば `<key> must be <expected>, got <classify>`。
fn typed_field(
  raw: Dynamic,
  key: String,
  decoder: decode.Decoder(a),
  expected: String,
) -> Result(a, String) {
  use value <- result.try(field(raw, key, "missing " <> key))
  decode.run(value, decoder)
  |> result.replace_error(
    key <> " must be " <> expected <> ", got " <> dynamic.classify(value),
  )
}

/// binary キーの map から `key` の生の値を読む。無ければ `missing_error`。
fn field(
  raw: Dynamic,
  key: String,
  missing_error: String,
) -> Result(Dynamic, String) {
  case lookup(raw, key) {
    Some(value) -> Ok(value)
    None -> Error(missing_error)
  }
}

/// binary キーの map から任意のキーを取り出す。無ければ（map ですらなければ）
/// `None`。
fn lookup(raw: Dynamic, key: String) -> Option(Dynamic) {
  let decoder =
    decode.optional_field(
      key,
      None,
      decode.map(decode.dynamic, Some),
      decode.success,
    )
  decode.run(raw, decoder)
  |> result.unwrap(None)
}
