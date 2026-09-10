//// 管理 UI の描画。状態のスナップショット（純粋なデータ）から HTML 文字列を
//// 組み立てるだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値はすべてユーザー由来になりうる（リレー URL、クライアント pubkey）
//// ため、`escape` を通してから連結する。

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/bunker/engine.{type Session}
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection.{type Status, Connected, Disconnected}
import wisp

/// ページ全体のスタイル。外部ファイルを読ませないよう最小限を埋め込む。
const style = "body{font-family:system-ui,sans-serif;margin:2rem auto;max-width:64rem;padding:0 1rem;line-height:1.5}
h1{font-size:1.4rem}
h2{font-size:1.1rem;margin-top:2rem}
table{border-collapse:collapse;width:100%}
th,td{border:1px solid #ccc;padding:.4rem .6rem;text-align:left;font-size:.9rem;vertical-align:top}
th{background:#f4f4f4}
code{word-break:break-all;font-size:.85rem}"

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
/// クライアントは管理 UI での承認を経てから署名を委任できる。
pub type AccountRow {
  AccountRow(signer: String, uri: String, auth_uri: String)
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
    accounts: List(AccountRow),
    pending: List(PendingRow),
    relays: List(RelayRow),
    sessions: List(Session),
    plugins: List(PluginRow),
    event_logger_enabled: Bool,
  )
}

/// スナップショットをダッシュボードのページに描画する。
pub fn render(snapshot: Snapshot) -> String {
  page("Dashboard", [
    accounts_section(snapshot.accounts),
    pending_section(snapshot.pending),
    relays_section(snapshot.relays),
    sessions_section(snapshot.sessions),
    plugins_section(snapshot.plugins),
    event_logger_section(snapshot.event_logger_enabled),
  ])
}

/// 管理 UI 共通のページ枠。本文は組み立て済みの HTML を順に並べる。
fn page(title: String, body: List(String)) -> String {
  "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
  <> "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
  <> "<title>nostr-no-su — "
  <> escape(title)
  <> "</title><style>"
  <> style
  <> "</style></head><body><h1>nostr-no-su</h1>"
  <> string.concat(body)
  <> "</body></html>"
}

/// アカウントと、その `bunker://` 接続 URI（secret 入りと、承認を経るもの）。
fn accounts_section(accounts: List(AccountRow)) -> String {
  section(
    "Accounts",
    ["Signer pubkey", "Connection URI", "Connection URI (approval)"],
    list.map(accounts, fn(account) {
      [code(account.signer), code(account.uri), code(account.auth_uri)]
    }),
    "No accounts configured.",
  )
}

/// 承認待ちの接続要求と、その承認・拒否ボタン。
fn pending_section(pending: List(PendingRow)) -> String {
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
  page("Approve connection", [
    "<h2>Approve connection</h2>",
    table(["Signer", "Client", "Age"], [pending_cells(pending)]),
    decision_forms(pending.token),
  ])
}

/// 承認・拒否を終えたことを伝えるページ。承認ページはクライアントが別ウィンドウ
/// で開くため、閉じてよいことを伝える。
pub fn notice_page(title: String, message: String) -> String {
  page(title, [
    "<h2>" <> escape(title) <> "</h2><p>" <> escape(message) <> "</p>",
    "<p><a href=\"/\">Back to dashboard</a></p>",
  ])
}

/// 承認待ち 1 件を表す、署名者・クライアント・経過時間のセル。
fn pending_cells(pending: PendingRow) -> List(String) {
  [
    code(pending.signer),
    code(pending.client),
    escape(int.to_string(pending.age_seconds) <> "s"),
  ]
}

/// リレーごとの接続状態。
fn relays_section(relays: List(RelayRow)) -> String {
  section(
    "Relays",
    ["Role", "URL", "State"],
    list.map(relays, fn(relay) {
      [
        escape(role_label(relay.role)),
        code(relay.url),
        escape(status_label(relay.status)),
      ]
    }),
    "No relays configured.",
  )
}

/// 承認済みセッションと、その取り消しボタン。
fn sessions_section(sessions: List(Session)) -> String {
  section(
    "Approved sessions",
    ["Signer", "Client", "Action"],
    list.map(sessions, fn(session) {
      [code(session.signer), code(session.client), revoke_form(session)]
    }),
    "No approved sessions.",
  )
}

/// 監視イベントを処理するプラグインと、その現在の状態。
fn plugins_section(plugins: List(PluginRow)) -> String {
  section(
    "Plugins",
    ["Name", "State"],
    list.map(plugins, fn(plugin) {
      [escape(plugin.name), escape(plugin_state_label(plugin.status))]
    }),
    "No plugins enabled.",
  )
}

/// プラグインの状態を 1 行の説明にする。`Disabled` の理由はプラグイン由来の
/// 文字列なので、呼び出し側で必ず `escape` を通すこと（長さは `plugin_runner`
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

/// イベントロガーによる保存が有効かどうか。
fn event_logger_section(enabled: Bool) -> String {
  "<h2>Event storage</h2><p>Event logger: "
  <> escape(enabled_label(enabled))
  <> "</p>"
}

/// 見出しと表からなる 1 節。行が無いときは表の代わりに一言を出す。セルは
/// 組み立て済みの HTML として受け取る。
fn section(
  title: String,
  headers: List(String),
  rows: List(List(String)),
  empty: String,
) -> String {
  let body = case rows {
    [] -> "<p>" <> escape(empty) <> "</p>"
    rows -> table(headers, rows)
  }
  "<h2>" <> escape(title) <> "</h2>" <> body
}

/// 見出し行付きの表。
fn table(headers: List(String), rows: List(List(String))) -> String {
  let head = row("th", list.map(headers, escape))
  let body = rows |> list.map(row("td", _)) |> string.concat
  "<table><thead>" <> head <> "</thead><tbody>" <> body <> "</tbody></table>"
}

/// 指定したセル要素（`th` / `td`）で組み立てた 1 行。
fn row(cell: String, cells: List(String)) -> String {
  let cells =
    cells
    |> list.map(fn(content) {
      "<" <> cell <> ">" <> content <> "</" <> cell <> ">"
    })
    |> string.concat
  "<tr>" <> cells <> "</tr>"
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

/// セッション取り消しの POST 先のパスセグメント。ルーティング（`admin`）と
/// フォームの action が同じ定義を見るよう、パスの知識はここにだけ置く。
pub const revoke_segments = ["sessions", "revoke"]

/// セッション取り消しの POST 先。
fn revoke_path() -> String {
  "/" <> string.join(revoke_segments, "/")
}

/// 承認待ち 1 件への承認・拒否フォーム。どちらも状態を変えるので POST で送る。
fn decision_forms(token: String) -> String {
  decision_form(approve_path(token), "Approve")
  <> decision_form(deny_path(token), "Deny")
}

/// 指定した宛先へ送るボタン 1 つだけのフォーム。
fn decision_form(action: String, label: String) -> String {
  "<form method=\"post\" action=\""
  <> escape(action)
  <> "\"><button type=\"submit\">"
  <> escape(label)
  <> "</button></form>"
}

/// セッションを 1 件取り消すフォーム。取り消しは副作用なので POST で送る。
fn revoke_form(session: Session) -> String {
  "<form method=\"post\" action=\""
  <> escape(revoke_path())
  <> "\">"
  <> hidden("signer", session.signer)
  <> hidden("client", session.client)
  <> "<button type=\"submit\">Revoke</button></form>"
}

/// フォームで送る隠しフィールド。
fn hidden(name: String, value: String) -> String {
  "<input type=\"hidden\" name=\""
  <> escape(name)
  <> "\" value=\""
  <> escape(value)
  <> "\">"
}

/// 鍵や URI のように等幅で見せたい値のセル。
fn code(value: String) -> String {
  "<code>" <> escape(value) <> "</code>"
}

/// HTML に埋め込める形に値をエスケープする。
fn escape(value: String) -> String {
  wisp.escape_html(value)
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

/// 有効・無効の表示名。
fn enabled_label(enabled: Bool) -> String {
  case enabled {
    True -> "enabled"
    False -> "disabled"
  }
}
