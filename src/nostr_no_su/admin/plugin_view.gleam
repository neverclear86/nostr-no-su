//// プラグインが返す管理 UI のページの記述を `admin/view` の部品に変換する、純粋な
//// 変換モジュール。
////
//// 記述は **段ごとに種別を閉じた 3 段の binary キーの Erlang map** である
//// （`docs/plugin-api.md` の第 13 章）。
////
//// - 最上位: `#{<<"sections">> => [節, ...]}`
//// - 節（`section`）: `title`（binary）、`blocks`（ブロックのリスト）
//// - ブロック: `text` / `note` / `pairs` / `table` / `alert` / `link` のいずれか
//// - インライン（`pairs` の値、`table` のセル）: `text` / `code` / `badge`
////   のいずれか（`badge` は `table` のセルだけ）
////
//// 深さのカウンターは持たない。ある段に合わない種別を置くと、その段を読む
//// decoder が失敗するため、深すぎる入れ子は構造的に `Error` になる。
////
//// **プラグインが選べるのは文字列・種別・`tone` だけである。** クラス名も
//// `href` も `id` も持ち込めない（`assets/admin.css` の方針）。描画は必ず
//// `admin/view` の部品を経由し、このモジュール自身が持つ生のクラス文字列は
//// `table` のセルの `code` インラインだけである。
////
//// プラグイン由来の文字列（節の見出しとブロックの中身）はすべて `lang="en"`
//// の祖先 1 つで包む。翻訳した文（空の節の案内）はその外に置く。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view

/// 節の描画に要る文脈。`page_href` は同じプラグインのページのキーからパスを
/// 組み立てる（`link` ブロック用）。キーがそのプラグインのページ一覧に無ければ
/// `Error(Nil)`。
pub type Context {
  Context(language: Language, page_href: fn(String) -> Result(String, Nil))
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
          html.div([attribute.lang("en")], [view.heading(title)]),
          view.empty_state(
            view.puzzle_icon(),
            i18n.text(context.language, i18n.PluginSectionEmpty),
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
          html.div([attribute.lang("en")], [view.heading(title), ..elements]),
        ]),
      )
    }
  }
}

/// ブロック 1 つを対応する部品にする。`pairs` の `items` が 0 件のときは空の
/// 状態の文にする。
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
          pair(indexed.0)
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
              ),
            ]),
          )
        _ -> Ok(view.summary_list(items))
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
        Ok(href) -> Ok(view.button_link(href, text, view.Normal))
        Error(Nil) -> Error("unknown page \"" <> page_key <> "\"")
      }
    }
    other -> Error("unknown type \"" <> other <> "\"")
  }
}

/// `pairs` の 1 件。値は `text` か `code` のインラインだけを許す
/// （`badge` は `table` のセルだけに置ける）。
fn pair(raw: Dynamic) -> Result(#(String, view.Value), String) {
  use term <- result.try(text_field(raw, "term"))
  use value_raw <- result.try(field(raw, "value", "missing value"))
  use kind <- result.try(text_field(value_raw, "type"))
  case kind {
    "text" -> {
      use text <- result.try(text_field(value_raw, "text"))
      Ok(#(term, view.Plain(text)))
    }
    "code" -> {
      use text <- result.try(text_field(value_raw, "text"))
      Ok(#(term, view.Code(text)))
    }
    "badge" -> Error("value: type \"badge\" is only allowed in table cells")
    other -> Error("value: unknown type \"" <> other <> "\"")
  }
}

/// `table` のセル 1 つ。`text`・`code`・`badge` のいずれか。`badge` はここでだけ
/// 使える。
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
      Ok(view.status_badge(badge_tone, text))
    }
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
