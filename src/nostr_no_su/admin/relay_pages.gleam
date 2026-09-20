//// 管理 UI のリレーのページ（追加、用途の編集、削除）の描画。`admin/account_pages` と
//// 同じく `admin/dashboard` のパスの定義と `admin/view` の部品で HTML 文字列にする
//// だけで、プロセスにも IO にも触れない。
////
//// 埋め込む値（URL）はテキストか属性値として lustre に渡し、エスケープを文字列化に任せる
//// （`admin/view` の規則に従う）。文言は `admin/i18n` から表示の言語で引き、文字列
//// リテラルで書かない（同じく `admin/view` の規則）。

import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view
import nostr_no_su/relay_list.{type Roles}
import nostr_no_su/relay_store.{type Relay}

/// URL の案内の `id`。URL の欄は追加のページに 1 つだけなので固定の値にする。
const relay_url_hint_id = "relay-url-hint"

/// リレーの追加のページ。GET では URL が空で両方にチェック、失敗して描き直すときは
/// 送られた URL とチェックを出す。
pub fn new_relay_page(
  language: Language,
  theme: view.Theme,
  url: String,
  roles: Roles,
  error: Option(i18n.Reason),
) -> String {
  let text = i18n.text(language, _)
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
      view.card([
        view.form_description(text(i18n.AddRelayDescription)),
        view.post_form(
          path,
          [url_field(language, url), roles_fieldset(language, roles, None)],
          text(i18n.Register),
          view.Primary,
          view.InForm,
        ),
      ]),
      view.back_link(language),
    ],
  )
}

/// リレー 1 件への操作のページ。カードの上に URL を出す。用途の編集のチェックは、GET
/// では保存済みの用途を、描き直すときは送られた用途（`roles`）を出す。送信のボタンは
/// 編集が主操作、削除が破壊。`states` はその用途の今の接続状態で、得られないときは
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
  let #(lead, description, form) = case action {
    dashboard.EditRelayRoles -> #(
      i18n.CouldNotSaveRelay,
      html.p([], [html.text(text(i18n.EditRelayRolesDescription))]),
      view.post_form(
        path,
        [roles_fieldset(language, option.unwrap(roles, relay.roles), states)],
        text(i18n.Save),
        view.Primary,
        view.InForm,
      ),
    )
    dashboard.DeleteRelay -> #(
      i18n.CouldNotDeleteRelay,
      html.p([], [html.text(text(i18n.DeleteRelayDescription))]),
      view.post_form(
        path,
        [],
        text(i18n.DeleteRelaySubmit),
        view.Destructive,
        view.InForm,
      ),
    )
  }
  let delete_link = case action {
    dashboard.EditRelayRoles -> [
      view.icon_button_link(
        dashboard.relay_action_path(relay.id, dashboard.DeleteRelay),
        view.trash_icon(),
        text(i18n.Delete),
        view.Destructive,
      ),
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
        description,
        form,
        ..delete_link
      ]),
      view.back_link(language),
    ],
  )
}

/// リレーの URL の欄。
fn url_field(language: Language, url: String) -> Element(msg) {
  let text = i18n.text(language, _)
  view.hinted_input(
    text(i18n.RelayUrl),
    relay_url_hint_id,
    text(i18n.RelayUrlHint),
    [
      attribute.type_("text"),
      attribute.name(dashboard.relay_url_field),
      attribute.required(True),
      attribute.autocomplete("off"),
      attribute.spellcheck(False),
      attribute.inputmode("url"),
      attribute.default_value(url),
      attribute.class("input w-full font-mono border-base-content/60"),
    ],
  )
}

/// 用途（監視・バンカー）のチェックの囲み。`states` はその用途の今の接続状態で、`None`
/// ならバッジを出さない。
fn roles_fieldset(
  language: Language,
  roles: Roles,
  states: Option(dashboard.RelayRow),
) -> Element(msg) {
  let text = i18n.text(language, _)
  html.fieldset([attribute.class("fieldset")], [
    html.legend([attribute.class("fieldset-legend")], [
      html.text(text(i18n.Role)),
    ]),
    role_row(
      language,
      dashboard.monitor_field,
      view.eye_icon(),
      text(i18n.UseForMonitoring),
      text(i18n.MonitorRoleDescription),
      roles.monitor,
      option.map(states, fn(row) { row.monitor }),
    ),
    role_row(
      language,
      dashboard.bunker_field,
      view.key_icon(),
      text(i18n.UseForBunker),
      text(i18n.BunkerRoleDescription),
      roles.bunker,
      option.map(states, fn(row) { row.bunker }),
    ),
  ])
}

/// 用途 1 つぶんの大きなチェック。チェック、アイコン、語、説明、あれば接続状態のバッジを
/// 1 行に並べる。
fn role_row(
  language: Language,
  name: String,
  icon: Element(msg),
  caption: String,
  description: String,
  checked: Bool,
  state: Option(dashboard.RoleState),
) -> Element(msg) {
  let badge = case state {
    Some(state) -> [dashboard.role_state_badge(language, state)]
    None -> []
  }
  html.label([attribute.class("flex items-center gap-3 text-sm")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.name(name),
      attribute.value("on"),
      attribute.class("checkbox border-base-content/60"),
      attribute.checked(checked),
    ]),
    icon,
    html.div([attribute.class("flex min-w-0 flex-col")], [
      html.span([], [html.text(caption)]),
      html.span([attribute.class("text-sm text-base-content/70")], [
        html.text(description),
      ]),
    ]),
    ..badge
  ])
}
