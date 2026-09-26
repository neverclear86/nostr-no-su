//// 管理 UI のページとフォームのパスの定義。パスセグメントの定数、パスの組み立て、
//// パスセグメントからの解析と、パスの引数になるアカウントとリレーへの操作の型を置く。
//// ルーティングとリンクがここの同じ定義を見て、`/` からの組み立ては `view.segments_path` に
//// 任せる。描画のモジュール（`admin/dashboard`）がここを import するので、ここは描画の
//// モジュールを import しない。

import gleam/int
import gleam/list
import gleam/result
import gleam/uri
import nostr_no_su/admin/view

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

/// アカウントの POST 先のパスの先頭のセグメント。
const accounts_segment = "accounts"

/// リレーの POST 先のパスの先頭のセグメント。
const relays_segment = "relays"

/// プラグインのページのパスの先頭のセグメント。
const plugins_segment = "plugins"

/// 承認ページのパスの先頭のセグメント。
pub const approve_segment = "approve"

/// 拒否のパスの先頭のセグメント。
pub const deny_segment = "deny"

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
  view.segments_path([accounts_segment, signer, account_action_segment(action)])
}

/// パスセグメントから、アカウント 1 件への操作の署名者と操作を引く。操作のパスで
/// なければ Error。署名者の値は検査しない（一覧との照合は呼び出し側が行う）。
pub fn parse_account_action_path(
  segments: List(String),
) -> Result(#(String, AccountAction), Nil) {
  case segments {
    [first, signer, segment] if first == accounts_segment ->
      action_for_segment(account_actions, account_action_segment, segment)
      |> result.map(fn(action) { #(signer, action) })
    _ -> Error(Nil)
  }
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
  view.segments_path([
    relays_segment,
    int.to_string(id),
    relay_action_segment(action),
  ])
}

/// パスセグメントから、リレー 1 件への操作の DB の行の id と操作を引く。id が整数として
/// 読めなければ Error。行との照合は呼び出し側が行う。
pub fn parse_relay_action_path(
  segments: List(String),
) -> Result(#(Int, RelayAction), Nil) {
  case segments {
    [first, id, segment] if first == relays_segment -> {
      use id <- result.try(int.parse(id))
      action_for_segment(relay_actions, relay_action_segment, segment)
      |> result.map(fn(action) { #(id, action) })
    }
    _ -> Error(Nil)
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

/// セッションの権限の保存のパス（`/sessions/<signer>/<client>/permissions`）。
pub fn session_permissions_path(signer: String, client: String) -> String {
  view.segments_path([
    sessions_segment,
    signer,
    client,
    session_permissions_segment,
  ])
}

/// パスセグメントから、セッションの権限の保存のパスの署名者とクライアントを引く。値は
/// 検査しない（一覧との照合は呼び出し側が行う）。
pub fn parse_session_permissions_path(
  segments: List(String),
) -> Result(#(String, String), Nil) {
  case segments {
    [first, signer, client, last]
      if first == sessions_segment && last == session_permissions_segment
    -> Ok(#(signer, client))
    _ -> Error(Nil)
  }
}

/// プラグインのページのパス（`/plugins/<プラグイン名>/<ページのキー>`）。符号化しない
/// 素のパスで、`view.SwitchReturningTo` に渡す値。リンクの `href` には
/// `plugin_page_href` を使う。
pub fn plugin_page_path(plugin: String, page: String) -> String {
  view.segments_path([plugins_segment, plugin, page])
}

/// プラグインのページへのリンクのパス。`plugin_name/0` は任意の文字列でよく
/// `wisp.path_segments` は percent-decode しないため、プラグイン名だけを
/// percent-encode する（ページのキーは `[a-z0-9_-]+` に限られているので符号化
/// しない）。`return` には `plugin_page_path` を渡すこと。`admin.return_path`
/// が自分でセグメントを符号化するため、符号化済みの値を渡すと二重になる。
pub fn plugin_page_href(plugin: String, page: String) -> String {
  view.segments_path([plugins_segment, uri.percent_encode(plugin), page])
}

/// パスセグメントから、プラグインのページのプラグイン名とキーを引く。プラグイン名は
/// percent-decode し、失敗すれば `Error(Nil)`。一覧との照合は呼び出し側が行う。
pub fn parse_plugin_page_path(
  segments: List(String),
) -> Result(#(String, String), Nil) {
  case segments {
    [first, name, key] if first == plugins_segment -> {
      use name <- result.try(uri.percent_decode(name))
      Ok(#(name, key))
    }
    _ -> Error(Nil)
  }
}

/// 承認ページのパス。`auth_url` としてクライアントへ渡す URL も、このパスに
/// 公開 URL を前置して組み立てる。
pub fn approve_path(token: String) -> String {
  view.segments_path([approve_segment, token])
}

/// 拒否のパス。承認ページと違い、POST でしか使わない。
pub fn deny_path(token: String) -> String {
  view.segments_path([deny_segment, token])
}
