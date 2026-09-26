//// `bunker/connection_uri` のテスト。`bunker://` URI とカメラ用のコピー用の
//// 文字列の組み立てを確かめる。

import gleam/option.{None, Some}
import gleam/uri
import nostr_no_su/bunker/connection_uri

/// テスト用の署名者（x-only 公開鍵の小文字 16 進）。
const signer = "a0b2d26e9b1ac8e1f9b7d5c3a1e8f6d4b2c0a9e7f5d3b1c9a7e5f3d1b9c7a5e3"

/// 設定したリレーはそれぞれパーセントエンコードされた `relay=` ヒントになる。
pub fn bunker_uri_lists_every_relay_test() {
  let uri =
    connection_uri.bunker_uri(
      signer,
      ["wss://relay.one", "ws://127.0.0.1:7777"],
      Some("s3cret"),
    )
  assert uri
    == "bunker://"
    <> signer
    <> "?relay=wss%3A%2F%2Frelay.one"
    <> "&relay=ws%3A%2F%2F127.0.0.1%3A7777"
    <> "&secret=s3cret"
}

/// secret 無しの URI には `secret=` を付けない。この URI で接続したクライアント
/// は管理 UI での承認を経る。
pub fn bunker_uri_without_a_secret_test() {
  assert connection_uri.bunker_uri(signer, ["wss://relay.one"], None)
    == "bunker://" <> signer <> "?relay=wss%3A%2F%2Frelay.one"
}

/// リレーが 0 件でも URI を返す。secret があれば `?secret=` だけ、無ければ
/// クエリー文字列自体を省く。
pub fn bunker_uri_without_relays_test() {
  assert connection_uri.bunker_uri(signer, [], Some("s3cret"))
    == "bunker://" <> signer <> "?secret=s3cret"
  assert connection_uri.bunker_uri(signer, [], None) == "bunker://" <> signer
}

/// `camera_copy_text` は先頭に `bunker://` を付けず、`relay=` の値のドットを `%2E` に
/// 置き換える。リレーが 0 件（`secret=` だけ、クエリーも無し）でも同じ。
pub fn camera_copy_text_encodes_relay_dots_test() {
  assert connection_uri.camera_copy_text(
      signer,
      ["wss://relay.one", "ws://127.0.0.1:7777"],
      Some("s3cret"),
    )
    == signer
    <> "?relay=wss%3A%2F%2Frelay%2Eone"
    <> "&relay=ws%3A%2F%2F127%2E0%2E0%2E1%3A7777"
    <> "&secret=s3cret"

  assert connection_uri.camera_copy_text(signer, [], Some("s3cret"))
    == signer <> "?secret=s3cret"

  assert connection_uri.camera_copy_text(signer, [], None) == signer
}

/// `"bunker://" <> camera_copy_text(signer, relay_urls, secret)` は元の URI として
/// 解析でき、`%2E` は `.` に戻る。
pub fn camera_copy_text_parses_back_with_the_bunker_scheme_test() {
  let relay_urls = ["wss://relay.one", "ws://127.0.0.1:7777"]
  let assert Ok(parsed) =
    uri.parse(
      "bunker://"
      <> connection_uri.camera_copy_text(signer, relay_urls, Some("s3cret")),
    )
  let assert Some(query) = parsed.query
  let assert Ok(parsed_query) = uri.parse_query(query)
  assert parsed_query
    == [
      #("relay", "wss://relay.one"),
      #("relay", "ws://127.0.0.1:7777"),
      #("secret", "s3cret"),
    ]
}
