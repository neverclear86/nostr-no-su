//// `log` のテスト。外部由来の文字列の正規化を確かめる。

import gleam/string
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
