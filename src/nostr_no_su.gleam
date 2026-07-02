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
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugins/console_logger
import nostr_no_su/relay_client
import nostr_no_su/time
import stratus

@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

pub fn main() -> Nil {
  ensure_ssl_started()
  let loaded = config.load()
  io.println("nostr-no-su — relay: " <> loaded.relay_url)
  let bunker = setup_bunker(loaded)
  let subscriptions = fn() {
    let base = [#("nostr-no-su", config.to_filter(loaded))]
    case bunker.signer_pubkeys {
      [] -> base
      pubkeys -> [
        #("bunker", config.bunker_filter(pubkeys, time.now_seconds() - 60)),
        ..base
      ]
    }
  }
  run_loop(loaded, subscriptions, bunker)
}

/// The bunker parts of the running system: the plugin list (which includes the
/// bunker plugin when enabled), the actor subject to rewire on reconnect, and
/// the signer pubkeys to subscribe for.
type BunkerSetup {
  BunkerSetup(
    plugins: List(Plugin),
    subject: Option(Subject(bunker.Msg)),
    signer_pubkeys: List(String),
  )
}

fn setup_bunker(config: Config) -> BunkerSetup {
  let console = console_logger.new()
  case account.load_all(config.account_keys) {
    Error(reason) -> {
      io.println("[bunker] disabled: " <> reason)
      BunkerSetup([console], None, [])
    }
    Ok([]) -> {
      io.println("[bunker] no ACCOUNT_KEYS set; monitor-only mode")
      BunkerSetup([console], None, [])
    }
    Ok(accounts) -> {
      let with_secrets =
        list.map(accounts, fn(account) { #(account, secret_for(config)) })
      list.each(with_secrets, fn(pair) {
        io.println(
          "[bunker] " <> account.bunker_uri(pair.0, config.relay_url, pair.1),
        )
      })
      case bunker.start(engine.new(with_secrets)) {
        Ok(subject) ->
          BunkerSetup(
            plugins: [console, bunker.plugin(subject)],
            subject: Some(subject),
            signer_pubkeys: list.map(accounts, fn(account) {
              account.pubkey_hex
            }),
          )
        Error(_) -> {
          io.println("[bunker] failed to start; monitor-only mode")
          BunkerSetup([console], None, [])
        }
      }
    }
  }
}

fn secret_for(config: Config) -> String {
  case config.bunker_secret {
    Some(secret) -> secret
    None ->
      crypto.strong_random_bytes(16)
      |> bit_array.base16_encode
      |> string.lowercase
  }
}

/// Connect, rewire the bunker's publisher onto the live socket, then block
/// until the connection dies and reconnect after a short pause.
fn run_loop(
  config: Config,
  subscriptions: relay_client.Subscriptions,
  bunker: BunkerSetup,
) -> Nil {
  case
    relay_client.start(config, subscriptions, plugin.dispatch(bunker.plugins, _))
  {
    Ok(client) -> {
      rewire_publisher(bunker.subject, client)
      wait_until_dead(client)
    }
    Error(reason) -> io.println("[main] failed to connect: " <> reason)
  }
  io.println("[main] reconnecting in 5s...")
  process.sleep(5000)
  run_loop(config, subscriptions, bunker)
}

fn rewire_publisher(
  subject: Option(Subject(bunker.Msg)),
  client: Subject(stratus.InternalMessage(relay_client.Msg)),
) -> Nil {
  case subject {
    None -> Nil
    Some(subject) ->
      process.send(
        subject,
        bunker.SetPublisher(fn(response) {
          process.send(
            client,
            stratus.to_user_message(relay_client.Publish(response)),
          )
        }),
      )
  }
}

fn wait_until_dead(
  client: Subject(stratus.InternalMessage(relay_client.Msg)),
) -> Nil {
  let assert Ok(pid) = process.subject_owner(client)
  process.new_selector()
  |> process.select_specific_monitor(process.monitor(pid), fn(_) { Nil })
  |> process.selector_receive_forever
}
