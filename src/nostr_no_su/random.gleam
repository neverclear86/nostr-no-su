//// 推測されては困る値（接続シークレット、承認トークン）のための乱数。

import gleam/crypto
import nostr_no_su/hex

/// 指定バイト数の乱数を 16 進の小文字で表した文字列。
pub fn hex(byte_count: Int) -> String {
  crypto.strong_random_bytes(byte_count)
  |> hex.encode
}
