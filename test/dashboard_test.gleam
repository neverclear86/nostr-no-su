//// 管理 UI のパスの定義と、状態の見せ方（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/permission_view
import nostr_no_su/admin/view
import nostr_no_su/admin/wordmark
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import support/account_actions

/// 操作のパスは、どの操作でもパスセグメントから同じ署名者と操作に戻る。
pub fn account_action_paths_round_trip_test() {
  use action <- list.each(account_actions.all)
  let assert "/" <> path = dashboard.account_action_path("abcd", action)
  assert dashboard.parse_account_action_path(string.split(path, "/"))
    == Ok(#("abcd", action))
}

/// 知らない操作のセグメントと、アカウントのページ以外のパスは操作にならない。
pub fn unknown_account_action_paths_are_rejected_test() {
  assert dashboard.parse_account_action_path(["accounts", "abcd", "nope"])
    == Error(Nil)
  assert dashboard.parse_account_action_path(["sessions", "abcd", "delete"])
    == Error(Nil)
  assert dashboard.parse_account_action_path(dashboard.new_account_segments)
    == Error(Nil)
}

/// プラグインのページへのリンク（`plugin_page_href`）を `/` で分けて解析すると、
/// 元のプラグイン名とページのキーに戻る。名前に空白、`/`、非 ASCII を含んでいてもよい。
pub fn plugin_page_path_round_trips_test() {
  use #(name, key) <- list.each([
    #("console_logger", "status"),
    #("a b", "status"),
    #("a/b", "status"),
    #("★", "status"),
  ])
  let assert "/" <> path = dashboard.plugin_page_href(name, key)
  assert dashboard.parse_plugin_page_path(string.split(path, "/"))
    == Ok(#(name, key))
}

/// プラグインの再有効化のパス、2 セグメントのパス、percent-decode に失敗する名前は
/// プラグインのページのパスにならない。
pub fn plugin_page_path_rejects_other_paths_test() {
  assert dashboard.parse_plugin_page_path(dashboard.reenable_plugin_segments)
    == Error(Nil)
  assert dashboard.parse_plugin_page_path(["plugins", "console_logger"])
    == Error(Nil)
  assert dashboard.parse_plugin_page_path(["plugins", "%ZZ", "status"])
    == Error(Nil)
}

/// リレーとプラグインのすべての状態と、承認待ち 1 件を持つスナップショット。
fn states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    accounts: Ok([]),
    skipped: Ok([]),
    pending: Ok([
      dashboard.PendingRow(
        token: "tok",
        signer: "abcd",
        client: "ef01",
        expires_in_seconds: 540,
        secret_mismatch: False,
        perms: "",
      ),
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

/// 提示なしと不一致の承認待ちを、失効までが長い順（作成の新しい順）に持つスナップショット。
/// 提示なしの方(`tok-1`) は権限を要求し、不一致の方（`tok-2`）は権限を要求しない。`tok-2`
/// は残り 60 秒未満で、警告のバッジを見るためのものである。
fn secret_states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    ..states(),
    pending: Ok([
      dashboard.PendingRow(
        token: "tok-1",
        signer: "abcd",
        client: "ef01",
        expires_in_seconds: 540,
        secret_mismatch: False,
        perms: "sign_event:1,nip44_encrypt",
      ),
      dashboard.PendingRow(
        token: "tok-2",
        signer: "abcd",
        client: "ef01",
        expires_in_seconds: 45,
        secret_mismatch: True,
        perms: "",
      ),
    ]),
  )
}

/// リレーとプラグインの状態は、状態ごとの色のバッジで出し、状態の語と詳細を文字で残す。
/// プラグイン由来の理由は英語のまま `lang="en"` を付けて出す。
pub fn states_are_shown_as_badges_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  let badges = [
    "<span class=\"whitespace-nowrap\">monitor</span>",
    element.to_string(view.status_chip(view.ActiveChip, "connected")),
    element.to_string(view.status_chip(view.DisconnectedChip, "disconnected")),
    element.to_string(view.status_chip(view.ActiveChip, "running")),
    element.to_string(view.status_chip(view.OverloadedChip, "overloaded"))
      <> "<span class=\"text-xs break-words\">(dropped 4)</span>",
    element.to_string(view.status_chip(view.DisabledChip, "disabled"))
      <> "<span class=\"text-xs break-words\"><span lang=\"en\">boom</span> (dropped 2)</span>",
    element.to_string(view.status_chip(view.UnansweredChip, "unavailable")),
    "<dd><span>540s</span></dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 日本語のダッシュボードでは、状態の語、件数、残り秒を日本語の形で出す。バッジの
/// クラスは英語と同じである。
pub fn japanese_states_are_translated_test() {
  let body = dashboard.render(i18n.Japanese, view.System, states())
  let badges = [
    "<span class=\"whitespace-nowrap\">監視</span>",
    "<span class=\"whitespace-nowrap\">バンカー</span>",
    element.to_string(view.status_chip(view.ActiveChip, "接続中")),
    element.to_string(view.status_chip(view.DisconnectedChip, "未接続")),
    element.to_string(view.status_chip(view.ActiveChip, "動作中")),
    element.to_string(view.status_chip(view.OverloadedChip, "過負荷"))
      <> "<span class=\"text-xs break-words\">（破棄 4 件）</span>",
    element.to_string(view.status_chip(view.DisabledChip, "無効"))
      <> "<span class=\"text-xs break-words\"><span lang=\"en\">boom</span>（破棄 2 件）</span>",
    element.to_string(view.status_chip(view.UnansweredChip, "応答なし")),
    "<dd><span>540 秒</span></dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 提示なしの承認待ちは secret のバッジが「Secret not offered」、不一致は警告色の
/// 「Secret mismatch」になる。日本語ではそれぞれ「secret 提示なし」「secret 不一致」に
/// なる。
pub fn secret_state_is_shown_as_a_badge_test() {
  let english = dashboard.render(i18n.English, view.System, secret_states())
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

/// secret が一致しない承認待ちの承認ページにだけ警告が出て、提示が無い承認待ちの承認
/// ページとダッシュボードの行には出ない。
pub fn wrong_secret_warning_is_shown_only_on_mismatched_approval_page_test() {
  let assert Ok([not_offered, mismatched]) = secret_states().pending

  assert string.contains(
    dashboard.approval_page(i18n.English, view.System, Ok([]), mismatched),
    "<div class=\"alert alert-soft alert-warning text-base-content\">"
      <> element.to_string(view.tone_icon(view.Warning))
      <> "<span><strong>The connection secret does not match.</strong> This happens when",
  )
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, Ok([]), mismatched),
    "<div class=\"alert alert-soft alert-warning text-base-content\">"
      <> element.to_string(view.tone_icon(view.Warning))
      <> "<span><strong>接続 secret が一致しません。</strong>secret を再生成する前の",
  )

  assert !string.contains(
    dashboard.approval_page(i18n.English, view.System, Ok([]), not_offered),
    "alert-warning",
  )
  assert !string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, Ok([]), not_offered),
    "alert-warning",
  )

  assert !string.contains(
    dashboard.render(i18n.English, view.System, secret_states()),
    "The connection secret does not match.",
  )
  assert !string.contains(
    dashboard.render(i18n.Japanese, view.System, secret_states()),
    "接続 secret が一致しません。",
  )
}

/// 要求された権限は、承認待ちの行と承認ページの両方でチップになる。空なら「権限の
/// 要求なし」のバッジ 1 つを出す。
pub fn permissions_are_shown_as_chips_test() {
  let assert Ok([offered, not_requested]) = secret_states().pending
  let chips =
    element.to_string(permission_view.chips(
      i18n.English,
      "sign_event:1,nip44_encrypt",
    ))
  assert string.contains(
    dashboard.render(i18n.English, view.System, secret_states()),
    chips,
  )
  assert string.contains(
    dashboard.approval_page(i18n.English, view.System, Ok([]), offered),
    chips,
  )

  let no_perms_badge =
    element.to_string(view.status_chip(
      view.ToneChip(view.Neutral),
      "No permissions requested",
    ))
  assert string.contains(
    dashboard.render(i18n.English, view.System, secret_states()),
    no_perms_badge,
  )
  assert string.contains(
    dashboard.approval_page(i18n.English, view.System, Ok([]), not_requested),
    no_perms_badge,
  )
}

/// アカウントの行の畳みには、接続 URI と公開鍵の 3 つの欄が出て、16 進の署名者が
/// `<details>` の外（畳みを開く前に見える範囲）には出ない。
pub fn account_row_hides_the_hex_pubkey_in_the_details_test() {
  let account =
    dashboard.AccountRow(
      signer: "abcdhex1234567890abcdef1234567890",
      npub: "npub1examplenpubvalueabcdefghijklmno",
      label: "main account",
      uri: "bunker://x?secret=s",
      auth_uri: "bunker://x",
    )
  let snapshot = dashboard.Snapshot(..states(), accounts: Ok([account]))
  let body = dashboard.render(i18n.English, view.System, snapshot)
  let assert Ok(#(_, after_accounts)) =
    string.split_once(body, "id=\"accounts\"")
  let assert Ok(#(before_details, after_details)) =
    string.split_once(after_accounts, "<details>")
  assert !string.contains(before_details, account.signer)
  assert string.contains(after_details, "Connection URIs and public key")
  assert string.contains(after_details, "Connection URI</span>")
  assert string.contains(after_details, "Connection URI (approval)</span>")
  assert string.contains(after_details, "Public key (hex)</span>")
  assert string.contains(after_details, account.signer)
}

/// アカウントの行の 5 つの操作はアイコン付きのボタンで、削除だけ短い語（`Delete`。
/// `Delete account` は出ない）で `text-error` が付く。
pub fn account_row_actions_are_icons_with_short_delete_test() {
  let account =
    dashboard.AccountRow(
      signer: "abcd",
      npub: "npub1x",
      label: "main",
      uri: "bunker://x",
      auth_uri: "bunker://x",
    )
  let snapshot = dashboard.Snapshot(..states(), accounts: Ok([account]))
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(
    body,
    element.to_string(view.icon_button_link(
      "/accounts/abcd/label",
      view.pencil_icon(),
      "Edit label",
      view.GhostButton,
    )),
  )
  assert string.contains(
    body,
    element.to_string(view.icon_button_link(
      "/accounts/abcd/private-key",
      view.eye_icon(),
      "Show private key",
      view.GhostButton,
    )),
  )
  assert string.contains(
    body,
    element.to_string(view.icon_button_link(
      "/accounts/abcd/rotate",
      view.rotate_icon(),
      "Rotate secret",
      view.GhostButton,
    )),
  )
  assert string.contains(
    body,
    element.to_string(view.icon_button_link(
      "/accounts/abcd/delete",
      view.trash_icon(),
      "Delete",
      view.DangerGhostButton,
    )),
  )
  assert !string.contains(body, "Delete account")
}

/// セッションの行は、権限をチップで出す。
pub fn sessions_show_perms_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "abcd",
          client: "ef01",
          perms: "sign_event:7",
          created_at: 1_788_253_200,
          last_used_at: 1_789_276_354,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(
    body,
    "<dt class=\"text-muted\">Permissions</dt><dd>"
      <> element.to_string(permission_view.chips(i18n.English, "sign_event:7"))
      <> "</dd>",
  )
}

/// 権限が空のとき、セッションの行は「権限の要求なし」のバッジを出す。
pub fn empty_session_perms_say_signing_and_encryption_are_refused_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "abcd",
          client: "ef01",
          perms: "",
          created_at: 1_788_253_200,
          last_used_at: 1_789_276_354,
        ),
      ]),
    )

  let assert Ok(#(_, sessions)) =
    string.split_once(
      dashboard.render(i18n.English, view.System, snapshot),
      "Approved sessions",
    )
  assert string.contains(
    sessions,
    "<dt class=\"text-muted\">Permissions</dt><dd>"
      <> element.to_string(view.status_chip(
      view.ToneChip(view.Neutral),
      "No permissions requested",
    ))
      <> "</dd>",
  )
}

/// ページを供給するプラグインの行にだけ、ページを開くリンクが出る。
pub fn only_plugins_with_a_page_have_a_link_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(body, dashboard.plugin_page_href("a", "status"))
  assert !string.contains(body, "/plugins/b/")
  assert !string.contains(body, "/plugins/c/")
  assert !string.contains(body, "/plugins/d/")
}

/// 無効になったプラグインの行にだけ再有効化のフォームが付き、プラグイン名を
/// hidden 欄で送る。
pub fn only_disabled_plugins_have_a_reenable_button_test() {
  let body = dashboard.render(i18n.English, view.System, states())
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

/// 読み込めなかったプラグインは、「読み込み失敗」のチップと識別子と理由つきでカードに出る。理由は英語のまま
/// `lang="en"` で包む。
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
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(english, "Plugins that failed to load")
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

/// `not_loaded_plugins` が 0 件のときはカードごと出さない。
pub fn dashboard_hides_not_loaded_plugins_when_empty_test() {
  let snapshot = dashboard.Snapshot(..states(), not_loaded_plugins: [])
  use language <- list.each([i18n.English, i18n.Japanese])
  assert !string.contains(
    dashboard.render(language, view.System, snapshot),
    "Plugins that failed to load",
  )
}

/// テーマの切り替えは `join` の枠にアイコンだけのボタンを `themes` の順に並べ、語を
/// `aria-label` と `title` に出す。表示中のテーマのボタンだけが `aria-pressed="true"` である。
pub fn navbar_theme_switch_presses_the_current_theme_test() {
  let snapshot = dashboard.Snapshot(..states(), plugins: [], relays: Ok([]))
  use language <- list.each(i18n.languages)
  use current <- list.each(view.themes)
  let body = dashboard.render(language, current, snapshot)
  assert string.contains(
    body,
    "<div aria-label=\""
      <> i18n.text(language, i18n.ThemeSwitchLabel)
      <> "\" class=\"join\" role=\"group\">",
  )
  use theme <- list.each(view.themes)
  let label = i18n.text(language, theme_message(theme))
  assert string.contains(
    body,
    "<button aria-label=\""
      <> label
      <> "\" "
      <> pressed_attributes(theme == current)
      <> " name=\"theme\" title=\""
      <> label
      <> "\" type=\"submit\" value=\""
      <> view.theme_code(theme)
      <> "\">",
  )
}

/// 上部のロゴは、製品名の字形、読み上げ用の製品名、表示の言語の副題を、ダッシュボードへの
/// 1 つのリンクに入れる。
pub fn brand_link_shows_the_wordmark_and_subtitle_test() {
  use #(language, subtitle) <- list.each([
    #(i18n.English, ">Admin</span>"),
    #(i18n.Japanese, ">管理画面</span>"),
  ])
  let assert Ok(#(_, rest)) =
    string.split_once(dashboard.render(language, view.System, states()), "<a ")
  let assert Ok(#(link, _)) = string.split_once(rest, "</a>")
  assert string.contains(link, "href=\"/\"")
  assert string.contains(
    link,
    "aria-hidden=\"true\" class=\"h-4 w-auto\" viewBox=\""
      <> wordmark.view_box
      <> "\"",
  )
  assert string.contains(link, "<span class=\"sr-only\">Nostr-no-Su</span>")
  assert string.contains(link, subtitle)
}

/// 製品名の「Nostr」と「Su」は文字の色、「-no-」は primary の色で塗る。
pub fn wordmark_colors_follow_the_theme_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "<path class=\"fill-base-content\" d=\""
      <> wordmark.heavy_path
      <> "\"></path><path class=\"fill-primary\" d=\""
      <> wordmark.medium_path
      <> "\"></path>",
  )
}

/// 言語の切り替えは `join` の枠の先頭にブラウザーの設定の押していないボタンを置き、続けて
/// 言語名をその言語自身で書いたボタンを並べる。表示している言語のボタンだけが
/// `aria-pressed="true"` である。
pub fn navbar_language_switch_presses_the_displayed_language_test() {
  let snapshot = dashboard.Snapshot(..states(), plugins: [], relays: Ok([]))
  use current <- list.each(i18n.languages)
  let body = dashboard.render(current, view.System, snapshot)
  let follow = i18n.text(current, i18n.FollowBrowser)
  assert string.contains(
    body,
    "<div aria-label=\""
      <> i18n.text(current, i18n.LanguageSwitchLabel)
      <> "\" class=\"join\" role=\"group\"><button aria-label=\""
      <> follow
      <> "\" "
      <> pressed_attributes(False)
      <> " name=\"language\" title=\""
      <> follow
      <> "\" type=\"submit\" value=\"system\">",
  )
  use language <- list.each(i18n.languages)
  let code = i18n.code(language)
  assert string.contains(
    body,
    "<button "
      <> pressed_attributes(language == current)
      <> " lang=\""
      <> code
      <> "\" name=\"language\" type=\"submit\" value=\""
      <> code
      <> "\">"
      <> i18n.native_name(language)
      <> "</button>",
  )
}

/// 切り替えのボタンの `aria-pressed` と `class` の属性。押した状態だけ `btn-neutral` で塗る。
fn pressed_attributes(pressed: Bool) -> String {
  case pressed {
    True ->
      "aria-pressed=\"true\" class=\"join-item btn btn-sm btn-neutral focus-visible:outline-base-content\""
    False ->
      "aria-pressed=\"false\" class=\"join-item btn btn-sm focus-visible:outline-base-content\""
  }
}

/// テーマのボタンの語。`view` の対応は非公開なので、テストの側で持つ。
fn theme_message(theme: view.Theme) -> i18n.Message {
  case theme {
    view.System -> i18n.FollowBrowser
    view.Light -> i18n.ThemeLight
    view.Dark -> i18n.ThemeDark
  }
}

/// 表の見出しは列を指す `scope="col"` を持ち、`scope` の無い `th` は出さない。
pub fn table_headers_scope_their_columns_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(body, "<th scope=\"col\">")
  assert !string.contains(body, "<th>")
}

/// 承認待ちとセッションを得られないときは、「0 件」の代わりに理由を出し、
/// 承認・拒否や取り消しのフォームも出さない。承認待ちの理由の囲みは error 色、
/// セッションの理由の囲みは中立の色になる。日本語では前置きも出る。
pub fn unlisted_pending_and_sessions_show_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      pending: Error(i18n.Untranslated("pending reason")),
      sessions: Error(i18n.Untranslated("sessions reason")),
    )
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(
    english,
    "alert alert-soft alert-error text-base-content\">"
      <> element.to_string(view.tone_icon(view.Failure))
      <> "<span><span lang=\"en\">pending reason</span></span>",
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
    "<span>承認待ちの一覧を表示できません。<span lang=\"en\">pending reason</span></span>",
  )
  assert string.contains(
    japanese,
    "<span>セッションの一覧を表示できません。<span lang=\"en\">sessions reason</span></span>",
  )
}

/// 承認済みセッションの行は、最終利用の `title` に作成と最終利用を RFC 3339 の UTC で出す。
pub fn sessions_show_created_and_last_used_times_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "abcd",
          client: "ef01",
          perms: "",
          created_at: 1_788_253_200,
          last_used_at: 1_789_276_354,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(
    body,
    "title=\"Last used: 2026-09-13T05:12:34Z · Created: 2026-09-01T09:00:00Z\"",
  )
}

/// セッションの行に署名者のラベルと省略した npub、権限のチップ、クライアントの
/// コピーボタンが出る。
pub fn session_row_shows_the_signer_and_permission_chips_test() {
  let known_signer = "abcd-known-signer-0123456789"
  let known_npub = "npub1sessionexampleabcdefghijklmno"
  let account =
    dashboard.AccountRow(
      signer: known_signer,
      npub: known_npub,
      label: "main",
      uri: "bunker://x",
      auth_uri: "bunker://x",
    )
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([account]),
      sessions: Ok([
        dashboard.SessionRow(
          signer: known_signer,
          client: "ef01",
          perms: "sign_event:1",
          created_at: 1000,
          last_used_at: 1000,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(body, "<span>main</span>")
  assert string.contains(body, view.shorten(known_npub))
  assert string.contains(
    body,
    element.to_string(permission_view.chips(i18n.English, "sign_event:1")),
  )
  assert string.contains(body, "data-action=\"copy\"")
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
        dashboard.SessionRow(
          signer: "abcd",
          client: "ef01",
          perms: "",
          created_at:,
          last_used_at:,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(body, "7 d ago")
  assert string.contains(
    body,
    "title=\"Last used: 2026-09-13T05:12:34Z · Created: 2026-09-01T09:00:00Z\"",
  )
}

/// `dashboard.relative_time` は、境界の秒数ごとに正しい文言を返す。未来の時刻は
/// 「たった今」（`JustNow`）にする。
pub fn relative_time_buckets_test() {
  assert dashboard.relative_time(1000, 1000) == i18n.JustNow
  assert dashboard.relative_time(1059, 1000) == i18n.JustNow
  assert dashboard.relative_time(1060, 1000) == i18n.MinutesAgo(1)
  assert dashboard.relative_time(1000 + 3599, 1000) == i18n.MinutesAgo(59)
  assert dashboard.relative_time(1000 + 3600, 1000) == i18n.HoursAgo(1)
  assert dashboard.relative_time(1000 + 86_399, 1000) == i18n.HoursAgo(23)
  assert dashboard.relative_time(1000 + 86_400, 1000) == i18n.DaysAgo(1)
  assert dashboard.relative_time(1000, 2000) == i18n.JustNow
}

/// 飛ばされた行が 1 件以上あれば、見出し・警告の 1 文・識別（ラベル・npub）・理由・
/// 削除のリンクが出る。日本語でも見出しが訳される。
pub fn skipped_rows_are_listed_with_their_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey: "abcd1234",
          npub: "npub1unreadable",
          label: "old wallet",
          reason: vault.UndecryptablePrivateKey,
        ),
      ]),
    )
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(english, "Unreadable accounts")
  assert string.contains(
    english,
    "The current ACCOUNT_MASTER_KEY cannot decrypt these rows.",
  )
  assert string.contains(english, "old wallet")
  assert string.contains(english, "npub1unreadable")
  assert string.contains(
    english,
    "The private key cannot be decrypted (wrong ACCOUNT_MASTER_KEY or a tampered row).",
  )
  assert string.contains(english, "href=\"/accounts/abcd1234/delete\"")
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "読み込めなかったアカウント",
  )
}

/// `pubkey` 列を読めない行は、識別も削除のリンクも出さず、理由の 1 文に削除でき
/// ない旨を続けて出す。
pub fn malformed_pubkey_rows_show_only_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey: "not-a-valid-pubkey-value",
          npub: "",
          label: "",
          reason: vault.MalformedPubkey,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(body, "The pubkey column cannot be read.")
  assert string.contains(
    body,
    "This row cannot be deleted here because its pubkey cannot be read.",
  )
  assert !string.contains(body, "not-a-valid-pubkey-value")
}

/// 読み込めなかった行にラベルと省略した npub、「削除」が出て、16 進の pubkey は
/// 削除のリンクの宛先にだけ使われ、識別としては出ない。
pub fn skipped_row_shows_the_label_and_npub_without_the_hex_test() {
  let pubkey = "deadbeef00112233445566778899aabbccddeeff0011223344"
  let npub = "npub1skippedexamplevalueabcdefghijklmno"
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey:,
          npub:,
          label: "old wallet",
          reason: vault.UndecryptablePrivateKey,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(body, "old wallet")
  assert string.contains(body, view.shorten(npub))
  assert string.contains(
    body,
    element.to_string(view.icon_button_link(
      dashboard.account_action_path(pubkey, dashboard.DeleteAccount),
      view.trash_icon(),
      "Delete",
      view.DangerGhostButton,
    )),
  )
  // pubkey の唯一の出現は削除のリンクの宛先である。
  assert list.length(string.split(body, pubkey)) == 2
}

/// 飛ばされた行が 0 件、あるいは一覧を得られないときはカードを描かない。
pub fn no_skipped_rows_draws_no_card_test() {
  let empty = dashboard.Snapshot(..states(), skipped: Ok([]))
  let unavailable =
    dashboard.Snapshot(..states(), skipped: Error(i18n.Untranslated("boom")))
  use language <- list.each([i18n.English, i18n.Japanese])
  assert !string.contains(
    dashboard.render(language, view.System, empty),
    "Unreadable accounts",
  )
  assert !string.contains(
    dashboard.render(language, view.System, empty),
    "読み込めなかったアカウント",
  )
  assert !string.contains(
    dashboard.render(language, view.System, unavailable),
    "Unreadable accounts",
  )
  assert !string.contains(
    dashboard.render(language, view.System, unavailable),
    "読み込めなかったアカウント",
  )
}

/// リレーは 1 行につき `<li>` 1 件で、監視、バンカーの順に用途のアイコン・語・状態の
/// バッジを並べ、アイコンだけの操作のリンク（用途の編集、削除）を続ける。使っていない
/// 用途は「未使用」のバッジで出し、URL は `break-all`。
pub fn relays_are_listed_one_item_per_row_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  let role = fn(icon, label, badge) {
    "<span class=\"flex items-center gap-2\">"
    <> element.to_string(icon)
    <> "<span class=\"whitespace-nowrap\">"
    <> label
    <> "</span>"
    <> element.to_string(badge)
    <> "</span>"
  }
  let actions = fn(id) {
    "<div class=\"flex shrink-0 flex-wrap gap-2\">"
    <> element.to_string(view.icon_only_link(
      "/relays/" <> id <> "/edit",
      view.pencil_icon(),
      "Edit roles",
      view.GhostButton,
    ))
    <> element.to_string(view.icon_only_link(
      "/relays/" <> id <> "/delete",
      view.trash_icon(),
      "Delete relay",
      view.DangerGhostButton,
    ))
    <> "</div>"
  }
  assert string.contains(
    body,
    "<ul class=\"list rounded-box border border-base-300 bg-base-100\"><li class=\"list-row flex flex-wrap items-center justify-between gap-x-6 gap-y-3\"><div class=\"flex min-w-0 flex-col gap-1\"><p class=\"font-mono text-xs break-all\">wss://a</p><div class=\"flex flex-wrap gap-x-4 gap-y-1 text-sm\">"
      <> role(
      view.eye_icon(),
      "monitor",
      view.status_chip(view.ActiveChip, "connected"),
    )
      <> role(
      view.key_icon(),
      "bunker",
      view.status_chip(view.DisconnectedChip, "disconnected"),
    )
      <> "</div></div>"
      <> actions("1")
      <> "</li><li class=\"list-row flex flex-wrap items-center justify-between gap-x-6 gap-y-3\"><div class=\"flex min-w-0 flex-col gap-1\"><p class=\"font-mono text-xs break-all\">wss://b</p><div class=\"flex flex-wrap gap-x-4 gap-y-1 text-sm\">"
      <> role(
      view.eye_icon(),
      "monitor",
      view.status_chip(view.DisconnectedChip, "disconnected"),
    )
      <> role(
      view.key_icon(),
      "bunker",
      view.status_chip(view.UnusedChip, "Unused"),
    )
      <> "</div></div>"
      <> actions("2")
      <> "</li></ul>",
  )
}

/// リレーの行のリンクは、用途の編集が地味なボタン、削除が error の文字色。
pub fn relay_rows_link_to_edit_and_delete_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    element.to_string(view.icon_only_link(
      "/relays/1/edit",
      view.pencil_icon(),
      "Edit roles",
      view.GhostButton,
    )),
  )
  assert string.contains(
    body,
    element.to_string(view.icon_only_link(
      "/relays/1/delete",
      view.trash_icon(),
      "Delete relay",
      view.DangerGhostButton,
    )),
  )
}

/// 締め切りまでに答えなかった用途（`Unanswered`）は「応答なし」のバッジになり、
/// URL と操作のリンク（用途の編集、削除）は残る。
pub fn a_relay_role_without_a_status_shows_unavailable_test() {
  let body =
    dashboard.render(
      i18n.English,
      view.System,
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
    "<span class=\"whitespace-nowrap\">monitor</span>"
      <> element.to_string(view.status_chip(view.UnansweredChip, "unavailable")),
  )
  assert string.contains(body, "wss://a")
  assert string.contains(body, "href=\"/relays/1/edit\"")
  assert string.contains(body, "href=\"/relays/1/delete\"")
}

/// 用途 2 つ（監視、バンカー）は必ず並び、使っていない側は「未使用」のバッジで出す。
pub fn unused_relay_roles_are_shown_as_unused_test() {
  let body =
    dashboard.render(
      i18n.English,
      view.System,
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
  assert string.contains(
    body,
    "<span class=\"whitespace-nowrap\">monitor</span>",
  )
  assert string.contains(
    body,
    "<span class=\"whitespace-nowrap\">bunker</span>"
      <> element.to_string(view.status_chip(view.UnusedChip, "Unused")),
  )
}

/// リレーの行の用途の編集と削除のリンクは、アイコンだけで `aria-label` を持ち、語は
/// ボタンの中身には出ない。
pub fn relay_actions_are_icon_only_with_labels_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(body, "aria-label=\"Edit roles\"")
  assert string.contains(body, "aria-label=\"Delete relay\"")
  assert !string.contains(body, ">Edit roles<")
  assert !string.contains(body, ">Delete relay<")
}

/// バンカーに使う行が 1 件も無ければ、見出しの直後に警告が出て一覧は出さない。監視だけの
/// 行があれば警告の後に一覧を出し、バンカーの行が 1 件でもあれば警告を出さない
/// （`states()` はバンカーの行を持つので、上のテストの描画に警告が無いことで確かめる）。
pub fn no_bunker_relay_is_warned_test() {
  let add_action =
    "<div class=\"flex flex-wrap justify-end gap-2\">"
    <> element.to_string(view.icon_button_link(
      "/relays/new",
      view.plus_icon(),
      "Add",
      view.PrimaryButton,
    ))
    <> "</div>"
  let no_rows =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), relays: Ok([])),
    )
  assert string.contains(
    no_rows,
    "Relays</h2></div></div>"
      <> add_action
      <> "</div><div class=\"alert alert-soft alert-warning text-base-content\">"
      <> element.to_string(view.tone_icon(view.Warning))
      <> "<span>No relay is used for the bunker. Clients cannot connect to any account until you add one.</span></div></section>",
  )
  let monitor_only =
    dashboard.render(
      i18n.English,
      view.System,
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
  assert string.contains(
    monitor_only,
    "Relays</h2>"
      <> "<span class=\"badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums\">1</span></div></div>"
      <> add_action
      <> "</div><div class=\"alert alert-soft alert-warning text-base-content\">"
      <> element.to_string(view.tone_icon(view.Warning))
      <> "<span>No relay is used for the bunker. Clients cannot connect to any account until you add one.</span></div><ul",
  )
  assert !string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "No relay is used for the bunker.",
  )
}

/// リレーの一覧を得られないときは、一覧の代わりに理由を出し、警告は出さない。日本語では
/// 前置きも出る。
pub fn unlisted_relays_show_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(..states(), relays: Error(i18n.Untranslated("boom")))
  assert string.contains(
    dashboard.render(i18n.English, view.System, snapshot),
    "Relays</h2></div></div></div>"
      <> "<div class=\"rounded-box border border-base-300 bg-base-100\"><div class=\"alert alert-soft text-base-content\">"
      <> element.to_string(view.tone_icon(view.Neutral))
      <> "<span><span lang=\"en\">boom</span></span></div></div></section>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "リレー</h2></div></div></div>"
      <> "<div class=\"rounded-box border border-base-300 bg-base-100\"><div class=\"alert alert-soft text-base-content\">"
      <> element.to_string(view.tone_icon(view.Neutral))
      <> "<span>リレーの一覧を表示できません。<span lang=\"en\">boom</span></span></div></div></section>",
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
  assert string.contains(
    dashboard.render(i18n.English, view.System, snapshot),
    "Not available right now.",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "今は取得できません。",
  )
}

/// リレーの節の見出しの行は、一覧を得たときだけ追加のリンクを出す。
pub fn relays_heading_links_to_add_a_relay_test() {
  let ok = dashboard.render(i18n.English, view.System, states())
  assert string.contains(ok, "href=\"/relays/new\"")

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), relays: Error(i18n.Untranslated("boom"))),
    )
  assert !string.contains(unavailable, "/relays/new")
}

/// セッションの節の見出しの行は、一覧を得たときだけクライアントの接続へのリンクを出す。
pub fn sessions_heading_links_to_connect_a_client_test() {
  let ok = dashboard.render(i18n.English, view.System, states())
  assert string.contains(ok, "href=\"/sessions/connect\"")

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), sessions: Error(i18n.Untranslated("boom"))),
    )
  assert !string.contains(unavailable, "/sessions/connect")
}

/// アカウントの節の見出しの行には、追加のリンクと並んで読み直しのフォームが出る。
pub fn accounts_heading_has_a_reload_form_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "<form action=\"/accounts/reload\" method=\"post\">",
  )
}

/// 一覧を得られないときも、アカウントの節の見出しの読み直しのフォームは出したままにする
/// （追加のリンクは一覧を得たときだけ出す）。
pub fn the_reload_form_stays_without_the_account_list_test() {
  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), accounts: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(unavailable, "/accounts/reload")
  assert !string.contains(unavailable, "/accounts/new")
}

/// アカウント・セッション・リレーの見出しは、一覧を得て 1 件以上あるときだけ題の直後に
/// 件数のピルを出す。一覧を得られない節にはピルを出さない。
pub fn section_headings_show_the_count_pill_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "Relays</h2>"
      <> "<span class=\"badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums\">2</span>",
  )

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(
        ..states(),
        accounts: Error(i18n.Untranslated("boom")),
        sessions: Error(i18n.Untranslated("boom")),
        relays: Error(i18n.Untranslated("boom")),
      ),
    )
  assert !string.contains(unavailable, "Accounts</h2><span class=\"badge")
  assert !string.contains(
    unavailable,
    "Approved sessions</h2><span class=\"badge",
  )
  assert !string.contains(unavailable, "Relays</h2><span class=\"badge")
}

/// 空のアカウント・セッション・プラグインの節は、アイコンと 1 文を出し、件数のピルは
/// 出さない。
pub fn empty_sections_show_an_icon_and_a_sentence_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([]),
      sessions: Ok([]),
      plugins: [],
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(
    body,
    "No accounts registered. Use &quot;Add&quot; to import an nsec or generate a key.",
  )
  assert string.contains(body, "No approved sessions.")
  assert string.contains(body, "No plugins enabled.")
  assert !string.contains(body, "Accounts</h2><span class=\"badge")
  assert !string.contains(body, "Approved sessions</h2><span class=\"badge")
  assert !string.contains(body, "Plugins</h2><span class=\"badge")
}

/// プラグインのタイルは、読み込めなかった候補が 1 件以上あるとき補足をその件数にし
/// （警告の色になる）、過負荷・無効・応答なしの内訳より優先する。0 件のときは今までどおり
/// その内訳を出す。
pub fn plugins_tile_notes_not_loaded_test() {
  let with_not_loaded =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), not_loaded_plugins: [
        plugin_loader.NotLoaded(id: "demo_plugin", reason: "boom"),
      ]),
    )
  assert string.contains(with_not_loaded, "1 failed to load")
  assert !string.contains(
    with_not_loaded,
    "1 overloaded · 1 disabled · 1 unavailable",
  )
  assert string.contains(
    with_not_loaded,
    "card card-border border-warning bg-warning/15 text-warning",
  )

  let without_not_loaded = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    without_not_loaded,
    "1 overloaded · 1 disabled · 1 unavailable",
  )
  assert !string.contains(without_not_loaded, "failed to load")
}

/// 承認ページは言語を切り替えた後に同じ承認ページを、通知ページはダッシュボードを開く。
pub fn language_switch_return_paths_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, Ok([]), pending),
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
  let with_pending = dashboard.render(i18n.English, view.System, states())
  assert string.contains(with_pending, "http-equiv=\"refresh\"")
  assert string.contains(with_pending, "content=\"30\"")
  assert !string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    ),
    "http-equiv=\"refresh\"",
  )
  assert !string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    ),
    "http-equiv=\"refresh\"",
  )
}

/// 承認待ちのタイルの補足は、自動更新中のときだけ更新の間隔を伝える。
pub fn pending_tile_shows_the_refresh_note_only_when_refreshing_test() {
  assert string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "Awaiting your decision · refreshes every 30 s",
  )
  assert !string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    ),
    "Awaiting your decision",
  )
}

/// 承認ページは常に 30 秒ごとに自動で読み込み直すが、その移り先の通知ページは
/// 読み込みを繰り返さない。
pub fn approval_page_refreshes_automatically_test() {
  let assert Ok([pending]) = states().pending
  let approval =
    dashboard.approval_page(i18n.English, view.System, Ok([]), pending)
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

/// 承認待ちの行と承認ページには「失効まで」の欄が出る。
pub fn pending_shows_time_until_expiry_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "<dt class=\"text-muted\">Expires in</dt><dd><span>540s</span></dd>",
  )
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, Ok([]), pending),
    "<dt class=\"text-muted\">失効まで</dt><dd><span>540 秒</span></dd>",
  )
}

/// 概要のタイルは、5 つの節へのリンク（`href="#…"`）になっており、各節は同じアンカーの
/// `id` を持つ。
pub fn overview_tiles_link_to_each_section_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  let anchors = ["pending", "accounts", "sessions", "relays", "plugins"]
  use anchor <- list.each(anchors)
  assert string.contains(body, "href=\"#" <> anchor <> "\"")
  assert string.contains(body, "id=\"" <> anchor <> "\"")
}

/// 承認待ちのタイルは、1 件以上あるときだけ狭い画面で全幅を占める。
pub fn pending_tile_is_full_width_only_when_pending_exists_test() {
  let wide_class =
    "card card-border col-span-2 border-warning bg-warning/15 text-warning lg:col-span-1"
  let with_pending = dashboard.render(i18n.English, view.System, states())
  assert string.contains(with_pending, wide_class)

  let empty =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    )
  assert !string.contains(empty, wide_class)
}

/// 承認待ちのタイルは、0 件のときは節が無いのでリンクにしない。1 件以上あるとき、
/// 一覧を得られないときはリンクにする。
pub fn pending_tile_is_not_a_link_when_no_pending_test() {
  let anchor = "href=\"#pending\""
  assert string.contains(
    dashboard.render(i18n.English, view.System, states()),
    anchor,
  )
  assert !string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    ),
    anchor,
  )
  assert string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    ),
    anchor,
  )
}

/// 承認待ち・アカウント・セッションの一覧を得られないとき、対応するタイルの値は
/// 「—」、補足は「取得できません」になる。
pub fn tiles_say_not_available_when_lists_are_missing_test() {
  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(
        ..states(),
        accounts: Error(i18n.Untranslated("boom")),
        pending: Error(i18n.Untranslated("boom")),
        sessions: Error(i18n.Untranslated("boom")),
      ),
    )
  let value = "<p class=\"text-2xl font-bold\">—</p>"
  let note = "<p class=\"text-xs\">Not available</p>"
  assert list.length(string.split(unavailable, value)) == 4
  assert list.length(string.split(unavailable, note)) == 4
}

/// 承認待ちの節は 1 件以上あるとき、または一覧を得られないときだけ描く。0 件のときは
/// 節ごと出さない。
pub fn empty_pending_section_is_not_rendered_test() {
  let empty =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    )
  assert !string.contains(empty, "Pending connections")

  let present = dashboard.render(i18n.English, view.System, states())
  assert string.contains(present, "Pending connections")
  assert !string.contains(present, "alert-error")

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(unavailable, "Pending connections")
  assert string.contains(unavailable, "alert-soft alert-error")
}

/// 承認待ちの行のクライアントは省略した表示とコピーボタンで出る。
pub fn pending_row_shows_the_client_shortened_with_a_copy_button_test() {
  let long_client = "cccc3333cccc3333cccc3333cccc3333"
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      pending: Ok([
        dashboard.PendingRow(
          token: "tok",
          signer: "abcd",
          client: long_client,
          expires_in_seconds: 540,
          secret_mismatch: False,
          perms: "",
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(body, view.shorten(long_client))
  assert string.contains(body, "data-action=\"copy\"")
}

/// 署名者は、アカウント一覧にあればラベルと省略した npub、無ければ省略した 16 進で出る。
/// アカウント一覧を得られないときも省略した 16 進になる。
pub fn signer_is_shown_as_label_and_npub_test() {
  let known_signer = "abcd-known-signer-0123456789"
  let unknown_signer = "unknown-signer-0123456789abcd"
  let known_npub = "npub1exampleexampleexampleexampleexampleexampleexamplex"
  let known_account =
    dashboard.AccountRow(
      signer: known_signer,
      npub: known_npub,
      label: "main",
      uri: "bunker://x",
      auth_uri: "bunker://x",
    )
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      accounts: Ok([known_account]),
      pending: Ok([
        dashboard.PendingRow(
          token: "tok-known",
          signer: known_signer,
          client: "ef01",
          expires_in_seconds: 540,
          secret_mismatch: False,
          perms: "",
        ),
        dashboard.PendingRow(
          token: "tok-unknown",
          signer: unknown_signer,
          client: "ef02",
          expires_in_seconds: 540,
          secret_mismatch: False,
          perms: "",
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(body, "<span>main</span>")
  assert string.contains(body, view.shorten(known_npub))
  assert string.contains(body, view.shorten(unknown_signer))

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..snapshot, accounts: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(unavailable, view.shorten(known_signer))
  assert !string.contains(unavailable, "<span>main</span>")
}

/// 承認ページには、承認の意味の説明が info の囲みで出る。権限が空のときだけ、既定で
/// 許す範囲を述べる一文が続く。
pub fn approval_page_explains_what_approval_means_test() {
  let assert Ok([with_perms, without_perms]) = secret_states().pending
  let with_perms_page =
    dashboard.approval_page(i18n.English, view.System, Ok([]), with_perms)
  assert string.contains(with_perms_page, "alert-info")
  assert string.contains(
    with_perms_page,
    "Approving lets this client request signing and encryption within the permissions above. You can change them later from the approved session.",
  )
  assert !string.contains(
    with_perms_page,
    "None requested. Signing any kind but 24133, and NIP-44 encryption and decryption, are allowed.",
  )

  let without_perms_page =
    dashboard.approval_page(i18n.English, view.System, Ok([]), without_perms)
  assert string.contains(
    without_perms_page,
    "You can change them later from the approved session. None requested. Signing any kind but 24133, and NIP-44 encryption and decryption, are allowed.",
  )
}
