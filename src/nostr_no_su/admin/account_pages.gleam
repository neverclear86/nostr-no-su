//// 管理 UI のアカウントのページ（登録画面、生成した鍵の確認、登録の完了、操作、
//// 秘密鍵の表示）の描画。`admin/dashboard` の型とパスの定義を `admin/view` の部品で
//// HTML 文字列にするだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値（ラベル、表示する理由、nsec）はテキストか属性値として lustre に渡し、
//// エスケープを文字列化に任せる（`admin/view` の規則に従う）。
////
//// 秘密鍵（nsec）を描画するのは `generated_key_page`、`registered_page`、
//// `private_key_page` の 3 つだけである。

import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/view

/// 別のマスターキーで暗号化された行についての案内。どの登録のページにも常に出す。
const skipped_row_note = "If registration reports \"account is already registered\" for an account that is not on the dashboard, a row encrypted with a different master key is left in the database; see the README for how to remove it."

/// アカウントの登録画面。nsec の入力による登録と、サーバー側での鍵の生成のフォーム。
pub fn new_account_page(error: Option(String)) -> String {
  view.page("Add account", view.Narrow, [
    view.error_message(error),
    view.card([
      view.heading("Import a private key"),
      form_description(
        "Paste the private key (nsec) of the account. It is shown once after "
        <> "registration, and afterwards only when you re-enter the admin "
        <> "password.",
      ),
      view.post_form(
        dashboard.segments_path(dashboard.import_account_segments),
        [
          view.labelled(
            "Private key (nsec)",
            view.secret_input(dashboard.nsec_field),
          ),
          view.labelled(
            "Label",
            label_input("", Some(dashboard.max_label_code_points)),
          ),
        ],
        "Register",
        view.Primary,
        view.InForm,
      ),
    ]),
    view.card([
      view.heading("Generate a new key"),
      form_description(
        "Generate a new private key on the server. It is shown for backup "
        <> "before it is registered.",
      ),
      view.post_form(
        dashboard.segments_path(dashboard.generate_account_segments),
        [],
        "Generate",
        view.Primary,
        view.InForm,
      ),
    ]),
    view.hint(skipped_row_note),
    view.back_link(),
  ])
}

/// 生成した鍵の確認ページ。生成した nsec を表示する唯一のページで、ここではまだ
/// 登録しない。登録のフォームは nsec を隠しフィールドで送り返す。`error` は、生成した鍵の
/// 登録でラベルが規則に反したときに再描画する理由。
pub fn generated_key_page(nsec: String, error: Option(String)) -> String {
  view.page("Generated key", view.Narrow, [
    view.error_message(error),
    view.card([
      view.warning([
        html.strong([], [html.text("Back up this private key now.")]),
        html.text(
          " The account is not registered until you press "
          <> "\"Register this key\". After registration, the key is shown "
          <> "only when you re-enter the admin password.",
        ),
      ]),
      view.copyable_field("Private key (nsec)", nsec),
      view.post_form(
        dashboard.segments_path(dashboard.register_generated_segments),
        [
          view.hidden_input(dashboard.nsec_field, nsec),
          view.labelled(
            "Label",
            label_input("", Some(dashboard.max_label_code_points)),
          ),
        ],
        "Register this key",
        view.Primary,
        view.InForm,
      ),
    ]),
    view.back_link(),
  ])
}

/// nsec の入力による登録の完了ページ。入力された鍵の nsec をここで 1 回だけ表示する。
/// 接続 URI はダッシュボードで取得する。
pub fn registered_page(npub: String, label: String, nsec: String) -> String {
  view.page("Account registered", view.Narrow, [
    view.card([
      view.summary_list([
        #("Label", view.Plain(label)),
        #("Account", view.Account(npub:, hex: None)),
      ]),
      view.warning([
        html.strong([], [
          html.text("Back up this private key if you have not already."),
        ]),
        html.text(
          " It is shown again only when you re-enter the admin password. The "
          <> "connection URI is on the dashboard.",
        ),
      ]),
      view.copyable_field("Private key (nsec)", nsec),
    ]),
    view.back_link(),
  ])
}

/// アカウント 1 件への操作のページ。操作の説明と、操作を実行する 1 つのフォーム。
/// ラベルの編集フォームには、利用者の入力ではなく一覧から得た保存済みのラベルを入れる。
/// 送信のボタンの重さは操作ごとに決める（ラベルの保存は主操作、secret の作り直しと
/// 秘密鍵の表示は注意、削除は破壊）。
pub fn account_action_page(
  row: dashboard.AccountRow,
  action: dashboard.AccountAction,
  error: Option(String),
) -> String {
  let title = dashboard.account_action_title(action)
  let path = dashboard.account_action_path(row.signer, action)
  let #(description, form) = case action {
    dashboard.EditLabel -> #(
      element.none(),
      view.post_form(
        path,
        [view.labelled("Label", label_input(row.label, None))],
        "Save",
        view.Primary,
        view.InForm,
      ),
    )
    dashboard.RotateSecret -> #(
      html.p([], [
        html.text(
          "A new connection secret is generated. Clients that connect with the "
          <> "old connection URI are no longer accepted without approval, but "
          <> "sessions that are already approved remain. Paste the new "
          <> "connection URI from the dashboard into your clients.",
        ),
      ]),
      view.post_form(path, [], title, view.Caution, view.InForm),
    )
    dashboard.DeleteAccount -> #(
      html.p([], [
        html.text(
          "The private key is deleted from the bunker and from the database. ",
        ),
        html.strong([], [
          html.text(
            "If you have not saved this key anywhere else, the account is "
            <> "lost.",
          ),
        ]),
        html.text(" Its sessions and pending connections are removed as well."),
      ]),
      view.post_form(path, [], title, view.Destructive, view.InForm),
    )
    dashboard.RevealPrivateKey -> #(
      html.p([], [
        html.text(
          "Re-enter the admin password to show the private key. Showing it is "
          <> "logged with the npub.",
        ),
      ]),
      view.post_form(
        path,
        [
          view.labelled(
            "Admin password",
            view.secret_input(dashboard.password_field),
          ),
        ],
        title,
        view.Caution,
        view.InForm,
      ),
    )
  }
  view.page(title, view.Narrow, [
    view.card([
      account_summary(row),
      view.error_message(error),
      description,
      form,
    ]),
    view.back_link(),
  ])
}

/// 管理パスワードを再入力した後の秘密鍵の表示ページ。
pub fn private_key_page(row: dashboard.AccountRow, nsec: String) -> String {
  view.page("Private key", view.Narrow, [
    view.card([
      account_summary(row),
      view.copyable_field("Private key (nsec)", nsec),
      view.warning([
        html.strong([], [html.text("Close this tab after copying the key.")]),
        html.text(
          " Reloading this page or coming back to it with the back button "
          <> "can resend the form, which shows the key again and logs it "
          <> "again.",
        ),
      ]),
    ]),
    view.back_link(),
  ])
}

/// 操作の対象のアカウント（ラベルと、npub と 16 進の公開鍵）。
fn account_summary(row: dashboard.AccountRow) -> Element(msg) {
  view.summary_list([
    #("Label", view.Plain(row.label)),
    #("Account", view.Account(npub: row.npub, hex: Some(row.signer))),
  ])
}

/// カードの見出しの下に置く、フォームの説明。
fn form_description(text: String) -> Element(msg) {
  html.p([attribute.class("text-sm")], [html.text(text)])
}

/// ラベルの入力欄。`maxlength` は新しく入力する欄にだけ付ける。保存済みのラベルは
/// UTF-16 で上限を超えうるので、編集の欄に付けると 1 文字の編集で送信できなくなる。
fn label_input(value: String, maxlength: Option(Int)) -> Element(msg) {
  let limit = case maxlength {
    Some(limit) -> [attribute.maxlength(limit)]
    None -> []
  }
  html.input([
    attribute.type_("text"),
    attribute.name(dashboard.label_field),
    attribute.autocomplete("off"),
    attribute.default_value(value),
    attribute.class("input w-full border-base-content/60"),
    ..limit
  ])
}
