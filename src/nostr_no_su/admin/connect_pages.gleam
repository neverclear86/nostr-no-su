//// 管理 UI のクライアントの接続のページ（`/sessions/connect`）と、その確認のページの描画。接続のページの
//// カードの中身（登録への案内、理由の囲み、フォーム）はダッシュボードのダイアログと共用するので
//// `admin/dashboard`（`connect_content`）にあり、ここはそれを入力の誤りと一緒にページの枠に入れる。確認の
//// ページは URI を解釈した内容を並べ、`/sessions/connect/confirm` へ送り直すフォームを出す。
//// `admin/relay_pages` と同じく `admin/dashboard` と `admin/view` の部品で HTML 文字列にするだけで、
//// プロセスにも IO にも触れない。
////
//// 埋め込む値（URI、署名者、クライアントの名乗る名前と公開鍵、権限、URI のリレー）は `admin/dashboard` がテキストか属性値として lustre に渡し、エスケープを
//// 文字列化に任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から表示の言語で引き、文字列
//// リテラルで書かない（同じく `admin/view` の規則）。

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/permission_view
import nostr_no_su/admin/view

/// 確認のページに出す接続の内容。`uri` と `signer` は 1 段目で送られた値で、確認のページの隠し欄で
/// 送り直す。`client_name` は表示のために整えた名前（無ければ `None`）。`relays` は URI に現れた順。
pub type ConnectReview {
  ConnectReview(
    uri: String,
    signer: String,
    client: String,
    client_name: Option(String),
    perms: String,
    relays: List(String),
  )
}

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
      view.card(dashboard.connect_content(
        language,
        accounts,
        uri,
        signer,
        view.InForm,
      )),
      view.back_link(language),
    ],
  )
}

/// クライアントの接続の確認のページ。URI を解釈した内容（クライアント、署名者、権限、URI のリレー）と
/// 接続の意味の説明を出し、「接続する」で `/sessions/connect/confirm` へ送る。接続の段で失敗して
/// 描き直すときは、カードの先頭に理由を出す。GET で開き直せず、切り替えると貼った URI を失うので、
/// テーマと言語の切り替えを出さない。
pub fn connect_review_page(
  language: Language,
  theme: view.Theme,
  accounts: List(dashboard.AccountRow),
  review: ConnectReview,
  error: Option(i18n.Reason),
) -> String {
  let text = i18n.text(language, _)
  view.page(
    language,
    theme,
    i18n.ConfirmConnection,
    view.Narrow,
    view.NoSwitch,
    view.NoRefresh,
    [
      view.card([
        view.error_message(language, Some(i18n.CouldNotStartConnection), error),
        view.form_description(text(i18n.ConnectConfirmDescription)),
        review_list(language, accounts, review),
        connect_explanation(language, review.perms),
        view.post_form(
          view.segments_path(dashboard.connect_confirm_segments),
          [
            view.hidden_input(dashboard.nostrconnect_uri_field, review.uri),
            view.hidden_input(dashboard.signer_field, review.signer),
          ],
          text(i18n.Connect),
          view.PrimaryButton,
          view.InForm,
        ),
        view.hint(
          text(i18n.ConnectWaitHint(
            seconds: dashboard.nostrconnect_wait_seconds,
          )),
        ),
        html.div([], [
          view.button_link(
            view.segments_path(dashboard.connect_segments),
            text(i18n.PasteAnotherUri),
            view.GhostButton,
          ),
        ]),
      ]),
      view.back_link(language),
    ],
  )
}

/// 確認のページの一覧。名乗る名前（無ければ行ごと省く）、クライアント、署名者、権限、URI の
/// リレーの順に並べる。
fn review_list(
  language: Language,
  accounts: List(dashboard.AccountRow),
  review: ConnectReview,
) -> Element(msg) {
  let text = i18n.text(language, _)
  let name_entry = case review.client_name {
    Some(name) -> [#(text(i18n.ClientName), view.value_cell(view.Plain(name)))]
    None -> []
  }
  view.detail_list(
    list.append(name_entry, [
      #(
        text(i18n.Client),
        view.identifier_cell(language, review.client, text(i18n.CopyClient)),
      ),
      #(
        text(i18n.Signer),
        html.dd([], [
          dashboard.signer_value(dashboard.signer_name(
            Ok(accounts),
            review.signer,
          )),
        ]),
      ),
      #(
        text(i18n.Permissions),
        html.dd([], [permission_view.chips(language, review.perms)]),
      ),
      #(text(i18n.UriRelays), html.dd([], [view.code_list(review.relays)])),
    ]),
  )
}

/// 接続の意味の説明。権限が空のときは、許す操作の一文を続ける。URI のリレーに届く
/// 情報を末尾に書く。
fn connect_explanation(language: Language, perms: String) -> Element(msg) {
  let text = i18n.text(language, _)
  let permissions = case perms {
    "" -> [i18n.NoPermissionsRequested]
    _ -> []
  }
  let sentences =
    [i18n.ConnectExplanation, ..permissions]
    |> list.append([i18n.ConnectRelaysScope])
    |> list.map(text)
  view.alert(view.Info, [
    html.text(string.join(sentences, i18n.sentence_gap(language))),
  ])
}
