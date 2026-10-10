//// 管理 UI のプラグインのページの記述（`Dynamic` の入れ子）を組む builder。組むのは
//// 本体の `nostr_no_su/admin/plugin_view` が読める正しい形だけで、変換に失敗する形は
//// 使う側が手で組む。
////
//// `test/` のモジュールは `dev/` のモジュールを import できるが、逆はできないので、
//// テストからも使えるよう `dev/` に置く。`gleam export erlang-shipment` の成果物には
//// 入らない。

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}

/// 記述 map の 1 組。
fn entry(key: String, value: Dynamic) -> #(Dynamic, Dynamic) {
  #(dynamic.string(key), value)
}

/// `value` が `Some` のときだけ `key` の組を持つリスト。
fn optional_entry(
  key: String,
  value: Option(Dynamic),
) -> List(#(Dynamic, Dynamic)) {
  case value {
    Some(value) -> [entry(key, value)]
    None -> []
  }
}

/// 記述の最上位。`#{"sections" => [節, ...]}`。
pub fn page_sections(sections: List(Dynamic)) -> Dynamic {
  dynamic.properties([entry("sections", dynamic.list(sections))])
}

/// 節（`type` = `"section"`）。`meta` は見出しの題の後ろに並べるインラインのリストで、
/// 空なら `meta` のキーを持たない。
pub fn section(
  title: String,
  meta: List(Dynamic),
  blocks: List(Dynamic),
) -> Dynamic {
  dynamic.properties(
    list.flatten([
      [
        entry("type", dynamic.string("section")),
        entry("title", dynamic.string(title)),
        entry("blocks", dynamic.list(blocks)),
      ],
      optional_entry("meta", case meta {
        [] -> None
        _ -> Some(dynamic.list(meta))
      }),
    ]),
  )
}

/// `pairs` ブロック。`items` は `term` と、すでに組み立てた `value` の
/// インラインの対。
pub fn pairs_block(items: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("pairs")),
    entry(
      "items",
      dynamic.list(
        list.map(items, fn(item) {
          dynamic.properties([
            entry("term", dynamic.string(item.0)),
            entry("value", item.1),
          ])
        }),
      ),
    ),
  ])
}

/// `table` ブロック。`rows` の各セルはすでに組み立てたインライン。
pub fn table_block(
  headers: List(String),
  rows: List(List(Dynamic)),
) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("table")),
    entry("headers", dynamic.list(list.map(headers, dynamic.string))),
    entry("rows", dynamic.list(list.map(rows, dynamic.list))),
  ])
}

/// `details` ブロック。`text` は開いたときに出す整形済みのテキスト。
pub fn details_block(summary: String, text: String) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("details")),
    entry("summary", dynamic.string(summary)),
    entry("text", dynamic.string(text)),
  ])
}

/// `type` と `text` の 2 キーだけのブロックかインライン。`kind` は `type` の値で、
/// ブロックの `text`・`note` とインラインの `text`・`code`・`id` に使う。`id`
/// インラインは `pairs` の値だけで使える。
pub fn typed_text(kind: String, text: String) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string(kind)),
    entry("text", dynamic.string(text)),
  ])
}

/// `link` ブロック。`page` は遷移先のページのキー、`text` はリンクの文字列。
pub fn link_block(page: String, text: String) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("link")),
    entry("page", dynamic.string(page)),
    entry("text", dynamic.string(text)),
  ])
}

/// `alert` ブロック。`tone` のキーを持たない。
pub fn alert_block(text: String) -> Dynamic {
  typed_text("alert", text)
}

/// `image` ブロック。`variant` が `None` なら `variant` のキーを持たない。
pub fn image_block(
  url: String,
  alt: String,
  variant: Option(String),
) -> Dynamic {
  dynamic.properties(
    list.flatten([
      [
        entry("type", dynamic.string("image")),
        entry("url", dynamic.string(url)),
        entry("alt", dynamic.string(alt)),
      ],
      optional_entry("variant", option.map(variant, dynamic.string)),
    ]),
  )
}

/// `form` ブロック。`fields` は `checkbox_field/4` と `input_field/5` で組んだ欄の記述、
/// `submit` は送信ボタンの文字列。
pub fn form_block(fields: List(Dynamic), submit: String) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("form")),
    entry("fields", dynamic.list(fields)),
    entry("submit", dynamic.string(submit)),
  ])
}

/// `checkbox` の欄。`name` が送信名、`hint` が欄の下の説明で、`None` なら `hint` の
/// キーを持たない。
pub fn checkbox_field(
  name name: String,
  label label: String,
  hint hint: Option(String),
  checked checked: Bool,
) -> Dynamic {
  dynamic.properties(
    list.flatten([
      [
        entry("type", dynamic.string("checkbox")),
        entry("name", dynamic.string(name)),
        entry("label", dynamic.string(label)),
        entry("checked", dynamic.bool(checked)),
      ],
      optional_entry("hint", option.map(hint, dynamic.string)),
    ]),
  )
}

/// 文字列の欄。`kind` は `type` の値（1 行の `text` か複数行の `textarea`）、`name` が
/// 送信名、`hint` が欄の下の説明、`value` が初期値。
pub fn input_field(
  kind kind: String,
  name name: String,
  label label: String,
  hint hint: String,
  value value: String,
) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string(kind)),
    entry("name", dynamic.string(name)),
    entry("label", dynamic.string(label)),
    entry("hint", dynamic.string(hint)),
    entry("value", dynamic.string(value)),
  ])
}

/// `badge` インライン。`table` のセルと節の `meta` で使える。
pub fn badge_inline(text: String, tone: String) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("badge")),
    entry("text", dynamic.string(text)),
    entry("tone", dynamic.string(tone)),
  ])
}

/// `kind` インライン。本体が kind の名前（無ければ番号）で出す。
pub fn kind_inline(kind: Int) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("kind")),
    entry("value", dynamic.int(kind)),
  ])
}

/// `time` インライン。本体が相対時刻で出し、UTC の時刻を `title` に持たせる。
pub fn time_inline(seconds: Int) -> Dynamic {
  dynamic.properties([
    entry("type", dynamic.string("time")),
    entry("value", dynamic.int(seconds)),
  ])
}
