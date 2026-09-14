//// 管理 UI のページ枠と、`admin/i18n` 以外の本体のモジュールに依存しない HTML の部品。lustre の
//// 要素ツリーで組み立てるが、lustre の component（`lustre/component`）や server
//// components は使わない。部品は `Element` を返し、HTML 文書の文字列にするのは
//// `page` だけである。
////
//// 値はテキストか属性値として lustre に渡し、HTML のエスケープは lustre の文字列化に
//// 任せる。エスケープでは防げない経路には決まった値だけを渡す。`html.style`、
//// `html.script`、`element.unsafe_raw_html`、イベント属性（`on*`）は使わない。JS の処理は
//// `priv/static/admin.js` に置き、要素には `data-action` で処理の名前を付ける（CSP の
//// `script-src 'self'` がインラインのスクリプトを実行させない。`script_test` が検査する）。
//// `href`、`action`、`src` には、`admin/dashboard` のパスの関数が `/` から組み立てた値か、
//// `"/"` か、`stylesheet_segments`、`script_segments`、`language_segments`、
//// `theme_segments` から組み立てた値だけを渡す（lustre は URL を検査しない）。
////
//// 入力欄の値は `attribute.default_value` で出す。サーバー側で初期値を出すだけで、
//// `attribute.value("")` は値の無い `value` 属性になるためである。
////
//// 文言は `admin/i18n` から表示の言語で引く。見出しや説明のように文字列を受け取る部品には、
//// 呼び出し側が表示の言語で引いた文字列を渡す。描画のモジュール（ここと `admin/dashboard`、
//// `admin/account_pages`、`admin/relay_pages`）には文言を文字列リテラルで書かない。型もテストも、
//// 書き足した英語の文言が日本語のページに出ることを検出しないためである。文字列リテラルの
//// まま出すのは製品名（`nostr-no-su`）だけである。
////
//// 見た目は Tailwind CSS と daisyUI のクラスで付け、ビルドした `priv/static/admin.css`
//// を読ませる。Tailwind は `admin/` の `.gleam`（文言だけを持つ `admin/i18n` を除く）の語
//// （文字列、識別子、コメント）からクラス名の候補を拾う。クラスを変えなくても、語を変えると
//// CSS が変わることがあるので、これらのファイルを変えたらビルドし直す。クラス名は文字列の
//// 連結で組み立てず、状態ごとに違うものは `case` で完全な文字列を列挙する。80 桁を超えても、
//// クラス名の文字列は分けない。フォーカスできる `btn` の文字列には
//// `focus-visible:outline-base-content`、`input` と `checkbox` の文字列には
//// `border-base-content/60` を付ける（デザイン方針 6 節。`stylesheet_test` が検査する）。

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import nostr_no_su/admin/i18n.{type Language}

/// ビルドした管理 UI のスタイルシートの URL のパスセグメント。ルーティング（`admin`）と
/// ページ枠の `link` が同じ定義を見る。配信する `wisp.serve_static` はこの定数ではなく要求の
/// パスから `priv` の下のファイルを引くので、このセグメントは `priv` の中の配置
/// （`priv/static/admin.css`）、`package.json` の `build:css` の出力先、`stylesheet_test` が
/// 読むパスと一致させる。
pub const stylesheet_segments = ["static", "admin.css"]

/// 管理 UI のスクリプトの URL のパスセグメント。ルーティング（`admin`）とページ枠の `script` が
/// 同じ定義を見る。`stylesheet_segments` と同じく要求のパスから `priv` の下のファイルを引くので、
/// `priv` の中の配置（`priv/static/admin.js`）と一致させる。
pub const script_segments = ["static", "admin.js"]

/// 言語の切り替えの POST 先のパスセグメント。ルーティング（`admin`）とナビゲーション
/// バーのフォームが同じ定義を見る。
pub const language_segments = ["language"]

/// 言語の切り替えで、選んだ言語のコードを送る欄の名前。
pub const language_field = "language"

/// テーマの切り替えの POST 先のパスセグメント。ルーティング（`admin`）とナビゲーション
/// バーのフォームが同じ定義を見る。
pub const theme_segments = ["theme"]

/// テーマの切り替えで、選んだテーマのコードを送る欄の名前。
pub const theme_field = "theme"

/// テーマと言語の切り替えで、切り替えた後に開くパスを送る欄の名前。
pub const return_field = "return"

/// ナビゲーションバーの 2 つのドロップダウン（`details`）に付ける名前。同じ名前の
/// `details` は Chromium で 1 つだけ開くので、片方を開くともう片方が閉じる。
pub const navbar_menu_name = "navbar-menu"

/// ページの本文の幅。
pub type Layout {
  /// 節を 2 列に並べるダッシュボード。
  Wide
  /// フォームと説明を 1 列で読む、ダッシュボード以外のページ。
  Narrow
}

/// 表示のテーマ。`System` はブラウザーの設定（`prefers-color-scheme`）に従い、
/// `data-theme` も cookie も出さない。
pub type Theme {
  System
  Light
  Dark
}

/// 対応するテーマ。ナビゲーションバーのドロップダウンはこの順に並べる。
pub const themes = [System, Light, Dark]

/// テーマと言語の切り替えで、ブラウザーの設定を表すフォームの値。
const follow_browser_code = "system"

/// テーマのコード。`data-theme`、切り替えで送る値、cookie の値に使う。`System` は
/// `data-theme` も cookie も持たないコードなので、フォームの値としてだけ使う。
pub fn theme_code(theme: Theme) -> String {
  case theme {
    System -> follow_browser_code
    Light -> "light"
    Dark -> "dark"
  }
}

/// テーマのコードのテーマ。対応していない値なら Error。
pub fn theme_from_code(value: String) -> Result(Theme, Nil) {
  list.find(themes, fn(theme) { theme_code(theme) == value })
}

/// 言語の切り替えで選ぶ値。`BrowserLanguage` は cookie を消して `Accept-Language` に従う。
pub type LanguageChoice {
  BrowserLanguage
  ChosenLanguage(language: Language)
}

/// 言語の一覧に並べる順。ブラウザーの設定を先頭に置き、続けて `i18n.languages` の順。
pub fn language_choices() -> List(LanguageChoice) {
  [BrowserLanguage, ..list.map(i18n.languages, ChosenLanguage)]
}

/// 言語の選択のコード。`BrowserLanguage` はテーマと同じ `follow_browser_code`、
/// `ChosenLanguage` は言語のコードである。
pub fn language_choice_code(choice: LanguageChoice) -> String {
  case choice {
    BrowserLanguage -> follow_browser_code
    ChosenLanguage(language) -> i18n.code(language)
  }
}

/// 言語の選択のコードの選択。対応していない値なら Error。
pub fn language_choice_from_code(value: String) -> Result(LanguageChoice, Nil) {
  list.find(language_choices(), fn(choice) {
    language_choice_code(choice) == value
  })
}

/// ナビゲーションバーにテーマと言語の切り替えを出すかどうか。
pub type NavbarSwitch {
  /// 切り替えを出す。切り替えた後は `return_to`（GET で開けるページのパス）を開く。
  SwitchReturningTo(return_to: String)
  /// 切り替えを出さない。秘密鍵を出すページは同じ内容を GET で開き直せず、切り替えで
  /// ページを離れると表示が失われるため。Origin と Host が一致しない要求への 400 の
  /// ページも、切り替えの POST が同じ不一致で同じ 400 になり、押しても何も変わらない
  /// ためこれを使う。
  NoSwitch
}

/// 操作の重さ。ボタンの色を決める。
pub type Weight {
  /// 状態を変えない、または取り消しても害が無い操作。
  Normal
  /// 登録、保存、承認。
  Primary
  /// 接続中のクライアントに影響する、または秘密を画面に出す操作。やり直しは効く。
  Caution
  /// 取り返しがつかない操作。
  Destructive
}

/// ボタンを置く場所。
pub type Placement {
  /// ダッシュボードの行や承認ページのように、小さいボタンを横に並べる。
  InRow
  /// 確認のページのように、欄を縦に並べたフォームの末尾に置く。
  InForm
}

/// 通知や理由の囲みの色。
pub type Tone {
  /// 良し悪しを伝えない結果（接続の拒否）と、正常な構成でもありうる理由（アカウント、
  /// 承認待ち、セッションの一覧を得られない）。
  Neutral
  /// 求めた操作が反映された結果（接続の承認）。
  Success
  /// 反映されたか分からない変更、今は受け付けられない変更、秘密鍵のバックアップの注意。
  Warning
  /// 処理できなかった操作と、フォームの上の失敗の理由。
  Failure
}

/// 見出しと値の組（`dl`）の値の見せ方。
pub type Value {
  /// 16 進の公開鍵のように、等幅で任意の位置で折り返す値。
  Code(String)
  /// ラベルや経過秒のように、単語の区切りで折り返す値。
  Plain(String)
  /// npub と、あれば 16 進の公開鍵を縦に並べたアカウント。
  Account(npub: String, hex: Option(String))
  /// RFC 3339 の UTC の時刻。折り返さず、数字の幅を揃える。
  Timestamp(String)
}

/// 管理 UI 共通のページ枠を HTML 文書の文字列にする。表示の言語を `<html lang>` にし、
/// `theme` が `Light` か `Dark` なら `data-theme` を出す。ナビゲーションバーと、`title` を
/// 見出し（h1）にした本文を出す。
pub fn page(
  language: Language,
  theme: Theme,
  title: i18n.Message,
  layout: Layout,
  switch: NavbarSwitch,
  body: List(Element(msg)),
) -> String {
  let title = i18n.text(language, title)
  let attrs = [attribute.lang(i18n.code(language)), ..theme_attributes(theme)]
  html.html(attrs, [
    html.head([], [
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width,initial-scale=1"),
      ]),
      html.title([], "nostr-no-su — " <> title),
      html.link([
        attribute.rel("stylesheet"),
        attribute.href(segments_path(stylesheet_segments)),
      ]),
      element.element(
        "script",
        [
          attribute.type_("module"),
          attribute.src(segments_path(script_segments)),
        ],
        [],
      ),
    ]),
    html.body([attribute.class("min-h-screen bg-base-200 text-base-content")], [
      navbar(language, theme, switch),
      html.main([attribute.class(main_class(layout))], [
        html.h1([attribute.class("text-2xl font-bold")], [html.text(title)]),
        ..body
      ]),
    ]),
  ])
  |> element.to_document_string
}

/// パスセグメントを `/` から連結したパス。ルーティング（`admin`）が照合するのと同じ
/// セグメントの定義から、リンク、フォームの宛先、スタイルシートの `href` のパスを
/// 組み立てる。
pub fn segments_path(segments: List(String)) -> String {
  "/" <> string.join(segments, "/")
}

/// `<html>` に出す属性。`System` はブラウザーの設定に従うので `data-theme` を出さない。
fn theme_attributes(theme: Theme) -> List(Attribute(msg)) {
  case theme {
    System -> []
    Light | Dark -> [attribute.data("theme", theme_code(theme))]
  }
}

/// 全ページ共通のナビゲーションバー。サイト名はダッシュボードへのリンクにし、右端
/// （`navbar-end`）にテーマと言語の切り替えを置く。切り替えを出さないページでも右端の
/// 枠は残す。
fn navbar(
  language: Language,
  theme: Theme,
  switch: NavbarSwitch,
) -> Element(msg) {
  let end = case switch {
    SwitchReturningTo(return_to:) -> [
      theme_switch(language, theme, return_to),
      language_switch(language, return_to),
    ]
    NoSwitch -> []
  }
  html.header(
    [
      attribute.class(
        "navbar gap-2 border-b border-base-300 bg-base-100 px-4 sm:px-6",
      ),
    ],
    [
      html.div([attribute.class("navbar-start flex-1")], [
        html.a(
          [
            attribute.href("/"),
            attribute.class(
              "btn btn-ghost px-2 text-lg font-bold focus-visible:outline-base-content",
            ),
          ],
          [html.text("nostr-no-su")],
        ),
      ]),
      html.div([attribute.class("navbar-end w-auto gap-2")], end),
    ],
  )
}

/// テーマの切り替え。テーマは `themes` の順（ブラウザーの設定、ライト、ダーク）に並べる。
fn theme_switch(
  language: Language,
  current: Theme,
  return_to: String,
) -> Element(msg) {
  dropdown(
    i18n.text(language, i18n.ThemeSwitchLabel),
    theme_segments,
    return_to,
    list.map(themes, fn(theme) {
      dropdown_item(
        theme_field,
        theme_code(theme),
        theme == current,
        None,
        i18n.text(language, theme_label(theme)),
      )
    }),
  )
}

/// テーマの項目の文言。
fn theme_label(theme: Theme) -> i18n.Message {
  case theme {
    System -> i18n.FollowBrowser
    Light -> i18n.ThemeLight
    Dark -> i18n.ThemeDark
  }
}

/// 言語の切り替え。先頭にブラウザーの設定を置き、続けて `i18n.languages` の順に並べ、
/// 言語名はその言語自身で書き `lang` を付ける。ブラウザーの設定は選択の印を付けない
/// （描画は cookie の有無を知らないため、表示中の判定は常に表示している言語につく）。
fn language_switch(current: Language, return_to: String) -> Element(msg) {
  dropdown(
    i18n.text(current, i18n.LanguageSwitchLabel),
    language_segments,
    return_to,
    list.map(language_choices(), fn(choice) {
      let #(selected, lang, label) = case choice {
        BrowserLanguage -> #(
          False,
          None,
          i18n.text(current, i18n.FollowBrowser),
        )
        ChosenLanguage(language) -> #(
          language == current,
          Some(i18n.code(language)),
          i18n.native_name(language),
        )
      }
      dropdown_item(
        language_field,
        language_choice_code(choice),
        selected,
        lang,
        label,
      )
    }),
  )
}

/// ナビゲーションバーの切り替えのドロップダウン。`details` で開閉し、一覧の各項目を
/// `action` へ POST する送信ボタンにする。JS なしで動き、外側のクリックと Esc では閉じない
/// （`details` の仕様）。ARIA のメニューにしない（矢印キーの移動を実装しないため）。
fn dropdown(
  label: String,
  action: List(String),
  return_to: String,
  items: List(Element(msg)),
) -> Element(msg) {
  html.details(
    [attribute.name(navbar_menu_name), attribute.class("dropdown dropdown-end")],
    [
      html.summary(
        [attribute.class("btn btn-sm focus-visible:outline-base-content")],
        [html.text(label), chevron_icon()],
      ),
      html.form(
        [
          attribute.method("post"),
          attribute.action(segments_path(action)),
          attribute.class("dropdown-content z-10 mt-1"),
        ],
        [
          hidden_input(return_field, return_to),
          html.ul(
            [
              attribute.class(
                "menu w-48 rounded-box border border-base-300 bg-base-100 shadow-sm",
              ),
            ],
            list.map(items, fn(item) { html.li([], [item]) }),
          ),
        ],
      ),
    ],
  )
}

/// ドロップダウンの一覧の項目 1 つ。表示中の項目は `aria-current` と `menu-active` と
/// チェックで示し、押すと同じ値を送り直す。
fn dropdown_item(
  field: String,
  value: String,
  selected: Bool,
  lang: Option(String),
  text: String,
) -> Element(msg) {
  let lang_attribute = case lang {
    Some(code) -> [attribute.lang(code)]
    None -> []
  }
  let class = case selected {
    True ->
      "menu-active focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-neutral-content"
    False ->
      "focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content"
  }
  let current = case selected {
    True -> [attribute.aria_current("true")]
    False -> []
  }
  html.button(
    [
      attribute.type_("submit"),
      attribute.name(field),
      attribute.value(value),
      attribute.class(class),
      ..list.append(lang_attribute, current)
    ],
    [check_icon(selected), html.span([], [html.text(text)])],
  )
}

/// 線で描く 16 × 16 の飾りのアイコン。読み上げない。
fn icon(class: String, path: String) -> Element(msg) {
  svg.svg(
    [
      attribute.aria_hidden(True),
      attribute.attribute("viewBox", "0 0 16 16"),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "2"),
      attribute.class(class),
    ],
    [svg.path([attribute.attribute("d", path)])],
  )
}

/// 表示中の項目のチェック。表示中でない項目にも同じ大きさの見えない枠を置き、文字の
/// 位置を揃える。
fn check_icon(shown: Bool) -> Element(msg) {
  let class = case shown {
    True -> "size-4"
    False -> "invisible size-4"
  }
  icon(class, "M3 8.5l3 3 7-7")
}

/// 開閉のボタンの下向きの矢印。
fn chevron_icon() -> Element(msg) {
  icon("size-3", "M4 6l4 4 4-4")
}

/// ページの本文（`main`）のクラス。
fn main_class(layout: Layout) -> String {
  case layout {
    Wide -> "mx-auto flex w-full max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6"
    Narrow -> "mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-6 sm:px-6"
  }
}

/// 節やページの内容を包むカード。
pub fn card(content: List(Element(msg))) -> Element(msg) {
  html.section(
    [attribute.class("card border border-base-300 bg-base-100 shadow-sm")],
    [html.div([attribute.class("card-body gap-4 p-4 sm:p-6")], content)],
  )
}

/// カードの見出し（h2）。
pub fn heading(title: String) -> Element(msg) {
  html.h2([attribute.class("card-title")], [html.text(title)])
}

/// 本文より控えめな一言。行が無い節の説明や、ページの末尾の案内に使う。
pub fn hint(text: String) -> Element(msg) {
  html.p([attribute.class("text-sm text-base-content/70")], [html.text(text)])
}

/// カードの中でフォームの前に置く、フォームの説明。
pub fn form_description(text: String) -> Element(msg) {
  html.p([attribute.class("text-sm")], [html.text(text)])
}

/// 見出し行付きの表。行は `td` の並びで渡す。枠より広い値は枠の中で横に送る。
pub fn table(
  headers: List(String),
  rows: List(List(Element(msg))),
) -> Element(msg) {
  html.div([attribute.class("overflow-x-auto")], [
    html.table([attribute.class("table table-sm")], [
      html.thead([], [
        html.tr(
          [],
          list.map(headers, fn(header) {
            html.th([attribute.scope("col")], [html.text(header)])
          }),
        ),
      ]),
      html.tbody([], list.map(rows, html.tr([], _))),
    ]),
  ])
}

/// 見出しと値の組の一覧（`dl`）。見出しを値の左に置くので、狭い画面でも横に伸びない。
pub fn summary_list(entries: List(#(String, Value))) -> Element(msg) {
  html.dl(
    [
      attribute.class(
        "grid min-w-0 grid-cols-[auto_minmax(0,1fr)] items-baseline gap-x-4 gap-y-1 text-sm",
      ),
    ],
    list.flat_map(entries, fn(entry) {
      let #(term, value) = entry
      [
        html.dt([attribute.class("text-base-content/70")], [html.text(term)]),
        summary_value(value),
      ]
    }),
  )
}

/// `summary_list` の値（`dd`）。
fn summary_value(value: Value) -> Element(msg) {
  case value {
    Code(text) ->
      html.dd([attribute.class("font-mono text-xs break-all")], [
        html.text(text),
      ])
    Plain(text) -> html.dd([attribute.class("break-words")], [html.text(text)])
    Account(npub:, hex:) -> {
      let hex = case hex {
        Some(hex) -> [
          html.span([attribute.class("text-base-content/70")], [html.text(hex)]),
        ]
        None -> []
      }
      html.dd(
        [
          attribute.class(
            "flex min-w-0 flex-col gap-1 font-mono text-xs break-all",
          ),
        ],
        [html.span([], [html.text(npub)]), ..hex],
      )
    }
    Timestamp(text) ->
      html.dd([], [
        html.time(
          [
            attribute.attribute("datetime", text),
            attribute.class("whitespace-nowrap tabular-nums"),
          ],
          [html.text(text)],
        ),
      ])
  }
}

/// 指定した宛先へ POST で送るフォーム。欄を並べ、最後に送信のボタンを置く。
pub fn post_form(
  action: String,
  fields: List(Element(msg)),
  label: String,
  weight: Weight,
  placement: Placement,
) -> Element(msg) {
  form_with([], action, fields, label, weight, placement)
}

/// 秘密を入力させるフォーム。フォームにも `autocomplete="off"` を付け、ブラウザーが
/// フォーム全体を資格情報として保存の対象にしないようにする。
pub fn secret_post_form(
  action: String,
  fields: List(Element(msg)),
  label: String,
  weight: Weight,
  placement: Placement,
) -> Element(msg) {
  form_with(
    [attribute.autocomplete("off")],
    action,
    fields,
    label,
    weight,
    placement,
  )
}

/// `post_form` と `secret_post_form` が共有するフォームの組み立て。
fn form_with(
  attributes: List(Attribute(msg)),
  action: String,
  fields: List(Element(msg)),
  label: String,
  weight: Weight,
  placement: Placement,
) -> Element(msg) {
  let submit =
    html.button(
      [
        attribute.type_("submit"),
        attribute.class(button_class(weight, placement)),
      ],
      [html.text(label)],
    )
  html.form(
    [
      attribute.method("post"),
      attribute.action(action),
      ..list.append(attributes, form_layout(placement))
    ],
    list.append(fields, [submit]),
  )
}

/// フォームの並べ方。行に置くフォームはボタン 1 つだけなので、クラスを付けない。
fn form_layout(placement: Placement) -> List(Attribute(msg)) {
  case placement {
    InRow -> []
    InForm -> [attribute.class("flex flex-col gap-4")]
  }
}

/// ボタンの見た目のリンク。ダッシュボードの行で、操作のページへの入口に使う。
pub fn button_link(href: String, text: String, weight: Weight) -> Element(msg) {
  html.a([attribute.href(href), attribute.class(button_class(weight, InRow))], [
    html.text(text),
  ])
}

/// 操作の重さと置き場所の組ごとのボタンのクラス。
fn button_class(weight: Weight, placement: Placement) -> String {
  case placement, weight {
    InRow, Normal -> "btn btn-sm focus-visible:outline-base-content"
    InRow, Primary ->
      "btn btn-sm btn-primary focus-visible:outline-base-content"
    InRow, Caution ->
      "btn btn-sm btn-warning focus-visible:outline-base-content"
    InRow, Destructive ->
      "btn btn-sm btn-error focus-visible:outline-base-content"
    InForm, Normal -> "btn self-start focus-visible:outline-base-content"
    InForm, Primary ->
      "btn btn-primary self-start focus-visible:outline-base-content"
    InForm, Caution ->
      "btn btn-warning self-start focus-visible:outline-base-content"
    InForm, Destructive ->
      "btn btn-error self-start focus-visible:outline-base-content"
  }
}

/// 見出しを付けた入力欄。`label` が入力欄 1 つだけを包む。
pub fn labelled(caption: String, input: Element(msg)) -> Element(msg) {
  html.label([attribute.class("fieldset")], [
    html.span([attribute.class("fieldset-legend")], [html.text(caption)]),
    input,
  ])
}

/// 見出し、入力欄、案内をまとめた囲み。入力欄に `aria-label` と、案内の `id` を指す
/// `aria-describedby` を付ける。`attributes` にクラスを含む入力欄の属性を渡す。
pub fn hinted_input(
  caption: String,
  hint_id: String,
  hint: String,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  html.div([attribute.class("fieldset")], [
    html.span([attribute.class("fieldset-legend")], [html.text(caption)]),
    html.input([
      attribute.aria_label(caption),
      attribute.aria_describedby(hint_id),
      ..attributes
    ]),
    html.p([attribute.id(hint_id), attribute.class("text-base-content/70")], [
      html.text(hint),
    ]),
  ])
}

/// nsec や管理パスワードのように伏せて入力させる欄。`autocomplete` は欄の自動入力の種類
/// （nsec は `new-password`、再入力のパスワードは `off`）。
pub fn secret_input(name: String, autocomplete: String) -> Element(msg) {
  html.input([
    attribute.type_("password"),
    attribute.name(name),
    attribute.autocomplete(autocomplete),
    attribute.required(True),
    attribute.class("input w-full font-mono border-base-content/60"),
  ])
}

/// フォームで送る隠しフィールド。
pub fn hidden_input(name: String, value: String) -> Element(msg) {
  html.input([
    attribute.type_("hidden"),
    attribute.name(name),
    attribute.default_value(value),
  ])
}

/// 見出しを付けた読み取り専用の欄と、その値をコピーするボタン。ボタンは `data-action` で
/// `priv/static/admin.js` の `copy` の処理を指し、値は処理が DOM から読む。欄に name を付けない
/// （送信にも入力履歴にも含めないため）。処理が囲みをボタンの親の親として読むので、囲みを
/// 1 つの要素として返す。ボタンの名前は常に「コピー」の文言のままにし、完了は囲みの直下の
/// `role="status"` で伝える。クリップボードに書けないときの案内も同じ要素に見える形で出す。
pub fn copyable_field(
  language: Language,
  caption: String,
  value: String,
) -> Element(msg) {
  let copied = i18n.text(language, i18n.Copied)
  html.div([attribute.class("fieldset group")], [
    html.span([attribute.class("fieldset-legend")], [html.text(caption)]),
    html.div([attribute.class("join w-full")], [
      html.input([
        attribute.type_("text"),
        attribute.readonly(True),
        attribute.default_value(value),
        attribute.aria_label(caption),
        attribute.class(
          "input join-item w-full min-w-0 font-mono text-xs border-base-content/60",
        ),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.data("action", "copy"),
          attribute.class(
            "btn join-item group-data-copied:btn-success focus-visible:outline-base-content",
          ),
        ],
        [
          html.span([attribute.class("grid")], [
            html.span(
              [
                attribute.class(
                  "col-start-1 row-start-1 group-data-copied:opacity-0",
                ),
              ],
              [html.text(i18n.text(language, i18n.Copy))],
            ),
            html.span(
              [
                attribute.aria_hidden(True),
                attribute.class(
                  "invisible col-start-1 row-start-1 group-data-copied:visible",
                ),
              ],
              [html.text(copied)],
            ),
          ]),
        ],
      ),
    ]),
    html.span(
      [
        attribute.role("status"),
        attribute.class("sr-only group-data-selected:not-sr-only"),
      ],
      [
        html.span([attribute.class("hidden group-data-copied:inline")], [
          html.text(copied),
        ]),
        html.span(
          [attribute.class("hidden group-data-selected:inline text-sm")],
          [html.text(i18n.text(language, i18n.SelectedPressCtrlC))],
        ),
      ],
    ),
  ])
}

/// 通知や理由を、トーンの色の囲みで出す。
pub fn alert(tone: Tone, content: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class(alert_class(tone))], [html.span([], content)])
}

/// フォームの上に出す理由の囲み。`role="alert"` で伝え、色を `tone` にする。
pub fn reason_alert(tone: Tone, content: List(Element(msg))) -> Element(msg) {
  html.div([attribute.role("alert"), attribute.class(alert_class(tone))], [
    html.span([], content),
  ])
}

/// フォームの上に出す失敗の理由。無ければ何も出さない。`lead` は、英語のまま届いた理由の
/// 前に置く前置き。
pub fn error_message(
  language: Language,
  lead: Option(i18n.Lead),
  error: Option(i18n.Reason),
) -> Element(msg) {
  case error {
    None -> element.none()
    Some(reason) ->
      reason_alert(Failure, reason_content(language, lead, reason))
  }
}

/// 理由の中身。訳す理由は表示の言語の文字列にする。英語のまま届いた理由は `lang="en"` を
/// 付けて出し、表示の言語に `lead` の前置きがあればその後に続ける。
pub fn reason_content(
  language: Language,
  lead: Option(i18n.Lead),
  reason: i18n.Reason,
) -> List(Element(msg)) {
  case reason {
    i18n.Translated(message) -> [html.text(i18n.text(language, message))]
    i18n.Untranslated(detail) ->
      case option.then(lead, i18n.lead(language, _)) {
        Some(prefix) -> [html.text(prefix), untranslated(detail)]
        None -> [untranslated(detail)]
      }
  }
}

/// 訳さずに英語のまま出す文字列（`i18n.Untranslated` の中身）。どの言語のページでも
/// `lang="en"` の `span` で出す。
pub fn untranslated(text: String) -> Element(msg) {
  html.span([attribute.lang("en")], [html.text(text)])
}

/// 秘密鍵を表示するページの、読み飛ばされては困る注意。
pub fn warning(content: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class(alert_class(Warning))], [html.p([], content)])
}

/// トーンごとの囲みのクラス。
fn alert_class(tone: Tone) -> String {
  case tone {
    Neutral -> "alert"
    Success -> "alert alert-success"
    Warning -> "alert alert-warning"
    Failure -> "alert alert-error"
  }
}

/// ダッシュボードへ戻るリンクの段落。
pub fn back_link(language: Language) -> Element(msg) {
  html.p([], [
    html.a([attribute.href("/"), attribute.class("link")], [
      html.text(i18n.text(language, i18n.BackToDashboard)),
    ]),
  ])
}
