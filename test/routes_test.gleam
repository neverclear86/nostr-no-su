//// 管理 UI のパスの解析（`admin/routes` の `parse`）の単体テスト。

import gleam/list
import nostr_no_su/admin/routes

/// 構築子ごとのパスはその構築子になり、引数の検査に落ちるパスと余分なセグメントを持つパスは Error になる。
pub fn parse_test() {
  use #(name, segments, expected) <- list.each([
    #("dashboard", [], Ok(routes.ShowDashboard)),
    #("stylesheet", ["static", "admin.css"], Ok(routes.Stylesheet)),
    #("script", ["static", "admin.js"], Ok(routes.Script)),
    #("switch language", ["language"], Ok(routes.SwitchLanguage)),
    #("switch theme", ["theme"], Ok(routes.SwitchTheme)),
    #("approve", ["approve", "tok"], Ok(routes.ApproveConnection("tok"))),
    #("deny", ["deny", "tok"], Ok(routes.DenyConnection("tok"))),
    #("revoke session", ["sessions", "revoke"], Ok(routes.RevokeSession)),
    #("connect client", ["sessions", "connect"], Ok(routes.ConnectClient)),
    #(
      "confirm connection",
      ["sessions", "connect", "confirm"],
      Ok(routes.ConfirmConnection),
    ),
    #("reenable plugin", ["plugins", "reenable"], Ok(routes.ReenablePlugin)),
    #("reload accounts", ["accounts", "reload"], Ok(routes.ReloadAccounts)),
    #("new relay", ["relays", "new"], Ok(routes.NewRelay)),
    #("generate account", ["accounts", "generate"], Ok(routes.GenerateAccount)),
    #("import account", ["accounts", "import"], Ok(routes.ImportAccount)),
    #(
      "register generated account",
      ["accounts", "register-generated"],
      Ok(routes.RegisterGeneratedAccount),
    ),
    #(
      "account operation",
      ["accounts", "abcd", "label"],
      Ok(routes.AccountOperation("abcd", routes.EditLabel)),
    ),
    #(
      "relay operation",
      ["relays", "7", "delete"],
      Ok(routes.RelayOperation(7, routes.DeleteRelay)),
    ),
    #(
      "plugin page",
      ["plugins", "a%20b", "status"],
      Ok(routes.ShowPluginPage("a b", "status")),
    ),
    #(
      "session permissions",
      ["sessions", "abcd", "ef01", "permissions"],
      Ok(routes.SessionPermissions("abcd", "ef01")),
    ),
    #("unknown segment", ["nope"], Error(Nil)),
    #("approve without a token", ["approve"], Error(Nil)),
    #("approve with an extra segment", ["approve", "tok", "x"], Error(Nil)),
    #("unknown account action", ["accounts", "abcd", "nope"], Error(Nil)),
    #(
      "account action with an extra segment",
      ["accounts", "abcd", "label", "x"],
      Error(Nil),
    ),
    #(
      "account action on another path",
      ["sessions", "abcd", "delete"],
      Error(Nil),
    ),
    #("a fixed route's head alone", ["accounts", "new"], Error(Nil)),
    #(
      "relay operation with a non-integer id",
      ["relays", "x", "delete"],
      Error(Nil),
    ),
    #("unknown relay action", ["relays", "7", "nope"], Error(Nil)),
    #("plugin page without a page", ["plugins", "console_logger"], Error(Nil)),
    #(
      "plugin page with an undecodable name",
      ["plugins", "%ZZ", "status"],
      Error(Nil),
    ),
    #(
      "session permissions with another tail",
      ["sessions", "abcd", "ef01", "x"],
      Error(Nil),
    ),
    #("another static file", ["static", "other.css"], Error(Nil)),
  ])
  assert #(name, routes.parse(segments)) == #(name, expected)
}
