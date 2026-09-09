import gleam/list
import nostr_no_su/nostr/event.{type Event}

/// プラグインは監視対象アカウントから受信したすべてのイベントを処理する。
/// 状態を持つプラグインは、`handle` クロージャの中で自前のアクターへの
/// `Subject` を捕捉できる。
pub type Plugin {
  Plugin(name: String, handle: fn(Event) -> Nil)
}

pub fn dispatch(plugins: List(Plugin), event: Event) -> Nil {
  list.each(plugins, fn(plugin) { plugin.handle(event) })
}
