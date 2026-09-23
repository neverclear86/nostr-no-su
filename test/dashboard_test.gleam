//// 管理 UI のパスの定義と、状態の見せ方（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/fingerprint
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
    "monitor</dt>",
    element.to_string(view.status_chip(view.ActiveChip, "connected")),
    element.to_string(view.status_chip(view.DisconnectedChip, "disconnected")),
    element.to_string(view.status_chip(view.ActiveChip, "running")),
    element.to_string(view.status_chip(view.OverloadedChip, "overloaded"))
      <> "<span class=\"text-xs break-words\">(dropped 4)</span>",
    element.to_string(view.status_chip(view.DisabledChip, "disabled"))
      <> "<span class=\"text-xs break-words\"><span lang=\"en\">boom</span> (dropped 2)</span>",
    element.to_string(view.status_chip(view.UnansweredChip, "unavailable")),
    "<dd>9:00 (expires at <time datetime=\"2026-09-13T05:21:34Z\">05:21:34 UTC</time>)</dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 日本語のダッシュボードでは、状態の語、件数、失効までを日本語の形で出す。バッジの
/// クラスは英語と同じである。
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
    "<dd>9:00（<time datetime=\"2026-09-13T05:21:34Z\">05:21:34（UTC）</time> に失効）</dd>",
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

/// secret が一致しない承認待ちの承認ページには `WrongSecretNotice` の警告の囲みが 1 つだけ出て、提示が無い
/// 承認待ちの承認ページには警告の囲みが出ない。
pub fn wrong_secret_warning_is_shown_only_on_mismatched_approval_page_test() {
  let assert Ok([not_offered, mismatched]) = secret_states().pending
  let page = fn(language, pending) {
    dashboard.approval_page(
      language,
      view.System,
      Ok([]),
      states().now,
      pending,
    )
  }
  list.each([i18n.English, i18n.Japanese], fn(language) {
    let notice =
      element.to_string(
        view.alert(view.Warning, [
          html.text(i18n.text(language, i18n.WrongSecretNotice)),
        ]),
      )
    assert list.length(string.split(page(language, mismatched), notice)) == 2
    assert !string.contains(page(language, not_offered), "alert-warning")
  })
}

/// 承認ページは、ダッシュボードと同じ承認待ちのカードを出し、残り時間を円で描く。
pub fn approval_page_draws_the_pending_card_test() {
  let assert Ok([pending]) = states().pending
  let page =
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      pending,
    )
  assert string.contains(page, "pathLength=\"600\"")
  assert string.contains(page, "aria-label=\"Expires in 9:00\"")
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
  assert string.contains(
    dashboard.render(i18n.English, view.System, secret_states()),
    chips,
  )
  assert string.contains(
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      offered,
    ),
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
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      not_requested,
    ),
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
    "<div class=\"col-span-2\">"
      <> element.to_string(permission_view.chips(i18n.English, "sign_event:7"))
      <> "</div>",
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
    "<div class=\"col-span-2\">"
      <> element.to_string(view.status_chip(
      view.ToneChip(view.Neutral),
      "No permissions requested",
    ))
      <> "</div>",
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

/// プラグインの節の見出しは、題の直後に件数のピルを置き、その下に 1 行の説明を出す。
pub fn plugins_heading_shows_the_count_and_description_test() {
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
    title
      <> "</h2><span class=\"badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums\">4</span></div><p class=\"text-sm text-muted sm:pl-10\">"
      <> description
      <> "</p>",
  )
}

/// プラグインは表ではなく行の一覧に並び、各行に名前と状態のチップが入る。応答の無いプラグインは
/// 「応答なし」のチップで出る。
pub fn plugin_rows_show_the_name_and_state_chip_test() {
  let body = dashboard.render(i18n.English, view.System, states())
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
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(english, "Plugins that failed to load")
  assert string.contains(
    english,
    "</li></ul><div class=\"alert alert-soft alert-error flex flex-col items-stretch gap-3 text-base-content\">",
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
  let english = dashboard.render(i18n.English, view.System, snapshot)
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
    "<span>承認待ち、アカウント、セッションの一覧を表示できません。"
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
  let english = dashboard.render(i18n.English, view.System, snapshot)
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
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert list.length(string.split(english, "first reason")) == 3
  assert list.length(string.split(english, "second reason")) == 2
  assert list.length(string.split(english, "alert alert-soft alert-error")) == 4
  assert !string.contains(english, "Not available for the reason above.")
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

/// リレーは 1 行につき `<li>` 1 件で、1 段目に URL とアイコンだけの操作のリンク（用途の編集、削除）を
/// 並べ、2 段目に監視、バンカーの順に用途のアイコン・語・状態のバッジのマスを並べる。使っていない
/// 用途は「未使用」のバッジで出し、URL は `break-all`。
pub fn relays_are_listed_one_item_per_row_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  let role = fn(icon, label, badge) {
    "<div class=\"flex flex-wrap items-center justify-between gap-x-2 gap-y-1 rounded-field bg-base-200 py-1.5 pr-1.5 pl-2.5\"><dt class=\"flex items-center gap-1.5 text-sm text-muted\">"
    <> element.to_string(icon)
    <> label
    <> "</dt><dd>"
    <> element.to_string(badge)
    <> "</dd></div>"
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
  let row = fn(id, url, monitor, bunker) {
    "<li class=\"list-row flex flex-wrap items-center justify-between gap-x-6 gap-y-3\"><p class=\"min-w-0 flex-1 font-mono text-sm break-all\">"
    <> url
    <> "</p>"
    <> actions(id)
    <> "<dl class=\"grid basis-full grid-cols-2 gap-1.5\">"
    <> role(view.eye_icon(), "monitor", monitor)
    <> role(view.key_icon(), "bunker", bunker)
    <> "</dl></li>"
  }
  assert string.contains(
    body,
    "<ul class=\"list rounded-box border border-base-300 bg-base-100\">"
      <> row(
      "1",
      "wss://a",
      view.status_chip(view.ActiveChip, "connected"),
      view.status_chip(view.DisconnectedChip, "disconnected"),
    )
      <> row(
      "2",
      "wss://b",
      view.status_chip(view.DisconnectedChip, "disconnected"),
      view.status_chip(view.UnusedChip, "Unused"),
    )
      <> "</ul>",
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
    "monitor</dt><dd>"
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
  assert string.contains(body, "monitor</dt><dd>")
  assert string.contains(
    body,
    "bunker</dt><dd>"
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

/// バンカーに使う行が 1 件も無ければ、見出しと凡例の直後にエラーの色の囲みが出て一覧は出さない。監視だけの
/// 行があれば囲みの後に一覧を出し、バンカーの行が 1 件でもあれば囲みを出さない
/// （`states()` はバンカーの行を持つので、上のテストの描画に囲みが無いことで確かめる）。
pub fn no_bunker_relay_is_shown_in_an_error_alert_test() {
  let add_action =
    "<div class=\"flex flex-wrap justify-end gap-2\">"
    <> element.to_string(view.icon_button_link(
      "/relays/new",
      view.plus_icon(),
      "Add",
      view.PrimaryButton,
    ))
    <> "</div>"
  let legend =
    legend_html(
      "monitor",
      "Subscribes to registered accounts&#39; events and passes them to plugins",
      "bunker",
      "Accepts NIP-46 requests",
    )
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
      <> "</div>"
      <> legend
      <> "</div><div class=\"alert alert-soft alert-error text-base-content\">"
      <> element.to_string(view.tone_icon(view.Failure))
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
      <> "</div>"
      <> legend
      <> "</div><div class=\"alert alert-soft alert-error text-base-content\">"
      <> element.to_string(view.tone_icon(view.Failure))
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
      <> legend_html(
      "monitor",
      "Subscribes to registered accounts&#39; events and passes them to plugins",
      "bunker",
      "Accepts NIP-46 requests",
    )
      <> "</div>"
      <> "<div class=\"rounded-box border border-base-300 bg-base-100\"><div class=\"alert alert-soft alert-error text-base-content\">"
      <> element.to_string(view.tone_icon(view.Failure))
      <> "<span><span lang=\"en\">boom</span></span></div></div></section>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "リレー</h2></div></div></div>"
      <> legend_html(
      "監視",
      "登録アカウントのイベントを購読してプラグインに渡す",
      "バンカー",
      "NIP-46 のリクエストを受け付ける",
    )
      <> "</div>"
      <> "<div class=\"rounded-box border border-base-300 bg-base-100\"><div class=\"alert alert-soft alert-error text-base-content\">"
      <> element.to_string(view.tone_icon(view.Failure))
      <> "<span>リレーの一覧を表示できません。<span lang=\"en\">boom</span></span></div></div></section>",
  )
}

/// リレーの節の見出しの直後には、一覧の行があるとき・0 件のとき・一覧を得られないときの
/// どれでも、監視とバンカーの語と説明を並べた凡例が出る。
pub fn relays_heading_is_followed_by_the_role_legend_test() {
  let legend =
    "</div>"
    <> legend_html(
      "monitor",
      "Subscribes to registered accounts&#39; events and passes them to plugins",
      "bunker",
      "Accepts NIP-46 requests",
    )
    <> "</div>"
  let snapshots = [
    states(),
    dashboard.Snapshot(..states(), relays: Ok([])),
    dashboard.Snapshot(..states(), relays: Error(i18n.Untranslated("boom"))),
  ]
  list.each(snapshots, fn(snapshot) {
    assert string.contains(
      dashboard.render(i18n.English, view.System, snapshot),
      legend,
    )
  })
}

/// リレーの節の凡例の HTML。語と説明の組を監視、バンカーの順に並べる。
fn legend_html(
  monitor: String,
  monitor_description: String,
  bunker: String,
  bunker_description: String,
) -> String {
  let pair = fn(role, description) {
    "<span class=\"inline-flex gap-1.5\"><b class=\"shrink-0 font-semibold text-base-content\">"
    <> role
    <> "</b>"
    <> description
    <> "</span>"
  }
  "<p class=\"flex flex-wrap gap-x-4 gap-y-1 text-sm text-muted sm:pl-10\">"
  <> pair(monitor, monitor_description)
  <> pair(bunker, bunker_description)
  <> "</p>"
}

/// 節の格子は 1121px 以上で 1.62 対 1 の 2 列になり、左の列の先頭がアカウント、右の列の
/// 先頭がリレーの節である。
pub fn dashboard_columns_split_above_1120px_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "<div class=\"grid items-start gap-6 min-[1121px]:grid-cols-[minmax(0,1.62fr)_minmax(0,1fr)]\"><div class=\"flex min-w-0 flex-col gap-6\"><section class=\"flex flex-col gap-3\" id=\"accounts\"",
  )
  assert string.contains(
    body,
    "<div class=\"flex min-w-0 flex-col gap-6\"><section class=\"flex flex-col gap-3\" id=\"relays\"",
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

/// 空のアカウント・セッション・プラグインの節は、アイコンと説明の文を出し、件数のピルは
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
    "No accounts registered. Import an nsec or generate a new key.",
  )
  assert string.contains(body, "No approved sessions.")
  assert string.contains(body, "No plugins enabled.")
  assert !string.contains(body, "Accounts</h2><span class=\"badge")
  assert !string.contains(body, "Approved sessions</h2><span class=\"badge")
  assert !string.contains(body, "Plugins</h2><span class=\"badge")
}

/// 空のアカウントとセッションの節は、点線の枠の中にそれぞれ追加と接続の枠のボタンを置き、
/// 空のプラグインの節はボタンを置かない。
pub fn empty_sections_offer_their_action_in_the_frame_test() {
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
    element.to_string(
      view.empty_state(
        view.users_icon(),
        "No accounts registered. Import an nsec or generate a new key.",
        [
          view.icon_button_link(
            "/accounts/new",
            view.plus_icon(),
            "Add account",
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
        view.icon_button_link(
          "/sessions/connect",
          view.plus_icon(),
          "Connect a client",
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
}

/// 承認ページは言語を切り替えた後に同じ承認ページを、通知ページはダッシュボードを開く。
pub fn language_switch_return_paths_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    dashboard.approval_page(
      i18n.Japanese,
      view.System,
      Ok([]),
      states().now,
      pending,
    ),
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

/// 承認ページは常に 30 秒ごとに自動で読み込み直すが、その移り先の通知ページは
/// 読み込みを繰り返さない。
pub fn approval_page_refreshes_automatically_test() {
  let assert Ok([pending]) = states().pending
  let approval =
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      pending,
    )
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

/// 承認待ちのカードには「失効まで」の欄が出て、残りの「分:秒」と失効の時刻を出す。承認ページも同じカードを使う。
pub fn pending_shows_time_until_expiry_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "<dt class=\"text-muted\">Expires in</dt><dd>9:00 (expires at <time datetime=\"2026-09-13T05:21:34Z\">05:21:34 UTC</time>)</dd>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, states()),
    "<dt class=\"text-muted\">失効まで</dt><dd>9:00（<time datetime=\"2026-09-13T05:21:34Z\">05:21:34（UTC）</time> に失効）</dd>",
  )
  assert string.contains(
    dashboard.approval_page(
      i18n.Japanese,
      view.System,
      Ok([]),
      states().now,
      pending,
    ),
    "<dt class=\"text-muted\">失効まで</dt><dd>9:00（<time datetime=\"2026-09-13T05:21:34Z\">05:21:34（UTC）</time> に失効）</dd>",
  )
}

/// secret が一致しないカードは、枠を warning の色にして説明の囲みを 1 つ置き、拒否を塗り、承認を
/// warning の枠の「それでも承認する」にする。並びは一致するカードと同じ承認、拒否の順で、承認ページも
/// 同じボタンを出す。
pub fn mismatched_pending_swaps_the_emphasis_but_not_the_order_test() {
  let assert Ok([not_offered, mismatched]) = secret_states().pending
  let mismatched_forms =
    "<form action=\"/approve/tok-2\" method=\"post\"><button class=\"btn btn-outline btn-warning btn-sm focus-visible:outline-base-content\" type=\"submit\">Approve anyway</button></form>"
    <> "<form action=\"/deny/tok-2\" method=\"post\"><button class=\"btn btn-primary btn-sm focus-visible:outline-base-content\" type=\"submit\">Deny</button></form>"
  let offered_forms =
    "<form action=\"/approve/tok-1\" method=\"post\"><button class=\"btn btn-primary btn-sm focus-visible:outline-base-content\" type=\"submit\">Approve</button></form>"
    <> "<form action=\"/deny/tok-1\" method=\"post\"><button class=\"btn btn-ghost btn-sm focus-visible:outline-base-content\" type=\"submit\">Deny</button></form>"
  let body = dashboard.render(i18n.English, view.System, secret_states())
  assert string.contains(body, mismatched_forms)
  assert string.contains(body, offered_forms)
  assert list.length(string.split(body, "border-warning/55")) == 2
  assert list.length(string.split(
      body,
      i18n.text(i18n.English, i18n.WrongSecretNotice),
    ))
    == 2

  assert string.contains(
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      mismatched,
    ),
    mismatched_forms,
  )
  assert string.contains(
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      not_offered,
    ),
    offered_forms,
  )
}

/// 承認待ちの帯は、見出しに説明を付け、ダッシュボードを自動で読み込み直すとき（1 件以上）だけ
/// 更新の間隔を出す。一覧を得られないときは帯と説明だけを出し、0 件のときは帯も更新の間隔も出さない。
pub fn pending_band_shows_the_refresh_only_while_refreshing_test() {
  let band =
    "<section class=\"flex flex-col gap-4 rounded-box border border-primary/28 bg-primary/8 p-4 sm:p-6\" id=\"pending\">"
  let description =
    "Until you approve, this client cannot request signing or encryption."
  let refresh = "Refreshes every 30 s"

  let present = dashboard.render(i18n.English, view.System, states())
  assert string.contains(present, band)
  assert string.contains(present, description)
  assert string.contains(present, refresh)

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(unavailable, band)
  assert string.contains(unavailable, description)
  assert !string.contains(unavailable, refresh)

  let empty =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    )
  assert !string.contains(empty, band)
  assert !string.contains(empty, refresh)
}

/// 残り時間の円は、600 を満たんとする弧を残りの秒の長さで描き、60 秒未満は弧と数字を warning の
/// 色にする。残り時間は囲みの `aria-label` で読み上げる。
pub fn pending_ring_follows_the_remaining_seconds_test() {
  let body = dashboard.render(i18n.English, view.System, secret_states())
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

/// 概要の帯の項目は、5 つの節へのリンク（`href="#…"`）になっており、各節は同じアンカーの
/// `id` を持つ。
pub fn overview_rail_links_to_each_section_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  let anchors = ["pending", "accounts", "sessions", "relays", "plugins"]
  use anchor <- list.each(anchors)
  assert string.contains(body, "href=\"#" <> anchor <> "\"")
  assert string.contains(body, "id=\"" <> anchor <> "\"")
}

/// 承認待ちの項目は、0 件のときは節が無いのでリンクにしない。1 件以上あるとき、
/// 一覧を得られないときはリンクにする。
pub fn overview_pending_is_not_a_link_when_no_pending_test() {
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

/// 承認待ち・アカウント・セッションの一覧を得られないとき、対応する項目の値は error の色の
/// 「—」、補足は error の色の「取得できません」になる。
pub fn overview_says_not_available_when_lists_are_missing_test() {
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

/// 承認待ちの帯は 1 件以上あるとき、または一覧を得られないときだけ描く。0 件のときは
/// 帯ごと出さない。
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

/// 承認待ちのカードのクライアントは省略した表示とコピーボタンで出る。
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

/// 承認待ちのカードは、64 桁の 16 進のクライアントの公開鍵なら色付きの指紋を描き、指紋を
/// 求められない値なら描かない。
pub fn pending_card_draws_the_client_fingerprint_test() {
  let client = string.repeat("0123456789abcdef", 4)
  let assert Ok(mark) = fingerprint.from_pubkey(client)
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      pending: Ok([
        dashboard.PendingRow(
          token: "tok",
          signer: "abcd",
          client:,
          expires_in_seconds: 540,
          secret_mismatch: False,
          perms: "",
        ),
      ]),
    )
  assert string.contains(
    dashboard.render(i18n.English, view.System, snapshot),
    element.to_string(fingerprint.svg(mark, fingerprint.Colored, "size-6")),
  )
  assert !string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "class=\"size-6 fp",
  )
}

/// クライアントの公開鍵が `client` の承認済みセッション 1 件。
fn session_row(client: String) -> dashboard.SessionRow {
  dashboard.SessionRow(
    signer: "abcd",
    client:,
    perms: "sign_event:7",
    created_at: 1_788_253_200,
    last_used_at: 1_789_276_354,
  )
}

/// 英語のダッシュボードのうち、セッションの節（`id="sessions"`）以降の部分。
fn sessions_part(snapshot: dashboard.Snapshot) -> String {
  let assert Ok(#(_, part)) =
    string.split_once(
      dashboard.render(i18n.English, view.System, snapshot),
      "id=\"sessions\"",
    )
  part
}

/// セッションの節の見出しは、件数のピルの後に 1 行の説明を出す。一覧を得られないときは件数を出さず、
/// 説明は出す。
pub fn sessions_heading_shows_the_count_and_the_description_test() {
  let description =
    "<p class=\"text-sm text-muted sm:pl-10\">Clients can request signing and encryption within the permissions shown here.</p>"
  let listed =
    sessions_part(
      dashboard.Snapshot(
        ..states(),
        sessions: Ok([session_row("ef01"), session_row("ef02")]),
      ),
    )
  assert string.contains(
    listed,
    "Approved sessions</h2><span class=\"badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums\">2</span></div>"
      <> description,
  )

  let unavailable =
    sessions_part(
      dashboard.Snapshot(..states(), sessions: Error(i18n.Untranslated("boom"))),
    )
  assert string.contains(
    unavailable,
    "Approved sessions</h2></div>" <> description,
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

/// セッションの行は、幅 720px 以下で 4 段に、721px 以上で 3 列 2 段に組み替える格子とボタンの升の
/// クラスを持つ。クラスの照合だけで、幅の切り替えそのものはブラウザーで確かめる。
pub fn session_row_regroups_at_720px_test() {
  let part =
    sessions_part(
      dashboard.Snapshot(..states(), sessions: Ok([session_row("ef01")])),
    )
  assert string.contains(
    part,
    "class=\"grid grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 gap-y-2 min-[721px]:grid-cols-[auto_minmax(0,1fr)_auto]\"",
  )
  assert string.contains(
    part,
    "class=\"col-span-2 flex flex-wrap justify-end gap-2 border-t border-dashed border-base-300 pt-2 min-[721px]:col-span-1 min-[721px]:self-start min-[721px]:border-t-0 min-[721px]:pt-0\"",
  )
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

/// 承認ページには、カードの直後に承認の意味の説明が info の囲みで畳まずに出る。権限が空のときだけ、既定で
/// 許す範囲を述べる一文が続く。
pub fn approval_page_explains_what_approval_means_test() {
  let assert Ok([with_perms, without_perms]) = secret_states().pending
  let with_perms_page =
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      with_perms,
    )
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

  let without_perms_page =
    dashboard.approval_page(
      i18n.English,
      view.System,
      Ok([]),
      states().now,
      without_perms,
    )
  assert string.contains(
    without_perms_page,
    "You can change them later from the approved session. None requested. Signing any kind but 24133, and NIP-44 encryption and decryption, are allowed.",
  )
}

/// 承認待ちの項目は、1 件以上あるときだけ `primary` で塗る。狭い画面では件数によらず全幅を
/// 占める。
pub fn overview_highlights_pending_only_when_pending_exists_test() {
  let highlighted =
    "col-span-2 flex flex-col gap-0.5 bg-primary px-4 py-3.5 text-primary-content"
  let plain =
    "col-span-2 flex flex-col gap-0.5 bg-base-100 px-4 py-3.5 lg:col-span-1"
  let with_pending = dashboard.render(i18n.English, view.System, states())
  assert string.contains(with_pending, highlighted)
  let empty =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    )
  assert !string.contains(empty, highlighted)
  assert string.contains(empty, plain)
}

/// 概要の帯の色の規則。一覧を得られない項目は値「—」と error の補足、要対応の語だけ状態の
/// チップの色、承認待ちが 1 件以上なら承認待ちの項目だけを塗る。
pub fn overview_color_rules_test() {
  let failure = Some(view.ToneChip(view.Failure))
  let not_available =
    dashboard.Overview(
      dashboard.NoValue,
      [dashboard.OverviewNote(failure, i18n.OverviewNotAvailable)],
      linked: True,
      highlighted: False,
    )
  let item = fn(value, notes) {
    dashboard.Overview(value, notes, linked: True, highlighted: False)
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
        linked: False,
        highlighted: False,
      ),
    ),
    #(
      secret_states(),
      pending,
      dashboard.Overview(
        dashboard.Count(2),
        [plain(i18n.AwaitingDecision), plain(i18n.SoonestExpiry("0:45"))],
        linked: True,
        highlighted: True,
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
            npub: "npub1unreadable",
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
  let account =
    dashboard.AccountRow(
      signer: "abcd",
      npub: "npub1x",
      label: "",
      uri: "bunker://x?secret=s",
      auth_uri: "bunker://x",
    )
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

/// 「はじめに」の帯は、まだの段に追加のページへのリンクを、済んだ段に「済み」のチップを出し、
/// 段 3 を点線の枠で出す。リレーとアカウントがそろうと帯ごと出さない。
pub fn getting_started_band_shows_done_open_and_locked_steps_test() {
  let render = fn(accounts, relays) {
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), accounts: Ok(accounts), relays: Ok(relays)),
    )
  }
  let link = fn(href, label) {
    element.to_string(view.icon_button_link(
      href,
      view.plus_icon(),
      label,
      view.PrimaryButton,
    ))
  }
  let add_relay = link("/relays/new", "Add relay")
  let add_account = link("/accounts/new", "Add account")
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

  let account =
    dashboard.AccountRow(
      signer: "abcd",
      npub: "npub1x",
      label: "",
      uri: "bunker://x?secret=s",
      auth_uri: "bunker://x",
    )
  assert !string.contains(render([account], [bunker_relay]), "Getting started")
}
