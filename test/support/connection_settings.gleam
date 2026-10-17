//// テストが使う `relay_connection.Settings` の、既定値つきの組み立て。

import gleam/erlang/process.{type Name}
import nostr_no_su/backoff.{type Backoff}
import nostr_no_su/relay_connection

/// `on_connect` と `on_disconnect` が何もせず、`stable_after_ms` が本番の既定値
/// （`relay_connection.default_stable_after_ms`）の `Settings`。これらを変える
/// テストは、戻り値を `Settings(..settings, 項目: 値)` の形で更新する。
pub fn new(
  name: Name(relay_connection.Msg),
  relay: String,
  connect: relay_connection.Connector,
  reconnect_delay: Backoff,
) -> relay_connection.Settings {
  relay_connection.Settings(
    name: name,
    relay: relay,
    connect: connect,
    on_connect: fn(_socket) { Nil },
    on_disconnect: fn() { Nil },
    reconnect_delay: reconnect_delay,
    stable_after_ms: relay_connection.default_stable_after_ms,
  )
}
