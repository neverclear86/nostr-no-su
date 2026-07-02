import gleam/erlang/process.{type Subject}
import gleam/io
import nostr_no_su/config.{type Config}
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugins/console_logger
import nostr_no_su/relay_client
import stratus

@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

pub fn main() -> Nil {
  ensure_ssl_started()
  let loaded = config.load()
  let plugins = [console_logger.new()]
  io.println("nostr-no-su v0 — relay: " <> loaded.relay_url)
  run_loop(loaded, plugins)
}

/// Connect, then block until the connection actor dies and reconnect after
/// a short pause. v0 has a single connection, so this simple loop replaces
/// a supervision tree.
fn run_loop(config: Config, plugins: List(Plugin)) -> Nil {
  case relay_client.start(config, plugin.dispatch(plugins, _)) {
    Ok(client) -> wait_until_dead(client)
    Error(reason) -> io.println("[main] failed to connect: " <> reason)
  }
  io.println("[main] reconnecting in 5s...")
  process.sleep(5000)
  run_loop(config, plugins)
}

fn wait_until_dead(
  client: Subject(stratus.InternalMessage(relay_client.Msg)),
) -> Nil {
  let assert Ok(pid) = process.subject_owner(client)
  process.new_selector()
  |> process.select_specific_monitor(process.monitor(pid), fn(_) { Nil })
  |> process.selector_receive_forever
}
