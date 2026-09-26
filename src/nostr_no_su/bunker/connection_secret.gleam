//// バンカーアカウントの接続 secret。`bunker://` URI に載る値で、これを提示した
//// クライアントに署名を委任する資格そのものである。

import gleam/bit_array
import gleam/crypto
import nostr_no_su/secret.{type Secret}

/// 接続 secret 1 件。値は `Secret` に閉じ込めて持つ。提示された値と比べるときは、
/// 定数時間で比べる `matches` を使うこと。
pub opaque type ConnectionSecret {
  ConnectionSecret(value: Secret(String))
}

/// 文字列を接続 secret として閉じ込める。空や長さの検査はしない。
/// 生成（`bunker.gleam`）と復号（`vault.gleam`）の側が持つ責務である。
pub fn new(value: String) -> ConnectionSecret {
  ConnectionSecret(secret.new(value))
}

/// 閉じ込めた文字列を取り出す。一覧（管理 UI の接続 URI）に出すときだけ使う。
pub fn value(connection: ConnectionSecret) -> String {
  secret.reveal(connection.value)
}

/// 提示された値が接続 secret と一致するか。一致した長さが応答時間に現れない
/// よう `crypto.secure_compare` で比べる。長さが違えば早く `False` になるが、
/// secret は固定長（`random.hex(16)` の 32 文字）なので長さで漏れる情報は無い。
pub fn matches(connection: ConnectionSecret, offered: String) -> Bool {
  crypto.secure_compare(
    bit_array.from_string(secret.reveal(connection.value)),
    bit_array.from_string(offered),
  )
}
