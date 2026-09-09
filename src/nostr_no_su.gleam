import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/app
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/config.{type Config}
import nostr_no_su/plugins/console_logger
import nostr_no_su/relay_connection
import nostr_no_su/time

/// How many recent event ids the monitor dispatcher remembers for
/// cross-relay de-duplication (see `dedup` for the exact bound).
const dedup_capacity = 4096

/// Start the `ssl` application, which `wss://` connections depend on.
@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

/// Start the supervision tree for the configured relays and accounts, then
/// idle: from here on every process is supervised, restarted and rewired by
/// the tree rather than by this one.
pub fn main() -> Nil {
  ensure_ssl_started()
  let loaded = config.load()
  io.println(
    "nostr-no-su — monitor relays: " <> describe_relays(loaded.relay_urls),
  )
  // A tree that will not start means a bug or a broken configuration, so
  // crash rather than idle in a half-started process: the exit code is what
  // tells the container to restart.
  let assert Ok(_started) = app.start(spec(loaded))
    as "supervision tree failed to start"
  process.sleep_forever()
}

/// The tree to run for the loaded configuration. The process names are
/// created here once and passed down, so a restarted actor re-registers the
/// name its connections send to.
fn spec(loaded: Config) -> app.Spec {
  app.Spec(
    monitor: monitor_spec(loaded),
    bunker: bunker_spec(loaded),
    open: app.open_websocket,
    reconnect_delay_ms: relay_connection.default_reconnect_delay_ms,
  )
}

/// The monitoring subtree for the configured relays, or nothing when there
/// are none to watch.
fn monitor_spec(loaded: Config) -> Option(app.Monitor) {
  case loaded.relay_urls {
    [] -> {
      io.println("[main] no monitor relays configured; monitoring disabled")
      None
    }
    relay_urls ->
      Some(
        app.Monitor(
          name: process.new_name("nostr_no_su_dedup"),
          plugins: [console_logger.new()],
          dedup_capacity: dedup_capacity,
          relay_urls: relay_urls,
          subscriptions: fn() { [#("nostr-no-su", config.to_filter(loaded))] },
        ),
      )
  }
}

/// The bunker subtree for the configured accounts, logging one connection URI
/// per account. Without usable accounts the app runs monitor-only.
fn bunker_spec(loaded: Config) -> Option(app.Bunker) {
  case account.load_all(loaded.account_keys) {
    Error(reason) -> {
      io.println("[bunker] disabled: " <> reason)
      None
    }
    Ok([]) -> {
      io.println("[bunker] no ACCOUNT_KEYS set; monitor-only mode")
      None
    }
    Ok(accounts) -> {
      let with_secrets =
        list.map(accounts, fn(account) { #(account, secret_for(loaded)) })
      list.each(with_secrets, fn(pair) {
        io.println(
          "[bunker] "
          <> account.bunker_uri(pair.0, loaded.bunker_relay_urls, pair.1),
        )
      })
      let signer_pubkeys =
        list.map(accounts, fn(account) { account.pubkey_hex })
      Some(
        app.Bunker(
          name: process.new_name("nostr_no_su_bunker"),
          engine: engine.new(with_secrets),
          relay_urls: loaded.bunker_relay_urls,
          subscriptions: fn() {
            [
              #(
                "bunker",
                config.bunker_filter(signer_pubkeys, time.now_seconds() - 60),
              ),
            ]
          },
        ),
      )
    }
  }
}

/// The configured connection secret, or a fresh random one per account.
fn secret_for(loaded: Config) -> String {
  case loaded.bunker_secret {
    Some(secret) -> secret
    None ->
      crypto.strong_random_bytes(16)
      |> bit_array.base16_encode
      |> string.lowercase
  }
}

/// Render a relay list for the startup log.
fn describe_relays(relay_urls: List(String)) -> String {
  case relay_urls {
    [] -> "(none)"
    urls -> string.join(urls, ", ")
  }
}
