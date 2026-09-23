//// 管理 UI のリレーのフォームの中身（`admin/relay_pages`）の単体テスト。

import gleam/option.{None}
import gleam/string
import lustre/element
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/relay_pages
import nostr_no_su/relay_list.{Roles}
import nostr_no_su/relay_store.{Relay}

/// 追加のフォームの中身は `/relays/new` へ POST し、URL の欄の補足を欄の下の 1 行で結び付ける。
/// ページの枠は含めない。
pub fn new_relay_form_describes_the_url_field_test() {
  let html =
    relay_pages.new_relay_form(i18n.English, "", Roles(False, True))
    |> element.fragment
    |> element.to_string
  assert string.contains(
    html,
    "<form action=\"/relays/new\" class=\"flex flex-col gap-4\" method=\"post\">",
  )
  assert string.contains(html, "aria-describedby=\"relay-url-hint\"")
  assert string.contains(html, "<p class=\"text-muted\" id=\"relay-url-hint\">")
  assert !string.contains(html, "<header")
}

/// 用途の編集と削除の中身は、結果の注意の段落を畳まずにフォームの直前に出す。
pub fn relay_action_form_keeps_the_description_visible_test() {
  let edit = action_form(dashboard.EditRelayRoles)
  let delete = action_form(dashboard.DeleteRelay)
  assert string.contains(
    edit,
    "<p>"
      <> i18n.text(i18n.English, i18n.EditRelayRolesDescription)
      <> "</p><form action=\"/relays/7/edit\"",
  )
  assert string.contains(
    delete,
    "<p>"
      <> i18n.text(i18n.English, i18n.DeleteRelayDescription)
      <> "</p><form action=\"/relays/7/delete\"",
  )
  assert !string.contains(edit, "popover")
  assert !string.contains(delete, "popover")
}

/// id 7 のリレーへの `action` の英語のフォームの中身を HTML 文字列にする。
fn action_form(action: dashboard.RelayAction) -> String {
  let relay = Relay(id: 7, url: "wss://relay.example", roles: Roles(True, True))
  relay_pages.relay_action_form(i18n.English, relay, action, None, None)
  |> element.fragment
  |> element.to_string
}
