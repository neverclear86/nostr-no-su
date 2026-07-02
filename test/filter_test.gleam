import gleam/json
import gleam/option.{Some}
import nostr_no_su/config
import nostr_no_su/nostr/filter.{Filter}

pub fn empty_filter_encodes_to_empty_object_test() {
  assert filter.new() |> filter.to_json |> json.to_string == "{}"
}

pub fn unset_fields_are_omitted_test() {
  let query = Filter(..filter.new(), kinds: Some([1, 7]), since: Some(123))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[1,7],\"since\":123}"
}

pub fn parse_pubkeys_test() {
  assert config.parse_pubkeys("") == []
  assert config.parse_pubkeys("a,b") == ["a", "b"]
  assert config.parse_pubkeys(" a , b ,") == ["a", "b"]
}

pub fn to_filter_without_pubkeys_test() {
  let loaded = config.Config(relay_url: "wss://example.com", pubkeys: [])
  assert config.to_filter(loaded) == Filter(..filter.new(), limit: Some(20))
}

pub fn to_filter_with_pubkeys_test() {
  let loaded = config.Config(relay_url: "wss://example.com", pubkeys: ["a"])
  assert config.to_filter(loaded)
    == Filter(..filter.new(), authors: Some(["a"]))
}
