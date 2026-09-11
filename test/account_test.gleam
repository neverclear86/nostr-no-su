import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/bunker/account
import nostr_no_su/nostr/nip19
import support/vector.{bytes}

const key = "0000000000000000000000000000000000000000000000000000000000000042"

/// 設定したリレーはそれぞれパーセントエンコードされた `relay=` ヒントになる。
pub fn bunker_uri_lists_every_relay_test() {
  let assert Ok(signer) = account.from_privkey(bytes(key))
  let uri =
    account.bunker_uri(
      signer,
      ["wss://relay.one", "ws://127.0.0.1:7777"],
      Some("s3cret"),
    )
  assert uri
    == "bunker://"
    <> account.pubkey_hex(signer)
    <> "?relay=wss%3A%2F%2Frelay.one"
    <> "&relay=ws%3A%2F%2F127.0.0.1%3A7777"
    <> "&secret=s3cret"
}

/// secret 無しの URI には `secret=` を付けない。この URI で接続したクライアント
/// は管理 UI での承認を経る。
pub fn bunker_uri_without_a_secret_test() {
  let assert Ok(signer) = account.from_privkey(bytes(key))
  assert account.bunker_uri(signer, ["wss://relay.one"], None)
    == "bunker://"
    <> account.pubkey_hex(signer)
    <> "?relay=wss%3A%2F%2Frelay.one"
}

/// BIP-340 の公式ベクター 0 の秘密鍵から、同じベクターの公開鍵を導く。閉じ込めた
/// 秘密鍵はアクセサーでそのまま取り出せる。
pub fn from_privkey_bip340_vector0_test() {
  let privkey =
    bytes("0000000000000000000000000000000000000000000000000000000000000003")
  let assert Ok(signer) = account.from_privkey(privkey)
  assert account.privkey(signer) == privkey
  assert account.pubkey_hex(signer)
    == "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
  assert account.pubkey(signer)
    == bytes("f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")
}

/// アカウントを表示しても秘密鍵は出ない。秘密鍵は関数に閉じ込めてあり、表示は
/// 関数の中身を含まないため。
pub fn inspecting_an_account_does_not_reveal_the_private_key_test() {
  let privkey =
    bytes("7f3c9a52e1d04b8a96c2f5e3d7a1b0c4e8f2a6d9b3c5e7f1a2b4c6d8e0f1a3b5")
  let assert Ok(signer) = account.from_privkey(privkey)
  let shown = string.inspect(signer)
  assert !string.contains(
    string.lowercase(shown),
    "7f3c9a52e1d04b8a96c2f5e3d7a1b0c4e8f2a6d9b3c5e7f1a2b4c6d8e0f1a3b5",
  )
  assert !string.contains(shown, string.inspect(privkey))
}

/// 32 バイトでない秘密鍵は理由付きで拒否する。
pub fn from_privkey_rejects_wrong_length_test() {
  let assert Error(reason) = account.from_privkey(<<0, 17, 34, 51>>)
  assert reason == "private key must be 32 bytes"
}

/// 範囲外のスカラー（0 と位数 n）の nsec は NIP-19 としては復号できるが、
/// 範囲の検査はアカウントの構築で行い、ここで拒否する。
pub fn from_privkey_rejects_out_of_range_nsec_test() {
  let nsecs = [
    "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqwkhnav",
    "nsec1lllllllllllllllllllllllll6a2ah8x4ay2qwal6f0ge5pkg9qstu3zum",
  ]
  use nsec <- list.each(nsecs)
  let assert Ok(privkey) = nip19.decode(nsec, nip19.Nsec)
  assert account.from_privkey(privkey)
    == Error("private key not in valid range")
}
