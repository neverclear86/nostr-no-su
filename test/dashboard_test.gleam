//// 管理 UI の描画（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/dashboard

/// HTML として解釈されうるラベル。
const hostile = "<script>\"x\"</script>"

/// `hostile` をエスケープした表記。
const escaped = "&lt;script&gt;&quot;x&quot;&lt;/script&gt;"

/// アカウント 1 件への操作のすべて。
const actions = [
  dashboard.EditLabel,
  dashboard.RotateSecret,
  dashboard.DeleteAccount,
  dashboard.RevealPrivateKey,
]

/// 指定したラベルを持つアカウントの行。
fn row(label: String) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer: "abcd",
    npub: "npub1example",
    label: label,
    uri: "bunker://abcd?relay=x&secret=s",
    auth_uri: "bunker://abcd?relay=x",
  )
}

/// ページの最初のコピーのボタンの `onclick` の属性値。
fn onclick(page: String) -> String {
  let assert Ok(#(_before, rest)) = string.split_once(page, "onclick=\"")
  let assert Ok(#(script, _after)) = string.split_once(rest, "\"")
  script
}

/// ラベルは、完了ページ、再表示のページ、操作のページのどれでもエスケープして出す。
pub fn account_pages_escape_the_label_test() {
  let pages = [
    dashboard.registered_page("npub1example", hostile, "nsec1example"),
    dashboard.private_key_page(row(hostile), "nsec1example"),
    ..list.map(actions, dashboard.account_action_page(row(hostile), _, None))
  ]
  use page <- list.each(pages)
  assert string.contains(page, escaped)
  assert !string.contains(page, hostile)
}

/// フォームの上に出す理由はエスケープして出す。
pub fn error_reasons_are_escaped_test() {
  let pages = [
    dashboard.new_account_page(Some(hostile)),
    dashboard.account_action_page(
      row("main"),
      dashboard.EditLabel,
      Some(hostile),
    ),
  ]
  use page <- list.each(pages)
  assert string.contains(page, "<p role=\"alert\">" <> escaped <> "</p>")
  assert !string.contains(page, hostile)
}

/// コピーのボタンの処理は値によらず同じで、値を含まない。値は `name` の無い読み取り
/// 専用の欄に、エスケープして入る。
pub fn copy_button_reads_the_value_from_the_page_test() {
  let first = dashboard.private_key_page(row("main"), "nsec1first\"")
  let second = dashboard.private_key_page(row("main"), "nsec1second")
  assert onclick(first) == onclick(second)
  assert !string.contains(onclick(first), "nsec1")
  assert string.contains(
    first,
    "<input type=\"text\" readonly size=\"64\" value=\"nsec1first&quot;\">",
  )
}

/// 操作のパスは、どの操作でもパスセグメントから同じ署名者と操作に戻る。
pub fn account_action_paths_round_trip_test() {
  use action <- list.each(actions)
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
