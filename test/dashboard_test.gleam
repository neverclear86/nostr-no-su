//// 管理 UI のパスの定義（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/string
import nostr_no_su/admin/dashboard
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
