//// 管理 UI のパスの定義。ページとフォームとページ枠（スタイルシート、スクリプト、テーマと
//// 言語の切り替え）のパスセグメントの定数、パスの組み立て、パスの引数になるアカウントと
//// リレーへの操作の型と、パスセグメントから引くルートの型（`Route`）とその解析（`parse`）を
//// 置く。ルーティング（`admin`）は `parse` の結果でハンドラーを選び、リンクとフォームの宛先は
//// 同じ定数から `segments_path` で組み立てる。描画のモジュール（`admin/view`、
//// `admin/dashboard`）がここを import するので、ここは描画のモジュールを import しない。

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
  /// ビルドしたスタイルシート（`stylesheet_segments`）。
  Stylesheet
  /// 管理 UI のスクリプト（`script_segments`）。
  Script
  /// 言語の切り替え（`language_segments`）。
  SwitchLanguage
  /// テーマの切り替え（`theme_segments`）。
  SwitchTheme
  /// 承認ページと承認（`/approve/<token>`）。
  ApproveConnection(token: String)
  /// 拒否（`/deny/<token>`）。
  DenyConnection(token: String)
  /// セッションの取り消し（`revoke_segments`）。
  RevokeSession
  /// クライアントの接続の 1 段目（`connect_segments`）。
  ConnectClient
  /// 確認のダイアログからの接続（`connect_confirm_segments`）。
  ConfirmConnection
  /// プラグインの再有効化（`reenable_plugin_segments`）。
  ReenablePlugin
  /// アカウントの読み直し（`reload_accounts_segments`）。
  ReloadAccounts
  /// リレーの追加（`new_relay_segments`）。
  NewRelay
  /// 鍵の生成（`generate_account_segments`）。
  GenerateAccount
  /// nsec による登録（`import_account_segments`）。
  ImportAccount
  /// 生成した鍵の登録（`register_generated_segments`）。
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

/// アカウントの読み直しの POST 先のパスセグメント。
pub const reload_accounts_segments = [accounts_segment, "reload"]

/// リレーの追加の POST 先のパスセグメント。
pub const new_relay_segments = [relays_segment, "new"]

/// 鍵の生成の POST 先のパスセグメント。
pub const generate_account_segments = [accounts_segment, "generate"]

/// nsec による登録の POST 先のパスセグメント。
pub const import_account_segments = [accounts_segment, "import"]

/// 生成した鍵の登録の POST 先のパスセグメント。
pub const register_generated_segments = [accounts_segment, "register-generated"]

/// セッションの POST 先のパスの先頭のセグメント。
const sessions_segment = "sessions"

/// セッションの取り消しの操作の語。POST 先のパスの末尾と、取り消しのダイアログの `id` に使う。
pub const revoke_segment = "revoke"

/// セッション取り消しの POST 先のパスセグメント。
pub const revoke_segments = [sessions_segment, revoke_segment]

/// クライアントの接続の 1 段目の送信先のパスセグメント。
pub const connect_segments = [sessions_segment, "connect"]

/// クライアントの接続の確認のダイアログから、接続を送るパス。
pub const connect_confirm_segments = [sessions_segment, "connect", "confirm"]

/// プラグインの再有効化の POST 先のパスセグメント。
pub const reenable_plugin_segments = [plugins_segment, "reenable"]

/// ビルドした管理 UI のスタイルシートの URL のパスセグメント。解析（`parse`）と
/// ページ枠の `link` が同じ定義を見る。配信する `wisp.serve_static` はこの定数ではなく要求の
/// パスから `priv` の下のファイルを引くので、このセグメントは `priv` の中の配置
/// （`priv/static/admin.css`）、`package.json` の `build:css` の出力先、`stylesheet_test` が
/// 読むパスと一致させる。
pub const stylesheet_segments = ["static", "admin.css"]

/// 管理 UI のスクリプトの URL のパスセグメント。解析（`parse`）とページ枠の `script` が
/// 同じ定義を見る。`stylesheet_segments` と同じく要求のパスから `priv` の下のファイルを引くので、
/// `priv` の中の配置（`priv/static/admin.js`）と一致させる。
pub const script_segments = ["static", "admin.js"]

/// 言語の切り替えの POST 先のパスセグメント。解析（`parse`）とナビゲーション
/// バーのフォームが同じ定義を見る。
pub const language_segments = ["language"]

/// テーマの切り替えの POST 先のパスセグメント。解析（`parse`）とナビゲーション
/// バーのフォームが同じ定義を見る。
pub const theme_segments = ["theme"]

/// パスセグメントを `/` から連結したパス。`parse` が照合するのと同じセグメントの定義から、
/// リンク、フォームの宛先、スタイルシートの `href` のパスを組み立てる。
pub fn segments_path(segments: List(String)) -> String {
  "/" <> string.join(segments, "/")
}

/// 操作のパスセグメント。
pub fn account_action_segment(action: AccountAction) -> String {
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

/// 操作のパスセグメント。
pub fn relay_action_segment(action: RelayAction) -> String {
  case action {
    EditRelayRoles -> "edit"
    DeleteRelay -> "delete"
  }
}

/// 操作のパス（`/relays/<id>/<segment>`）。
pub fn relay_action_path(id: Int, action: RelayAction) -> String {
  segments_path([
    relays_segment,
    int.to_string(id),
    relay_action_segment(action),
  ])
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

/// セッションの権限の保存のパス（`/sessions/<signer>/<client>/permissions`）。
pub fn session_permissions_path(signer: String, client: String) -> String {
  segments_path([
    sessions_segment,
    signer,
    client,
    session_permissions_segment,
  ])
}

/// プラグインのページのパス（`/plugins/<プラグイン名>/<ページのキー>`）。符号化しない
/// 素のパスで、`view.SwitchReturningTo` に渡す値。リンクの `href` には
/// `plugin_page_href` を使う。
pub fn plugin_page_path(plugin: String, page: String) -> String {
  segments_path([plugins_segment, plugin, page])
}

/// プラグインのページへのリンクのパス。`plugin_name/0` は任意の文字列でよく
/// `wisp.path_segments` は percent-decode しないため、プラグイン名だけを
/// percent-encode する（ページのキーは `[a-z0-9_-]+` に限られているので符号化
/// しない）。`return` には `plugin_page_path` を渡すこと。`admin.return_path`
/// が自分でセグメントを符号化するため、符号化済みの値を渡すと二重になる。
pub fn plugin_page_href(plugin: String, page: String) -> String {
  segments_path([plugins_segment, uri.percent_encode(plugin), page])
}

/// 承認ページのパス。`auth_url` としてクライアントへ渡す URL も、このパスに
/// 公開 URL を前置して組み立てる。
pub fn approve_path(token: String) -> String {
  segments_path([approve_segment, token])
}

/// 拒否のパス。承認ページと違い、POST でしか使わない。
pub fn deny_path(token: String) -> String {
  segments_path([deny_segment, token])
}

/// 引数を持たないルートと、そのパスセグメント。`parse` が最初に完全一致で引く。
const fixed_routes = [
  #([], ShowDashboard),
  #(stylesheet_segments, Stylesheet),
  #(script_segments, Script),
  #(language_segments, SwitchLanguage),
  #(theme_segments, SwitchTheme),
  #(revoke_segments, RevokeSession),
  #(connect_segments, ConnectClient),
  #(connect_confirm_segments, ConfirmConnection),
  #(reenable_plugin_segments, ReenablePlugin),
  #(reload_accounts_segments, ReloadAccounts),
  #(new_relay_segments, NewRelay),
  #(generate_account_segments, GenerateAccount),
  #(import_account_segments, ImportAccount),
  #(register_generated_segments, RegisterGeneratedAccount),
]

/// パスセグメント（`wisp.path_segments` の値）からルートを引く。引数を持たないルートは
/// `fixed_routes` と完全に一致したときに選ぶ。承認と拒否は 2 つ目のセグメントを token にし、
/// アカウントの操作は操作のセグメントが `account_actions` にあるとき、リレーの操作は id が
/// 整数として読めて操作のセグメントが `relay_actions` にあるとき、プラグインのページは
/// プラグイン名が percent-decode できるとき、セッションの権限は末尾が
/// `session_permissions_segment` のときに選ぶ。署名者、token、クライアント、ページのキーの
/// 値は検査しない（一覧との照合は呼び出し側が行う）。どれにも当たらなければ Error。
pub fn parse(segments: List(String)) -> Result(Route, Nil) {
  use <- result.lazy_or(list.key_find(fixed_routes, segments))
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
