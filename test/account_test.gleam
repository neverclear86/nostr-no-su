import nostr_no_su/bunker/account

const key = "0000000000000000000000000000000000000000000000000000000000000042"

/// 設定したリレーはそれぞれパーセントエンコードされた `relay=` ヒントになる。
pub fn bunker_uri_lists_every_relay_test() {
  let assert Ok(signer) = account.from_hex(key)
  let uri =
    account.bunker_uri(
      signer,
      ["wss://relay.one", "ws://127.0.0.1:7777"],
      "s3cret",
    )
  assert uri
    == "bunker://"
    <> signer.pubkey_hex
    <> "?relay=wss%3A%2F%2Frelay.one"
    <> "&relay=ws%3A%2F%2F127.0.0.1%3A7777"
    <> "&secret=s3cret"
}
