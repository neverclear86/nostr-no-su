//// プラグインの記述 map から `admin/view` の部品への変換（`admin/plugin_view`）の
//// 単体テスト。
////
//// 記述 map は `dynamic.properties` / `dynamic.string` / `dynamic.list` で組む
//// （`test/event_test.gleam` と同じ形）。

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import nostr_no_su/admin/i18n
import nostr_no_su/admin/plugin_view.{Context}
import nostr_no_su/admin/view

/// binary キーの map をキーと値の組から組み立てる。
fn map_(entries: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    entries |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) }),
  )
}

/// インライン（`text`）。
fn text_inline(text: String) -> Dynamic {
  map_([#("type", dynamic.string("text")), #("text", dynamic.string(text))])
}

/// インライン（`code`）。
fn code_inline(text: String) -> Dynamic {
  map_([#("type", dynamic.string("code")), #("text", dynamic.string(text))])
}

/// インライン（`badge`）。
fn badge_inline(text: String, tone: String) -> Dynamic {
  map_([
    #("type", dynamic.string("badge")),
    #("text", dynamic.string(text)),
    #("tone", dynamic.string(tone)),
  ])
}

/// インライン（`id`）。
fn id_inline(text: String) -> Dynamic {
  map_([#("type", dynamic.string("id")), #("text", dynamic.string(text))])
}

/// ブロック（`text`）。
fn text_block(text: String) -> Dynamic {
  map_([#("type", dynamic.string("text")), #("text", dynamic.string(text))])
}

/// ブロック（`note`）。
fn note_block(text: String) -> Dynamic {
  map_([#("type", dynamic.string("note")), #("text", dynamic.string(text))])
}

/// ブロック（`pairs`）。`items` は `#(term, value)` の並び。
fn pairs_block(items: List(#(String, Dynamic))) -> Dynamic {
  map_([
    #("type", dynamic.string("pairs")),
    #(
      "items",
      dynamic.list(
        list.map(items, fn(item) {
          map_([#("term", dynamic.string(item.0)), #("value", item.1)])
        }),
      ),
    ),
  ])
}

/// ブロック（`table`）。
fn table_block(headers: List(String), rows: List(List(Dynamic))) -> Dynamic {
  map_([
    #("type", dynamic.string("table")),
    #("headers", dynamic.list(list.map(headers, dynamic.string))),
    #("rows", dynamic.list(list.map(rows, dynamic.list))),
  ])
}

/// ブロック（`alert`）。
fn alert_block(text: String) -> Dynamic {
  map_([#("type", dynamic.string("alert")), #("text", dynamic.string(text))])
}

/// ブロック（`link`）。
fn link_block(page: String, text: String) -> Dynamic {
  map_([
    #("type", dynamic.string("link")),
    #("page", dynamic.string(page)),
    #("text", dynamic.string(text)),
  ])
}

/// ブロック（`details`）。
fn details_block(summary: String, text: String) -> Dynamic {
  map_([
    #("type", dynamic.string("details")),
    #("summary", dynamic.string(summary)),
    #("text", dynamic.string(text)),
  ])
}

/// ブロック（`image`）。
fn image_block(url: String, alt: String) -> Dynamic {
  map_([
    #("type", dynamic.string("image")),
    #("url", dynamic.string(url)),
    #("alt", dynamic.string(alt)),
  ])
}

/// ブロック（`form`）。`fields` は欄の記述の並び。
fn form_block(fields: List(Dynamic), submit: String) -> Dynamic {
  map_([
    #("type", dynamic.string("form")),
    #("fields", dynamic.list(fields)),
    #("submit", dynamic.string(submit)),
  ])
}

/// 欄（`checkbox`）。
fn checkbox_field(
  name: String,
  label: String,
  hint: Option(String),
  checked: Bool,
) -> Dynamic {
  let hint_entry = case hint {
    Some(hint) -> [#("hint", dynamic.string(hint))]
    None -> []
  }
  map_(
    list.flatten([
      [
        #("type", dynamic.string("checkbox")),
        #("name", dynamic.string(name)),
        #("label", dynamic.string(label)),
        #("checked", dynamic.bool(checked)),
      ],
      hint_entry,
    ]),
  )
}

/// 欄（`text`）。
fn text_field(
  name: String,
  label: String,
  hint: Option(String),
  value: Option(String),
) -> Dynamic {
  map_(
    list.flatten([
      [
        #("type", dynamic.string("text")),
        #("name", dynamic.string(name)),
        #("label", dynamic.string(label)),
      ],
      optional_entry("hint", hint),
      optional_entry("value", value),
    ]),
  )
}

/// 欄（`textarea`）。キーの意味は `text_field` と同じ。
fn textarea_field(
  name: String,
  label: String,
  hint: Option(String),
  value: Option(String),
) -> Dynamic {
  map_(
    list.flatten([
      [
        #("type", dynamic.string("textarea")),
        #("name", dynamic.string(name)),
        #("label", dynamic.string(label)),
      ],
      optional_entry("hint", hint),
      optional_entry("value", value),
    ]),
  )
}

/// `key` の任意の値の組。無ければ空のリスト。
fn optional_entry(
  key: String,
  value: Option(String),
) -> List(#(String, Dynamic)) {
  case value {
    Some(value) -> [#(key, dynamic.string(value))]
    None -> []
  }
}

/// 節。
fn section_(title: String, blocks: List(Dynamic)) -> Dynamic {
  map_([
    #("type", dynamic.string("section")),
    #("title", dynamic.string(title)),
    #("blocks", dynamic.list(blocks)),
  ])
}

/// テストが使う文脈。ページのキー `settings` だけを解決できる。
fn context() -> plugin_view.Context {
  Context(
    language: i18n.English,
    page_href: fn(key) {
      case key {
        "settings" -> Ok("/plugins/example/settings")
        _ -> Error(Nil)
      }
    },
    form_action: "/plugins/example/settings",
  )
}

/// 対応する種別ごとの部品で、対応する文字列とクラスで描かれる。
pub fn section_renders_every_block_type_test() {
  let raw =
    section_("Settings", [
      text_block("A plain paragraph."),
      note_block("A quieter note."),
      pairs_block([
        #("state", text_inline("running")),
        #("id", code_inline("abc123")),
      ]),
      table_block(["Name", "Status"], [
        [text_inline("worker"), badge_inline("ok", "success")],
      ]),
      alert_block("Something happened."),
      link_block("settings", "Open settings"),
    ])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)

  assert string.contains(
    body,
    element.to_string(view.form_description("A plain paragraph.")),
  )
  assert string.contains(body, element.to_string(view.hint("A quieter note.")))
  assert string.contains(
    body,
    element.to_string(
      view.summary_list([
        #("state", view.Plain("running")),
        #("id", view.Code("abc123")),
      ]),
    ),
  )
  assert string.contains(body, "worker")
  assert string.contains(
    body,
    element.to_string(view.status_badge(view.Success, "ok")),
  )
  assert string.contains(
    body,
    element.to_string(view.alert(view.Info, [html.text("Something happened.")])),
  )
  assert string.contains(
    body,
    element.to_string(view.button_link(
      "/plugins/example/settings",
      "Open settings",
      view.Normal,
    )),
  )
}

/// 未知の種別は、節の見出しとブロックの位置を添えた 1 行の `Error` になる。
pub fn unknown_type_is_an_error_test() {
  let raw = section_("設定", [map_([#("type", dynamic.string("chart"))])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason == "section \"設定\": block #0: unknown type \"chart\""
}

/// 節の `type` が `"section"` でなければ `Error` になる（決めたこと 10）。
pub fn section_type_mismatch_is_an_error_test() {
  let raw =
    map_([
      #("type", dynamic.string("note")),
      #("title", dynamic.string("設定")),
      #("blocks", dynamic.list([])),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason == "unknown type \"note\""
}

/// 型の合わない値は `Error` になる。
pub fn wrong_value_type_is_an_error_test() {
  let bad_value =
    map_([#("type", dynamic.string("text")), #("text", dynamic.int(1))])
  let raw = section_("Values", [pairs_block([#("state", bad_value)])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "text must be a String, got Int")
}

/// `pairs` の `items` の 2 件目に型の合わない値があると、理由に何件目かが
/// 付く。
pub fn wrong_value_type_reports_item_index_test() {
  let good = text_inline("ok")
  let bad = map_([#("type", dynamic.string("text")), #("text", dynamic.int(1))])
  let raw = section_("Values", [pairs_block([#("a", good), #("b", bad)])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "item #1: text must be a String, got Int")
}

/// `table` の `rows` の 2 件目がリストでないと、理由に何件目かが付く。
pub fn row_not_a_list_reports_row_index_test() {
  let raw =
    section_("Cells", [
      map_([
        #("type", dynamic.string("table")),
        #("headers", dynamic.list([dynamic.string("A")])),
        #(
          "rows",
          dynamic.list([
            dynamic.list([text_inline("ok")]),
            dynamic.string("nope"),
          ]),
        ),
      ]),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "row #1: must be a List")
}

/// 節をブロックとして入れ子にすると、種別が閉じた段に合わないので `Error`
/// になる。
pub fn nested_section_is_an_error_test() {
  let nested =
    map_([
      #("type", dynamic.string("section")),
      #("title", dynamic.string("Inner")),
      #("blocks", dynamic.list([])),
    ])
  let raw = section_("Outer", [nested])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "unknown type \"section\"")
}

/// `table` のセルにブロックを置くと、インラインの段に合わないので `Error` に
/// なる。
pub fn block_in_a_cell_is_an_error_test() {
  let raw = section_("Cells", [table_block(["A"], [[table_block(["B"], [])]])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "unknown type \"table\"")
}

/// `sections` が返す節はそれぞれ独立に描画される。壊れた節が 1 つあっても、
/// 他の節は `Ok` になる。
pub fn other_sections_still_render_test() {
  let description =
    map_([
      #(
        "sections",
        dynamic.list([
          section_("Broken", [map_([#("type", dynamic.string("mystery"))])]),
          section_("Fine", [text_block("ok")]),
        ]),
      ),
    ])
  let assert Ok(raw_sections) = plugin_view.sections(description)
  let assert [Error(_), Ok(_)] =
    list.map(raw_sections, plugin_view.section(_, context()))
}

/// 節のカードの中身（見出しとブロック）は `lang="en"` の 1 つの祖先の中にある。
pub fn plugin_text_is_marked_english_test() {
  let raw = section_("English Only", [text_block("Some plugin text.")])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  let assert [_, after] = string.split(body, "<div lang=\"en\">")
  assert string.contains(after, "English Only")
  assert string.contains(after, "Some plugin text.")
}

/// `blocks` が空の節には翻訳した空の状態の文が出て、それは `lang="en"` の外に
/// 置かれる。
pub fn empty_section_shows_the_translated_line_test() {
  let raw = section_("Empty", [])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  let translated = i18n.text(i18n.English, i18n.PluginSectionEmpty)
  let assert [before_close, ..] = string.split(body, "</div>")
  assert !string.contains(before_close, translated)
  assert string.contains(body, translated)
}

/// `pairs` の `items` が 0 件の節には翻訳した空の状態の文が出る。
pub fn empty_pairs_shows_the_translated_line_test() {
  let raw = section_("Has Pairs", [pairs_block([])])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(body, i18n.text(i18n.English, i18n.PluginSectionEmpty))
}

/// `pairs` の `items` が 0 件のときの訳した文は、プラグイン由来の文字列を包む
/// `lang="en"` の中ではなく、表示の言語を持つ `div` に包まれる。
pub fn empty_pairs_translated_line_has_display_language_test() {
  let raw = section_("Has Pairs", [pairs_block([])])
  let japanese_context =
    Context(
      language: i18n.Japanese,
      page_href: fn(_) { Error(Nil) },
      form_action: "/plugins/example/settings",
    )
  let assert Ok(el) = plugin_view.section(raw, japanese_context)
  let body = element.to_string(el)
  let translated = i18n.text(i18n.Japanese, i18n.PluginSectionEmpty)
  let assert [_, after_ja] = string.split(body, "<div lang=\"ja\">")
  assert string.contains(after_ja, translated)
}

/// `page_href` が `Error(Nil)` を返すキーの `link` は節の `Error` になる。
pub fn unknown_page_key_is_an_error_test() {
  let raw = section_("Links", [link_block("missing", "Go")])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "unknown page \"missing\"")
}

/// `form` は宛先・チェック・ラベル・説明・送信のボタンを描く。宛先は
/// `context.form_action`（今開いているページ自身）に固定される。
pub fn form_block_renders_checkboxes_test() {
  let raw =
    section_("Settings", [
      form_block(
        [
          checkbox_field("main", "Main account", Some("f9308a…"), True),
          checkbox_field("bot", "Bot account", None, False),
        ],
        "Save",
      ),
    ])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(view.post_form(
      "/plugins/example/settings",
      [
        view.plugin_checkbox_row("main", "Main account", Some("f9308a…"), True),
        view.plugin_checkbox_row("bot", "Bot account", None, False),
      ],
      "Save",
      view.Primary,
      view.InForm,
    )),
  )
}

/// `text` と `textarea` の欄が、それぞれの部品の描画と一致する（`hint` あり・なしの
/// 両方を並べる）。
pub fn form_block_renders_text_fields_test() {
  let raw =
    section_("Settings", [
      form_block(
        [
          text_field("name", "Name", Some("displayed publicly"), Some("Alice")),
          textarea_field("about", "About", None, Some("Hello.")),
        ],
        "Save",
      ),
    ])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(view.post_form(
      "/plugins/example/settings",
      [
        view.plugin_text_field(
          "name",
          "Name",
          Some("displayed publicly"),
          "Alice",
        ),
        view.plugin_textarea_field("about", "About", None, "Hello."),
      ],
      "Save",
      view.Primary,
      view.InForm,
    )),
  )
}

/// `value` を省いた `text` の欄は、初期値 `""` の `view.plugin_text_field` と一致する。
pub fn form_block_text_field_defaults_to_an_empty_value_test() {
  let raw =
    section_("Settings", [
      form_block([text_field("name", "Name", None, None)], "Save"),
    ])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(view.plugin_text_field("name", "Name", None, "")),
  )
}

/// `textarea` の初期値は `>…</textarea>` の内容に出る（属性ではない）。
pub fn form_block_textarea_shows_the_value_as_its_content_test() {
  let raw =
    section_("Settings", [
      form_block(
        [textarea_field("about", "About", None, Some("Hello."))],
        "Save",
      ),
    ])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(body, ">Hello.</textarea>")
}

/// `text` の欄の `name` が `[A-Za-z0-9_-]+` の外なら `Error`。
pub fn form_block_rejects_a_bad_text_field_name_test() {
  let raw =
    section_("Settings", [
      form_block([text_field("bad name", "Label", None, None)], "Save"),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "name \"bad name\" must match [A-Za-z0-9_-]+")
}

/// `checkbox` / `text` / `textarea` 以外の欄は節ひとつぶんの `Error` になる。
pub fn form_block_rejects_an_unknown_field_type_test() {
  let raw =
    section_("Settings", [
      form_block([map_([#("type", dynamic.string("select"))])], "Save"),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason
    == "section \"Settings\": block #0: field #0: unknown type \"select\""
}

/// `name` が `[A-Za-z0-9_-]+` の外なら `Error`。
pub fn form_block_rejects_a_bad_field_name_test() {
  let raw =
    section_("Settings", [
      form_block([checkbox_field("bad name", "Label", None, False)], "Save"),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "name \"bad name\" must match [A-Za-z0-9_-]+")
}

/// `fields` が 0 件なら `Error`。
pub fn form_block_rejects_empty_fields_test() {
  let raw = section_("Settings", [form_block([], "Save")])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "fields must not be empty")
}

/// `checked` が無い欄は未チェック、真偽値でなければ `Error`。
pub fn form_field_checked_defaults_to_false_test() {
  let no_checked =
    map_([
      #("type", dynamic.string("checkbox")),
      #("name", dynamic.string("main")),
      #("label", dynamic.string("Main")),
    ])
  let raw = section_("Settings", [form_block([no_checked], "Save")])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(view.plugin_checkbox_row("main", "Main", None, False)),
  )

  let bad_checked =
    map_([
      #("type", dynamic.string("checkbox")),
      #("name", dynamic.string("main")),
      #("label", dynamic.string("Main")),
      #("checked", dynamic.string("yes")),
    ])
  let raw2 = section_("Settings", [form_block([bad_checked], "Save")])
  let assert Error(reason) = plugin_view.section(raw2, context())
  assert string.contains(reason, "checked must be a Bool, got String")
}

/// `details` ブロックは `view.details_panel` に `view.preformatted` した本文を
/// 渡した出力を含む。
pub fn details_blocks_are_rendered_test() {
  let raw =
    section_("Settings", [details_block("tags (1)", "[[\"p\",\"abc\"]]")])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(
      view.details_panel("tags (1)", [view.preformatted("[[\"p\",\"abc\"]]")]),
    ),
  )
}

/// `details` ブロックは `summary` と `text` の両方が要る。
pub fn details_blocks_require_a_summary_and_text_test() {
  let missing_summary =
    map_([#("type", dynamic.string("details")), #("text", dynamic.string("x"))])
  let raw_missing_summary = section_("Settings", [missing_summary])
  let assert Error(reason_summary) =
    plugin_view.section(raw_missing_summary, context())
  assert string.contains(reason_summary, "missing summary")

  let missing_text =
    map_([
      #("type", dynamic.string("details")),
      #("summary", dynamic.string("s")),
    ])
  let raw_missing_text = section_("Settings", [missing_text])
  let assert Error(reason_text) =
    plugin_view.section(raw_missing_text, context())
  assert string.contains(reason_text, "missing text")
}

/// `pairs` の `id` の値は `view.identifier_cell` の出力になり、コピーボタンの
/// ラベル（`i18n.Copy` の訳語）を含む。
pub fn id_values_are_truncated_test() {
  let value = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"
  let raw = section_("Settings", [pairs_block([#("id", id_inline(value))])])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(view.identifier_cell(
      i18n.English,
      value,
      i18n.text(i18n.English, i18n.Copy),
    )),
  )
  assert string.contains(body, i18n.text(i18n.English, i18n.Copy))
}

/// `table` のセルに `id` を置くと `Error`。`id` は `pairs` の値だけに置ける。
pub fn id_is_rejected_in_table_cells_test() {
  let raw = section_("Cells", [table_block(["A"], [[id_inline("abc")]])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "type \"id\" is only allowed in pairs values")
}

/// `image` ブロックは `url` の scheme が `http` / `https` なら `view.plugin_image`
/// の出力を含む。
pub fn image_block_renders_image_test() {
  let cases = [
    #("https://example.com/a.png", "A picture"),
    #("http://example.com/a.png", "A picture"),
  ]
  use #(url, alt) <- list.each(cases)
  let raw = section_("Media", [image_block(url, alt)])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(body, element.to_string(view.plugin_image(url, alt)))
}

/// `url` の scheme が `http` / `https` でない（別の scheme、scheme の無い相対
/// URL、`uri.parse` が `Error` を返す文字列）と、画像を描かずに
/// `view.plugin_image_placeholder` の出力になり、`<img` の開始タグを含まない。
pub fn image_block_with_other_scheme_renders_alt_only_test() {
  let urls = [
    "data:image/png;base64,AAA", "javascript:alert(1)", "//example.com/a.png",
    "not a url at all",
  ]
  use url <- list.each(urls)
  let raw = section_("Media", [image_block(url, "A picture")])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(view.plugin_image_placeholder(
      i18n.English,
      i18n.text(i18n.English, i18n.PluginImageNotShown),
      "A picture",
    )),
  )
  assert !string.contains(body, "<img")
}

/// `image` ブロックは `url` と `alt` の両方が要り、`url` は String でなければ
/// ならない。
pub fn image_block_requires_url_and_alt_test() {
  let missing_url =
    map_([#("type", dynamic.string("image")), #("alt", dynamic.string("x"))])
  let raw_missing_url = section_("Media", [missing_url])
  let assert Error(reason_url) = plugin_view.section(raw_missing_url, context())
  assert string.contains(reason_url, "missing url")

  let missing_alt =
    map_([
      #("type", dynamic.string("image")),
      #("url", dynamic.string("https://example.com/a.png")),
    ])
  let raw_missing_alt = section_("Media", [missing_alt])
  let assert Error(reason_alt) = plugin_view.section(raw_missing_alt, context())
  assert string.contains(reason_alt, "missing alt")

  let bad_url =
    map_([
      #("type", dynamic.string("image")),
      #("url", dynamic.int(1)),
      #("alt", dynamic.string("x")),
    ])
  let raw_bad_url = section_("Media", [bad_url])
  let assert Error(reason_bad_url) = plugin_view.section(raw_bad_url, context())
  assert string.contains(reason_bad_url, "url must be a String, got Int")
}

/// `image` は `table` のセルにも `pairs` の値にも置けない。段が違うので、それぞれ
/// のインラインの decoder が読む種別の一覧に無い `unknown type "image"` になる。
pub fn image_is_not_an_inline_test() {
  let table_raw =
    section_("Cells", [
      table_block(["A"], [
        [image_block("https://example.com/a.png", "x")],
      ]),
    ])
  let assert Error(table_reason) = plugin_view.section(table_raw, context())
  assert string.contains(table_reason, "unknown type \"image\"")

  let pairs_raw =
    section_("Values", [
      pairs_block([#("a", image_block("https://example.com/a.png", "x"))]),
    ])
  let assert Error(pairs_reason) = plugin_view.section(pairs_raw, context())
  assert string.contains(pairs_reason, "value: unknown type \"image\"")
}
