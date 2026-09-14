//// クライアントが出す `nostrconnect://` URI を解釈する純粋なモジュール。
////
//// 前後の空白は落とさない（貼り付けの整形は呼び出し側の責務）。クエリーの値は
//// percent デコードだけを行い、`+` を空白にしない。form 符号化
//// （`application/x-www-form-urlencoded`）で URI を組んだクライアントが `name`
//// に入れた空白は `+` のまま残るが、これは `secret` を 1 バイトも変えないための
//// 選択である。`relay` / `secret` / `perms` / `name` 以外のクエリーのキーは無視する。

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import gleam/uri
import nostr_no_su/hex

/// クライアント公開鍵の長さ（バイト）。
const client_pubkey_bytes = 32

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
  NoSecret
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
  case hex.decode(host) {
    Ok(bytes) ->
      case bit_array.byte_size(bytes) == client_pubkey_bytes {
        True -> Ok(hex.encode(bytes))
        False -> Error(MalformedClientPubkey)
      }
    Error(Nil) -> Error(MalformedClientPubkey)
  }
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

/// `relay` の値を並び順にすべて集め、`ws://` / `wss://` でホストを持つものだけを
/// 通す。1 件も無ければ `NoRelay`。
fn relay_urls(
  params: List(#(String, String)),
) -> Result(List(String), ParseError) {
  case list.key_filter(params, "relay") {
    [] -> Error(NoRelay)
    relays -> list.try_map(relays, check_relay_url)
  }
}

/// 1 件の relay URL がスキーム `ws` / `wss` でホストが空でないかを確かめる。
fn check_relay_url(url: String) -> Result(String, ParseError) {
  case uri.parse(url) {
    Ok(uri.Uri(scheme: Some(scheme), host: Some(host), ..))
      if { scheme == "ws" || scheme == "wss" } && host != ""
    -> Ok(url)
    _ -> Error(InvalidRelayUrl(url))
  }
}

/// `secret` の値を取り出す。無いか空文字列なら `NoSecret`。
fn secret(params: List(#(String, String))) -> Result(String, ParseError) {
  case list.key_find(params, "secret") {
    Ok(value) if value != "" -> Ok(value)
    _ -> Error(NoSecret)
  }
}
