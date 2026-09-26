//// プラグインが供給する管理 UI のページのページ枠（見出し、出どころの行、タブ、節の
//// 並び、戻るリンク）の組み立て。節 1 つの記述から `admin/view` の部品への変換は
//// `admin/plugin_view` に委ね、このモジュールは節の並びと `Error` の囲みだけを持つ。
//// プラグインが持ち込める値の規則は `admin/plugin_view` のモジュール Doc にある。
//// フォームの宛先は今開いているページ自身。

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/plugin_view
import nostr_no_su/admin/routes
import nostr_no_su/admin/view
import nostr_no_su/plugin
import nostr_no_su/plugin_runner

/// プラグインのページ 1 枚を HTML 文書の文字列にする。見出しと `<title>` は `page_heading` で、
/// プラグイン由来の文字列なので、`view.TaggedTitle` で `plugin.text_language` の言語として
/// 出す。`raw_sections` は `plugin_view.sections` が最上位の記述から取り出した節の記述の並び。
/// `now` は描画時点の Unix 秒で、インライン `time` の相対時刻の基準になる。
pub fn plugin_page(
  language: Language,
  theme: view.Theme,
  plugin: dashboard.PluginRow,
  page: plugin.PluginPage,
  now: Int,
  raw_sections: List(Dynamic),
) -> String {
  let code = i18n.code(language)
  view.page(
    language,
    theme,
    view.TaggedTitle(
      code: plugin.text_language(page, code),
      text: page_heading(plugin, page, code),
    ),
    view.Narrow,
    view.SwitchReturningTo(routes.plugin_page_path(plugin.name, page.key)),
    view.NoRefresh,
    list.flatten([
      [source_row(language, plugin), tabs(language, plugin, page)],
      disabled_alert(language, plugin),
      sections(language, plugin, page, now, raw_sections),
      [view.back_link(language)],
    ]),
  )
}

/// ページの見出し。プラグイン名と、言語のコード `code` で引いたページの表示名
/// （`plugin.title_in`）を ` — ` でつなぐ（例: `event_logger — Settings`）。
fn page_heading(
  plugin: dashboard.PluginRow,
  page: plugin.PluginPage,
  code: String,
) -> String {
  plugin.name <> " — " <> plugin.title_in(page, code)
}

/// プラグイン名と現在の状態の行。
fn source_row(language: Language, plugin: dashboard.PluginRow) -> Element(msg) {
  html.div([attribute.class("flex flex-wrap items-center gap-2")], [
    view.puzzle_icon(),
    view.untranslated(plugin.name),
    dashboard.plugin_state(language, plugin),
  ])
}

/// 供給するページが 2 つ以上のときだけ出すタブ。表示名は `plugin.title_in` で表示の
/// 言語のものを引き、`plugin.text_language` の `lang` を持つ `span`
/// （`view.in_language`）に包む。
fn tabs(
  language: Language,
  plugin: dashboard.PluginRow,
  current: plugin.PluginPage,
) -> Element(msg) {
  case plugin.pages {
    [] | [_] -> element.none()
    pages ->
      html.nav(
        [attribute.class("tabs tabs-border")],
        list.map(pages, tab_link(language, plugin.name, current, _)),
      )
  }
}

/// タブ 1 件。現在のページには `tab-active` と `aria-current="page"` を付ける。
fn tab_link(
  language: Language,
  plugin_name: String,
  current: plugin.PluginPage,
  page: plugin.PluginPage,
) -> Element(msg) {
  let href = routes.plugin_page_href(plugin_name, page.key)
  let attrs = case page.key == current.key {
    True -> [
      attribute.href(href),
      attribute.class("tab tab-active"),
      attribute.aria_current("page"),
    ]
    False -> [attribute.href(href), attribute.class("tab")]
  }
  let code = i18n.code(language)
  html.a(attrs, [
    view.in_language(
      plugin.text_language(page, code),
      plugin.title_in(page, code),
    ),
  ])
}

/// `Disabled` のときだけ、イベントを処理していない旨の注意を 1 要素のリストで返す。
fn disabled_alert(
  language: Language,
  plugin: dashboard.PluginRow,
) -> List(Element(msg)) {
  case plugin.status {
    Some(plugin_runner.Disabled(..)) -> [
      view.alert(view.Warning, [
        html.text(i18n.text(language, i18n.PluginPageWhileDisabled)),
      ]),
    ]
    _ -> []
  }
}

/// 節の並び。0 件ならページ全体の空の状態の文、そうでなければ節ごとに
/// `plugin_view.section` を当て、`Error` はその節ひとつぶんを訳文とプラグイン由来の
/// 理由の囲みに差し替える（他の節の描画は止めない）。
fn sections(
  language: Language,
  plugin: dashboard.PluginRow,
  page: plugin.PluginPage,
  now: Int,
  raw: List(Dynamic),
) -> List(Element(msg)) {
  case raw {
    [] -> [
      view.empty_state(
        view.puzzle_icon(),
        i18n.text(language, i18n.PluginPageEmpty),
        [],
      ),
    ]
    raw_sections -> {
      let context = context(language, plugin, page, now)
      list.map(raw_sections, fn(raw_section) {
        case plugin_view.section(raw_section, context) {
          Ok(element) -> element
          Error(reason) -> section_failure(language, reason)
        }
      })
    }
  }
}

/// 節 1 つの変換の失敗。訳した案内の後にプラグイン由来の理由を続ける。
fn section_failure(language: Language, reason: String) -> Element(msg) {
  view.alert(view.Failure, [
    html.text(
      i18n.text(language, i18n.PluginSectionFailed)
      <> i18n.sentence_gap(language),
    ),
    view.untranslated(reason),
  ])
}

/// 表示中のプラグインとページから、節の描画に渡す `plugin_view.Context` を組み立てる。
fn context(
  language: Language,
  plugin: dashboard.PluginRow,
  page: plugin.PluginPage,
  now: Int,
) -> plugin_view.Context {
  plugin_view.Context(
    language:,
    plugin_language: plugin.text_language(page, i18n.code(language)),
    page_href: fn(key) {
      case list.any(plugin.pages, fn(page) { page.key == key }) {
        True -> Ok(routes.plugin_page_href(plugin.name, key))
        False -> Error(Nil)
      }
    },
    form_action: routes.plugin_page_href(plugin.name, page.key),
    now:,
  )
}
