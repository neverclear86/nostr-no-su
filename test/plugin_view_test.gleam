//// プラグインの記述 map から `admin/view` の部品への変換（`admin/plugin_view`）の
//// 単体テスト。
////
//// 正しい形の記述 map は撮影用のサーバーと共通の builder（`plugin_page_builder`）で組み、
//// 変換に失敗する形と、共通の builder に無い形（`alert`・`link` のブロック、キーを省いた
//// `text`・`textarea` の欄）は、このモジュールの `map_` と builder で組む。

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element
import lustre/element/html
import nostr_no_su/admin/i18n
import nostr_no_su/admin/plugin_view.{Context}
import nostr_no_su/admin/view
import plugin_page_builder.{
  badge_inline, checkbox_field, details_block, form_block, image_block,
  kind_inline, pairs_block, section, table_block, time_inline, typed_text,
}

/// binary キーの map をキーと値の組から組み立てる。
fn map_(entries: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties(
    entries |> list.map(fn(entry) { #(dynamic.string(entry.0), entry.1) }),
  )
}

/// ブロック（`alert`）。
fn alert_block(text: String) -> Dynamic {
  map_([#("type", dynamic.string("alert")), #("text", dynamic.string(text))])
}

/// ブロック（`alert`）に `tone` を持たせたもの。`tone` は形の誤りを試すため `Dynamic` で受ける。
fn alert_block_with_tone(text: String, tone: Dynamic) -> Dynamic {
  map_([
    #("type", dynamic.string("alert")),
    #("text", dynamic.string(text)),
    #("tone", tone),
  ])
}

/// ブロック（`link`）。
fn link_block(page: String, text: String) -> Dynamic {
  map_([
    #("type", dynamic.string("link")),
    #("page", dynamic.string(page)),
    #("text", dynamic.string(text)),
  ])
}

/// ブロック（`image`）に見た目の種類 `variant` を足したもの。`variant` は形の誤りを試すため
/// `Dynamic` で受ける。
fn image_block_with_variant(
  url: String,
  alt: String,
  variant: Dynamic,
) -> Dynamic {
  map_([
    #("type", dynamic.string("image")),
    #("url", dynamic.string(url)),
    #("alt", dynamic.string(alt)),
    #("variant", variant),
  ])
}

/// 欄（`text`）。`hint` と `value` は `None` ならキーを持たない（共通の builder の
/// `input_field` は両方のキーを常に持つので、キーを省いた形はこの関数で組む）。
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

/// テストが使う文脈。ページのキー `settings` だけを解決できる。
fn context() -> plugin_view.Context {
  Context(
    language: i18n.English,
    plugin_language: "en",
    page_href: fn(key) {
      case key {
        "settings" -> Ok("/plugins/example/settings")
        _ -> Error(Nil)
      }
    },
    form_action: "/plugins/example/settings",
    now: 0,
  )
}

/// `now` を固定し、表示の言語を選べる文脈。
fn at_context(language: i18n.Language) -> plugin_view.Context {
  Context(..context(), language:, now: 1_789_276_354 + 180)
}

/// 対応する種別ごとの部品で、対応する文字列とクラスで描かれる。
pub fn section_renders_every_block_type_test() {
  let raw =
    section("Settings", [], [
      typed_text("text", "A plain paragraph."),
      typed_text("note", "A quieter note."),
      pairs_block([
        #("state", typed_text("text", "running")),
        #("id", typed_text("code", "abc123")),
      ]),
      table_block(["Name", "Status"], [
        [typed_text("text", "worker"), badge_inline("ok", "success")],
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
    element.to_string(view.status_chip(view.ToneChip(view.Success), "ok")),
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
      view.GhostButton,
    )),
  )
}

/// `text` ブロックは、空白の無い長い語を枠の幅で折り返す段落になる。
pub fn text_block_breaks_long_words_test() {
  let raw =
    section("Timeline", [], [typed_text("text", "https://example.com/aaaa")])
  let assert Ok(el) = plugin_view.section(raw, context())
  assert string.contains(
    element.to_string(el),
    "<p class=\"text-sm break-words\">https://example.com/aaaa</p>",
  )
}

/// 未知の種別は、節の見出しとブロックの位置を添えた 1 行の `Error` になる。
pub fn unknown_type_is_an_error_test() {
  let raw = section("設定", [], [map_([#("type", dynamic.string("chart"))])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason == "section \"設定\": block #0: unknown type \"chart\""
}

/// 節の `type` が `"section"` でなければ `Error` になる。
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
  let raw = section("Values", [], [pairs_block([#("state", bad_value)])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "text must be a String, got Int")
}

/// `pairs` の `items` の 2 件目に型の合わない値があると、理由に何件目かが
/// 付く。
pub fn wrong_value_type_reports_item_index_test() {
  let good = typed_text("text", "ok")
  let bad = map_([#("type", dynamic.string("text")), #("text", dynamic.int(1))])
  let raw = section("Values", [], [pairs_block([#("a", good), #("b", bad)])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "item #1: text must be a String, got Int")
}

/// `table` の `rows` の 2 件目がリストでないと、理由に何件目かが付く。
pub fn row_not_a_list_reports_row_index_test() {
  let raw =
    section("Cells", [], [
      map_([
        #("type", dynamic.string("table")),
        #("headers", dynamic.list([dynamic.string("A")])),
        #(
          "rows",
          dynamic.list([
            dynamic.list([typed_text("text", "ok")]),
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
  let raw = section("Outer", [], [nested])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "unknown type \"section\"")
}

/// `table` のセルにブロックを置くと、インラインの段に合わないので `Error` に
/// なる。
pub fn block_in_a_cell_is_an_error_test() {
  let raw =
    section("Cells", [], [table_block(["A"], [[table_block(["B"], [])]])])
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
          section("Broken", [], [map_([#("type", dynamic.string("mystery"))])]),
          section("Fine", [], [typed_text("text", "ok")]),
        ]),
      ),
    ])
  let assert Ok(raw_sections) = plugin_view.sections(description)
  let assert [Error(_), Ok(_)] =
    list.map(raw_sections, plugin_view.section(_, context()))
}

/// 節のカードの中身（見出しとブロック）は `lang="en"` の 1 つの祖先の中にある。
pub fn plugin_text_is_marked_english_test() {
  let raw =
    section("English Only", [], [typed_text("text", "Some plugin text.")])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  let assert [_, after] = string.split(body, "<div lang=\"en\">")
  assert string.contains(after, "English Only")
  assert string.contains(after, "Some plugin text.")
}

/// `blocks` が空の節には翻訳した空の状態の文が出て、それは `lang="en"` の外に
/// 置かれる。
pub fn empty_section_shows_the_translated_line_test() {
  let raw = section("Empty", [], [])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  let translated = i18n.text(i18n.English, i18n.PluginSectionEmpty)
  let assert [before_close, ..] = string.split(body, "</div>")
  assert !string.contains(before_close, translated)
  assert string.contains(body, translated)
}

/// `pairs` の `items` が 0 件のときの訳した文は、プラグイン由来の文字列を包む
/// `lang="en"` の中ではなく、表示の言語を持つ `div` に包まれる。
pub fn empty_pairs_translated_line_has_display_language_test() {
  let raw = section("Has Pairs", [], [pairs_block([])])
  let japanese_context =
    Context(
      language: i18n.Japanese,
      plugin_language: "en",
      page_href: fn(_) { Error(Nil) },
      form_action: "/plugins/example/settings",
      now: 0,
    )
  let assert Ok(el) = plugin_view.section(raw, japanese_context)
  let body = element.to_string(el)
  let translated = i18n.text(i18n.Japanese, i18n.PluginSectionEmpty)
  let assert [_, after_ja] = string.split(body, "<div lang=\"ja\">")
  assert string.contains(after_ja, translated)
}

/// `page_href` が `Error(Nil)` を返すキーの `link` は節の `Error` になる。
pub fn unknown_page_key_is_an_error_test() {
  let raw = section("Links", [], [link_block("missing", "Go")])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "unknown page \"missing\"")
}

/// `form` は宛先・チェック・ラベル・説明・送信のボタンを描く。宛先は
/// `context.form_action`（今開いているページ自身）に固定される。
pub fn form_block_renders_checkboxes_test() {
  let raw =
    section("Settings", [], [
      form_block(
        [
          checkbox_field(
            name: "main",
            label: "Main account",
            hint: Some("f9308a…"),
            checked: True,
          ),
          checkbox_field(
            name: "bot",
            label: "Bot account",
            hint: None,
            checked: False,
          ),
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
      view.PrimaryButton,
      view.InForm,
    )),
  )
}

/// `text` と `textarea` の欄が、それぞれの部品の描画と一致する（`hint` あり・なしの
/// 両方を並べる）。
pub fn form_block_renders_text_fields_test() {
  let raw =
    section("Settings", [], [
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
      view.PrimaryButton,
      view.InForm,
    )),
  )
}

/// `value` を省いた `text` の欄は、初期値 `""` の `view.plugin_text_field` と一致する。
pub fn form_block_text_field_defaults_to_an_empty_value_test() {
  let raw =
    section("Settings", [], [
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
    section("Settings", [], [
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
    section("Settings", [], [
      form_block([text_field("bad name", "Label", None, None)], "Save"),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "name \"bad name\" must match [A-Za-z0-9_-]+")
}

/// `checkbox` / `text` / `textarea` 以外の欄は節ひとつぶんの `Error` になる。
pub fn form_block_rejects_an_unknown_field_type_test() {
  let raw =
    section("Settings", [], [
      form_block([map_([#("type", dynamic.string("select"))])], "Save"),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason
    == "section \"Settings\": block #0: field #0: unknown type \"select\""
}

/// `name` が `[A-Za-z0-9_-]+` の外なら `Error`。
pub fn form_block_rejects_a_bad_field_name_test() {
  let raw =
    section("Settings", [], [
      form_block(
        [
          checkbox_field(
            name: "bad name",
            label: "Label",
            hint: None,
            checked: False,
          ),
        ],
        "Save",
      ),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "name \"bad name\" must match [A-Za-z0-9_-]+")
}

/// `fields` が 0 件なら `Error`。
pub fn form_block_rejects_empty_fields_test() {
  let raw = section("Settings", [], [form_block([], "Save")])
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
  let raw = section("Settings", [], [form_block([no_checked], "Save")])
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
  let raw2 = section("Settings", [], [form_block([bad_checked], "Save")])
  let assert Error(reason) = plugin_view.section(raw2, context())
  assert string.contains(reason, "checked must be a Bool, got String")
}

/// `details` ブロックは `view.details_panel` に `view.preformatted` した本文を
/// 渡した出力を含む。
pub fn details_blocks_are_rendered_test() {
  let raw =
    section("Settings", [], [details_block("tags (1)", "[[\"p\",\"abc\"]]")])
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
  let raw_missing_summary = section("Settings", [], [missing_summary])
  let assert Error(reason_summary) =
    plugin_view.section(raw_missing_summary, context())
  assert string.contains(reason_summary, "missing summary")

  let missing_text =
    map_([
      #("type", dynamic.string("details")),
      #("summary", dynamic.string("s")),
    ])
  let raw_missing_text = section("Settings", [], [missing_text])
  let assert Error(reason_text) =
    plugin_view.section(raw_missing_text, context())
  assert string.contains(reason_text, "missing text")
}

/// `pairs` の `id` の値は `view.identifier_cell` の出力になり、コピーボタンの
/// ラベル（`i18n.Copy` の訳語）を含む。
pub fn id_values_are_truncated_test() {
  let value = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd"
  let raw =
    section("Settings", [], [pairs_block([#("id", typed_text("id", value))])])
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
  let raw =
    section("Cells", [], [table_block(["A"], [[typed_text("id", "abc")]])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, "type \"id\" is only allowed in pairs values")
}

/// `pairs` の値に `badge` を置くと `Error`。`badge` は `table` のセルと節の `meta` だけに置ける。
pub fn badge_is_rejected_in_pairs_values_test() {
  let raw =
    section("Values", [], [
      pairs_block([#("state", badge_inline("ok", "success"))]),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason
    == "section \"Values\": block #0: item #0: value: type \"badge\" is only allowed in table cells and section meta"
}

/// `table` のセルの `code` は、等幅で長い語を折り返す `span` になる。
pub fn code_cells_are_monospace_test() {
  let raw =
    section("Cells", [], [table_block(["A"], [[typed_text("code", "abc123")]])])
  let assert Ok(el) = plugin_view.section(raw, context())
  assert string.contains(
    element.to_string(el),
    "<td><span class=\"font-mono text-xs break-all\">abc123</span></td>",
  )
}

/// `tone` は `view.Tone` の 5 値を名前で選び、文字列でない値と未知の値は `Error` になる。
pub fn tone_selects_one_of_five_values_test() {
  let cases = [
    #("neutral", dynamic.string("neutral"), Ok(view.Neutral)),
    #("success", dynamic.string("success"), Ok(view.Success)),
    #("warning", dynamic.string("warning"), Ok(view.Warning)),
    #("failure", dynamic.string("failure"), Ok(view.Failure)),
    #("info", dynamic.string("info"), Ok(view.Info)),
    #(
      "not a string",
      dynamic.int(1),
      Error("section \"Tones\": block #0: tone must be a String, got Int"),
    ),
    #(
      "unknown",
      dynamic.string("loud"),
      Error("section \"Tones\": block #0: unknown tone \"loud\""),
    ),
  ]
  list.each(cases, fn(row) {
    let #(name, tone, expected) = row
    let raw = section("Tones", [], [alert_block_with_tone("Heads up.", tone)])
    let actual =
      plugin_view.section(raw, context()) |> result.map(element.to_string)
    let wanted =
      result.map(expected, fn(tone) {
        element.to_string(
          view.card([
            html.div([attribute.lang("en")], [
              view.heading("Tones"),
              view.alert(tone, [html.text("Heads up.")]),
            ]),
          ]),
        )
      })
    assert #(name, actual) == #(name, wanted)
  })
}

/// `variant` の無い `image` ブロックは、`url` の scheme が `http` / `https` なら
/// `view.ContainedImage` の `view.plugin_image` の出力（今までの見た目）を含む。
pub fn image_block_renders_image_test() {
  let cases = [
    #("https://example.com/a.png", "A picture"),
    #("http://example.com/a.png", "A picture"),
  ]
  use #(url, alt) <- list.each(cases)
  let raw = section("Media", [], [image_block(url, alt, None)])
  let assert Ok(el) = plugin_view.section(raw, context())
  let body = element.to_string(el)
  assert string.contains(
    body,
    element.to_string(view.plugin_image(url, alt, view.ContainedImage)),
  )
}

/// `variant` が `icon` なら `view.IconImage`、`banner` なら `view.BannerImage` の
/// `view.plugin_image` の出力を含む。
pub fn image_block_variants_select_the_shape_test() {
  let url = "https://example.com/a.png"
  let cases = [#("icon", view.IconImage), #("banner", view.BannerImage)]
  use #(variant, shape) <- list.each(cases)
  let raw =
    section("Media", [], [
      image_block(url, "A picture", Some(variant)),
    ])
  let assert Ok(el) = plugin_view.section(raw, context())
  assert string.contains(
    element.to_string(el),
    element.to_string(view.plugin_image(url, "A picture", shape)),
  )
}

/// `variant` が `icon` / `banner` 以外の文字列なら `unknown variant "<値>"`、文字列で
/// なければ `variant must be a String, got <型>` の `Error` になる。
pub fn image_block_rejects_an_unknown_variant_test() {
  let cases = [
    #(dynamic.string("round"), "unknown variant \"round\""),
    #(dynamic.int(1), "variant must be a String, got Int"),
  ]
  use #(variant, expected) <- list.each(cases)
  let raw =
    section("Media", [], [
      image_block_with_variant(
        "https://example.com/a.png",
        "A picture",
        variant,
      ),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert string.contains(reason, expected)
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
  let raw = section("Media", [], [image_block(url, "A picture", None)])
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

/// 表示の言語を受け取るプラグインの `image` ブロックの代替文は、`url` を描かないとき、
/// `en` で上書きせず、節の包みの表示の言語の `lang` を引き継ぐ。
pub fn image_placeholder_alt_inherits_the_plugin_language_test() {
  let japanese_context =
    Context(
      language: i18n.Japanese,
      plugin_language: "ja",
      page_href: fn(_) { Error(Nil) },
      form_action: "/plugins/example/status",
      now: 0,
    )
  let raw =
    section("キュー", [], [image_block("data:image/png;base64,AAA", "猫の写真", None)])
  let assert Ok(el) = plugin_view.section(raw, japanese_context)
  let body = element.to_string(el)
  let assert [_, inside] = string.split(body, "<div lang=\"ja\">")
  assert string.contains(inside, "<span>猫の写真</span>")
  assert !string.contains(body, "lang=\"en\"")
}

/// `image` ブロックは `url` と `alt` の両方が要り、`url` は String でなければ
/// ならない。
pub fn image_block_requires_url_and_alt_test() {
  let missing_url =
    map_([#("type", dynamic.string("image")), #("alt", dynamic.string("x"))])
  let raw_missing_url = section("Media", [], [missing_url])
  let assert Error(reason_url) = plugin_view.section(raw_missing_url, context())
  assert string.contains(reason_url, "missing url")

  let missing_alt =
    map_([
      #("type", dynamic.string("image")),
      #("url", dynamic.string("https://example.com/a.png")),
    ])
  let raw_missing_alt = section("Media", [], [missing_alt])
  let assert Error(reason_alt) = plugin_view.section(raw_missing_alt, context())
  assert string.contains(reason_alt, "missing alt")

  let bad_url =
    map_([
      #("type", dynamic.string("image")),
      #("url", dynamic.int(1)),
      #("alt", dynamic.string("x")),
    ])
  let raw_bad_url = section("Media", [], [bad_url])
  let assert Error(reason_bad_url) = plugin_view.section(raw_bad_url, context())
  assert string.contains(reason_bad_url, "url must be a String, got Int")
}

/// `image` は `table` のセルにも `pairs` の値にも置けない。段が違うので、それぞれ
/// のインラインの decoder が読む種別の一覧に無い `unknown type "image"` になる。
pub fn image_is_not_an_inline_test() {
  let table_raw =
    section("Cells", [], [
      table_block(["A"], [
        [image_block("https://example.com/a.png", "x", None)],
      ]),
    ])
  let assert Error(table_reason) = plugin_view.section(table_raw, context())
  assert string.contains(table_reason, "unknown type \"image\"")

  let pairs_raw =
    section("Values", [], [
      pairs_block([#("a", image_block("https://example.com/a.png", "x", None))]),
    ])
  let assert Error(pairs_reason) = plugin_view.section(pairs_raw, context())
  assert string.contains(pairs_reason, "value: unknown type \"image\"")
}

/// `table` のセルの `kind` は、表にある kind を表示の言語の名前にし、その言語の `lang` を持つ
/// `span` で出す。
pub fn kind_inline_shows_the_kind_name_in_the_display_language_test() {
  let raw = section("a", [], [table_block(["Kind"], [[kind_inline(1)]])])
  let assert Ok(japanese) = plugin_view.section(raw, at_context(i18n.Japanese))
  assert string.contains(
    element.to_string(japanese),
    "<span lang=\"ja\">投稿</span>",
  )
  let assert Ok(english) = plugin_view.section(raw, at_context(i18n.English))
  assert string.contains(
    element.to_string(english),
    "<span lang=\"en\">post</span>",
  )
}

/// 表に無い kind は番号（`kind 30023`）で出す。
pub fn kind_inline_without_a_name_shows_the_number_test() {
  let raw =
    section("a", [], [
      table_block(["Kind"], [[kind_inline(30_023)]]),
    ])
  let assert Ok(el) = plugin_view.section(raw, at_context(i18n.Japanese))
  assert string.contains(
    element.to_string(el),
    "<span lang=\"ja\">kind 30023</span>",
  )
}

/// `time` は文脈の `now` からの相対時刻を出し、`title` に UTC の時刻を持たせる。
pub fn time_inline_is_relative_with_a_utc_title_test() {
  let raw =
    section("a", [], [
      table_block(["At"], [[time_inline(1_789_276_354)]]),
    ])
  let assert Ok(el) = plugin_view.section(raw, at_context(i18n.English))
  assert string.contains(
    element.to_string(el),
    "<span lang=\"en\" title=\"2026-09-13T05:12:34Z\">3 min ago</span>",
  )
}

/// `kind` と `time` の `value` が整数でなければ、その節の `Error` になる。
pub fn inline_value_must_be_an_int_test() {
  let raw =
    section("a", [], [
      table_block(["Kind"], [
        [
          map_([
            #("type", dynamic.string("kind")),
            #("value", dynamic.string("1")),
          ]),
        ],
      ]),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason
    == "section \"a\": block #0: row #0: value must be an Int, got String"
}

/// `kind` と `time` の `value` が負なら、その節の `Error` になる。
pub fn inline_value_must_not_be_negative_test() {
  let raw = section("a", [], [table_block(["At"], [[time_inline(-1)]])])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason
    == "section \"a\": block #0: row #0: value must not be negative, got -1"
}

/// 節の `meta` は、`blocks` が 1 件でも 0 件でも、見出しの題の後ろに ` · ` で区切って並ぶ。
pub fn section_meta_is_placed_in_the_heading_test() {
  let meta = [kind_inline(1), time_inline(1_789_276_354)]
  let heading =
    "<h2 class=\"card-title flex-wrap\">Timeline<span class=\"text-sm font-normal text-muted\"><span lang=\"en\">post</span> · <span lang=\"en\" title=\"2026-09-13T05:12:34Z\">3 min ago</span></span></h2>"
  let with_block = section("Timeline", meta, [typed_text("text", "body")])
  let assert Ok(el) = plugin_view.section(with_block, at_context(i18n.English))
  assert string.contains(element.to_string(el), heading)
  let empty = section("Timeline", meta, [])
  let assert Ok(el) = plugin_view.section(empty, at_context(i18n.English))
  assert string.contains(element.to_string(el), heading)
}

/// `meta` の項目の誤りは何件目かを付け、`meta` がリストでなければその旨の `Error` になる。
pub fn section_meta_errors_name_the_item_test() {
  let bad_item = section("a", [kind_inline(1), typed_text("id", "abc")], [])
  let assert Error(item_reason) = plugin_view.section(bad_item, context())
  assert item_reason
    == "section \"a\": meta #1: type \"id\" is only allowed in pairs values"
  let not_a_list =
    map_([
      #("type", dynamic.string("section")),
      #("title", dynamic.string("a")),
      #("meta", dynamic.string("x")),
      #("blocks", dynamic.list([])),
    ])
  let assert Error(list_reason) = plugin_view.section(not_a_list, context())
  assert list_reason == "section \"a\": meta must be a List, got String"
}

/// `pairs` の値の `kind` と `time` は `inline` で描いて `dd` で包む。
pub fn pairs_value_accepts_kind_and_time_test() {
  let raw =
    section("a", [], [
      pairs_block([
        #("kind", kind_inline(1)),
        #("at", time_inline(1_789_276_354)),
      ]),
    ])
  let assert Ok(el) = plugin_view.section(raw, at_context(i18n.English))
  let body = element.to_string(el)
  assert string.contains(body, "<dd><span lang=\"en\">post</span></dd>")
  assert string.contains(
    body,
    "<dd><span lang=\"en\" title=\"2026-09-13T05:12:34Z\">3 min ago</span></dd>",
  )
}

/// 欄の任意の `hint` と `value` が文字列でなければ、その欄の
/// `<key> must be a String, got <型>` の `Error` になる。
pub fn form_field_optional_values_must_be_strings_test() {
  let cases = [
    #("checkbox", "hint"),
    #("text", "hint"),
    #("text", "value"),
    #("textarea", "hint"),
    #("textarea", "value"),
  ]
  use #(kind, key) <- list.each(cases)
  let field =
    map_([
      #("type", dynamic.string(kind)),
      #("name", dynamic.string("main")),
      #("label", dynamic.string("Main")),
      #(key, dynamic.int(1)),
    ])
  let raw = section("Settings", [], [form_block([field], "Save")])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason
    == "section \"Settings\": block #0: field #0: "
    <> key
    <> " must be a String, got Int"
}

/// `blocks`・`items`・`rows`・`fields` がリストでなければ `<key> must be a List, got <型>` の
/// `Error` になる。
pub fn list_fields_must_be_lists_test() {
  let cases = [
    #(
      map_([
        #("type", dynamic.string("section")),
        #("title", dynamic.string("a")),
        #("blocks", dynamic.string("x")),
      ]),
      "blocks must be a List, got String",
    ),
    #(
      section("a", [], [
        map_([
          #("type", dynamic.string("pairs")),
          #("items", dynamic.string("x")),
        ]),
      ]),
      "section \"a\": block #0: items must be a List, got String",
    ),
    #(
      section("a", [], [
        map_([
          #("type", dynamic.string("table")),
          #("headers", dynamic.list([dynamic.string("A")])),
          #("rows", dynamic.string("x")),
        ]),
      ]),
      "section \"a\": block #0: rows must be a List, got String",
    ),
    #(
      section("a", [], [
        map_([
          #("type", dynamic.string("form")),
          #("fields", dynamic.string("x")),
          #("submit", dynamic.string("Save")),
        ]),
      ]),
      "section \"a\": block #0: fields must be a List, got String",
    ),
  ]
  use #(raw, expected) <- list.each(cases)
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason == expected
}

/// `pairs` の項目に `value` が無ければ `item #<添字>: missing value` の `Error` になる。
pub fn pairs_item_requires_a_value_test() {
  let raw =
    section("a", [], [
      map_([
        #("type", dynamic.string("pairs")),
        #("items", dynamic.list([map_([#("term", dynamic.string("state"))])])),
      ]),
    ])
  let assert Error(reason) = plugin_view.section(raw, context())
  assert reason == "section \"a\": block #0: item #0: missing value"
}

/// `tone` の無い `badge` は `view.Neutral` の色で出る。
pub fn badge_without_tone_is_neutral_test() {
  let meta = [
    map_([#("type", dynamic.string("badge")), #("text", dynamic.string("on"))]),
  ]
  let raw = section("a", meta, [])
  let assert Ok(el) = plugin_view.section(raw, context())
  assert string.contains(
    element.to_string(el),
    element.to_string(view.status_chip(view.ToneChip(view.Neutral), "on")),
  )
}
