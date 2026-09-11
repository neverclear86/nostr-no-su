//// 管理 UI のページ枠と、本体の他のモジュールに依存しない HTML の部品。lustre の
//// 要素ツリーで組み立てるが、lustre の component（`lustre/component`）や server
//// components は使わない。部品は `Element` を返し、HTML 文書の文字列にするのは
//// `page` だけである。
////
//// 値はテキストか属性値として lustre に渡し、HTML のエスケープは lustre の文字列化に
//// 任せる。エスケープでは防げない経路には決まった値だけを渡す。`html.style` には
//// 定数の `style` だけを渡し、`html.script` と `element.unsafe_raw_html` は使わない。
//// イベント属性には定数の `copy_script` だけを渡す。`href` と `action` には、
//// `admin/dashboard` のパスの関数が `/` から組み立てた値か `"/"` だけを渡す（lustre は
//// URL を検査しない）。
////
//// 入力欄の値は `attribute.default_value` で出す。サーバー側で初期値を出すだけで、
//// `attribute.value("")` は値の無い `value` 属性になるためである。

import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html

/// ページ全体のスタイル。外部ファイルを読ませないよう最小限を埋め込む。
const style = "body{font-family:system-ui,sans-serif;margin:2rem auto;max-width:64rem;padding:0 1rem;line-height:1.5}
h1{font-size:1.4rem}
h2{font-size:1.1rem;margin-top:2rem}
h3{font-size:1rem;margin-top:1.5rem}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ccc;padding:.4rem .6rem;text-align:left;font-size:.9rem;vertical-align:top}
th{background:#f4f4f4}
code{word-break:break-all;font-size:.85rem}
[role=alert]{color:#a00}"

/// コピーのボタンの処理。直前の入力欄を選択し、クリップボードへ書く。値はスクリプトに
/// 埋め込まず DOM から読むので、値によらず同じ文字列になる。
const copy_script = "const f=this.previousElementSibling;f.select();if(navigator.clipboard)navigator.clipboard.writeText(f.value)"

/// 表のセル 1 つの中身。
pub type Cell(msg) =
  List(Element(msg))

/// 管理 UI 共通のページ枠を HTML 文書の文字列にする。
pub fn page(title: String, body: List(Element(msg))) -> String {
  html.html([attribute.lang("en")], [
    html.head([], [
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width,initial-scale=1"),
      ]),
      html.title([], "nostr-no-su — " <> title),
      html.style([], style),
    ]),
    html.body([], [html.h1([], [html.text("nostr-no-su")]), ..body]),
  ])
  |> element.to_document_string
}

/// 節やページの見出し（h2）。
pub fn heading(title: String) -> Element(msg) {
  html.h2([], [html.text(title)])
}

/// 見出し行付きの表。
pub fn table(
  headers: List(String),
  rows: List(List(Cell(msg))),
) -> Element(msg) {
  html.table([], [
    html.thead([], [
      html.tr(
        [],
        list.map(headers, fn(header) { html.th([], [html.text(header)]) }),
      ),
    ]),
    html.tbody(
      [],
      list.map(rows, fn(cells) { html.tr([], list.map(cells, html.td([], _))) }),
    ),
  ])
}

/// 指定した宛先へ POST で送るフォーム。欄を並べ、最後に送信のボタンを置く。
pub fn post_form(
  action: String,
  fields: List(Element(msg)),
  label: String,
) -> Element(msg) {
  html.form(
    [attribute.method("post"), attribute.action(action)],
    list.append(fields, [
      html.button([attribute.type_("submit")], [html.text(label)]),
    ]),
  )
}

/// 見出しを付けた入力欄の段落。
pub fn labelled(caption: String, input: List(Element(msg))) -> Element(msg) {
  html.p([], [html.label([], [html.text(caption), html.br([]), ..input])])
}

/// nsec や管理パスワードのように伏せて入力させる欄。
pub fn secret_input(name: String) -> Element(msg) {
  html.input([
    attribute.type_("password"),
    attribute.name(name),
    attribute.autocomplete("off"),
    attribute.required(True),
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

/// 読み取り専用の入力欄と、その値をコピーするボタン。値はスクリプトに埋め込まず、
/// ボタンが直前の兄弟要素の欄から読むので、欄とボタンを並んだ 2 要素で返す。欄に
/// name を付けない（送信にも入力履歴にも含めないため）。
pub fn copyable_field(value: String) -> List(Element(msg)) {
  [
    html.input([
      attribute.type_("text"),
      attribute.readonly(True),
      attribute.size("64"),
      attribute.default_value(value),
    ]),
    html.button(
      [attribute.type_("button"), attribute.attribute("onclick", copy_script)],
      [html.text("Copy")],
    ),
  ]
}

/// フォームの上に出す失敗の理由。無ければ何も出さない。
pub fn error_message(error: Option(String)) -> Element(msg) {
  case error {
    None -> element.none()
    Some(reason) -> html.p([attribute.role("alert")], [html.text(reason)])
  }
}

/// ダッシュボードへ戻るリンクの段落。
pub fn back_link() -> Element(msg) {
  html.p([], [link("/", "Back to dashboard")])
}

/// リンク 1 つ。
pub fn link(href: String, text: String) -> Element(msg) {
  html.a([attribute.href(href)], [html.text(text)])
}

/// 鍵や URI のように等幅で見せたい値。
pub fn code(value: String) -> Element(msg) {
  html.code([], [html.text(value)])
}
