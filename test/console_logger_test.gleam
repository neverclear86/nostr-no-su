//// `console_logger` のテスト。ログ行の本文を確かめる。

import gleam/string
import nostr_no_su/plugins/console_logger
import support/signed_event

/// content に改行があっても、ログ行は 1 行に収まる。
pub fn event_line_keeps_a_multiline_content_on_one_line_test() {
  let event = signed_event.new(1, "hello\n[bunker] forged")

  let line = console_logger.event_line(event)
  assert !string.contains(line, "\n")
  assert string.contains(line, "content=hello [bunker] forged")
}

/// `new` はこのプラグインの名前を持ち、子プロセスを起こさない。
pub fn new_has_no_children_test() {
  let plugin = console_logger.new()
  assert plugin.name == console_logger.name
  assert plugin.children == []
}

/// `new` が返す `handle` にイベントを渡しても落ちない。
pub fn handling_an_event_does_not_crash_test() {
  let plugin = console_logger.new()
  plugin.handle(signed_event.new(1, "note"))
}
