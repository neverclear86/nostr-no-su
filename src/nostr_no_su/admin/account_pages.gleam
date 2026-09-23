//// 管理 UI のアカウントのページ（登録画面、生成した鍵の確認、登録の完了、操作、
//// 接続 QR コード、秘密鍵の表示）の描画。`admin/dashboard` の型とパスの定義を
//// `admin/view` の部品で HTML 文字列にするだけで、プロセスにも IO にも触れない。
//// フォームの中身（説明とフォーム）はページの枠を持たない関数で作り、ページはそれをカードに
//// 入れる。ダッシュボードのダイアログと共用するもの（操作の `account_action_form`、読み込めない
//// 行の削除の `unreadable_delete_form`、ラベルの欄の `label_fieldset`）は、このモジュールが
//// `admin/dashboard` を import するので `admin/dashboard` に置く。
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

/// アカウントの登録画面。`import_form` と `generate_form` を見出し付きのカードに 1 つずつ
/// 入れ、末尾に、ダッシュボードに無いアカウントが登録済みと出るときの案内を 1 行出す。失敗の
/// 理由を出した POST の応答でも、テーマか言語を切り替えた後はこの画面を GET で開き直す。
/// `label` は欄に入れる値。GET では空、入力の誤りか 409 で戻したときは送られた値。
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
        view.section_heading(
          view.key_icon(),
          text(i18n.ImportPrivateKey),
          None,
          None,
          [],
        ),
        ..import_form(language, label)
      ]),
      view.card([
        view.section_heading(
          view.plus_icon(),
          text(i18n.GenerateNewKey),
          None,
          None,
          [],
        ),
        ..generate_form(language)
      ]),
      view.hint(text(i18n.SkippedRowNote)),
      view.back_link(language),
    ],
  )
}

/// 既存の秘密鍵の登録のフォーム（ページの枠を含まない）。nsec の伏せ字の欄とラベルの欄を
/// 送る。nsec の欄の説明（`ImportDescription`）は見出しの横の ⓘ で開く補足にし、欄の
/// `aria-describedby` から指す。`label` はラベルの欄に入れる値。
pub fn import_form(language: Language, label: String) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.secret_post_form(
      view.segments_path(dashboard.import_account_segments),
      [
        view.hinted_input(
          language,
          text(i18n.PrivateKeyNsec),
          nsec_hint_id,
          view.FoldedHint(text(i18n.ImportDescription)),
          view.secret_input_attributes(dashboard.nsec_field, "new-password"),
        ),
        dashboard.label_fieldset(language, dashboard.label_hint_id, label),
      ],
      text(i18n.Register),
      view.PrimaryButton,
      view.InForm,
    ),
  ]
}

/// 新しい秘密鍵の生成の説明とフォーム（ページの枠を含まない）。フォームは欄を持たず、
/// 送信のボタンは枠のボタンにする。
pub fn generate_form(language: Language) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.form_description(text(i18n.GenerateDescription)),
    view.post_form(
      view.segments_path(dashboard.generate_account_segments),
      [],
      text(i18n.Generate),
      view.OutlineButton,
      view.InForm,
    ),
  ]
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
        view.alert(
          view.Warning,
          view.emphasized(language, i18n.BackUpNow, i18n.GeneratedKeyNotice),
        ),
        view.copyable_field(language, text(i18n.PrivateKeyNsec), nsec),
        view.post_form(
          view.segments_path(dashboard.register_generated_segments),
          [
            view.hidden_input(dashboard.nsec_field, nsec),
            dashboard.label_fieldset(language, dashboard.label_hint_id, label),
          ],
          text(i18n.RegisterThisKey),
          view.PrimaryButton,
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
        view.alert(
          view.Warning,
          view.emphasized(
            language,
            i18n.BackUpIfNotAlready,
            i18n.RegisteredKeyNotice,
          ),
        ),
        view.copyable_field(language, text(i18n.PrivateKeyNsec), nsec),
      ]),
      view.back_link(language),
    ],
  )
}

/// アカウント 1 件への操作のページ。対象のアカウント、入力の誤りか失敗の理由、
/// `dashboard.account_action_form` の説明とフォームを 1 枚のカードに並べ、カードの下に同じ
/// アカウントのほかの操作のページへのリンク（`dashboard.other_action_links`）を置く。カードの
/// 上の `account_summary` は保存済みのラベルのままにする。見出しの文言は
/// `dashboard.account_action_title` から引く。テーマか言語を切り替えた後は、この操作の
/// ページを GET で開き直す。
pub fn account_action_page(
  language: Language,
  theme: view.Theme,
  row: dashboard.AccountRow,
  action: dashboard.AccountAction,
  label: Option(String),
  error: Option(i18n.Reason),
) -> String {
  let path = dashboard.account_action_path(row.signer, action)
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
        ..dashboard.account_action_form(
          language,
          row,
          action,
          label,
          dashboard.label_hint_id,
        )
      ]),
      dashboard.other_action_links(language, row.signer, action),
      view.back_link(language),
    ],
  )
}

/// 接続 URI をスマートフォンへ渡すための QR コードのページ。バンカーに使うリレーが無ければ
/// 警告を先に出す。続く 1 枚のカードに、アカウントの識別と案内の文、secret 入りの URI と
/// 要承認の URI を切り替える 2 つのタブ（`uri_tab` の組を `view.radio_tabs` に渡す。既定で
/// secret 入りの URI を選ぶ）、カメラ用のコードの貼り方の案内を並べる。タブはラジオボタンと
/// CSS で切り替わり、JS は要らない。カードの後に、この URI が使うバンカーのリレーの URL と、クライアント側の
/// `nostrconnect://` で接続する経路への案内を出す。符号化できない URI はその位置に理由を
/// 出し、コピー欄は残す。
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
      dashboard.no_bunker_relay_alert(language, relays),
      view.card([
        account_summary(language, row),
        html.p([], [html.text(text(i18n.ConnectionQrDescription))]),
        view.radio_tabs(uri_tab_group, [
          uri_tab(
            language,
            i18n.ConnectionUri,
            row.uri,
            view.alert(view.Warning, [
              html.text(text(i18n.ConnectionQrSecretWarning)),
            ]),
          ),
          uri_tab(
            language,
            i18n.ConnectionUriForApproval,
            row.auth_uri,
            approval_note(language),
          ),
        ]),
        html.p([], [html.text(text(i18n.CameraCopySteps))]),
        view.hint(text(i18n.CameraCopyNote)),
      ]),
      bunker_relay_card(language, relays),
      client_uri_card(language),
      view.back_link(language),
    ],
  )
}

/// 接続 URI のタブのラジオボタンの `name`。ページに 1 組だけなので固定の値にする。
const uri_tab_group = "connection-uri"

/// 要承認のタブの `note`。この URI で接続したクライアントは承認待ちで承認するまで署名
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

/// 接続 URI 1 件のタブの語と中身の組（`view.radio_tabs` に渡す）。中身は `note`、端末の
/// カメラ用のコピー用 QR、コピー欄、クライアントの読み取り機能が読む完全な `bunker://` の QR
/// の畳みの順に並べる。
fn uri_tab(
  language: Language,
  title: i18n.Message,
  uri: String,
  note: Element(msg),
) -> #(String, List(Element(msg))) {
  let text = i18n.text(language, title)
  #(text, [
    note,
    qr_or_notice(language, text, account.camera_copy_text(uri)),
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
    view.section_heading(
      view.plug_icon(),
      text(i18n.BunkerRelaysForUri),
      None,
      None,
      [],
    ),
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
    view.section_heading(
      view.plug_icon(),
      text(i18n.ConnectWithClientUri),
      None,
      None,
      [],
    ),
    view.hint(text(i18n.ConnectWithClientUriHint)),
    view.button_link(
      view.segments_path(dashboard.connect_segments),
      text(i18n.ConnectClient),
      view.PrimaryButton,
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
  let path = dashboard.account_action_path(row.pubkey, dashboard.DeleteAccount)
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
        ..dashboard.unreadable_delete_form(language, row)
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
        view.alert(
          view.Warning,
          view.emphasized(
            language,
            i18n.CloseTabAfterCopying,
            i18n.ResendNotice,
          ),
        ),
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

/// nsec の欄の補足の `id`。nsec の欄は登録のフォームに 1 つだけなので固定の値にする。
const nsec_hint_id = "nsec-hint"
