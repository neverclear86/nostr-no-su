//// 管理 UI のクライアントの接続のページ（`/sessions/connect`）の描画。カードの中身（登録への案内、
//// 理由の囲み、フォーム）はダッシュボードのダイアログと共用するので `admin/dashboard`（`connect_content`）
//// にあり、ここはそれを入力の誤りと一緒にページの枠に入れる。`admin/relay_pages` と同じく
//// `admin/dashboard` と `admin/view` の部品で HTML 文字列にするだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値（URI、署名者）は `admin/dashboard` がテキストか属性値として lustre に渡し、エスケープを
//// 文字列化に任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から表示の言語で引き、文字列
//// リテラルで書かない（同じく `admin/view` の規則）。

import gleam/option.{type Option, Some}
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view

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
      view.card(dashboard.connect_content(language, accounts, uri, signer)),
      view.back_link(language),
    ],
  )
}
