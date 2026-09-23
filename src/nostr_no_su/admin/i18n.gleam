// i18n.gleam
//
// Updated the user‑facing message for the `nostrconnect://` form
// to reflect the new behaviour: the relay is used only for the
// current session and is not registered globally.

pub fn get_message(key: String) -> String {
  match key {
    // ... other keys ...
    "uri_relay_description" ->
      // Old text: "URI のリレーはバンカーの用途で登録します"
      // New text: "URI のリレーはクライアントごとのセッションで使用します"
      "URI のリレーはクライアントごとのセッションで使用します"
    _ -> "Unknown message key"
  }
}
