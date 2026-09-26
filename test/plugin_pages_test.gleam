//// プラグインが供給するページのページ枠（`admin/plugin_pages`）の単体テスト。
////
//// 節の記述 map は `test/plugin_view_test.gleam` と同じ形（`dynamic.properties` /
//// `dynamic.string` / `dynamic.list`）で組む。

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{Some}
import gleam/string
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/plugin_pages
import nostr_no_su/admin/routes
import nostr_no_su/admin/view
import nostr_no_su/plugin
import nostr_no_su/plugin_runner

/// binary キーの map をキーと値の組から組み立てる。
fn map_(entries: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    entries |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) }),
  )
}

/// 節。ブロック 1 つ（`text`）を持つ。
fn section_(title: String) -> Dynamic {
  map_([
    #("type", dynamic.string("section")),
    #("title", dynamic.string(title)),
    #(
      "blocks",
      dynamic.list([
        map_([
          #("type", dynamic.string("text")),
          #("text", dynamic.string("content")),
        ]),
      ]),
    ),
  ])
}

/// 見出しの補足（`meta`）に Unix 秒 `at` の `time` を 1 件置いた、ブロックの無い節。
fn section_with_time(title: String, at: Int) -> Dynamic {
  map_([
    #("type", dynamic.string("section")),
    #("title", dynamic.string(title)),
    #(
      "meta",
      dynamic.list([
        map_([#("type", dynamic.string("time")), #("value", dynamic.int(at))]),
      ]),
    ),
    #("blocks", dynamic.list([])),
  ])
}

/// `form` ブロック 1 つ（チェック 1 件）を持つ節。
fn section_with_form(title: String) -> Dynamic {
  map_([
    #("type", dynamic.string("section")),
    #("title", dynamic.string(title)),
    #(
      "blocks",
      dynamic.list([
        map_([
          #("type", dynamic.string("form")),
          #(
            "fields",
            dynamic.list([
              map_([
                #("type", dynamic.string("checkbox")),
                #("name", dynamic.string("enabled")),
                #("label", dynamic.string("Enabled")),
              ]),
            ]),
          ),
          #("submit", dynamic.string("Save")),
        ]),
      ]),
    ),
  ])
}

/// `title` を欠き、変換に失敗する節。
fn broken_section() -> Dynamic {
  map_([#("type", dynamic.string("section")), #("blocks", dynamic.list([]))])
}

/// ページ 1 件だけを持つプラグインの行。
fn one_page_row() -> dashboard.PluginRow {
  dashboard.PluginRow("example", Some(plugin_runner.Running), pages: [
    plugin.PluginPage(key: "status", title: "Status"),
  ])
}

/// ページ 2 件を持つプラグインの行。
fn two_page_row() -> dashboard.PluginRow {
  dashboard.PluginRow("example", Some(plugin_runner.Running), pages: [
    plugin.PluginPage(key: "status", title: "Status"),
    plugin.PluginPage(key: "settings", title: "Settings"),
  ])
}

/// ページ 1 件だけなら、切り替えるものが無いのでタブを出さない。
pub fn single_page_has_no_tabs_test() {
  let body =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      one_page_row(),
      plugin.PluginPage(key: "status", title: "Status"),
      0,
      [section_("Queue")],
    )
  assert !string.contains(body, "tabs tabs-border")
}

/// ページ 2 件なら両方のタブが出て、現在のページだけ `tab-active` と
/// `aria-current="page"` を持つ。表示名はプラグイン由来の英語なので `lang="en"` の
/// 中に出る。
pub fn two_pages_show_tabs_with_the_current_one_active_test() {
  let body =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      two_page_row(),
      plugin.PluginPage(key: "status", title: "Status"),
      0,
      [section_("Queue")],
    )
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
    plugin_pages.plugin_page(
      i18n.Japanese,
      view.System,
      localized_row(),
      localized_status_page(),
      0,
      [section_("Queue")],
    )
  assert string.contains(japanese, "<span lang=\"ja\">状態</span>")
  assert string.contains(japanese, "<span lang=\"ja\">設定</span>")
  assert string.contains(japanese, "<div lang=\"ja\">")
  assert !string.contains(japanese, "<div lang=\"en\">")
  let english =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      localized_row(),
      localized_status_page(),
      0,
      [section_("Queue")],
    )
  assert string.contains(english, "<span lang=\"en\">Status</span>")
  assert string.contains(english, "<div lang=\"en\">")
}

/// 表示の言語を受け取るプラグインのページは、見出し（h1）と `<title>` のページの表示名を
/// 表示の言語で引き、その言語の `lang` で出す。
pub fn localized_heading_is_in_the_display_language_test() {
  let body =
    plugin_pages.plugin_page(
      i18n.Japanese,
      view.System,
      localized_row(),
      localized_status_page(),
      0,
      [section_("Queue")],
    )
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
  let body =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      one_page_row(),
      plugin.PluginPage(key: "status", title: "Status"),
      0,
      [],
    )
  assert string.contains(body, i18n.text(i18n.English, i18n.PluginPageEmpty))
}

/// 節 1 つの変換が失敗しても、他の節は描かれる。失敗した節は訳した案内に続けて
/// プラグイン由来の理由を出す。
pub fn a_failed_section_does_not_stop_the_others_test() {
  let body =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      one_page_row(),
      plugin.PluginPage(key: "status", title: "Status"),
      0,
      [section_("Queue"), broken_section()],
    )
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
      pages: [plugin.PluginPage(key: "status", title: "Status")],
    )
  let body =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      row,
      plugin.PluginPage(key: "status", title: "Status"),
      0,
      [section_("Queue")],
    )
  assert string.contains(
    body,
    i18n.text(i18n.English, i18n.PluginPageWhileDisabled),
  )
}

/// 見出し（h1）と `<title>` にプラグイン名とページの表示名を ` — ` でつないで出す。
/// どちらもプラグイン由来の英語なので、表示の言語が日本語でも `lang="en"` の中に出し、
/// 訳した「プラグインのページ」は出さない。
pub fn heading_shows_the_plugin_and_page_names_test() {
  let body =
    plugin_pages.plugin_page(
      i18n.Japanese,
      view.System,
      one_page_row(),
      plugin.PluginPage(key: "status", title: "Status"),
      0,
      [section_("Summary")],
    )
  assert string.contains(
    body,
    "<h1 class=\"text-2xl font-bold\"><span lang=\"en\">example — Status</span></h1>",
  )
  assert string.contains(
    body,
    "<title lang=\"en\">Nostr-no-Su — example — Status</title>",
  )
  assert !string.contains(body, "<title>Nostr-no-Su — プラグインのページ</title>")
}

/// インライン `time` の相対時刻は `plugin_page` に渡した `now` を基準にする。
pub fn plugin_page_times_are_relative_to_now_test() {
  let html =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      one_page_row(),
      plugin.PluginPage(key: "status", title: "Status"),
      1000 + 7200,
      [section_with_time("Queue", 1000)],
    )
  assert string.contains(html, ">2 h ago</span>")
}

/// `form` ブロックの宛先は、今開いているページ自身のパス（`routes.plugin_page_href`）になる。
pub fn plugin_page_form_posts_to_the_current_page_test() {
  let body =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      two_page_row(),
      plugin.PluginPage(key: "settings", title: "Settings"),
      0,
      [section_with_form("Options")],
    )
  assert string.contains(
    body,
    "<form action=\"" <> routes.plugin_page_href("example", "settings") <> "\"",
  )
}
