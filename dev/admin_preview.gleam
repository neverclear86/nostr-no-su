//// 管理 UI を固定の状態で起動する撮影用のサーバー。`admin.handle_request` を本物のまま
//// 使い、`Context` の関数だけを固定の値に差し替える。待ち受けるのは `PREVIEW_PORT`
//// （既定は 18461）から続く 3 つのポートで、順に通常の状態、アカウント・承認待ち・
//// セッションの一覧を得られない状態、すべての一覧が空の状態である。
//// `gleam run -m admin_preview` で起動し、`dev/screenshots.mjs` で撮る。
////
//// `dev/` は `gleam build` と `gleam test` でコンパイルされるので、`Context` を変えて
//// ここを直し忘れると CI で落ちる。`gleam export erlang-shipment` の成果物には入らない。
//// 管理パスワードは固定の値で、鍵は公開のテストベクター、secret はダミーの値である。

import envoy
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection

/// 使い捨ての管理パスワード。
const password = "preview-password"

/// 待ち受けの先頭のポートの既定値。
const default_port = 18_461

/// BIP-340 の公式ベクター 0 の公開鍵。
const signer = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

/// `signer` の npub。
const signer_npub = "npub1lycg5qvjtrp3qjf5f7zl382j9x6nrjz9sdhenvyxq8c3808qxmus6gq266"

/// BIP-340 の公式ベクター 0 の秘密鍵の nsec。
const signer_nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re"

/// NIP-19 の仕様の公開鍵。
const second = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"

/// `second` の npub。
const second_npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

/// 接続してきたクライアントの公開鍵（ダミー）。
const client = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"

/// 接続 URI の relay= の部分。
const relay = "relay=ws%3A%2F%2F127.0.0.1%3A7801"

/// 固定の行。secret はダミーの値。
fn row(signer: String, npub: String, label: String) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer:,
    npub:,
    label:,
    uri: "bunker://"
      <> signer
      <> "?"
      <> relay
      <> "&secret=0123456789abcdef0123456789abcdef",
    auth_uri: "bunker://" <> signer <> "?" <> relay,
  )
}

/// ラベルの値で、ラベルの変更の結果を選ぶ。
fn change(label: String) -> Result(Nil, bunker.ChangeFailure) {
  case label {
    "not-applied" -> Error(bunker.NotApplied("account is not registered"))
    "not-ready" -> Error(bunker.NotReady("accounts are not loaded yet"))
    "maybe" -> Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
    _ -> Ok(Nil)
  }
}

/// クライアントの値で、取り消しの結果を選ぶ。
fn revocation(revoked_client: String) -> Result(Nil, bunker.SessionFailure) {
  case revoked_client {
    "not-approved" -> Error(bunker.SessionNotFound("session is not approved"))
    "not-applied" -> Error(bunker.SessionNotApplied("not written"))
    "not-ready" -> Error(bunker.SessionNotReady("accounts are not loaded yet"))
    "no-answer" -> Error(bunker.SessionMaybeApplied(bunker.BunkerDidNotRespond))
    _ -> Ok(Nil)
  }
}

/// プラグイン名の値で、再有効化の結果を選ぶ。
fn reenabling(plugin: String) -> Result(Nil, admin.ReenableFailure) {
  case plugin {
    "missing" -> Error(admin.PluginNotFound("plugin not found"))
    "no-answer" ->
      Error(admin.PluginNotAnswered("plugin runner did not answer"))
    _ -> Ok(Nil)
  }
}

/// 通常の状態の Context。削除は常に「反映されていない」（409）を返す。登録は
/// `signer` の鍵なら「反映されていない」（409）、ラベルが `not-ready` / `maybe` なら
/// それぞれ 503 / 202 を返す（生成した鍵の確認ページの撮影用）。
fn context() -> admin.Context {
  admin.Context(
    password:,
    accounts: fn() {
      Ok([
        row(signer, signer_npub, "main account"),
        row(second, second_npub, "<b>bot</b> 🙂"),
      ])
    },
    add_account: fn(added, label) {
      case account.pubkey_hex(added) == signer, label {
        True, _ -> Error(bunker.NotApplied("account is already registered"))
        False, "not-ready" ->
          Error(bunker.NotReady("accounts are not loaded yet"))
        False, "maybe" -> Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
        False, _ -> Ok(Nil)
      }
    },
    remove_account: fn(_) {
      Error(bunker.NotApplied("account is not registered"))
    },
    rotate_secret: fn(_) { Ok(Nil) },
    update_label: fn(_, label) { change(label) },
    nsec: fn(_) { Ok(signer_nsec) },
    relays: fn() {
      Ok([
        dashboard.RelayRow(
          1,
          "wss://relay.example",
          Some(relay_connection.Connected),
          Some(relay_connection.Disconnected),
        ),
        dashboard.RelayRow(
          2,
          "ws://evil/\"><b>xss</b>",
          Some(relay_connection.Disconnected),
          None,
        ),
        dashboard.RelayRow(
          3,
          "ws://127.0.0.1:7801",
          None,
          Some(relay_connection.Connected),
        ),
      ])
    },
    plugins: fn() {
      [
        dashboard.PluginRow("console_logger", Some(plugin_runner.Running)),
        dashboard.PluginRow(
          "event_logger",
          Some(plugin_runner.Overloaded(dropped: 42)),
        ),
        dashboard.PluginRow(
          "broken",
          Some(plugin_runner.Disabled(
            reason: "error:<script>alert(1)</script>",
            dropped: 3,
          )),
        ),
        dashboard.PluginRow("slow", None),
      ]
    },
    reenable_plugin: reenabling,
    sessions: fn() {
      Ok([
        dashboard.SessionRow(
          signer:,
          client:,
          created_at: 1000,
          last_used_at: 1000,
        ),
      ])
    },
    revoke: fn(_signer, revoked_client) { revocation(revoked_client) },
    pending: fn() {
      Ok([
        dashboard.PendingRow(token: "tok-1", signer:, client:, age_seconds: 12),
      ])
    },
    approve: decide,
    deny: decide,
  )
}

/// 承認・拒否。承認待ちの一覧に無いトークンは管理 UI が呼び出す前に 404 にする
/// ので、呼ばれたら成功させる。
fn decide(_token: String) -> Result(Nil, bunker.SessionFailure) {
  Ok(Nil)
}

/// 待ち受けの先頭のポート。`PREVIEW_PORT` が整数でなければ既定値を使う。
fn base_port() -> Int {
  envoy.get("PREVIEW_PORT")
  |> result.try(int.parse)
  |> result.unwrap(default_port)
}

/// 3 つの状態の管理 UI を、先頭のポートから順に起動して待ち続ける。
pub fn main() -> Nil {
  let port = base_port()
  let unavailable_reason =
    "account store unavailable: database is unreachable or rejected the connection"
  let unavailable =
    admin.Context(
      ..context(),
      accounts: fn() { Error(unavailable_reason) },
      pending: fn() { Error(unavailable_reason) },
      sessions: fn() { Error(unavailable_reason) },
    )
  let empty =
    admin.Context(
      ..context(),
      accounts: fn() { Ok([]) },
      relays: fn() { Ok([]) },
      plugins: fn() { [] },
      sessions: fn() { Ok([]) },
      pending: fn() { Ok([]) },
    )
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(admin.supervised("127.0.0.1", port, context()))
    |> static_supervisor.add(admin.supervised(
      "127.0.0.1",
      port + 1,
      unavailable,
    ))
    |> static_supervisor.add(admin.supervised("127.0.0.1", port + 2, empty))
    |> static_supervisor.start
  process.sleep_forever()
}
