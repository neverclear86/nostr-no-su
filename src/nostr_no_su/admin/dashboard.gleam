//// 管理 UI のダッシュボード、承認ページ、通知ページの描画と、表示する状態の型、パスと
//// フォームの欄の名前の定義。描画は状態のスナップショット（純粋なデータ）から HTML
//// 文字列を組み立てるだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値はすべてユーザー由来になりうる（リレー URL、クライアント pubkey、
//// アカウントのラベル、表示する理由）ため、テキストか属性値として lustre に渡し、
//// エスケープを文字列化に任せる（`admin/view` の規則に従う）。
////
//// パスとフォームの欄の名前は、ルーティング（`admin`）とフォーム（ここと
//// `admin/account_pages`）が同じ定義を見るようここにだけ置く。

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/view
import nostr_no_su/bunker/engine.{type Session}
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection.{type Status, Connected, Disconnected}

/// リレーの用途。同じ URL を監視とバンカーの両方に使う構成があるため、行を
/// 区別できるようにする。
pub type Role {
  MonitorRelay
  BunkerRelay
}

/// リレー接続 1 本の表示内容。接続の仕様を表す `app.Relay` とは別物なので、
/// 表の行であることを名前に出す。
pub type RelayRow {
  RelayRow(role: Role, url: String, status: Status)
}

/// アカウント 1 件の表示内容。`uri` は secret を含むため、認証済みページ以外に
/// 出してはならない。`auth_uri` は secret を持たない URI で、これで接続した
/// クライアントは管理 UI での承認を経てから署名を委任できる。`npub` は画面で
/// アカウントを識別するための表記。
pub type AccountRow {
  AccountRow(
    signer: String,
    npub: String,
    label: String,
    uri: String,
    auth_uri: String,
  )
}

/// プラグイン 1 つの表示内容。`status` が `None` なのは、ランナーが再起動中か、
/// 遅いプラグインの実行中で問い合わせに応答しなかったことを意味する。
pub type PluginRow {
  PluginRow(name: String, status: Option(plugin_runner.Status))
}

/// 承認待ちの接続要求 1 件の表示内容。`age_seconds` は描画時点での経過秒。
pub type PendingRow {
  PendingRow(token: String, signer: String, client: String, age_seconds: Int)
}

/// ダッシュボードが表示する状態の一式。
pub type Snapshot {
  Snapshot(
    /// アカウントの一覧。得られないとき（バンカーが無効、読み込み中、応答なし）は
    /// 表示する理由。
    accounts: Result(List(AccountRow), String),
    pending: List(PendingRow),
    relays: List(RelayRow),
    sessions: List(Session),
    plugins: List(PluginRow),
  )
}

/// アカウント 1 件に対する操作。
pub type AccountAction {
  EditLabel
  RotateSecret
  DeleteAccount
  RevealPrivateKey
}

/// 操作の一覧。ダッシュボードのリンクはこの順（重さの軽い順）に並べ、セグメントとの
/// 対応もここから引く。
const account_actions = [
  EditLabel,
  RevealPrivateKey,
  RotateSecret,
  DeleteAccount,
]

/// アカウントのページのパスの先頭のセグメント。
const accounts_segment = "accounts"

/// アカウントの登録画面のパスセグメント。
pub const new_account_segments = [accounts_segment, "new"]

/// 鍵の生成の POST 先のパスセグメント。
pub const generate_account_segments = [accounts_segment, "generate"]

/// nsec による登録の POST 先のパスセグメント。
pub const import_account_segments = [accounts_segment, "import"]

/// 生成した鍵の登録の POST 先のパスセグメント。
pub const register_generated_segments = [accounts_segment, "register-generated"]

/// セッション取り消しの POST 先のパスセグメント。
pub const revoke_segments = ["sessions", "revoke"]

/// 登録のフォームで nsec を送る欄の名前。
pub const nsec_field = "nsec"

/// ラベルを送る欄の名前。
pub const label_field = "label"

/// 秘密鍵の再表示で管理パスワードを送る欄の名前。
pub const password_field = "password"

/// ラベルの符号位置の最大数。UTF-8 では 400 バイト以下になる。
pub const max_label_code_points = 100

/// スナップショットをダッシュボードのページに描画する。広い画面では、判断を待つ承認待ちと
/// アカウントとセッションを左の列に、リレーとプラグインの状態を右の列に置く。狭い画面では
/// この順に 1 列に並ぶ。
pub fn render(snapshot: Snapshot) -> String {
  view.page("Dashboard", view.Wide, [
    html.div([attribute.class("grid items-start gap-6 xl:grid-cols-5")], [
      html.div([attribute.class("flex min-w-0 flex-col gap-6 xl:col-span-3")], [
        pending_section(snapshot.pending),
        accounts_section(snapshot.accounts),
        sessions_section(snapshot.sessions),
      ]),
      html.div([attribute.class("flex min-w-0 flex-col gap-6 xl:col-span-2")], [
        relays_section(snapshot.relays),
        plugins_section(snapshot.plugins),
      ]),
    ]),
  ])
}

/// アカウントと、その `bunker://` 接続 URI（secret 入りと、承認を経るもの）と操作。
/// 一覧を得られないときは、一覧の代わりにその理由を出し、登録のリンクも出さない。
fn accounts_section(
  accounts: Result(List(AccountRow), String),
) -> Element(msg) {
  let #(add_link, body) = case accounts {
    Ok(rows) -> #(
      view.button_link(
        segments_path(new_account_segments),
        "Add account",
        view.Primary,
      ),
      section_body(rows, "No accounts registered.", fn(rows) {
        item_list(list.map(rows, account_item))
      }),
    )
    Error(reason) -> #(element.none(), view.alert(view.Neutral, reason))
  }
  view.card([
    html.div(
      [attribute.class("flex flex-wrap items-center justify-between gap-2")],
      [view.heading("Accounts"), add_link],
    ),
    body,
  ])
}

/// アカウント 1 件。識別、2 つの接続 URI、操作のリンクを縦に並べる。
fn account_item(account: AccountRow) -> Element(msg) {
  html.li([attribute.class("flex flex-col gap-3 py-4 first:pt-0 last:pb-0")], [
    account_identity(account),
    view.copyable_field("Connection URI", account.uri),
    view.copyable_field("Connection URI (approval)", account.auth_uri),
    account_action_links(account.signer),
  ])
}

/// アカウントを識別する、ラベル、npub、16 進の公開鍵。
fn account_identity(account: AccountRow) -> Element(msg) {
  html.div([attribute.class("flex min-w-0 flex-col gap-1")], [
    html.p([attribute.class("font-semibold break-words")], [
      html.text(account.label),
    ]),
    html.p([attribute.class("font-mono text-xs break-all")], [
      html.text(account.npub),
    ]),
    html.p(
      [attribute.class("font-mono text-xs break-all text-base-content/70")],
      [
        html.text(account.signer),
      ],
    ),
  ])
}

/// アカウント 1 件への操作のページへのリンク。
fn account_action_links(signer: String) -> Element(msg) {
  html.div(
    [attribute.class("flex flex-wrap gap-2")],
    list.map(account_actions, fn(action) {
      view.button_link(
        account_action_path(signer, action),
        account_action_title(action),
        account_action_link_weight(action),
      )
    }),
  )
}

/// 操作のページへのリンクの重さ。行き先の操作の重さを付けるが、秘密鍵の表示は開くだけでは
/// 何も起きず（管理パスワードの再入力が要る）、色付きのボタンが並ぶと削除の色が埋もれるので
/// 通常にする。
fn account_action_link_weight(action: AccountAction) -> view.Weight {
  case action {
    EditLabel | RevealPrivateKey -> view.Normal
    RotateSecret -> view.Caution
    DeleteAccount -> view.Destructive
  }
}

/// 承認待ちの接続要求と、その承認・拒否ボタン。
fn pending_section(pending: List(PendingRow)) -> Element(msg) {
  use rows <- section("Pending connections", pending, "No pending connections.")
  item_list(list.map(rows, fn(entry) { entry_item(pending_content(entry)) }))
}

/// 承認ページ。クライアントが `auth_url` で開く、接続要求 1 件の確認画面。
pub fn approval_page(pending: PendingRow) -> String {
  view.page("Approve connection", view.Narrow, [
    view.card(pending_content(pending)),
  ])
}

/// 見出しと理由だけを伝えるページ。承認・拒否の結果と、アカウントを扱えないときや
/// 変更が反映されたか分からないときに使う。`tone` は理由の囲みの色で、呼び出し側が
/// 結果に応じて決める。理由はほかのページと同じくカードに入れる（中立の囲みはページの
/// 背景と同じ色なので、カードの外では見えない）。ダッシュボードで状態を確かめられるよう
/// リンクを置く。
pub fn notice_page(title: String, message: String, tone: view.Tone) -> String {
  view.page(title, view.Narrow, [
    view.card([view.alert(tone, message)]),
    view.back_link(),
  ])
}

/// 操作の見出しと、ダッシュボードのリンクの文言。
pub fn account_action_title(action: AccountAction) -> String {
  case action {
    EditLabel -> "Edit label"
    RotateSecret -> "Rotate secret"
    DeleteAccount -> "Delete account"
    RevealPrivateKey -> "Show private key"
  }
}

/// 操作のパスセグメント。
fn account_action_segment(action: AccountAction) -> String {
  case action {
    EditLabel -> "label"
    RotateSecret -> "rotate"
    DeleteAccount -> "delete"
    RevealPrivateKey -> "private-key"
  }
}

/// 操作のパス（`/accounts/<signer>/<segment>`）。
pub fn account_action_path(signer: String, action: AccountAction) -> String {
  segments_path([accounts_segment, signer, account_action_segment(action)])
}

/// パスセグメントから、アカウント 1 件への操作の署名者と操作を引く。操作のパスで
/// なければ Error。署名者の値は検査しない（一覧との照合は呼び出し側が行う）。
pub fn parse_account_action_path(
  segments: List(String),
) -> Result(#(String, AccountAction), Nil) {
  case segments {
    [first, signer, segment] if first == accounts_segment ->
      account_actions
      |> list.find(fn(action) { account_action_segment(action) == segment })
      |> result.map(fn(action) { #(signer, action) })
    _ -> Error(Nil)
  }
}

/// 承認待ち 1 件の、署名者・クライアント・経過時間と、承認・拒否ボタン。ダッシュボードの
/// 行と承認ページが使う。
fn pending_content(pending: PendingRow) -> List(Element(msg)) {
  [
    view.summary_list([
      #("Signer", view.Code(pending.signer)),
      #("Client", view.Code(pending.client)),
      #("Age", view.Plain(int.to_string(pending.age_seconds) <> "s")),
    ]),
    button_row(decision_forms(pending.token)),
  ]
}

/// リレーごとの接続状態。
fn relays_section(relays: List(RelayRow)) -> Element(msg) {
  use rows <- section("Relays", relays, "No relays configured.")
  view.table(
    ["Role", "URL", "State"],
    list.map(rows, fn(relay) {
      [
        html.td([attribute.class("whitespace-nowrap")], [
          html.text(role_label(relay.role)),
        ]),
        html.td([attribute.class("font-mono text-xs break-all")], [
          html.text(relay.url),
        ]),
        html.td([], [relay_status(relay.status)]),
      ]
    }),
  )
}

/// 承認済みセッションと、その取り消しボタン。
fn sessions_section(sessions: List(Session)) -> Element(msg) {
  use rows <- section("Approved sessions", sessions, "No approved sessions.")
  item_list(
    list.map(rows, fn(session) {
      entry_item([
        view.summary_list([
          #("Signer", view.Code(session.signer)),
          #("Client", view.Code(session.client)),
        ]),
        button_row([revoke_form(session)]),
      ])
    }),
  )
}

/// 監視イベントを処理するプラグインと、その現在の状態。
fn plugins_section(plugins: List(PluginRow)) -> Element(msg) {
  use rows <- section("Plugins", plugins, "No plugins enabled.")
  view.table(
    ["Name", "State"],
    list.map(rows, fn(plugin) {
      [
        html.td([attribute.class("break-words")], [html.text(plugin.name)]),
        html.td([], [plugin_state(plugin.status)]),
      ]
    }),
  )
}

/// 見出しと本文からなる 1 節。行が無いときは本文の代わりに一言を出す。
fn section(
  title: String,
  rows: List(a),
  empty: String,
  render: fn(List(a)) -> Element(msg),
) -> Element(msg) {
  view.card([view.heading(title), section_body(rows, empty, render)])
}

/// 節の本文。行が無いときは `render` の代わりに一言を出す。
fn section_body(
  rows: List(a),
  empty: String,
  render: fn(List(a)) -> Element(msg),
) -> Element(msg) {
  case rows {
    [] -> view.hint(empty)
    rows -> render(rows)
  }
}

/// 項目を区切り線で分けた一覧。
fn item_list(items: List(Element(msg))) -> Element(msg) {
  html.ul([attribute.class("divide-y divide-base-300")], items)
}

/// 承認待ちとセッションの 1 件。値の組とボタンの並びを横に置き、収まらなければボタンを
/// 下へ回す。
fn entry_item(content: List(Element(msg))) -> Element(msg) {
  html.li(
    [
      attribute.class(
        "flex flex-wrap items-center justify-between gap-x-6 gap-y-3 py-4 first:pt-0 last:pb-0",
      ),
    ],
    content,
  )
}

/// 行と承認ページのボタンの並び。
fn button_row(buttons: List(Element(msg))) -> Element(msg) {
  html.div([attribute.class("flex shrink-0 flex-wrap gap-2")], buttons)
}

/// 承認ページのパス。`auth_url` としてクライアントへ渡す URL も、このパスに
/// 公開 URL を前置して組み立てる。
pub fn approve_path(token: String) -> String {
  "/approve/" <> token
}

/// 拒否のパス。承認ページと違い、POST でしか使わない。
fn deny_path(token: String) -> String {
  "/deny/" <> token
}

/// パスセグメントを連結したパス。
pub fn segments_path(segments: List(String)) -> String {
  "/" <> string.join(segments, "/")
}

/// 承認待ち 1 件への承認・拒否フォーム。どちらも状態を変えるので POST で送る。承認が
/// この画面の主な操作で、拒否してもクライアントは接続し直せるので通常の重さにする。
fn decision_forms(token: String) -> List(Element(msg)) {
  [
    view.post_form(approve_path(token), [], "Approve", view.Primary, view.InRow),
    view.post_form(deny_path(token), [], "Deny", view.Normal, view.InRow),
  ]
}

/// セッションを 1 件取り消すフォーム。取り消しは副作用なので POST で送る。確認のページを
/// 経ずに接続中のクライアントに影響するが、クライアントは接続し直せるので注意の重さにする。
fn revoke_form(session: Session) -> Element(msg) {
  view.post_form(
    segments_path(revoke_segments),
    [
      view.hidden_input("signer", session.signer),
      view.hidden_input("client", session.client),
    ],
    "Revoke",
    view.Caution,
    view.InRow,
  )
}

/// リレーの接続状態のバッジ。
fn relay_status(status: Status) -> Element(msg) {
  let class = case status {
    Connected -> "badge badge-sm badge-success whitespace-nowrap"
    Disconnected -> "badge badge-sm badge-error whitespace-nowrap"
  }
  html.span([attribute.class(class)], [html.text(status_label(status))])
}

/// プラグインの状態。バッジと、あれば詳細を縦に並べる。応答が無いのは再起動中か応答待ちの
/// 一時的な状態なので、異常の色にしない。
fn plugin_state(status: Option(plugin_runner.Status)) -> Element(msg) {
  let class = case status {
    None -> "badge badge-sm badge-ghost whitespace-nowrap"
    Some(plugin_runner.Running) ->
      "badge badge-sm badge-success whitespace-nowrap"
    Some(plugin_runner.Overloaded(..)) ->
      "badge badge-sm badge-warning whitespace-nowrap"
    Some(plugin_runner.Disabled(..)) ->
      "badge badge-sm badge-error whitespace-nowrap"
  }
  let #(word, detail) = plugin_state_label(status)
  let badge = html.span([attribute.class(class)], [html.text(word)])
  case detail {
    None -> badge
    Some(detail) ->
      html.div([attribute.class("flex flex-col items-start gap-1")], [
        badge,
        html.span([attribute.class("text-xs break-words")], [html.text(detail)]),
      ])
  }
}

/// プラグインの状態の語と、あれば詳細の文。`Disabled` の理由はプラグイン由来の
/// 文字列なので、呼び出し側でテキストとして描画すること（長さは `plugin_runner`
/// 側で切ってあるので、ここでは切らない）。
fn plugin_state_label(
  status: Option(plugin_runner.Status),
) -> #(String, Option(String)) {
  case status {
    None -> #("unavailable", None)
    Some(plugin_runner.Running) -> #("running", None)
    Some(plugin_runner.Overloaded(dropped:)) -> #(
      "overloaded",
      Some("(dropped " <> int.to_string(dropped) <> ")"),
    )
    Some(plugin_runner.Disabled(reason:, dropped:)) -> #(
      "disabled",
      Some(reason <> " (dropped " <> int.to_string(dropped) <> ")"),
    )
  }
}

/// リレーの用途の表示名。
fn role_label(role: Role) -> String {
  case role {
    MonitorRelay -> "monitor"
    BunkerRelay -> "bunker"
  }
}

/// 接続状態の表示名。
fn status_label(status: Status) -> String {
  case status {
    Connected -> "connected"
    Disconnected -> "disconnected"
  }
}
