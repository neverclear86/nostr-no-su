import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// A NIP-01 subscription filter. Unset fields are omitted from the JSON
/// entirely: relays reject `null` values.
pub type Filter {
  Filter(
    authors: Option(List(String)),
    kinds: Option(List(Int)),
    since: Option(Int),
    limit: Option(Int),
  )
}

pub fn new() -> Filter {
  Filter(authors: None, kinds: None, since: None, limit: None)
}

pub fn to_json(filter: Filter) -> Json {
  [
    #("authors", option.map(filter.authors, json.array(_, of: json.string))),
    #("kinds", option.map(filter.kinds, json.array(_, of: json.int))),
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
