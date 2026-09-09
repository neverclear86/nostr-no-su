import gleam/http
import gleam/option.{Some}
import nostr_no_su/relay_client

/// Only the leading scheme is stripped, not later occurrences of "://".
pub fn label_strips_only_the_scheme_test() {
  assert relay_client.label("ws://127.0.0.1:7777") == "127.0.0.1:7777"
  assert relay_client.label("wss://relay.example/wss://x")
    == "relay.example/wss://x"
  assert relay_client.label("relay.example") == "relay.example"
}

/// `wss` becomes the https request stratus turns back into a TLS socket.
pub fn to_request_maps_wss_to_https_test() {
  let assert Ok(req) = relay_client.to_request("wss://relay.example/path")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
  assert req.path == "/path"
}

/// `ws` becomes a plain http request, port and all.
pub fn to_request_maps_ws_to_http_test() {
  let assert Ok(req) = relay_client.to_request("ws://127.0.0.1:7777")
  assert req.scheme == http.Http
  assert req.host == "127.0.0.1"
  assert req.port == Some(7777)
}

/// Any other scheme is passed through untouched.
pub fn to_request_leaves_other_schemes_alone_test() {
  let assert Ok(req) = relay_client.to_request("https://relay.example")
  assert req.scheme == http.Https
  assert req.host == "relay.example"
}
