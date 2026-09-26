//// `secret` のテスト。

import gleam/string
import nostr_no_su/secret

/// 閉じ込めた値は `string.inspect` の表示に出ない。表示は関数の中身を含まないため。
pub fn inspecting_a_secret_does_not_reveal_the_value_test() {
  let shown = string.inspect(secret.new("s3cr3t-value"))
  assert !string.contains(shown, "s3cr3t-value")
}

/// `==` は閉じ込めた値どうしの比較になる。関数の比較は捕捉した値を比べるため。
pub fn secrets_compare_by_their_values_test() {
  assert secret.new("x") == secret.new("x")
  assert secret.new("x") != secret.new("y")
}
