//// 管理 UI のページ枠と、`admin/i18n` と `admin/wordmark`（生成した字形のパス）以外の本体の
//// モジュールに依存しない HTML の部品。lustre の要素ツリーで組み立てるが、lustre の component（`lustre/component`）や server
//// components は使わない。部品は `Element` を返し、HTML 文書の文字列にするのは
//// `page` と `page_in_language` だけである。
////
//// 値はテキストか属性値として lustre に渡し、HTML のエスケープは lustre の文字列化に
//// 任せる。エスケープでは防げない経路には決まった値だけを渡す。`html.style`、
//// `html.script`、`element.unsafe_raw_html`、イベント属性（`on*`）は使わない。JS の処理は
//// `priv/static/admin.js` に置き、要素には `data-action` で処理の名前を付ける（CSP の
//// `script-src 'self'` がインラインのスクリプトを実行させない。`script_test` が検査する）。
//// 時刻は `time_of_day` の `<time datetime>` で UTC のまま描き、`admin.js` が閲覧者のローカルの
//// 時刻に直す。欄の補足を ⓘ で開く部品（`FieldHint` の `FoldedHint`）は、`popover` 属性の段落と
//// `popovertarget` のボタンで開閉し、位置は CSS の anchor positioning（`position-area`）で決める。
//// JS も `data-action` も使わない。
//// 確認と小さいフォームのダイアログは `<button commandfor command>` と `<dialog>` で開閉し、JS を使わない（`dialog_button`）。
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
//// で色を継ぐ飾りである。製品のロゴだけは固定の色で塗った板つきの SVG で、上部バーと
//// `<head>` の favicon のどちらにも同じ文書を `data:` の URI にして出す。
//// 上部バーの製品名は `admin/wordmark` の M PLUS 2 の字形のパスを塗りで描き、「Nostr」と「Su」を
//// base-content、「-no-」を primary のユーティリティで塗る。字形は読み上げず、同じ語を
//// `sr-only` の文字で出す。

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/wordmark

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

/// 対応するテーマ。ナビゲーションバーのテーマの切り替えは、この順にボタンを並べる。
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

/// 言語の切り替えに並べるボタンの順。ブラウザーの設定を先頭に置き、続けて `i18n.languages` の順。
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

/// ボタンの種類。daisyUI のボタンのクラスを決める。
pub type ButtonKind {
  /// 主の操作（登録、保存、承認、追加、接続）と、secret が一致しない承認待ちの拒否。塗りの primary。
  PrimaryButton
  /// 枠だけのボタン。フォームの末尾の、主ではない送信と、空の節の操作に使う。
  OutlineButton
  /// 地味なボタン。主でも危険でもない操作の入口と、取り消しのきく操作の送信に使う。
  GhostButton
  /// 取り返しのつかない操作の送信。塗りの error。
  DangerButton
  /// 取り返しのつかない操作への入口。地味なボタンに error の文字色。
  DangerGhostButton
  /// 秘密を画面に出す、または接続中のクライアントに影響する操作の送信と、secret が一致しない承認待ちの承認。warning の枠。
  WarningOutlineButton
}

/// ボタンを置く場所。
pub type Placement {
  /// ダッシュボードの行や承認ページのように、小さいボタンを横に並べる。
  InRow
  /// 確認のページのように、欄を縦に並べたフォームの末尾に置く。
  InForm
}

/// 通知のページの結果の印、通知や理由の囲み、`ToneChip` のチップの色。
pub type Tone {
  /// 良し悪しを伝えない結果（接続の拒否）と、正常な構成でもありうる理由（接続 QR コード、クライアントの
  /// 接続、権限の編集のページで、リレー、アカウント、セッションを得られない）。
  Neutral
  /// 求めた操作が反映された結果（接続の承認）。
  Success
  /// 反映されたか分からない変更、今は受け付けられない変更、秘密鍵のバックアップの注意。
  Warning
  /// 処理できなかった操作、フォームの上の失敗の理由、ダッシュボードの節の一覧を得られない理由
  /// （0 件と読み違えさせない）、バンカーに使うリレーが無いこと（クライアントが接続できない）。
  Failure
  /// 承認の意味の説明など、危険を伴わない補足。
  Info
}

/// 状態のチップと状態の注記（`status_note`）の種類。色とアイコンを決め、語は呼び出し側が渡す。
pub type Chip {
  /// 接続中、動作中。success の色と circle-check。
  ActiveChip
  /// リレーの未接続。warning の色と unplug。
  DisconnectedChip
  /// 締め切りまでに状態が返らない（リレーの用途、プラグイン）。warning の色と clock。
  UnansweredChip
  /// 使っていないリレーの用途。点線の枠で塗らず、circle-minus。
  UnusedChip
  /// プラグインの過負荷。warning の色と gauge。
  OverloadedChip
  /// プラグインの無効。error の色と ban。
  DisabledChip
  /// 起動時に読み込めなかったプラグインと、読み込みで飛ばされたアカウントの行。error の色と octagon-alert。
  LoadFailedChip
  /// 承認待ちの secret の提示なし。色を付けず shield。
  SecretNotOfferedChip
  /// 承認待ちの secret の不一致。warning の色と shield-alert。
  SecretMismatchChip
  /// 状態の表に無いチップ（プラグインのページの `badge`、権限の宣言なし、概要の帯の「取得できません」とバンカー用リレーなし、「はじめに」の帯の済んだ段）。
  /// 色は `tone_chip_class`、アイコンは `tone_icon` でトーンから決まる。
  ToneChip(tone: Tone)
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

/// 板つきのロゴの SVG の文書。`assets/logo/nostr-no-su-plate.svg` はこの文字列に改行を 1 つ
/// 足したものである。図形の色はテーマに関係なく固定で、体は紺、尻尾は青緑、目と歯は白にする。
/// 図形は白い丸い板に載り、板の内側に灰色の縁が付く。図形は板の直径の 85% の大きさで、縁の幅は
/// 板の直径の 1.5/46（46px の板で 1.5px）にする。
pub fn logo_svg() -> String {
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\""
  <> logo_view_box
  <> "\" width=\"900\" height=\"900\" role=\"img\" aria-labelledby=\"title\"><title id=\"title\">Nostr no Su — beaver logo</title><circle cx=\"627\" cy=\"536\" r=\"512.1483\" fill=\"#FFFFFF\" stroke=\"#C3CCD8\" stroke-width=\"34.5269\" /><path fill=\"#FFFFFF\" d=\""
  <> logo_face_path
  <> "\" /><path fill=\"#183965\" fill-rule=\"evenodd\" d=\""
  <> logo_body_path
  <> "\" /><path fill=\"#28B9BE\" d=\""
  <> logo_tail_path
  <> "\" /></svg>"
}

/// `logo_svg` を `data:` の URI にしたもの。上部バーのロゴと favicon で共有する。
fn logo_data_uri() -> String {
  "data:image/svg+xml," <> percent_encode_svg(logo_svg())
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
    attribute.href(logo_data_uri()),
  ])
}

/// 管理 UI 共通のページ枠を HTML 文書の文字列にする。`title` を表示の言語で引き、
/// `<title>` の `Nostr-no-Su — ` の後と見出し（h1）に出す。枠の残りは `document` が出す。
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
  document(
    language,
    theme,
    html.title([], "Nostr-no-Su — " <> title),
    [html.text(title)],
    layout,
    switch,
    refresh,
    body,
  )
}

/// 見出しが本体の訳文でない文字列（プラグイン由来の文字列）のページ枠を HTML 文書の文字列に
/// する。`code` は `title` が書かれている言語のコードで、見出し（h1）には `title` を
/// `in_language` の `span` で出す。`<title>` は子の要素を持てないので、`title` を
/// `Nostr-no-Su — ` の後に置いた `<title>` 要素そのものに `lang` を付ける。枠の残りは
/// `document` が出す。
pub fn page_in_language(
  language: Language,
  theme: Theme,
  code: String,
  title: String,
  layout: Layout,
  switch: NavbarSwitch,
  refresh: Refresh,
  body: List(Element(msg)),
) -> String {
  document(
    language,
    theme,
    html.title([attribute.lang(code)], "Nostr-no-Su — " <> title),
    [in_language(code, title)],
    layout,
    switch,
    refresh,
    body,
  )
}

/// `page` と `page_in_language` が共有するページ枠を HTML 文書の文字列にする。表示の言語を
/// `<html lang>` にし、`theme` が `Light` か `Dark` なら `data-theme` を出す。`refresh` が
/// `RefreshEverySeconds` なら `<meta http-equiv="refresh">` を出す。`<head>` に
/// `title`（`<title>` 要素）を置き、ナビゲーションバーと、`h1_content` を見出し（h1）にした
/// 本文を出す。
fn document(
  language: Language,
  theme: Theme,
  title: Element(msg),
  h1_content: List(Element(msg)),
  layout: Layout,
  switch: NavbarSwitch,
  refresh: Refresh,
  body: List(Element(msg)),
) -> String {
  let attrs = [attribute.lang(i18n.code(language)), ..theme_attributes(theme)]
  html.html(attrs, [
    html.head([], [
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width,initial-scale=1"),
      ]),
      refresh_meta(refresh),
      title,
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
        html.h1([attribute.class("text-2xl font-bold")], h1_content),
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

/// 全ページ共通のナビゲーションバー。帯の地と下の線を付けず、ページの地の上に置く。
/// 左端に `brand_link` のロゴを置き、右端（`navbar-end`）にテーマと言語の切り替えを置く。
/// ロゴの枠（`navbar-start`）は内容の幅を基準に伸びるので、1 行に収まらない幅ではロゴを縮めずに、
/// 切り替えを次の行の右端に送る。切り替えを出さないページでも右端の枠は残す。
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
      attribute.class("navbar flex-wrap justify-end gap-2 px-4 sm:px-6"),
    ],
    [
      html.div([attribute.class("navbar-start w-auto grow")], [
        brand_link(language),
      ]),
      html.div([attribute.class("navbar-end w-auto gap-2")], end),
    ],
  )
}

/// テーマの切り替え。テーマは `themes` の順（ブラウザーの設定、ライト、ダーク）に、
/// モニター、太陽、月のアイコンだけのボタンで並べる。語は `aria-label` と `title` に出す。
fn theme_switch(
  language: Language,
  current: Theme,
  return_to: String,
) -> Element(msg) {
  switch_group(
    i18n.text(language, i18n.ThemeSwitchLabel),
    theme_segments,
    return_to,
    list.map(themes, fn(theme) {
      let label = i18n.text(language, theme_label(theme))
      switch_button(
        theme_field,
        theme_code(theme),
        theme == current,
        [attribute.aria_label(label), attribute.title(label)],
        [theme_choice_icon(theme)],
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

/// テーマの項目のアイコン。
fn theme_choice_icon(theme: Theme) -> Element(msg) {
  case theme {
    System -> monitor_icon()
    Light -> sun_icon()
    Dark -> moon_icon()
  }
}

/// 言語の切り替え。先頭にブラウザーの設定を地球のアイコンだけのボタンで置き（語は
/// `aria-label` と `title` に出す）、続けて `i18n.languages` の順に、言語名をその言語自身で
/// 書いて `lang` を付けたボタンを並べる。ブラウザーの設定は押した状態にしない（描画は
/// cookie の有無を知らないため、押した状態は常に表示している言語につく）。
fn language_switch(current: Language, return_to: String) -> Element(msg) {
  switch_group(
    i18n.text(current, i18n.LanguageSwitchLabel),
    language_segments,
    return_to,
    list.map(language_choices(), fn(choice) {
      let #(pressed, extra, content) = case choice {
        BrowserLanguage -> {
          let label = i18n.text(current, i18n.FollowBrowser)
          #(False, [attribute.aria_label(label), attribute.title(label)], [
            globe_icon(),
          ])
        }
        ChosenLanguage(language) -> #(
          language == current,
          [attribute.lang(i18n.code(language))],
          [html.text(i18n.native_name(language))],
        )
      }
      switch_button(
        language_field,
        language_choice_code(choice),
        pressed,
        extra,
        content,
      )
    }),
  )
}

/// 上部の切り替えの 1 つ。`action` へ POST するフォームで、戻り先を隠し欄で送り、送信ボタンを
/// daisyUI の `join` で 1 つの枠に並べる。隠し欄は枠の外に置く（`join` は角の丸めを最初と
/// 最後の子で決めるため）。枠は `role="group"` にし、`label` を読み上げの名前にする。JS なしで
/// 動く。
fn switch_group(
  label: String,
  action: List(String),
  return_to: String,
  buttons: List(Element(msg)),
) -> Element(msg) {
  html.form(
    [attribute.method("post"), attribute.action(segments_path(action))],
    [
      hidden_input(return_field, return_to),
      html.div(
        [
          attribute.role("group"),
          attribute.aria_label(label),
          attribute.class("join"),
        ],
        buttons,
      ),
    ],
  )
}

/// 切り替えの送信ボタン 1 つ。押すと `field` に `value` を送る。今の値（`pressed`）は
/// `aria-pressed="true"` と `btn-neutral` の塗りで示し、ほかは `aria-pressed="false"` にする。
/// 今の値のボタンも押せて、同じ値を送り直す。`extra` は語や `lang` の属性、`content` は
/// アイコンか言語名である。
fn switch_button(
  field: String,
  value: String,
  pressed: Bool,
  extra: List(Attribute(msg)),
  content: List(Element(msg)),
) -> Element(msg) {
  let #(aria_pressed, class) = case pressed {
    True -> #(
      "true",
      "join-item btn btn-sm btn-neutral focus-visible:outline-base-content",
    )
    False -> #(
      "false",
      "join-item btn btn-sm focus-visible:outline-base-content",
    )
  }
  html.button(
    [
      attribute.type_("submit"),
      attribute.name(field),
      attribute.value(value),
      attribute.aria_pressed(aria_pressed),
      attribute.class(class),
      ..extra
    ],
    content,
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

/// ダッシュボードの節。枠を持たず、節の見出し（`section_heading`）と本文を縦に並べる。`id` は概要の帯の項目のリンク先である。
pub fn section_block(id: String, content: List(Element(msg))) -> Element(msg) {
  html.section(
    [attribute.id(id), attribute.class("flex flex-col gap-3")],
    content,
  )
}

/// 節の見出し。`primary` を薄く混ぜた地の面に載せたアイコン、題（`h2`）、`count` があれば件数のピルを 1 行に並べ、
/// `description` があればその下に 1 行の説明を補助の文字の色で出す。`actions` は右端に置き、幅が足りなければ
/// 下に回る。`actions` が空なら右には何も置かない。
pub fn section_heading(
  icon: Element(msg),
  title: String,
  count: Option(Int),
  description: Option(String),
  actions: List(Element(msg)),
) -> Element(msg) {
  let pill = case count {
    Some(count) -> count_badge(count)
    None -> element.none()
  }
  let description_line = case description {
    Some(description) ->
      html.p([attribute.class("text-sm text-muted sm:pl-10")], [
        html.text(description),
      ])
    None -> element.none()
  }
  let action_row = case actions {
    [] -> element.none()
    _ ->
      html.div(
        [attribute.class("ml-auto flex flex-wrap justify-end gap-2")],
        actions,
      )
  }
  html.div(
    [
      attribute.class(
        "flex flex-wrap items-start justify-between gap-x-4 gap-y-2",
      ),
    ],
    [
      html.div([attribute.class("flex min-w-0 flex-col gap-0.5")], [
        html.div([attribute.class("flex items-center gap-2.5")], [
          html.span(
            [
              attribute.class(
                "grid size-7.5 shrink-0 place-items-center rounded-field bg-primary/13 text-primary",
              ),
            ],
            [icon],
          ),
          heading(title),
          pill,
        ]),
        description_line,
      ]),
      action_row,
    ],
  )
}

/// 節の見出しの件数のピル。等幅の数字を補助の文字の色で出す。
fn count_badge(count: Int) -> Element(msg) {
  html.span(
    [
      attribute.class(
        "badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums",
      ),
    ],
    [html.text(int.to_string(count))],
  )
}

/// 一覧の 1 行の中身の並べ方。
pub type RowLayout {
  /// 値の組と操作を横に並べ、収まらなければ操作を下へ回す。
  InlineRow
  /// 中身を縦に積む。
  StackedRow
}

/// 行の一覧の枠（daisyUI の `list`）。面の色、枠線、角の丸みを付け、行の間は `list-row` が区切る。行は
/// `list_row` で作る。
pub fn row_list(rows: List(Element(msg))) -> Element(msg) {
  html.ul(
    [attribute.class("list rounded-box border border-base-300 bg-base-100")],
    rows,
  )
}

/// 一覧の 1 行（`list-row`）。`list-row` の格子の代わりに `layout` の並べ方で中身を置く（Tailwind の
/// ユーティリティは daisyUI の部品のクラスより優先される）。
pub fn list_row(
  layout: RowLayout,
  content: List(Element(msg)),
) -> Element(msg) {
  let class = case layout {
    InlineRow ->
      "list-row flex flex-wrap items-center justify-between gap-x-6 gap-y-3"
    StackedRow -> "list-row flex flex-col gap-3"
  }
  html.li([attribute.class(class)], content)
}

/// 面の色、枠線、角の丸みを持つ囲み。枠を持たない節（`section_block`）の中で、表や理由の囲みをページの地から浮かせる。
pub fn surface(content: List(Element(msg))) -> Element(msg) {
  html.div(
    [attribute.class("rounded-box border border-base-300 bg-base-100")],
    content,
  )
}

/// 節やカードの見出し（h2）。
pub fn heading(title: String) -> Element(msg) {
  html.h2([attribute.class("card-title")], [html.text(title)])
}

/// 本文より控えめな一言。行が無い節の説明、ページの末尾の案内、フォームの中の 1 行の補足に使う。
pub fn hint(text: String) -> Element(msg) {
  html.p([attribute.class("text-sm text-muted")], [html.text(text)])
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
      html.span([attribute.class("text-sm text-muted break-all")], [
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

/// 文字列の欄 2 種が共有する囲み。`label` が欄を包むので `id` が要らない。
fn plugin_field(
  label: String,
  hint: Option(String),
  input: Element(msg),
) -> Element(msg) {
  let description = case hint {
    Some(hint) -> [
      html.span([attribute.class("text-sm text-muted break-all")], [
        html.text(hint),
      ]),
    ]
    None -> []
  }
  html.label([attribute.class("fieldset")], [
    html.span([attribute.class("fieldset-legend")], [html.text(label)]),
    input,
    ..description
  ])
}

/// プラグインのフォームが宣言する 1 行の文字列の欄。`hinted_input` と違って補足の `id`
/// を使わないのは、プラグインが選ぶ `name` の一意性を本体が保証できないためである。
pub fn plugin_text_field(
  name: String,
  label: String,
  hint: Option(String),
  value: String,
) -> Element(msg) {
  plugin_field(
    label,
    hint,
    html.input([
      attribute.type_("text"),
      attribute.name(name),
      attribute.default_value(value),
      attribute.autocomplete("off"),
      attribute.class("input w-full border-base-content/60"),
    ]),
  )
}

/// 同じ囲みの複数行版。値は要素の内容で出す。
pub fn plugin_textarea_field(
  name: String,
  label: String,
  hint: Option(String),
  value: String,
) -> Element(msg) {
  plugin_field(
    label,
    hint,
    html.textarea(
      [
        attribute.name(name),
        attribute.rows(4),
        attribute.class("textarea w-full text-sm border-base-content/60"),
      ],
      value,
    ),
  )
}

/// プラグインのページの画像の見た目。プラグインが `image` ブロックの `variant` で選ぶ。
pub type ImageShape {
  /// `variant` が無いときの見た目。縦横とも実寸のまま高さ 192px と枠の幅の 2 つの
  /// 上限に収め、比の違う画像は切らずに余白を枠の中に入れる。
  ContainedImage
  /// `icon`。64px の正方形の丸に切り抜く（プロフィールのアイコン）。
  IconImage
  /// `banner`。枠の幅いっぱいの 3:1 の帯に切り抜き、高さは 192px までにする
  /// （プロフィールのバナー）。
  BannerImage
}

/// プラグインのページの画像 1 枚。プラグインは URL と代替文と見た目の種類（`shape`）だけを
/// 渡し、大きさもクラスも選べない。別のオリジンへ Referer を出さない。
pub fn plugin_image(
  url: String,
  alt: String,
  shape: ImageShape,
) -> Element(msg) {
  html.img([
    attribute.src(url),
    attribute.alt(alt),
    attribute.loading("lazy"),
    attribute.decoding("async"),
    attribute.referrerpolicy("no-referrer"),
    attribute.class(case shape {
      ContainedImage ->
        "block h-auto w-auto max-h-48 max-w-full rounded-lg border border-base-300 bg-base-200 object-contain"
      IconImage ->
        "block size-16 rounded-full border border-base-300 bg-base-200 object-cover"
      BannerImage ->
        "block aspect-3/1 w-full max-h-48 rounded-lg border border-base-300 bg-base-200 object-cover"
    }),
  ])
}

/// `http` / `https` 以外の URL の画像の代わりに出す破線の枠。理由は表示の言語に訳した文を
/// 受け取り、その言語の `lang` で出す。代替文はプラグイン由来の文字列なので `lang` を付けず、
/// 祖先（`plugin_view` の節の包み）の `lang` を引き継ぐ。
pub fn plugin_image_placeholder(
  language: Language,
  reason: String,
  alt: String,
) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "flex flex-col gap-1 rounded-lg border border-dashed border-base-300 bg-base-200 p-4 text-sm text-muted",
      ),
    ],
    [
      html.span([attribute.lang(i18n.code(language))], [html.text(reason)]),
      html.span([], [html.text(alt)]),
    ],
  )
}

/// 行が 1 件も無い節の本文。点線の枠の中に、アイコン、説明の文、操作のボタンを縦に積む。
/// `actions` が空なら、ボタンを置かない。
pub fn empty_state(
  icon: Element(msg),
  text: String,
  actions: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "flex flex-col items-start gap-3 rounded-box border border-dashed border-field bg-base-100/60 px-4 py-5 text-sm text-muted",
      ),
    ],
    [icon, html.p([], [html.text(text)]), ..actions],
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
        html.dt([attribute.class("text-muted")], [html.text(term)]),
        value,
      ]
    }),
  )
}

/// 見出しと値の組の一覧（`dl`）。見出しを値の左に置くので、狭い画面でも横に伸びない。
pub fn summary_list(entries: List(#(String, Value))) -> Element(msg) {
  detail_list(list.map(entries, fn(entry) { #(entry.0, value_cell(entry.1)) }))
}

/// `Value` 1 つを `dl` の値（`dd`）にする。`summary_list` と `admin/plugin_view` の
/// `pairs` が使う。
pub fn value_cell(value: Value) -> Element(msg) {
  case value {
    Code(text) ->
      html.dd([attribute.class("font-mono text-xs break-all")], [
        html.text(text),
      ])
    Plain(text) -> html.dd([attribute.class("break-words")], [html.text(text)])
  }
}

/// 省略した識別子を `dl` の値（`dd`）にする。値の列が潰れないよう `min-w-0` を付け、
/// `truncated_id` が出す訳文のために表示言語の `lang` を付ける。
pub fn identifier_cell(
  language: Language,
  value: String,
  copy_label: String,
) -> Element(msg) {
  html.dd([attribute.class("min-w-0"), attribute.lang(i18n.code(language))], [
    truncated_id(language, value, copy_label),
  ])
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

/// 指定した宛先へ POST で送るフォーム。欄を並べ、最後に送信のボタンを置く。
pub fn post_form(
  action: String,
  fields: List(Element(msg)),
  label: String,
  kind: ButtonKind,
  placement: Placement,
) -> Element(msg) {
  form_with([], action, fields, label, kind, placement)
}

/// 秘密を入力させるフォーム。フォームにも `autocomplete="off"` を付け、ブラウザーが
/// フォーム全体を資格情報として保存の対象にしないようにする。
pub fn secret_post_form(
  action: String,
  fields: List(Element(msg)),
  label: String,
  kind: ButtonKind,
  placement: Placement,
) -> Element(msg) {
  form_with(
    [attribute.autocomplete("off")],
    action,
    fields,
    label,
    kind,
    placement,
  )
}

/// `post_form` と `secret_post_form` が共有するフォームの組み立て。
fn form_with(
  attributes: List(Attribute(msg)),
  action: String,
  fields: List(Element(msg)),
  label: String,
  kind: ButtonKind,
  placement: Placement,
) -> Element(msg) {
  let submit =
    html.button(
      [
        attribute.type_("submit"),
        attribute.class(button_class(kind, placement)),
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
pub fn button_link(
  href: String,
  text: String,
  kind: ButtonKind,
) -> Element(msg) {
  html.a([attribute.href(href), attribute.class(button_class(kind, InRow))], [
    html.text(text),
  ])
}

/// ボタンの種類と置き場所の組ごとのクラス。行に置くものは小さく（`btn-sm`）、フォームの末尾に
/// 置くものは左に寄せる（`self-start`）。
fn button_class(kind: ButtonKind, placement: Placement) -> String {
  case placement, kind {
    InRow, PrimaryButton ->
      "btn btn-primary btn-sm focus-visible:outline-base-content"
    InRow, OutlineButton ->
      "btn btn-outline btn-sm focus-visible:outline-base-content"
    InRow, GhostButton ->
      "btn btn-ghost btn-sm focus-visible:outline-base-content"
    InRow, DangerButton ->
      "btn btn-error btn-sm focus-visible:outline-base-content"
    InRow, DangerGhostButton ->
      "btn btn-ghost btn-sm text-error focus-visible:outline-base-content"
    InRow, WarningOutlineButton ->
      "btn btn-outline btn-warning btn-sm focus-visible:outline-base-content"
    InForm, PrimaryButton ->
      "btn btn-primary self-start focus-visible:outline-base-content"
    InForm, OutlineButton ->
      "btn btn-outline self-start focus-visible:outline-base-content"
    InForm, GhostButton ->
      "btn btn-ghost self-start focus-visible:outline-base-content"
    InForm, DangerButton ->
      "btn btn-error self-start focus-visible:outline-base-content"
    InForm, DangerGhostButton ->
      "btn btn-ghost self-start text-error focus-visible:outline-base-content"
    InForm, WarningOutlineButton ->
      "btn btn-outline btn-warning self-start focus-visible:outline-base-content"
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

/// 欄の補足の出し方。どちらも補足の段落に呼び出し側が渡す `id` を付け、欄の
/// `aria-describedby` から指す。
pub type FieldHint {
  /// 欄の下に常に出す、短い 1 行の補足。
  LineHint(text: String)
  /// 見出しの横の ⓘ のボタンで開く補足。`popover` の段落なので、閉じていても欄の説明として
  /// 読まれ、JS 無しで開き、ホバーでは開かない。
  FoldedHint(text: String)
}

/// 見出し、入力欄、補足をまとめた囲み。入力欄に `aria-label` と、補足の `id` を指す
/// `aria-describedby` を付ける。`attributes` にクラスを含む入力欄の属性を渡す。`language` は
/// ⓘ のボタンの語を引く表示の言語である。
pub fn hinted_input(
  language: Language,
  caption: String,
  hint_id: String,
  hint: FieldHint,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  hinted_field(
    language,
    caption,
    hint_id,
    hint,
    html.input([
      attribute.aria_label(caption),
      attribute.aria_describedby(hint_id),
      ..attributes
    ]),
  )
}

/// 見出し、複数行の入力欄、補足をまとめた囲み。`hinted_input` と同じ構造で、欄だけ
/// `textarea` にする。値は `html.textarea` の内容で出す（`input` の `default_value` では
/// ない）。
pub fn hinted_textarea(
  language: Language,
  caption: String,
  hint_id: String,
  hint: FieldHint,
  value: String,
  attributes: List(Attribute(msg)),
) -> Element(msg) {
  hinted_field(
    language,
    caption,
    hint_id,
    hint,
    html.textarea(
      [
        attribute.aria_label(caption),
        attribute.aria_describedby(hint_id),
        ..attributes
      ],
      value,
    ),
  )
}

/// `hinted_input` と `hinted_textarea` が共有する囲み。`LineHint` は見出し、欄、補足の段落の順に
/// 並べる。`FoldedHint` は見出しの横に、補足を `popovertarget` で指す送信しない ⓘ のボタンを置き、
/// 欄の後に `popover="auto"` の補足の段落を置く。段落はボタンの上に重ねて開く。
fn hinted_field(
  language: Language,
  caption: String,
  hint_id: String,
  hint: FieldHint,
  control: Element(msg),
) -> Element(msg) {
  case hint {
    LineHint(text:) ->
      html.div([attribute.class("fieldset")], [
        html.span([attribute.class("fieldset-legend")], [html.text(caption)]),
        control,
        html.p([attribute.id(hint_id), attribute.class("text-muted")], [
          html.text(text),
        ]),
      ])
    FoldedHint(text:) -> {
      let label = i18n.text(language, i18n.ShowFieldHint)
      html.div([attribute.class("fieldset")], [
        html.div([attribute.class("fieldset-legend w-fit justify-start")], [
          html.text(caption),
          html.button(
            [
              attribute.type_("button"),
              attribute.popovertarget(hint_id),
              attribute.aria_label(label),
              attribute.title(label),
              attribute.class(
                "btn btn-ghost btn-xs btn-circle text-muted focus-visible:outline-base-content",
              ),
            ],
            [info_icon()],
          ),
        ]),
        control,
        html.p(
          [
            attribute.id(hint_id),
            attribute.popover("auto"),
            attribute.class(
              "inset-auto m-0 mb-1 max-w-80 rounded-box border border-base-300 bg-base-100 p-3 text-sm text-base-content shadow-lift [position-area:top_span-right] [position-try-fallbacks:flip-block,flip-inline]",
            ),
          ],
          [html.text(text)],
        ),
      ])
    }
  }
}

/// チェック 1 つぶんの大きな行。ページの地の色の角丸の行に、チェック、アイコン、語、説明、あれば
/// バッジを並べ、チェックとアイコンは縮めずに語の 1 行目に揃える。説明は `label` の中に置くので、
/// チェックの名前の一部として読まれる。
pub fn checkbox_row(
  name: String,
  icon: Element(msg),
  caption: String,
  description: Element(msg),
  checked: Bool,
  badge: List(Element(msg)),
) -> Element(msg) {
  html.label(
    [
      attribute.class(
        "flex cursor-pointer items-start gap-3 rounded-field bg-base-200 px-3 py-2.5 text-sm",
      ),
    ],
    [
      html.input([
        attribute.type_("checkbox"),
        attribute.name(name),
        attribute.value("on"),
        attribute.class(
          "checkbox checkbox-sm mt-0.5 shrink-0 border-base-content/60",
        ),
        attribute.checked(checked),
      ]),
      html.span([attribute.class("mt-0.5 shrink-0")], [icon]),
      html.div([attribute.class("flex min-w-0 flex-col")], [
        html.span([], [html.text(caption)]),
        html.span([attribute.class("text-sm text-muted")], [
          description,
        ]),
      ]),
      ..badge
    ],
  )
}

/// nsec や管理パスワードのように伏せて入力させる欄。属性は `secret_input_attributes` のとおり。
pub fn secret_input(name: String, autocomplete: String) -> Element(msg) {
  html.input(secret_input_attributes(name, autocomplete))
}

/// 伏せて入力させる欄の属性（伏せ字、必須、等幅）。`hinted_input` に渡すと補足を持つ伏せ字の
/// 欄になる。`autocomplete` は欄の自動入力の種類（nsec は `new-password`、再入力のパスワードは
/// `off`）。
pub fn secret_input_attributes(
  name: String,
  autocomplete: String,
) -> List(Attribute(msg)) {
  [
    attribute.type_("password"),
    attribute.name(name),
    attribute.autocomplete(autocomplete),
    attribute.required(True),
    attribute.class("input w-full font-mono border-base-content/60"),
  ]
}

/// フォームで送る隠しフィールド。
pub fn hidden_input(name: String, value: String) -> Element(msg) {
  html.input([
    attribute.type_("hidden"),
    attribute.name(name),
    attribute.default_value(value),
  ])
}

/// 見出しを付けた読み取り専用の欄と、その値をコピーする `copy_button`。欄に name を付けない（送信にも
/// 入力履歴にも含めないため）。ボタンは欄の直後の兄弟に、囲みはボタンの親の親に置き、完了と
/// クリップボードに書けないときの案内は囲みの直下の `copy_status` で伝える。
pub fn copyable_field(
  language: Language,
  caption: String,
  value: String,
) -> Element(msg) {
  html.div([attribute.class("fieldset group")], [
    html.span([attribute.class("fieldset-legend")], [html.text(caption)]),
    html.div([attribute.class("flex items-center gap-1")], [
      html.input([
        attribute.type_("text"),
        attribute.readonly(True),
        attribute.default_value(value),
        attribute.aria_label(caption),
        attribute.class(
          "input w-full min-w-0 font-mono text-xs border-base-content/60",
        ),
      ]),
      copy_button(i18n.text(language, i18n.Copy)),
    ]),
    copy_status(language),
  ])
}

/// コピーのボタン。語は `aria-label` と `title` に置き、アイコンだけを見せる。`data-action` で
/// `priv/static/admin.js` の `copy` の処理を指し、その処理が読む構造（欄はボタンの直前の兄弟、囲みは
/// ボタンの親の親）に置いて使う。コピーできると、囲みの `data-copied` でアイコンがチェックに替わり
/// success の色になる。
pub fn copy_button(label: String) -> Element(msg) {
  html.button(
    [
      attribute.type_("button"),
      attribute.data("action", "copy"),
      attribute.aria_label(label),
      attribute.title(label),
      attribute.class(
        "btn btn-ghost btn-sm btn-square text-muted group-data-copied:text-success focus-visible:outline-base-content",
      ),
    ],
    [
      html.span([attribute.class("grid")], [
        lucide_icon(
          "col-start-1 row-start-1 size-4 group-data-copied:invisible",
          copy_icon_paths,
        ),
        lucide_icon(
          "invisible col-start-1 row-start-1 size-4 group-data-copied:visible",
          copied_icon_paths,
        ),
      ]),
    ],
  )
}

/// コピーの囲みの直下に置く `role="status"` の案内。完了の語と、クリップボードに書けないときの手動の
/// コピーの案内を、囲みの `data-copied` と `data-selected` で出し分ける。
fn copy_status(language: Language) -> Element(msg) {
  html.span(
    [
      attribute.role("status"),
      attribute.class("sr-only group-data-selected:not-sr-only"),
    ],
    [
      html.span([attribute.class("hidden group-data-copied:inline")], [
        html.text(i18n.text(language, i18n.Copied)),
      ]),
      html.span([attribute.class("hidden group-data-selected:inline text-sm")], [
        html.text(i18n.text(language, i18n.SelectedPressCtrlC)),
      ]),
    ],
  )
}

/// 節の末尾に置く、読み込めなかった行の error の色の囲み（`alert alert-soft alert-error`）。`icon` と題（`h3`）と
/// `count` の件数のピルを 1 行に、`description` の 1 文をその下に、`rows` を行の一覧（`row_list`）で続ける。
pub fn failure_frame(
  icon: Element(msg),
  title: String,
  count: Int,
  description: String,
  rows: List(Element(msg)),
) -> Element(msg) {
  html.div(
    [
      attribute.class(
        "alert alert-soft alert-error flex flex-col items-stretch gap-3 text-base-content",
      ),
    ],
    [
      html.h3(
        [attribute.class("flex items-center gap-2 font-bold text-error")],
        [
          icon,
          html.text(title),
          count_badge(count),
        ],
      ),
      html.p([attribute.class("text-sm")], [html.text(description)]),
      row_list(rows),
    ],
  )
}

/// 通知や理由を、薄い塗りの囲みで出す。先頭にトーンのアイコンを置き、文字は本文色にする。読み飛ばされて
/// は困る注意（秘密鍵の表示、接続 QR コードの secret、secret が一致しない承認待ちのカードと承認ページ）も `Warning` で出す。
pub fn alert(tone: Tone, content: List(Element(msg))) -> Element(msg) {
  alert_box([], tone, content)
}

/// フォームの上に出す理由の囲み。`role="alert"` で伝え、先頭のトーンのアイコンと薄い塗りで
/// `tone` を伝える。
pub fn reason_alert(tone: Tone, content: List(Element(msg))) -> Element(msg) {
  alert_box([attribute.role("alert")], tone, content)
}

/// `alert` と `reason_alert` が共有する囲みの組み立て。先頭にトーンのアイコンを置き、中身を `span` に
/// 包む。`attributes` は囲みの要素に足す。
fn alert_box(
  attributes: List(Attribute(msg)),
  tone: Tone,
  content: List(Element(msg)),
) -> Element(msg) {
  html.div([attribute.class(alert_class(tone)), ..attributes], [
    tone_icon(tone),
    html.span([], content),
  ])
}

/// 全幅の帯。`primary` を 8% 混ぜた地と 28% 混ぜた枠の囲みに、見出しや一覧を縦に積む。`id` はページ内のリンク先である。
pub fn band(id: String, content: List(Element(msg))) -> Element(msg) {
  html.section(
    [
      attribute.id(id),
      attribute.class(
        "flex flex-col gap-4 rounded-box border border-primary/28 bg-primary/8 p-4 sm:p-6",
      ),
    ],
    content,
  )
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
  in_language("en", text)
}

/// `code` の言語で書かれた文字列を、その `lang` を持つ `span` で出す。
pub fn in_language(code: String, text: String) -> Element(msg) {
  html.span([attribute.lang(code)], [html.text(text)])
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
/// 付けた丸のチェック・三角・丸の×。`alert_box`（`alert` と `reason_alert`）と状態のチップが共有する。
pub fn tone_icon(tone: Tone) -> Element(msg) {
  case tone {
    Neutral -> lucide_icon("size-4", info_icon_paths)
    Success -> lucide_icon("size-4 text-success", check_circle_icon_paths)
    Warning -> lucide_icon("size-4 text-warning", warning_triangle_icon_paths)
    Failure -> lucide_icon("size-4 text-error", x_circle_icon_paths)
    Info -> lucide_icon("size-4 text-info", info_icon_paths)
  }
}

/// 通知のページの先頭に置く結果の印。トーンの色を薄く混ぜた丸い面に、状態の語彙のアイコンを載せる。`Success` は
/// success の色の circle-check（接続中と同じ）、`Warning` は warning の色の clock（応答なしと同じ）、`Failure` は
/// error の色の octagon-alert（読み込み失敗と同じ）、`Neutral` は色を付けない circle-minus（未使用と同じ）、`Info` は
/// info の色の info である。アイコンは飾りで、結果は見出しと理由の文で伝える。
pub fn notice_mark(tone: Tone) -> Element(msg) {
  let #(class, paths) = case tone {
    Success -> #(
      "grid size-10 shrink-0 place-items-center rounded-full bg-success/13 text-success",
      check_circle_icon_paths,
    )
    Warning -> #(
      "grid size-10 shrink-0 place-items-center rounded-full bg-warning/13 text-warning",
      clock_icon_paths,
    )
    Failure -> #(
      "grid size-10 shrink-0 place-items-center rounded-full bg-error/13 text-error",
      octagon_alert_icon_paths,
    )
    Neutral -> #(
      "grid size-10 shrink-0 place-items-center rounded-full bg-base-200 text-muted",
      circle_minus_icon_paths,
    )
    Info -> #(
      "grid size-10 shrink-0 place-items-center rounded-full bg-info/13 text-info",
      info_icon_paths,
    )
  }
  html.span([attribute.class(class)], [lucide_icon("size-5", paths)])
}

/// アイコン＋語の状態のチップ。色とアイコンは `chip` で決まり、色だけに頼らない。
pub fn status_chip(chip: Chip, text: String) -> Element(msg) {
  html.span([attribute.class(chip_class(chip))], [
    chip_icon(chip),
    html.text(text),
  ])
}

/// チップのクラス。未使用だけ点線の枠にし、ほかは状態をトーンに写して `tone_chip_class` を
/// 使う。
fn chip_class(chip: Chip) -> String {
  case chip {
    UnusedChip -> "badge badge-dash badge-sm whitespace-nowrap gap-1"
    _ -> tone_chip_class(chip_tone(chip))
  }
}

/// 状態のチップの色のトーン。未使用は色を付けないので `Neutral` にする。
fn chip_tone(chip: Chip) -> Tone {
  case chip {
    ActiveChip -> Success
    DisconnectedChip | UnansweredChip | OverloadedChip | SecretMismatchChip ->
      Warning
    DisabledChip | LoadFailedChip -> Failure
    UnusedChip | SecretNotOfferedChip -> Neutral
    ToneChip(tone) -> tone
  }
}

/// アイコン＋語の状態の注記。チップと同じアイコンを付け、語をチップと同じ色の文字で出す。
/// 塗りも枠も付けないので、面の中の短い補足に使う。
pub fn status_note(chip: Chip, text: String) -> Element(msg) {
  let class = case chip_tone(chip) {
    Neutral -> "inline-flex items-center gap-1"
    Success -> "inline-flex items-center gap-1 text-success"
    Warning -> "inline-flex items-center gap-1 text-warning"
    Failure -> "inline-flex items-center gap-1 text-error"
    Info -> "inline-flex items-center gap-1 text-info"
  }
  html.span([attribute.class(class)], [chip_icon(chip), html.text(text)])
}

/// トーンごとのチップのクラス。どれも薄い塗り（`badge-soft`）で、`Neutral` だけ色の修飾を
/// 付けない。
fn tone_chip_class(tone: Tone) -> String {
  case tone {
    Neutral -> "badge badge-soft badge-sm whitespace-nowrap gap-1"
    Success -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-success"
    Warning -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-warning"
    Failure -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-error"
    Info -> "badge badge-soft badge-sm whitespace-nowrap gap-1 badge-info"
  }
}

/// チップのアイコン。状態の変種は Lucide のストロークを文字色で描き、`ToneChip` は `tone_icon` を
/// 使う。
fn chip_icon(chip: Chip) -> Element(msg) {
  case chip {
    ToneChip(tone) -> tone_icon(tone)
    ActiveChip -> lucide_icon("size-4", check_circle_icon_paths)
    DisconnectedChip -> lucide_icon("size-4", unplug_icon_paths)
    UnansweredChip -> lucide_icon("size-4", clock_icon_paths)
    UnusedChip -> lucide_icon("size-4", circle_minus_icon_paths)
    OverloadedChip -> lucide_icon("size-4", gauge_icon_paths)
    DisabledChip -> lucide_icon("size-4", ban_icon_paths)
    LoadFailedChip -> lucide_icon("size-4", octagon_alert_icon_paths)
    SecretNotOfferedChip -> lucide_icon("size-4", shield_icon_paths)
    SecretMismatchChip -> lucide_icon("size-4", shield_alert_icon_paths)
  }
}

/// 折りたたみの中に出す整形済みのテキスト。長い 16 進と JSON を横スクロールなしで折り返す。
pub fn preformatted(text: String) -> Element(msg) {
  html.pre(
    [
      attribute.class(
        "font-mono text-xs whitespace-pre-wrap break-all rounded bg-base-200 p-2",
      ),
    ],
    [html.text(text)],
  )
}

/// 等幅の 1 行を並べる箇条書き。URL のように長く、行ごとに区切りたい値に使う。
pub fn code_list(values: List(String)) -> Element(msg) {
  html.ul(
    [attribute.class("list-disc pl-5 space-y-1")],
    list.map(values, fn(v) {
      html.li([attribute.class("font-mono text-xs break-all")], [
        html.text(v),
      ])
    }),
  )
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

/// Unix 秒の時刻。`datetime` 属性に RFC 3339 の UTC の全文を置き、本文には UTC の時分秒を
/// 「05:12:34 UTC」（日本語は「05:12:34（UTC）」）の形で出す。`priv/static/admin.js` が読み込み時に
/// 本文を閲覧者のローカルの時刻に直すので、「UTC」の表記が残るのは JS が動かないときだけである。
pub fn time_of_day(language: Language, seconds: Int) -> Element(msg) {
  let #(_, time) =
    timestamp.from_unix_seconds(seconds)
    |> timestamp.to_calendar(calendar.utc_offset)
  let clock =
    [time.hours, time.minutes, time.seconds]
    |> list.map(two_digits)
    |> string.join(":")
  html.time([attribute.datetime(utc_time(seconds))], [
    html.text(i18n.text(language, i18n.UtcTimeOfDay(clock))),
  ])
}

/// 秒数を「分:秒」（`8:12`、`0:45`）の残り時間にする。秒は 2 桁に 0 埋めし、負の値は 0 とみなす。
pub fn countdown(seconds: Int) -> String {
  let seconds = int.max(seconds, 0)
  int.to_string(seconds / 60) <> ":" <> two_digits(seconds % 60)
}

/// 0〜59 の数を 2 桁に 0 埋めする。
fn two_digits(value: Int) -> String {
  string.pad_start(int.to_string(value), 2, "0")
}

/// Unix 秒を RFC 3339 の UTC の文字列（`2026-09-13T05:12:34Z`）にする。
pub fn utc_time(seconds: Int) -> String {
  timestamp.from_unix_seconds(seconds)
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

/// 省略した識別子。`shorten` した表示（`title` に全文）、コピー用の読み取り専用の全文の `input`、
/// `copy_button` を並べ、`copy_status` の案内を添える。欄はボタンの直前の兄弟、囲みはボタンの親の親に置く。
pub fn truncated_id(
  language: Language,
  value: String,
  copy_label: String,
) -> Element(msg) {
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
      copy_button(copy_label),
    ]),
    copy_status(language),
  ])
}

/// ダイアログを開くボタンの見た目。
pub type DialogTrigger(msg) {
  /// アイコンと語のボタン（`icon_button_link` と同じ見た目）。節の見出しの操作、セッションの行の権限の編集、アカウントの行と読み込めなかった行の操作に使う。
  IconTextTrigger(icon: Element(msg), text: String)
  /// アイコンだけのボタン（`icon_only_link` と同じ見た目）。語は読み上げのための `aria-label` に置く。
  IconOnlyTrigger(icon: Element(msg), label: String)
  /// 語だけのボタン（`post_form` の `InRow` の送信ボタンと同じ見た目）。セッションの行の承認の取り消しに使う。
  TextTrigger(text: String)
}

/// ダイアログの `id`。`dialog-` に `parts` を `-` で繋ぐ。`parts` には節の語、行の DB の id か 16 進の pubkey、操作のセグメントのような決まった形の値だけを渡し、ラベルのような利用者の文字列を渡さない。
pub fn dialog_id(parts: List(String)) -> String {
  string.join(["dialog", ..parts], "-")
}

/// ダイアログを開くボタンと、そのダイアログの 2 要素。ボタンは `commandfor` で `id` のダイアログを指し、`command="show-modal"` で開く（`type="button"` で、何も送らない）。ダイアログは題（`id` に `-title` を付けた `id` の `h2`。ダイアログの `aria-labelledby` が指す）、`content`、「キャンセル」のボタンを縦に並べる。キャンセルは同じダイアログを `command="close"` で閉じるだけで、開いたときにフォーカスを受ける（`autofocus`）。Esc でも閉じる。
pub fn dialog_button(
  language: Language,
  id: String,
  trigger: DialogTrigger(msg),
  kind: ButtonKind,
  title: String,
  content: List(Element(msg)),
) -> List(Element(msg)) {
  let title_id = id <> "-title"
  let command = fn(name) {
    [
      attribute.type_("button"),
      attribute.attribute("commandfor", id),
      attribute.attribute("command", name),
    ]
  }
  let button = case trigger {
    IconTextTrigger(icon:, text:) ->
      html.button(
        [attribute.class(button_class(kind, InRow)), ..command("show-modal")],
        [icon, html.text(text)],
      )
    IconOnlyTrigger(icon:, label:) ->
      html.button(
        [
          attribute.aria_label(label),
          attribute.class(button_class(kind, InRow)),
          ..command("show-modal")
        ],
        [icon],
      )
    TextTrigger(text:) ->
      html.button(
        [attribute.class(button_class(kind, InRow)), ..command("show-modal")],
        [html.text(text)],
      )
  }
  let dialog =
    html.dialog(
      [
        attribute.id(id),
        attribute.class("modal"),
        attribute.aria_labelledby(title_id),
      ],
      [
        html.div([attribute.class("modal-box flex flex-col gap-4")], [
          html.h2([attribute.id(title_id), attribute.class("card-title")], [
            html.text(title),
          ]),
          ..list.append(content, [
            html.button(
              [
                attribute.autofocus(True),
                attribute.class(button_class(GhostButton, InForm)),
                ..command("close")
              ],
              [html.text(i18n.text(language, i18n.Cancel))],
            ),
          ])
        ]),
      ],
    )
  [button, dialog]
}

/// ダイアログを開けないブラウザー（`commandfor` に対応しないもの）のための、今の操作のページへのリンク。ダイアログのボタンの並びごとに 1 つ、並びの末尾か、並びの幅を保つときはその下の行に置く。
pub fn fallback_link(language: Language, href: String) -> Element(msg) {
  html.a(
    [
      attribute.href(href),
      attribute.class("link link-hover self-center text-xs text-muted"),
    ],
    [html.text(i18n.text(language, i18n.OpenAsPage))],
  )
}

/// アイコン＋語のボタンのリンク。ダッシュボードの節の主操作、「はじめに」の帯の段の追加の操作、空の節の操作と、アカウントの操作のページの下のほかの操作へのリンクに使う。
pub fn icon_button_link(
  href: String,
  icon: Element(msg),
  text: String,
  kind: ButtonKind,
) -> Element(msg) {
  html.a([attribute.href(href), attribute.class(button_class(kind, InRow))], [
    icon,
    html.text(text),
  ])
}

/// アイコン＋語のボタンのリンクで、狭い画面（640px 未満）では語を隠してアイコンだけにする。語は `title` にも置き、隠した後も読み上げとマウスを重ねたときの表示に残す。
pub fn compact_icon_button_link(
  href: String,
  icon: Element(msg),
  text: String,
  kind: ButtonKind,
) -> Element(msg) {
  html.a(
    [
      attribute.href(href),
      attribute.title(text),
      attribute.class(button_class(kind, InRow)),
    ],
    [icon, html.span([attribute.class("max-sm:sr-only")], [html.text(text)])],
  )
}

/// アイコンだけのボタンのリンク。語は読み上げのための `aria-label` に置く。
pub fn icon_only_link(
  href: String,
  icon: Element(msg),
  label: String,
  kind: ButtonKind,
) -> Element(msg) {
  html.a(
    [
      attribute.href(href),
      attribute.aria_label(label),
      attribute.class(button_class(kind, InRow)),
    ],
    [icon],
  )
}

/// ロゴの SVG の `viewBox`。板の外接の正方形で、図形の枠（`177 86 900 900`）が板の直径の 85% に
/// なるよう、同じ中心（627, 536）で広げたもの。
const logo_view_box = "97.5882 6.5882 1058.8235 1058.8235"

/// ビーバーの体の輪郭。目と歯を副パスに持ち、`fill-rule="evenodd"` で穴にする。
const logo_body_path = "M 513.0000 164.5029 A 402 402 0 0 0 275.4029 744.8935  C 297.2193 784.2514 445 774 552 716  C 619 680 659 629 680 569  C 709 498 762 453 816 430  C 827 432 839 431 847 425  C 867 429 883 414 883 395  L 883 342  C 911 319 921 280 872 262  C 818 175 733 145 620 162  C 614 138 592 120 566 120  C 535 120 510 140 513.0000 164.5029 Z M 762 266 A 24 24 0 1 0 714 266 A 24 24 0 1 0 762 266 Z M 818 354 Q 813 354 813 360 L 813 414 Q 813 422 827 422 Q 841 422 841 414 L 841 351 Z M 850 350 L 875 346 L 875 395 Q 875 416 858 418 L 850 418 Z"

/// ビーバーの尻尾。
const logo_tail_path = "M 293.7269 774.7955 A 402 402 0 0 0 1028.4491 571.0391  C 1034 499 985 454 908 454  C 826 454 747 506 713 586  C 684 664 632 717 562 750  C 471 794 366 805 293.7269 774.7955 Z"

/// 目と歯。白く塗り、`logo_body_path` の穴に重ねる。
const logo_face_path = "M 762 266 A 24 24 0 1 0 714 266 A 24 24 0 1 0 762 266 Z M 818 354 Q 813 354 813 360 L 813 414 Q 813 422 827 422 Q 841 422 841 414 L 841 351 Z M 850 350 L 875 346 L 875 395 Q 875 416 858 418 L 850 418 Z"

/// 上部のロゴ。図形（`logo_icon`）の右に、製品名の字形（`wordmark_svg`）、読み上げ用の製品名、
/// 表示の言語の副題（`LogoSubtitle`）を縦に並べ、全体をダッシュボード（`/`）への 1 つのリンクに
/// する。リンクは「Nostr-no-Su」と副題の順に読み上げられる。
fn brand_link(language: Language) -> Element(msg) {
  html.a(
    [
      attribute.href("/"),
      attribute.class(
        "flex items-center gap-3 rounded-box focus-visible:outline-2 focus-visible:outline-solid focus-visible:outline-offset-2 focus-visible:outline-base-content",
      ),
    ],
    [
      logo_icon(),
      html.span([attribute.class("grid gap-1")], [
        wordmark_svg(),
        html.span([attribute.class("sr-only")], [html.text("Nostr-no-Su")]),
        html.span([attribute.class("text-xs tracking-widest text-muted")], [
          html.text(i18n.text(language, i18n.LogoSubtitle)),
        ]),
      ]),
    ],
  )
}

/// 製品名「Nostr-no-Su」の字形の飾り。`admin/wordmark` のパスを、「Nostr」と「Su」は文字の色
/// （`fill-base-content`）、「-no-」は primary（`fill-primary`）で塗るので、テーマに従う。高さは
/// `h-4` で、幅は `viewBox` の比で決まる。読み上げない（`brand_link` が同じ語を `sr-only` の
/// 文字で出す）。
fn wordmark_svg() -> Element(msg) {
  svg.svg(
    [
      attribute.aria_hidden(True),
      attribute.attribute("viewBox", wordmark.view_box),
      attribute.class("h-4 w-auto"),
    ],
    [
      svg.path([
        attribute.attribute("d", wordmark.heavy_path),
        attribute.class("fill-base-content"),
      ]),
      svg.path([
        attribute.attribute("d", wordmark.medium_path),
        attribute.class("fill-primary"),
      ]),
    ],
  )
}

/// 上部バーのロゴ。favicon と同じ板つきのロゴ（`logo_svg`）を `data:` の URI の画像にして、
/// 板の直径 46px で出す。隣に製品名の文字があるので、代替文を空にして読み上げない。
pub fn logo_icon() -> Element(msg) {
  html.img([
    attribute.src(logo_data_uri()),
    attribute.alt(""),
    attribute.class("size-11.5"),
  ])
}

/// テーマの切り替えのブラウザーの設定のアイコン（Lucide の monitor）。
fn monitor_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M4 3h16a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2",
    "M8 21h8", "M12 17v4",
  ])
}

/// テーマの切り替えのライトのアイコン（Lucide の sun）。
fn sun_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0", "M12 2v2", "M12 20v2",
    "m4.93 4.93 1.41 1.41", "m17.66 17.66 1.41 1.41", "M2 12h2", "M20 12h2",
    "m6.34 17.66-1.41 1.41", "m19.07 4.93-1.41 1.41",
  ])
}

/// テーマの切り替えのダークのアイコン（Lucide の moon）。
fn moon_icon() -> Element(msg) {
  lucide_icon("size-4", ["M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"])
}

/// 言語の切り替えのブラウザーの設定のアイコン（Lucide の globe）。
fn globe_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0",
    "M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20", "M2 12h20",
  ])
}

/// QR のページへのリンクのアイコン（Lucide の qr-code）。
pub fn qr_code_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M4 3h3a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1",
    "M17 3h3a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H17a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1",
    "M4 16h3a1 1 0 0 1 1 1v3a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V17a1 1 0 0 1 1-1",
    "M21 16h-3a2 2 0 0 0-2 2v3", "M21 21v.01", "M12 7v3a2 2 0 0 1-2 2H7",
    "M3 12h.01", "M12 3h.01", "M12 16v.01", "M16 12h1", "M21 12v.01",
    "M12 21v-1",
  ])
}

/// `info_icon` のストローク（Lucide の info）。
const info_icon_paths = [
  "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "M12 16v-4", "M12 8h.01",
]

/// `back_link` の左向きの矢印（Lucide の arrow-left）。
const arrow_left_icon_paths = ["m12 19-7-7 7-7", "M19 12H5"]

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

/// `DisconnectedChip` のストローク（Lucide の unplug）。
const unplug_icon_paths = [
  "m19 5 3-3", "m2 22 3-3",
  "M6.3 20.3a2.4 2.4 0 0 0 3.4 0L12 18l-6-6-2.3 2.3a2.4 2.4 0 0 0 0 3.4Z",
  "M7.5 13.5 10 11", "M10.5 16.5 13 14",
  "m12 6 6 6 2.3-2.3a2.4 2.4 0 0 0 0-3.4l-2.6-2.6a2.4 2.4 0 0 0-3.4 0Z",
]

/// `UnusedChip` と通知のページの `Neutral` の印のストローク（Lucide の circle-minus）。
const circle_minus_icon_paths = [
  "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "M8 12h8",
]

/// `OverloadedChip` のストローク（Lucide の gauge）。
const gauge_icon_paths = ["m12 14 4-4", "M3.34 19a10 10 0 1 1 17.32 0"]

/// `DisabledChip` のストローク（Lucide の ban）。
const ban_icon_paths = [
  "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "M4.929 4.929 19.07 19.071",
]

/// `LoadFailedChip` と通知のページの `Failure` の印のストローク（Lucide の octagon-alert）。
const octagon_alert_icon_paths = [
  "M12 16h.01", "M12 8v4",
  "M15.312 2a2 2 0 0 1 1.414.586l4.688 4.688A2 2 0 0 1 22 8.688v6.624a2 2 0 0 1-.586 1.414l-4.688 4.688a2 2 0 0 1-1.414.586H8.688a2 2 0 0 1-1.414-.586l-4.688-4.688A2 2 0 0 1 2 15.312V8.688a2 2 0 0 1 .586-1.414l4.688-4.688A2 2 0 0 1 8.688 2z",
]

/// `SecretNotOfferedChip` のストローク（Lucide の shield）。
const shield_icon_paths = [
  "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z",
]

/// `SecretMismatchChip` のストローク（Lucide の shield-alert）。
const shield_alert_icon_paths = [
  "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z",
  "M12 8v4", "M12 16h.01",
]

/// 情報のアイコン（Lucide の info）。欄の補足を開く ⓘ のボタンに使う。
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

/// コピーのアイコンのストローク（Lucide の copy）。
const copy_icon_paths = [
  "M8 8h11a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V10a2 2 0 0 1 2-2z",
  "M4 16a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v2",
]

/// コピーの完了と、「はじめに」の帯の済んだ段の印（`check_icon`）のアイコンのストローク（Lucide の check）。
const copied_icon_paths = ["M20 6 9 17l-5-5"]

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

/// `clock_icon` のストローク（Lucide の clock）。
const clock_icon_paths = [
  "M2 12a10 10 0 1 0 20 0a10 10 0 1 0 -20 0", "M12 6v6l4 2",
]

/// セッションの節と、承認待ちの帯の更新の間隔のアイコン（Lucide の clock）。
pub fn clock_icon() -> Element(msg) {
  lucide_icon("size-4", clock_icon_paths)
}

/// 承認待ちの接続の節のアイコン（Lucide の door-open）。
pub fn door_open_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M13 4h3a2 2 0 0 1 2 2v14", "M2 20h3", "M13 20h9", "M10 12v.01",
    "M13 4.562v16.157a1 1 0 0 1-1.242.97L5 20V5.562a2 2 0 0 1 1.515-1.94l4-1A2 2 0 0 1 13 4.561Z",
  ])
}

/// 「はじめに」の帯の見出しのアイコン（Lucide の sparkle）。
pub fn sparkle_icon() -> Element(msg) {
  lucide_icon("size-4", [
    "M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z",
  ])
}

/// 済んだ段の印のアイコン（Lucide の check）。
pub fn check_icon() -> Element(msg) {
  lucide_icon("size-4", copied_icon_paths)
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

/// ダッシュボードへ戻るリンクの段落。左向きの矢印と語を地味なボタンの見た目で出し、ボタンの内側の
/// 余白のぶん左へずらして矢印を本文の左端に揃える。
pub fn back_link(language: Language) -> Element(msg) {
  html.p([], [
    html.a(
      [
        attribute.href("/"),
        attribute.class(
          "btn btn-ghost btn-sm -ml-3 focus-visible:outline-base-content",
        ),
      ],
      [
        lucide_icon("size-4", arrow_left_icon_paths),
        html.text(i18n.text(language, i18n.BackToDashboard)),
      ],
    ),
  ])
}
