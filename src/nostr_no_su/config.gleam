import envoy
import gleam/list
import gleam/option.{type Option, Some}
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
  )
}

/// Read the whole configuration from the environment.
pub fn load() -> Config {
  let relay_urls =
    envoy.get("RELAY_URL")
    |> result.unwrap(default_relay_url)
    |> parse_list
  Config(
    relay_urls: relay_urls,
    bunker_relay_urls: pick_bunker_relays(
      envoy.get("BUNKER_RELAY_URL") |> result.unwrap(""),
      relay_urls,
    ),
    pubkeys: envoy.get("PUBKEYS") |> result.unwrap("") |> parse_list,
    account_keys: envoy.get("ACCOUNT_KEYS")
      |> result.unwrap("")
      |> parse_list,
    bunker_secret: envoy.get("BUNKER_SECRET") |> option.from_result,
  )
}

/// The relays the bunker listens and replies on: the explicit override when
/// set, otherwise the monitor relays, otherwise the default relay.
pub fn pick_bunker_relays(
  override: String,
  relay_urls: List(String),
) -> List(String) {
  case parse_list(override), relay_urls {
    [], [] -> [default_relay_url]
    [], urls -> urls
    urls, _ -> urls
  }
}

/// Parse a comma-separated list (pubkeys, keys, relay urls), ignoring
/// surrounding whitespace and empty entries.
pub fn parse_list(raw: String) -> List(String) {
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
}

/// Subscribe to the configured accounts, or to a small sample of recent
/// events when no pubkeys are configured.
pub fn to_filter(config: Config) -> Filter {
  case config.pubkeys {
    [] -> Filter(..filter.new(), limit: Some(20))
    pubkeys -> Filter(..filter.new(), authors: Some(pubkeys))
  }
}

/// Subscribe to NIP-46 requests addressed to the given signer pubkeys.
pub fn bunker_filter(signer_pubkeys: List(String), since: Int) -> Filter {
  Filter(
    ..filter.new(),
    kinds: Some([24_133]),
    p_tags: Some(signer_pubkeys),
    since: Some(since),
  )
}
