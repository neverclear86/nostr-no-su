//// admin_*_test が共有する、状態を即値で持つ `admin.Context` と認証済みの
//// リクエストを組み立てるヘルパー。関数名の注意は `app_tree` と同じ。

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/nostrconnect
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_config
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import wisp
import wisp/simulate

/// 管理 UI のパスワード。`test_context` が Context に入れ、Basic 認証と再表示の入力に使う。
pub const password = "s3cr3t-password"

/// 認証の失敗のログ行に入る接続元。本物のサーバーは mist の接続情報から入れる。
pub const client_address = "203.0.113.5"

/// 登録済みのアカウントの署名者。BIP-340 の公式ベクター 0 の公開鍵。
pub const signer = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

/// 登録済みのアカウントの npub。
pub const signer_npub = "npub1lycg5qvjtrp3qjf5f7zl382j9x6nrjz9sdhenvyxq8c3808qxmus6gq266"

/// 登録済みのアカウントの nsec（BIP-340 の公式ベクター 0 の秘密鍵）。
pub const signer_nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re"

/// 未登録のアカウントとして登録に使う、NIP-19 の仕様の nsec。
pub const spec_nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

/// セッション一覧に出るクライアント。公開鍵の代わりに短い値を使う。
pub const client = "bbbb2222"

/// セッション一覧の 2 件目のクライアント。権限を宣言して承認したセッションで、
/// 権限の編集のテストが使う。
pub const declared_client = "eeee5555"

/// フェイクの取り消しが、承認済みでない組に返す理由。
pub const session_not_approved = "session is not approved"

/// 無効化されたプラグインの理由。プラグイン由来の文字列なので HTML への埋め込み
/// でエスケープされなければならない。
const disabled_reason = "error:<script>alert(1)</script>"

/// `console_logger` の `settings` ページの中身の呼び出しが返す理由。
pub const plugin_page_unavailable_reason = "settings unavailable"

/// `console_logger` の `settings` ページの実行への送信で、この欄が送られると
/// 拒否する。値が拒否の理由になる。
pub const plugin_action_reject_field = "reject"

/// `console_logger` の `status` ページの記述。節 1 つ、ブロック 1 つ（`text`）を持つ。
fn console_logger_status_description() -> Dynamic {
  dynamic.properties([
    #(
      dynamic.string("sections"),
      dynamic.list([
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("section")),
          #(dynamic.string("title"), dynamic.string("Queue")),
          #(
            dynamic.string("blocks"),
            dynamic.list([
              dynamic.properties([
                #(dynamic.string("type"), dynamic.string("text")),
                #(dynamic.string("text"), dynamic.string("processed 3 events")),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

/// プラグインのページの中身。`console_logger` の `status` は記述を返し、`settings`
/// は理由を返す（応答の失敗を試すため）。それ以外は名前が引けないという理由を返す。
/// 登録アカウントの一覧は使わない。
fn plugin_page_content(
  name: String,
  key: String,
  _language: i18n.Language,
  _accounts: List(plugin_config.PageAccount),
) -> Result(Dynamic, String) {
  case name, key {
    "console_logger", "status" -> Ok(console_logger_status_description())
    "console_logger", "settings" -> Error(plugin_page_unavailable_reason)
    _, _ -> Error("plugin not found")
  }
}

/// フォームの送信を受け取る実行の口。`console_logger` の `settings` だけが持つ。
/// `plugin_action_reject_field` が送られればその値を理由に拒否し、それ以外は
/// 成功する。
fn plugin_page_action(
  name: String,
  key: String,
) -> Option(
  fn(List(#(String, String)), List(plugin_config.PageAccount)) ->
    Result(Nil, String),
) {
  case name, key {
    "console_logger", "settings" ->
      Some(fn(values, _accounts) {
        case list.key_find(values, plugin_action_reject_field) {
          Ok(reason) -> Error(reason)
          Error(Nil) -> Ok(Nil)
        }
      })
    _, _ -> None
  }
}

/// 承認待ちのトークン。フェイクの一覧（`pending`）はこれだけを持つ。
pub const token = "tok-1"

/// secret 入りの接続 URI。
pub const uri = "bunker://f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9?relay=x&secret=s"

/// 承認を経る接続 URI（secret なし）。
pub const auth_uri = "bunker://f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9?relay=x"

/// アカウントのラベル。
pub const label = "main account"

/// DB の障害でアカウントの一覧を得られないときの理由。本物の一覧の文言に合わせる。
pub const unavailable = "account store unavailable: database is unreachable or rejected the connection"

/// フェイクのハンドラーがテストへ報告する内容。
pub type Report {
  Revoked(signer: String, client: String)
  PermissionsSaved(signer: String, client: String, perms: String)
  Approved(token: String)
  Denied(token: String)
  Added(signer: String, label: String)
  Removed(signer: String)
  Rotated(signer: String)
  Relabeled(signer: String, label: String)
  NsecRequested(signer: String)
  Reenabled(name: String)
  AccountsReloaded
  RelayAdded(url: String, roles: relay_list.Roles)
  RelayRolesUpdated(id: Int, roles: relay_list.Roles)
  RelayDeleted(id: Int)
  ClientConnectRequested(request: nostrconnect.ConnectRequest, signer: String)
}

/// 指定したラベルを持つ、登録済みのアカウントの行。
pub fn account_row(row_label: String) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer: signer,
    npub: signer_npub,
    label: row_label,
    uri: uri,
    auth_uri: auth_uri,
  )
}

/// 状態をすべて即値で持つ Context。アクターを起動せずにルートを検証できる。
/// 監視リレーの URL だけはエスケープの検証のために差し替えられる。アカウントの変更は
/// 報告したうえで成功し、登録済みの公開鍵の追加だけを拒否する。
pub fn test_context(
  reports: Subject(Report),
  monitor_relay_url: String,
) -> admin.Context {
  admin.Context(
    password: password,
    client_address: client_address,
    authentication_delay: fn() { Nil },
    accounts: fn() { Ok([account_row(label)]) },
    skipped: fn() { Ok([]) },
    add_account: fn(added, added_label) {
      let added_signer = account.pubkey_hex(added)
      process.send(reports, Added(added_signer, added_label))
      case added_signer == signer {
        True -> Error(bunker.AccountAlreadyRegistered)
        False -> Ok(Nil)
      }
    },
    remove_account: fn(removed) {
      process.send(reports, Removed(removed))
      Ok(Nil)
    },
    rotate_secret: fn(rotated) {
      process.send(reports, Rotated(rotated))
      Ok(Nil)
    },
    update_label: fn(relabeled, new_label) {
      process.send(reports, Relabeled(relabeled, new_label))
      Ok(Nil)
    },
    nsec: fn(requested) {
      process.send(reports, NsecRequested(requested))
      Ok(signer_nsec)
    },
    reload_accounts: fn() {
      process.send(reports, AccountsReloaded)
      Ok(Nil)
    },
    relays: fn(_deadline) {
      Ok([
        dashboard.RelayRow(
          id: 1,
          url: monitor_relay_url,
          monitor: dashboard.Reported(relay_connection.Connected),
          bunker: dashboard.Unused,
        ),
        dashboard.RelayRow(
          id: 2,
          url: "wss://bunker.example",
          monitor: dashboard.Unused,
          bunker: dashboard.Reported(relay_connection.Disconnected),
        ),
      ])
    },
    add_relay: fn(added_url, added_roles) {
      process.send(reports, RelayAdded(added_url, added_roles))
      case added_url == "wss://bunker.example" {
        True -> Error(admin.DuplicateRelay)
        False -> Ok(Nil)
      }
    },
    registered_relays: fn() {
      Ok([
        relay_store.Relay(
          id: 1,
          url: monitor_relay_url,
          roles: relay_list.Roles(monitor: True, bunker: False),
        ),
        relay_store.Relay(
          id: 2,
          url: "wss://bunker.example",
          roles: relay_list.Roles(monitor: False, bunker: True),
        ),
      ])
    },
    update_relay_roles: fn(relay, roles) {
      process.send(reports, RelayRolesUpdated(relay.id, roles))
      Ok(Nil)
    },
    delete_relay: fn(relay) {
      process.send(reports, RelayDeleted(relay.id))
      Ok(Nil)
    },
    connect_client: fn(request, connecting_signer) {
      process.send(reports, ClientConnectRequested(request, connecting_signer))
      Ok(Nil)
    },
    plugins: fn(_deadline) {
      [
        dashboard.PluginRow(
          name: "console_logger",
          status: Some(plugin_runner.Running),
          pages: [
            plugin.PluginPage(key: "status", title: "Status"),
            plugin.PluginPage(key: "settings", title: "Settings"),
          ],
        ),
        // 無効化の理由はプラグイン由来の文字列なので、素のまま出てはならない。
        // ページを供給しないので、404 の検査にも使う。
        dashboard.PluginRow(
          name: "broken",
          status: Some(plugin_runner.Disabled(
            reason: disabled_reason,
            dropped: 3,
          )),
          pages: [],
        ),
      ]
    },
    not_loaded_plugins: [],
    reenable_plugin: fn(name) {
      process.send(reports, Reenabled(name))
      Ok(Nil)
    },
    plugin_page_content: plugin_page_content,
    page_accounts: fn() { Ok([]) },
    plugin_page_action: plugin_page_action,
    sessions: fn() {
      Ok([
        dashboard.SessionRow(
          signer: signer,
          client: client,
          perms: "",
          created_at: 1000,
          last_used_at: 1000,
        ),
        dashboard.SessionRow(
          signer: signer,
          client: declared_client,
          perms: "sign_event:1,nip04_encrypt",
          created_at: 1000,
          last_used_at: 900,
        ),
      ])
    },
    revoke: fn(revoked_signer, revoked_client) {
      process.send(
        reports,
        Revoked(signer: revoked_signer, client: revoked_client),
      )
      case revoked_signer == signer && revoked_client == client {
        True -> Ok(Nil)
        False -> Error(bunker.SessionNotFound(session_not_approved))
      }
    },
    update_perms: fn(updated_signer, updated_client, perms) {
      process.send(
        reports,
        PermissionsSaved(
          signer: updated_signer,
          client: updated_client,
          perms: perms,
        ),
      )
      case updated_signer == signer && updated_client == declared_client {
        True -> Ok(Nil)
        False -> Error(bunker.SessionNotFound(session_not_approved))
      }
    },
    pending: fn() {
      Ok([
        dashboard.PendingRow(
          token: token,
          signer: signer,
          client: client,
          expires_in_seconds: 540,
          secret_mismatch: False,
          perms: "",
        ),
      ])
    },
    approve: fn(decided) { record_decision(reports, Approved(decided)) },
    deny: fn(decided) { record_decision(reports, Denied(decided)) },
  )
}

/// 承認・拒否のフェイク。テストへ報告したうえで成功する。承認待ちの一覧に無い
/// トークンはハンドラーが呼び出す前に 404 にするので、ここには届かない。
fn record_decision(
  reports: Subject(Report),
  report: Report,
) -> Result(Nil, bunker.SessionFailure) {
  process.send(reports, report)
  Ok(Nil)
}

/// 状態を変える操作を報告する Context。
pub fn reporting_context(reports: Subject(Report)) -> admin.Context {
  test_context(reports, "wss://relay.example")
}

/// 報告を捨てる Context。操作を観測しないテスト向け。
pub fn context() -> admin.Context {
  reporting_context(process.new_subject())
}

/// アカウントの変更がすべて指定した失敗を返す Context。
pub fn failing_context(failure: bunker.ChangeFailure) -> admin.Context {
  admin.Context(
    ..context(),
    add_account: fn(_added, _label) { Error(failure) },
    remove_account: fn(_signer) { Error(failure) },
    rotate_secret: fn(_signer) { Error(failure) },
    update_label: fn(_signer, _label) { Error(failure) },
  )
}

/// 認証済みの POST リクエストを 1 件処理する。本文は空で、承認・拒否はパスの
/// トークンだけで決まる。
pub fn post(context: admin.Context, path: String) -> Response(wisp.Body) {
  simulate.request(http.Post, path)
  |> with_credentials("admin", context.password)
  |> admin.handle_request(context, _)
}

/// 認証済みのフォームの POST リクエストを 1 件処理する。
pub fn post_form(
  context: admin.Context,
  path: String,
  fields: List(#(String, String)),
) -> Response(wisp.Body) {
  simulate.request(http.Post, path)
  |> with_credentials("admin", context.password)
  |> simulate.form_body(fields)
  |> admin.handle_request(context, _)
}

/// Basic 認証のヘッダーを付けたリクエスト。
pub fn with_credentials(
  request: wisp.Request,
  user: String,
  password: String,
) -> wisp.Request {
  let credentials =
    bit_array.from_string(user <> ":" <> password)
    |> bit_array.base64_encode(True)
  request.set_header(request, "authorization", "Basic " <> credentials)
}

/// 認証済みの GET リクエストを 1 件処理する。
pub fn get(context: admin.Context, path: String) -> Response(wisp.Body) {
  simulate.request(http.Get, path)
  |> with_credentials("admin", context.password)
  |> admin.handle_request(context, _)
}

/// 応答ヘッダーの値。存在しなければテストを失敗させる。
pub fn header(response: Response(wisp.Body), name: String) -> String {
  let assert Ok(value) = list.key_find(response.headers, name)
  value
}

/// 登録済みのアカウントへの操作のパス。
pub fn action_path(action: dashboard.AccountAction) -> String {
  dashboard.account_action_path(signer, action)
}

/// 取り消しにバンカーが応答しない Context。
pub fn not_answering_context() -> admin.Context {
  admin.Context(..context(), revoke: fn(_signer, _client) {
    Error(bunker.SessionMaybeApplied(bunker.BunkerDidNotRespond))
  })
}

/// 指定したアカウントの一覧を返す Context。
pub fn with_accounts(
  accounts: Result(List(dashboard.AccountRow), String),
) -> admin.Context {
  admin.Context(..context(), accounts: fn() { accounts })
}

/// プラグインのページと実行の呼び出しに渡す登録アカウントの一覧を指定した
/// Context。
pub fn with_page_accounts(
  accounts: Result(List(plugin_config.PageAccount), String),
) -> admin.Context {
  admin.Context(..context(), page_accounts: fn() { accounts })
}

/// 読み込みで飛ばされた行の公開鍵。登録済みの `signer` とは違う値。
pub const skipped_pubkey = "dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444"

/// `skipped_pubkey` の npub。
pub const skipped_npub = "npub1mhw5g3xam4zyfhwag3zdmh2ygnwa63zymhw5g3xam4zyfhwag3zqqkw2rx"

/// 読み込みで飛ばされた行 1 件（`MalformedPubkey` 以外）。
pub fn skipped_row() -> dashboard.SkippedRow {
  dashboard.SkippedRow(
    pubkey: skipped_pubkey,
    npub: skipped_npub,
    label: "old wallet",
    reason: vault.UndecryptablePrivateKey,
  )
}

/// 指定した、読み込みで飛ばされた行の一覧を返す Context。
pub fn with_skipped(
  skipped: Result(List(dashboard.SkippedRow), String),
) -> admin.Context {
  admin.Context(..context(), skipped: fn() { skipped })
}

/// `Accept-Language` で日本語を求めるリクエスト。
pub fn in_japanese(request: wisp.Request) -> wisp.Request {
  request.set_header(request, "accept-language", "ja")
}
