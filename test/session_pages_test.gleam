//// 管理 UI のセッションの権限の編集フォームの中身（`admin/session_pages`）の単体テスト。

import gleam/option.{None}
import gleam/string
import lustre/element
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/session_pages

/// kind 1 の署名だけを許すセッションで、英語のフォームの中身を HTML 文字列にする。
fn english_form() -> String {
  let session =
    dashboard.SessionRow(
      signer: "0123",
      client: "4567",
      perms: "sign_event:1",
      created_at: 0,
      last_used_at: 0,
    )
  session_pages.permissions_form(i18n.English, session, None)
  |> element.fragment
  |> element.to_string
}

/// フォームの中身はセッションの権限のパスへ POST し、保存済みの kind を欄に出す。ページの枠と
/// 要約は含めない。
pub fn permissions_form_posts_without_the_page_frame_test() {
  let html = english_form()
  assert string.contains(
    html,
    "<form action=\"/sessions/0123/4567/permissions\" class=\"flex flex-col gap-4\" method=\"post\">",
  )
  assert string.contains(html, "value=\"1\"")
  assert !string.contains(html, "<header")
  assert !string.contains(
    html,
    i18n.text(i18n.English, i18n.CurrentPermissions),
  )
}

/// kind の欄の補足は ⓘ のボタンで開く `popover` の段落で、欄の説明として結び付く。
pub fn permissions_form_opens_the_kinds_hint_from_the_info_button_test() {
  let html = english_form()
  assert string.contains(
    html,
    "aria-describedby=\"session-permissions-kinds-hint\"",
  )
  assert string.contains(
    html,
    "popovertarget=\"session-permissions-kinds-hint\"",
  )
  assert string.contains(
    html,
    "id=\"session-permissions-kinds-hint\" popover=\"auto\"",
  )
}
