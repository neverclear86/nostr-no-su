import gleam/json
import gleam/option.{None, Some}
import nostr_no_su/config
import nostr_no_su/nostr/filter.{Filter}

/// A filter with no fields set encodes to an empty JSON object.
pub fn empty_filter_encodes_to_empty_object_test() {
  assert filter.new() |> filter.to_json |> json.to_string == "{}"
}

/// Only the fields that are set appear in the encoded filter.
pub fn unset_fields_are_omitted_test() {
  let query = Filter(..filter.new(), kinds: Some([1, 7]), since: Some(123))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[1,7],\"since\":123}"
}

/// `p_tags` is encoded under the NIP-01 `#p` key.
pub fn p_tags_encode_test() {
  let query =
    Filter(..filter.new(), kinds: Some([24_133]), p_tags: Some(["abc", "def"]))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[24133],\"#p\":[\"abc\",\"def\"]}"
}

/// Comma-separated lists are trimmed and stripped of empty entries.
pub fn parse_list_test() {
  assert config.parse_list("") == []
  assert config.parse_list("a,b") == ["a", "b"]
  assert config.parse_list(" a , b ,") == ["a", "b"]
}

/// `BUNKER_RELAY_URL` wins over the monitor relays when it is set.
pub fn pick_bunker_relays_prefers_override_test() {
  assert config.pick_bunker_relays(["wss://x"], ["wss://a", "wss://b"])
    == ["wss://x"]
}

/// A blank override falls back to the monitor relays.
pub fn pick_bunker_relays_falls_back_to_monitor_relays_test() {
  assert config.pick_bunker_relays([], ["wss://a", "wss://b"])
    == ["wss://a", "wss://b"]
}

/// With neither list configured the bunker uses the default relay.
pub fn pick_bunker_relays_defaults_when_nothing_configured_test() {
  assert config.pick_bunker_relays([], []) == ["wss://relay.damus.io"]
}

/// A config that differs only in the pubkeys being monitored.
fn test_config(pubkeys: List(String)) -> config.Config {
  config.Config(
    relay_urls: ["wss://example.com"],
    bunker_relay_urls: ["wss://example.com"],
    pubkeys: pubkeys,
    account_keys: [],
    bunker_secret: None,
  )
}

/// Without pubkeys the monitor subscribes to a sample of recent events.
pub fn to_filter_without_pubkeys_test() {
  assert config.to_filter(test_config([]))
    == Filter(..filter.new(), limit: Some(20))
}

/// With pubkeys the monitor subscribes to those authors.
pub fn to_filter_with_pubkeys_test() {
  assert config.to_filter(test_config(["a"]))
    == Filter(..filter.new(), authors: Some(["a"]))
}

/// The bunker filter selects recent kind 24133 events for the signers.
pub fn bunker_filter_test() {
  assert config.bunker_filter(["pk1", "pk2"], 1000)
    == Filter(
      ..filter.new(),
      kinds: Some([24_133]),
      p_tags: Some(["pk1", "pk2"]),
      since: Some(1000),
    )
}
