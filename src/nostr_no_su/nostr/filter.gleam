//// NIP-01 の REQ に載せる購読フィルター。
////
//// 本体が実際に使う `authors`、`kinds`、`#p`、`since`、`limit` の 5 つだけを
//// 持つ。`ids` や `#e`、`until` は必要になるまで足さない。

import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// NIP-01 の購読フィルター。未設定のフィールドは JSON から完全に省く。リレーは
/// `null` 値を拒否するため。
pub type Filter {
  Filter(
    authors: Option(List(String)),
    kinds: Option(List(Int)),
    p_tags: Option(List(String)),
    since: Option(Int),
    limit: Option(Int),
  )
}

/// 何も絞り込まない空のフィルター。ここから必要なフィールドだけを設定する。
pub fn new() -> Filter {
  Filter(authors: None, kinds: None, p_tags: None, since: None, limit: None)
}

/// フィルターを REQ に載せる JSON オブジェクトにする。未設定のフィールドは
/// キーごと省く。
pub fn to_json(filter: Filter) -> Json {
  [
    #("authors", option.map(filter.authors, json.array(_, of: json.string))),
    #("kinds", option.map(filter.kinds, json.array(_, of: json.int))),
    #("#p", option.map(filter.p_tags, json.array(_, of: json.string))),
    #("since", option.map(filter.since, json.int)),
    #("limit", option.map(filter.limit, json.int)),
  ]
  |> list.filter_map(fn(field) {
    case field {
      #(name, Some(value)) -> Ok(#(name, value))
      #(_, None) -> Error(Nil)
    }
  })
  |> json.object
}
