//// 管理 UI のパスの定義。ページとフォームとページ枠（スタイルシート、スクリプト、テーマと
//// 言語の切り替え）のルートの型（`Route`）、パスセグメントからの解析（`parse`）、ルートからの
//// パスの組み立て（`path`、`href`）と、パスの引数になるアカウントとリレーへの操作の型を置く。
//// 解析と組み立ては同じセグメントの定義（`route_segments`）を見る。ルーティング（`admin`）は
//// `parse` の結果でハンドラーを選び、リンクとフォームの宛先は `href` で組み立てる。描画の
//// モジュール（`admin/view`、`admin/dashboard`）がここを import するので、ここは描画の
//// モジュールを import しない。

import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

/// アカウント 1 件に対する操作。
pub type AccountAction {
  EditLabel
  RotateSecret
  DeleteAccount
  RevealPrivateKey
}

/// 操作の一覧。セグメントとの対応をここから引く。
pub const account_actions = [
  EditLabel,
  RevealPrivateKey,
  RotateSecret,
  DeleteAccount,
]

/// リレー 1 件に対する操作。
pub type RelayAction {
  EditRelayRoles
  DeleteRelay
}

/// 操作の一覧。ダッシュボードのボタンとダイアログはこの順に並べ、セグメントとの対応もここから引く。
pub const relay_actions = [EditRelayRoles, DeleteRelay]

/// 管理 UI のパス 1 つ。`admin` のハンドラー 1 つに構築子 1 つを対応させ（静的ファイルだけは
/// スタイルシートとスクリプトの 2 つ）、パスの引数は構築子の欄に持つ。`/healthz` は認証の前に
/// 分けるのでここに無い。
pub type Route {
  /// ダッシュボード（`/`）。
  ShowDashboard
  /// ビルドしたスタイルシート（`/static/admin.css`）。配信する `wisp.serve_static` は要求のパスから
  /// `priv` の下のファイルを引くので、このパスは `priv` の中の配置（`priv/static/admin.css`）と
  /// `package.json` の `build:css` の出力先に一致させる。
  Stylesheet
  /// 管理 UI のスクリプト（`/static/admin.js`）。`Stylesheet` と同じく要求のパスから `priv` の下の
  /// ファイルを引くので、`priv` の中の配置（`priv/static/admin.js`）に一致させる。
  Script
  /// 言語の切り替え（`/language`）。
  SwitchLanguage
  /// テーマの切り替え（`/theme`）。
  SwitchTheme
  /// 承認ページと承認（`/approve/<token>`）。
  ApproveConnection(token: String)
  /// 拒否（`/deny/<token>`）。
  DenyConnection(token: String)
  /// セッションの取り消し（`/sessions/revoke`）。
  RevokeSession
  /// クライアントの接続の 1 段目（`/sessions/connect`）。
  ConnectClient
  /// 確認のダイアログからの接続（`/sessions/connect/confirm`）。
  ConfirmConnection
  /// プラグインの再有効化（`/plugins/reenable`）。
  ReenablePlugin
  /// アカウントの読み直し（`/accounts/reload`）。
  ReloadAccounts
  /// リレーの追加（`/relays/new`）。
  NewRelay
  /// 鍵の生成（`/accounts/generate`）。
  GenerateAccount
  /// nsec による登録（`/accounts/import`）。
  ImportAccount
  /// 生成した鍵の登録（`/accounts/register-generated`）。
  RegisterGeneratedAccount
  /// アカウント 1 件への操作（`/accounts/<signer>/<操作>`）。
  AccountOperation(signer: String, action: AccountAction)
  /// リレー 1 件への操作（`/relays/<id>/<操作>`）。
  RelayOperation(id: Int, action: RelayAction)
  /// プラグインのページ（`/plugins/<プラグイン名>/<ページのキー>`）。名前は percent-decode した値。
  ShowPluginPage(plugin: String, page: String)
  /// セッションの権限の保存（`/sessions/<signer>/<client>/permissions`）。
  SessionPermissions(signer: String, client: String)
}

/// アカウントの POST 先のパスの先頭のセグメント。
const accounts_segment = "accounts"

/// リレーの POST 先のパスの先頭のセグメント。
const relays_segment = "relays"

/// プラグインのページのパスの先頭のセグメント。
const plugins_segment = "plugins"

/// 承認ページのパスの先頭のセグメント。
const approve_segment = "approve"

/// 拒否のパスの先頭のセグメント。
const deny_segment = "deny"

/// セッションの POST 先のパスの先頭のセグメント。
const sessions_segment = "sessions"

/// セッションの取り消しの操作の語。POST 先のパスの末尾と、取り消しのダイアログの `id` に使う。
pub const revoke_segment = "revoke"

/// 操作のパスセグメント。
pub fn account_action_segment(action: AccountAction) -> String {
  case action {
    EditLabel -> "label"
    RotateSecret -> "rotate"
    DeleteAccount -> "delete"
    RevealPrivateKey -> "private-key"
  }
}

/// 操作のパスセグメント。
pub fn relay_action_segment(action: RelayAction) -> String {
  case action {
    EditRelayRoles -> "edit"
    DeleteRelay -> "delete"
  }
}

/// 操作の一覧 `actions` から、パスセグメントが `segment` の操作を引く。無ければ Error。
fn action_for_segment(
  actions: List(action),
  to_segment: fn(action) -> String,
  segment: String,
) -> Result(action, Nil) {
  list.find(actions, fn(action) { to_segment(action) == segment })
}

/// セッションの権限の保存の POST 先のパスの末尾のセグメント。
pub const session_permissions_segment = "permissions"

/// 引数を持たないルート。`parse` が最初に、`route_segments` がパスセグメントと完全に一致するものを
/// 引く。
const fixed_routes = [
  ShowDashboard,
  Stylesheet,
  Script,
  SwitchLanguage,
  SwitchTheme,
  RevokeSession,
  ConnectClient,
  ConfirmConnection,
  ReenablePlugin,
  ReloadAccounts,
  NewRelay,
  GenerateAccount,
  ImportAccount,
  RegisterGeneratedAccount,
]

/// ルートのパスセグメント。`path` と `href` の組み立てと、`parse` の引数を持たないルートの照合が
/// 見る定義。引数はそのまま入れ、符号化しない。
fn route_segments(route: Route) -> List(String) {
  case route {
    ShowDashboard -> []
    Stylesheet -> ["static", "admin.css"]
    Script -> ["static", "admin.js"]
    SwitchLanguage -> ["language"]
    SwitchTheme -> ["theme"]
    ApproveConnection(token) -> [approve_segment, token]
    DenyConnection(token) -> [deny_segment, token]
    RevokeSession -> [sessions_segment, revoke_segment]
    ConnectClient -> [sessions_segment, "connect"]
    ConfirmConnection -> [sessions_segment, "connect", "confirm"]
    ReenablePlugin -> [plugins_segment, "reenable"]
    ReloadAccounts -> [accounts_segment, "reload"]
    NewRelay -> [relays_segment, "new"]
    GenerateAccount -> [accounts_segment, "generate"]
    ImportAccount -> [accounts_segment, "import"]
    RegisterGeneratedAccount -> [accounts_segment, "register-generated"]
    AccountOperation(signer, action) -> [
      accounts_segment,
      signer,
      account_action_segment(action),
    ]
    RelayOperation(id, action) -> [
      relays_segment,
      int.to_string(id),
      relay_action_segment(action),
    ]
    ShowPluginPage(plugin, page) -> [plugins_segment, plugin, page]
    SessionPermissions(signer, client) -> [
      sessions_segment,
      signer,
      client,
      session_permissions_segment,
    ]
  }
}

/// ルートのパス。`route_segments` を `/` から連結した値で、プラグイン名も符号化しない。テーマと
/// 言語の切り替えの戻り先（`view.SwitchReturningTo`）に渡す値で、受け取る側（`admin.return_path`）が
/// セグメントを自分で percent-encode するので、符号化済みの `href` を渡すと二重になる。リンクと
/// フォームの宛先には `href` を使う。
pub fn path(route: Route) -> String {
  "/" <> string.join(route_segments(route), "/")
}

/// ルートへのリンク、フォームの宛先、リダイレクト先のパス。`path` と同じだが、プラグインのページ
/// だけはプラグイン名を percent-encode する（`plugin_name/0` は任意の文字列でよく、
/// `wisp.path_segments` は percent-decode しないため。ページのキーは `[a-z0-9_-]+` に限られている
/// ので符号化しない）。`parse` は `href` を `/` で分けたセグメントから元のルートに戻す。
pub fn href(route: Route) -> String {
  case route {
    ShowPluginPage(plugin, page) ->
      path(ShowPluginPage(uri.percent_encode(plugin), page))
    _ -> path(route)
  }
}

/// パスセグメント（`wisp.path_segments` の値）からルートを引く。引数を持たないルートは
/// `fixed_routes` のうち `route_segments` が完全に一致するものを選ぶ。承認と拒否は 2 つ目の
/// セグメントを token にし、
/// アカウントの操作は操作のセグメントが `account_actions` にあるとき、リレーの操作は id が
/// 整数として読めて操作のセグメントが `relay_actions` にあるとき、プラグインのページは
/// プラグイン名が percent-decode できるとき、セッションの権限は末尾が
/// `session_permissions_segment` のときに選ぶ。署名者、token、クライアント、ページのキーの
/// 値は検査しない（一覧との照合は呼び出し側が行う）。どれにも当たらなければ Error。
pub fn parse(segments: List(String)) -> Result(Route, Nil) {
  use <- result.lazy_or(
    list.find(fixed_routes, fn(route) { route_segments(route) == segments }),
  )
  case segments {
    [first, token] if first == approve_segment -> Ok(ApproveConnection(token))
    [first, token] if first == deny_segment -> Ok(DenyConnection(token))
    [first, signer, segment] if first == accounts_segment ->
      action_for_segment(account_actions, account_action_segment, segment)
      |> result.map(AccountOperation(signer, _))
    [first, id, segment] if first == relays_segment -> {
      use id <- result.try(int.parse(id))
      action_for_segment(relay_actions, relay_action_segment, segment)
      |> result.map(RelayOperation(id, _))
    }
    [first, plugin, page] if first == plugins_segment ->
      uri.percent_decode(plugin) |> result.map(ShowPluginPage(_, page))
    [first, signer, client, last]
      if first == sessions_segment && last == session_permissions_segment
    -> Ok(SessionPermissions(signer, client))
    _ -> Error(Nil)
  }
}
