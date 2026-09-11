//// バンカーアカウント。バンカーが代理で署名する 1 つのアイデンティティ
//// （鍵ペア）の鍵素材。

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri
import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex

/// バンカーが代理で署名する 1 つのアイデンティティ。x-only 公開鍵は署名にも
/// ルーティングにも使うため、バイト列と 16 進表現の両方を持つ。
///
/// 構築の経路は `from_privkey` だけなので、秘密鍵と公開鍵が食い違う値は作れない。
/// 秘密鍵は関数に閉じ込めて持つ。opaque 型も実行時にはただのタプルなので、
/// バイト列を直接持たせると `string.inspect`、`sys:get_state/1`、クラッシュ
/// レポートにそのまま出てしまうためである。代償として、**同じ秘密鍵から作った
/// 値同士でも `==` は `False` になる。** 比べるときは `pubkey_hex` を比べること。
pub opaque type Account {
  Account(privkey: fn() -> BitArray, pubkey: BitArray, pubkey_hex: String)
}

/// 32 バイトの秘密鍵からアカウントを構築する。範囲外のスカラーは拒否する。
pub fn from_privkey(privkey: BitArray) -> Result(Account, String) {
  case bit_array.byte_size(privkey) {
    32 ->
      case secp256k1.xonly_pubkey(privkey) {
        Ok(pubkey) ->
          Ok(Account(
            privkey: fn() { privkey },
            pubkey: pubkey,
            pubkey_hex: hex.encode(pubkey),
          ))
        Error(_) -> Error("private key not in valid range")
      }
    _ -> Error("private key must be 32 bytes")
  }
}

/// 署名と会話鍵の導出に使う 32 バイトの秘密鍵。
pub fn privkey(account: Account) -> BitArray {
  account.privkey()
}

/// x-only 公開鍵の 32 バイト。
pub fn pubkey(account: Account) -> BitArray {
  account.pubkey
}

/// x-only 公開鍵の小文字 16 進。署名者の識別子とルーティングに使う。
pub fn pubkey_hex(account: Account) -> String {
  account.pubkey_hex
}

/// 署名者 `signer`（x-only 公開鍵の小文字 16 進）へ接続するためにクライアントへ
/// 貼り付ける `bunker://` URI。URI に入るのは公開鍵だけなので、秘密鍵を持つ
/// `Account` を受け取らない。NIP-46 は複数の `relay=` ヒントを許容し、クライアント
/// はそのすべてに接続するため、生きているリレーが 1 つあればバンカーに到達できる。
/// `secret` が `None` の URI はその場では接続できず、管理 UI での承認（auth_url
/// フロー）を経る。
pub fn bunker_uri(
  signer: String,
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
  "bunker://" <> signer <> "?" <> relay_params <> secret_param
}
