import gleam/list
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

/// 16 進として読めない鍵は理由付きで拒否する。
pub fn from_hex_rejects_non_hex_test() {
  let assert Error(reason) = account.from_hex("zz")
  assert reason == "invalid hex private key"
}

/// 32 バイトでない鍵は理由付きで拒否する。
pub fn from_hex_rejects_wrong_length_test() {
  let assert Error(reason) = account.from_hex("00112233")
  assert reason == "private key must be 32 bytes"
}

/// 範囲外のスカラー（0 と位数 n）は公開鍵を導けないため拒否する。
pub fn from_hex_rejects_out_of_range_test() {
  let assert Error(reason) =
    account.from_hex(
      "0000000000000000000000000000000000000000000000000000000000000000",
    )
  assert reason == "private key not in valid range"
  let assert Error(_) =
    account.from_hex(
      "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
    )
}

/// 前後の空白は取り除いてから読む。カンマ区切りの設定をそのまま渡せる。
pub fn from_hex_trims_whitespace_test() {
  let assert Ok(signer) = account.from_hex("  " <> key <> "\t")
  let assert Ok(same) = account.from_hex(key)
  assert signer.pubkey_hex == same.pubkey_hex
}

/// 鍵をすべて読み込む。1 つでも不正なら、そこで失敗して理由を返す。
pub fn load_all_fails_on_the_first_invalid_key_test() {
  let assert Ok(accounts) = account.load_all([key, key])
  assert list.length(accounts) == 2

  let assert Error(reason) = account.load_all([key, "not-hex"])
  assert reason == "invalid hex private key"

  assert account.load_all([]) == Ok([])
}
