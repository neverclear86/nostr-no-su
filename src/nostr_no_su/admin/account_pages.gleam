//// 管理 UI のアカウントのページ（登録画面、生成した鍵の確認、登録の完了、操作、
//// 接続 QR コード、秘密鍵の表示）の描画。`admin/dashboard` の型とパスの定義を
//// `admin/view` の部品で HTML 文字列にするだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値（ラベル、表示する理由、nsec）はテキストか属性値として lustre に渡し、
//// エスケープを文字列化に任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から
//// 表示の言語で引き、文字列リテラルで書かない（同じく `admin/view` の規則）。
////
//// 秘密鍵（nsec）を描画するのは `generated_key_page`、`registered_page`、
//// `private_key_page` の 3 つだけである。この 3 つにはテーマと言語の切り替えを出さない
//// （`view.NoSwitch`）。

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/qr
import nostr_no_su/admin/view
import nostr_no_su/bunker/account

/// アカウントの登録画面。nsec の入力による登録と、サーバー側での鍵の生成のフォーム。
/// 失敗の理由を出した POST の応答でも、テーマか言語を切り替えた後はこの画面を GET で
/// 開き直す。`label` は欄に入れる値。GET では空、入力の誤りか 409 で戻したときは送られた値。
pub fn new_account_page(
  language: Language,
  theme: view.Theme,
  label: String,
  error: Option(i18n.Reason),
) -> String {
  let text = i18n.text(language, _)
  let path = view.segments_path(dashboard.new_account_segments)
  view.page(
    language,
    theme,
    i18n.AddAccount,
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.error_message(language, Some(i18n.CouldNotRegister), error),
      view.card([
        view.icon_heading(view.key_icon(), text(i18n.ImportPrivateKey)),
        view.form_description(text(i18n.ImportDescription)),
        view.secret_post_form(
          view.segments_path(dashboard.import_account_segments),
          [
            view.labelled(
              text(i18n.PrivateKeyNsec),
              view.secret_input(dashboard.nsec_field, "new-password"),
            ),
            label_fieldset(language, label),
          ],
          text(i18n.Register),
          view.Primary,
          view.InForm,
        ),
      ]),
      view.card([
        view.icon_heading(view.plus_icon(), text(i18n.GenerateNewKey)),
        view.form_description(text(i18n.GenerateDescription)),
        view.post_form(
          view.segments_path(dashboard.generate_account_segments),
          [],
          text(i18n.Generate),
          view.Normal,
          view.InForm,
        ),
      ]),
      view.hint(text(i18n.SkippedRowNote)),
      view.back_link(language),
    ],
  )
}

/// 生成した鍵の登録に失敗して確認ページを再描画する理由。
pub type GeneratedKeyProblem {
  /// ラベルが規則に反した（400）。
  InvalidLabel(i18n.Message)
  /// バンカーが登録を反映しなかった（409）。画面に出す理由を持つ（登録済みは訳した
  /// 文言、ストアの失敗は英語のまま届いた理由）。
  NotApplied(i18n.Reason)
  /// バンカーが今は登録を受け付けられない（503）。英語のまま届いた理由を持つ。
  NotAccepted(String)
  /// 登録が反映されたか分からない（202）。確かめられなかった原因の文言を持つ。
  NotConfirmed(i18n.Message)
}

/// 生成した鍵の確認ページ。生成した nsec を表示する唯一のページで、ここではまだ
/// 登録しない。登録のフォームは nsec を隠しフィールドで送り返す。`npub` は生成した鍵の
/// 公開鍵で、省略して出す。`label` は欄に入れる値（生成の直後は空、ラベルが規則に反する
/// かバンカーが登録に失敗して再描画するときは送られた値）。`problem` は再描画の理由。
pub fn generated_key_page(
  language: Language,
  theme: view.Theme,
  npub: String,
  nsec: String,
  label: String,
  problem: Option(GeneratedKeyProblem),
) -> String {
  let text = i18n.text(language, _)
  view.page(
    language,
    theme,
    i18n.GeneratedKey,
    view.Narrow,
    view.NoSwitch,
    view.NoRefresh,
    [
      option.map(problem, problem_alert(language, _))
        |> option.unwrap(element.none()),
      view.card([
        view.truncated_id(language, npub, text(i18n.CopyNpub)),
        view.warning(view.emphasized(
          language,
          i18n.BackUpNow,
          i18n.GeneratedKeyNotice,
        )),
        view.copyable_field(language, text(i18n.PrivateKeyNsec), nsec),
        view.post_form(
          view.segments_path(dashboard.register_generated_segments),
          [
            view.hidden_input(dashboard.nsec_field, nsec),
            label_fieldset(language, label),
          ],
          text(i18n.RegisterThisKey),
          view.Primary,
          view.InForm,
        ),
      ]),
      view.back_link(language),
    ],
  )
}

/// 確認ページのカードの上に出す、再描画の理由の囲み。
fn problem_alert(
  language: Language,
  problem: GeneratedKeyProblem,
) -> Element(msg) {
  case problem {
    InvalidLabel(reason) ->
      view.error_message(language, None, Some(i18n.Translated(reason)))
    NotApplied(reason) ->
      view.error_message(language, Some(i18n.CouldNotRegister), Some(reason))
    NotAccepted(reason) ->
      guided_warning(
        language,
        i18n.RegistrationNotAccepted,
        i18n.Untranslated(reason),
      )
    NotConfirmed(cause) ->
      guided_warning(
        language,
        i18n.RegistrationNotConfirmed,
        i18n.Translated(cause),
      )
  }
}

/// 次の操作の案内の文に理由を続けた、`Warning` の囲み。
fn guided_warning(
  language: Language,
  guide: i18n.Message,
  reason: i18n.Reason,
) -> Element(msg) {
  view.reason_alert(view.Warning, [
    html.text(i18n.text(language, guide) <> i18n.sentence_gap(language)),
    ..view.reason_content(language, None, reason)
  ])
}

/// nsec の入力による登録の完了ページ。入力された鍵の nsec をここで 1 回だけ表示する。
/// 接続 URI はダッシュボードで取得する。
pub fn registered_page(
  language: Language,
  theme: view.Theme,
  npub: String,
  label: String,
  nsec: String,
) -> String {
  let text = i18n.text(language, _)
  view.page(
    language,
    theme,
    i18n.AccountRegistered,
    view.Narrow,
    view.NoSwitch,
    view.NoRefresh,
    [
      view.card([
        view.identity(language, label, npub),
        view.warning(view.emphasized(
          language,
          i18n.BackUpIfNotAlready,
          i18n.RegisteredKeyNotice,
        )),
        view.copyable_field(language, text(i18n.PrivateKeyNsec), nsec),
      ]),
      view.back_link(language),
    ],
  )
}

/// アカウント 1 件への操作のページ。操作の説明と、操作を実行する 1 つのフォーム。
/// ラベルの編集フォームの欄には、GET では一覧から得た保存済みのラベルを、入力の誤りか
/// 409 で再描画するときは送られた値（`label`）を入れる。カードの上の `account_summary`
/// は保存済みのラベルのままにする。送信のボタンの重さは操作ごとに決める（ラベルの保存は
/// 主操作、secret の作り直しと秘密鍵の表示は注意、削除は破壊）。送信のボタンの文言は、
/// 見出しとリンクの文言（`dashboard.account_action_title`）とは別に持つ。テーマか言語を
/// 切り替えた後は、この操作のページを GET で開き直す。
pub fn account_action_page(
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
  action: dashboard.AccountAction,
  label: Option(String),
  error: Option(i18n.Reason),
) -> String {
  let text = i18n.text(language, _)
  let path = dashboard.account_action_path(row.signer, action)
  let #(description, form) = case action {
    dashboard.EditLabel -> #(
      element.none(),
      view.post_form(
        path,
        [label_fieldset(language, option.unwrap(label, row.label))],
        text(i18n.Save),
        view.Primary,
        view.InForm,
      ),
    )
    dashboard.RotateSecret -> #(
      html.p([], [html.text(text(i18n.RotateSecretDescription))]),
      view.post_form(
        path,
        [],
        text(i18n.RotateSecretSubmit),
        view.Caution,
        view.InForm,
      ),
    )
    dashboard.DeleteAccount -> {
      let gap = i18n.sentence_gap(language)
      #(
        html.p([], [
          html.text(text(i18n.DeleteDescription) <> gap),
          html.strong([], [html.text(text(i18n.DeleteWarning))]),
          html.text(gap <> text(i18n.DeleteAlsoRemoves)),
        ]),
        view.post_form(
          path,
          [],
          text(i18n.DeleteAccountSubmit),
          view.Destructive,
          view.InForm,
        ),
      )
    }
    dashboard.RevealPrivateKey -> #(
      html.p([], [html.text(text(i18n.ShowPrivateKeyDescription))]),
      view.post_form(
        path,
        [
          view.labelled(
            text(i18n.AdminPassword),
            view.secret_input(dashboard.password_field, "off"),
          ),
        ],
        text(i18n.ShowPrivateKeySubmit),
        view.Caution,
        view.InForm,
      ),
    )
    dashboard.ShowConnectionQr -> #(element.none(), element.none())
  }
  view.page(
    language,
    theme,
    dashboard.account_action_title(action),
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.card([
        account_summary(language, row),
        view.error_message(language, action_lead(action), error),
        description,
        form,
      ]),
      view.back_link(language),
    ],
  )
}

/// 接続 URI をスマートフォンへ渡すための QR コードのページ。secret 入りの URI と要承認の
/// URI を 1 枚ずつのカードに出す。各カードは、端末のカメラがテキストとして扱う形
/// （`bunker://` を外し `relay=` のドットを `%2E` にした形）の QR と貼り方の案内を既定に
/// 置き、クライアントの読み取り機能が読む完全な `bunker://` の QR を畳みに入れる。続けて、
/// この URI が使うバンカーのリレーの URL と、クライアント側の `nostrconnect://` で接続する
/// 経路への案内を出す。バンカーに使うリレーが無ければ警告を先に出す。符号化できない URI は
/// その位置に理由を出し、コピー欄は残す。
pub fn connection_qr_page(
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
  relays: Result(List(dashboard.RelayRow), i18n.Reason),
) -> String {
  let text = i18n.text(language, _)
  let path =
    dashboard.account_action_path(row.signer, dashboard.ShowConnectionQr)
  view.page(
    language,
    theme,
    i18n.ConnectionQr,
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.card([
        account_summary(language, row),
        html.p([], [html.text(text(i18n.ConnectionQrDescription))]),
      ]),
      dashboard.no_bunker_relay_warning(language, relays),
      uri_card(
        language,
        i18n.ConnectionUri,
        row.uri,
        view.warning([html.text(text(i18n.ConnectionQrSecretWarning))]),
      ),
      uri_card(
        language,
        i18n.ConnectionUriForApproval,
        row.auth_uri,
        approval_note(language),
      ),
      bunker_relay_card(language, relays),
      client_uri_card(language),
      view.back_link(language),
    ],
  )
}

/// 要承認のカードの `note`。この URI で接続したクライアントは承認待ちで承認するまで署名
/// できない旨を伝え、承認待ちの節へのリンクを添える。
fn approval_note(language: Language) -> Element(msg) {
  html.p([], [
    html.text(
      i18n.text(language, i18n.ApprovalUriNeedsApproval)
      <> i18n.sentence_gap(language),
    ),
    html.a(
      [
        attribute.href("/#" <> dashboard.pending_anchor),
        attribute.class("link"),
      ],
      [html.text(i18n.text(language, i18n.PendingConnections))],
    ),
  ])
}

/// 接続 URI 1 件のカード。見出し、`note`、端末のカメラ用のコピー用 QR、貼り方の案内、
/// コピー欄、クライアントの読み取り機能が読む完全な `bunker://` の QR の畳みを並べる。
fn uri_card(
  language: Language,
  title: i18n.Message,
  uri: String,
  note: Element(msg),
) -> Element(msg) {
  let text = i18n.text(language, title)
  view.card([
    view.icon_heading(view.qr_code_icon(), text),
    note,
    qr_or_notice(language, text, account.camera_copy_text(uri)),
    html.p([], [html.text(i18n.text(language, i18n.CameraCopySteps))]),
    view.hint(i18n.text(language, i18n.CameraCopyNote)),
    view.copyable_field(language, text, uri),
    view.details_panel(i18n.text(language, i18n.ScanWithClientScanner), [
      qr_or_notice(
        language,
        text <> " / " <> i18n.text(language, i18n.ScanWithClientScanner),
        uri,
      ),
    ]),
  ])
}

/// この URI が使うバンカーのリレーの URL の一覧。`relays` が `Error` なら一覧の代わりに
/// 理由を出す。`Unused` でない `bunker` の用途を持つ行だけを出す。
fn bunker_relay_card(
  language: Language,
  relays: Result(List(dashboard.RelayRow), i18n.Reason),
) -> Element(msg) {
  let text = i18n.text(language, _)
  view.card([
    view.icon_heading(view.plug_icon(), text(i18n.BunkerRelaysForUri)),
    view.hint(text(i18n.BunkerRelaysHint)),
    case relays {
      Ok(rows) ->
        case list.filter(rows, fn(row) { row.bunker != dashboard.Unused }) {
          [] -> element.none()
          bunker_rows ->
            view.code_list(list.map(bunker_rows, fn(row) { row.url }))
        }
      Error(reason) ->
        view.alert(
          view.Neutral,
          view.reason_content(language, Some(i18n.CouldNotListRelays), reason),
        )
    },
  ])
}

/// クライアント側の `nostrconnect://` で接続する経路への案内。
fn client_uri_card(language: Language) -> Element(msg) {
  let text = i18n.text(language, _)
  view.card([
    view.icon_heading(view.plug_icon(), text(i18n.ConnectWithClientUri)),
    view.hint(text(i18n.ConnectWithClientUriHint)),
    view.button_link(
      view.segments_path(dashboard.connect_segments),
      text(i18n.ConnectClient),
      view.Primary,
    ),
  ])
}

/// QR コードに載せる文字列 1 つ。完全な `bunker://` URI と、カメラ用のコピー用の文字列のどちらも受ける。符号化できなければ理由を出す。
fn qr_or_notice(
  language: Language,
  label: String,
  text: String,
) -> Element(msg) {
  case qr.svg(label, text) {
    Ok(svg) -> svg
    Error(Nil) ->
      view.alert(view.Neutral, [
        html.text(i18n.text(language, i18n.CouldNotEncodeQr)),
      ])
  }
}

/// 読み込みで飛ばされた行の削除の確認ページ。`pubkey` 列を読めない行
/// （`MalformedPubkey`）はここには来ない（画面からは削除できない）。
pub fn unreadable_delete_page(
  language: Language,
  theme: view.Theme,
  row: dashboard.SkippedRow,
  error: Option(i18n.Reason),
) -> String {
  let text = i18n.text(language, _)
  let path = dashboard.account_action_path(row.pubkey, dashboard.DeleteAccount)
  let gap = i18n.sentence_gap(language)
  view.page(
    language,
    theme,
    dashboard.account_action_title(dashboard.DeleteAccount),
    view.Narrow,
    view.SwitchReturningTo(path),
    view.NoRefresh,
    [
      view.card([
        unreadable_summary(language, row),
        view.error_message(language, Some(i18n.CouldNotDeleteAccount), error),
        html.p([], [
          html.text(text(i18n.DeleteUnreadableDescription) <> gap),
          html.strong([], [html.text(text(i18n.DeleteUnreadableWarning))]),
          html.text(
            gap
            <> text(i18n.DeleteUnreadableRecover)
            <> gap
            <> text(i18n.DeleteAlsoRemoves),
          ),
        ]),
        view.post_form(
          path,
          [],
          text(i18n.DeleteAccountSubmit),
          view.Destructive,
          view.InForm,
        ),
      ]),
      view.back_link(language),
    ],
  )
}

/// 削除の対象の、読み込みで飛ばされた行（省略した npub と、飛ばした理由）。
fn unreadable_summary(
  language: Language,
  row: dashboard.SkippedRow,
) -> Element(msg) {
  let text = i18n.text(language, _)
  html.div([attribute.class("flex flex-col gap-3")], [
    view.identity(language, row.label, row.npub),
    view.summary_list([
      #(
        text(i18n.ReasonLabel),
        view.Plain(text(i18n.UnreadableReason(row.reason))),
      ),
    ]),
  ])
}

/// 操作のページで、バンカーから英語のまま届いた理由の前に置く前置き。秘密鍵の表示の
/// フォームに出る理由は管理パスワードの誤り（訳す理由）だけなので、前置きを持たない。
fn action_lead(action: dashboard.AccountAction) -> Option(i18n.Lead) {
  case action {
    dashboard.EditLabel -> Some(i18n.CouldNotSaveLabel)
    dashboard.RotateSecret -> Some(i18n.CouldNotRotateSecret)
    dashboard.DeleteAccount -> Some(i18n.CouldNotDeleteAccount)
    dashboard.RevealPrivateKey -> None
    dashboard.ShowConnectionQr -> None
  }
}

/// 管理パスワードを再入力した後の秘密鍵の表示ページ。
pub fn private_key_page(
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
  nsec: String,
) -> String {
  view.page(
    language,
    theme,
    i18n.PrivateKey,
    view.Narrow,
    view.NoSwitch,
    view.NoRefresh,
    [
      view.card([
        account_summary(language, row),
        view.copyable_field(
          language,
          i18n.text(language, i18n.PrivateKeyNsec),
          nsec,
        ),
        view.warning(view.emphasized(
          language,
          i18n.CloseTabAfterCopying,
          i18n.ResendNotice,
        )),
      ]),
      view.back_link(language),
    ],
  )
}

/// 操作の対象のアカウントの、ラベルと省略した npub。
fn account_summary(
  language: Language,
  row: dashboard.AccountRow,
) -> Element(msg) {
  view.identity(language, row.label, row.npub)
}

/// ラベルの案内の `id`。ラベルの欄は各ページに 1 つだけなので固定の値にする。
const label_hint_id = "label-hint"

/// ラベルの見出し、入力欄、上限の案内をまとめた囲み。3 つのフォーム（登録画面、生成した
/// 鍵の確認、編集）のどれでも必須にする。
fn label_fieldset(language: Language, value: String) -> Element(msg) {
  let caption = i18n.text(language, i18n.Label)
  view.hinted_input(
    caption,
    label_hint_id,
    i18n.text(language, i18n.LabelHint(max: dashboard.max_label_code_points)),
    [
      attribute.type_("text"),
      attribute.name(dashboard.label_field),
      attribute.autocomplete("off"),
      attribute.default_value(value),
      attribute.required(True),
      attribute.class("input w-full border-base-content/60"),
    ],
  )
}
