//// 管理 UI のアカウントのページ（登録画面、生成した鍵の確認、登録の完了、操作、
//// 秘密鍵の表示）の描画。`admin/dashboard` の型とパスの定義を `admin/view` の部品で
//// HTML 文字列にするだけで、プロセスにも IO にも触れない。
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
  view.page("Add account", [
    view.heading("Add account"),
    view.error_message(error),
    html.h3([], [html.text("Import a private key")]),
    html.p([], [
      html.text(
        "Paste the private key (nsec) of the account. It is shown once after "
        <> "registration, and afterwards only when you re-enter the admin "
        <> "password.",
      ),
    ]),
    view.post_form(
      dashboard.segments_path(dashboard.import_account_segments),
      [
        view.labelled("Private key (nsec)", [
          view.secret_input(dashboard.nsec_field),
        ]),
        view.labelled("Label", [
          label_input("", Some(dashboard.max_label_code_points)),
        ]),
      ],
      "Register",
    ),
    html.h3([], [html.text("Generate a new key")]),
    html.p([], [
      html.text(
        "Generate a new private key on the server. It is shown for backup "
        <> "before it is registered.",
      ),
    ]),
    view.post_form(
      dashboard.segments_path(dashboard.generate_account_segments),
      [],
      "Generate",
    ),
    html.p([], [html.text(skipped_row_note)]),
    view.back_link(),
  ])
}

/// 生成した鍵の確認ページ。生成した nsec を表示する唯一のページで、ここではまだ
/// 登録しない。登録のフォームは nsec を隠しフィールドで送り返す。`error` は、生成した鍵の
/// 登録でラベルが規則に反したときに再描画する理由。
pub fn generated_key_page(nsec: String, error: Option(String)) -> String {
  view.page("Generated key", [
    view.heading("Generated key"),
    view.error_message(error),
    html.p([], [
      html.strong([], [html.text("Back up this private key now.")]),
      html.text(
        " The account is not "
        <> "registered until you press \"Register this key\". After "
        <> "registration, the key is shown only when you re-enter the admin "
        <> "password.",
      ),
    ]),
    view.labelled("Private key (nsec)", view.copyable_field(nsec)),
    view.post_form(
      dashboard.segments_path(dashboard.register_generated_segments),
      [
        view.hidden_input(dashboard.nsec_field, nsec),
        view.labelled("Label", [
          label_input("", Some(dashboard.max_label_code_points)),
        ]),
      ],
      "Register this key",
    ),
    view.back_link(),
  ])
}

/// nsec の入力による登録の完了ページ。入力された鍵の nsec をここで 1 回だけ表示する。
/// 接続 URI はダッシュボードで取得する。
pub fn registered_page(npub: String, label: String, nsec: String) -> String {
  view.page("Account registered", [
    view.heading("Account registered"),
    view.table(["Label", "Account"], [[[html.text(label)], [view.code(npub)]]]),
    html.p([], [
      html.strong([], [
        html.text("Back up this private key if you have not already."),
      ]),
      html.text(
        " It is shown again only when you re-enter the admin password. The "
        <> "connection URI is on the dashboard.",
      ),
    ]),
    view.labelled("Private key (nsec)", view.copyable_field(nsec)),
    view.back_link(),
  ])
}

/// アカウント 1 件への操作のページ。操作の説明と、操作を実行する 1 つのフォーム。
/// ラベルの編集フォームには、利用者の入力ではなく一覧から得た保存済みのラベルを入れる。
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
        [view.labelled("Label", [label_input(row.label, None)])],
        "Save",
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
      view.post_form(path, [], title),
    )
    dashboard.DeleteAccount -> #(
      html.p([], [
        html.text(
          "The private key is deleted from the bunker and from the database. ",
        ),
        html.strong([], [
          html.text(
            "If you have not saved this key anywhere else, the account "
            <> "is lost.",
          ),
        ]),
        html.text(
          " Its sessions and pending connections are removed " <> "as well.",
        ),
      ]),
      view.post_form(path, [], title),
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
          view.labelled("Admin password", [
            view.secret_input(dashboard.password_field),
          ]),
        ],
        title,
      ),
    )
  }
  view.page(title, [
    view.heading(title),
    account_summary(row),
    view.error_message(error),
    description,
    form,
    view.back_link(),
  ])
}

/// 管理パスワードを再入力した後の秘密鍵の表示ページ。
pub fn private_key_page(row: dashboard.AccountRow, nsec: String) -> String {
  view.page("Private key", [
    view.heading("Private key"),
    account_summary(row),
    view.labelled("Private key (nsec)", view.copyable_field(nsec)),
    html.p([], [
      html.strong([], [html.text("Close this tab after copying the key.")]),
      html.text(
        " Reloading this "
        <> "page or coming back to it with the back button can resend the form, "
        <> "which shows the key again and logs it again.",
      ),
    ]),
    view.back_link(),
  ])
}

/// 操作の対象のアカウントを示す表。
fn account_summary(row: dashboard.AccountRow) -> Element(msg) {
  view.table(["Label", "Account"], [
    [[html.text(row.label)], dashboard.account_cell(row)],
  ])
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
    ..limit
  ])
}
