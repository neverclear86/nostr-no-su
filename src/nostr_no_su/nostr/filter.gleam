//// NIP-01 の REQ に載せる購読フィルター。
////
//// 持つのは `authors`、`kinds`、`#p`、`since`、`until`、`limit` の 6 つだけで、
//// `ids` や `#e` は必要になるまで足さない。本体が設定するのは `limit` 以外の
//// 5 つで、`limit` は今のところテストだけが使う。`until` を設定するのは
//// プラグインの取り直しの購読だけである。

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
    until: Option(Int),
    limit: Option(Int),
  )
}

/// 何も絞り込まない空のフィルター。ここから必要なフィールドだけを設定する。
pub fn new() -> Filter {
  Filter(
    authors: None,
    kinds: None,
    p_tags: None,
    since: None,
    until: None,
    limit: None,
  )
}

/// フィルターを REQ に載せる JSON オブジェクトにする。未設定のフィールドは
/// キーごと省く。
pub fn to_json(filter: Filter) -> Json {
  [
    #("authors", option.map(filter.authors, json.array(_, of: json.string))),
    #("kinds", option.map(filter.kinds, json.array(_, of: json.int))),
    #("#p", option.map(filter.p_tags, json.array(_, of: json.string))),
    #("since", option.map(filter.since, json.int)),
    #("until", option.map(filter.until, json.int)),
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
