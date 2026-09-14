//// `nostrconnect://` URI の解釈のテスト。

import gleam/option.{None, Some}
import nostr_no_su/bunker/nostrconnect.{
  ConnectRequest, InvalidRelayUrl, MalformedClientPubkey, MalformedQuery,
  NoRelay, NoSecret, NotNostrconnect,
}

/// クライアント公開鍵（32 バイトの hex、小文字）。
const client = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"

/// クライアント公開鍵を大文字にした表記。
const client_upper = "AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899"

/// 正常な URI から `client` / `relays` / `secret` / `perms` / `name` を取り出す
/// （percent デコードを含む）。
pub fn parse_reads_every_field_test() {
  let uri =
    "nostrconnect://"
    <> client
    <> "?relay=wss%3A%2F%2Fr.example&secret=s3cret&perms=sign_event%3A1&name=my%20app"
  assert nostrconnect.parse(uri)
    == Ok(ConnectRequest(
      client: client,
      relays: ["wss://r.example"],
      secret: "s3cret",
      perms: "sign_event:1",
      name: Some("my app"),
    ))
}

/// `secret` の `+` が空白にならない。
pub fn parse_keeps_plus_in_secret_test() {
  let uri =
    "nostrconnect://" <> client <> "?relay=wss://r.example&secret=abc+def"
  assert nostrconnect.parse(uri)
    == Ok(ConnectRequest(
      client: client,
      relays: ["wss://r.example"],
      secret: "abc+def",
      perms: "",
      name: None,
    ))
}

/// 複数の `relay` を並び順に集める。
pub fn parse_collects_relays_in_order_test() {
  let uri =
    "nostrconnect://"
    <> client
    <> "?relay=wss://a.example&secret=s&relay=wss://b.example"
  assert nostrconnect.parse(uri)
    == Ok(ConnectRequest(
      client: client,
      relays: ["wss://a.example", "wss://b.example"],
      secret: "s",
      perms: "",
      name: None,
    ))
}

/// 大文字の pubkey を小文字にそろえる。
pub fn parse_lowercases_client_pubkey_test() {
  let uri =
    "nostrconnect://" <> client_upper <> "?relay=wss://r.example&secret=s"
  assert nostrconnect.parse(uri)
    == Ok(ConnectRequest(
      client: client,
      relays: ["wss://r.example"],
      secret: "s",
      perms: "",
      name: None,
    ))
}

/// `perms` と `name` を省いた URI で `perms == ""`、`name == None`。
pub fn parse_defaults_optional_fields_test() {
  let uri = "nostrconnect://" <> client <> "?relay=wss://r.example&secret=s"
  assert nostrconnect.parse(uri)
    == Ok(ConnectRequest(
      client: client,
      relays: ["wss://r.example"],
      secret: "s",
      perms: "",
      name: None,
    ))
}

/// `bunker://` と URI でない文字列が `NotNostrconnect`。
pub fn parse_rejects_other_scheme_test() {
  assert nostrconnect.parse(
      "bunker://" <> client <> "?relay=wss://r.example&secret=s",
    )
    == Error(NotNostrconnect)
  assert nostrconnect.parse("not a uri") == Error(NotNostrconnect)
}

/// 長さの足りない hex が `MalformedClientPubkey`。
pub fn parse_rejects_malformed_client_pubkey_test() {
  assert nostrconnect.parse(
      "nostrconnect://aabb?relay=wss://r.example&secret=s",
    )
    == Error(MalformedClientPubkey)
}

/// `relay=%zz` が `MalformedQuery`。
pub fn parse_rejects_malformed_query_test() {
  assert nostrconnect.parse(
      "nostrconnect://" <> client <> "?relay=%zz&secret=s",
    )
    == Error(MalformedQuery)
}

/// `relay` 無しが `NoRelay`。
pub fn parse_rejects_missing_relay_test() {
  assert nostrconnect.parse("nostrconnect://" <> client <> "?secret=s")
    == Error(NoRelay)
}

/// `https://a`、空の値、`wss://a b` が `InvalidRelayUrl`。
pub fn parse_rejects_non_websocket_relay_test() {
  assert nostrconnect.parse(
      "nostrconnect://" <> client <> "?relay=https://a.example&secret=s",
    )
    == Error(InvalidRelayUrl("https://a.example"))
  assert nostrconnect.parse("nostrconnect://" <> client <> "?relay=&secret=s")
    == Error(InvalidRelayUrl(""))
  assert nostrconnect.parse(
      "nostrconnect://" <> client <> "?relay=wss%3A%2F%2Fa%20b&secret=s",
    )
    == Error(InvalidRelayUrl("wss://a b"))
}

/// `secret` 無しと `secret=` が `NoSecret`。
pub fn parse_rejects_missing_secret_test() {
  assert nostrconnect.parse(
      "nostrconnect://" <> client <> "?relay=wss://r.example",
    )
    == Error(NoSecret)
  assert nostrconnect.parse(
      "nostrconnect://" <> client <> "?relay=wss://r.example&secret=",
    )
    == Error(NoSecret)
}
