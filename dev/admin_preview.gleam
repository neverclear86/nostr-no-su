//// 管理 UI を固定の状態で起動する撮影用のサーバー。`admin.handle_request` を本物のまま
//// 使い、`Context` の関数だけを固定の値に差し替える。待ち受けるのは `PREVIEW_PORT`
//// （既定は 18461）から続く 3 つのポートで、順に通常の状態、アカウント・飛ばされた行・
//// 承認待ち・セッションの一覧を得られない状態、すべての一覧が空の状態である。
//// `gleam run -m admin_preview` で起動し、`dev/screenshots.mjs` で撮る。
////
//// `dev/` は `gleam build` と `gleam test` でコンパイルされるので、`Context` を変えて
//// ここを直し忘れると CI で落ちる。`gleam export erlang-shipment` の成果物には入らない。
//// 管理パスワードは固定の値で、鍵は公開のテストベクター、secret はダミーの値である。

import envoy
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/result
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_config
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/time

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

/// 読み込みで飛ばされた行（秘密鍵を復号できない）の pubkey（ダミー）。
const unreadable_pubkey = "dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444"

/// `unreadable_pubkey` の npub。
const unreadable_npub = "npub1mhw5g3xam4zyfhwag3zdmh2ygnwa63zymhw5g3xam4zyfhwag3zqqkw2rx"

/// 読み込みで飛ばされた行（`pubkey` 列が形式不正）の値。32 バイトの 16 進として
/// 読めない。
const malformed_pubkey = "not-a-valid-pubkey"

/// 辞書順で `client` より前に来る、2 件目のセッションのクライアントの公開鍵（ダミー）。
const earlier_client = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"

/// 接続してきたクライアントの公開鍵（ダミー）。
const client = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"

/// アカウント一覧に無い署名者（ダミー）。承認待ちのタイルに省略した 16 進の署名者を
/// 写すために使う。
const unknown_signer = "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"

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

/// クライアントの値で、権限の更新の結果を選ぶ。`earlier_client` だけ、保存の失敗の
/// 状態を撮るために書き込まれていないことが確定した失敗にする。
fn updating_perms(
  updated_client: String,
) -> Result(Nil, bunker.SessionFailure) {
  case updated_client == earlier_client {
    True ->
      Error(bunker.SessionNotApplied(
        "database is unreachable or rejected the connection",
      ))
    False -> Ok(Nil)
  }
}

/// URL の値で、リレーの追加の結果を選ぶ。用途は撮影に使わない。
fn adding_relay(
  url: String,
  _roles: relay_list.Roles,
) -> Result(Nil, admin.RelayChangeFailure) {
  case url {
    "wss://duplicate.example" -> Error(admin.DuplicateRelay)
    "wss://not-saved.example" ->
      Error(admin.RelayNotSaved(
        "database is unreachable or rejected the connection",
      ))
    "wss://maybe.example" -> Error(admin.RelayMaybeSaved)
    "wss://unconfirmed.example" -> Error(admin.ConnectionsNotConfirmed)
    _ -> Ok(Nil)
  }
}

/// `relays` と同じ id と URL の DB の行。用途の編集と削除の撮影に使う。
fn db_relays() -> List(relay_store.Relay) {
  [
    relay_store.Relay(1, "wss://relay.example", relay_list.Roles(True, True)),
    relay_store.Relay(
      2,
      "ws://evil/\"><b>xss</b>",
      relay_list.Roles(True, False),
    ),
    relay_store.Relay(3, "ws://127.0.0.1:7801", relay_list.Roles(False, True)),
  ]
}

/// id の値で、用途の編集と削除の結果を選ぶ。id 2 は書き込まれていないことが確定した DB の
/// 失敗、id 3 は接続の確認ができない状態、それ以外は成功。
fn changing_relay(
  relay: relay_store.Relay,
) -> Result(Nil, admin.RelayChangeFailure) {
  case relay.id {
    2 ->
      Error(admin.RelayNotSaved(
        "database is unreachable or rejected the connection",
      ))
    3 -> Error(admin.ConnectionsNotConfirmed)
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

/// `console_logger` の `status` ページの記述。`pairs` の節、`table` の節に加え、
/// 変換に失敗する節を 1 つ持つ（失敗した節だけを囲みに差し替えて出す画面を撮るため）。
fn console_logger_status_description() -> Dynamic {
  let text_inline = fn(text: String) {
    dynamic.properties([
      #(dynamic.string("type"), dynamic.string("text")),
      #(dynamic.string("text"), dynamic.string(text)),
    ])
  }
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
                #(dynamic.string("type"), dynamic.string("pairs")),
                #(
                  dynamic.string("items"),
                  dynamic.list([
                    dynamic.properties([
                      #(dynamic.string("term"), dynamic.string("processed")),
                      #(dynamic.string("value"), text_inline("42")),
                    ]),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("section")),
          #(dynamic.string("title"), dynamic.string("Recent events")),
          #(
            dynamic.string("blocks"),
            dynamic.list([
              dynamic.properties([
                #(dynamic.string("type"), dynamic.string("table")),
                #(
                  dynamic.string("headers"),
                  dynamic.list([dynamic.string("kind"), dynamic.string("id")]),
                ),
                #(
                  dynamic.string("rows"),
                  dynamic.list([
                    dynamic.list([text_inline("1"), text_inline("abcd1234")]),
                  ]),
                ),
              ]),
            ]),
          ),
        ]),
        dynamic.properties([#(dynamic.string("type"), dynamic.string("nope"))]),
      ]),
    ),
  ])
}

/// `console_logger` の `settings` ページの記述。`form` の節 1 つ（チェック 2 件と
/// 送信のボタン）にし、フォームの描画と送信の経路を撮る。
fn console_logger_settings_description() -> Dynamic {
  let checkbox_field = fn(name: String, label: String, checked: Bool) {
    dynamic.properties([
      #(dynamic.string("type"), dynamic.string("checkbox")),
      #(dynamic.string("name"), dynamic.string(name)),
      #(dynamic.string("label"), dynamic.string(label)),
      #(dynamic.string("checked"), dynamic.bool(checked)),
    ])
  }
  dynamic.properties([
    #(
      dynamic.string("sections"),
      dynamic.list([
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("section")),
          #(dynamic.string("title"), dynamic.string("Monitored accounts")),
          #(
            dynamic.string("blocks"),
            dynamic.list([
              dynamic.properties([
                #(dynamic.string("type"), dynamic.string("form")),
                #(
                  dynamic.string("fields"),
                  dynamic.list([
                    checkbox_field("main", "main account", True),
                    checkbox_field("bot", "<b>bot</b> 🙂", False),
                  ]),
                ),
                #(dynamic.string("submit"), dynamic.string("Save")),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

/// `broken` の `status` ページの記述。`Disabled` の注意の囲みと並べて撮る。
fn broken_status_description() -> Dynamic {
  dynamic.properties([
    #(
      dynamic.string("sections"),
      dynamic.list([
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("section")),
          #(dynamic.string("title"), dynamic.string("Status")),
          #(
            dynamic.string("blocks"),
            dynamic.list([
              dynamic.properties([
                #(dynamic.string("type"), dynamic.string("text")),
                #(
                  dynamic.string("text"),
                  dynamic.string("last known state before it was disabled"),
                ),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
  ])
}

/// プラグインのページの中身。`slow` は無応答を模して常に理由を返す。登録
/// アカウントの一覧は撮影には使わない。
fn plugin_page_content(
  name: String,
  key: String,
  _accounts: List(plugin_config.PageAccount),
) -> Result(Dynamic, String) {
  case name, key {
    "console_logger", "status" -> Ok(console_logger_status_description())
    "console_logger", "settings" -> Ok(console_logger_settings_description())
    "broken", "status" -> Ok(broken_status_description())
    "slow", "status" -> Error("plugin did not answer in time")
    _, _ -> Error("plugin not found")
  }
}

/// フォームの送信を受け取る実行の口。`console_logger` の `settings` だけが持ち、
/// 常に成功する。ほかのプラグインとページ（`broken/status` など）は `None` を
/// 返し、405 の経路を撮る。
fn plugin_page_action(
  name: String,
  key: String,
) -> Option(
  fn(List(#(String, String)), List(plugin_config.PageAccount)) ->
    Result(Nil, String),
) {
  case name, key {
    "console_logger", "settings" -> Some(fn(_values, _accounts) { Ok(Nil) })
    _, _ -> None
  }
}

/// プラグインのページと実行の呼び出しに渡す、固定の登録アカウントの一覧。
fn page_accounts() -> Result(List(plugin_config.PageAccount), String) {
  Ok([
    plugin_config.PageAccount(
      pubkey: signer,
      npub: signer_npub,
      label: "main account",
    ),
    plugin_config.PageAccount(
      pubkey: second,
      npub: second_npub,
      label: "<b>bot</b> 🙂",
    ),
  ])
}

/// 通常の状態の Context。削除は常に「反映されていない」（409）を返す。登録は
/// `signer` の鍵なら「反映されていない」（409）、ラベルが `not-ready` / `maybe` なら
/// それぞれ 503 / 202 を返す（生成した鍵の確認ページの撮影用）。
fn context() -> admin.Context {
  admin.Context(
    password:,
    client_address: admin.unknown_client_address,
    authentication_delay: 0,
    accounts: fn() {
      Ok([
        row(signer, signer_npub, "main account"),
        row(second, second_npub, "<b>bot</b> 🙂"),
      ])
    },
    skipped: fn() {
      Ok([
        dashboard.SkippedRow(
          pubkey: unreadable_pubkey,
          npub: unreadable_npub,
          label: "old wallet",
          reason: vault.UndecryptablePrivateKey,
        ),
        dashboard.SkippedRow(
          pubkey: malformed_pubkey,
          npub: "",
          label: "",
          reason: vault.MalformedPubkey,
        ),
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
    reload_accounts: fn() { Ok(Nil) },
    relays: fn(_deadline) {
      Ok([
        dashboard.RelayRow(
          1,
          "wss://relay.example",
          dashboard.Reported(relay_connection.Connected),
          dashboard.Reported(relay_connection.Disconnected),
        ),
        dashboard.RelayRow(
          2,
          "ws://evil/\"><b>xss</b>",
          dashboard.Unanswered,
          dashboard.Unused,
        ),
        dashboard.RelayRow(
          3,
          "ws://127.0.0.1:7801",
          dashboard.Unused,
          dashboard.Reported(relay_connection.Connected),
        ),
      ])
    },
    plugins: fn(_deadline) {
      [
        dashboard.PluginRow(
          "console_logger",
          Some(plugin_runner.Running),
          pages: [
            plugin.PluginPage(key: "status", title: "Status"),
            plugin.PluginPage(key: "settings", title: "Settings"),
          ],
        ),
        dashboard.PluginRow(
          "event_logger",
          Some(plugin_runner.Overloaded(dropped: 42)),
          pages: [],
        ),
        dashboard.PluginRow(
          "broken",
          Some(plugin_runner.Disabled(
            reason: "error:<script>alert(1)</script>",
            dropped: 3,
          )),
          pages: [plugin.PluginPage(key: "status", title: "Status")],
        ),
        dashboard.PluginRow("slow", None, pages: [
          plugin.PluginPage(key: "status", title: "Status"),
        ]),
      ]
    },
    add_relay: adding_relay,
    registered_relays: fn() { Ok(db_relays()) },
    update_relay_roles: fn(relay, _roles) { changing_relay(relay) },
    delete_relay: changing_relay,
    connect_client: fn(_request, _signer) { Error(admin.RelayNotConnected) },
    reenable_plugin: reenabling,
    plugin_page_content: plugin_page_content,
    page_accounts: page_accounts,
    plugin_page_action: plugin_page_action,
    sessions: fn() {
      let now = time.now_seconds()
      Ok([
        dashboard.SessionRow(
          signer:,
          client:,
          perms: "sign_event:1,sign_event:7,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt",
          created_at: now - 30 * 86_400,
          last_used_at: now - 7 * 86_400,
        ),
        dashboard.SessionRow(
          signer:,
          client: earlier_client,
          perms: "",
          created_at: now - 14 * 86_400,
          last_used_at: now - 14 * 86_400,
        ),
      ])
    },
    revoke: fn(_signer, revoked_client) { revocation(revoked_client) },
    update_perms: fn(_signer, updated_client, _perms) {
      updating_perms(updated_client)
    },
    pending: fn() {
      Ok([
        dashboard.PendingRow(
          token: "tok-1",
          signer:,
          client:,
          expires_in_seconds: 540,
          secret_mismatch: False,
          perms: "sign_event:1,sign_event:7,nip04_encrypt,nip04_decrypt,nip44_encrypt,nip44_decrypt",
        ),
        dashboard.PendingRow(
          token: "tok-2",
          signer:,
          client:,
          expires_in_seconds: 45,
          secret_mismatch: True,
          perms: "",
        ),
        dashboard.PendingRow(
          token: "tok-3",
          signer: unknown_signer,
          client:,
          expires_in_seconds: 540,
          secret_mismatch: False,
          perms: "sign_event:1",
        ),
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
      skipped: fn() { Error(unavailable_reason) },
      pending: fn() { Error(unavailable_reason) },
      sessions: fn() { Error(unavailable_reason) },
    )
  let empty =
    admin.Context(
      ..context(),
      accounts: fn() { Ok([]) },
      skipped: fn() { Ok([]) },
      relays: fn(_deadline) { Ok([]) },
      plugins: fn(_deadline) { [] },
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
