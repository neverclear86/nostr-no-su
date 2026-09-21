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
//// `theme_segments` から組み立てた値か、`admin/dashboard` の節のアンカーの定数の先頭に `#` を
//// 付けた値だけを渡す（lustre は URL を検査しない）。
////
//// 入力欄の値は `attribute.default_value` で出す。サーバー側で初期値を出すだけで、
//// `attribute.value("")` は値の無い `value` 属性になるためである。
////
//// 文言は `admin/i18n` から表示の言語で引く。見出しや説明のように文字列を受け取る部品には、
//// 呼び出し側が表示の言語で引いた文字列を渡す。描画のモジュール（ここと `admin/dashboard`、
//// `admin/account_pages`、`admin/relay_pages`、`admin/connect_pages`、
//// `admin/session_pages`）には文言を文字列リテラルで書かない。型もテストも、書き足した
//// 英語の文言が日本語のページに出ることを検出しないためである。文字列リテラルのまま
//// 出すのは製品名（`Nostr-no-Su`）だけである。
////
//// 見た目は Tailwind CSS と daisyUI のクラスで付け、ビルドした `priv/static/admin.css`
//// を読ませる。Tailwind は `admin/` の `.gleam`（文言だけを持つ `admin/i18n` を除く）の語
//// （文字列、識別子、コメント）からクラス名の候補を拾う。クラスを変えなくても、語を変えると
//// CSS が変わることがあるので、これらのファイルを変えたらビルドし直す。クラス名は文字列の
//// 連結で組み立てず、状態ごとに違うものは `case` で完全な文字列を列挙する。80 桁を超えても、
//// クラス名の文字列は分けない。フォーカスできる `btn` の文字列には
//// `focus-visible:outline-base-content`、`input`、`checkbox`、`textarea`、`select` の
//// 文字列には `border-base-content/60` を付ける（デザイン方針 6 節。`stylesheet_test` が
//// 検査する）。
////
//// アイコンは Lucide（ISC ライセンス）のストロークを写したインライン SVG で、`currentColor`
//// で色を継ぐ飾りである。製品のロゴだけは塗りで描き、上部バーでは単色版を `currentColor`
//// で、`<head>` の favicon ではカラー版を `data:` の URI にして出す。

import gleam/int
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

/// 通知や理由の囲みと、状態のバッジの色。
pub type Tone {
  /// 良し悪しを伝えない結果（接続の拒否）と、正常な構成でもありうる理由（アカウント、
  /// セッションの一覧を得られない）。
  Neutral
  /// 求めた操作が反映された結果（接続の承認）。
  Success
  /// 反映されたか分からない変更、今は受け付けられない変更、秘密鍵のバックアップの注意。
  Warning
  /// 処理できなかった操作、フォームの上の失敗の理由、承認待ちの一覧を得られない理由
  /// （0 件と読み違えさせない）。
  Failure
  /// 承認の意味の説明など、危険を伴わない補足。
  Info
}

/// ページを自動で読み込み直すかどうか。`RefreshEverySeconds` のページだけ
/// `<meta http-equiv="refresh">` を出す。
pub type Refresh {
  NoRefresh
  RefreshEverySeconds(seconds: Int)
}

/// 見出しと値の組（`dl`）の値の見せ方。
pub type Value {
  /// 16 進の公開鍵のように、等幅で任意の位置で折り返す値。
  Code(String)
  /// ラベルや残り秒のように、単語の区切りで折り返す値。
  Plain(String)
}

/// favicon にするカラー版のロゴの SVG。`fill` は属性に書き、暗い配色のときだけ `<style>` が
/// 白版に上書きする（media が効かなければカラー版のまま出る）。
fn favicon_svg() -> String {
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\""
  <> logo_view_box
  <> "\" width=\"900\" height=\"900\"><style>@media (prefers-color-scheme: dark){.ink{fill:#FFFFFF}.face{fill:none}}</style><path fill=\"#FFFFFF\" class=\"face\" d=\""
  <> logo_face_path
  <> "\" /><path fill=\"#183965\" fill-rule=\"evenodd\" class=\"ink\" d=\""
  <> logo_body_path
  <> "\" /><path fill=\"#28B9BE\" class=\"ink\" d=\""
  <> logo_tail_path
  <> "\" /></svg>"
}

/// SVG の markup を `data:` の URI に入れられるよう百分率符号化する。空白と URL で使えない
/// 文字だけを 1 文字ずつ写し、ほかはそのまま通す。
fn percent_encode_svg(markup: String) -> String {
  markup
  |> string.to_graphemes
  |> list.map(fn(grapheme) {
    case grapheme {
      " " -> "%20"
      "\"" -> "%22"
      "#" -> "%23"
      "%" -> "%25"
      "<" -> "%3C"
      ">" -> "%3E"
      "{" -> "%7B"
      "}" -> "%7D"
      "|" -> "%7C"
      "\\" -> "%5C"
      "^" -> "%5E"
      "`" -> "%60"
      other -> other
    }
  })
  |> string.concat
}

/// ページのタブに出すロゴ。`data:` の SVG なので配信するファイルもルートも増えない（CSP の
/// `img-src data:` が読ませる）。
fn favicon_link() -> Element(msg) {
  html.link([
    attribute.rel("icon"),
    attribute.type_("image/svg+xml"),
    attribute.href("data:image/svg+xml," <> percent_encode_svg(favicon_svg())),
  ])
}

/// 管理 UI 共通のページ枠を HTML 文書の文字列にする。表示の言語を `<html lang>` にし、
/// `theme` が `Light` か `Dark` なら `data-theme` を出す。`refresh` が
/// `RefreshEverySeconds` なら `<meta http-equiv="refresh">` を出す。ナビゲーションバーと、
/// `title` を見出し（h1）にした本文を出す。
pub fn page(
  language: Language,
  theme: Theme,
  title: i18n.Message,
  layout: Layout,
  switch: NavbarSwitch,
  refresh: Refresh,
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
      refresh_meta(refresh),
      html.title([], "Nostr-no-Su — " <> title),
      favicon_link(),
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

/// `refresh` に応じた `<meta http-equiv="refresh">`。`NoRefresh` は何も出さない。
fn refresh_meta(refresh: Refresh) -> Element(msg) {
  case refresh {
    NoRefresh -> element.none()
    RefreshEverySeconds(seconds:) ->
      html.meta([
        attribute.attribute("http-equiv", "refresh"),
        attribute.content(int.to_string(seconds)),
      ])
  }
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
              "btn btn-ghost gap-2 px-2 text-lg font-bold focus-visible:outline-base-content",
            ),
          ],
          [logo_icon(), html.text("Nostr-no-Su")],
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
    theme_icon(),
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
    language_icon(),
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
  icon: Element(msg),
  label: String,
  action: List(String),
  return_to: String,
  items: List(Element(msg)),
) -> Element(msg) {
  html.details(
    [attribute.name(navbar_menu_name), attribute.class("dropdown dropdown-end")],
    [
      html.summary(
        [
          attribute.aria_label(label),
          attribute.class("btn btn-sm gap-1 focus-visible:outline-base-content"),
        ],
        [
          icon,
          html.span([attribute.class("hidden sm:inline")], [html.text(label)]),
          chevron_icon(),
        ],
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

/// 線で描く飾りの SVG アイコン。読み上げず、`currentColor` で線を描く。`extra` は既定の属性の
/// 並びの末尾に足す。
fn icon_svg(
  class: String,
  view_box: String,
  extra: List(Attribute(msg)),
  paths: List(String),
) -> Element(msg) {
  svg.svg(
    [
      attribute.aria_hidden(True),
      attribute.attribute("viewBox", view_box),
      attribute.attribute("fill", "none"),
      attribute.attribute("stroke", "currentColor"),
      attribute.attribute("stroke-width", "2"),
      attribute.class(class),
      ..extra
    ],
    list.map(paths, fn(path) { svg.path([attribute.attribute("d", path)]) }),
  )
}

/// 線で描く 16 × 16 の飾りのアイコン。読み上げない。
fn icon(class: String, path: String) -> Element(msg) {
  icon_svg(class, "0 0 16 16", [], [path])
}

/// Lucide（ISC）の 24 × 24 のストロークアイコン。`currentColor` で描き、読み上げない飾りに
/// する。
pub fn lucide_icon(class: String, paths: List(String)) -> Element(msg) {
  icon_svg(
    class,
    "0 0 24 24",
    [
      attribute.attribute("stroke-linecap", "round"),
      attribute.attribute("stroke-linejoin", "round"),
    ],
    paths,
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
  card_element(
    None,
    "card border border-base-300 bg-base-100 shadow-sm",
    content,
  )
}

/// タイルのリンク先の `id` を持つ節のカード。
pub fn section_card(id: String, content: List(Element(msg))) -> Element(msg) {
  card_element(
    Some(id),
    "card border border-base-300 bg-base-100 shadow-sm",
    content,
  )
}

/// 承認待ちの節の warning 色の枠のカード。
pub fn warning_card(id: String, content: List(Element(msg))) -> Element(msg) {
  card_element(
    Some(id),
    "card border border-warning bg-base-100 shadow-sm",
    content,
  )
}

/// `card`、`section_card`、`warning_card` が共有するカードの組み立て。`id` があれば要素に
/// 付ける。
fn card_element(
  id: Option(String),
  class: String,
  content: List(Element(msg)),
) -> Element(msg) {
  let id_attribute = case id {
    Some(id) -> [attribute.id(id)]
    None -> []
  }
  html.section([attribute.class(class), ..id_attribute], [
    html.div([attribute.class("card-body gap-4 p-4 sm:p-6")], content),
  ])
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

/// プラグインのフォームが宣言するチェック 1 件の行。チェック、ラベル、あれば説明を
/// 並べる。送信値は `on` に固定する。`checkbox_row` と似た形だが、あちらはアイコンと
/// バッジを同じ行に挟むため、この部品と共通化しない。
pub fn plugin_checkbox_row(
  name: String,
  label: String,
  hint: Option(String),
  checked: Bool,
) -> Element(msg) {
  let description = case hint {
    Some(hint) -> [
      html.span([attribute.class("text-sm text-base-content/70 break-all")], [
        html.text(hint),
      ]),
    ]
    None -> []
  }
  html.label([attribute.class("flex items-center gap-3 text-sm")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.name(name),
      attribute.value("on"),
      attribute.class("checkbox border-base-content/60"),
      attribute.checked(checked),
    ]),
    html.div([attribute.class("flex min-w-0 flex-col")], [
      html.span([], [html.text(label)]),
      ..description
    ]),
  ])
}

/// 行が 1 件も無い節の本文。アイコンと 1 文を横に並べる。
pub fn empty_state(icon: Element(msg), text: String) -> Element(msg) {
  html.div(
    [attribute.class("flex items-center gap-2 text-sm text-base-content/70")],
    [icon, html.text(text)],
  )
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

/// 見出しと `dd` 要素の組の一覧（`dl`）。見出しを値の左に置くので、狭い画面でも横に伸びない。
/// 値には `html.dd` で包んだ要素を渡す。
pub fn detail_list(entries: List(#(String, Element(msg)))) -> Element(msg) {
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
        value,
      ]
    }),
  )
}

/// 見出しと値の組の一覧（`dl`）。見出しを値の左に置くので、狭い画面でも横に伸びない。
pub fn summary_list(entries: List(#(String, Value))) -> Element(msg) {
  detail_list(
    list.map(entries, fn(entry) { #(entry.0, summary_value(entry.1)) }),
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
  }
}

/// アカウントを識別する、ラベルと省略した npub。アカウントの一覧、読み込みで飛ばされた
/// 行、アカウントのサブページが使う。16 進の公開鍵はここには出さない。
pub fn identity(
  language: Language,
  label: String,
  npub: String,
) -> Element(msg) {
  html.div([attribute.class("flex min-w-0 flex-col gap-1")], [
    html.p([attribute.class("font-semibold break-words")], [html.text(label)]),
    truncated_id(language, npub, i18n.text(language, i18n.CopyNpub)),
  ])
}

/// アイコンを添えたカードの見出し。
pub fn icon_heading(icon: Element(msg), title: String) -> Element(msg) {
  html.div([attribute.class("flex items-center gap-2")], [
    icon,
    heading(title),
  ])
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
    InRow, Normal -> "btn btn-ghost btn-sm focus-visible:outline-base-content"
    InRow, Primary ->
      "btn btn-primary btn-sm focus-visible:outline-base-content"
    InRow, Caution -> "btn btn-ghost btn-sm focus-visible:outline-base-content"
    InRow, Destructive ->
      "btn btn-ghost btn-sm text-error focus-visible:outline-base-content"
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

/// 見出しを付けた選択欄。`options` は `#(値, 表示)` の並び順で出し、`selected` と等しい
/// 値の項目を選択済みにする。
pub fn select_field(
  caption: String,
  name: String,
  options: List(#(String, String)),
  selected: String,
) -> Element(msg) {
  labelled(
    caption,
    html.select(
      [
        attribute.name(name),
        attribute.class("select w-full border-base-content/60"),
      ],
      list.map(options, option_item(_, selected)),
    ),
  )
}

/// 選択欄の項目 1 件。値が `selected` と等しければ選択済みにする。
fn option_item(option: #(String, String), selected: String) -> Element(msg) {
  let #(value, caption) = option
  html.option(
    [attribute.value(value), attribute.selected(value == selected)],
    caption,
  )
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

/// 見出し、複数行の入力欄、案内をまとめた囲み。`hinted_input` と同じ構造で、欄だけ
/// `textarea` にする。値は `html.textarea` の内容で出す（`input` の `default_value` では
/// ない）。
pub fn hinted_textarea(
  caption: String,
  hint_id: String,
  hint: String,
  value: String,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  html.div([attribute.class("fieldset")], [
    html.span([attribute.class("fieldset-legend")], [html.text(caption)]),
    html.textarea(
      [
        attribute.aria_label(caption),
        attribute.aria_describedby(hint_id),
        ..attributes
      ],
      value,
    ),
    html.p([attribute.id(hint_id), attribute.class("text-base-content/70")], [
      html.text(hint),
    ]),
  ])
}

/// チェック 1 つぶんの大きな行。チェック、アイコン、語、説明、あればバッジを 1 行に
/// 並べる。
pub fn checkbox_row(
  name: String,
  icon: Element(msg),
  caption: String,
  description: Element(msg),
  checked: Bool,
  badge: List(Element(msg)),
) -> Element(msg) {
  html.label([attribute.class("flex items-center gap-3 text-sm")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.name(name),
      attribute.value("on"),
      attribute.class("checkbox border-base-content/60"),
      attribute.checked(checked),
    ]),
    icon,
    html.div([attribute.class("flex min-w-0 flex-col")], [
      html.span([], [html.text(caption)]),
      html.span([attribute.class("text-sm text-base-content/70")], [
        description,
      ]),
    ]),
    ..badge
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

/// 通知や理由を、薄い塗りの囲みで出す。先頭にトーンのアイコンを置き、文字は本文色にする。
pub fn alert(tone: Tone, content: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class(alert_class(tone))], [
    tone_icon(tone),
    html.span([], content),
  ])
}

/// フォームの上に出す理由の囲み。`role="alert"` で伝え、先頭のトーンのアイコンと薄い塗りで
/// `tone` を伝える。
pub fn reason_alert(tone: Tone, content: List(Element(msg))) -> Element(msg) {
  html.div([attribute.role("alert"), attribute.class(alert_class(tone))], [
    tone_icon(tone),
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

/// 読み飛ばされては困る注意（秘密鍵の表示と、secret が一致しない承認ページ）。先頭に警告の
/// アイコンを置く。
pub fn warning(content: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class(alert_class(Warning))], [
    tone_icon(Warning),
    html.p([], content),
  ])
}

/// 強調した 1 文と、それに続く文。文の間は表示の言語の区切り（`i18n.sentence_gap`）に
/// する。
pub fn emphasized(
  language: Language,
  first: i18n.Message,
  rest: i18n.Message,
) -> List(Element(msg)) {
  [
    html.strong([], [html.text(i18n.text(language, first))]),
    html.text(i18n.sentence_gap(language) <> i18n.text(language, rest)),
  ]
}

/// トーンごとの囲みのクラス。薄い塗り（`alert-soft`）に本文色の文字を合わせる
/// （`alert-soft` は既定で状態色の文字にするため）。
fn alert_class(tone: Tone) -> String {
  case tone {
    Neutral -> "alert alert-soft text-base-content"
    Success -> "alert alert-soft alert-success text-base-content"
    Warning -> "alert alert-soft alert-warning text-base-content"
    Failure -> "alert alert-soft alert-error text-base-content"
    Info -> "alert alert-soft alert-info text-base-content"
  }
}

/// トーンごとのアイコン。`Neutral` と `Info` は情報、ほかはトーンの色（`text-success` など）を
/// 付けた丸のチェック・三角・丸の×。`alert`、`reason_alert`、`warning`、`status_badge` が共有
/// する。
pub fn tone_icon(tone: Tone) -> Element(msg) {
  case tone {
    Neutral -> lucide_icon("size-4", info_icon_paths)
    Success -> lucide_icon("size-4 text-success", check_circle_icon_paths)
    Warning -> lucide_icon("size-4 text-warning", warning_triangle_icon_paths)
    Failure -> lucide_icon("size-4 text-error", x_circle_icon_paths)
    Info -> lucide_icon("size-4 text-info", info_icon_paths)
  }
}

/// アイコン＋語の状態バッジ。`Neutral` は無色の ghost、ほかはトーンの色の薄い塗り。
pub fn status_badge(tone: Tone, text: String) -> Element(msg) {
  let class = case tone {
    Neutral -> "badge badge-ghost badge-sm whitespace-nowrap gap-1"
    Success -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-success"
    Warning -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-warning"
    Failure -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-error"
    Info -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-info"
  }
  html.span([attribute.class(class)], [tone_icon(tone), html.text(text)])
}

/// 件数のピル。
pub fn count_pill(count: Int) -> Element(msg) {
  html.span([attribute.class("badge badge-ghost badge-sm tabular-nums")], [
    html.text(int.to_string(count)),
  ])
}

/// `<details>` の畳み。`summary` はボタンの見た目で、開閉の矢印と語を置く。本文は開いたときに
/// 上へ余白を空ける。JS なしで動く。
pub fn details_panel(
  summary_text: String,
  content: List(Element(msg)),
) -> Element(msg) {
  html.details([], [
    html.summary(
      [
        attribute.class(
          "btn btn-ghost btn-sm focus-visible:outline-base-content",
        ),
      ],
      [chevron_icon(), html.text(summary_text)],
    ),
    html.div([attribute.class("pt-2")], content),
  ])
}

/// 16 進や npub を先頭 10 桁と末尾 6 桁に短くし、間を `…` にした文字列。17 文字以下はそのまま
/// 返す。
pub fn shorten(value: String) -> String {
  case string.length(value) <= 17 {
    True -> value
    False -> string.slice(value, 0, 10) <> "…" <> string.slice(value, -6, 6)
  }
}

/// 省略した識別子。`shorten` した表示（`title` に全文）、コピー用の読み取り専用の全文の
/// `input`、コピーボタンを並べ、`copyable_field` と同じ `role="status"` の案内を添える。
/// ボタンは `priv/static/admin.js` の `copy` の処理を指し、その処理が読む構造
/// （欄はボタンの直前の兄弟、囲みはボタンの親の親）に合わせている。
pub fn truncated_id(
  language: Language,
  value: String,
  copy_label: String,
) -> Element(msg) {
  let copied = i18n.text(language, i18n.Copied)
  html.div([attribute.class("group")], [
    html.div([attribute.class("flex items-center gap-1")], [
      html.span([attribute.class("font-mono text-xs"), attribute.title(value)], [
        html.text(shorten(value)),
      ]),
      html.input([
        attribute.type_("text"),
        attribute.readonly(True),
        attribute.default_value(value),
        attribute.class("sr-only"),
      ]),
      html.button(
        [
          attribute.type_("button"),
          attribute.data("action", "copy"),
          attribute.aria_label(copy_label),
          attribute.class(
            "btn btn-ghost btn-sm group-data-copied:btn-success focus-visible:outline-base-content",
          ),
        ],
        [copy_icon()],
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

/// アイコン＋語のボタンのリンク。ダッシュボードの節の主操作と、アカウントの行の操作に使う。
pub fn icon_button_link(
  href: String,
  icon: Element(msg),
  text: String,
  weight: Weight,
) -> Element(msg) {
  html.a([attribute.href(href), attribute.class(button_class(weight, InRow))], [
    icon,
    html.text(text),
  ])
}

/// アイコンだけのボタンのリンク。語は読み上げのための `aria-label` に置く。
pub fn icon_only_link(
  href: String,
  icon: Element(msg),
  label: String,
  weight: Weight,
) -> Element(msg) {
  html.a(
    [
      attribute.href(href),
      attribute.aria_label(label),
      attribute.class(button_class(weight, InRow)),
    ],
    [icon],
  )
}

/// ロゴの SVG の `viewBox`。ヘッダーのロゴと favicon で共有する。
const logo_view_box = "177 86 900 900"

/// ビーバーの体の輪郭。目と歯を副パスに持ち、`fill-rule="evenodd"` で穴にする。
const logo_body_path = "M 513.0000 164.5029 A 402 402 0 0 0 275.4029 744.8935  C 297.2193 784.2514 445 774 552 716  C 619 680 659 629 680 569  C 709 498 762 453 816 430  C 827 432 839 431 847 425  C 867 429 883 414 883 395  L 883 342  C 911 319 921 280 872 262  C 818 175 733 145 620 162  C 614 138 592 120 566 120  C 535 120 510 140 513.0000 164.5029 Z M 762 266 A 24 24 0 1 0 714 266 A 24 24 0 1 0 762 266 Z M 818 354 Q 813 354 813 360 L 813 414 Q 813 422 827 422 Q 841 422 841 414 L 841 351 Z M 850 350 L 875 346 L 875 395 Q 875 416 858 418 L 850 418 Z"

/// ビーバーの尻尾。
const logo_tail_path = "M 293.7269 774.7955 A 402 402 0 0 0 1028.4491 571.0391  C 1034 499 985 454 908 454  C 826 454 747 506 713 586  C 684 664 632 717 562 750  C 471 794 366 805 293.7269 774.7955 Z"

/// 目と歯。カラー版でだけ白く塗り、単色版では `logo_body_path` の穴のままにする。
const logo_face_path = "M 762 266 A 24 24 0 1 0 714 266 A 24 24 0 1 0 762 266 Z M 818 354 Q 813 354 813 360 L 813 414 Q 813 422 827 422 Q 841 422 841 414 L 841 351 Z M 850 350 L 875 346 L 875 395 Q 875 416 858 418 L 850 418 Z"

/// 上部バーのロゴの飾り。単色版のロゴを `currentColor` で塗る。読み上げない。
pub fn logo_icon() -> Element(msg) {
  svg.svg(
    [
      attribute.aria_hidden(True),
      attribute.attribute("viewBox", logo_view_box),
      attribute.attribute("fill", "currentColor"),
      attribute.class("size-5"),
    ],
    [
      svg.path([
        attribute.attribute("d", logo_body_path),
        attribute.attribute("fill-rule", "evenodd"),
      ]),
      svg.path([attribute.attribute("d", logo_tail_path)]),
    ],
  )
}

/// テーマの切り替えのアイコン（Lucide の sun-moon）。
pub fn theme_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M12 8a2.83 2.83 0 0 0 4 4 4 4 0 1 1-4-4", "M12 2v2", "M12 20v2",
    "m4.9 4.9 1.4 1.4", "m17.7 17.7 1.4 1.4", "M2 12h2", "M20 12h2",
    "m6.3 17.7-1.4 1.4", "m19.1 4.9-1.4 1.4",
  ])
}

/// 言語の切り替えのアイコン（Lucide の languages）。
pub fn language_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "m5 8 6 6", "m4 14 6-6 2-3", "M2 5h12", "M7 2h1", "m22 22-5-10-5 10",
    "M14 18h6",
  ])
}

/// `info_icon` のストローク（Lucide の info）。
const info_icon_paths = [
  "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "M12 16v-4", "M12 8h.01",
]

/// `check_circle_icon` のストローク（Lucide の circle-check）。
const check_circle_icon_paths = [
  "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "m9 12 2 2 4-4",
]

/// `warning_triangle_icon` のストローク（Lucide の triangle-alert）。
const warning_triangle_icon_paths = [
  "m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3",
  "M12 9v4", "M12 17h.01",
]

/// `x_circle_icon` のストローク（Lucide の circle-x）。
const x_circle_icon_paths = [
  "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "m15 9-6 6", "m9 9 6 6",
]

/// `Neutral` のトーンのアイコン（Lucide の info）。
pub fn info_icon() -> Element(msg) {
  lucide_icon("size-4", info_icon_paths)
}

/// `Success` のトーンのアイコン（Lucide の circle-check）。
pub fn check_circle_icon() -> Element(msg) {
  lucide_icon("size-4", check_circle_icon_paths)
}

/// `Warning` のトーンのアイコン（Lucide の triangle-alert）。
pub fn warning_triangle_icon() -> Element(msg) {
  lucide_icon("size-4", warning_triangle_icon_paths)
}

/// `Failure` のトーンのアイコン（Lucide の circle-x）。
pub fn x_circle_icon() -> Element(msg) {
  lucide_icon("size-4", x_circle_icon_paths)
}

/// コピーボタンのアイコン（Lucide の copy）。
pub fn copy_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M8 8h11a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V10a2 2 0 0 1 2-2z",
    "M4 16a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v2",
  ])
}

/// 追加のボタンのアイコン（Lucide の plus）。
pub fn plus_icon() -> Element(msg) {
  lucide_icon("size-4", ["M5 12h14", "M12 5v14"])
}

/// 削除のボタンのアイコン（Lucide の trash-2）。
pub fn trash_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M3 6h18", "M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6",
    "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2", "M10 11v6", "M14 11v6",
  ])
}

/// 編集のボタンのアイコン（Lucide の pencil）。
pub fn pencil_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z",
    "m15 5 4 4",
  ])
}

/// 接続のボタンのアイコン（Lucide の plug）。
pub fn plug_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M12 22v-5", "M9 8V2", "M15 8V2",
    "M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z",
  ])
}

/// 監視の用途と、秘密鍵の表示のアイコン（Lucide の eye）。
pub fn eye_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0",
    "M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0",
  ])
}

/// 秘密鍵の節と、バンカーの用途のアイコン（Lucide の key）。
pub fn key_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "m15.5 7.5 2.3 2.3a1 1 0 0 0 1.4 0l2.1-2.1a1 1 0 0 0 0-1.4L19 4",
    "m21 2-9.6 9.6", "M2 15.5a5.5 5.5 0 1 0 11 0a5.5 5.5 0 1 0 -11 0",
  ])
}

/// secret の再生成のアイコン（Lucide の refresh-cw）。
pub fn rotate_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8", "M3 3v5h5",
    "M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16", "M16 16h5v5",
  ])
}

/// アカウントの節のアイコン（Lucide の users）。
pub fn users_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2",
    "M5 7a4 4 0 1 0 8 0a4 4 0 1 0 -8 0", "M22 21v-2a4 4 0 0 0-3-3.87",
    "M16 3.13a4 4 0 0 1 0 7.75",
  ])
}

/// セッションの節のアイコン（Lucide の clock）。
pub fn clock_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "M12 6v6l4 2",
  ])
}

/// プラグインの節のアイコン（Lucide の puzzle）。
pub fn puzzle_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M19.439 7.85c-.049.322.059.648.289.878l1.568 1.568c.47.47.706 1.087.706 1.704s-.235 1.233-.706 1.704l-1.611 1.611a.98.98 0 0 1-.837.276c-.47-.07-.802-.48-.968-.925a2.5 2.5 0 1 0-3.214 3.214c.446.166.855.497.925.968a.979.979 0 0 1-.276.837l-1.61 1.61a2.404 2.404 0 0 1-1.705.707 2.402 2.402 0 0 1-1.704-.706l-1.568-1.568a1.026 1.026 0 0 0-.877-.29c-.493.074-.84.504-1.02.968a2.5 2.5 0 1 1-3.237-3.237c.464-.18.894-.527.967-1.02a1.026 1.026 0 0 0-.289-.877l-1.568-1.568A2.402 2.402 0 0 1 2 12c0-.617.236-1.234.706-1.704L4.23 8.77c.24-.24.581-.353.917-.303.515.077.877.528 1.073 1.01a2.5 2.5 0 1 0 3.259-3.259c-.482-.196-.933-.558-1.01-1.073-.05-.336.062-.676.303-.917l1.525-1.525A2.402 2.402 0 0 1 12 2c.617 0 1.234.236 1.704.706l1.568 1.568c.23.23.556.338.877.29.493-.074.84-.504 1.02-.968a2.5 2.5 0 1 1 3.237 3.237c-.464.18-.894.527-.967 1.02Z",
  ])
}

/// プラグインのページへのリンクのアイコン（Lucide の file-text）。
pub fn file_text_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z",
    "M14 2v4a2 2 0 0 0 2 2h4", "M10 9H8", "M16 13H8", "M16 17H8",
  ])
}

/// ダッシュボードへ戻るリンクの段落。
pub fn back_link(language: Language) -> Element(msg) {
  html.p([], [
    html.a([attribute.href("/"), attribute.class("link")], [
      html.text(i18n.text(language, i18n.BackToDashboard)),
    ]),
  ])
}
