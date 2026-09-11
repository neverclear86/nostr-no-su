//// 管理 UI のページ枠と、本体の他のモジュールに依存しない HTML の部品。lustre の
//// 要素ツリーで組み立てるが、lustre の component（`lustre/component`）や server
//// components は使わない。部品は `Element` を返し、HTML 文書の文字列にするのは
//// `page` だけである。
////
//// 値はテキストか属性値として lustre に渡し、HTML のエスケープは lustre の文字列化に
//// 任せる。エスケープでは防げない経路には決まった値だけを渡す。`html.style`、
//// `html.script`、`element.unsafe_raw_html` は使わない。イベント属性には定数の
//// `copy_script` だけを渡す。`href` と `action` には、`admin/dashboard` のパスの関数が
//// `/` から組み立てた値か、`"/"` か、`stylesheet_segments` から組み立てた値だけを渡す
//// （lustre は URL を検査しない）。
////
//// 入力欄の値は `attribute.default_value` で出す。サーバー側で初期値を出すだけで、
//// `attribute.value("")` は値の無い `value` 属性になるためである。
////
//// 見た目は Tailwind CSS と daisyUI のクラスで付け、ビルドした `priv/static/admin.css`
//// を読ませる。Tailwind は `admin/` の `.gleam` の文字列からクラス名を拾うので、クラス名は
//// 文字列の連結で組み立てず、状態ごとに違うものは `case` で完全な文字列を列挙する。
//// 80 桁を超えても、クラス名の文字列は分けない。フォーカスできる `btn` の文字列には
//// `focus-visible:outline-base-content`、`input` の文字列には `border-base-content/60` を
//// 付ける（デザイン方針 6 節。`stylesheet_test` が検査する）。

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html

/// ビルドした管理 UI のスタイルシートの URL のパスセグメント。ルーティング（`admin`）と
/// ページ枠の `link` が同じ定義を見る。配信する `wisp.serve_static` はこの定数ではなく要求の
/// パスから `priv` の下のファイルを引くので、このセグメントは `priv` の中の配置
/// （`priv/static/admin.css`）、`package.json` の `build:css` の出力先、`stylesheet_test` が
/// 読むパスと一致させる。
pub const stylesheet_segments = ["static", "admin.css"]

/// コピーのボタンの処理。直前の兄弟要素の入力欄を選択してクリップボードへ書き、書けたとき
/// だけコピーの欄の囲み（ボタンの親の親）に `data-copied` を 2 秒付ける。値はスクリプトに
/// 埋め込まず DOM から読むので、値によらず同じ文字列になる。
const copy_script = "const f=this.previousElementSibling,w=this.parentElement.parentElement;f.select();if(navigator.clipboard)navigator.clipboard.writeText(f.value).then(()=>{w.dataset.copied=1;clearTimeout(w.copiedTimer);w.copiedTimer=setTimeout(()=>{delete w.dataset.copied},2000)})"

/// ページの本文の幅。
pub type Layout {
  /// 節を 2 列に並べるダッシュボード。
  Wide
  /// フォームと説明を 1 列で読む、ダッシュボード以外のページ。
  Narrow
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
  /// 良し悪しを伝えない結果（接続の拒否）と、正常な構成でもありうる理由（アカウントの
  /// 一覧を得られない）。
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
}

/// 管理 UI 共通のページ枠を HTML 文書の文字列にする。ナビゲーションバーと、`title` を
/// 見出し（h1）にした本文を出す。
pub fn page(title: String, layout: Layout, body: List(Element(msg))) -> String {
  html.html([attribute.lang("en")], [
    html.head([], [
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width,initial-scale=1"),
      ]),
      html.title([], "nostr-no-su — " <> title),
      html.link([
        attribute.rel("stylesheet"),
        attribute.href("/" <> string.join(stylesheet_segments, "/")),
      ]),
    ]),
    html.body([attribute.class("min-h-screen bg-base-200 text-base-content")], [
      navbar(),
      html.main([attribute.class(main_class(layout))], [
        html.h1([attribute.class("text-2xl font-bold")], [html.text(title)]),
        ..body
      ]),
    ]),
  ])
  |> element.to_document_string
}

/// 全ページ共通のナビゲーションバー。サイト名はダッシュボードへのリンクにする。右端
/// （`navbar-end`）は言語の切り替え（#50）の置き場所で、今は空にしておく。
fn navbar() -> Element(msg) {
  html.header(
    [
      attribute.class(
        "navbar gap-2 border-b border-base-300 bg-base-100 px-4 sm:px-6",
      ),
    ],
    [
      html.div([attribute.class("navbar-start")], [
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
      html.div([attribute.class("navbar-end")], []),
    ],
  )
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
          list.map(headers, fn(header) { html.th([], [html.text(header)]) }),
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
      ..form_layout(placement)
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

/// nsec や管理パスワードのように伏せて入力させる欄。
pub fn secret_input(name: String) -> Element(msg) {
  html.input([
    attribute.type_("password"),
    attribute.name(name),
    attribute.autocomplete("off"),
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

/// 見出しを付けた読み取り専用の欄と、その値をコピーするボタン。値はスクリプトに埋め込まず、
/// ボタンが DOM から読む。欄に name を付けない（送信にも入力履歴にも含めないため）。
/// `copy_script` が囲みをボタンの親の親として読むので、囲みを 1 つの要素として返す。
/// ボタンの名前は常に Copy のままにし、完了は囲みの直下の `role="status"` で伝える。
pub fn copyable_field(caption: String, value: String) -> Element(msg) {
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
          attribute.attribute("onclick", copy_script),
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
              [html.text("Copy")],
            ),
            html.span(
              [
                attribute.aria_hidden(True),
                attribute.class(
                  "invisible col-start-1 row-start-1 group-data-copied:visible",
                ),
              ],
              [html.text("Copied")],
            ),
          ]),
        ],
      ),
    ]),
    html.span([attribute.role("status"), attribute.class("sr-only")], [
      html.span([attribute.class("hidden group-data-copied:inline")], [
        html.text("Copied"),
      ]),
    ]),
  ])
}

/// 通知や理由を、トーンの色の囲みで出す。
pub fn alert(tone: Tone, message: String) -> Element(msg) {
  html.div([attribute.class(alert_class(tone))], [
    html.span([], [html.text(message)]),
  ])
}

/// フォームの上に出す失敗の理由。無ければ何も出さない。
pub fn error_message(error: Option(String)) -> Element(msg) {
  case error {
    None -> element.none()
    Some(reason) ->
      html.div(
        [attribute.role("alert"), attribute.class(alert_class(Failure))],
        [html.span([], [html.text(reason)])],
      )
  }
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
pub fn back_link() -> Element(msg) {
  html.p([], [
    html.a([attribute.href("/"), attribute.class("link")], [
      html.text("Back to dashboard"),
    ]),
  ])
}
