import gleam/bit_array
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/config.{type Config}
import nostr_no_su/dedup
import nostr_no_su/nostr/event
import nostr_no_su/plugins/console_logger
import nostr_no_su/relay_client
import nostr_no_su/time

/// How many recent event ids the monitor dispatcher remembers for
/// cross-relay de-duplication (see `dedup` for the exact bound).
const dedup_capacity = 4096

/// Start the `ssl` application, which `wss://` connections depend on.
@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

/// Start the bunker, then one connection per monitor and bunker relay, and
/// idle: each connection runs its own reconnect loop in a separate process.
pub fn main() -> Nil {
  ensure_ssl_started()
  let loaded = config.load()
  io.println(
    "nostr-no-su — monitor relays: " <> describe_relays(loaded.relay_urls),
  )
  let bunker = setup_bunker(loaded)
  start_monitors(loaded)
  case bunker.subject {
    Some(subject) ->
      start_bunker_connections(loaded, bunker.signer_pubkeys, subject)
    None -> Nil
  }
  process.sleep_forever()
}

/// Render a relay list for the startup log.
fn describe_relays(relay_urls: List(String)) -> String {
  case relay_urls {
    [] -> "(none)"
    urls -> string.join(urls, ", ")
  }
}

/// The bunker parts of the running system: the actor subject to rewire on
/// reconnect, and the signer pubkeys to subscribe for.
type BunkerSetup {
  BunkerSetup(
    subject: Option(Subject(bunker.Msg)),
    signer_pubkeys: List(String),
  )
}

/// Start the bunker actor for the configured accounts and log one connection
/// URI per account. Any failure downgrades to monitor-only mode.
fn setup_bunker(loaded: Config) -> BunkerSetup {
  case account.load_all(loaded.account_keys) {
    Error(reason) -> {
      io.println("[bunker] disabled: " <> reason)
      BunkerSetup(None, [])
    }
    Ok([]) -> {
      io.println("[bunker] no ACCOUNT_KEYS set; monitor-only mode")
      BunkerSetup(None, [])
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
      case bunker.start(engine.new(with_secrets)) {
        Ok(subject) ->
          BunkerSetup(
            subject: Some(subject),
            signer_pubkeys: list.map(accounts, fn(account) {
              account.pubkey_hex
            }),
          )
        Error(_) -> {
          io.println("[bunker] failed to start; monitor-only mode")
          BunkerSetup(None, [])
        }
      }
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

/// Open one monitor connection per configured relay. All connections feed the
/// dedup dispatcher, so plugins see each event once no matter how many relays
/// deliver it.
fn start_monitors(loaded: Config) -> Nil {
  case loaded.relay_urls {
    [] -> io.println("[main] no monitor relays configured; monitoring disabled")
    urls ->
      case dedup.start([console_logger.new()], dedup_capacity) {
        Ok(dispatcher) -> {
          let subscriptions = fn() {
            [#("nostr-no-su", config.to_filter(loaded))]
          }
          list.each(urls, fn(url) {
            spawn_relay_loop(
              url,
              subscriptions,
              fn(incoming) {
                process.send(dispatcher, dedup.Incoming(incoming))
              },
              fn(_connection) { Nil },
            )
          })
        }
        Error(_) ->
          io.println("[main] failed to start dispatcher; monitoring disabled")
      }
  }
}

/// The bunker's own connections, one per bunker relay: only the NIP-46
/// subscription runs on them, so bunker-only relays (e.g. relay.nsec.app)
/// that reject other subscriptions stay usable. See `bunker.SetPublisher`
/// for how responses are published back.
fn start_bunker_connections(
  loaded: Config,
  signer_pubkeys: List(String),
  subject: Subject(bunker.Msg),
) -> Nil {
  let subscriptions = fn() {
    [#("bunker", config.bunker_filter(signer_pubkeys, time.now_seconds() - 60))]
  }
  list.each(loaded.bunker_relay_urls, fn(url) {
    spawn_relay_loop(
      url,
      subscriptions,
      fn(incoming) { process.send(subject, bunker.Incoming(incoming)) },
      fn(connection) { rewire_publisher(subject, url, connection) },
    )
  })
}

/// Run a reconnect loop in its own process. The websocket actor is linked to
/// the loop process and exits abnormally on abrupt socket loss (e.g.
/// `SocketClosed` when a relay is killed); trapping exits turns that into a
/// message so the loop reconnects instead of taking the whole app down.
fn spawn_relay_loop(
  url: String,
  subscriptions: relay_client.Subscriptions,
  handle_event: fn(event.Event) -> Nil,
  on_connect: fn(relay_client.Connection) -> Nil,
) -> Nil {
  process.spawn(fn() {
    process.trap_exits(True)
    relay_loop(url, subscriptions, handle_event, on_connect)
  })
  Nil
}

/// Connect, run `on_connect` on the live socket (e.g. to rewire the bunker's
/// publisher), then block until the connection dies and reconnect after a
/// short pause.
fn relay_loop(
  url: String,
  subscriptions: relay_client.Subscriptions,
  handle_event: fn(event.Event) -> Nil,
  on_connect: fn(relay_client.Connection) -> Nil,
) -> Nil {
  let relay = relay_client.label(url)
  case relay_client.start(url, subscriptions, handle_event) {
    Ok(connection) -> {
      let assert Ok(pid) = process.subject_owner(connection)
      on_connect(connection)
      relay_client.wait_until_dead(pid)
    }
    Error(reason) ->
      io.println("[main " <> relay <> "] failed to connect: " <> reason)
  }
  io.println("[main " <> relay <> "] reconnecting in 5s...")
  process.sleep(5000)
  relay_loop(url, subscriptions, handle_event, on_connect)
}

/// Point the bunker's publisher for this relay at the freshly connected
/// socket, replacing the one installed before the last disconnect.
fn rewire_publisher(
  subject: Subject(bunker.Msg),
  relay_url: String,
  connection: relay_client.Connection,
) -> Nil {
  process.send(
    subject,
    bunker.SetPublisher(relay_url, fn(response) {
      relay_client.publish(connection, response)
    }),
  )
}
