//// 実際のリレーと Postgres の上で、本番の仕様のツリーに NIP-46 の
//// connect → get_public_key → sign_event を往復させ、`nostrconnect://` からの
//// 接続と、セッションを開けなかったときの URI のリレーの取り外しと、登録して
//// いないセッションのリレーだけで応答する接続も試す E2E。
////
//// `TEST_RELAY_URL` と `TEST_DATABASE_URL` の両方があるときだけ走り、どちらかが
//// 未設定ならスキップして 1 行ログを出す。CI の `test` ジョブは strfry と Postgres
//// を立てて両方渡す。

import envoy
import gleam/dict
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri.{Uri}
import nostr_no_su
import nostr_no_su/admin
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/nostrconnect
import nostr_no_su/config
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/random
import nostr_no_su/relay_client
import nostr_no_su/relay_list
import nostr_no_su/time
import pog
import support/nip46_client.{account_for}
import support/poll
import support/postgres
import support/random_account.{random_master_key}

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
    start_tree_with_relay(scoped_database_url, relay_url, signer)
  let events = process.new_subject()
  let acks = process.new_subject()
  let connection = connect_client(relay_url, client, events, acks)

  let connected =
    call(
      connection,
      client,
      signer,
      nip46_client.connect_body_with_perms(
        signer,
        secret,
        "sign_event:1",
        "connect-1",
      ),
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

/// `nostrconnect://` の接続は、URI のリレーを `relays` テーブルに登録せず、セッションの
/// リレーとして接続してから開き、応答の `result` に URI の secret を入れて返す。
/// 開いたセッションは URI のリレーを持ち、以降のリクエストを処理できる。
pub fn nostrconnect_client_initiated_connection_test() {
  use relay_url <- with_test_relay_url
  use database_url <- postgres.with_test_database_url("nip46_relay")
  use scoped_database_url <- with_database(database_url)

  let signer = account_for(signer_key)
  let client = account_for(random.hex(32))
  let #(spec, tree, _secret) = start_tree(scoped_database_url, signer)
  let events = process.new_subject()
  let acks = process.new_subject()
  let connection = connect_client(relay_url, client, events, acks)

  let uri_secret = "nostrconnect-secret"
  let request =
    nostrconnect.ConnectRequest(
      client: account.pubkey_hex(client),
      relays: [relay_url],
      secret: uri_secret,
      perms: "sign_event:1",
      name: None,
    )
  assert app.connect_nostrconnect(spec, request, account.pubkey_hex(signer))
    == Ok(Nil)

  // 応答はクライアントの購読から届き、`result` は URI の secret になる。
  let assert Ok(response) = process.receive(events, response_timeout_ms)
  let body = nip46_client.decrypt_response(client, signer, response)
  assert string.contains(body, "\"result\":\"" <> uri_secret <> "\"")

  // 開いたセッションは URI のリレーを持つ。
  let assert Ok([session]) = bunker.sessions(spec.bunker.name)
  assert session.relays == [relay_url]

  // 開いたセッションで `sign_event` が署名を返す。
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
  assert string.contains(signed, "\\\"sig\\\":\\\"")

  // URI のリレーは `relays` テーブルに登録されない。
  assert app.registered_relays(spec) == Ok([])

  process.unlink(tree)
  process.kill(tree)
}

/// セッションを開けなかった `nostrconnect://` の接続は、取り置いた URI のリレーを
/// 外し、そのリレーの接続を閉じる。
pub fn a_failed_nostrconnect_releases_the_uri_relays_test() {
  use relay_url <- with_test_relay_url
  use database_url <- postgres.with_test_database_url("nip46_relay")
  use scoped_database_url <- with_database(database_url)

  let signer = account_for(signer_key)
  let #(spec, tree, _secret) = start_tree(scoped_database_url, signer)
  let name = spec.bunker.name
  let unregistered = account.pubkey_hex(account_for(random.hex(32)))
  let request =
    nostrconnect.ConnectRequest(
      client: account.pubkey_hex(account_for(random.hex(32))),
      relays: [relay_url],
      secret: "failed-secret",
      perms: "sign_event:1",
      name: None,
    )
  let assert Error(admin.SessionNotOpened(bunker.SessionNotFound(_))) =
    app.connect_nostrconnect(spec, request, unregistered)
  assert poll.until(
    fn() {
      case bunker.publisher_urls(name) {
        Some(urls) -> !list.contains(urls, relay_url)
        None -> False
      }
    },
    5000,
    50,
  )
  assert bunker.session_signers(name, relay_url) == Some([])

  process.unlink(tree)
  process.kill(tree)
}

/// 登録していないリレーを持つセッションは、そのリレーの接続を開いて応答し、
/// 取り消すと接続を閉じる。
pub fn a_session_only_relay_serves_its_session_over_a_relay_test() {
  use relay_url <- with_test_relay_url
  use database_url <- postgres.with_test_database_url("nip46_relay")
  use scoped_database_url <- with_database(database_url)

  let signer = account_for(signer_key)
  let client = account_for(random.hex(32))
  let signer_hex = account.pubkey_hex(signer)
  let client_hex = account.pubkey_hex(client)
  let #(spec, tree, _secret) = start_tree(scoped_database_url, signer)
  let name = spec.bunker.name
  let events = process.new_subject()
  let acks = process.new_subject()
  let connection = connect_client(relay_url, client, events, acks)

  // `connect` の応答は、接続がまだ無いので送る先が無い。確かめるのは開いた後の往復。
  let assert Ok(Nil) =
    bunker.open_client_session(
      name,
      signer_hex,
      client_hex,
      "sign_event:1",
      [relay_url],
      "session-only-secret",
    )
  assert poll.until(
    fn() {
      case bunker.publisher_urls(name) {
        Some(urls) -> list.contains(urls, relay_url)
        None -> False
      }
    },
    5000,
    50,
  )
  assert bunker.session_signers(name, relay_url) == Some([signer_hex])

  let signed = call_retrying(connection, client, signer, events, acks, 1)
  assert string.contains(signed, "\\\"sig\\\":\\\"")

  let assert Ok(Nil) = bunker.revoke(name, signer_hex, client_hex)
  assert poll.until(
    fn() {
      case bunker.publisher_urls(name) {
        Some(urls) -> !list.contains(urls, relay_url)
        None -> False
      }
    },
    5000,
    50,
  )

  process.unlink(tree)
  process.kill(tree)
}

/// `sign_event` を送り、`response_timeout_ms` 内に応答が届かなければ id を変えて
/// 3 回目まで送り直す。kind 24133 はリレーが保存しないので、接続の REQ が届く前の
/// リクエストは取りこぼされる。`attempt` は何回目の送信か。
fn call_retrying(
  connection: relay_client.Client,
  client: Account,
  signer: Account,
  events: Subject(Event),
  acks: Subject(relay_client.Acknowledgement),
  attempt: Int,
) -> String {
  let request =
    nip46_client.request_event(
      client,
      signer,
      nip46_client.request_body(
        "sign-" <> int.to_string(attempt),
        "sign_event",
        "[\"{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}\"]",
      ),
      time.now_seconds(),
    )
  relay_client.publish(connection, request)
  let assert Ok(ack) = process.receive(acks, ack_timeout_ms)
  assert ack.accepted
  case process.receive(events, response_timeout_ms), attempt < 3 {
    Ok(response), _ -> nip46_client.decrypt_response(client, signer, response)
    Error(Nil), True ->
      call_retrying(connection, client, signer, events, acks, attempt + 1)
    Error(Nil), False -> panic as "no response to sign_event over the relay"
  }
}

/// 空でない `TEST_RELAY_URL` で `run` を呼ぶ。未設定ならスキップの 1 行を出す。
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

/// `startup` の仕様でツリーを起動し、読み込みが終わるのを待ってから署名者を足す。
/// 仕様とツリーの pid、追加した署名者の接続 secret を返す。リレーは呼び出し側が
/// 開く。
fn start_tree(
  database_url: String,
  signer: Account,
) -> #(app.Spec, Pid, String) {
  let assert Ok(started) = nostr_no_su.startup(test_config(database_url))
  let assert Ok(tree) = app.start(started.spec)
  assert poll.until(
    fn() {
      case bunker.accounts(started.spec.bunker.name) {
        Ok(_) -> True
        Error(_) -> False
      }
    },
    5000,
    50,
  )
  let assert Ok(Nil) = app.add_account(started.spec, signer, "e2e")
  let assert Ok([listing]) = bunker.accounts(started.spec.bunker.name)
  #(started.spec, tree.pid, listing.secret)
}

/// `start_tree` で起動し、`relay_url` をバンカー用途で開く。
fn start_tree_with_relay(
  database_url: String,
  relay_url: String,
  signer: Account,
) -> #(app.Spec, Pid, String) {
  let #(spec, tree, secret) = start_tree(database_url, signer)
  let assert Ok(Nil) =
    app.open_relay(
      spec,
      relay_url,
      relay_list.Roles(monitor: False, bunker: True),
    )
  #(spec, tree, secret)
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
    admin_base_url: None,
    console_logger_enabled: Ok(False),
    dedup_capacity: Ok(4096),
  )
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
      fn(received) {
        case received {
          relay_client.ReceivedEvent(_, verified) ->
            process.send(events, event.verified_event(verified))
          relay_client.ReceivedEose(_) -> Nil
        }
      },
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
