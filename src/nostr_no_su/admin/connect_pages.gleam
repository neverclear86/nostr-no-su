//// 管理 UI のクライアントの接続のページ（`/sessions/connect`）の描画。`admin/relay_pages` と
//// 同じく `admin/dashboard` のパスの定義と `admin/view` の部品で HTML 文字列にする
//// だけで、プロセスにも IO にも触れない。
////
//// 埋め込む値（URI、署名者）はテキストか属性値として lustre に渡し、エスケープを文字列化に
//// 任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から表示の言語で引き、文字列
//// リテラルで書かない（同じく `admin/view` の規則）。

import gleam/list
import gleam/option.{type Option, Some}
import lustre/attribute
import lustre/element.{type Element}
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view

/// URI の補足の `id`。URI の欄はこのページに 1 つだけなので固定の値にする。
const nostrconnect_uri_hint_id = "nostrconnect-uri-hint"

/// クライアントの接続のページ。アカウントの一覧を得られたときだけフォームを出し、
/// 0 件なら登録への案内、得られなければ理由の囲みをカードの中に出す。失敗して描き直す
/// ときは、送られた URI と選ばれた署名者を戻す。
pub fn connect_client_page(
  language: Language,
  theme: view.Theme,
  accounts: Result(List(dashboard.AccountRow), i18n.Reason),
  uri: String,
  signer: String,
  error: Option(i18n.Reason),
) -> String {
  let path = view.segments_path(dashboard.connect_segments)
  view.page(
    language,
    theme,
    i18n.ConnectClient,
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.error_message(language, Some(i18n.CouldNotStartConnection), error),
      view.card(card_body(language, path, accounts, uri, signer)),
      view.back_link(language),
    ],
  )
}

/// カードの中身。アカウントの一覧が空なら登録への案内、得られなければ理由の囲みを、
/// 得られればフォームを出す。
fn card_body(
  language: Language,
  path: String,
  accounts: Result(List(dashboard.AccountRow), i18n.Reason),
  uri: String,
  signer: String,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  case accounts {
    Ok([]) -> [
      view.hint(text(i18n.NoAccountsForConnect)),
      view.button_link(
        view.segments_path(dashboard.new_account_segments),
        text(i18n.AddAccount),
        view.PrimaryButton,
      ),
    ]
    Ok(rows) -> [
      view.form_description(text(i18n.ConnectClientDescription)),
      view.post_form(
        path,
        [uri_field(language, uri), signer_field(language, rows, signer)],
        text(i18n.Connect),
        view.PrimaryButton,
        view.InForm,
      ),
    ]
    Error(reason) -> [
      view.alert(
        view.Neutral,
        view.reason_content(language, Some(i18n.CouldNotListAccounts), reason),
      ),
    ]
  }
}

/// URI の欄。
fn uri_field(language: Language, uri: String) -> Element(msg) {
  let text = i18n.text(language, _)
  view.hinted_textarea(
    language,
    text(i18n.NostrconnectUri),
    nostrconnect_uri_hint_id,
    view.LineHint(text(i18n.NostrconnectUriHint)),
    uri,
    [
      attribute.name(dashboard.nostrconnect_uri_field),
      attribute.required(True),
      attribute.autocomplete("off"),
      attribute.spellcheck(False),
      attribute.autocapitalize("off"),
      attribute.rows(4),
      attribute.class(
        "textarea w-full font-mono text-xs border-base-content/60",
      ),
    ],
  )
}

/// 署名するアカウントの選択欄。`rows` の順に並べ、`selected` が空文字列なら先頭を
/// 選ぶ。表示はラベルと省略した npub を並べる。
fn signer_field(
  language: Language,
  rows: List(dashboard.AccountRow),
  selected: String,
) -> Element(msg) {
  let selected = case selected, list.first(rows) {
    "", Ok(first) -> first.signer
    _, _ -> selected
  }
  view.select_field(
    i18n.text(language, i18n.SigningAccount),
    dashboard.signer_field,
    list.map(rows, fn(row) {
      #(row.signer, row.label <> " " <> view.shorten(row.npub))
    }),
    selected,
  )
}
