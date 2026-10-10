//// プラグインが供給するページのページ枠（`admin/plugin_pages`）の単体テスト。
////
//// 正しい形の節の記述 map は撮影用のサーバーと共通の builder（`plugin_page_builder`）で組み、
//// 変換に失敗する形（`title` を欠く節）はこのモジュールで手で組む。

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/plugin_pages
import nostr_no_su/admin/routes
import nostr_no_su/admin/view
import nostr_no_su/plugin
import nostr_no_su/plugin_runner
import plugin_page_builder.{
  checkbox_field, form_block, link_block, section, time_inline, typed_text,
}

/// `title` を欠き、変換に失敗する節。
fn broken_section() -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("section")),
    #(dynamic.string("blocks"), dynamic.list([])),
  ])
}

/// キー `status`、表示名 `Status` のページ。
const status_page = plugin.PluginPage(key: "status", title: "Status")

/// `plugin_pages.plugin_page` をテーマ `view.System` で呼ぶ。
fn render(
  language: i18n.Language,
  row: dashboard.PluginRow,
  page: plugin.PluginPage,
  now: Int,
  sections: List(Dynamic),
) -> String {
  plugin_pages.plugin_page(language, view.System, row, page, now, sections)
}

/// チェック 1 件（`enabled`）だけを持つ `form` ブロック。
fn options_form() -> Dynamic {
  form_block(
    [
      checkbox_field(
        name: "enabled",
        label: "Enabled",
        hint: None,
        checked: False,
      ),
    ],
    "Save",
  )
}

/// ページ 1 件だけを持つプラグインの行。
fn one_page_row() -> dashboard.PluginRow {
  dashboard.PluginRow("example", Some(plugin_runner.Running), pages: [
    status_page,
  ])
}

/// ページ 2 件を持つプラグインの行。
fn two_page_row() -> dashboard.PluginRow {
  dashboard.PluginRow("example", Some(plugin_runner.Running), pages: [
    status_page,
    plugin.PluginPage(key: "settings", title: "Settings"),
  ])
}

/// ページ 1 件だけなら、切り替えるものが無いのでタブを出さない。
pub fn single_page_has_no_tabs_test() {
  let body =
    render(i18n.English, one_page_row(), status_page, 0, [
      section("Queue", [], [typed_text("text", "content")]),
    ])
  assert !string.contains(body, "tabs tabs-border")
}

/// ページ 2 件なら両方のタブが出て、現在のページだけ `tab-active` と
/// `aria-current="page"` を持つ。表示名はプラグイン由来の英語なので `lang="en"` の
/// 中に出る。
pub fn two_pages_show_tabs_with_the_current_one_active_test() {
  let body =
    render(i18n.English, two_page_row(), status_page, 0, [
      section("Queue", [], [typed_text("text", "content")]),
    ])
  assert string.contains(
    body,
    "<a aria-current=\"page\" class=\"tab tab-active\" href=\"/plugins/example/status\">"
      <> "<span lang=\"en\">Status</span></a>",
  )
  assert string.contains(
    body,
    "<a class=\"tab\" href=\"/plugins/example/settings\">"
      <> "<span lang=\"en\">Settings</span></a>",
  )
}

/// 表示の言語を受け取るプラグインのページ 2 件を持つ行。
fn localized_row() -> dashboard.PluginRow {
  dashboard.PluginRow("example", Some(plugin_runner.Running), pages: [
    localized_status_page(),
    plugin.LocalizedPage(
      key: "settings",
      titles: dict.from_list([#("en", "Settings"), #("ja", "設定")]),
    ),
  ])
}

/// `localized_row` の 1 件目のページ。
fn localized_status_page() -> plugin.PluginPage {
  plugin.LocalizedPage(
    key: "status",
    titles: dict.from_list([#("en", "Status"), #("ja", "状態")]),
  )
}

/// 表示の言語を受け取るプラグインのページは、タブの表示名と節の包みを表示の言語の
/// `lang` で出す。
pub fn localized_plugin_page_is_in_the_display_language_test() {
  let japanese =
    render(i18n.Japanese, localized_row(), localized_status_page(), 0, [
      section("Queue", [], [typed_text("text", "content")]),
    ])
  assert string.contains(japanese, "<span lang=\"ja\">状態</span>")
  assert string.contains(japanese, "<span lang=\"ja\">設定</span>")
  assert string.contains(japanese, "<div lang=\"ja\">")
  assert !string.contains(japanese, "<div lang=\"en\">")
  let english =
    render(i18n.English, localized_row(), localized_status_page(), 0, [
      section("Queue", [], [typed_text("text", "content")]),
    ])
  assert string.contains(english, "<span lang=\"en\">Status</span>")
  assert string.contains(english, "<div lang=\"en\">")
}

/// タブの表示名の `lang` は、現在のページではなくタブのページごとに決まる。
pub fn each_tab_is_in_its_own_pages_language_test() {
  let row =
    dashboard.PluginRow("example", Some(plugin_runner.Running), pages: [
      status_page,
      plugin.LocalizedPage(
        key: "settings",
        titles: dict.from_list([#("en", "Settings"), #("ja", "設定")]),
      ),
    ])
  let body =
    render(i18n.Japanese, row, status_page, 0, [
      section("Queue", [], [typed_text("text", "content")]),
    ])
  assert string.contains(body, "<span lang=\"en\">Status</span>")
  assert string.contains(body, "<span lang=\"ja\">設定</span>")
}

/// 表示の言語を受け取るプラグインのページは、見出し（h1）と `<title>` のページの表示名を
/// 表示の言語で引き、その言語の `lang` で出す。
pub fn localized_heading_is_in_the_display_language_test() {
  let body =
    render(i18n.Japanese, localized_row(), localized_status_page(), 0, [
      section("Queue", [], [typed_text("text", "content")]),
    ])
  assert string.contains(
    body,
    "<h1 class=\"text-2xl font-bold\"><span lang=\"ja\">example — 状態</span></h1>",
  )
  assert string.contains(
    body,
    "<title lang=\"ja\">Nostr-no-Su — example — 状態</title>",
  )
}

/// 節が 0 件のときは、ページ全体の空の状態の文を出す。
pub fn no_sections_shows_the_empty_state_test() {
  let body = render(i18n.English, one_page_row(), status_page, 0, [])
  assert string.contains(body, i18n.text(i18n.English, i18n.PluginPageEmpty))
}

/// 節 1 つの変換が失敗しても、他の節は描かれる。失敗した節は訳した案内に続けて
/// プラグイン由来の理由を出す。
pub fn a_failed_section_does_not_stop_the_others_test() {
  let body =
    render(i18n.English, one_page_row(), status_page, 0, [
      section("Queue", [], [typed_text("text", "content")]),
      broken_section(),
    ])
  assert string.contains(body, "Queue")
  assert string.contains(
    body,
    i18n.text(i18n.English, i18n.PluginSectionFailed),
  )
  assert string.contains(body, "<span lang=\"en\">missing title</span>")
}

/// `Disabled` のときは、イベントを処理していない旨の注意を出す。
pub fn disabled_plugin_shows_a_warning_test() {
  let row =
    dashboard.PluginRow(
      "example",
      Some(plugin_runner.Disabled(reason: "boom", dropped: 1)),
      pages: [status_page],
    )
  let body =
    render(i18n.English, row, status_page, 0, [
      section("Queue", [], [typed_text("text", "content")]),
    ])
  assert string.contains(
    body,
    i18n.text(i18n.English, i18n.PluginPageWhileDisabled),
  )
}

/// 見出し（h1）と `<title>` にプラグイン名とページの表示名を ` — ` でつないで出す。
/// どちらもプラグイン由来の英語なので、表示の言語が日本語でも `lang="en"` の中に出し（節の
/// `div` も同じ）、訳した「プラグインのページ」は出さない。
pub fn heading_shows_the_plugin_and_page_names_test() {
  let body =
    render(i18n.Japanese, one_page_row(), status_page, 0, [
      section("Summary", [], [typed_text("text", "content")]),
    ])
  assert string.contains(
    body,
    "<h1 class=\"text-2xl font-bold\"><span lang=\"en\">example — Status</span></h1>",
  )
  assert string.contains(
    body,
    "<title lang=\"en\">Nostr-no-Su — example — Status</title>",
  )
  assert !string.contains(body, "<title>Nostr-no-Su — プラグインのページ</title>")
  assert string.contains(body, "<div lang=\"en\">")
}

/// インライン `time` の相対時刻は `plugin_page` に渡した `now` を基準にする。
pub fn plugin_page_times_are_relative_to_now_test() {
  let html =
    render(i18n.English, one_page_row(), status_page, 1000 + 7200, [
      section("Queue", [time_inline(1000)], []),
    ])
  assert string.contains(html, ">2 h ago</span>")
}

/// `form` ブロックの宛先は、今開いているページ自身のパス（`routes.href`）になる。
pub fn plugin_page_form_posts_to_the_current_page_test() {
  let body =
    render(
      i18n.English,
      two_page_row(),
      plugin.PluginPage(key: "settings", title: "Settings"),
      0,
      [section("Options", [], [options_form()])],
    )
  assert string.contains(
    body,
    "<form action=\""
      <> routes.href(routes.ShowPluginPage("example", "settings"))
      <> "\"",
  )
}

/// タブのリンク、`link` ブロックのリンク、フォームの宛先はプラグイン名を percent-encode し、
/// テーマと言語の切り替えの戻り先は符号化しないパスにする（受け取る側がセグメントを符号化するため）。
pub fn plugin_name_is_encoded_in_links_but_not_in_the_return_path_test() {
  let row =
    dashboard.PluginRow("a b", Some(plugin_runner.Running), pages: [
      status_page,
      plugin.PluginPage(key: "settings", title: "Settings"),
    ])
  let body =
    render(
      i18n.English,
      row,
      plugin.PluginPage(key: "settings", title: "Settings"),
      0,
      [
        section("See also", [], [link_block("settings", "Open")]),
        section("Options", [], [options_form()]),
      ],
    )
  assert string.contains(body, "href=\"/plugins/a%20b/status\"")
  assert list.length(string.split(body, "href=\"/plugins/a%20b/settings\""))
    == 3
  assert string.contains(body, "<form action=\"/plugins/a%20b/settings\"")
  assert string.contains(body, "value=\"/plugins/a b/settings\"")
}
