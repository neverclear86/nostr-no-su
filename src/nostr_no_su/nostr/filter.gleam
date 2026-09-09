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

pub fn new() -> Filter {
  Filter(authors: None, kinds: None, p_tags: None, since: None, limit: None)
}

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
