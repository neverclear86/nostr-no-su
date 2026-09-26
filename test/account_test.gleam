import gleam/erlang/process
import gleam/list
import gleam/string
import nostr_no_su/bunker/account
import nostr_no_su/nostr/nip19
import support/vector.{bytes}

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

/// 32 バイトでない秘密鍵は `WrongLength` で拒否する。
pub fn from_privkey_rejects_wrong_length_test() {
  assert account.from_privkey(<<0, 17, 34, 51>>) == Error(account.WrongLength)
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
  assert account.from_privkey(privkey) == Error(account.OutOfRange)
}

/// BIP-340 の公式ベクター 0 の鍵から、NIP-19 の nsec と npub を作る。
pub fn npub_and_nsec_test() {
  let assert Ok(signer) =
    account.from_privkey(bytes(
      "0000000000000000000000000000000000000000000000000000000000000003",
    ))
  assert account.nsec(signer)
    == "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re"
  assert account.npub(signer)
    == "npub1lycg5qvjtrp3qjf5f7zl382j9x6nrjz9sdhenvyxq8c3808qxmus6gq266"
}

/// 範囲外の鍵を引いたら乱数を引き直す。1 回目に 0、2 回目にベクター 0 の鍵を返す偽の
/// 乱数では、2 回目の鍵のアカウントになる。
pub fn generate_retries_an_out_of_range_key_test() {
  let draws = process.new_subject()
  process.send(draws, <<0:size(256)>>)
  process.send(
    draws,
    bytes("0000000000000000000000000000000000000000000000000000000000000003"),
  )
  let generated =
    account.generate(fn(size) {
      let assert Ok(drawn) = process.receive(draws, 0)
      assert size == 32
      drawn
    })
  assert account.pubkey_hex(generated)
    == "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
  assert process.receive(draws, 0) == Error(Nil)
}
