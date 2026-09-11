//// 管理 UI の描画。状態のスナップショット（純粋なデータ）から HTML 文字列を
//// 組み立てるだけで、プロセスにも IO にも触れない。
////
//// 埋め込む値はすべてユーザー由来になりうる（リレー URL、クライアント pubkey、
//// アカウントのラベル、表示する理由）ため、`escape` を通してから連結する。
////
//// パスとフォームの欄の名前は、ルーティング（`admin`）とフォームが同じ定義を見るよう
//// ここにだけ置く。

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/bunker/engine.{type Session}
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection.{type Status, Connected, Disconnected}
import wisp

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

/// コピーのボタンの処理。直前の入力欄を選択し、クリップボードへ書く。値はスクリプトに
/// 埋め込まず DOM から読むので、属性値として固定の文字列のまま出せる（`&`、`<`、`>`、
/// `"`、`'` を含めないこと）。
const copy_script = "const f=this.previousElementSibling;f.select();if(navigator.clipboard)navigator.clipboard.writeText(f.value)"

/// 別のマスターキーで暗号化された行についての案内。どの登録のページにも常に出す。
const skipped_row_note = "If registration reports \"account is already registered\" for an account that is not on the dashboard, a row encrypted with a different master key is left in the database; see the README for how to remove it."

/// スナップショットをダッシュボードのページに描画する。
pub fn render(snapshot: Snapshot) -> String {
  page("Dashboard", [
    accounts_section(snapshot.accounts),
    pending_section(snapshot.pending),
    relays_section(snapshot.relays),
    sessions_section(snapshot.sessions),
    plugins_section(snapshot.plugins),
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

/// アカウントと、その `bunker://` 接続 URI（secret 入りと、承認を経るもの）と操作。
/// 一覧を得られないときは、表の代わりにその理由を出し、登録のリンクも出さない。
fn accounts_section(accounts: Result(List(AccountRow), String)) -> String {
  let #(rows, empty, add_link) = case accounts {
    Ok(rows) -> #(
      rows,
      "No accounts registered.",
      "<p>"
        <> link(segments_path(new_account_segments), "Add account")
        <> "</p>",
    )
    Error(reason) -> #([], reason, "")
  }
  heading("Accounts")
  <> add_link
  <> section_body(
    [
      "Label",
      "Account",
      "Connection URI",
      "Connection URI (approval)",
      "Actions",
    ],
    list.map(rows, fn(account) {
      [
        escape(account.label),
        account_cell(account),
        copyable_field(account.uri),
        copyable_field(account.auth_uri),
        account_action_links(account.signer),
      ]
    }),
    empty,
  )
}

/// アカウントを識別するセル。npub と 16 進の公開鍵を並べる。
fn account_cell(account: AccountRow) -> String {
  code(account.npub) <> "<br>" <> code(account.signer)
}

/// アカウント 1 件への操作のページへのリンク。
fn account_action_links(signer: String) -> String {
  account_actions
  |> list.map(fn(action) {
    link(account_action_path(signer, action), account_action_title(action))
  })
  |> string.join("<br>")
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

/// 見出しと理由だけを伝えるページ。承認・拒否の結果と、アカウントを扱えないときや
/// 変更が反映されたか分からないときに使う。ダッシュボードで状態を確かめられるよう
/// リンクを置く。
pub fn notice_page(title: String, message: String) -> String {
  page(title, [
    "<h2>" <> escape(title) <> "</h2><p>" <> escape(message) <> "</p>",
    back_link(),
  ])
}

/// アカウントの登録画面。nsec の入力による登録と、サーバー側での鍵の生成のフォーム。
pub fn new_account_page(error: Option(String)) -> String {
  page("Add account", [
    "<h2>Add account</h2>",
    error_message(error),
    "<h3>Import a private key</h3>",
    "<p>Paste the private key (nsec) of the account. It is shown once after "
      <> "registration, and afterwards only when you re-enter the admin "
      <> "password.</p>",
    post_form(
      segments_path(import_account_segments),
      [
        labelled("Private key (nsec)", secret_input(nsec_field)),
        labelled("Label", label_input("", Some(max_label_code_points))),
      ],
      "Register",
    ),
    "<h3>Generate a new key</h3>",
    "<p>Generate a new private key on the server. It is shown for backup "
      <> "before it is registered.</p>",
    post_form(segments_path(generate_account_segments), [], "Generate"),
    "<p>" <> escape(skipped_row_note) <> "</p>",
    back_link(),
  ])
}

/// 生成した鍵の確認ページ。生成した nsec を表示する唯一のページで、ここではまだ
/// 登録しない。登録のフォームは nsec を隠しフィールドで送り返す。`error` は、生成した鍵の
/// 登録でラベルが規則に反したときに再描画する理由。
pub fn generated_key_page(nsec: String, error: Option(String)) -> String {
  page("Generated key", [
    "<h2>Generated key</h2>",
    error_message(error),
    "<p><strong>Back up this private key now.</strong> The account is not "
      <> "registered until you press \"Register this key\". After "
      <> "registration, the key is shown only when you re-enter the admin "
      <> "password.</p>",
    labelled("Private key (nsec)", copyable_field(nsec)),
    post_form(
      segments_path(register_generated_segments),
      [
        hidden(nsec_field, nsec),
        labelled("Label", label_input("", Some(max_label_code_points))),
      ],
      "Register this key",
    ),
    back_link(),
  ])
}

/// nsec の入力による登録の完了ページ。入力された鍵の nsec をここで 1 回だけ表示する。
/// 接続 URI はダッシュボードで取得する。
pub fn registered_page(npub: String, label: String, nsec: String) -> String {
  page("Account registered", [
    "<h2>Account registered</h2>",
    table(["Label", "Account"], [[escape(label), code(npub)]]),
    "<p><strong>Back up this private key if you have not already.</strong> "
      <> "It is shown again only when you re-enter the admin password. The "
      <> "connection URI is on the dashboard.</p>",
    labelled("Private key (nsec)", copyable_field(nsec)),
    back_link(),
  ])
}

/// アカウント 1 件への操作のページ。操作の説明と、操作を実行する 1 つのフォーム。
/// ラベルの編集フォームには、利用者の入力ではなく一覧から得た保存済みのラベルを入れる。
pub fn account_action_page(
  row: AccountRow,
  action: AccountAction,
  error: Option(String),
) -> String {
  let title = account_action_title(action)
  let path = account_action_path(row.signer, action)
  let #(description, form) = case action {
    EditLabel -> #(
      "",
      post_form(path, [labelled("Label", label_input(row.label, None))], "Save"),
    )
    RotateSecret -> #(
      "<p>A new connection secret is generated. Clients that connect with the "
        <> "old connection URI are no longer accepted without approval, but "
        <> "sessions that are already approved remain. Paste the new "
        <> "connection URI from the dashboard into your clients.</p>",
      post_form(path, [], title),
    )
    DeleteAccount -> #(
      "<p>The private key is deleted from the bunker and from the database. "
        <> "<strong>If you have not saved this key anywhere else, the account "
        <> "is lost.</strong> Its sessions and pending connections are removed "
        <> "as well.</p>",
      post_form(path, [], title),
    )
    RevealPrivateKey -> #(
      "<p>Re-enter the admin password to show the private key. Showing it is "
        <> "logged with the npub.</p>",
      post_form(
        path,
        [labelled("Admin password", secret_input(password_field))],
        title,
      ),
    )
  }
  page(title, [
    "<h2>" <> escape(title) <> "</h2>",
    account_summary(row),
    error_message(error),
    description,
    form,
    back_link(),
  ])
}

/// 管理パスワードを再入力した後の秘密鍵の表示ページ。
pub fn private_key_page(row: AccountRow, nsec: String) -> String {
  page("Private key", [
    "<h2>Private key</h2>",
    account_summary(row),
    labelled("Private key (nsec)", copyable_field(nsec)),
    "<p><strong>Close this tab after copying the key.</strong> Reloading this "
      <> "page or coming back to it with the back button can resend the form, "
      <> "which shows the key again and logs it again.</p>",
    back_link(),
  ])
}

/// 操作の対象のアカウントを示す表。
fn account_summary(row: AccountRow) -> String {
  table(["Label", "Account"], [[escape(row.label), account_cell(row)]])
}

/// 操作の見出しと、ダッシュボードのリンクの文言。
fn account_action_title(action: AccountAction) -> String {
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

/// 見出しと表からなる 1 節。行が無いときは表の代わりに一言を出す。セルは
/// 組み立て済みの HTML として受け取る。
fn section(
  title: String,
  headers: List(String),
  rows: List(List(String)),
  empty: String,
) -> String {
  heading(title) <> section_body(headers, rows, empty)
}

/// 節の見出し。
fn heading(title: String) -> String {
  "<h2>" <> escape(title) <> "</h2>"
}

/// 節の本文。行が無いときは表の代わりに一言を出す。
fn section_body(
  headers: List(String),
  rows: List(List(String)),
  empty: String,
) -> String {
  case rows {
    [] -> "<p>" <> escape(empty) <> "</p>"
    rows -> table(headers, rows)
  }
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

/// パスセグメントを連結したパス。
fn segments_path(segments: List(String)) -> String {
  "/" <> string.join(segments, "/")
}

/// 承認待ち 1 件への承認・拒否フォーム。どちらも状態を変えるので POST で送る。
fn decision_forms(token: String) -> String {
  post_form(approve_path(token), [], "Approve")
  <> post_form(deny_path(token), [], "Deny")
}

/// セッションを 1 件取り消すフォーム。取り消しは副作用なので POST で送る。
fn revoke_form(session: Session) -> String {
  post_form(
    segments_path(revoke_segments),
    [hidden("signer", session.signer), hidden("client", session.client)],
    "Revoke",
  )
}

/// 指定した宛先へ POST で送るフォーム。欄は組み立て済みの HTML を並べ、最後に送信の
/// ボタンを置く。
fn post_form(action: String, fields: List(String), label: String) -> String {
  "<form method=\"post\" action=\""
  <> escape(action)
  <> "\">"
  <> string.concat(fields)
  <> "<button type=\"submit\">"
  <> escape(label)
  <> "</button></form>"
}

/// 見出しを付けた入力欄の段落。
fn labelled(caption: String, input: String) -> String {
  "<p><label>" <> escape(caption) <> "<br>" <> input <> "</label></p>"
}

/// nsec や管理パスワードのように伏せて入力させる欄。
fn secret_input(name: String) -> String {
  "<input type=\"password\" name=\""
  <> escape(name)
  <> "\" autocomplete=\"off\" required>"
}

/// ラベルの入力欄。`maxlength` は新しく入力する欄にだけ付ける。保存済みのラベルは
/// UTF-16 で上限を超えうるので、編集の欄に付けると 1 文字の編集で送信できなくなる。
fn label_input(value: String, maxlength: Option(Int)) -> String {
  let limit = case maxlength {
    Some(limit) -> " maxlength=\"" <> int.to_string(limit) <> "\""
    None -> ""
  }
  "<input type=\"text\" name=\""
  <> escape(label_field)
  <> "\""
  <> limit
  <> " autocomplete=\"off\" value=\""
  <> escape(value)
  <> "\">"
}

/// 読み取り専用の入力欄と、その値をコピーするボタン。値はスクリプトに埋め込まず、
/// ボタンが DOM から読む。欄に name を付けない（送信にも入力履歴にも含めないため）。
fn copyable_field(value: String) -> String {
  "<input type=\"text\" readonly size=\"64\" value=\""
  <> escape(value)
  <> "\"><button type=\"button\" onclick=\""
  <> copy_script
  <> "\">Copy</button>"
}

/// フォームの上に出す失敗の理由。無ければ空。
fn error_message(error: Option(String)) -> String {
  case error {
    None -> ""
    Some(reason) -> "<p role=\"alert\">" <> escape(reason) <> "</p>"
  }
}

/// ダッシュボードへ戻るリンクの段落。
fn back_link() -> String {
  "<p>" <> link("/", "Back to dashboard") <> "</p>"
}

/// リンク 1 つ。
fn link(href: String, text: String) -> String {
  "<a href=\"" <> escape(href) <> "\">" <> escape(text) <> "</a>"
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
