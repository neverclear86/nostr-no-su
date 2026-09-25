//// `nostrconnect://` URI の解釈のテスト。

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import nostr_no_su/bunker/nostrconnect.{
  ConnectRequest, InternalRelayUrl, InvalidRelayUrl, MalformedClientPubkey,
  MalformedQuery, NoRelay, NoSecret, NotNostrconnect, TooManyRelays,
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

/// `=` の無いクエリーの断片は、値が空文字列のキーとして扱う。
pub fn parse_treats_bare_query_key_as_empty_value_test() {
  let uri =
    "nostrconnect://" <> client <> "?relay=wss://r.example&secret=s&name"
  assert nostrconnect.parse(uri)
    == Ok(ConnectRequest(
      client: client,
      relays: ["wss://r.example"],
      secret: "s",
      perms: "",
      name: Some(""),
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

/// 長さの足りない hex と、64 文字でも 16 進でないホストが
/// `MalformedClientPubkey`。
pub fn parse_rejects_malformed_client_pubkey_test() {
  assert nostrconnect.parse(
      "nostrconnect://aabb?relay=wss://r.example&secret=s",
    )
    == Error(MalformedClientPubkey)
  assert nostrconnect.parse(
      "nostrconnect://"
      <> string.repeat("z", 64)
      <> "?relay=wss://r.example&secret=s",
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

/// `https://a`、空の値、`wss://a b`、大文字スキームの `WSS://a.example` が
/// `InvalidRelayUrl`。
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
  assert nostrconnect.parse(
      "nostrconnect://" <> client <> "?relay=WSS://a.example&secret=s",
    )
    == Error(InvalidRelayUrl("WSS://a.example"))
}

/// `max_relays` 件の `relay` を持つ URI は通り、`relays` は同じ並びになる。
pub fn parse_accepts_relays_up_to_the_limit_test() {
  let relays = numbered_relays(nostrconnect.max_relays)
  assert nostrconnect.parse(uri_with_relays(relays))
    |> result.map(fn(request) { request.relays })
    == Ok(relays)
}

/// `max_relays` 件を 1 件超える `relay` を持つ URI が `TooManyRelays`。
pub fn parse_rejects_relays_over_the_limit_test() {
  assert nostrconnect.parse(
      uri_with_relays(numbered_relays(nostrconnect.max_relays + 1)),
    )
    == Error(TooManyRelays)
}

/// 公開のリレーの後ろに内部のアドレスのリレーを 1 件置いた URI が、その URL の
/// `InternalRelayUrl`。ループバック、リンクローカル、プライベート、未指定の
/// アドレス、IPv4 射影、省略形の IPv4、ドットを含まない名前、`.localhost` で
/// 終わる名前、大文字と末尾のドットを含む。
pub fn parse_rejects_internal_relay_hosts_test() {
  use url <- list.each([
    "ws://127.0.0.1:7777", "ws://127.1", "ws://[::1]:7777",
    "ws://localhost:7777", "wss://LOCALHOST./", "ws://relay.LocalHost",
    "ws://0.0.0.0", "ws://[::]", "ws://169.254.169.254/", "ws://[fe80::1]",
    "ws://[febf::1]", "ws://10.0.0.1", "ws://172.16.0.1", "ws://172.31.255.255",
    "ws://192.168.1.1", "ws://[fc00::1]", "ws://[fdff::1]",
    "ws://[::ffff:192.168.0.1]", "ws://postgres:5432", "ws://postgres.:5432",
    "ws://2130706433",
  ])
  assert nostrconnect.parse(uri_with_relays(["wss://r.example", url]))
    == Error(InternalRelayUrl(url))
}

/// 内部の範囲の境界のすぐ外にあるアドレスと公開の名前のリレーは通る。
pub fn parse_accepts_public_relay_hosts_test() {
  use url <- list.each([
    "wss://relay.example", "ws://1.1.1.1", "ws://11.0.0.1",
    "ws://126.255.255.255", "ws://128.0.0.1", "ws://169.253.0.1",
    "ws://169.255.0.1", "ws://172.15.255.255", "ws://172.32.0.1",
    "ws://192.167.0.1", "ws://192.169.0.1", "ws://[2001:db8::1]",
    "ws://[fec0::1]", "ws://[fe7f::1]", "ws://[fbff::1]", "ws://[fe00::1]",
    "ws://[::2]", "ws://[::ffff:8.8.8.8]",
  ])
  assert nostrconnect.parse(uri_with_relays([url]))
    |> result.map(fn(request) { request.relays })
    == Ok([url])
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

/// `client` と `secret=s` を持ち、`relays` を並び順に `relay=` で並べた URI。
/// 値は `uri.percent_encode` する。
fn uri_with_relays(relays: List(String)) -> String {
  let query =
    relays
    |> list.map(fn(relay) { "relay=" <> uri.percent_encode(relay) <> "&" })
    |> string.concat
  "nostrconnect://" <> client <> "?" <> query <> "secret=s"
}

/// `wss://r0.example` から始まる、番号の違う `count` 件の relay URL。
fn numbered_relays(count: Int) -> List(String) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, n) { "wss://r" <> int.to_string(n) <> ".example" })
}
