import envoy
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import nostr_no_su/nostr/filter.{type Filter, Filter}

pub type Config {
  Config(
    relay_url: String,
    pubkeys: List(String),
    account_keys: List(String),
    bunker_secret: Option(String),
  )
}

pub fn load() -> Config {
  Config(
    relay_url: envoy.get("RELAY_URL") |> result.unwrap("wss://relay.damus.io"),
    pubkeys: envoy.get("PUBKEYS") |> result.unwrap("") |> parse_pubkeys,
    account_keys: envoy.get("ACCOUNT_KEYS")
      |> result.unwrap("")
      |> parse_pubkeys,
    bunker_secret: envoy.get("BUNKER_SECRET") |> option.from_result,
  )
}

/// Parse a comma-separated list of hex pubkeys, ignoring surrounding
/// whitespace and empty entries.
pub fn parse_pubkeys(raw: String) -> List(String) {
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(pubkey) { pubkey != "" })
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
