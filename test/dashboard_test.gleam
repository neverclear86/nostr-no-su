//// 管理 UI の状態の見せ方とダイアログに出すフォームの中身（`admin/dashboard`）の単体テスト。

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/element
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/fingerprint
import nostr_no_su/admin/i18n
import nostr_no_su/admin/permission_view
import nostr_no_su/admin/routes
import nostr_no_su/admin/view
import nostr_no_su/bunker/session
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import support/admin_context.{closed_dialog, opened_dialog, opened_dialogs}

/// リレーとプラグインのすべての状態と、承認待ち 1 件を持つスナップショット。
fn states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    accounts: Ok([]),
    skipped: Ok([]),
    pending: Ok([
      pending("tok"),
    ]),
    sessions: Ok([]),
    relays: Ok([
      dashboard.RelayRow(
        1,
        "wss://a",
        dashboard.Reported(relay_connection.Connected),
        dashboard.Reported(relay_connection.Disconnected),
      ),
      dashboard.RelayRow(
        2,
        "wss://b",
        dashboard.Reported(relay_connection.Disconnected),
        dashboard.Unused,
      ),
    ]),
    plugins: [
      dashboard.PluginRow("a", Some(plugin_runner.Running), pages: [
        plugin.PluginPage(key: "status", title: "Status"),
      ]),
      dashboard.PluginRow(
        "b",
        Some(plugin_runner.Overloaded(dropped: 4)),
        pages: [],
      ),
      dashboard.PluginRow(
        "c",
        Some(plugin_runner.Disabled(reason: "boom", dropped: 2)),
        pages: [],
      ),
      dashboard.PluginRow("d", None, pages: []),
    ],
    not_loaded_plugins: [],
    now: 1_789_276_354,
  )
}

/// `snapshot` を英語・システムのテーマのダッシュボードのページに描く。
fn english(snapshot: dashboard.Snapshot) -> String {
  dashboard.render(i18n.English, view.System, snapshot)
}

/// `pending` の承認ページを `language` とシステムのテーマで、アカウントの一覧を空にして
/// `states().now` の時刻に描く。
fn approval(language: i18n.Language, pending: dashboard.PendingRow) -> String {
  dashboard.approval_page(language, view.System, Ok([]), states().now, pending)
}

/// トークン `token` の承認待ちの行。他の欄は固定の値で、違う欄は `..pending(token)` の上書きで変える。
fn pending(token: String) -> dashboard.PendingRow {
  dashboard.PendingRow(
    token:,
    signer: "abcd",
    client: "ef01",
    expires_in_seconds: 540,
    secret_mismatch: False,
    perms: "",
  )
}

/// 提示なしと不一致の承認待ちを、失効までが長い順（作成の新しい順）に持つスナップショット。
/// 提示なしの方(`tok-1`) は権限を要求し、不一致の方（`tok-2`）は権限を要求しない。`tok-2`
/// は残り 60 秒未満で、警告のバッジを見るためのものである。
fn secret_states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    ..states(),
    pending: Ok([
      dashboard.PendingRow(
        ..pending("tok-1"),
        perms: "sign_event:1,nip44_encrypt",
      ),
      dashboard.PendingRow(
        ..pending("tok-2"),
        expires_in_seconds: 45,
        secret_mismatch: True,
      ),
    ]),
  )
}

/// リレーとプラグインの状態は、状態ごとの色のバッジで出し、状態の語と詳細を文字で残す。
/// プラグイン由来の理由は英語のまま `lang="en"` を付けて出す。
pub fn states_are_shown_as_badges_test() {
  let body = english(states())
  let badges = [
    "monitor</dt>",
    element.to_string(view.status_chip(view.ActiveChip, "connected")),
    element.to_string(view.status_chip(view.DisconnectedChip, "disconnected")),
    element.to_string(view.status_chip(view.ActiveChip, "running")),
    element.to_string(view.status_chip(view.OverloadedChip, "overloaded"))
      <> "<span class=\"text-xs break-words\">(dropped 4)</span>",
    element.to_string(view.status_chip(view.DisabledChip, "disabled"))
      <> "<span class=\"text-xs break-words\"><span lang=\"en\">boom</span> (dropped 2)</span>",
    element.to_string(view.status_chip(view.UnansweredChip, "unavailable")),
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 日本語のダッシュボードでは、状態の語と件数を日本語の形で出す。バッジのクラスは英語と同じ
/// である。
pub fn japanese_states_are_translated_test() {
  let body = dashboard.render(i18n.Japanese, view.System, states())
  let badges = [
    "監視</dt>",
    "バンカー</dt>",
    element.to_string(view.status_chip(view.ActiveChip, "接続中")),
    element.to_string(view.status_chip(view.DisconnectedChip, "未接続")),
    element.to_string(view.status_chip(view.ActiveChip, "動作中")),
    element.to_string(view.status_chip(view.OverloadedChip, "過負荷"))
      <> "<span class=\"text-xs break-words\">（破棄 4 件）</span>",
    element.to_string(view.status_chip(view.DisabledChip, "無効"))
      <> "<span class=\"text-xs break-words\"><span lang=\"en\">boom</span>（破棄 2 件）</span>",
    element.to_string(view.status_chip(view.UnansweredChip, "応答なし")),
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 提示なしの承認待ちは secret のバッジが「Secret not offered」、不一致は警告色の
/// 「Secret mismatch」になる。日本語ではそれぞれ「secret 提示なし」「secret 不一致」に
/// なる。
pub fn secret_state_is_shown_as_a_badge_test() {
  let english = english(secret_states())
  assert string.contains(
    english,
    element.to_string(view.status_chip(
      view.SecretNotOfferedChip,
      "Secret not offered",
    )),
  )
  assert string.contains(
    english,
    element.to_string(view.status_chip(
      view.SecretMismatchChip,
      "Secret mismatch",
    )),
  )

  let japanese = dashboard.render(i18n.Japanese, view.System, secret_states())
  assert string.contains(japanese, "secret 提示なし")
  assert string.contains(japanese, "secret 不一致")
}

/// secret が一致しない承認待ちの承認ページには `WrongSecretNotice` の警告の囲みが 1 つだけ出て、提示が無い
/// 承認待ちの承認ページには警告の囲みが出ない。
pub fn wrong_secret_warning_is_shown_only_on_mismatched_approval_page_test() {
  let assert Ok([not_offered, mismatched]) = secret_states().pending
  list.each([i18n.English, i18n.Japanese], fn(language) {
    let notice =
      element.to_string(
        view.alert(view.Warning, [
          html.text(i18n.text(language, i18n.WrongSecretNotice)),
        ]),
      )
    assert list.length(string.split(approval(language, mismatched), notice))
      == 2
    assert !string.contains(approval(language, not_offered), "alert-warning")
  })
}

/// 要求された権限は、承認待ちのカードと承認ページの両方でチップになる。空なら「権限の
/// 要求なし」のバッジ 1 つを出す。
pub fn permissions_are_shown_as_chips_test() {
  let assert Ok([offered, not_requested]) = secret_states().pending
  let chips =
    element.to_string(permission_view.chips(
      i18n.English,
      "sign_event:1,nip44_encrypt",
    ))
  assert string.contains(english(secret_states()), chips)
  assert string.contains(approval(i18n.English, offered), chips)

  let no_perms_badge =
    element.to_string(view.status_chip(
      view.ToneChip(view.Neutral),
      "No permissions requested",
    ))
  assert string.contains(english(secret_states()), no_perms_badge)
  assert string.contains(approval(i18n.English, not_requested), no_perms_badge)
}

/// アカウントの行の畳みには、接続 URI と公開鍵の 3 つの欄が出て、16 進の署名者は
/// `<details>` の外（畳みを開く前に見える範囲）では「接続 QR コード」のボタンが開くダイアログの `id` にだけ使われる。
pub fn account_row_hides_the_hex_pubkey_in_the_details_test() {
  let account = account("abcdhex1234567890abcdef1234567890", "main account")
  let snapshot = dashboard.Snapshot(..states(), accounts: Ok([account]))
  let body = english(snapshot)
  let assert Ok(#(_, after_accounts)) =
    string.split_once(body, "id=\"accounts\"")
  let assert Ok(#(before_details, after_details)) =
    string.split_once(after_accounts, "<details>")
  assert list.length(string.split(before_details, account.signer)) == 2
  assert string.contains(
    before_details,
    "commandfor=\"dialog-account-" <> account.signer <> "-qr\"",
  )
  assert string.contains(after_details, "Connection URIs and actions")
  assert string.contains(after_details, "Connection URI<button")
  assert string.contains(after_details, "Connection URI (approval)<button")
  assert string.contains(after_details, "Public key (hex)</span>")
  assert string.contains(after_details, account.signer)
}

/// 署名者 `signer`、ラベル `label` のアカウントの行。npub は `npub1` に署名者を逆順に続け、
/// 63 文字に満たなければ `q` で埋めた値で、`view.shorten` で省略される。逆順にするのは、
/// 回文でない署名者を npub に部分文字列として含ませないためである。
fn account(signer: String, label: String) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer:,
    npub: string.pad_end("npub1" <> string.reverse(signer), 63, "q"),
    label:,
    uri: "bunker://x?secret=s",
    auth_uri: "bunker://x",
    uri_camera_text: "x?secret=s",
    auth_uri_camera_text: "x",
    picture: None,
  )
}

/// 署名者 `signer` の承認済みセッション 1 件。`client` で行を区別する。
fn session_of(signer: String, client: String) -> session.Session {
  session.Session(
    signer:,
    client:,
    perms: "",
    created_at: 1_788_253_200,
    last_used_at: 1_789_276_354,
    relays: [],
  )
}

/// ダッシュボードのアカウントの節（`id="accounts"` からセッションの節の前まで）。
fn accounts_part(body: String) -> String {
  let assert Ok(#(_, after_accounts)) =
    string.split_once(body, "id=\"accounts\"")
  let assert Ok(#(accounts, _)) =
    string.split_once(after_accounts, "id=\"sessions\"")
  accounts
}

/// アカウントの行の畳み（`<details>` から `</details>` まで）の前と中。
fn split_account_details(body: String) -> #(String, String) {
  let assert Ok(#(before_details, after_details)) =
    string.split_once(accounts_part(body), "<details>")
  let assert Ok(#(details, _)) = string.split_once(after_details, "</details>")
  #(before_details, details)
}

/// アカウントの節の見出しに 1 行の説明が出て、「DB から読み直す」が「アカウントを追加」の
/// ボタンより前に並ぶ。
pub fn accounts_heading_has_the_description_and_reload_before_add_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([account(dialog_signer, "main")]),
    )
  let accounts = accounts_part(english(snapshot))
  assert string.contains(
    accounts,
    "Your registered private keys. Paste a connection URI into a client to sign with that key.",
  )
  let assert Ok(#(before_reload, after_reload)) =
    string.split_once(accounts, "action=\"/accounts/reload\"")
  assert !string.contains(before_reload, "Add account")
  assert string.contains(
    after_reload,
    "command=\"show-modal\" commandfor=\"dialog-account-new\"",
  )
}

/// アカウントの行の畳みの前に、色つきの鍵の指紋、その署名者のセッションの件数（他の署名者の
/// セッションは数えない）、「接続 QR コード」のダイアログを開く主のボタンが出て、畳みの中に QR のボタンは無い。
pub fn account_row_shows_the_fingerprint_session_count_and_qr_test() {
  let account = account(dialog_signer, "main")
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([account]),
      sessions: Ok([
        session_of(account.signer, "ef01"),
        session_of(account.signer, "ef02"),
        session_of(string.repeat("4567", 16), "ef03"),
      ]),
    )
  let #(before_details, details) = split_account_details(english(snapshot))
  assert string.contains(
    before_details,
    element.to_string(fingerprint.pubkey_svg(
      account.signer,
      fingerprint.Colored,
      "size-10",
    )),
  )
  assert string.contains(before_details, ">2 sessions</span>")
  assert string.contains(
    before_details,
    element.to_string(view.dialog_trigger(
      "dialog-account-" <> account.signer <> "-qr",
      view.CompactFace(view.qr_code_icon(), "Connection QR code"),
      view.PrimaryButton,
    )),
  )
  assert !string.contains(details, "-qr\"")
}

/// セッションの件数は、一覧を得たら 0 件でも出し、一覧を得られないときは出さない。
pub fn account_session_count_follows_the_session_list_test() {
  let account = account(dialog_signer, "main")
  let render = fn(sessions) {
    let snapshot =
      dashboard.Snapshot(..states(), accounts: Ok([account]), sessions:)
    accounts_part(english(snapshot))
  }
  assert string.contains(
    render(Ok([session_of(account.signer, "ef01")])),
    ">1 session</span>",
  )
  assert string.contains(render(Ok([])), ">0 sessions</span>")
  let unavailable = render(Error(i18n.Untranslated("boom")))
  assert !string.contains(unavailable, ">1 session</span>")
  assert !string.contains(unavailable, ">0 sessions</span>")
}

/// 畳みの中に 2 つの URI の説明が出て、ラベルの編集・秘密鍵の表示・secret の再生成のダイアログを開くボタン、
/// 右端に離した（`ml-auto` の囲みの）削除のダイアログを開くボタンの順に並ぶ。
pub fn account_details_hold_the_uris_and_the_actions_test() {
  let account = account(dialog_signer, "main")
  let snapshot = dashboard.Snapshot(..states(), accounts: Ok([account]))
  let #(_, details) = split_account_details(english(snapshot))
  assert string.contains(
    details,
    "Connects without approval. Paste it into your own client.",
  )
  assert string.contains(
    details,
    "A client that connects with this URI cannot sign until you approve it under pending connections on the dashboard.",
  )
  let trigger = fn(segment, icon, text, kind) {
    element.to_string(view.dialog_trigger(
      "dialog-account-" <> account.signer <> "-" <> segment,
      view.IconTextFace(icon, text),
      kind,
    ))
  }
  assert contains_in_order(details, [
    trigger("label", view.pencil_icon(), "Edit label", view.GhostButton),
    trigger(
      "private-key",
      view.eye_icon(),
      "Show private key",
      view.GhostButton,
    ),
    trigger("rotate", view.rotate_icon(), "Rotate secret", view.GhostButton)
      <> "<div class=\"ml-auto\">"
      <> trigger("delete", view.trash_icon(), "Delete", view.DangerGhostButton),
  ])
}

/// 行の 4 つの操作と接続 QR コードのダイアログは、畳み（`<details>`）の中ではなく `</details>` の後に置く。
pub fn account_row_dialogs_sit_outside_the_details_test() {
  let account = account(dialog_signer, "main")
  let snapshot = dashboard.Snapshot(..states(), accounts: Ok([account]))
  let assert Ok(#(_, after_details)) =
    string.split_once(accounts_part(english(snapshot)), "</details>")
  use segment <- list.each(["label", "private-key", "rotate", "delete", "qr"])
  let id = "dialog-account-" <> account.signer <> "-" <> segment
  assert #(
      segment,
      string.contains(after_details, "class=\"modal\" id=\"" <> id <> "\">"),
    )
    == #(segment, True)
}

/// `needles` が `haystack` にこの順に重ならずに現れる。
fn contains_in_order(haystack: String, needles: List(String)) -> Bool {
  case needles {
    [] -> True
    [needle, ..rest] ->
      case string.split_once(haystack, needle) {
        Ok(#(_, after)) -> contains_in_order(after, rest)
        Error(Nil) -> False
      }
  }
}

/// 読み込めなかった行は、アカウントの節の中で行の一覧の後に error の色の枠として出て、
/// 行に灰色の鍵の指紋が付く。
pub fn skipped_rows_sit_in_a_failure_frame_after_the_accounts_test() {
  let pubkey = string.repeat("8901", 16)
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([account(dialog_signer, "main")]),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey:,
          npub: Some("npub1unreadable"),
          label: "old wallet",
          reason: vault.UndecryptablePrivateKey,
        ),
      ]),
    )
  let accounts = accounts_part(english(snapshot))
  let assert Ok(#(before_frame, frame)) =
    string.split_once(accounts, "alert alert-soft alert-error")
  assert string.contains(before_frame, "Your registered private keys.")
  assert string.contains(before_frame, "</dialog></li></ul>")
  assert string.contains(frame, "Unreadable accounts")
  assert string.contains(
    frame,
    element.to_string(fingerprint.pubkey_svg(pubkey, fingerprint.Gray, "size-8")),
  )
}

/// ページを供給するプラグインの行にだけ、ページを開くリンクが出る。
pub fn only_plugins_with_a_page_have_a_link_test() {
  let body = english(states())
  assert string.contains(
    body,
    routes.href(routes.ShowPluginPage("a", "status")),
  )
  assert !string.contains(body, "/plugins/b/")
  assert !string.contains(body, "/plugins/c/")
  assert !string.contains(body, "/plugins/d/")
}

/// プラグインのページを開くリンクは、プラグイン名を percent-encode する。
pub fn plugin_page_link_encodes_the_plugin_name_test() {
  let snapshot =
    dashboard.Snapshot(..states(), plugins: [
      dashboard.PluginRow("a b", Some(plugin_runner.Running), pages: [
        plugin.PluginPage(key: "status", title: "Status"),
      ]),
    ])
  let body = english(snapshot)
  assert string.contains(body, "href=\"/plugins/a%20b/status\"")
}

/// 無効になったプラグインの行にだけ再有効化のフォームが付き、プラグイン名を
/// hidden 欄で送る。
pub fn only_disabled_plugins_have_a_reenable_button_test() {
  let body = english(states())
  let forms =
    string.split(body, "action=\"/plugins/reenable\"")
    |> list.length
  assert forms == 2
  assert string.contains(
    body,
    "action=\"/plugins/reenable\" method=\"post\"><input name=\"name\" type=\"hidden\" value=\"c\">",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, states()),
    "再有効化",
  )
}

/// 節の見出しの件数のピルの開始タグ。`view.section_heading` を件数 0 で描き、題の `</h2>` の
/// 直後から取り出す。
fn count_pill_tag() -> String {
  let heading =
    element.to_string(view.section_heading(element.none(), "", Some(0), [], []))
  let assert Ok(#(_, after_title)) = string.split_once(heading, "</h2>")
  let assert Ok(#(tag, _)) = string.split_once(after_title, ">")
  tag <> ">"
}

/// 節の見出しの件数 `count` のピルの HTML。
fn count_pill(count: Int) -> String {
  count_pill_tag() <> int.to_string(count) <> "</span>"
}

/// プラグインの節の見出しは、題の直後に件数のピルを置き、説明の段落も ⓘ も持たない。
pub fn plugins_heading_shows_the_count_without_a_description_test() {
  use #(language, title, description) <- list.each([
    #(
      i18n.English,
      "Plugins",
      "Receives and processes the events of registered accounts.",
    ),
    #(i18n.Japanese, "プラグイン", "登録したアカウントのイベントを受け取って処理します。"),
  ])
  let body = dashboard.render(language, view.System, states())
  assert string.contains(
    body,
    title <> "</h2>" <> count_pill(4) <> "</div></div>",
  )
  assert !string.contains(body, "plugins-hint")
  assert !string.contains(body, description)
}

/// プラグインは表ではなく行の一覧に並び、各行に名前と状態のチップが入る。応答の無いプラグインは
/// 「応答なし」のチップで出る。
pub fn plugin_rows_show_the_name_and_state_chip_test() {
  let body = english(states())
  assert !string.contains(body, "<table")
  let rows = string.split(body, "<li class=\"list-row ")
  use #(name, chip, word) <- list.each([
    #("a", view.ActiveChip, "running"),
    #("b", view.OverloadedChip, "overloaded"),
    #("c", view.DisabledChip, "disabled"),
    #("d", view.UnansweredChip, "unavailable"),
  ])
  let name_span =
    "<span class=\"font-semibold break-words\">" <> name <> "</span>"
  let assert Ok(row) = list.find(rows, string.contains(_, name_span))
  assert string.contains(row, element.to_string(view.status_chip(chip, word)))
}

/// 読み込めなかったプラグインは、プラグインの行の一覧の直後にエラーの色の枠で、「読み込み失敗」のチップと識別子と理由つきで出る。理由は英語のまま `lang="en"` で包む。
pub fn dashboard_shows_not_loaded_plugins_test() {
  let snapshot =
    dashboard.Snapshot(..states(), not_loaded_plugins: [
      plugin_loader.NotLoaded(
        id: "demo_plugin",
        reason: "unsupported api version 2 (expected 1)",
      ),
      plugin_loader.NotLoaded(
        id: "broken-bundle",
        reason: "no ebin directory found (expected broken-bundle/ebin or broken-bundle/*/ebin)",
      ),
    ])
  let english = english(snapshot)
  assert string.contains(english, "Plugins that failed to load")
  assert string.contains(
    english,
    "</li></ul>"
      <> opening_tag(view.failure_frame(element.none(), "", 0, "", [])),
  )
  assert string.contains(
    english,
    element.to_string(view.status_chip(view.LoadFailedChip, "failed to load")),
  )
  assert string.contains(
    english,
    "These plugins are not running. Fix the cause below and restart the server.",
  )
  assert string.contains(english, "<span lang=\"en\">demo_plugin</span>")
  assert string.contains(
    english,
    "<span lang=\"en\">unsupported api version 2 (expected 1)</span>",
  )
  let japanese = dashboard.render(i18n.Japanese, view.System, snapshot)
  assert string.contains(japanese, "読み込めなかったプラグイン")
  assert string.contains(
    japanese,
    element.to_string(view.status_chip(view.LoadFailedChip, "読み込み失敗")),
  )
}

/// `not_loaded_plugins` が 0 件のときは枠ごと出さない。
pub fn dashboard_hides_not_loaded_plugins_when_empty_test() {
  use language <- list.each([i18n.English, i18n.Japanese])
  assert !string.contains(
    dashboard.render(language, view.System, states()),
    i18n.text(language, i18n.NotLoadedPlugins),
  )
}

/// 「はじめに」の帯は、見出しに説明の段落も ⓘ も持たない。
pub fn getting_started_band_has_no_description_test() {
  use #(language, description) <- list.each([
    #(
      i18n.English,
      "Register a relay and an account, then paste the connection URI into your client.",
    ),
    #(i18n.Japanese, "リレーとアカウントを登録し、接続 URI をクライアントに貼ると使えます。"),
  ])
  let body = dashboard.render(language, view.System, states())
  assert string.contains(body, "id=\"getting-started\"")
  assert !string.contains(body, "getting-started-hint")
  assert !string.contains(body, description)
}

/// アカウントの節の見出しは、題の直後の ⓘ で説明を `accounts-hint` の補足に開く。
pub fn accounts_heading_opens_the_description_from_the_info_button_test() {
  let body = english(dialog_snapshot())
  assert string.contains(
    body,
    "Accounts</h2>"
      <> hint_html(
      i18n.English,
      "accounts-hint",
      i18n.text(i18n.English, i18n.AccountsDescription),
    ),
  )
}

/// 承認待ちの帯の見出しは、題の直後の ⓘ で説明を `pending-hint` の補足に開く。
pub fn pending_band_opens_the_description_from_the_info_button_test() {
  let body = dashboard.render(i18n.Japanese, view.System, states())
  assert string.contains(
    body,
    i18n.text(i18n.Japanese, i18n.PendingConnections)
      <> "</h2>"
      <> hint_html(
      i18n.Japanese,
      "pending-hint",
      i18n.text(i18n.Japanese, i18n.PendingConnectionsDescription),
    ),
  )
}

/// アカウントの行の畳みの 2 つの URI の欄は、行ごとの `id` の ⓘ で説明を開く。2 行あっても各 `id` は
/// 1 回ずつ現れる。
pub fn account_details_open_the_uri_descriptions_from_the_info_buttons_test() {
  let second = string.repeat("4567", 16)
  let body =
    english(
      dashboard.Snapshot(
        ..dialog_snapshot(),
        accounts: Ok([
          account(dialog_signer, "main"),
          account(second, "bot"),
        ]),
      ),
    )
  use signer <- list.each([dialog_signer, second])
  let uri_hint = "account-" <> signer <> "-uri-hint"
  let auth_hint = "account-" <> signer <> "-auth-uri-hint"
  assert string.contains(
    body,
    "Connection URI"
      <> hint_html(
      i18n.English,
      uri_hint,
      i18n.text(i18n.English, i18n.SecretUriDescription),
    ),
  )
  assert string.contains(
    body,
    "Connection URI (approval)"
      <> hint_html(
      i18n.English,
      auth_hint,
      i18n.text(i18n.English, i18n.ApprovalUriNeedsApproval),
    ),
  )
  assert list.length(string.split(body, "id=\"" <> uri_hint <> "\"")) == 2
  assert list.length(string.split(body, "id=\"" <> auth_hint <> "\"")) == 2
  assert string.contains(body, "<input aria-describedby=\"" <> uri_hint <> "\"")
  assert string.contains(
    body,
    "<input aria-describedby=\"" <> auth_hint <> "\"",
  )
}

/// `node` の開始タグ（最初の `>` まで）。
fn opening_tag(node: element.Element(Nil)) -> String {
  let assert Ok(#(opening, _)) = string.split_once(element.to_string(node), ">")
  opening <> ">"
}

/// `id` のダイアログを閉じるボタン（語は `dismiss`）だけを並べた操作の行の HTML
/// （`view.dialog_actions` の `opening` の描画）。
fn dismiss_row(
  id: String,
  dismiss: String,
  opening: view.DialogOpening,
) -> String {
  view.dialog_actions(view.InDialog(id:, dismiss:, opening:), [])
  |> list.map(element.to_string)
  |> string.concat
}

/// ダッシュボードのどのダイアログも、同じダイアログを閉じるボタン（接続 QR コードは「閉じる」、ほかは
/// 「キャンセル」）を送信の右に並べる。
pub fn every_dashboard_dialog_puts_cancel_beside_submit_test() {
  let body = english(dialog_snapshot())
  let assert [_, ..dialogs] = string.split(body, "<dialog ")
  assert dialogs != []
  use dialog <- list.each(dialogs)
  let assert Ok(#(dialog, _)) = string.split_once(dialog, "</dialog>")
  let assert Ok(#(_, rest)) = string.split_once(dialog, "id=\"")
  let assert Ok(#(id, _)) = string.split_once(rest, "\"")
  let dismiss = case string.ends_with(id, "-qr") {
    True -> "Close"
    False -> "Cancel"
  }
  // 行の開始タグを除いた、閉じるボタンと行の閉じタグ
  let assert Ok(#(_, dismiss_tail)) =
    string.split_once(dismiss_row(id, dismiss, view.OpensOnTrigger), ">")
  assert string.contains(dialog, dismiss_tail)
}

/// アカウントが 0 件のときの接続のダイアログも、キャンセルの行を残す。
/// アカウントの一覧を得られないときは、その行にキャンセルだけを置く。
pub fn connect_dialog_without_accounts_still_has_cancel_test() {
  let actions =
    dismiss_row("dialog-session-connect", "Cancel", view.OpensOnTrigger)
  let empty = closed_dialog(english(states()), "dialog-session-connect")
  assert string.contains(empty, actions)
  let failed =
    closed_dialog(
      english(
        dashboard.Snapshot(
          ..states(),
          accounts: Error(i18n.Untranslated("boom")),
        ),
      ),
      "dialog-session-connect",
    )
  assert string.contains(failed, actions)
}

/// 節の一覧を得られないときの、面に載せた error の色の理由の囲みの HTML。`lead` は日本語の
/// 前置き、`reason` は英語のまま届いた理由である。
fn listed_reason_html(
  language: i18n.Language,
  lead: i18n.Lead,
  reason: String,
) -> String {
  element.to_string(
    view.surface([
      view.alert(
        view.Failure,
        view.reason_content(language, Some(lead), i18n.Untranslated(reason)),
      ),
    ]),
  )
}

/// 承認待ちとセッションを得られないときは、「0 件」の代わりに理由を出し、
/// 承認・拒否や取り消しのフォームも出さない。承認待ちとセッションの理由の囲みは
/// どちらも error 色になる。日本語では前置きも出る。
pub fn unlisted_pending_and_sessions_show_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      pending: Error(i18n.Untranslated("pending reason")),
      sessions: Error(i18n.Untranslated("sessions reason")),
    )
  let english = english(snapshot)
  assert string.contains(
    english,
    listed_reason_html(i18n.English, i18n.CouldNotListPending, "pending reason"),
  )
  assert string.contains(english, "<span lang=\"en\">sessions reason</span>")
  assert !string.contains(
    english,
    i18n.text(i18n.English, i18n.NoApprovedSessions),
  )
  assert !string.contains(english, "action=\"/approve/")
  assert !string.contains(english, "action=\"/sessions/revoke\"")

  let japanese = dashboard.render(i18n.Japanese, view.System, snapshot)
  assert string.contains(
    japanese,
    listed_reason_html(
      i18n.Japanese,
      i18n.CouldNotListPending,
      "pending reason",
    ),
  )
  assert string.contains(
    japanese,
    listed_reason_html(
      i18n.Japanese,
      i18n.CouldNotListSessions,
      "sessions reason",
    ),
  )
}

/// 承認待ち、アカウント、セッションの 3 つの一覧が同じ英語の理由で得られないときは、承認待ちの
/// 帯より前にエラーの色の囲みを 1 つ出して理由をそこで 1 回だけ出し、3 つの節には
/// 「上の理由で取得できません。」の 1 文だけを出す。日本語では囲みに前置きが付く。
pub fn shared_listing_failure_is_shown_once_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Error(i18n.Untranslated("account store unavailable: boom")),
      pending: Error(i18n.Untranslated("account store unavailable: boom")),
      sessions: Error(i18n.Untranslated("account store unavailable: boom")),
    )
  let english = outside_dialogs(english(snapshot))
  assert list.length(string.split(english, "account store unavailable: boom"))
    == 2
  assert list.length(string.split(english, "alert alert-soft alert-error")) == 2
  assert list.length(string.split(
      english,
      "<p class=\"text-sm text-muted\">Not available for the reason above.</p>",
    ))
    == 4
  let assert Ok(#(before_pending, _)) =
    string.split_once(english, "id=\"pending\"")
  assert string.contains(
    before_pending,
    "<span lang=\"en\">account store unavailable: boom</span>",
  )

  let japanese = dashboard.render(i18n.Japanese, view.System, snapshot)
  assert string.contains(
    japanese,
    "<span class=\"wrap-anywhere\">承認待ち、アカウント、セッションの一覧を表示できません。"
      <> "<span lang=\"en\">account store unavailable: boom</span></span>",
  )
  assert list.length(string.split(
      japanese,
      "<p class=\"text-sm text-muted\">上の理由で取得できません。</p>",
    ))
    == 4
}

/// 3 つの一覧がどれも締め切りを超えたときは先頭の囲みにまとめず、節ごとにエラーの色の囲みで
/// 「今は取得できません。」を出す。
pub fn timed_out_listings_are_not_merged_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Error(i18n.Translated(i18n.NotAvailable)),
      pending: Error(i18n.Translated(i18n.NotAvailable)),
      sessions: Error(i18n.Translated(i18n.NotAvailable)),
    )
  let english = outside_dialogs(english(snapshot))
  assert list.length(string.split(english, "Not available right now.")) == 4
  assert list.length(string.split(english, "alert alert-soft alert-error")) == 4
  assert !string.contains(english, "Not available for the reason above.")
}

/// 3 つの一覧の理由が 1 つでも違うときは先頭の囲みにまとめず、節ごとにエラーの色の囲みで
/// それぞれの理由を出す。
pub fn different_listing_failures_stay_in_each_section_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Error(i18n.Untranslated("first reason")),
      pending: Error(i18n.Untranslated("first reason")),
      sessions: Error(i18n.Untranslated("second reason")),
    )
  let english = outside_dialogs(english(snapshot))
  assert list.length(string.split(english, "first reason")) == 3
  assert list.length(string.split(english, "second reason")) == 2
  assert list.length(string.split(english, "alert alert-soft alert-error")) == 4
  assert !string.contains(english, "Not available for the reason above.")
}

/// セッションの行に署名者のラベルと省略した npub、権限のチップ（2 列にまたがる枠の中）、
/// クライアントのコピーボタンが出る。
pub fn session_row_shows_the_signer_and_permission_chips_test() {
  let known_signer = "abcd-known-signer-0123456789"
  let account = account(known_signer, "main")
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([account]),
      sessions: Ok([
        session.Session(
          ..session_of(known_signer, "ef01"),
          perms: "sign_event:1",
          created_at: 1000,
          last_used_at: 1000,
        ),
      ]),
    )
  let body = english(snapshot)
  assert string.contains(body, "<span>main</span>")
  assert string.contains(body, view.shorten(account.npub))
  assert string.contains(
    body,
    "<div class=\"col-span-2\">"
      <> element.to_string(permission_view.chips(i18n.English, "sign_event:1"))
      <> "</div>",
  )
  assert string.contains(
    sessions_part(snapshot),
    i18n.text(i18n.English, i18n.CopyClient),
  )
}

/// `now` を固定したスナップショットで、最終利用が相対時刻（「7 d ago」の形）になり、
/// `title` に最終利用と作成の UTC の全文が入る。
pub fn last_used_is_shown_as_a_relative_time_test() {
  let last_used_at = 1_789_276_354
  let created_at = 1_788_253_200
  let now = last_used_at + 7 * 86_400
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      now:,
      sessions: Ok([
        session.Session(
          ..session_of("abcd", "ef01"),
          created_at:,
          last_used_at:,
        ),
      ]),
    )
  let body = english(snapshot)
  assert string.contains(body, "7 d ago")
  assert string.contains(
    body,
    "title=\"Last used: 2026-09-13T05:12:34Z · Created: 2026-09-01T09:00:00Z\"",
  )
}

/// 飛ばされた行が 1 件以上あれば、見出し・警告の 1 文・識別（ラベルと省略した npub）・理由・
/// 削除のダイアログを開くボタンが出る。日本語でも見出しが訳される。16 進の pubkey は属性値
/// （ダイアログの `id`、フォームの宛先）にだけ使われ、識別としては出ない。
pub fn skipped_rows_are_listed_with_their_reason_test() {
  let pubkey = "deadbeef00112233445566778899aabbccddeeff0011223344"
  let npub = "npub1skippedexamplevalueabcdefghijklmno"
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey:,
          npub: Some(npub),
          label: "old wallet",
          reason: vault.UndecryptablePrivateKey,
        ),
      ]),
    )
  let english = english(snapshot)
  assert string.contains(english, "Unreadable accounts")
  assert string.contains(
    english,
    "The current ACCOUNT_MASTER_KEY cannot decrypt these rows.",
  )
  assert string.contains(english, "old wallet")
  assert string.contains(english, view.shorten(npub))
  assert string.contains(
    english,
    "The private key cannot be decrypted (wrong ACCOUNT_MASTER_KEY or a tampered row).",
  )
  assert string.contains(
    english,
    element.to_string(view.dialog_trigger(
      "dialog-unreadable-" <> pubkey <> "-delete",
      view.IconTextFace(view.trash_icon(), "Delete"),
      view.DangerGhostButton,
    )),
  )
  assert !string.contains(english, ">" <> pubkey)
  assert !string.contains(english, pubkey <> "<")
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "読み込めなかったアカウント",
  )
}

/// `pubkey` 列を読めない行は、識別も削除のボタンも出さず、理由の 1 文に削除でき
/// ない旨を続けて出す。
pub fn malformed_pubkey_rows_show_only_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey: "not-a-valid-pubkey-value",
          npub: None,
          label: "",
          reason: vault.MalformedPubkey,
        ),
      ]),
    )
  let body = english(snapshot)
  assert string.contains(body, "The pubkey column cannot be read.")
  assert string.contains(
    body,
    "This row cannot be deleted here because its pubkey cannot be read.",
  )
  assert !string.contains(body, "not-a-valid-pubkey-value")
}

/// 飛ばされた行が 0 件、あるいは一覧を得られないときは枠を描かない。
pub fn no_skipped_rows_draws_no_frame_test() {
  let empty = dashboard.Snapshot(..states(), skipped: Ok([]))
  let unavailable =
    dashboard.Snapshot(..states(), skipped: Error(i18n.Untranslated("boom")))
  use language <- list.each([i18n.English, i18n.Japanese])
  let heading = i18n.text(language, i18n.UnreadableAccounts)
  assert !string.contains(
    dashboard.render(language, view.System, empty),
    heading,
  )
  assert !string.contains(
    dashboard.render(language, view.System, unavailable),
    heading,
  )
}

/// リレーは 1 件につき節の `<li>` 1 件で、URL、操作（用途の編集、削除）のダイアログを開くアイコン
/// だけのボタン、監視、バンカーの順に並び、用途ごとにアイコン・語・状態のバッジを出す。使って
/// いない用途は「未使用」のバッジで出す。
pub fn relays_are_listed_one_item_per_row_test() {
  let body = english(states())
  let assert Ok(#(_, section)) = string.split_once(body, "id=\"relays\"")
  let assert Ok(#(section, _)) = string.split_once(section, "id=\"plugins\"")
  let assert [_, first, second] = string.split(section, "<li ")
  let trigger = fn(id, icon, label, kind) {
    element.to_string(view.dialog_trigger(
      "dialog-relay-" <> id,
      view.IconOnlyFace(icon, label),
      kind,
    ))
  }
  use #(item, url, id, monitor, bunker) <- list.each([
    #(
      first,
      "wss://a",
      "1",
      view.status_chip(view.ActiveChip, "connected"),
      view.status_chip(view.DisconnectedChip, "disconnected"),
    ),
    #(
      second,
      "wss://b",
      "2",
      view.status_chip(view.DisconnectedChip, "disconnected"),
      view.status_chip(view.UnusedChip, "Unused"),
    ),
  ])
  assert contains_in_order(item, [
    url,
    trigger(id <> "-edit", view.pencil_icon(), "Edit roles", view.GhostButton),
    trigger(
      id <> "-delete",
      view.trash_icon(),
      "Delete relay",
      view.DangerGhostButton,
    ),
    element.to_string(view.eye_icon()),
    "monitor</dt><dd>",
    element.to_string(monitor),
    element.to_string(view.key_icon()),
    "bunker</dt><dd>",
    element.to_string(bunker),
  ])
}

/// アカウントの追加のダイアログの nsec の欄は、貼り付けの説明（`ImportDescription`）を ⓘ で開く補足に畳み、
/// 欄の `aria-describedby` から指す。説明はフォームの前の段落には出さない。
pub fn add_account_dialog_folds_the_nsec_description_test() {
  use language <- list.each(i18n.languages)
  let text = i18n.text(language, _)
  let dialog =
    closed_dialog(
      dashboard.render(language, view.System, states()),
      "dialog-account-new",
    )
  assert string.contains(
    dialog,
    "<input aria-describedby=\"nsec-hint\" aria-label=\""
      <> text(i18n.PrivateKeyNsec)
      <> "\" autocomplete=\"new-password\"",
  )
  assert string.contains(dialog, "popovertarget=\"nsec-hint\"")
  assert string.contains(
    dialog,
    "id=\"nsec-hint\" popover=\"hint\">"
      <> text(i18n.ImportDescription)
      <> "</div>",
  )
  assert !string.contains(
    dialog,
    element.to_string(view.paragraph(text(i18n.ImportDescription))),
  )
}

/// 生成した鍵のダイアログは、開き直す理由ごとの囲みを先頭に出す。ラベルの誤りと反映されなかった登録は
/// error の色の理由（英語のまま届いた理由には前置き）、受け付けられない登録と確かめられない登録は案内の文に
/// 理由を続けた warning の色の囲みにする。
pub fn generated_key_dialog_shows_each_problem_test() {
  let render = fn(problem) {
    let assert Ok(html) =
      dashboard.render_open(
        i18n.Japanese,
        view.System,
        states(),
        dashboard.GeneratedKeyOpen(
          "npub1example",
          "nsec1example",
          "main",
          Some(problem),
        ),
      )
    opened_dialog(html, "dialog-result")
  }
  let alert = fn(tone, content) {
    element.to_string(view.reason_alert(tone, content))
  }
  assert string.contains(
    render(dashboard.InvalidLabel(i18n.LabelEmpty)),
    alert(view.Failure, [html.text("ラベルを入力してください。")]),
  )
  assert string.contains(
    render(
      dashboard.NotApplied(i18n.Untranslated("account is already registered")),
    ),
    alert(view.Failure, [
      html.text("登録できませんでした。"),
      view.untranslated("account is already registered"),
    ]),
  )
  assert string.contains(
    render(dashboard.NotAccepted("accounts are not loaded yet")),
    alert(view.Warning, [
      html.text(i18n.text(i18n.Japanese, i18n.RegistrationNotAccepted)),
      view.untranslated("accounts are not loaded yet"),
    ]),
  )
  assert string.contains(
    render(dashboard.NotConfirmed(i18n.StoreDidNotConfirm)),
    alert(view.Warning, [
      html.text(i18n.text(i18n.Japanese, i18n.RegistrationNotConfirmed)),
      html.text(i18n.text(i18n.Japanese, i18n.StoreDidNotConfirm)),
    ]),
  )
}

/// アカウントと読み込めなかった行のダイアログは、その一覧を得られなければ理由を、開く行が無ければ
/// `AccountNotFound` を返す。追加、生成した鍵、秘密鍵のダイアログは一覧を得られなくても描く。
pub fn render_open_needs_the_listed_account_test() {
  let reason = i18n.Untranslated("boom")
  let failed =
    dashboard.Snapshot(
      ..states(),
      accounts: Error(reason),
      skipped: Error(reason),
    )
  let open = fn(snapshot, dialog) {
    dashboard.render_open(i18n.English, view.System, snapshot, dialog)
    |> result.map(fn(_) { Nil })
  }
  let row_dialogs = [
    dashboard.AccountActionOpen(
      dialog_signer,
      routes.RotateSecret,
      None,
      reason,
    ),
    dashboard.UnreadableDeleteOpen(dialog_skipped, reason),
  ]
  list.each(row_dialogs, fn(dialog) {
    assert open(failed, dialog) == Error(reason)
    assert open(states(), dialog)
      == Error(i18n.Translated(i18n.AccountNotFound))
    assert open(dialog_snapshot(), dialog) == Ok(Nil)
  })
  list.each(
    [
      dashboard.AddAccountOpen("", reason),
      dashboard.GeneratedKeyOpen("npub1example", "nsec1example", "", None),
      dashboard.PrivateKeyOpen(account(dialog_signer, "main"), "nsec1example"),
    ],
    fn(dialog) {
      assert open(failed, dialog) == Ok(Nil)
    },
  )
}

/// アカウントの追加のダイアログは、登録、生成の順のタブで 2 つのフォームを出す。
pub fn account_add_dialog_has_import_and_generate_tabs_test() {
  let dialog = closed_dialog(english(states()), "dialog-account-new")
  let in_dialog =
    view.InDialog(
      id: "dialog-account-new",
      dismiss: "Cancel",
      opening: view.OpensOnTrigger,
    )
  assert string.contains(
    dialog,
    element.to_string(
      view.radio_tabs("dialog-account-new-tab", [
        #(
          "Import a private key",
          dashboard.import_form(i18n.English, "", in_dialog),
        ),
        #(
          "Generate a new key",
          dashboard.generate_form(i18n.English, in_dialog),
        ),
      ]),
    ),
  )
}

/// `html` の中で `name="<name>"` を持つ最初の `<input>` に `checked` が付いているか。lustre は
/// 属性を名前順に出すので、`checked` は `<input` の直後に来る。
fn checkbox_checked(html: String, name: String) -> Bool {
  let assert Ok(#(before, _)) =
    string.split_once(html, " name=\"" <> name <> "\"")
  let assert Ok(tag) = list.last(string.split(before, "<input"))
  string.starts_with(tag, " checked ")
}

/// 用途の編集のダイアログは、行の今の用途にチェックを入れ、用途の接続状態のバッジを付ける。
pub fn relay_edit_dialogs_check_the_current_roles_test() {
  let body = english(states())
  let first = closed_dialog(body, "dialog-relay-1-edit")
  assert string.contains(first, "wss://a")
  assert checkbox_checked(first, "bunker")
  let second = closed_dialog(body, "dialog-relay-2-edit")
  assert string.contains(second, "wss://b")
  assert checkbox_checked(second, "monitor")
  assert !checkbox_checked(second, "bunker")
  assert string.contains(
    second,
    element.to_string(view.status_chip(view.UnusedChip, "Unused")),
  )
}

/// 最初の `<form action="<prefix>` から `>` の前までを取り出す。ページ枠の切り替えのフォームを避けて宛先で探す。
fn form_tag(html: String, prefix: String) -> String {
  let assert Ok(#(_, rest)) =
    string.split_once(html, "<form action=\"" <> prefix)
  let assert Ok(#(tag, _)) = string.split_once(rest, ">")
  tag
}

/// テストのアカウントの署名者（64 桁の 16 進）。鍵の指紋を描ける値である。
const dialog_signer =
  "0123012301230123012301230123012301230123012301230123012301230123"

/// ダイアログのテストの読み込めなかった行の pubkey（64 桁の 16 進）。
const dialog_skipped =
  "8901890189018901890189018901890189018901890189018901890189018901"

/// アカウント 1 行と読み込めなかった行 1 行を持つダッシュボードの状態。
fn dialog_snapshot() -> dashboard.Snapshot {
  dashboard.Snapshot(
    ..states(),
    accounts: Ok([account(dialog_signer, "main")]),
    skipped: Ok([
      dashboard.SkippedRow(
        pubkey: dialog_skipped,
        npub: Some("npub1skippeddialogvalueabcdefghijklmnopq"),
        label: "old wallet",
        reason: vault.UndecryptablePrivateKey,
      ),
    ]),
  )
}

/// ラベルの違う 2 行の、それぞれの編集のダイアログに、その行のラベルの識別と欄の値と
/// 補足の `id` がある。
pub fn account_label_dialogs_hold_each_row_label_test() {
  let second = string.repeat("4567", 16)
  let snapshot =
    dashboard.Snapshot(
      ..dialog_snapshot(),
      accounts: Ok([
        account(dialog_signer, "main"),
        account(second, "bot"),
      ]),
    )
  let body = english(snapshot)
  use #(signer, label) <- list.each([#(dialog_signer, "main"), #(second, "bot")])
  let account = account(signer, label)
  let id = "dialog-account-" <> signer <> "-label"
  let dialog = closed_dialog(body, id)
  assert string.contains(
    dialog,
    element.to_string(view.identity(
      i18n.English,
      view.PlainIdentity,
      account.label,
      account.npub,
    )),
  )
  assert string.contains(dialog, "value=\"" <> label <> "\"")
  assert string.contains(dialog, "aria-describedby=\"" <> id <> "-label-hint\"")
  assert string.contains(dialog, "id=\"" <> id <> "-label-hint\"")
}

/// 締め切りまでに答えなかった用途（`Unanswered`）は「応答なし」のバッジになり、
/// URL と操作のボタン（用途の編集、削除）は残る。
pub fn a_relay_role_without_a_status_shows_unavailable_test() {
  let body =
    english(
      dashboard.Snapshot(
        ..states(),
        relays: Ok([
          dashboard.RelayRow(
            1,
            "wss://a",
            dashboard.Unanswered,
            dashboard.Unused,
          ),
        ]),
      ),
    )
  assert string.contains(
    body,
    "monitor</dt><dd>"
      <> element.to_string(view.status_chip(view.UnansweredChip, "unavailable")),
  )
  assert string.contains(body, "wss://a")
  assert string.contains(body, "commandfor=\"dialog-relay-1-edit\"")
  assert string.contains(body, "commandfor=\"dialog-relay-1-delete\"")
}

/// バンカーに使う行が 1 件も無ければ、見出しと凡例の直後にエラーの色の囲みが出て一覧は出さない。監視だけの
/// 行があれば囲みの後に一覧を出し、バンカーの行が 1 件でもあれば囲みを出さない
/// （`states()` はバンカーの行を持つので、上のテストの描画に囲みが無いことで確かめる）。
pub fn no_bunker_relay_is_shown_in_an_error_alert_test() {
  let add_trigger =
    element.to_string(view.dialog_trigger(
      "dialog-relay-new",
      view.IconTextFace(view.plus_icon(), "Add"),
      view.PrimaryButton,
    ))
  let no_bunker =
    element.to_string(
      view.alert(view.Failure, [
        html.text(i18n.text(i18n.English, i18n.NoBunkerRelay)),
      ]),
    )
  let legend = english_relays_hint_html()
  let no_rows = english(dashboard.Snapshot(..states(), relays: Ok([])))
  assert string.contains(no_rows, "Relays</h2>" <> legend <> "</div>")
  assert string.contains(no_rows, add_trigger <> "</div></div>" <> no_bunker)
  let monitor_only =
    english(
      dashboard.Snapshot(
        ..states(),
        relays: Ok([
          dashboard.RelayRow(
            1,
            "wss://a",
            dashboard.Reported(relay_connection.Connected),
            dashboard.Unused,
          ),
        ]),
      ),
    )
  assert string.contains(monitor_only, "Relays</h2>" <> legend <> count_pill(1))
  assert string.contains(
    monitor_only,
    add_trigger <> "</div></div>" <> no_bunker <> "<ul",
  )
  assert !string.contains(english(states()), "No relay is used for the bunker.")
}

/// リレーの一覧を得られないときは、一覧の代わりに理由を出し、警告は出さない。日本語では
/// 前置きも出る。
pub fn unlisted_relays_show_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(..states(), relays: Error(i18n.Untranslated("boom")))
  assert string.contains(
    english(snapshot),
    "Relays</h2>"
      <> english_relays_hint_html()
      <> "</div></div>"
      <> listed_reason_html(i18n.English, i18n.CouldNotListRelays, "boom"),
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "リレー</h2>"
      <> relays_hint_html(
      i18n.Japanese,
      "監視",
      "登録アカウントのイベントを購読してプラグインに渡す",
      "バンカー",
      "NIP-46 のリクエストを受け付ける",
    )
      <> "</div></div>"
      <> listed_reason_html(i18n.Japanese, i18n.CouldNotListRelays, "boom"),
  )
}

/// `id` の ⓘ のボタンと、`content`（HTML）を包む補足の HTML。
fn hint_html(language: i18n.Language, id: String, content: String) -> String {
  view.info_hint(language, id, [html.text("@content@")])
  |> list.map(element.to_string)
  |> string.concat
  |> string.replace("@content@", content)
}

/// リレーの節の ⓘ と、監視、バンカーの順に太字の語と説明を 1 段落ずつ並べた凡例の補足の HTML。
fn relays_hint_html(
  language: i18n.Language,
  monitor: String,
  monitor_description: String,
  bunker: String,
  bunker_description: String,
) -> String {
  hint_html(
    language,
    "relays-hint",
    "<p><b class=\"font-semibold\">"
      <> monitor
      <> "</b> "
      <> monitor_description
      <> "</p><p class=\"mt-1\"><b class=\"font-semibold\">"
      <> bunker
      <> "</b> "
      <> bunker_description
      <> "</p>",
  )
}

/// 英語のリレーの節の、監視とバンカーの説明を並べた凡例の補足の HTML。
fn english_relays_hint_html() -> String {
  relays_hint_html(
    i18n.English,
    "monitor",
    "Subscribes to registered accounts&#39; events and passes them to plugins",
    "bunker",
    "Accepts NIP-46 requests",
  )
}

/// 節の格子は、1121px 以上で 1.62 対 1 の 2 列に切り替えるクラスを持つ。クラスの照合だけで、
/// 幅の切り替えそのものはブラウザーで確かめる。
pub fn dashboard_columns_split_above_1120px_test() {
  let body = english(states())
  assert string.contains(
    body,
    "min-[1121px]:grid-cols-[minmax(0,1.62fr)_minmax(0,1fr)]",
  )
}

/// 締め切りを超えた節は、上流の理由の代わりに訳した「今は取得できません。」
/// （`Not available right now.`）を出す。
pub fn a_section_past_the_deadline_says_not_available_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      relays: Error(i18n.Translated(i18n.NotAvailable)),
    )
  assert string.contains(english(snapshot), "Not available right now.")
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "今は取得できません。",
  )
}

/// 一覧を得られない節の見出しの行は、追加・接続のダイアログを開くボタンを出さない。ダイアログは
/// 一覧の有無によらず描き、アカウントの節は読み直しのフォームも出したままにする。
pub fn an_unavailable_list_keeps_its_dialog_but_not_the_open_button_test() {
  let boom = i18n.Untranslated("boom")
  let available = english(states())
  let accounts = english(dashboard.Snapshot(..states(), accounts: Error(boom)))
  let relays = english(dashboard.Snapshot(..states(), relays: Error(boom)))
  let sessions = english(dashboard.Snapshot(..states(), sessions: Error(boom)))
  assert string.contains(accounts, "/accounts/reload")
  use #(unavailable, dialog) <- list.each([
    #(accounts, "dialog-account-new"),
    #(relays, "dialog-relay-new"),
    #(sessions, "dialog-session-connect"),
  ])
  let trigger = "command=\"show-modal\" commandfor=\"" <> dialog <> "\""
  assert string.contains(available, trigger)
  assert string.contains(available, "id=\"" <> dialog <> "\"")
  assert !string.contains(unavailable, trigger)
  assert string.contains(unavailable, "id=\"" <> dialog <> "\"")
}

/// `body` の `title` の節の見出しで、題の `</h2>` の後に続く HTML。題の直後に ⓘ があれば、
/// その補足の `</div>` の後から返す。件数のピルがあれば、返す HTML の先頭に出る。
fn after_heading_title(body: String, title: String) -> String {
  let assert Ok(#(_, rest)) = string.split_once(body, title <> "</h2>")
  case string.starts_with(rest, "<button") {
    False -> rest
    True -> {
      let assert Ok(#(_, hint)) = string.split_once(rest, "popover=\"hint\">")
      let assert Ok(#(_, after_hint)) = string.split_once(hint, "</div>")
      after_hint
    }
  }
}

/// アカウント・セッション・リレーの見出しは、一覧を得て 1 件以上あるときだけ題の直後に
/// 件数のピルを出す。一覧を得られない節にはピルを出さない。
pub fn section_headings_show_the_count_pill_test() {
  let body =
    english(
      dashboard.Snapshot(
        ..states(),
        accounts: Ok([account(dialog_signer, "main")]),
      ),
    )
  assert string.starts_with(
    after_heading_title(body, "Accounts"),
    count_pill(1),
  )
  assert string.contains(
    body,
    "Relays</h2>" <> english_relays_hint_html() <> count_pill(2),
  )

  let unavailable =
    english(
      dashboard.Snapshot(
        ..states(),
        accounts: Error(i18n.Untranslated("boom")),
        sessions: Error(i18n.Untranslated("boom")),
        relays: Error(i18n.Untranslated("boom")),
      ),
    )
  list.each(["Accounts", "Approved sessions", "Relays"], fn(title) {
    assert !string.starts_with(
      after_heading_title(unavailable, title),
      count_pill_tag(),
    )
  })
}

/// 空のアカウント・セッション・プラグインの節は、件数のピルを出さず、点線の枠の中にアイコンと
/// 説明の文を置く。アカウントとセッションの枠にはそれぞれ追加と接続の枠のボタンを置き、
/// プラグインの枠にはボタンを置かない。
pub fn empty_sections_offer_their_action_in_the_frame_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([]),
      sessions: Ok([]),
      plugins: [],
    )
  let body = english(snapshot)
  assert string.contains(
    body,
    element.to_string(
      view.empty_state(
        view.users_icon(),
        "No accounts registered. Import an nsec or generate a new key.",
        [
          view.dialog_trigger(
            "dialog-account-new",
            view.IconTextFace(view.plus_icon(), "Add account"),
            view.OutlineButton,
          ),
        ],
      ),
    ),
  )
  assert string.contains(
    body,
    element.to_string(
      view.empty_state(view.clock_icon(), "No approved sessions.", [
        view.dialog_trigger(
          "dialog-session-connect",
          view.IconTextFace(view.plus_icon(), "Connect a client"),
          view.OutlineButton,
        ),
      ]),
    ),
  )
  assert string.contains(
    body,
    element.to_string(
      view.empty_state(
        view.puzzle_icon(),
        "No plugins enabled. Plugins placed in the plugin directory are loaded when the server restarts.",
        [],
      ),
    ),
  )
  use title <- list.each(["Accounts", "Approved sessions", "Plugins"])
  assert !string.starts_with(after_heading_title(body, title), count_pill_tag())
}

/// 承認ページは言語を切り替えた後に同じ承認ページを、通知ページはダッシュボードを開く。
pub fn language_switch_return_paths_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    approval(i18n.Japanese, pending),
    "<input name=\"return\" type=\"hidden\" value=\"/approve/tok\">",
  )
  assert string.contains(
    dashboard.notice_page(
      i18n.Japanese,
      view.System,
      view.SwitchReturningTo("/"),
      i18n.NotFound,
      i18n.Untranslated("unknown or expired approval request"),
      view.Failure,
      [],
    ),
    "<input name=\"return\" type=\"hidden\" value=\"/\">",
  )
}

/// ダッシュボードは承認待ちを 1 件以上得たときだけ 30 秒ごとに自動で読み込み直す。
/// 空のときと一覧を得られないときは自動更新しない。
pub fn dashboard_refreshes_only_when_pending_exists_test() {
  let with_pending = english(states())
  assert string.contains(with_pending, "http-equiv=\"refresh\"")
  assert string.contains(with_pending, "content=\"30\"")
  assert !string.contains(
    english(dashboard.Snapshot(..states(), pending: Ok([]))),
    "http-equiv=\"refresh\"",
  )
  assert !string.contains(
    english(
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    ),
    "http-equiv=\"refresh\"",
  )
}

/// 承認ページは常に 30 秒ごとに自動で読み込み直すが、その移り先の通知ページは
/// 読み込みを繰り返さない。
pub fn approval_page_refreshes_automatically_test() {
  let assert Ok([pending]) = states().pending
  let approval = approval(i18n.English, pending)
  assert string.contains(approval, "http-equiv=\"refresh\"")
  assert string.contains(approval, "content=\"30\"")
  assert !string.contains(
    dashboard.notice_page(
      i18n.English,
      view.System,
      view.SwitchReturningTo("/"),
      i18n.NotFound,
      i18n.Untranslated("gone"),
      view.Failure,
      [],
    ),
    "http-equiv=\"refresh\"",
  )
}

/// 承認待ちのカードには「失効まで」の欄が出て、残りの「分:秒」と失効の時刻を出す。承認ページも
/// 同じカードを使い、残り時間を円で描いて `aria-label` で読み上げる。
pub fn pending_shows_time_until_expiry_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    english(states()),
    "<dt class=\"text-muted\">Expires in</dt><dd>9:00 (expires at <time datetime=\"2026-09-13T05:21:34Z\">05:21:34 UTC</time>)</dd>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, states()),
    "<dt class=\"text-muted\">失効まで</dt><dd>9:00（<time datetime=\"2026-09-13T05:21:34Z\">05:21:34（UTC）</time> に失効）</dd>",
  )
  let page = approval(i18n.Japanese, pending)
  assert string.contains(
    page,
    "<dt class=\"text-muted\">失効まで</dt><dd>9:00（<time datetime=\"2026-09-13T05:21:34Z\">05:21:34（UTC）</time> に失効）</dd>",
  )
  assert string.contains(page, "pathLength=\"600\"")
  assert string.contains(page, "aria-label=\"失効まで 9:00\"")
}

/// secret が一致しないカードは、枠を warning の色にして説明の囲みを 1 つ置き、拒否を塗り、承認を
/// warning の枠の「それでも承認する」にする。並びは一致するカードと同じ承認、拒否の順で、承認ページも
/// 同じボタンを出す。
pub fn mismatched_pending_swaps_the_emphasis_but_not_the_order_test() {
  let assert Ok([not_offered, mismatched]) = secret_states().pending
  let form = fn(action, label, kind) {
    element.to_string(view.post_form(action, [], label, kind, view.InRow))
  }
  let mismatched_forms =
    form("/approve/tok-2", "Approve anyway", view.WarningOutlineButton)
    <> form("/deny/tok-2", "Deny", view.PrimaryButton)
  let offered_forms =
    form("/approve/tok-1", "Approve", view.PrimaryButton)
    <> form("/deny/tok-1", "Deny", view.GhostButton)
  let body = english(secret_states())
  assert string.contains(body, mismatched_forms)
  assert string.contains(body, offered_forms)
  assert list.length(string.split(body, "border-warning/55")) == 2
  assert list.length(string.split(
      body,
      i18n.text(i18n.English, i18n.WrongSecretNotice),
    ))
    == 2

  assert string.contains(approval(i18n.English, mismatched), mismatched_forms)
  assert string.contains(approval(i18n.English, not_offered), offered_forms)
}

/// 承認待ちの帯は、見出しに説明を付け、ダッシュボードを自動で読み込み直すとき（1 件以上）だけ
/// 更新の間隔を出す。一覧を得られないときは帯と説明に理由の囲みを添えて更新の間隔を出さず、
/// 0 件のときは帯も更新の間隔も出さない。
pub fn pending_band_shows_the_refresh_only_while_refreshing_test() {
  let band = opening_tag(view.band("pending", []))
  let description =
    "Until you approve, this client cannot request signing or encryption."
  let refresh = "Refreshes every 30 s"

  let present = english(states())
  assert string.contains(present, band)
  assert string.contains(present, description)
  assert string.contains(present, refresh)

  let unavailable =
    english(
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(unavailable, band)
  assert string.contains(unavailable, description)
  assert !string.contains(unavailable, refresh)
  assert string.contains(
    unavailable,
    listed_reason_html(i18n.English, i18n.CouldNotListPending, "boom"),
  )

  let empty = english(dashboard.Snapshot(..states(), pending: Ok([])))
  assert !string.contains(empty, band)
  assert !string.contains(empty, refresh)
}

/// 残り時間の円は、600 を満たんとする弧を残りの秒の長さで描き、60 秒未満は弧と数字を warning の
/// 色にする。残り時間は囲みの `aria-label` で読み上げる。
pub fn pending_ring_follows_the_remaining_seconds_test() {
  let body = english(secret_states())
  assert string.contains(
    body,
    "<circle class=\"fill-none stroke-6 stroke-primary\" cx=\"32\" cy=\"32\" pathLength=\"600\" r=\"28\" stroke-dasharray=\"540 600\" stroke-linecap=\"round\"></circle>",
  )
  assert string.contains(
    body,
    "<circle class=\"fill-none stroke-6 stroke-warning\" cx=\"32\" cy=\"32\" pathLength=\"600\" r=\"28\" stroke-dasharray=\"45 600\" stroke-linecap=\"round\"></circle>",
  )
  assert string.contains(body, "aria-label=\"Expires in 9:00\"")
  assert string.contains(body, "text-warning\">0:45</span>")
}

/// 承認待ちの円は、広い画面で跨ぐ行が、secret の不一致の警告の囲みがあるカードでは 3、
/// ないカードでは 2 である。
pub fn pending_ring_spans_the_rows_of_its_card_test() {
  let body = english(secret_states())
  let cards = list.drop(string.split(body, "<article "), 1)
  let assert Ok(mismatch) =
    list.find(cards, string.contains(_, "border-warning/55"))
  let assert Ok(matching) =
    list.find(cards, fn(card) { !string.contains(card, "border-warning/55") })
  assert string.contains(mismatch, "sm:size-17 sm:row-span-3\"")
  assert !string.contains(mismatch, "row-span-2")
  assert string.contains(matching, "sm:size-17 sm:row-span-2\"")
  assert !string.contains(matching, "row-span-3")
}

/// 概要の帯の項目は、5 つの節へのリンク（`href="#…"`）になっており、各節は同じアンカーの
/// `id` を持つ。
pub fn overview_rail_links_to_each_section_test() {
  let body = english(states())
  let anchors = ["pending", "accounts", "sessions", "relays", "plugins"]
  use anchor <- list.each(anchors)
  assert string.contains(body, "href=\"#" <> anchor <> "\"")
  assert string.contains(body, "id=\"" <> anchor <> "\"")
}

/// 承認待ちの項目は、1 件以上あるときだけ `primary` で塗り、狭い画面では件数によらず全幅を
/// 占める。リンクにするのは節が出るとき（1 件以上、一覧を得られないとき）で、0 件のときは
/// 節が無いのでリンクにしない。
pub fn overview_pending_is_linked_and_highlighted_only_when_pending_exists_test() {
  let anchor = "href=\"#pending\""
  let highlighted =
    "col-span-2 flex flex-col gap-0.5 bg-primary px-4 py-3.5 text-primary-content"
  let plain =
    "col-span-2 flex flex-col gap-0.5 bg-base-100 px-4 py-3.5 lg:col-span-1"
  let with_pending = english(states())
  assert string.contains(with_pending, anchor)
  assert string.contains(with_pending, highlighted)
  let empty = english(dashboard.Snapshot(..states(), pending: Ok([])))
  assert !string.contains(empty, anchor)
  assert !string.contains(empty, highlighted)
  assert string.contains(empty, plain)
  let unavailable =
    english(
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(unavailable, anchor)
}

/// 承認待ち・アカウント・セッションの一覧を得られないとき、対応する項目の値は error の色の
/// 「—」、補足は error の色の「取得できません」になる。
pub fn overview_says_not_available_when_lists_are_missing_test() {
  let unavailable =
    english(
      dashboard.Snapshot(
        ..states(),
        accounts: Error(i18n.Untranslated("boom")),
        pending: Error(i18n.Untranslated("boom")),
        sessions: Error(i18n.Untranslated("boom")),
      ),
    )
  let value =
    "<span class=\"whitespace-nowrap font-mono text-3xl font-bold leading-tight tabular-nums text-error\">—</span>"
  let note =
    element.to_string(view.status_note(
      view.ToneChip(view.Failure),
      "Not available",
    ))
  assert list.length(string.split(unavailable, value)) == 4
  assert list.length(string.split(unavailable, note)) == 4
}

/// 承認待ちのカードのクライアントは省略した表示とコピーボタンで出る。
pub fn pending_row_shows_the_client_shortened_with_a_copy_button_test() {
  let long_client = "cccc3333cccc3333cccc3333cccc3333"
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      pending: Ok([
        dashboard.PendingRow(..pending("tok"), client: long_client),
      ]),
    )
  let body = english(snapshot)
  assert string.contains(body, view.shorten(long_client))
  assert string.contains(body, "data-action=\"copy\"")
}

/// 承認待ちのカードは、64 桁の 16 進のクライアントの公開鍵なら色付きの指紋を描き、指紋を
/// 求められない値なら描かない。
pub fn pending_card_draws_the_client_fingerprint_test() {
  let client = string.repeat("0123456789abcdef", 4)
  let assert Ok(mark) = fingerprint.from_pubkey(client)
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      pending: Ok([
        dashboard.PendingRow(..pending("tok"), client:),
      ]),
    )
  assert string.contains(
    english(snapshot),
    element.to_string(fingerprint.svg(mark, fingerprint.Colored, "size-6")),
  )
  assert !string.contains(english(states()), "class=\"size-6 fp")
}

/// クライアントの公開鍵が `client` の承認済みセッション 1 件。
fn session_row(client: String) -> session.Session {
  session.Session(..session_of("abcd", client), perms: "sign_event:7")
}

/// 英語のダッシュボードのうち、セッションの節（`id="sessions"`）以降の部分。
fn sessions_part(snapshot: dashboard.Snapshot) -> String {
  let assert Ok(#(_, part)) =
    string.split_once(english(snapshot), "id=\"sessions\"")
  part
}

/// セッションの節の見出しは、題の直後の ⓘ で説明を `sessions-hint` の補足に開き、その後に件数のピルを
/// 出す。一覧を得られないときは件数を出さず、ⓘ は出す。
pub fn sessions_heading_shows_the_count_and_the_description_test() {
  let hint =
    hint_html(
      i18n.English,
      "sessions-hint",
      "Clients can request signing and encryption within the permissions shown here.",
    )
  let listed =
    sessions_part(
      dashboard.Snapshot(
        ..states(),
        sessions: Ok([session_row("ef01"), session_row("ef02")]),
      ),
    )
  assert string.contains(
    listed,
    "Approved sessions</h2>" <> hint <> count_pill(2) <> "</div>",
  )

  let unavailable =
    sessions_part(
      dashboard.Snapshot(..states(), sessions: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(
    unavailable,
    "Approved sessions</h2>" <> hint <> "</div>",
  )
}

/// セッションの行は、64 桁の 16 進のクライアントの公開鍵なら色付きの指紋を描き、指紋を求められない値なら
/// 描かない。
pub fn session_row_draws_the_client_fingerprint_test() {
  let client = string.repeat("0123456789abcdef", 4)
  let assert Ok(mark) = fingerprint.from_pubkey(client)
  assert string.contains(
    sessions_part(
      dashboard.Snapshot(..states(), sessions: Ok([session_row(client)])),
    ),
    element.to_string(fingerprint.svg(mark, fingerprint.Colored, "size-6")),
  )
  assert !string.contains(
    sessions_part(
      dashboard.Snapshot(..states(), sessions: Ok([session_row("ef01")])),
    ),
    "class=\"size-6 fp",
  )
}

/// セッションの行は、721px 以上で 3 列 2 段に組み替える格子とボタンの升の切り替えのクラスを
/// 持つ。クラスの照合だけで、幅の切り替えそのものはブラウザーで確かめる。
pub fn session_row_regroups_at_720px_test() {
  let part =
    sessions_part(
      dashboard.Snapshot(..states(), sessions: Ok([session_row("ef01")])),
    )
  use class <- list.each([
    "min-[721px]:grid-cols-[auto_minmax(0,1fr)_auto]",
    "min-[721px]:col-span-1",
    "min-[721px]:self-start",
    "min-[721px]:border-t-0",
    "min-[721px]:pt-0",
  ])
  assert string.contains(part, class)
}

/// 署名者は、アカウント一覧にあればラベルと省略した npub、無ければ省略した 16 進で出る。
/// アカウント一覧を得られないときも省略した 16 進になる。
pub fn signer_is_shown_as_label_and_npub_test() {
  let known_signer = "abcd-known-signer-0123456789"
  let unknown_signer = "unknown-signer-0123456789abcd"
  let known_account = account(known_signer, "main")
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([known_account]),
      pending: Ok([
        dashboard.PendingRow(..pending("tok-known"), signer: known_signer),
        dashboard.PendingRow(
          ..pending("tok-unknown"),
          signer: unknown_signer,
          client: "ef02",
        ),
      ]),
    )
  let body = english(snapshot)
  assert string.contains(body, "<span>main</span>")
  assert string.contains(body, view.shorten(known_account.npub))
  assert string.contains(body, view.shorten(unknown_signer))

  let unavailable =
    english(
      dashboard.Snapshot(..snapshot, accounts: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(unavailable, view.shorten(known_signer))
  assert !string.contains(unavailable, "<span>main</span>")
}

/// 承認ページには、カードの直後に承認の意味の説明が info の囲みで畳まずに出る。権限が空のときだけ、既定で
/// 許す範囲を述べる一文が続く。
pub fn approval_page_explains_what_approval_means_test() {
  let assert Ok([with_perms, without_perms]) = secret_states().pending
  let with_perms_page = approval(i18n.English, with_perms)
  assert string.contains(with_perms_page, "alert-info")
  assert string.contains(
    with_perms_page,
    "Approving lets this client request signing and encryption within the permissions above. You can change them later from the approved session.",
  )
  assert string.contains(
    with_perms_page,
    "</article>"
      <> element.to_string(
      view.alert(view.Info, [
        html.text(i18n.text(i18n.English, i18n.ApprovalExplanation)),
      ]),
    ),
  )
  assert !string.contains(with_perms_page, "<details")
  assert !string.contains(
    with_perms_page,
    "None requested. Signing any kind but 24133, and NIP-44 encryption and decryption, are allowed.",
  )

  let without_perms_page = approval(i18n.English, without_perms)
  assert string.contains(
    without_perms_page,
    "You can change them later from the approved session. None requested. Signing any kind but 24133, and NIP-44 encryption and decryption, are allowed.",
  )
}

/// 概要の帯の色の規則。一覧を得られない項目は値「—」と error の補足、要対応の語だけ状態の
/// チップの色、承認待ちが 1 件以上なら承認待ちの項目だけを塗る。
pub fn overview_color_rules_test() {
  let failure = Some(view.ToneChip(view.Failure))
  let not_available =
    dashboard.Overview(
      dashboard.NoValue,
      [dashboard.OverviewNote(failure, i18n.OverviewNotAvailable)],
      emphasis: dashboard.Linked,
    )
  let item = fn(value, notes) {
    dashboard.Overview(value, notes, emphasis: dashboard.Linked)
  }
  let plain = fn(text) { dashboard.OverviewNote(None, text) }
  let note = fn(chip, text) { dashboard.OverviewNote(Some(chip), text) }
  let reason = i18n.Untranslated("boom")
  let relays = fn(monitor, bunker) {
    dashboard.Snapshot(
      ..states(),
      relays: Ok([dashboard.RelayRow(1, "wss://a", monitor, bunker)]),
    )
  }
  let connected = dashboard.Reported(relay_connection.Connected)
  let pending = fn(rail: dashboard.OverviewRail) { rail.pending }
  let accounts = fn(rail: dashboard.OverviewRail) { rail.accounts }
  let sessions = fn(rail: dashboard.OverviewRail) { rail.sessions }
  let relay = fn(rail: dashboard.OverviewRail) { rail.relays }
  let plugins = fn(rail: dashboard.OverviewRail) { rail.plugins }
  let cases = [
    #(
      dashboard.Snapshot(..states(), pending: Error(reason)),
      pending,
      not_available,
    ),
    #(
      dashboard.Snapshot(..states(), pending: Ok([])),
      pending,
      dashboard.Overview(
        dashboard.Count(0),
        [plain(i18n.PendingExpireAfterMinutes(10))],
        emphasis: dashboard.Unlinked,
      ),
    ),
    #(
      secret_states(),
      pending,
      dashboard.Overview(
        dashboard.Count(2),
        [plain(i18n.AwaitingDecision), plain(i18n.SoonestExpiry("0:45"))],
        emphasis: dashboard.Highlighted,
      ),
    ),
    #(
      dashboard.Snapshot(..states(), accounts: Error(reason)),
      accounts,
      not_available,
    ),
    #(
      states(),
      accounts,
      item(dashboard.Count(0), [plain(i18n.AllAccountsLoaded)]),
    ),
    #(
      dashboard.Snapshot(
        ..states(),
        skipped: Ok([
          dashboard.SkippedRow(
            pubkey: "abcd1234",
            npub: Some("npub1unreadable"),
            label: "old wallet",
            reason: vault.UndecryptablePrivateKey,
          ),
        ]),
      ),
      accounts,
      item(dashboard.Count(0), [
        note(view.LoadFailedChip, i18n.UnreadableRowCount(1)),
      ]),
    ),
    #(
      dashboard.Snapshot(..states(), skipped: Error(reason)),
      accounts,
      item(dashboard.Count(0), not_available.notes),
    ),
    #(
      dashboard.Snapshot(..states(), sessions: Error(reason)),
      sessions,
      not_available,
    ),
    #(
      dashboard.Snapshot(..states(), relays: Error(reason)),
      relay,
      not_available,
    ),
    #(
      states(),
      relay,
      item(dashboard.Count(2), [
        note(view.DisconnectedChip, i18n.DisconnectedRelayCount(2)),
      ]),
    ),
    #(
      relays(dashboard.Unused, dashboard.Unanswered),
      relay,
      item(dashboard.Count(1), [
        note(view.UnansweredChip, i18n.UnansweredRelayCount(1)),
      ]),
    ),
    #(
      relays(connected, dashboard.Unused),
      relay,
      item(dashboard.Count(1), [
        note(view.ToneChip(view.Warning), i18n.NoBunkerRelayShort),
      ]),
    ),
    #(
      relays(connected, connected),
      relay,
      item(dashboard.Count(1), [plain(i18n.AllRelaysConnected)]),
    ),
    #(
      dashboard.Snapshot(..states(), not_loaded_plugins: [
        plugin_loader.NotLoaded(id: "demo_plugin", reason: "boom"),
      ]),
      plugins,
      item(dashboard.CountOfTotal(1, 4), [
        note(view.OverloadedChip, i18n.OverloadedPluginCount(1)),
        note(view.DisabledChip, i18n.DisabledPluginCount(1)),
        note(view.UnansweredChip, i18n.UnavailablePluginCount(1)),
        note(view.LoadFailedChip, i18n.PluginsNotLoadedShort(1)),
      ]),
    ),
    #(
      dashboard.Snapshot(..states(), plugins: [
        dashboard.PluginRow("a", Some(plugin_runner.Running), pages: []),
      ]),
      plugins,
      item(dashboard.CountOfTotal(1, 1), [plain(i18n.RunningOfTotal)]),
    ),
    #(
      dashboard.Snapshot(..states(), plugins: []),
      plugins,
      item(dashboard.CountOfTotal(0, 0), [plain(i18n.NoPluginsEnabledShort)]),
    ),
  ]
  use #(snapshot, pick, expected) <- list.each(cases)
  assert pick(dashboard.overview(snapshot)) == expected
}

/// 「はじめに」の帯の段の状態は、バンカーに使うリレーと読み込めたアカウントの有無から決まり、
/// 両方がそろうか、どちらかの一覧を得られないときは帯を出さない。
pub fn getting_started_follows_the_bunker_relays_and_accounts_test() {
  let account = account("abcd", "")
  let connected = dashboard.Reported(relay_connection.Connected)
  let bunker_relay =
    dashboard.RelayRow(1, "wss://a", dashboard.Unused, connected)
  let monitor_relay =
    dashboard.RelayRow(2, "wss://b", connected, dashboard.Unused)
  let reason = i18n.Untranslated("reason")
  assert dashboard.getting_started(Ok([]), Ok([]))
    == Some(dashboard.GettingStarted(bunker_relay: False, account: False))
  assert dashboard.getting_started(Ok([]), Ok([bunker_relay]))
    == Some(dashboard.GettingStarted(bunker_relay: True, account: False))
  assert dashboard.getting_started(Ok([]), Ok([monitor_relay]))
    == Some(dashboard.GettingStarted(bunker_relay: False, account: False))
  assert dashboard.getting_started(Ok([account]), Ok([monitor_relay]))
    == Some(dashboard.GettingStarted(bunker_relay: False, account: True))
  assert dashboard.getting_started(Ok([account]), Ok([bunker_relay])) == None
  assert dashboard.getting_started(Error(reason), Ok([])) == None
  assert dashboard.getting_started(Ok([]), Error(reason)) == None
}

/// 「はじめに」の帯は、まだの段に追加のダイアログを開くボタンを、済んだ段に「済み」のチップを出し、
/// 段 3 を点線の枠で出す。リレーとアカウントがそろうと帯ごと出さない。
pub fn getting_started_band_shows_done_open_and_locked_steps_test() {
  let render = fn(accounts, relays) {
    english(
      dashboard.Snapshot(..states(), accounts: Ok(accounts), relays: Ok(relays)),
    )
  }
  let opener = fn(id, label) {
    element.to_string(view.dialog_trigger(
      id,
      view.IconTextFace(view.plus_icon(), label),
      view.PrimaryButton,
    ))
  }
  let add_relay = opener("dialog-relay-new", "Add relay")
  let add_account = opener("dialog-account-new", "Add account")
  let done_chip =
    element.to_string(view.status_chip(view.ToneChip(view.Success), "Done"))
  let locked_count = fn(html) {
    list.length(string.split(
      html,
      "<li class=\"flex flex-col items-start gap-2 rounded-box border border-dashed border-field p-4\">",
    ))
    - 1
  }
  let bunker_relay =
    dashboard.RelayRow(
      1,
      "wss://a",
      dashboard.Unused,
      dashboard.Reported(relay_connection.Connected),
    )

  let nothing = render([], [])
  assert string.contains(nothing, "Getting started</h2>")
  assert string.contains(nothing, add_relay)
  assert string.contains(nothing, add_account)
  assert !string.contains(nothing, done_chip)
  assert locked_count(nothing) == 1

  let relay_only = render([], [bunker_relay])
  assert string.contains(relay_only, "Add a bunker relay</h3>" <> done_chip)
  assert !string.contains(relay_only, add_relay)
  assert string.contains(relay_only, add_account)
  assert locked_count(relay_only) == 1

  let account = account("abcd", "")
  assert !string.contains(render([account], [bunker_relay]), "Getting started")
}

/// 追加のフォームの中身は `/relays/new` へ POST し、URL の欄の補足を欄の下の 1 行で結び付ける。
/// ページの枠は含めない。
pub fn new_relay_form_describes_the_url_field_test() {
  let html =
    dashboard.new_relay_form(
      i18n.English,
      "",
      Some(dashboard.new_relay_roles),
      view.InForm,
    )
    |> element.fragment
    |> element.to_string
  assert string.contains(form_tag(html, "/relays/new\""), "method=\"post\"")
  assert string.contains(html, "aria-describedby=\"relay-url-hint\"")
  assert string.contains(html, "<p class=\"text-muted\" id=\"relay-url-hint\">")
  assert !string.contains(html, "<header")
}

/// 用途のチェックは、監視、バンカーの順に、用途ごとの欄の名前、アイコン、語、説明を持つ。
/// 用途の編集は接続状態のバッジをチェックの横に添え、追加のフォームは添えない。
pub fn relay_role_checkboxes_follow_the_role_order_test() {
  let text = i18n.text(i18n.English, _)
  let row = fn(name, icon, caption, description, checked, badge) {
    element.to_string(view.checkbox_row(
      name,
      icon,
      caption,
      html.text(text(description)),
      checked,
      badge,
    ))
  }
  let edit =
    dashboard.relay_action_form(
      i18n.English,
      dashboard.RelayRow(
        7,
        "wss://a",
        dashboard.Reported(relay_connection.Connected),
        dashboard.Unanswered,
      ),
      routes.EditRelayRoles,
      Some(relay_list.MonitorOnly),
      view.InForm,
    )
    |> element.fragment
    |> element.to_string
  assert string.contains(
    edit,
    row(
      "monitor",
      view.eye_icon(),
      "Use for monitoring",
      i18n.MonitorRoleDescription,
      True,
      [view.status_chip(view.ActiveChip, "connected")],
    )
      <> row(
      "bunker",
      view.key_icon(),
      "Use for the bunker",
      i18n.BunkerRoleDescription,
      False,
      [view.status_chip(view.UnansweredChip, "unavailable")],
    ),
  )
  let new =
    dashboard.new_relay_form(
      i18n.English,
      "",
      Some(relay_list.BunkerOnly),
      view.InForm,
    )
    |> element.fragment
    |> element.to_string
  assert string.contains(
    new,
    row(
      "monitor",
      view.eye_icon(),
      "Use for monitoring",
      i18n.MonitorRoleDescription,
      False,
      [],
    )
      <> row(
      "bunker",
      view.key_icon(),
      "Use for the bunker",
      i18n.BunkerRoleDescription,
      True,
      [],
    ),
  )
}

/// 用途の編集と削除の中身は、結果の注意の段落を畳まずにフォームの直前に出す。
pub fn relay_action_form_keeps_the_description_visible_test() {
  let edit = action_form(routes.EditRelayRoles)
  let delete = action_form(routes.DeleteRelay)
  assert string.contains(
    edit,
    "<p>"
      <> i18n.text(i18n.English, i18n.EditRelayRolesDescription)
      <> "</p><form action=\"/relays/7/edit\"",
  )
  assert string.contains(
    delete,
    "<p>"
      <> i18n.text(i18n.English, i18n.DeleteRelayDescription)
      <> "</p><form action=\"/relays/7/delete\"",
  )
  assert !string.contains(edit, "popover")
  assert !string.contains(delete, "popover")
}

/// id 7 のリレーへの `action` の英語のフォームの中身を HTML 文字列にする。
fn action_form(action: routes.RelayAction) -> String {
  dashboard.relay_action_form(
    i18n.English,
    dashboard.RelayRow(7, "wss://a", dashboard.Unused, dashboard.Unused),
    action,
    Some(relay_list.Both),
    view.InForm,
  )
  |> element.fragment
  |> element.to_string
}

/// `account("abcd", "main")` だけを署名者の候補にし、URI と署名者が空の英語の接続のフォームの中身の HTML。
fn connect_form_html() -> String {
  dashboard.connect_form(
    i18n.English,
    [account("abcd", "main")],
    "",
    "",
    view.InForm,
  )
  |> element.fragment
  |> element.to_string
}

/// アカウント 1 件（署名者 `abcd`、ラベル `main`）と、署名者 `abcd` の承認済みセッション
/// `ef01`・`ef02` を持つスナップショット。2 行は権限を変え、ダイアログのフォームの行の取り違えを
/// 見分けられるようにする。
fn session_snapshot() -> dashboard.Snapshot {
  dashboard.Snapshot(
    ..states(),
    accounts: Ok([account("abcd", "main")]),
    sessions: Ok([
      session.Session(
        ..session_of("abcd", "ef01"),
        perms: "sign_event,nip44_encrypt",
      ),
      session.Session(..session_of("abcd", "ef02"), perms: "sign_event:7"),
    ]),
  )
}

/// 描画から `<form action="<action>"` の直後から最初の `</form>` の手前まで（開始タグの残りの属性と中身）を
/// 取り出す。
fn form_html(html: String, action: String) -> String {
  let assert Ok(#(_, rest)) =
    string.split_once(html, "<form action=\"" <> action <> "\"")
  let assert Ok(#(inner, _)) = string.split_once(rest, "</form>")
  inner
}

/// 描画から、すべての `<dialog` から `</dialog>` までを除いた残り。
fn outside_dialogs(body: String) -> String {
  case string.split_once(body, "<dialog ") {
    Error(Nil) -> body
    Ok(#(before, rest)) -> {
      let assert Ok(#(_, after)) = string.split_once(rest, "</dialog>")
      before <> outside_dialogs(after)
    }
  }
}

/// ダイアログの開閉が組になっている: 表のスナップショットの描画で、各 `id` について、同じ `id` を
/// `commandfor` で指す開くボタン、閉じた `<dialog>` の開始タグ、中の閉じるボタンがある。表は
/// `states()` のアカウントとリレーの追加・行 1・2 の編集と削除、`dialog_snapshot()` の行の 4 つの
/// 操作と読み込めなかった行の削除、`session_snapshot()` の接続と各行の権限の編集・取り消しである。
pub fn dashboard_dialogs_open_from_matching_triggers_test() {
  use #(snapshot, ids) <- list.each([
    #(states(), [
      "dialog-account-new",
      "dialog-relay-new",
      "dialog-relay-1-edit",
      "dialog-relay-1-delete",
      "dialog-relay-2-edit",
      "dialog-relay-2-delete",
    ]),
    #(dialog_snapshot(), [
      "dialog-account-" <> dialog_signer <> "-label",
      "dialog-account-" <> dialog_signer <> "-private-key",
      "dialog-account-" <> dialog_signer <> "-rotate",
      "dialog-account-" <> dialog_signer <> "-delete",
      "dialog-unreadable-" <> dialog_skipped <> "-delete",
    ]),
    #(session_snapshot(), [
      "dialog-session-connect",
      "dialog-session-abcd-ef01-permissions",
      "dialog-session-abcd-ef01-revoke",
      "dialog-session-abcd-ef02-permissions",
      "dialog-session-abcd-ef02-revoke",
    ]),
  ])
  let body = english(snapshot)
  use id <- list.each(ids)
  assert string.contains(
    body,
    "command=\"show-modal\" commandfor=\"" <> id <> "\"",
  )
  assert string.contains(
    body,
    "<dialog aria-labelledby=\""
      <> id
      <> "-title\" class=\"modal\" id=\""
      <> id
      <> "\">",
  )
  assert string.contains(
    closed_dialog(body, id),
    "command=\"close\" commandfor=\"" <> id <> "\"",
  )
}

/// 取り消しのダイアログのフォームは `/sessions/revoke` へ POST し、署名者の隠し欄を持つ。
pub fn revoke_dialog_posts_the_signer_test() {
  let body = english(session_snapshot())
  let revoke = closed_dialog(body, "dialog-session-abcd-ef01-revoke")
  assert string.contains(
    form_tag(revoke, "/sessions/revoke\""),
    "method=\"post\"",
  )
  assert string.contains(
    form_html(revoke, "/sessions/revoke"),
    element.to_string(view.hidden_input(dashboard.signer_field, "abcd")),
  )
}

/// 承認の取り消しのフォームはダイアログの中にだけあり、送信は warning の枠のボタンである。
pub fn session_rows_revoke_only_from_the_dialog_test() {
  let body = english(session_snapshot())
  assert !string.contains(outside_dialogs(body), "action=\"/sessions/revoke\"")
  assert string.contains(
    closed_dialog(body, "dialog-session-abcd-ef01-revoke"),
    "btn btn-outline btn-warning",
  )
}

/// 接続の中身は、アカウントが 0 件なら登録への案内、得られなければ理由、得られればフォームを出す。
pub fn connect_content_follows_the_accounts_state_test() {
  let content = fn(accounts) {
    dashboard.connect_content(i18n.English, accounts, "", "", view.InForm)
    |> element.fragment
    |> element.to_string
  }
  let empty = content(Ok([]))
  assert string.contains(
    empty,
    "Register an account before connecting a client.",
  )
  assert !string.contains(empty, "/accounts/new")
  assert !string.contains(empty, "<form")
  let failed = content(Error(i18n.Untranslated("boom")))
  assert string.contains(failed, "<span lang=\"en\">boom</span>")
  assert !string.contains(failed, "<form")
  assert string.contains(
    content(Ok([account("abcd", "main")])),
    "<form action=\"/sessions/connect\"",
  )
}

/// 権限が `perms` のセッションで、英語の権限の編集フォームの中身を HTML 文字列にする。
fn english_permissions_form(perms: String) -> String {
  let session =
    session.Session(
      ..session_of("0123", "4567"),
      perms:,
      created_at: 0,
      last_used_at: 0,
    )
  dashboard.permissions_form(i18n.English, session, None, view.InForm)
  |> element.fragment
  |> element.to_string
}

/// フォームの中身はセッションの権限のパスへ POST し、保存済みの kind を欄に出す。ページの枠と
/// 要約は含めない。
pub fn permissions_form_posts_without_the_page_frame_test() {
  let html = english_permissions_form("sign_event:1")
  assert string.contains(
    form_tag(html, "/sessions/0123/4567/permissions\""),
    "method=\"post\"",
  )
  assert string.contains(html, "value=\"1\"")
  assert !string.contains(html, "<header")
}

/// kind の欄の補足は ⓘ のボタンで開く `popover` の段落で、欄の説明として結び付く。
pub fn permissions_form_opens_the_kinds_hint_from_the_info_button_test() {
  let html = english_permissions_form("sign_event:1")
  assert string.contains(
    html,
    "aria-describedby=\"dialog-session-0123-4567-permissions-kinds-hint\"",
  )
  assert string.contains(
    html,
    "popovertarget=\"dialog-session-0123-4567-permissions-kinds-hint\"",
  )
  assert string.contains(
    html,
    "id=\"dialog-session-0123-4567-permissions-kinds-hint\" popover=\"hint\"",
  )
}

/// 保存済みの `perms` は 3 つのチェック、kind の欄、「そのほかの宣言」に分けて欄に写す。
/// kind の欄と「そのほかの宣言」は、並びの順と重複を保存済みのまま残す。
pub fn permissions_form_splits_the_saved_perms_test() {
  let html =
    english_permissions_form(
      "sign_event:-1,nip44_decrypt,sign_event:0,get_public_key,sign_event:7,sign_event:0",
    )
  assert !checkbox_checked(html, "sign_event")
  assert !checkbox_checked(html, "nip44_encrypt")
  assert checkbox_checked(html, "nip44_decrypt")
  assert string.contains(html, "name=\"kinds\" value=\"0,7,0\"")
  assert string.contains(
    html,
    "<input name=\"other\" type=\"hidden\" value=\"sign_event:-1,get_public_key\">",
  )
}

/// `sign_event:01` のような 0 埋めの kind の署名は kind の欄に移さず、「そのほかの宣言」の
/// 隠し欄に綴りのまま残す（kind の欄に写して保存し直すと `sign_event:1` になり許可が広がる）。
pub fn permissions_form_keeps_a_padded_kind_as_another_declaration_test() {
  let html = english_permissions_form("sign_event:01")
  assert string.contains(
    html,
    "<input name=\"other\" type=\"hidden\" value=\"sign_event:01\">",
  )
  assert !string.contains(html, "value=\"1\"")
}

/// 接続のフォームの中身は `/sessions/connect` へ POST し、URI の欄の補足を欄の下の 1 行で
/// 結び付ける。ページの枠は含めない。
pub fn connect_form_describes_the_uri_field_test() {
  let html = connect_form_html()
  assert string.contains(
    form_tag(html, "/sessions/connect\""),
    "method=\"post\"",
  )
  assert string.contains(html, "aria-describedby=\"nostrconnect-uri-hint\"")
  assert string.contains(
    html,
    "<p class=\"text-muted\" id=\"nostrconnect-uri-hint\">",
  )
  assert !string.contains(html, "<header")
}

/// `render_open` は指定したダイアログだけを `open` で描き、先頭に理由を、欄に送られた用途を出し、
/// キャンセルを `/` へのリンクにする。承認待ちがあっても自動で読み込み直さず、更新の間隔も出さない。
pub fn render_open_opens_only_the_named_relay_dialog_test() {
  let assert Ok(body) =
    dashboard.render_open(
      i18n.English,
      view.System,
      states(),
      dashboard.RelayActionOpen(
        1,
        routes.EditRelayRoles,
        None,
        i18n.Translated(i18n.RelayRoleRequired),
      ),
    )
  assert list.length(string.split(body, "\" open>")) - 1 == 1
  let assert Ok(#(_, rest)) =
    string.split_once(body, "class=\"modal\" id=\"dialog-relay-1-edit\" open>")
  let assert Ok(#(dialog, _)) = string.split_once(rest, "</dialog>")
  assert string.contains(
    dialog,
    i18n.text(i18n.English, i18n.RelayRoleRequired),
  )
  assert !string.contains(dialog, "checked class=\"checkbox")
  // 行の開始タグを除いた、キャンセルのリンクと行の閉じタグ
  let assert Ok(#(_, cancel)) =
    string.split_once(
      dismiss_row("dialog-relay-1-edit", "Cancel", view.OpenedByResponse),
      ">",
    )
  assert string.contains(dialog, cancel)
  assert !string.contains(body, "http-equiv=\"refresh\"")
  assert !string.contains(
    body,
    i18n.text(i18n.English, i18n.RefreshesEverySeconds(30)),
  )
  assert string.contains(english(states()), "http-equiv=\"refresh\"")
}

/// アカウントへの操作のダイアログは、操作ごとの題と、失敗の理由の前置きを持つ。前置きの無い
/// 秘密鍵の表示は理由だけを出す。読み込めなかった行の削除のダイアログの題は、アカウントの削除と
/// 同じである。
pub fn account_action_dialogs_carry_their_title_and_failure_lead_test() {
  let reason = i18n.Untranslated("boom")
  let boom = "<span lang=\"en\">boom</span>"
  let open = fn(dialog) {
    let assert Ok(body) =
      dashboard.render_open(
        i18n.Japanese,
        view.System,
        dialog_snapshot(),
        dialog,
      )
    body
  }
  use #(action, segment, title, lead) <- list.each([
    #(routes.EditLabel, "label", "ラベルを編集", "ラベルを保存できませんでした。"),
    #(routes.RevealPrivateKey, "private-key", "秘密鍵を表示", ""),
    #(routes.RotateSecret, "rotate", "secret を再生成", "secret を再生成できませんでした。"),
    #(routes.DeleteAccount, "delete", "アカウントを削除", "アカウントを削除できませんでした。"),
  ])
  let id = "dialog-account-" <> dialog_signer <> "-" <> segment
  let dialog =
    opened_dialog(
      open(dashboard.AccountActionOpen(dialog_signer, action, None, reason)),
      id,
    )
  assert string.contains(
    dialog,
    "id=\"" <> id <> "-title\">" <> title <> "</h2>",
  )
  assert string.contains(dialog, lead <> boom)
  assert lead != "" || !string.contains(dialog, "できませんでした。" <> boom)

  let unreadable_id = "dialog-unreadable-" <> dialog_skipped <> "-delete"
  let unreadable =
    opened_dialog(
      open(dashboard.UnreadableDeleteOpen(dialog_skipped, reason)),
      unreadable_id,
    )
  assert string.contains(
    unreadable,
    "id=\"" <> unreadable_id <> "-title\">アカウントを削除</h2>",
  )
  assert string.contains(unreadable, "アカウントを削除できませんでした。" <> boom)
}

/// リレーへの操作のダイアログは、操作ごとの題と、失敗の理由の前置きを持つ。
pub fn relay_action_dialogs_carry_their_title_and_failure_lead_test() {
  let boom = "<span lang=\"en\">boom</span>"
  use #(action, segment, title, lead) <- list.each([
    #(routes.EditRelayRoles, "edit", "用途を編集", "用途を保存できませんでした。"),
    #(routes.DeleteRelay, "delete", "リレーを削除", "リレーを削除できませんでした。"),
  ])
  let id = "dialog-relay-1-" <> segment
  let assert Ok(body) =
    dashboard.render_open(
      i18n.Japanese,
      view.System,
      states(),
      dashboard.RelayActionOpen(1, action, None, i18n.Untranslated("boom")),
    )
  let dialog = opened_dialog(body, id)
  assert string.contains(
    dialog,
    "id=\"" <> id <> "-title\">" <> title <> "</h2>",
  )
  assert string.contains(dialog, lead <> boom)
}

/// 追加のダイアログを開いて描くときは、送られた URL と用途を欄に出す。
pub fn render_open_echoes_the_new_relay_form_test() {
  let assert Ok(body) =
    dashboard.render_open(
      i18n.English,
      view.System,
      states(),
      dashboard.NewRelayOpen(
        "wss://typed.example",
        Some(relay_list.MonitorOnly),
        i18n.Translated(i18n.InvalidRelayUrl),
      ),
    )
  let assert Ok(#(_, rest)) =
    string.split_once(body, "class=\"modal\" id=\"dialog-relay-new\" open>")
  let assert Ok(#(dialog, _)) = string.split_once(rest, "</dialog>")
  assert string.contains(dialog, i18n.text(i18n.English, i18n.InvalidRelayUrl))
  assert string.contains(dialog, "value=\"wss://typed.example\"")
  assert checkbox_checked(dialog, "monitor")
}

/// `render_open` は、リレーの一覧を得られなければその理由を、操作するリレーが一覧に無ければ
/// `RelayNotFound` を `Error` で返す。
pub fn render_open_needs_the_relay_list_test() {
  let reason = i18n.Untranslated("boom")
  let unlisted = dashboard.Snapshot(..states(), relays: Error(reason))
  let delete = fn(id) {
    dashboard.RelayActionOpen(
      id,
      routes.DeleteRelay,
      None,
      i18n.Translated(i18n.RelayRoleRequired),
    )
  }
  let assert Ok(body) =
    dashboard.render_open(
      i18n.English,
      view.System,
      unlisted,
      dashboard.NewRelayOpen("", Some(relay_list.BunkerOnly), reason),
    )
  assert string.contains(body, "class=\"modal\" id=\"dialog-relay-new\" open>")
  assert dashboard.render_open(i18n.English, view.System, unlisted, delete(1))
    == Error(reason)
  assert dashboard.render_open(i18n.English, view.System, states(), delete(99))
    == Error(i18n.Translated(i18n.RelayNotFound))
}

/// `picture` のある行は、鍵の指紋の上に、読めるまで透明な `<img data-avatar>` を重ねる。
pub fn account_row_overlays_the_picture_on_the_fingerprint_test() {
  let account =
    dashboard.AccountRow(
      ..account(dialog_signer, "main"),
      picture: Some("https://example.com/a.png"),
    )
  let #(before, _details) =
    split_account_details(english(
      dashboard.Snapshot(..states(), accounts: Ok([account])),
    ))
  assert string.contains(
    before,
    element.to_string(fingerprint.pubkey_svg(
      account.signer,
      fingerprint.Colored,
      "size-10",
    )),
  )
  assert string.contains(
    before,
    "<img alt class=\"absolute inset-0 size-10 rounded-field object-cover border border-base-300 opacity-0 data-loaded:opacity-100\" data-avatar decoding=\"async\" height=\"40\" referrerpolicy=\"no-referrer\" src=\"https://example.com/a.png\" width=\"40\">",
  )
}

/// `picture` の無い行は `<img>` を描かず、鍵の指紋だけになる。
pub fn account_row_without_a_picture_draws_no_image_test() {
  let #(before, _details) =
    split_account_details(english(
      dashboard.Snapshot(
        ..states(),
        accounts: Ok([account(dialog_signer, "main")]),
      ),
    ))
  assert !string.contains(before, "<img")
}

/// 署名者の選択欄には、ラベルと省略した npub を並べて出す。
pub fn connect_form_lists_accounts_with_the_shortened_npub_test() {
  let html = connect_form_html()
  assert string.contains(
    html,
    "main " <> view.shorten(account("abcd", "main").npub) <> "</option>",
  )
}

/// 送られた URI と署名者と理由で開く接続のダイアログは、先頭に理由を出し、URI を欄に戻す。
pub fn connect_dialog_opens_with_the_submitted_values_test() {
  let assert Ok(body) =
    dashboard.render_open(
      i18n.English,
      view.System,
      session_snapshot(),
      dashboard.ConnectOpen(
        uri: "not-a-uri",
        signer: "abcd",
        error: Some(i18n.Translated(i18n.NotNostrconnectUri)),
      ),
    )
  let assert [#("dialog-session-connect", dialog)] = opened_dialogs(body)
  assert string.contains(
    dialog,
    i18n.text(i18n.English, i18n.NotNostrconnectUri),
  )
  assert string.contains(dialog, ">not-a-uri</textarea>")
}

/// 確認のダイアログは開くときだけ描き、閉じた状態では描かない。
pub fn connect_review_dialog_is_drawn_only_when_opened_test() {
  assert !string.contains(
    english(session_snapshot()),
    "dialog-session-connect-review",
  )
}

/// 確認のダイアログに渡す内容。名前と権限があり、リレーは 2 件。署名者は `session_snapshot` の
/// アカウントと同じ `abcd`。
fn review() -> dashboard.ConnectReview {
  dashboard.ConnectReview(
    uri: "nostrconnect://abcd?relay=wss%3A%2F%2Ffirst.example&relay=wss%3A%2F%2Fsecond.example&secret=s",
    signer: "abcd",
    client: "1111111111111111111111111111111111111111111111111111111111111111",
    client_name: Some("example"),
    perms: "sign_event:1",
    relays: ["wss://first.example", "wss://second.example"],
  )
}

/// `review` と `error` で確認のダイアログを開いた英語のダッシュボードから、唯一の開いたダイアログの
/// 中身を取り出す。
fn review_dialog(
  review: dashboard.ConnectReview,
  error: Option(i18n.Reason),
) -> String {
  let assert Ok(body) =
    dashboard.render_open(
      i18n.English,
      view.System,
      session_snapshot(),
      dashboard.ConnectReviewOpen(review:, error:),
    )
  let assert [#("dialog-session-connect-review", dialog)] = opened_dialogs(body)
  dialog
}

/// URI のリレーは URI に現れた順に 1 行ずつ並び、URI と署名者は隠し欄で確認のパスへ送り直す。
pub fn connect_review_dialog_lists_the_relays_in_order_test() {
  let dialog = review_dialog(review(), None)
  assert string.contains(
    dialog,
    "<li class=\"font-mono text-xs break-all\">wss://first.example</li><li class=\"font-mono text-xs break-all\">wss://second.example</li>",
  )
  assert string.contains(dialog, "<form action=\"/sessions/connect/confirm\"")
  assert string.contains(
    dialog,
    "<input name=\"uri\" type=\"hidden\" value=\""
      <> string.replace(review().uri, "&", "&amp;")
      <> "\">",
  )
  assert string.contains(
    dialog,
    "<input name=\"signer\" type=\"hidden\" value=\"abcd\">",
  )
}

/// 名乗る名前の行は、名前があるときだけ出す。
pub fn connect_review_dialog_shows_the_name_only_when_given_test() {
  let label = i18n.text(i18n.English, i18n.ClientName)
  let named = review_dialog(review(), None)
  assert string.contains(named, label)
  assert string.contains(named, "<dd class=\"break-words\">example</dd>")
  let unnamed =
    review_dialog(dashboard.ConnectReview(..review(), client_name: None), None)
  assert !string.contains(unnamed, label)
}

/// 権限が空のときだけ、許す操作の一文を説明に続ける。
pub fn connect_review_dialog_explains_empty_permissions_test() {
  let sentence = i18n.text(i18n.English, i18n.NoPermissionsRequested)
  assert !string.contains(review_dialog(review(), None), sentence)
  assert string.contains(
    review_dialog(dashboard.ConnectReview(..review(), perms: ""), None),
    sentence,
  )
}

/// 接続の段で失敗したときは、確認のダイアログの先頭に理由を出す。
pub fn connect_review_dialog_shows_the_failure_test() {
  let reason = i18n.text(i18n.English, i18n.NostrconnectRelayNotConnected)
  let failed =
    review_dialog(
      review(),
      Some(i18n.Translated(i18n.NostrconnectRelayNotConnected)),
    )
  assert string.contains(failed, reason)
  assert string.contains(failed, "role=\"alert\"")
  assert !string.contains(review_dialog(review(), None), reason)
}

/// 権限の編集のダイアログは、`PermissionsOpen` と一致する行のものだけを、送られた欄の状態と先頭の理由で
/// 開く。
pub fn permissions_dialog_opens_for_the_matching_row_test() {
  let assert Ok(body) =
    dashboard.render_open(
      i18n.English,
      view.System,
      session_snapshot(),
      dashboard.PermissionsOpen(
        signer: "abcd",
        client: "ef02",
        form: dashboard.PermissionsForm(
          sign_event: True,
          nip44_encrypt: False,
          nip44_decrypt: False,
          kinds: "abc",
          other: "",
        ),
        error: i18n.Translated(i18n.InvalidKindList),
      ),
    )
  let assert [#("dialog-session-abcd-ef02-permissions", dialog)] =
    opened_dialogs(body)
  assert string.contains(dialog, "value=\"abc\"")
  assert string.contains(dialog, i18n.text(i18n.English, i18n.InvalidKindList))
}
