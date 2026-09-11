//// 管理 UI のアカウントのページの描画（`admin/account_pages`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/account_pages
import nostr_no_su/admin/dashboard
import support/account_actions

/// HTML として解釈されうるラベル。
const hostile = "<script>\"x\"</script>"

/// `hostile` をエスケープした表記。
const escaped = "&lt;script&gt;&quot;x&quot;&lt;/script&gt;"

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
    account_pages.registered_page("npub1example", hostile, "nsec1example"),
    account_pages.private_key_page(row(hostile), "nsec1example"),
    ..list.map(account_actions.all, account_pages.account_action_page(
      row(hostile),
      _,
      None,
    ))
  ]
  use page <- list.each(pages)
  assert string.contains(page, escaped)
  assert !string.contains(page, hostile)
}

/// フォームの上に出す理由はエスケープして出す。
pub fn error_reasons_are_escaped_test() {
  let pages = [
    account_pages.new_account_page(Some(hostile)),
    account_pages.account_action_page(
      row("main"),
      dashboard.EditLabel,
      Some(hostile),
    ),
  ]
  use page <- list.each(pages)
  assert string.contains(
    page,
    "<div class=\"alert alert-error\" role=\"alert\"><span>"
      <> escaped
      <> "</span></div>",
  )
  assert !string.contains(page, hostile)
}

/// コピーのボタンの処理は値によらず同じで、値を含まない。値は `name` の無い読み取り
/// 専用の欄に、エスケープして入る。コピーの欄は、処理が頼る形（欄はボタンの直前の兄弟、
/// 囲みはボタンの親の親、`role="status"` は囲みの直下）で出す。形が崩れてもコピーはできて
/// しまい、完了の表示と読み上げだけが消えるので、欄全体を照合する。
pub fn copy_button_reads_the_value_from_the_page_test() {
  let first = account_pages.private_key_page(row("main"), "nsec1first\"")
  let second = account_pages.private_key_page(row("main"), "nsec1second")
  assert onclick(first) == onclick(second)
  assert !string.contains(onclick(first), "nsec1")
  assert string.contains(
    first,
    "<div class=\"fieldset group\"><span class=\"fieldset-legend\">Private key (nsec)</span><div class=\"join w-full\"><input aria-label=\"Private key (nsec)\" class=\"input join-item w-full min-w-0 font-mono text-xs border-base-content/60\" readonly type=\"text\" value=\"nsec1first&quot;\"><button class=\"btn join-item group-data-copied:btn-success focus-visible:outline-base-content\" onclick=\""
      <> onclick(first)
      <> "\" type=\"button\">",
  )
  assert string.contains(
    first,
    "</button></div><span class=\"sr-only\" role=\"status\"><span class=\"hidden group-data-copied:inline\">Copied</span></span></div>",
  )
}
