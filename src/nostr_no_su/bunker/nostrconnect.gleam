//// クライアントが出す `nostrconnect://` URI を解釈する純粋なモジュール。
////
//// 前後の空白は落とさない（貼り付けの整形は呼び出し側の責務）。クエリーの値は
//// percent デコードだけを行い、`+` を空白にしない。form 符号化
//// （`application/x-www-form-urlencoded`）で URI を組んだクライアントが `name`
//// に入れた空白は `+` のまま残るが、これは `secret` を 1 バイトも変えないための
//// 選択である。`relay` / `secret` / `perms` / `name` 以外のクエリーのキーは無視する。
////
//// `relay` は件数（`max_relays` まで）と、ホストが内部のアドレス（ループバック、
//// リンクローカル、プライベート、未指定のアドレス、ドットを含まない名前、
//// `.localhost` で終わる名前）を指さないことも確かめる。名前は解決しないので、
//// 公開の名前が内部のアドレスに解決される場合は通る。

import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/uri
import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex
import nostr_no_su/relay_client

/// `nostrconnect://` URI が持てる `relay` の件数の上限。
pub const max_relays = 5

/// `nostrconnect://` URI が求める接続。`client` は小文字 16 進の 32 バイト、
/// `relays` は URI に現れた順、`secret` はクライアントが `connect` の応答で受け取る
/// ことを期待する値、`perms` は要求された権限（省略時は空文字列）、`name` は
/// クライアントの表示名。
pub type ConnectRequest {
  ConnectRequest(
    client: String,
    relays: List(String),
    secret: String,
    perms: String,
    name: Option(String),
  )
}

/// URI を解釈できなかった理由。
pub type ParseError {
  NotNostrconnect
  MalformedClientPubkey
  MalformedQuery
  NoRelay
  InvalidRelayUrl(url: String)
  /// `relay` が `max_relays` 件を超える。
  TooManyRelays
  /// ホストが内部のアドレスを指す relay URL。
  InternalRelayUrl(url: String)
  NoSecret
}

/// `inet:parse_address` が読んだ IP アドレス。要素は IPv4 が 8 ビット、IPv6 が
/// 16 ビットの値で、FFI の `parse_ip_address` が `{ipv4, …}` / `{ipv6, …}` の形で
/// 返す。
type IpAddress {
  Ipv4(Int, Int, Int, Int)
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// `nostrconnect://<client-pubkey>?relay=…&secret=…&perms=…&name=…` を解釈する。
pub fn parse(text: String) -> Result(ConnectRequest, ParseError) {
  use parsed <- result.try(
    uri.parse(text) |> result.replace_error(NotNostrconnect),
  )
  use _ <- result.try(check_scheme(parsed.scheme))
  use client <- result.try(client_pubkey(option.unwrap(parsed.host, "")))
  use params <- result.try(query_params(option.unwrap(parsed.query, "")))
  use relays <- result.try(relay_urls(params))
  use secret <- result.try(secret(params))
  let perms = list.key_find(params, "perms") |> result.unwrap("")
  let name = list.key_find(params, "name") |> option.from_result
  Ok(ConnectRequest(
    client: client,
    relays: relays,
    secret: secret,
    perms: perms,
    name: name,
  ))
}

/// `Some("nostrconnect")` 以外を `NotNostrconnect` にする。`uri.parse` はスキームを
/// 小文字にするので、大文字混じりの URI も通る。
fn check_scheme(scheme: Option(String)) -> Result(Nil, ParseError) {
  case scheme {
    Some("nostrconnect") -> Ok(Nil)
    _ -> Error(NotNostrconnect)
  }
}

/// ホストをクライアント公開鍵として読む。32 バイトちょうどの 16 進でなければ
/// `MalformedClientPubkey`。
fn client_pubkey(host: String) -> Result(String, ParseError) {
  hex.decode_exact(host, secp256k1.xonly_pubkey_bytes)
  |> result.map(hex.encode)
  |> result.replace_error(MalformedClientPubkey)
}

/// クエリー文字列を `&` で分け、`=` で 1 回だけ分けてキーと値を percent デコード
/// する。`application/x-www-form-urlencoded` の `+` を空白にする変換は行わない。
/// 1 つでもデコードに失敗したら `MalformedQuery`。
fn query_params(query: String) -> Result(List(#(String, String)), ParseError) {
  query
  |> string.split("&")
  |> list.filter(fn(fragment) { fragment != "" })
  |> list.try_map(query_pair)
  |> result.replace_error(MalformedQuery)
}

/// クエリーの 1 断片をキーと値の組にする。`=` が無ければ値は空文字列。
fn query_pair(fragment: String) -> Result(#(String, String), Nil) {
  let #(key, value) = case string.split_once(fragment, "=") {
    Ok(pair) -> pair
    Error(Nil) -> #(fragment, "")
  }
  use key <- result.try(uri.percent_decode(key))
  use value <- result.try(uri.percent_decode(value))
  Ok(#(key, value))
}

/// `relay` の値を並び順にすべて集め、`check_relay_url` を通ったものだけを返す。
/// 1 件も無ければ `NoRelay`、`max_relays` 件を超えれば URL を見る前に
/// `TooManyRelays`、通らない URL があれば並び順で最初のものの理由を返す。
fn relay_urls(
  params: List(#(String, String)),
) -> Result(List(String), ParseError) {
  case list.key_filter(params, "relay") {
    [] -> Error(NoRelay)
    relays ->
      case list.length(relays) > max_relays {
        True -> Error(TooManyRelays)
        False -> list.try_map(relays, check_relay_url)
      }
  }
}

/// 1 件の relay URL を `relay_client.to_request` で確かめ、受けなければ
/// `InvalidRelayUrl`。受けた URL の接続先のホストが内部のアドレスを指せば
/// （`internal_host`）`InternalRelayUrl`。
fn check_relay_url(url: String) -> Result(String, ParseError) {
  case relay_client.to_request(url) {
    Error(Nil) -> Error(InvalidRelayUrl(url))
    Ok(req) ->
      case internal_host(req.host) {
        True -> Error(InternalRelayUrl(url))
        False -> Ok(url)
      }
  }
}

/// relay URL のホストが内部のアドレスを指すか。小文字にし、末尾のドットを 1 つ
/// 落としてから見る。IP アドレスとして読めれば `internal_address` で決め、
/// 読めなければドットを含まない名前（`localhost`、`postgres` など）と
/// `.localhost` で終わる名前を内部とする。IP アドレスは `inet:parse_address` で
/// 読むので、`127.1` や `2130706433` のような省略形も同じアドレスとして扱う。
fn internal_host(host: String) -> Bool {
  let lowered = string.lowercase(host)
  let name = case string.ends_with(lowered, ".") {
    True -> string.drop_end(lowered, 1)
    False -> lowered
  }
  case parse_ip_address(name) {
    Ok(address) -> internal_address(address)
    Error(Nil) ->
      !string.contains(name, ".") || string.ends_with(name, ".localhost")
  }
}

/// IP アドレスが未指定（`0.0.0.0/8`、`::`）、ループバック（`127.0.0.0/8`、
/// `::1`）、リンクローカル（`169.254.0.0/16`、`fe80::/10`）、プライベート
/// （`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`fc00::/7`）の範囲に
/// あるか。IPv4 射影の IPv6 アドレス（`::ffff:0:0/96`）は埋め込んだ IPv4
/// アドレスで決める。
fn internal_address(address: IpAddress) -> Bool {
  case address {
    Ipv4(0, _, _, _)
    | Ipv4(127, _, _, _)
    | Ipv4(10, _, _, _)
    | Ipv4(169, 254, _, _)
    | Ipv4(192, 168, _, _) -> True
    Ipv4(172, second, _, _) -> second >= 16 && second <= 31
    Ipv4(_, _, _, _) -> False
    Ipv6(0, 0, 0, 0, 0, 0xffff, high, low) ->
      internal_address(Ipv4(high / 256, high % 256, low / 256, low % 256))
    Ipv6(0, 0, 0, 0, 0, 0, 0, 0) | Ipv6(0, 0, 0, 0, 0, 0, 0, 1) -> True
    Ipv6(first, _, _, _, _, _, _, _) ->
      int.bitwise_and(first, 0xffc0) == 0xfe80
      || int.bitwise_and(first, 0xfe00) == 0xfc00
  }
}

/// `host` を IPv4 か IPv6 のアドレスとして読む。読めなければ `Error(Nil)`。
@external(erlang, "nostr_no_su_ffi", "parse_ip_address")
fn parse_ip_address(host: String) -> Result(IpAddress, Nil)

/// `secret` の値を取り出す。無いか空文字列なら `NoSecret`。
fn secret(params: List(#(String, String))) -> Result(String, ParseError) {
  case list.key_find(params, "secret") {
    Ok(value) if value != "" -> Ok(value)
    _ -> Error(NoSecret)
  }
}
