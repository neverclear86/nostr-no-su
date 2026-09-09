import envoy
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

/// 空文字列の環境変数は未設定として扱う。docker compose は未設定の変数を空文字列
/// として渡すため、`DATABASE_URL=` で保存を無効にできる必要がある。
pub fn empty_environment_variables_are_unset_test() {
  envoy.set("DATABASE_URL", "")
  assert config.load().database_url == None

  envoy.set("DATABASE_URL", "postgres://user@host:5432/db")
  assert config.load().database_url == Some("postgres://user@host:5432/db")

  envoy.unset("DATABASE_URL")
  assert config.load().database_url == None
}

/// `ADMIN_PORT` は未設定なら既定ポート、明示的な空文字列なら無効。
pub fn admin_port_test() {
  envoy.unset("ADMIN_PORT")
  assert config.load().admin_port == config.Listen(8080)

  envoy.set("ADMIN_PORT", "9000")
  assert config.load().admin_port == config.Listen(9000)

  envoy.set("ADMIN_PORT", " 9000 ")
  assert config.load().admin_port == config.Listen(9000)

  // 上限の境界。1 つ上の 65536 は `Invalid` になる（下のテストを参照）。
  envoy.set("ADMIN_PORT", "65535")
  assert config.load().admin_port == config.Listen(65_535)

  envoy.set("ADMIN_PORT", "")
  assert config.load().admin_port == config.Disabled

  envoy.unset("ADMIN_PORT")
}

/// 範囲外や数値でない `ADMIN_PORT` は、理由付きで無効として報告する。範囲を
/// 検証しないと待ち受け開始時に badarg でクラッシュする。
pub fn admin_port_rejects_invalid_values_test() {
  let assert config.Invalid(_) = admin_port_for("not-a-port")
  let assert config.Invalid(_) = admin_port_for("0")
  let assert config.Invalid(_) = admin_port_for("-1")
  let assert config.Invalid(_) = admin_port_for("65536")
  envoy.unset("ADMIN_PORT")
}

/// 指定した `ADMIN_PORT` を設定して読み込んだ結果。
fn admin_port_for(raw: String) -> config.AdminPort {
  envoy.set("ADMIN_PORT", raw)
  config.load().admin_port
}

/// `ADMIN_BIND` は未設定ならループバックのみ。ページに secret が載るため、外部へ
/// 出すのは明示的な設定にする。
pub fn admin_bind_test() {
  envoy.unset("ADMIN_BIND")
  assert config.load().admin_bind == "127.0.0.1"

  envoy.set("ADMIN_BIND", "0.0.0.0")
  assert config.load().admin_bind == "0.0.0.0"

  envoy.set("ADMIN_BIND", "")
  assert config.load().admin_bind == "127.0.0.1"

  envoy.unset("ADMIN_BIND")
}

/// `ADMIN_BASE_URL` は未設定なら None。末尾のスラッシュは、承認ページのパスと
/// 重ならないよう取り除く。
pub fn admin_base_url_test() {
  envoy.unset("ADMIN_BASE_URL")
  assert config.load().admin_base_url == None

  envoy.set("ADMIN_BASE_URL", "https://bunker.example")
  assert config.load().admin_base_url == Some("https://bunker.example")

  envoy.set("ADMIN_BASE_URL", "https://bunker.example//")
  assert config.load().admin_base_url == Some("https://bunker.example")

  envoy.set("ADMIN_BASE_URL", "")
  assert config.load().admin_base_url == None

  envoy.unset("ADMIN_BASE_URL")
}

/// 承認ページの URL の土台。`ADMIN_BASE_URL` が優先され、未設定なら待ち受け
/// ポートから既定値を組み立てる。管理 UI が無効なら承認フローも無効。
pub fn auth_url_base_test() {
  envoy.unset("ADMIN_BASE_URL")
  envoy.set("ADMIN_PORT", "9000")
  assert config.auth_url_base(config.load()) == Some("http://localhost:9000")

  envoy.set("ADMIN_BASE_URL", "https://bunker.example")
  assert config.auth_url_base(config.load()) == Some("https://bunker.example")

  envoy.set("ADMIN_PORT", "")
  assert config.auth_url_base(config.load()) == None

  envoy.set("ADMIN_PORT", "not-a-port")
  assert config.auth_url_base(config.load()) == None

  envoy.unset("ADMIN_PORT")
  envoy.unset("ADMIN_BASE_URL")
}

/// 監視対象の pubkey だけが異なる設定。
fn test_config(pubkeys: List(String)) -> config.Config {
  config.Config(
    relay_urls: ["wss://example.com"],
    bunker_relay_urls: ["wss://example.com"],
    pubkeys: pubkeys,
    account_keys: [],
    bunker_secret: None,
    database_url: None,
    admin_port: config.Disabled,
    admin_bind: "127.0.0.1",
    admin_password: None,
    admin_base_url: None,
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
