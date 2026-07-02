import gleam/int
import gleam/io
import gleam/string
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin, Plugin}

pub fn new() -> Plugin {
  Plugin(name: "console_logger", handle: log_event)
}

fn log_event(event: Event) -> Nil {
  io.println(
    "[event] kind="
    <> int.to_string(event.kind)
    <> " pubkey="
    <> string.slice(event.pubkey, 0, 8)
    <> " content="
    <> string.slice(event.content, 0, 80),
  )
}
