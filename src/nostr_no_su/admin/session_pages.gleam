//// 管理 UI のセッションの権限の編集ページ（`/sessions/<signer>/<client>/permissions`）の描画。
//// フォームの中身はダッシュボードのダイアログと共用するので `admin/dashboard`（`permissions_form`）
//// にあり、ここはそれを要約と入力の誤りと一緒にページの枠に入れる。`admin/relay_pages` と同じく
//// `admin/dashboard` と、`admin/view` と `admin/permission_view` の部品で HTML 文字列にするだけで、
//// プロセスにも IO にも触れない。
////
//// 埋め込む値（署名者・クライアントの公開鍵、権限のトークン）はテキストか属性値として
//// lustre に渡し、エスケープを文字列化に任せる（`admin/view` の規則に従う）。文言は
//// `admin/i18n` から表示の言語で引き、文字列リテラルで書かない（同じく `admin/view` の
//// 規則）。

import gleam/option.{type Option, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/permission_view
import nostr_no_su/admin/view

/// ページの kind の欄の補足の `id`。ページには kind の欄が 1 つだけなので固定の値にする（ダッシュボードの
/// ダイアログは行ごとの値を `dashboard.permissions_form` に渡す）。
const kinds_hint_id = "session-permissions-kinds-hint"

/// セッションの権限の編集ページ。`session` を得られなければ理由の囲みだけを出して
/// フォームを出さない。`form` は描き直すときに送られた欄の状態で、`None` なら
/// `session` の保存済みの値を欄に入れる（`dashboard.permissions_form`）。
pub fn session_permissions_page(
  language: Language,
  theme: view.Theme,
  session: Result(dashboard.SessionRow, i18n.Reason),
  form: Option(dashboard.PermissionsForm),
  error: Option(i18n.Reason),
) -> String {
  let path = case session {
    Ok(row) -> dashboard.session_permissions_path(row.signer, row.client)
    Error(_) -> "/"
  }
  view.page(
    language,
    theme,
    i18n.EditPermissions,
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.card(card_body(language, session, form, error)),
      view.back_link(language),
    ],
  )
}

/// カードの中身。`session` を得られなければ理由の囲み 1 つ、得られれば要約、入力の誤り、
/// フォームの中身（`dashboard.permissions_form`）を出す。
fn card_body(
  language: Language,
  session: Result(dashboard.SessionRow, i18n.Reason),
  form: Option(dashboard.PermissionsForm),
  error: Option(i18n.Reason),
) -> List(Element(msg)) {
  case session {
    Error(reason) -> [
      view.alert(
        view.Neutral,
        view.reason_content(language, Some(i18n.CouldNotListSessions), reason),
      ),
    ]
    Ok(row) -> [
      summary(language, row),
      view.error_message(language, Some(i18n.CouldNotSavePermissions), error),
      ..dashboard.permissions_form(
        language,
        row,
        form,
        kinds_hint_id,
        view.InForm,
      )
    ]
  }
}

/// 要約。クライアントの省略 id、署名者の省略 16 進、今の権限のチップ（無宣言なら
/// バッジ）を並べる。
fn summary(language: Language, session: dashboard.SessionRow) -> Element(msg) {
  let text = i18n.text(language, _)
  view.detail_list([
    #(
      text(i18n.Client),
      html.dd([], [
        view.truncated_id(language, session.client, text(i18n.CopyClient)),
      ]),
    ),
    #(
      text(i18n.Signer),
      html.dd([], [
        html.span(
          [
            attribute.class("font-mono text-xs"),
            attribute.title(session.signer),
          ],
          [html.text(view.shorten(session.signer))],
        ),
      ]),
    ),
    #(
      text(i18n.CurrentPermissions),
      html.dd([], [current_permissions(language, session.perms)]),
    ),
  ])
}

/// 今の権限。無宣言（空文字列）ならバッジ、そうでなければチップ。
fn current_permissions(language: Language, perms: String) -> Element(msg) {
  case perms {
    "" ->
      view.status_chip(
        view.ToneChip(view.Neutral),
        i18n.text(language, i18n.PermissionsNotDeclared),
      )
    _ -> permission_view.chips(language, perms)
  }
}
