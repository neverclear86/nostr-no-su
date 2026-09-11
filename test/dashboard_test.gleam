//// 管理 UI のパスの定義と、状態の見せ方（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/dashboard
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

/// リレーとプラグインの状態は、状態ごとの色のバッジで出し、状態の語と詳細を文字で残す。
pub fn states_are_shown_as_badges_test() {
  let body =
    dashboard.render(
      dashboard.Snapshot(
        accounts: Ok([]),
        pending: [],
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
      ),
    )
  let badges = [
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">connected</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">running</span>",
    "<span class=\"badge badge-sm badge-warning whitespace-nowrap\">overloaded</span><span class=\"text-xs break-words\">(dropped 4)</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">disabled</span><span class=\"text-xs break-words\">boom (dropped 2)</span>",
    "<span class=\"badge badge-sm badge-ghost whitespace-nowrap\">unavailable</span>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}
