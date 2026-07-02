//// A bunker account: the key material for one identity the bunker signs for.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import gleam/uri
import nostr_no_su/crypto/secp256k1

pub type Account {
  Account(privkey: BitArray, pubkey: BitArray, pubkey_hex: String)
}

/// Build an account from a 64-char hex private key.
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

/// Parse a comma-separated list of hex private keys.
pub fn load_all(raw_keys: List(String)) -> Result(List(Account), String) {
  list.try_map(raw_keys, from_hex)
}

/// The `bunker://` connection URI a client pastes to reach this account.
pub fn bunker_uri(
  account: Account,
  relay_url: String,
  secret: String,
) -> String {
  "bunker://"
  <> account.pubkey_hex
  <> "?relay="
  <> uri.percent_encode(relay_url)
  <> "&secret="
  <> secret
}
