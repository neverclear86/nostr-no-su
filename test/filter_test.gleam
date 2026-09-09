import gleam/json
import gleam/option.{None, Some}
import nostr_no_su/config
import nostr_no_su/nostr/filter.{Filter}

/// フィールドを何も設定しないフィルターは空の JSON オブジェクトになる。
pub fn empty_filter_encodes_to_empty_object_test() {
  assert filter.new() |> filter.to_json |> json.to_string == "{}"
}

/// エンコード結果には、設定済みのフィールドだけが現れる。
pub fn unset_fields_are_omitted_test() {
  let query = Filter(..filter.new(), kinds: Some([1, 7]), since: Some(123))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[1,7],\"since\":123}"
}

/// `p_tags` は NIP-01 の `#p` キーとしてエンコードされる。
pub fn p_tags_encode_test() {
  let query =
    Filter(..filter.new(), kinds: Some([24_133]), p_tags: Some(["abc", "def"]))
  assert filter.to_json(query) |> json.to_string
    == "{\"kinds\":[24133],\"#p\":[\"abc\",\"def\"]}"
}

/// カンマ区切りのリストは前後の空白を除去し、空の要素を取り除く。
pub fn parse_list_test() {
  assert config.parse_list("") == []
  assert config.parse_list("a,b") == ["a", "b"]
  assert config.parse_list(" a , b ,") == ["a", "b"]
}

/// `BUNKER_RELAY_URL` が設定されていれば、監視用リレーより優先される。
pub fn pick_bunker_relays_prefers_override_test() {
  assert config.pick_bunker_relays(["wss://x"], ["wss://a", "wss://b"])
    == ["wss://x"]
}

/// 上書きが空の場合は監視用リレーにフォールバックする。
pub fn pick_bunker_relays_falls_back_to_monitor_relays_test() {
  assert config.pick_bunker_relays([], ["wss://a", "wss://b"])
    == ["wss://a", "wss://b"]
}

/// どちらのリストも未設定なら、バンカーは既定のリレーを使う。
pub fn pick_bunker_relays_defaults_when_nothing_configured_test() {
  assert config.pick_bunker_relays([], []) == ["wss://relay.damus.io"]
}

/// 監視対象の pubkey だけが異なる設定。
fn test_config(pubkeys: List(String)) -> config.Config {
  config.Config(
    relay_urls: ["wss://example.com"],
    bunker_relay_urls: ["wss://example.com"],
    pubkeys: pubkeys,
    account_keys: [],
    bunker_secret: None,
  )
}

/// pubkey が無い場合、監視は直近イベントの一部を購読する。
pub fn to_filter_without_pubkeys_test() {
  assert config.to_filter(test_config([]))
    == Filter(..filter.new(), limit: Some(20))
}

/// pubkey がある場合、監視はその author を購読する。
pub fn to_filter_with_pubkeys_test() {
  assert config.to_filter(test_config(["a"]))
    == Filter(..filter.new(), authors: Some(["a"]))
}

/// バンカーのフィルターは、署名者宛の直近の kind 24133 イベントを選択する。
pub fn bunker_filter_test() {
  assert config.bunker_filter(["pk1", "pk2"], 1000)
    == Filter(
      ..filter.new(),
      kinds: Some([24_133]),
      p_tags: Some(["pk1", "pk2"]),
      since: Some(1000),
    )
}
