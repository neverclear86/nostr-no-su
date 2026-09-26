//// バンカーアカウントへ接続するためにクライアントへ渡す文字列を、署名者の公開鍵、
//// バンカーのリレーの URL、接続 secret から組み立てる。完全な `bunker://` URI と、
//// 端末のカメラがテキストとして扱うコピー用の文字列の 2 つを作る（純粋）。

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/uri

/// 署名者 `signer`（x-only 公開鍵の小文字 16 進）へ接続するためにクライアントへ
/// 貼り付ける `bunker://` URI。URI に入るのは公開鍵だけなので、秘密鍵を持つ
/// `Account` を受け取らない。NIP-46 は複数の `relay=` ヒントを許容し、クライアント
/// はそのすべてに接続するため、生きているリレーが 1 つあればバンカーに到達できる。
/// `secret` が `None` の URI はその場では接続できず、管理 UI での承認（auth_url
/// フロー）を経る。リレーが 0 件でも URI を返す（クエリー文字列自体を省く）。
pub fn bunker_uri(
  signer: String,
  relay_urls: List(String),
  secret: Option(String),
) -> String {
  "bunker://"
  <> compose(signer, list.map(relay_urls, uri.percent_encode), secret)
}

/// 同じ部品の `bunker_uri` から、端末のカメラがテキストとして扱う形を作る。先頭の
/// `bunker://` を付けず、`relay=` の値のドットを `%2E` に置き換える。クライアントの
/// 入力欄で先頭に `bunker://` を打ち直せば `bunker_uri` と同じ URI として解析でき、
/// `%2E` は `.` に戻る。公開鍵と `secret=` の値は置き換えない。
pub fn camera_copy_text(
  signer: String,
  relay_urls: List(String),
  secret: Option(String),
) -> String {
  compose(
    signer,
    list.map(relay_urls, fn(url) {
      uri.percent_encode(url) |> string.replace(".", "%2E")
    }),
    secret,
  )
}

/// `signer` に、`relay_values` の各値の `relay=` と `secret` の `secret=` を `&` で
/// 繋いだクエリーを `?` で続ける。どちらも無ければ `signer` だけを返す。
/// `relay_values` は符号化済みの値で、ここでは変えない。
fn compose(
  signer: String,
  relay_values: List(String),
  secret: Option(String),
) -> String {
  let relay_params = list.map(relay_values, fn(value) { "relay=" <> value })
  let secret_param = case secret {
    None -> []
    Some(secret) -> ["secret=" <> secret]
  }
  case list.append(relay_params, secret_param) {
    [] -> signer
    params -> signer <> "?" <> string.join(params, "&")
  }
}
