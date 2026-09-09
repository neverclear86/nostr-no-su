import envoy
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/nostr/filter.{type Filter, Filter}

const default_relay_url = "wss://relay.damus.io"

pub type Config {
  Config(
    relay_urls: List(String),
    bunker_relay_urls: List(String),
    pubkeys: List(String),
    account_keys: List(String),
    bunker_secret: Option(String),
    database_url: Option(String),
  )
}

/// 環境変数から設定全体を読み込む。
pub fn load() -> Config {
  let relay_urls =
    envoy.get("RELAY_URL")
    |> result.unwrap(default_relay_url)
    |> parse_list
  Config(
    relay_urls: relay_urls,
    bunker_relay_urls: pick_bunker_relays(
      envoy.get("BUNKER_RELAY_URL") |> result.unwrap("") |> parse_list,
      relay_urls,
    ),
    pubkeys: envoy.get("PUBKEYS") |> result.unwrap("") |> parse_list,
    account_keys: envoy.get("ACCOUNT_KEYS")
      |> result.unwrap("")
      |> parse_list,
    bunker_secret: optional("BUNKER_SECRET"),
    database_url: optional("DATABASE_URL"),
  )
}

/// 任意の環境変数を読む。docker compose は未設定の変数を空文字列として渡す
/// ため、空文字列も未設定として扱う。
fn optional(name: String) -> Option(String) {
  case envoy.get(name) {
    Ok("") | Error(Nil) -> None
    Ok(value) -> Some(value)
  }
}

/// バンカーが待ち受け・応答するリレー。明示的な上書きが空でなければそれを、
/// 無ければ監視用リレーを、それも無ければ既定のリレーを使う。
pub fn pick_bunker_relays(
  override: List(String),
  relay_urls: List(String),
) -> List(String) {
  case override, relay_urls {
    [], [] -> [default_relay_url]
    [], urls -> urls
    urls, _ -> urls
  }
}

/// カンマ区切りのリスト（pubkey、鍵、リレー URL）をパースする。前後の空白は
/// 無視し、空の要素は除外する。
pub fn parse_list(raw: String) -> List(String) {
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
}

/// 設定されたアカウントを購読する。pubkey が未設定なら直近イベントを少数だけ
/// 購読する。
pub fn to_filter(config: Config) -> Filter {
  case config.pubkeys {
    [] -> Filter(..filter.new(), limit: Some(20))
    pubkeys -> Filter(..filter.new(), authors: Some(pubkeys))
  }
}

/// 指定した署名者 pubkey 宛の NIP-46 リクエストを購読する。
pub fn bunker_filter(signer_pubkeys: List(String), since: Int) -> Filter {
  Filter(
    ..filter.new(),
    kinds: Some([24_133]),
    p_tags: Some(signer_pubkeys),
    since: Some(since),
  )
}
