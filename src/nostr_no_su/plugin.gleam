import gleam/list
import nostr_no_su/nostr/event.{type Event}

/// A plugin processes every event received from the monitored accounts.
/// Stateful plugins can capture a `Subject` to their own actor inside the
/// `handle` closure.
pub type Plugin {
  Plugin(name: String, handle: fn(Event) -> Nil)
}

pub fn dispatch(plugins: List(Plugin), event: Event) -> Nil {
  list.each(plugins, fn(plugin) { plugin.handle(event) })
}
