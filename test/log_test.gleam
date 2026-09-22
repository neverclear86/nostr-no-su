//// `log` のテスト。外部由来の文字列の正規化と、制御文字の判定を確かめる。

import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import nostr_no_su/log

/// 改行、ESC、TAB、DEL、C1、行区切りと段落区切りは、それぞれ空白 1 文字に
/// 置き換わる。
pub fn sanitize_replaces_line_breaks_and_controls_with_spaces_test() {
  let text = "a\nb\r\nc\u{1B}[31m\t\u{7F}\u{85}\u{2028}\u{2029}d"
  assert log.sanitize(text, 200) == "a b  c [31m     d"
}

/// 制御文字ではない非 ASCII の文字や記号はそのまま返る。
pub fn sanitize_keeps_printable_text_test() {
  assert log.sanitize("é🙂 [x]", 200) == "é🙂 [x]"
}

/// `\r\n` は書記素 1 つだが、コードポイント 2 つとして数える。
pub fn sanitize_counts_a_crlf_as_two_codepoints_test() {
  let text = string.repeat("\r\n", 10)
  assert log.sanitize(text, 5) == "     ..."
}

/// 結合文字を並べた入力でも、戻り値のバイト数はコードポイントの上限で抑えられる。
pub fn sanitize_caps_the_bytes_of_combining_marks_test() {
  let text = "x" <> string.repeat("\u{0301}", 10_000)
  assert string.byte_size(log.sanitize(text, 200)) <= 4 * 200 + 3
}

/// 双方向テキストの制御文字は、それぞれ空白 1 文字に置き換わる。
pub fn sanitize_replaces_bidi_controls_with_spaces_test() {
  let text = "a\u{202A}b\u{202E}c\u{2066}d\u{2069}e"
  assert log.sanitize(text, 200) == "a b c d e"
}

/// `has_control` は `sanitize` が空白に置き換えるコードポイント（ESC、双方向
/// テキストの制御）を見つけ、印刷可能な値は `False` を返す。
pub fn has_control_finds_what_sanitize_replaces_test() {
  assert log.has_control("http://evil.example\u{1b}[2J")
  assert log.has_control("https://admin.example/\u{202E}accounts")
  assert !log.has_control("https://admin.example:8443/accounts?x=1")
}

/// 4 MiB の入力でも、先頭の上限までしか読まないので 0.05 秒未満で終わる。
pub fn sanitize_is_fast_for_a_long_input_test() {
  let text = string.repeat("a", 4_000_000)
  let start = timestamp.system_time()
  let _ = log.sanitize(text, 200)
  let elapsed = timestamp.difference(start, timestamp.system_time())
  assert duration.to_seconds(elapsed) <. 0.05
}
