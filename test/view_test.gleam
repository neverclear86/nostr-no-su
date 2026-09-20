//// 管理 UI のページ枠と共通の部品（`admin/view`）の単体テスト。

import nostr_no_su/admin/view

/// 64 桁の 16 進のように長い値は、先頭 10 桁と末尾 6 桁を `…` でつなぐ。
pub fn shorten_keeps_the_head_and_tail_test() {
  let hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  assert view.shorten(hex) == "0123456789…abcdef"
}

/// 17 文字以下の値はそのまま返す。
pub fn shorten_returns_short_values_unchanged_test() {
  assert view.shorten("01234567890123456") == "01234567890123456"
  assert view.shorten("") == ""
}
