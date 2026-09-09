//// 推測されては困る値（接続シークレット、管理 UI のパスワード、承認トークン）の
//// ための乱数。

import gleam/crypto
import nostr_no_su/hex

/// 指定バイト数の乱数を 16 進の小文字で表した文字列。
pub fn hex(byte_count: Int) -> String {
  crypto.strong_random_bytes(byte_count)
  |> hex.encode
}
