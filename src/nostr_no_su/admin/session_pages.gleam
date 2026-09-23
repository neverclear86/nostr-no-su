//// 管理 UI のセッションの権限の編集ページ（`/sessions/<signer>/<client>/permissions`）の
//// 描画。`admin/relay_pages` と同じく `admin/dashboard` のパスの定義と、`admin/view` と
//// `admin/permission_view` の部品で HTML 文字列にするだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値（署名者・クライアントの公開鍵、権限のトークン）はテキストか属性値として
//// lustre に渡し、エスケープを文字列化に任せる（`admin/view` の規則に従う）。文言は
//// `admin/i18n` から表示の言語で引き、文字列リテラルで書かない（同じく `admin/view` の
//// 規則）。

import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/permission_view
import nostr_no_su/admin/view

/// kind の補足の `id`。kind の欄はこのページに 1 つだけなので固定の値にする。
const kinds_hint_id = "session-permissions-kinds-hint"

/// 権限の編集フォームの欄の状態。`kinds` と `other` は欄に出す文字列そのままで、
/// 検証していない値も持つ。
pub type PermissionsForm {
  PermissionsForm(
    sign_event: Bool,
    nip44_encrypt: Bool,
    nip44_decrypt: Bool,
    kinds: String,
    other: String,
  )
}

/// `perms` を 3 つのチェック、kind の一覧、そのほかの宣言に分けたもの。
/// `form_of_perms` の途中の形で、最後に `PermissionsForm` へまとめる。
type ParsedPerms {
  ParsedPerms(
    sign_event: Bool,
    nip44_encrypt: Bool,
    nip44_decrypt: Bool,
    kinds: List(String),
    other: List(String),
  )
}

/// セッションの権限の編集ページ。`session` を得られなければ理由の囲みだけを出して
/// フォームを出さない。`form` は描き直すときに送られた欄の状態で、`None` なら
/// `session` の保存済みの値（`form_of_perms(session.perms)`）を使う。
pub fn session_permissions_page(
  language: Language,
  theme: view.Theme,
  session: Result(dashboard.SessionRow, i18n.Reason),
  form: Option(PermissionsForm),
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
      view.card(card_body(language, path, session, form, error)),
      view.back_link(language),
    ],
  )
}

/// カードの中身。`session` を得られなければ理由の囲み 1 つ、得られれば要約とフォームを
/// 出す。
fn card_body(
  language: Language,
  path: String,
  session: Result(dashboard.SessionRow, i18n.Reason),
  form: Option(PermissionsForm),
  error: Option(i18n.Reason),
) -> List(Element(msg)) {
  case session {
    Error(reason) -> [
      view.alert(
        view.Neutral,
        view.reason_content(language, Some(i18n.CouldNotListSessions), reason),
      ),
    ]
    Ok(row) -> {
      let fields = option.unwrap(form, form_of_perms(row.perms))
      [
        summary(language, row),
        view.error_message(language, Some(i18n.CouldNotSavePermissions), error),
        view.form_description(i18n.text(
          language,
          i18n.EditPermissionsDescription,
        )),
        view.post_form(
          path,
          form_fields(language, fields),
          i18n.text(language, i18n.Save),
          view.PrimaryButton,
          view.InForm,
        ),
      ]
    }
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

/// フォームの欄。3 つのチェック、kind の欄、あればそのほかの宣言のチップと隠し欄。
fn form_fields(
  language: Language,
  fields: PermissionsForm,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    html.fieldset([attribute.class("fieldset")], [
      view.checkbox_row(
        dashboard.sign_event_field,
        view.pencil_icon(),
        text(i18n.AllowSignEvent),
        view.untranslated(dashboard.sign_event_field),
        fields.sign_event,
        [],
      ),
      html.p([attribute.class("text-sm text-muted")], [
        html.text(text(i18n.SignEventAlwaysRefused)),
      ]),
      view.checkbox_row(
        dashboard.nip44_encrypt_field,
        view.key_icon(),
        text(i18n.AllowNip44Encrypt),
        view.untranslated(dashboard.nip44_encrypt_field),
        fields.nip44_encrypt,
        [],
      ),
      view.checkbox_row(
        dashboard.nip44_decrypt_field,
        view.key_icon(),
        text(i18n.AllowNip44Decrypt),
        view.untranslated(dashboard.nip44_decrypt_field),
        fields.nip44_decrypt,
        [],
      ),
    ]),
    view.hinted_input(
      language,
      text(i18n.AllowedKinds),
      kinds_hint_id,
      view.LineHint(text(i18n.AllowedKindsHint)),
      [
        attribute.name(dashboard.perms_kinds_field),
        attribute.inputmode("numeric"),
        attribute.default_value(fields.kinds),
        attribute.class("input w-full font-mono border-base-content/60"),
        attribute.maxlength(512),
      ],
    ),
    ..other_declarations(language, fields.other)
  ]
}

/// 「そのほかの宣言」がある場合だけ、読み取り専用のチップと案内、送信のための隠し欄を
/// 出す。無ければ何も出さない。
fn other_declarations(language: Language, other: String) -> List(Element(msg)) {
  case other {
    "" -> []
    _ -> [
      html.div([attribute.class("flex flex-col gap-1")], [
        html.span([], [html.text(i18n.text(language, i18n.OtherPermissions))]),
        permission_view.chips(language, other),
        html.p([attribute.class("text-sm text-muted")], [
          html.text(i18n.text(language, i18n.OtherPermissionsHint)),
        ]),
      ]),
      view.hidden_input(dashboard.perms_other_field, other),
    ]
  }
}

/// 保存済みの `perms` を欄の状態に写す。3 つの語はチェック、`sign_event:<n>` は
/// kind の欄、それ以外は「そのほかの宣言」に落とし、空の `perms` は 3 つのチェック
/// を入れる。
fn form_of_perms(perms: String) -> PermissionsForm {
  let parsed = case perms {
    "" ->
      ParsedPerms(
        sign_event: True,
        nip44_encrypt: True,
        nip44_decrypt: True,
        kinds: [],
        other: [],
      )
    _ ->
      string.split(perms, ",")
      |> list.fold(
        ParsedPerms(
          sign_event: False,
          nip44_encrypt: False,
          nip44_decrypt: False,
          kinds: [],
          other: [],
        ),
        fold_token,
      )
      |> reverse_lists
  }
  PermissionsForm(
    sign_event: parsed.sign_event,
    nip44_encrypt: parsed.nip44_encrypt,
    nip44_decrypt: parsed.nip44_decrypt,
    kinds: string.join(parsed.kinds, ","),
    other: string.join(parsed.other, ","),
  )
}

/// `form_of_perms` の 1 トークンぶんの畳み込み。
fn fold_token(acc: ParsedPerms, token: String) -> ParsedPerms {
  case token {
    "sign_event" -> ParsedPerms(..acc, sign_event: True)
    "nip44_encrypt" -> ParsedPerms(..acc, nip44_encrypt: True)
    "nip44_decrypt" -> ParsedPerms(..acc, nip44_decrypt: True)
    _ ->
      case permission_view.signed_kind(token) {
        Ok(kind) ->
          ParsedPerms(..acc, kinds: [int.to_string(kind), ..acc.kinds])
        Error(Nil) -> ParsedPerms(..acc, other: [token, ..acc.other])
      }
  }
}

/// `fold_token` が先頭に積んだ `kinds` と `other` を入力の順に戻す。
fn reverse_lists(parsed: ParsedPerms) -> ParsedPerms {
  ParsedPerms(
    ..parsed,
    kinds: list.reverse(parsed.kinds),
    other: list.reverse(parsed.other),
  )
}
