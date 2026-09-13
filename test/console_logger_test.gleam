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
