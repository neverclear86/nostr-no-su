//// 管理 UI のパスの定義と、状態の見せ方（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
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

/// リレーとプラグインのすべての状態と、承認待ち 1 件を持つスナップショット。
fn states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    accounts: Ok([]),
    pending: [
      dashboard.PendingRow(
        token: "tok",
        signer: "abcd",
        client: "ef01",
        age_seconds: 12,
      ),
    ],
    sessions: [],
    relays: [
      dashboard.RelayRow(
        dashboard.MonitorRelay,
        "wss://a",
        relay_connection.Connected,
      ),
      dashboard.RelayRow(
        dashboard.BunkerRelay,
        "wss://b",
        relay_connection.Disconnected,
      ),
    ],
    plugins: [
      dashboard.PluginRow("a", Some(plugin_runner.Running)),
      dashboard.PluginRow("b", Some(plugin_runner.Overloaded(dropped: 4))),
      dashboard.PluginRow(
        "c",
        Some(plugin_runner.Disabled(reason: "boom", dropped: 2)),
      ),
      dashboard.PluginRow("d", None),
    ],
  )
}

/// リレーとプラグインの状態は、状態ごとの色のバッジで出し、状態の語と詳細を文字で残す。
/// プラグイン由来の理由は英語のまま `lang="en"` を付けて出す。
pub fn states_are_shown_as_badges_test() {
  let body = dashboard.render(i18n.English, states())
  let badges = [
    "<td class=\"whitespace-nowrap\">monitor</td>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">connected</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">running</span>",
    "<span class=\"badge badge-sm badge-warning whitespace-nowrap\">overloaded</span><span class=\"text-xs break-words\">(dropped 4)</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">disabled</span><span class=\"text-xs break-words\"><span lang=\"en\">boom</span> (dropped 2)</span>",
    "<span class=\"badge badge-sm badge-ghost whitespace-nowrap\">unavailable</span>",
    "<dd class=\"break-words\">12s</dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 日本語のダッシュボードでは、状態の語、件数、経過時間を日本語の形で出す。バッジの
/// クラスは英語と同じである。
pub fn japanese_states_are_translated_test() {
  let body = dashboard.render(i18n.Japanese, states())
  let badges = [
    "<td class=\"whitespace-nowrap\">監視</td>",
    "<td class=\"whitespace-nowrap\">バンカー</td>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">接続中</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">未接続</span>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">動作中</span>",
    "<span class=\"badge badge-sm badge-warning whitespace-nowrap\">過負荷</span><span class=\"text-xs break-words\">（破棄 4 件）</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">無効</span><span class=\"text-xs break-words\"><span lang=\"en\">boom</span>（破棄 2 件）</span>",
    "<span class=\"badge badge-sm badge-ghost whitespace-nowrap\">応答なし</span>",
    "<dd class=\"break-words\">12 秒</dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 言語の切り替えは、表示している言語を押せない項目にし、それ以外の言語をその言語の
/// コードを送るボタンにする。言語名はどちらの言語のページでも同じ文字で出す。
pub fn language_switch_marks_the_current_language_test() {
  let snapshot = dashboard.Snapshot(..states(), plugins: [], relays: [])
  assert string.contains(
    dashboard.render(i18n.English, snapshot),
    "<div class=\"navbar-end\"><form action=\"/language\" method=\"post\"><input name=\"return\" type=\"hidden\" value=\"/\"><div aria-label=\"Language\" class=\"join\" role=\"group\"><span aria-current=\"true\" class=\"btn btn-sm join-item cursor-default border-base-content bg-base-content text-base-100\" lang=\"en\">English</span><button class=\"btn btn-sm join-item focus-visible:outline-base-content\" lang=\"ja\" name=\"language\" type=\"submit\" value=\"ja\">日本語</button></div></form></div>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, snapshot),
    "<div class=\"navbar-end\"><form action=\"/language\" method=\"post\"><input name=\"return\" type=\"hidden\" value=\"/\"><div aria-label=\"言語\" class=\"join\" role=\"group\"><button class=\"btn btn-sm join-item focus-visible:outline-base-content\" lang=\"en\" name=\"language\" type=\"submit\" value=\"en\">English</button><span aria-current=\"true\" class=\"btn btn-sm join-item cursor-default border-base-content bg-base-content text-base-100\" lang=\"ja\">日本語</span></div></form></div>",
  )
}

/// 承認ページは言語を切り替えた後に同じ承認ページを、通知ページはダッシュボードを開く。
pub fn language_switch_return_paths_test() {
  let assert [pending] = states().pending
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, pending),
    "<input name=\"return\" type=\"hidden\" value=\"/approve/tok\">",
  )
  assert string.contains(
    dashboard.notice_page(
      i18n.Japanese,
      i18n.NotFound,
      i18n.Untranslated("unknown or expired approval request"),
      view.Failure,
    ),
    "<input name=\"return\" type=\"hidden\" value=\"/\">",
  )
}
