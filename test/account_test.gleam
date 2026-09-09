import gleam/option.{None, Some}
import nostr_no_su/bunker/account

const key = "0000000000000000000000000000000000000000000000000000000000000042"

/// 設定したリレーはそれぞれパーセントエンコードされた `relay=` ヒントになる。
pub fn bunker_uri_lists_every_relay_test() {
  let assert Ok(signer) = account.from_hex(key)
  let uri =
    account.bunker_uri(
      signer,
      ["wss://relay.one", "ws://127.0.0.1:7777"],
      Some("s3cret"),
    )
  assert uri
    == "bunker://"
    <> signer.pubkey_hex
    <> "?relay=wss%3A%2F%2Frelay.one"
    <> "&relay=ws%3A%2F%2F127.0.0.1%3A7777"
    <> "&secret=s3cret"
}

/// secret 無しの URI には `secret=` を付けない。この URI で接続したクライアント
/// は管理 UI での承認を経る。
pub fn bunker_uri_without_a_secret_test() {
  let assert Ok(signer) = account.from_hex(key)
  assert account.bunker_uri(signer, ["wss://relay.one"], None)
    == "bunker://" <> signer.pubkey_hex <> "?relay=wss%3A%2F%2Frelay.one"
}
