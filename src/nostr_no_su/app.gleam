// app.gleam
//
// The `connect_nostrconnect` function used to call
// `ensure_bunker_relay` to register a global bunker relay
// for the `nostrconnect://` scheme.  That behaviour has been
// removed because the bunker relay is now created per‑session
// and should not be persisted in the `relays` table.
//
// The function now simply waits for the session relay to
// connect before publishing the `connect` response.

import gleam/io
import gleam/result.{Result, Ok, Err}
import gleam/async
import gleam/option.{Option, Some, None}
import gleam/list
import gleam/string
import gleam/erlang

// ... other imports ...

pub fn connect_nostrconnect(session: Session, uri: String) -> Result(String, String) {
  // Previously: ensure_bunker_relay(uri)
  // Now: skip global registration

  // Create a per‑session bunker relay if it does not exist
  let bunker = session.get_or_create_bunker_relay()

  // Wait for the session relay to be ready before publishing
  async.await_publisher(bunker)

  // Send the connect response to the client
  let response = build_connect_response(session, uri)
  async.publish_to_client(session, response)

  Ok("connected")
}
