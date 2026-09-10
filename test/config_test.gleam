import envoy
import gleam/option.{None, Some}
import nostr_no_su/config
import nostr_no_su/nostr/filter.{Filter}

/// カンマ区切りのリストは前後の空白を除去し、空の要素を取り除く。
pub fn parse_list_test() {
  assert config.parse_list("") == []
  assert config.parse_list("a,b") == ["a", "b"]
  assert config.parse_list(" a , b ,") == ["a", "b"]
}

/// 重複した要素は最初の 1 つだけ残る。同じリレー URL を 2 度書くと接続が 2 本
/// 開き、バンカーが URL で持つ送信手段のキーが衝突するため。
pub fn parse_list_drops_duplicates_test() {
  assert config.parse_list("wss://a, wss://b, wss://a")
    == ["wss://a", "wss://b"]
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

/// 環境変数を一時的に設定して `run` を実行し、終了後に元の値へ戻す。設定と復元を
/// 1 か所にまとめることで、テストごとに散らばる後始末と、その書き忘れを防ぐ。
fn with_env(name: String, value: String, run: fn() -> a) -> a {
  let restore = envoy.get(name)
  envoy.set(name, value)
  let result = run()
  case restore {
    Ok(previous) -> envoy.set(name, previous)
    Error(Nil) -> envoy.unset(name)
  }
  result
}

/// 環境変数を一時的に未設定にして `run` を実行し、終了後に元の値へ戻す。
fn without_env(name: String, run: fn() -> a) -> a {
  let restore = envoy.get(name)
  envoy.unset(name)
  let result = run()
  case restore {
    Ok(previous) -> envoy.set(name, previous)
    Error(Nil) -> Nil
  }
  result
}

/// 指定した環境変数をすべて設定して読み込んだ設定。読み込みを終えた時点で環境
/// 変数は元に戻るため、assert が失敗しても後続のテストに影響しない。
fn config_with(vars: List(#(String, String))) -> config.Config {
  case vars {
    [] -> config.load()
    [#(name, value), ..rest] -> {
      use <- with_env(name, value)
      config_with(rest)
    }
  }
}

/// 指定した環境変数を未設定にして読み込んだ設定。
fn config_without(name: String) -> config.Config {
  use <- without_env(name)
  config.load()
}

/// 空文字列の環境変数は未設定として扱う。docker compose は未設定の変数を空文字列
/// として渡すため、`DATABASE_URL=` で保存を無効にできる必要がある。
pub fn empty_environment_variables_are_unset_test() {
  assert config_with([#("DATABASE_URL", "")]).database_url == None
  assert config_with([#("DATABASE_URL", "postgres://user@host:5432/db")]).database_url
    == Some("postgres://user@host:5432/db")
  assert config_without("DATABASE_URL").database_url == None

  // `BUNKER_SECRET=` も同じく未設定として扱う。空文字列をシークレットとして
  // 受け付けると、secret 無しで接続したクライアントが素通りしてしまう。
  assert config_with([#("BUNKER_SECRET", "")]).bunker_secret == None
  assert config_with([#("BUNKER_SECRET", "s3cret")]).bunker_secret
    == Some("s3cret")
  assert config_without("BUNKER_SECRET").bunker_secret == None
}

/// `PLUGIN_DIR` は未設定・空文字列なら None（外部プラグインの読み込みを無効に
/// する）。値があればそのまま走査対象のディレクトリーになる。
pub fn plugin_dir_test() {
  assert config_without("PLUGIN_DIR").plugin_dir == None
  assert config_with([#("PLUGIN_DIR", "")]).plugin_dir == None
  assert config_with([#("PLUGIN_DIR", "/plugins")]).plugin_dir
    == Some("/plugins")
}

/// `ADMIN_PORT` は未設定なら既定ポート、明示的な空文字列なら無効。
pub fn admin_port_test() {
  assert config_without("ADMIN_PORT").admin_port == config.Listen(8080)
  assert config_with([#("ADMIN_PORT", "9000")]).admin_port
    == config.Listen(9000)
  assert config_with([#("ADMIN_PORT", " 9000 ")]).admin_port
    == config.Listen(9000)
  // 上限の境界。1 つ上の 65536 は `Invalid` になる（下のテストを参照）。
  assert config_with([#("ADMIN_PORT", "65535")]).admin_port
    == config.Listen(65_535)
  assert config_with([#("ADMIN_PORT", "")]).admin_port == config.Disabled
}

/// 範囲外や数値でない `ADMIN_PORT` は、理由付きで無効として報告する。範囲を
/// 検証しないと待ち受け開始時に badarg でクラッシュする。
pub fn admin_port_rejects_invalid_values_test() {
  let assert config.Invalid(_) = admin_port_for("not-a-port")
  let assert config.Invalid(_) = admin_port_for("0")
  let assert config.Invalid(_) = admin_port_for("-1")
  let assert config.Invalid(_) = admin_port_for("65536")
}

/// 指定した `ADMIN_PORT` を設定して読み込んだ結果。
fn admin_port_for(raw: String) -> config.AdminPort {
  config_with([#("ADMIN_PORT", raw)]).admin_port
}

/// `ADMIN_BIND` は未設定ならループバックのみ。ページに secret が載るため、外部へ
/// 出すのは明示的な設定にする。
pub fn admin_bind_test() {
  assert config_without("ADMIN_BIND").admin_bind == "127.0.0.1"
  assert config_with([#("ADMIN_BIND", "0.0.0.0")]).admin_bind == "0.0.0.0"
  assert config_with([#("ADMIN_BIND", "")]).admin_bind == "127.0.0.1"
}

/// `ADMIN_BASE_URL` は未設定なら None。末尾のスラッシュは、承認ページのパスと
/// 重ならないよう取り除く。
pub fn admin_base_url_test() {
  assert config_without("ADMIN_BASE_URL").admin_base_url == None
  assert config_with([#("ADMIN_BASE_URL", "https://bunker.example")]).admin_base_url
    == Some("https://bunker.example")
  assert config_with([#("ADMIN_BASE_URL", "https://bunker.example//")]).admin_base_url
    == Some("https://bunker.example")
  assert config_with([#("ADMIN_BASE_URL", "")]).admin_base_url == None
}

/// 承認ページの URL の土台。`ADMIN_BASE_URL` が優先され、未設定なら待ち受け
/// ポートから既定値を組み立てる。管理 UI が無効なら承認フローも無効。
pub fn auth_url_base_test() {
  // 空文字列は未設定として扱われるため、`ADMIN_BASE_URL` を明示的に外せる。
  let from_port =
    config_with([#("ADMIN_PORT", "9000"), #("ADMIN_BASE_URL", "")])
  assert config.auth_url_base(from_port) == Some("http://localhost:9000")

  let from_base_url =
    config_with([
      #("ADMIN_PORT", "9000"),
      #("ADMIN_BASE_URL", "https://bunker.example"),
    ])
  assert config.auth_url_base(from_base_url) == Some("https://bunker.example")

  assert config.auth_url_base(config_with([#("ADMIN_PORT", "")])) == None
  assert config.auth_url_base(config_with([#("ADMIN_PORT", "not-a-port")]))
    == None
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
    plugin_dir: None,
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
