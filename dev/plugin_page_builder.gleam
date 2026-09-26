//// 管理 UI のプラグインのページの記述（`Dynamic` の入れ子）を組む builder。組むのは
//// 本体の `nostr_no_su/admin/plugin_view` が読める正しい形だけで、変換に失敗する形は
//// 使う側が手で組む。撮影用のサーバー（`admin_preview`）と、管理 UI の検査の
//// `support/admin_ui`・`support/admin_context` が使う。
////
//// `test/` のモジュールは `dev/` のモジュールを import できるが、逆はできないので、
//// テストからも使えるよう `dev/` に置く。`gleam export erlang-shipment` の成果物には
//// 入らない。

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}

/// 記述の最上位。`#{"sections" => [節, ...]}`。
pub fn page_sections(sections: List(Dynamic)) -> Dynamic {
  dynamic.properties([#(dynamic.string("sections"), dynamic.list(sections))])
}

/// 節（`type` = `"section"`）。`meta` は見出しの題の後ろに並べるインラインのリストで、
/// 空なら `meta` のキーを持たない。
pub fn section(
  title: String,
  meta: List(Dynamic),
  blocks: List(Dynamic),
) -> Dynamic {
  dynamic.properties(
    [
      #(dynamic.string("type"), dynamic.string("section")),
      #(dynamic.string("title"), dynamic.string(title)),
      #(dynamic.string("blocks"), dynamic.list(blocks)),
    ]
    |> list.append(case meta {
      [] -> []
      _ -> [#(dynamic.string("meta"), dynamic.list(meta))]
    }),
  )
}

/// `pairs` ブロック。`items` は `term` と、すでに組み立てた `value` の
/// インラインの対。
pub fn pairs_block(items: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("pairs")),
    #(
      dynamic.string("items"),
      dynamic.list(
        list.map(items, fn(item) {
          dynamic.properties([
            #(dynamic.string("term"), dynamic.string(item.0)),
            #(dynamic.string("value"), item.1),
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
    #(dynamic.string("type"), dynamic.string("table")),
    #(
      dynamic.string("headers"),
      dynamic.list(list.map(headers, dynamic.string)),
    ),
    #(dynamic.string("rows"), dynamic.list(list.map(rows, dynamic.list))),
  ])
}

/// `details` ブロック。`text` は開いたときに出す整形済みのテキスト。
pub fn details_block(summary: String, text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("details")),
    #(dynamic.string("summary"), dynamic.string(summary)),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `type` と `text` の 2 キーだけのブロックかインライン。`kind` は `type` の値で、
/// ブロックの `text`・`note` とインラインの `text`・`code`・`id` に使う。`id`
/// インラインは `pairs` の値だけで使える。
pub fn typed_text(kind: String, text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string(kind)),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `image` ブロック。`variant` が `None` なら `variant` のキーを持たない。
pub fn image_block(
  url: String,
  alt: String,
  variant: Option(String),
) -> Dynamic {
  dynamic.properties(
    [
      #(dynamic.string("type"), dynamic.string("image")),
      #(dynamic.string("url"), dynamic.string(url)),
      #(dynamic.string("alt"), dynamic.string(alt)),
    ]
    |> list.append(case variant {
      Some(value) -> [#(dynamic.string("variant"), dynamic.string(value))]
      None -> []
    }),
  )
}

/// `form` ブロック。`fields` は `checkbox_field/4` と `input_field/5` で組んだ欄の記述、
/// `submit` は送信ボタンの文字列。
pub fn form_block(fields: List(Dynamic), submit: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("form")),
    #(dynamic.string("fields"), dynamic.list(fields)),
    #(dynamic.string("submit"), dynamic.string(submit)),
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
    [
      #(dynamic.string("type"), dynamic.string("checkbox")),
      #(dynamic.string("name"), dynamic.string(name)),
      #(dynamic.string("label"), dynamic.string(label)),
      #(dynamic.string("checked"), dynamic.bool(checked)),
    ]
    |> list.append(case hint {
      Some(text) -> [#(dynamic.string("hint"), dynamic.string(text))]
      None -> []
    }),
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
    #(dynamic.string("type"), dynamic.string(kind)),
    #(dynamic.string("name"), dynamic.string(name)),
    #(dynamic.string("label"), dynamic.string(label)),
    #(dynamic.string("hint"), dynamic.string(hint)),
    #(dynamic.string("value"), dynamic.string(value)),
  ])
}

/// `badge` インライン。`table` のセルと節の `meta` で使える。
pub fn badge_inline(text: String, tone: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("badge")),
    #(dynamic.string("text"), dynamic.string(text)),
    #(dynamic.string("tone"), dynamic.string(tone)),
  ])
}

/// `kind` インライン。本体が kind の名前（無ければ番号）で出す。
pub fn kind_inline(kind: Int) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("kind")),
    #(dynamic.string("value"), dynamic.int(kind)),
  ])
}

/// `time` インライン。本体が相対時刻で出し、UTC の時刻を `title` に持たせる。
pub fn time_inline(seconds: Int) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("time")),
    #(dynamic.string("value"), dynamic.int(seconds)),
  ])
}
