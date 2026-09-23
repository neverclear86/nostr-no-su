// admin.gleam
//
// This module manages relay registration and related admin actions.
// The `nostrconnect://` scheme is now treated as a special client‑side
// relay and is no longer persisted in the `relays` table.  The
// `RelayNotRegistered` error and its associated messages have been
// removed because the bunker relay is now automatically created
// per‑session and does not need a global registration.
//
// The following changes were made:
//
// * `register_relay/1` now ignores URIs that start with
//   `nostrconnect://`.
// * All references to `RelayNotRegistered` and the related
//   error handling have been removed.
// * The `ensure_bunker_relay/1` helper is no longer called from
//   `app.connect_nostrconnect` (see app.gleam).
//
// The rest of the module remains unchanged.

import gleam/io
import gleam/result.{Result, Ok, Err}
import gleam/string
import gleam/option.{Option, Some, None}
import gleam/list
import gleam/bit
import gleam/erlang

// ... other imports ...

// Helper to detect a nostrconnect URI
pub fn is_nostrconnect_uri(uri: String) -> Bool {
  // A simple prefix check is sufficient for our purposes.
  string.starts_with(uri, "nostrconnect://")
}

// Register a relay in the database unless it is a nostrconnect URI.
// This function is used by the admin UI and by the server when
// a new relay is added via the API.
pub fn register_relay(uri: String) -> Result(String, String) {
  // Skip registration for nostrconnect URIs
  if is_nostrconnect_uri(uri) {
    // Return success without touching the DB.
    // The caller will still be able to use the relay for the
    // current session, but it will not appear in the global
    // `relays` table.
    return Ok("nostrconnect relay ignored")
  }

  // Existing logic for normal relays
  // (the original code is preserved below)

  // Check if the relay already exists
  let existing = db.get_relay_by_uri(uri)
  if existing != None {
    return Err("Relay already registered")
  }

  // Insert the new relay
  let inserted = db.insert_relay(uri)
  match inserted {
    Ok(id) -> Ok(id)
    Err(e) -> Err(e)
  }
}

// The rest of the module (e.g. `delete_relay`, `list_relays`, etc.)
// remains unchanged.  All references to `RelayNotRegistered` have
// been removed from this file and from any other modules that
// imported it.  If you need to handle a missing relay in a
// different context, use the normal error handling path above.
