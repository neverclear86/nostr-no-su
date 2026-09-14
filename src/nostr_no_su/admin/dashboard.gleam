//// 管理 UI のダッシュボード、承認ページ、通知ページの描画と、表示する状態の型、パスと
//// フォームの欄の名前の定義。描画は状態のスナップショット（純粋なデータ）から HTML
//// 文字列を組み立てるだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値はすべてユーザー由来になりうる（リレー URL、クライアント pubkey、
//// アカウントのラベル、表示する理由）ため、テキストか属性値として lustre に渡し、
//// エスケープを文字列化に任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から
//// 表示の言語で引き、文字列リテラルで書かない（同じく `admin/view` の規則）。
////
//// パスとフォームの欄の名前は、ルーティング（`admin`）とフォーム（ここと
//// `admin/account_pages`）が同じ定義を見るようここに置く。ページ枠が使う定義
//// （スタイルシートとテーマと言語の切り替えのパスセグメント、切り替えの欄の名前）と、
//// パスセグメントからパスを組み立てる `segments_path` は `admin/view` に置く。

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/i18n.{type Language}
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

/// リレー接続 1 本の表示内容。接続の識別を表す `relay_list.Connection` とは
/// 別物なので、表の行であることを名前に出す。
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
    /// アカウントの一覧。得られないとき（読み込み中、応答なし）は表示する理由。
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

/// プラグインの再有効化の POST 先のパスセグメント。
pub const reenable_plugin_segments = ["plugins", "reenable"]

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
pub fn render(
  language: Language,
  theme: view.Theme,
  snapshot: Snapshot,
) -> String {
  view.page(
    language,
    theme,
    i18n.Dashboard,
    view.Wide,
    view.SwitchReturningTo("/"),
    [
      html.div([attribute.class("grid items-start gap-6 xl:grid-cols-5")], [
        html.div(
          [attribute.class("flex min-w-0 flex-col gap-6 xl:col-span-3")],
          [
            pending_section(language, snapshot.pending),
            accounts_section(language, snapshot.accounts),
            sessions_section(language, snapshot.sessions),
          ],
        ),
        html.div(
          [attribute.class("flex min-w-0 flex-col gap-6 xl:col-span-2")],
          [
            relays_section(language, snapshot.relays),
            plugins_section(language, snapshot.plugins),
          ],
        ),
      ]),
    ],
  )
}

/// アカウントと、その `bunker://` 接続 URI（secret 入りと、承認を経るもの）と操作。
/// 一覧を得られないときは、一覧の代わりにその理由を出し、登録のリンクも出さない。
fn accounts_section(
  language: Language,
  accounts: Result(List(AccountRow), String),
) -> Element(msg) {
  let text = i18n.text(language, _)
  let #(add_link, body) = case accounts {
    Ok(rows) -> #(
      view.button_link(
        view.segments_path(new_account_segments),
        text(i18n.AddAccount),
        view.Primary,
      ),
      section_body(rows, text(i18n.NoAccounts), fn(rows) {
        item_list(list.map(rows, account_item(language, _)))
      }),
    )
    Error(reason) -> #(
      element.none(),
      view.alert(
        view.Neutral,
        view.reason_content(
          language,
          Some(i18n.CouldNotListAccounts),
          i18n.Untranslated(reason),
        ),
      ),
    )
  }
  view.card([
    html.div(
      [attribute.class("flex flex-wrap items-center justify-between gap-2")],
      [view.heading(text(i18n.Accounts)), add_link],
    ),
    body,
  ])
}

/// アカウント 1 件。識別、2 つの接続 URI、操作のリンクを縦に並べる。
fn account_item(language: Language, account: AccountRow) -> Element(msg) {
  let text = i18n.text(language, _)
  html.li([attribute.class("flex flex-col gap-3 py-4 first:pt-0 last:pb-0")], [
    account_identity(account),
    view.copyable_field(language, text(i18n.ConnectionUri), account.uri),
    view.copyable_field(
      language,
      text(i18n.ConnectionUriForApproval),
      account.auth_uri,
    ),
    account_action_links(language, account.signer),
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
fn account_action_links(language: Language, signer: String) -> Element(msg) {
  html.div(
    [attribute.class("flex flex-wrap gap-2")],
    list.map(account_actions, fn(action) {
      view.button_link(
        account_action_path(signer, action),
        i18n.text(language, account_action_title(action)),
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
fn pending_section(
  language: Language,
  pending: List(PendingRow),
) -> Element(msg) {
  let text = i18n.text(language, _)
  use rows <- section(
    text(i18n.PendingConnections),
    pending,
    text(i18n.NoPendingConnections),
  )
  item_list(
    list.map(rows, fn(entry) { entry_item(pending_content(language, entry)) }),
  )
}

/// 承認ページ。クライアントが `auth_url` で開く、接続要求 1 件の確認画面。テーマか言語を
/// 切り替えた後は同じ承認ページを開き直す。
pub fn approval_page(
  language: Language,
  theme: view.Theme,
  pending: PendingRow,
) -> String {
  view.page(
    language,
    theme,
    i18n.ApproveConnection,
    view.Narrow,
    view.SwitchReturningTo(approve_path(pending.token)),
    [view.card(pending_content(language, pending))],
  )
}

/// 見出しと理由だけを伝えるページ。承認・拒否の結果、アカウントを扱えないとき、
/// 変更が反映されたか分からないとき、404 / 405 / 400 の通知に使う。`tone` は理由の
/// 囲みの色で、呼び出し側が結果に応じて決める。理由はほかのページと同じくカードに入れる
/// （中立の囲みはページの背景と同じ色なので、カードの外では見えない）。ダッシュボードで
/// 状態を確かめられるようリンクを置く。切り替えを出すか、切り替えた後にどこを開くかは
/// 呼び出し側が `switch` で決める。
pub fn notice_page(
  language: Language,
  theme: view.Theme,
  switch: view.NavbarSwitch,
  title: i18n.Message,
  message: i18n.Reason,
  tone: view.Tone,
) -> String {
  view.page(language, theme, title, view.Narrow, switch, [
    view.card([view.alert(tone, view.reason_content(language, None, message))]),
    view.back_link(language),
  ])
}

/// 操作の見出しと、ダッシュボードのリンクの文言。
pub fn account_action_title(action: AccountAction) -> i18n.Message {
  case action {
    EditLabel -> i18n.EditLabel
    RotateSecret -> i18n.RotateSecret
    DeleteAccount -> i18n.DeleteAccount
    RevealPrivateKey -> i18n.ShowPrivateKey
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
  view.segments_path([accounts_segment, signer, account_action_segment(action)])
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
fn pending_content(
  language: Language,
  pending: PendingRow,
) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.summary_list([
      #(text(i18n.Signer), view.Code(pending.signer)),
      #(text(i18n.Client), view.Code(pending.client)),
      #(text(i18n.Age), view.Plain(text(i18n.AgeSeconds(pending.age_seconds)))),
    ]),
    button_row(decision_forms(language, pending.token)),
  ]
}

/// リレーごとの接続状態。
fn relays_section(language: Language, relays: List(RelayRow)) -> Element(msg) {
  let text = i18n.text(language, _)
  use rows <- section(text(i18n.Relays), relays, text(i18n.NoRelays))
  view.table(
    [text(i18n.RoleColumn), text(i18n.UrlColumn), text(i18n.StateColumn)],
    list.map(rows, fn(relay) {
      [
        html.td([attribute.class("whitespace-nowrap")], [
          html.text(text(role_label(relay.role))),
        ]),
        html.td([attribute.class("font-mono text-xs break-all")], [
          html.text(relay.url),
        ]),
        html.td([], [relay_status(language, relay.status)]),
      ]
    }),
  )
}

/// 承認済みセッションと、その取り消しボタン。
fn sessions_section(
  language: Language,
  sessions: List(Session),
) -> Element(msg) {
  let text = i18n.text(language, _)
  use rows <- section(
    text(i18n.ApprovedSessions),
    sessions,
    text(i18n.NoApprovedSessions),
  )
  item_list(
    list.map(rows, fn(session) {
      entry_item([
        view.summary_list([
          #(text(i18n.Signer), view.Code(session.signer)),
          #(text(i18n.Client), view.Code(session.client)),
        ]),
        button_row([revoke_form(language, session)]),
      ])
    }),
  )
}

/// 監視イベントを処理するプラグインと、その現在の状態。
fn plugins_section(
  language: Language,
  plugins: List(PluginRow),
) -> Element(msg) {
  let text = i18n.text(language, _)
  use rows <- section(text(i18n.Plugins), plugins, text(i18n.NoPlugins))
  view.table(
    [text(i18n.NameColumn), text(i18n.StateColumn)],
    list.map(rows, fn(plugin) {
      [
        html.td([attribute.class("break-words")], [html.text(plugin.name)]),
        html.td([], [plugin_state(language, plugin)]),
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

/// 承認待ち 1 件への承認・拒否フォーム。どちらも状態を変えるので POST で送る。承認が
/// この画面の主な操作で、拒否してもクライアントは接続し直せるので通常の重さにする。
fn decision_forms(language: Language, token: String) -> List(Element(msg)) {
  let text = i18n.text(language, _)
  [
    view.post_form(
      approve_path(token),
      [],
      text(i18n.Approve),
      view.Primary,
      view.InRow,
    ),
    view.post_form(
      deny_path(token),
      [],
      text(i18n.Deny),
      view.Normal,
      view.InRow,
    ),
  ]
}

/// セッションを 1 件取り消すフォーム。取り消しは副作用なので POST で送る。確認のページを
/// 経ずに接続中のクライアントに影響するが、クライアントは接続し直せるので注意の重さにする。
fn revoke_form(language: Language, session: Session) -> Element(msg) {
  view.post_form(
    view.segments_path(revoke_segments),
    [
      view.hidden_input("signer", session.signer),
      view.hidden_input("client", session.client),
    ],
    i18n.text(language, i18n.Revoke),
    view.Caution,
    view.InRow,
  )
}

/// 無効になったプラグイン 1 つの再有効化フォーム。イベント処理を再開させ、失敗が
/// 続けばまた無効になるので、状態を変えない `Normal` でも取り返しの付かない
/// `Destructive` でもなく注意の重さにする。
fn reenable_form(language: Language, name: String) -> Element(msg) {
  view.post_form(
    view.segments_path(reenable_plugin_segments),
    [view.hidden_input("name", name)],
    i18n.text(language, i18n.ReenablePlugin),
    view.Caution,
    view.InRow,
  )
}

/// リレーの接続状態のバッジ。
fn relay_status(language: Language, status: Status) -> Element(msg) {
  let class = case status {
    Connected -> "badge badge-sm badge-success whitespace-nowrap"
    Disconnected -> "badge badge-sm badge-error whitespace-nowrap"
  }
  html.span([attribute.class(class)], [
    html.text(i18n.text(language, status_label(status))),
  ])
}

/// プラグインの状態。バッジと、あれば詳細を縦に並べる。応答が無いのは再起動中か応答待ちの
/// 一時的な状態なので、異常の色にしない。`Disabled` のときだけ、詳細の下に再有効化の
/// ボタンを並べる。
fn plugin_state(language: Language, plugin: PluginRow) -> Element(msg) {
  let status = plugin.status
  let class = case status {
    None -> "badge badge-sm badge-ghost whitespace-nowrap"
    Some(plugin_runner.Running) ->
      "badge badge-sm badge-success whitespace-nowrap"
    Some(plugin_runner.Overloaded(..)) ->
      "badge badge-sm badge-warning whitespace-nowrap"
    Some(plugin_runner.Disabled(..)) ->
      "badge badge-sm badge-error whitespace-nowrap"
  }
  let #(word, detail) = plugin_state_label(language, status)
  let badge = html.span([attribute.class(class)], [html.text(word)])
  case detail {
    None -> badge
    Some(detail) ->
      html.div([attribute.class("flex flex-col items-start gap-1")], [
        badge,
        html.span([attribute.class("text-xs break-words")], detail),
        ..reenable_form_if_disabled(language, plugin)
      ])
  }
}

/// `Disabled` のときだけ再有効化のフォームを 1 要素のリストで返す。それ以外は空。
fn reenable_form_if_disabled(
  language: Language,
  plugin: PluginRow,
) -> List(Element(msg)) {
  case plugin.status {
    Some(plugin_runner.Disabled(..)) -> [reenable_form(language, plugin.name)]
    _ -> []
  }
}

/// プラグインの状態の語と、あれば詳細。`Disabled` の理由はプラグイン由来の英語の文字列
/// なので、訳さずにテキストとして描画する（長さは `plugin_runner` 側で切ってあるので、
/// ここでは切らない）。
fn plugin_state_label(
  language: Language,
  status: Option(plugin_runner.Status),
) -> #(String, Option(List(Element(msg)))) {
  let text = i18n.text(language, _)
  case status {
    None -> #(text(i18n.PluginUnavailable), None)
    Some(plugin_runner.Running) -> #(text(i18n.PluginRunning), None)
    Some(plugin_runner.Overloaded(dropped:)) -> #(
      text(i18n.PluginOverloaded),
      Some([html.text(text(i18n.Dropped(dropped)))]),
    )
    Some(plugin_runner.Disabled(reason:, dropped:)) -> #(
      text(i18n.PluginDisabled),
      Some([
        view.untranslated(reason),
        html.text(text(i18n.DroppedAfterReason(dropped))),
      ]),
    )
  }
}

/// リレーの用途の表示名。
fn role_label(role: Role) -> i18n.Message {
  case role {
    MonitorRelay -> i18n.MonitorRole
    BunkerRelay -> i18n.BunkerRole
  }
}

/// 接続状態の表示名。
fn status_label(status: Status) -> i18n.Message {
  case status {
    Connected -> i18n.RelayConnected
    Disconnected -> i18n.RelayDisconnected
  }
}
