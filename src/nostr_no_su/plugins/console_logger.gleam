import gleam/int
import gleam/option.{None}
import gleam/string
import nostr_no_su/log
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin, Plugin}

/// プラグインの名前。`new` とログの接頭辞のほか、予約名としても使う
/// （`nostr_no_su.builtin_plugins` が無効時にも `plugin_loader.load_all` へ渡す）。
pub const name = "console_logger"

/// 受信したイベントの概要を標準出力に書くプラグイン。
pub fn new() -> Plugin {
  Plugin(name: name, children: [], handle: log_event, ui: None)
}

/// イベント 1 件の概要をこのプラグインの接頭辞を付けて出力する。
fn log_event(event: Event) -> Nil {
  log.write(log.Notice, log.plugin_prefix(name), event_line(event))
}

/// イベント 1 件の概要のログ行の本文。content は長くなりうるので先頭の 80
/// コードポイントだけを、改行を含む制御文字を空白にして出す。
pub fn event_line(event: Event) -> String {
  "kind="
  <> int.to_string(event.kind)
  <> " pubkey="
  <> string.slice(event.pubkey, 0, 8)
  <> " content="
  <> log.sanitize(event.content, 80)
}
