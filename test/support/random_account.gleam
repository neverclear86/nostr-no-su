//// 実行のたびに違うマスターキーとアカウント。

import gleam/crypto
import nostr_no_su/bunker/account
import nostr_no_su/bunker/vault.{
  type MasterKey, type StoredAccount, StoredAccount,
}
import nostr_no_su/hex
import nostr_no_su/random

/// 実行のたびに違うマスターキー。
pub fn random_master_key() -> MasterKey {
  let assert Ok(key) =
    vault.master_key_from_hex(hex.encode(crypto.strong_random_bytes(32)))
  key
}

/// 実行のたびに違う鍵と secret を持ち、指定したラベルを持つアカウント。
pub fn random_entry(label: String) -> StoredAccount {
  let assert Ok(signer) = account.from_privkey(crypto.strong_random_bytes(32))
  StoredAccount(account: signer, secret: random.hex(16), label: label)
}
