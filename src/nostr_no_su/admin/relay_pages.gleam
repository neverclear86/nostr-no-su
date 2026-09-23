//// 管理 UI のリレーのページ（追加、用途の編集、削除）の描画。フォームの中身はダッシュボードの
//// ダイアログと共用するので `admin/dashboard`（`new_relay_form`、`relay_action_form`）にあり、
//// ここはそれを要約、入力の誤り、削除のページへのリンクと一緒にページの枠に入れる。
//// `admin/account_pages` と同じく `admin/dashboard` と `admin/view` の部品で HTML 文字列に
//// するだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値（URL）はテキストか属性値として lustre に渡し、エスケープを文字列化に任せる
//// （`admin/view` の規則に従う）。文言は `admin/i18n` から表示の言語で引き、文字列
//// リテラルで書かない（同じく `admin/view` の規則）。

import gleam/list
import gleam/option.{type Option, Some}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view
import nostr_no_su/relay_list.{type Roles}
import nostr_no_su/relay_store.{type Relay}

/// リレーの追加のページ。GET では URL が空でバンカーだけにチェック、失敗して
/// 描き直すときは送られた URL とチェックを出す。
pub fn new_relay_page(
  language: Language,
  theme: view.Theme,
  url: String,
  roles: Roles,
  error: Option(i18n.Reason),
) -> String {
  let path = view.segments_path(dashboard.new_relay_segments)
  view.page(
    language,
    theme,
    i18n.AddRelay,
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.error_message(language, Some(i18n.CouldNotAddRelay), error),
      view.card(dashboard.new_relay_form(language, url, roles, view.InForm)),
      view.back_link(language),
    ],
  )
}

/// リレー 1 件への操作のページ。カードの上に URL を出す。用途の編集のチェックは、GET
/// では保存済みの用途を、描き直すときは送られた用途（`roles`）を出す。送信のボタンは
/// 編集が主、削除が危険。`states` はその用途の今の接続状態で、得られないときは
/// `None`。編集のページにだけ渡す。テーマか言語を切り替えた後は、この操作のページを
/// GET で開き直す。
pub fn relay_action_page(
  language: Language,
  theme: view.Theme,
  relay: Relay,
  action: dashboard.RelayAction,
  roles: Option(Roles),
  states: Option(dashboard.RelayRow),
  error: Option(i18n.Reason),
) -> String {
  let text = i18n.text(language, _)
  let path = dashboard.relay_action_path(relay.id, action)
  let lead = case action {
    dashboard.EditRelayRoles -> i18n.CouldNotSaveRelay
    dashboard.DeleteRelay -> i18n.CouldNotDeleteRelay
  }
  let delete_link = case action {
    dashboard.EditRelayRoles -> [
      html.div([], [
        view.icon_button_link(
          dashboard.relay_action_path(relay.id, dashboard.DeleteRelay),
          view.trash_icon(),
          text(i18n.Delete),
          view.DangerGhostButton,
        ),
      ]),
    ]
    dashboard.DeleteRelay -> []
  }
  view.page(
    language,
    theme,
    dashboard.relay_action_title(action),
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.card([
        view.summary_list([#(text(i18n.RelayUrl), view.Code(relay.url))]),
        view.error_message(language, Some(lead), error),
        ..list.append(
          dashboard.relay_action_form(
            language,
            relay,
            action,
            roles,
            states,
            view.InForm,
          ),
          delete_link,
        )
      ]),
      view.back_link(language),
    ],
  )
}
