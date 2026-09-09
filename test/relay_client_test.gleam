import gleam/http
import gleam/option.{Some}
import nostr_no_su/relay_client

/// 取り除くのは先頭のスキームだけで、以降に現れる "://" は残す。
pub fn label_strips_only_the_scheme_test() {
  assert relay_client.label("ws://127.0.0.1:7777") == "127.0.0.1:7777"
  assert relay_client.label("wss://relay.example/wss://x")
    == "relay.example/wss://x"
  assert relay_client.label("relay.example") == "relay.example"
}

/// `wss` は、stratus が TLS ソケットに戻す https リクエストになる。
pub fn to_request_maps_wss_to_https_test() {
  let assert Ok(req) = relay_client.to_request("wss://relay.example/path")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
  assert req.path == "/path"
}

/// `ws` はポートも含めてそのまま平文の http リクエストになる。
pub fn to_request_maps_ws_to_http_test() {
  let assert Ok(req) = relay_client.to_request("ws://127.0.0.1:7777")
  assert req.scheme == http.Http
  assert req.host == "127.0.0.1"
  assert req.port == Some(7777)
}

/// それ以外のスキームは手を加えずそのまま通す。
pub fn to_request_leaves_other_schemes_alone_test() {
  let assert Ok(req) = relay_client.to_request("https://relay.example")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
}
