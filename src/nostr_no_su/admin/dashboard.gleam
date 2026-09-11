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

/// 操作の一覧。セグメントとの対応はここから引く。
const account_actions = [
  EditLabel,
  RotateSecret,
  DeleteAccount,
  RevealPrivateKey,
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

/// スナップショットをダッシュボードのページに描画する。
pub fn render(snapshot: Snapshot) -> String {
  view.page(
    "Dashboard",
    list.flatten([
      accounts_section(snapshot.accounts),
      pending_section(snapshot.pending),
      relays_section(snapshot.relays),
      sessions_section(snapshot.sessions),
      plugins_section(snapshot.plugins),
    ]),
  )
}

/// アカウントと、その `bunker://` 接続 URI（secret 入りと、承認を経るもの）と操作。
/// 一覧を得られないときは、表の代わりにその理由を出し、登録のリンクも出さない。
fn accounts_section(
  accounts: Result(List(AccountRow), String),
) -> List(Element(msg)) {
  let #(rows, empty, add_link) = case accounts {
    Ok(rows) -> #(
      rows,
      "No accounts registered.",
      html.p([], [
        view.link(segments_path(new_account_segments), "Add account"),
      ]),
    )
    Error(reason) -> #([], reason, element.none())
  }
  [
    view.heading("Accounts"),
    add_link,
    section_body(
      [
        "Label",
        "Account",
        "Connection URI",
        "Connection URI (approval)",
        "Actions",
      ],
      list.map(rows, fn(account) {
        [
          [html.text(account.label)],
          account_cell(account),
          view.copyable_field(account.uri),
          view.copyable_field(account.auth_uri),
          account_action_links(account.signer),
        ]
      }),
      empty,
    ),
  ]
}

/// アカウントを識別するセル。npub と 16 進の公開鍵を並べる。
pub fn account_cell(account: AccountRow) -> view.Cell(msg) {
  [view.code(account.npub), html.br([]), view.code(account.signer)]
}

/// アカウント 1 件への操作のページへのリンク。
fn account_action_links(signer: String) -> view.Cell(msg) {
  account_actions
  |> list.map(fn(action) {
    view.link(account_action_path(signer, action), account_action_title(action))
  })
  |> list.intersperse(html.br([]))
}

/// 承認待ちの接続要求と、その承認・拒否ボタン。
fn pending_section(pending: List(PendingRow)) -> List(Element(msg)) {
  section(
    "Pending connections",
    ["Signer", "Client", "Age", "Action"],
    list.map(pending, fn(entry) {
      list.append(pending_cells(entry), [decision_forms(entry.token)])
    }),
    "No pending connections.",
  )
}

/// 承認ページ。クライアントが `auth_url` で開く、接続要求 1 件の確認画面。
pub fn approval_page(pending: PendingRow) -> String {
  view.page("Approve connection", [
    view.heading("Approve connection"),
    view.table(["Signer", "Client", "Age"], [pending_cells(pending)]),
    ..decision_forms(pending.token)
  ])
}

/// 見出しと理由だけを伝えるページ。承認・拒否の結果と、アカウントを扱えないときや
/// 変更が反映されたか分からないときに使う。ダッシュボードで状態を確かめられるよう
/// リンクを置く。
pub fn notice_page(title: String, message: String) -> String {
  view.page(title, [
    view.heading(title),
    html.p([], [html.text(message)]),
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

/// 承認待ち 1 件を表す、署名者・クライアント・経過時間のセル。
fn pending_cells(pending: PendingRow) -> List(view.Cell(msg)) {
  [
    [view.code(pending.signer)],
    [view.code(pending.client)],
    [html.text(int.to_string(pending.age_seconds) <> "s")],
  ]
}

/// リレーごとの接続状態。
fn relays_section(relays: List(RelayRow)) -> List(Element(msg)) {
  section(
    "Relays",
    ["Role", "URL", "State"],
    list.map(relays, fn(relay) {
      [
        [html.text(role_label(relay.role))],
        [view.code(relay.url)],
        [html.text(status_label(relay.status))],
      ]
    }),
    "No relays configured.",
  )
}

/// 承認済みセッションと、その取り消しボタン。
fn sessions_section(sessions: List(Session)) -> List(Element(msg)) {
  section(
    "Approved sessions",
    ["Signer", "Client", "Action"],
    list.map(sessions, fn(session) {
      [
        [view.code(session.signer)],
        [view.code(session.client)],
        [revoke_form(session)],
      ]
    }),
    "No approved sessions.",
  )
}

/// 監視イベントを処理するプラグインと、その現在の状態。
fn plugins_section(plugins: List(PluginRow)) -> List(Element(msg)) {
  section(
    "Plugins",
    ["Name", "State"],
    list.map(plugins, fn(plugin) {
      [
        [html.text(plugin.name)],
        [html.text(plugin_state_label(plugin.status))],
      ]
    }),
    "No plugins enabled.",
  )
}

/// プラグインの状態を 1 行の説明にする。`Disabled` の理由はプラグイン由来の
/// 文字列なので、呼び出し側でテキストとして描画すること（長さは `plugin_runner`
/// 側で切ってあるので、ここでは切らない）。
fn plugin_state_label(status: Option(plugin_runner.Status)) -> String {
  case status {
    None -> "unavailable"
    Some(plugin_runner.Running) -> "running"
    Some(plugin_runner.Overloaded(dropped:)) ->
      "overloaded (dropped " <> int.to_string(dropped) <> ")"
    Some(plugin_runner.Disabled(reason:, dropped:)) ->
      "disabled: " <> reason <> " (dropped " <> int.to_string(dropped) <> ")"
  }
}

/// 見出しと表からなる 1 節。行が無いときは表の代わりに一言を出す。
fn section(
  title: String,
  headers: List(String),
  rows: List(List(view.Cell(msg))),
  empty: String,
) -> List(Element(msg)) {
  [view.heading(title), section_body(headers, rows, empty)]
}

/// 節の本文。行が無いときは表の代わりに一言を出す。
fn section_body(
  headers: List(String),
  rows: List(List(view.Cell(msg))),
  empty: String,
) -> Element(msg) {
  case rows {
    [] -> html.p([], [html.text(empty)])
    rows -> view.table(headers, rows)
  }
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

/// 承認待ち 1 件への承認・拒否フォーム。どちらも状態を変えるので POST で送る。
fn decision_forms(token: String) -> List(Element(msg)) {
  [
    view.post_form(approve_path(token), [], "Approve"),
    view.post_form(deny_path(token), [], "Deny"),
  ]
}

/// セッションを 1 件取り消すフォーム。取り消しは副作用なので POST で送る。
fn revoke_form(session: Session) -> Element(msg) {
  view.post_form(
    segments_path(revoke_segments),
    [
      view.hidden_input("signer", session.signer),
      view.hidden_input("client", session.client),
    ],
    "Revoke",
  )
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
