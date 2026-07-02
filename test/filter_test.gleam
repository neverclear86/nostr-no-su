import gleam/json
import gleam/option.{None, Some}
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

pub fn p_tags_encode_test() {
  let query =
    Filter(..filter.new(), kinds: Some([24_133]), p_tags: Some(["abc", "def"]))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[24133],\"#p\":[\"abc\",\"def\"]}"
}

pub fn parse_pubkeys_test() {
  assert config.parse_pubkeys("") == []
  assert config.parse_pubkeys("a,b") == ["a", "b"]
  assert config.parse_pubkeys(" a , b ,") == ["a", "b"]
}

fn test_config(pubkeys: List(String)) -> config.Config {
  config.Config(
    relay_url: "wss://example.com",
    pubkeys: pubkeys,
    account_keys: [],
    bunker_secret: None,
  )
}

pub fn to_filter_without_pubkeys_test() {
  assert config.to_filter(test_config([]))
    == Filter(..filter.new(), limit: Some(20))
}

pub fn to_filter_with_pubkeys_test() {
  assert config.to_filter(test_config(["a"]))
    == Filter(..filter.new(), authors: Some(["a"]))
}

pub fn bunker_filter_test() {
  assert config.bunker_filter(["pk1", "pk2"], 1000)
    == Filter(
      ..filter.new(),
      kinds: Some([24_133]),
      p_tags: Some(["pk1", "pk2"]),
      since: Some(1000),
    )
}
