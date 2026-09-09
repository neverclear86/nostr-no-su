//// バンカーアカウント。バンカーが代理で署名する 1 つのアイデンティティ
//// （鍵ペア）の鍵素材。

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import nostr_no_su/crypto/secp256k1

pub type Account {
  Account(privkey: BitArray, pubkey: BitArray, pubkey_hex: String)
}

/// 64 文字の 16 進秘密鍵からアカウントを構築する。
pub fn from_hex(hex: String) -> Result(Account, String) {
  use privkey <- result.try(
    bit_array.base16_decode(string.uppercase(string.trim(hex)))
    |> result.replace_error("invalid hex private key"),
  )
  case bit_array.byte_size(privkey) {
    32 ->
      case secp256k1.xonly_pubkey(privkey) {
        Ok(pubkey) ->
          Ok(Account(
            privkey: privkey,
            pubkey: pubkey,
            pubkey_hex: string.lowercase(bit_array.base16_encode(pubkey)),
          ))
        Error(_) -> Error("private key not in valid range")
      }
    _ -> Error("private key must be 32 bytes")
  }
}

/// 16 進秘密鍵ごとにアカウントを構築し、最初の不正な鍵で失敗する。
pub fn load_all(raw_keys: List(String)) -> Result(List(Account), String) {
  list.try_map(raw_keys, from_hex)
}

/// このアカウントへ接続するためにクライアントへ貼り付ける `bunker://` URI。
/// NIP-46 は複数の `relay=` ヒントを許容し、クライアントはそのすべてに接続する
/// ため、生きているリレーが 1 つあればバンカーに到達できる。`secret` が `None`
/// の URI はその場では接続できず、管理 UI での承認（auth_url フロー）を経る。
pub fn bunker_uri(
  account: Account,
  relay_urls: List(String),
  secret: Option(String),
) -> String {
  let relay_params =
    relay_urls
    |> list.map(fn(url) { "relay=" <> uri.percent_encode(url) })
    |> string.join("&")
  let secret_param = case secret {
    None -> ""
    Some(secret) -> "&secret=" <> secret
  }
  "bunker://" <> account.pubkey_hex <> "?" <> relay_params <> secret_param
}
