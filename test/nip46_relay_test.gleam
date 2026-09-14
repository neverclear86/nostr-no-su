//// 実際のリレーと Postgres の上で、本番の仕様のツリーに NIP-46 の
//// connect → get_public_key → sign_event を往復させる E2E。
////
//// `TEST_RELAY_URL` と `TEST_DATABASE_URL` の両方があるときだけ走る。CI では
//// `nip46-e2e` ジョブが両方を渡す。他のジョブは `TEST_RELAY_URL` を渡さないので
//// このテストはスキップされる。

import envoy
import gleam/crypto
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/io
import gleam/option.{None}
import gleam/string
import gleam/uri.{Uri}
import nostr_no_su
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/vault
import nostr_no_su/config
import nostr_no_su/hex
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/random
import nostr_no_su/relay_client
import nostr_no_su/relay_list
import nostr_no_su/time
import pog
import support/nip46_client.{account_for}
import support/postgres

/// テスト用の署名者の 16 進秘密鍵。他のテストと同じ固定値。
const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

/// 発行したリクエストへの OK を待つ時間。
const ack_timeout_ms = 5000

/// 応答イベントを待つ時間。実リレーの往復を含むため OK より長く取る。
const response_timeout_ms = 20_000

/// 実リレー越しに connect が `ack`、get_public_key が署名者の公開鍵、sign_event が
/// `sig` を持つイベントを返す。
pub fn nip46_round_trip_over_a_relay_test() {
  use relay_url <- with_test_relay_url
  use database_url <- postgres.with_test_database_url("nip46_relay")
  use scoped_database_url <- with_database(database_url)

  let signer = account_for(signer_key)
  let client = account_for(random.hex(32))
  let #(_spec, tree, secret) =
    start_tree(scoped_database_url, relay_url, signer)
  let events = process.new_subject()
  let acks = process.new_subject()
  let connection = connect_client(relay_url, client, events, acks)

  let connected =
    call(
      connection,
      client,
      signer,
      nip46_client.connect_body(signer, secret, "connect-1"),
      events,
      acks,
    )
  assert string.contains(connected, "\"result\":\"ack\"")

  let public_key =
    call(
      connection,
      client,
      signer,
      nip46_client.request_body("gpk-1", "get_public_key", "[]"),
      events,
      acks,
    )
  assert string.contains(public_key, account.pubkey_hex(signer))

  let signed =
    call(
      connection,
      client,
      signer,
      nip46_client.request_body(
        "sign-1",
        "sign_event",
        "[\"{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}\"]",
      ),
      events,
      acks,
    )
  // `result` は署名済みイベントを JSON 文字列として符号化した値なので、内側の
  // 引用符はエスケープされている。
  assert string.contains(signed, "\\\"sig\\\":\\\"")

  process.unlink(tree)
  process.kill(tree)
}

/// 空でない `TEST_RELAY_URL` で `run` を呼ぶ。未設定なら、`test` ジョブはリレーを
/// 立てないので、CI かどうかに関わらずスキップの 1 行を出す。
fn with_test_relay_url(run: fn(String) -> Nil) -> Nil {
  case envoy.get("TEST_RELAY_URL") {
    Ok(url) if url != "" -> run(url)
    _ ->
      io.println(
        "[nip46_relay] TEST_RELAY_URL is not set; skipping the integration test",
      )
  }
}

/// `database_url` の DB に専用の database を作り、その database を指す URL で
/// `run` を呼び、終わったら `DROP DATABASE … WITH (FORCE)` で消す。advisory lock は
/// database 単位なので、テストごとに database を分ける（`account_reconcile_test`
/// と同じスキーマの分離では、先に走る統合テストのロックが残ったプールと衝突する）。
fn with_database(database_url: String, run: fn(String) -> Nil) -> Nil {
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  let name = "nip46_relay_" <> random.hex(8)
  postgres.run_statement(admin, "CREATE DATABASE " <> name)
  run(database_url_with_name(database_url, name))
  postgres.run_statement(admin, "DROP DATABASE " <> name <> " WITH (FORCE)")
}

/// `database_url` のパスを `name` に置き換えた URL。
fn database_url_with_name(database_url: String, name: String) -> String {
  let assert Ok(parsed) = uri.parse(database_url)
  uri.to_string(Uri(..parsed, path: "/" <> name))
}

/// `startup` の仕様でツリーを起動し、読み込みが終わるのを待ってから署名者を足し、
/// リレーをバンカー用途で開く。仕様とツリーの pid、追加した署名者の接続 secret を
/// 返す。
fn start_tree(
  database_url: String,
  relay_url: String,
  signer: Account,
) -> #(app.Spec, Pid, String) {
  let assert Ok(started) = nostr_no_su.startup(test_config(database_url))
  let assert Ok(tree) = app.start(started.spec)
  assert await(
    fn() {
      case bunker.accounts(started.spec.bunker.name) {
        Ok(_) -> True
        Error(_) -> False
      }
    },
    5000,
  )
  let assert Ok(Nil) = app.add_account(started.spec, signer, "e2e")
  let assert Ok(Nil) =
    app.open_relay(
      started.spec,
      relay_url,
      relay_list.Roles(monitor: False, bunker: True),
    )
  let assert Ok([listing]) = bunker.accounts(started.spec.bunker.name)
  #(started.spec, tree.pid, listing.secret)
}

/// `database_url` を使い、他はすべて無効・最小に揃えた設定。管理 UI とプラグインを
/// 起動しないことで、このテストが監視するのはバンカーとリレー接続だけになる。
fn test_config(database_url: String) -> config.Config {
  config.Config(
    account_store: config.AccountStore(
      database_url: database_url,
      master_key: random_master_key(),
    ),
    plugin_dir: None,
    plugin_env: dict.new(),
    admin_ui: config.Disabled,
    admin_bind: "127.0.0.1",
    admin_base_url: None,
    console_logger_enabled: Ok(False),
  )
}

/// 実行のたびに違うマスターキー。
fn random_master_key() -> vault.MasterKey {
  let assert Ok(key) =
    vault.master_key_from_hex(hex.encode(crypto.strong_random_bytes(32)))
  key
}

/// `relay_url` へ繋ぎ、`client` 宛ての kind 24133 を購読する。イベントと OK は
/// `events` と `acks` へ送る。
fn connect_client(
  relay_url: String,
  client: Account,
  events: Subject(Event),
  acks: Subject(relay_client.Acknowledgement),
) -> relay_client.Client {
  let subscriptions = fn() {
    Ok([
      #(
        "client",
        config.bunker_filter(
          [account.pubkey_hex(client)],
          time.now_seconds() - 60,
        ),
      ),
    ])
  }
  let assert Ok(connection) =
    relay_client.start(
      relay_url,
      subscriptions,
      fn(verified) { process.send(events, event.verified_event(verified)) },
      fn(ack) { process.send(acks, ack) },
      None,
      relay_client.subscription_retry_delay,
      relay_client.keepalive_interval_ms,
    )
  connection
}

/// `client` から `signer` 宛てに `body` を要求として送り、OK の受理を確かめてから
/// 応答を復号した本文を返す。
fn call(
  connection: relay_client.Client,
  client: Account,
  signer: Account,
  body: String,
  events: Subject(Event),
  acks: Subject(relay_client.Acknowledgement),
) -> String {
  let request =
    nip46_client.request_event(client, signer, body, time.now_seconds())
  relay_client.publish(connection, request)
  let assert Ok(ack) = process.receive(acks, ack_timeout_ms)
  assert ack.accepted
  let assert Ok(response) = process.receive(events, response_timeout_ms)
  nip46_client.decrypt_response(client, signer, response)
}

/// `check` が真になるまで待つ。50ms ごとに `remaining` から引き、尽きたら諦める。
/// `start_tree` が `bunker.accounts` の `Ok` を待つのに使う。
fn await(check: fn() -> Bool, remaining: Int) -> Bool {
  case check(), remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(50)
      await(check, remaining - 50)
    }
  }
}
