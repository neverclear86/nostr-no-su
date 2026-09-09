import gleam/erlang/atom
import gleam/erlang/process.{type Down, type Name, type Pid, type Subject}
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/crypto/nip44
import nostr_no_su/dedup
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin
import nostr_no_su/plugins/postgres_logger
import nostr_no_su/relay_connection
import nostr_no_su/time
import pog

const secret = "s3cr3t-token"

const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

/// 承認ページを載せる管理 UI の公開 URL。承認フローを有効にするために渡す。
const auth_base = "http://admin.test"

/// 偽リレーがテストへ報告する内容。
type Report {
  /// 接続が開かれた。どのリレーの接続か、所有するアクター、監視対象のソケット
  /// プロセス、そして実際のソケットと同じようにサブツリーへイベントを流し込む
  /// ハンドラーを伴う。
  Opened(
    relay_url: String,
    connection: Pid,
    socket: Pid,
    deliver: fn(Event) -> Nil,
  )
  /// イベントが送信された。送信に使われたソケットを伴う。
  Published(socket: Pid, event: Event)
}

/// 偽リレー。接続をすべて報告し、WebSocket の代わりに監視用の待機プロセスを
/// ツリーへ渡し、送信されたイベントをテストへ転送する。
fn fake_open(reports: Subject(Report)) -> app.Open {
  fn(relay_url, _subscriptions, handle_event) {
    let socket = process.spawn(fn() { process.sleep_forever() })
    process.send(
      reports,
      Opened(relay_url, process.self(), socket, handle_event),
    )
    Ok(
      relay_connection.Socket(pid: socket, publish: fn(published) {
        process.send(reports, Published(socket, published))
      }),
    )
  }
}

/// ツリーを起動する。起動できなければテストを失敗させる。
fn start_tree(spec: app.Spec) -> Pid {
  let assert Ok(started) = app.start(spec)
  started.pid
}

/// 偽リレー 1 本ぶんの仕様。URL は `fake_open` が無視するのでラベルでしかない。
fn test_relay() -> app.Relay {
  named_relay("ws://relay.test")
}

/// 指定した URL の偽リレー 1 本ぶんの仕様。バンカーは publisher を URL で
/// 区別するため、複数本を張るテストは別々の URL を渡す。
fn named_relay(url: String) -> app.Relay {
  app.Relay(name: process.new_name("test_relay"), url: url)
}

/// 接続が切断状態になるまで待つ。切断を観測できた時点で、接続アクターは
/// `on_disconnect` を実行し終えている。
fn await_disconnect(name: Name(relay_connection.Msg), timeout_ms: Int) -> Bool {
  case relay_connection.status(name), timeout_ms <= 0 {
    relay_connection.Disconnected, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_disconnect(name, timeout_ms - 10)
    }
  }
}

/// 偽リレー 1 本の上でバンカーだけを動かすツリー。
fn start_bunker_tree(reports: Subject(Report), name: Name(bunker.Msg)) -> Pid {
  start_tree(app.Spec(
    monitor: None,
    bunker: Some(
      app.Bunker(
        name: name,
        engine: engine.new(
          [#(account_for(signer_key), secret)],
          Some(fn(token) { auth_base <> "/approve/" <> token }),
        ),
        relays: [test_relay()],
        subscriptions: fn() { [] },
      ),
    ),
    storage: None,
    admin: None,
    open: fake_open(reports),
    reconnect_delay_ms: 100,
  ))
}

/// 親プロセスと同じ方法でツリーを停止する。ルートスーパーバイザーは exit
/// シグナルをツリー全体の順序立った停止に変換する。先にリンクを解除するのは、
/// 停止に失敗してもテストプロセスを巻き込まないようにするため。
fn stop_tree(tree: Pid) -> Nil {
  process.unlink(tree)
  process.send_exit(tree)
}

/// ツリーが次に開く接続を待ち、そのアクターが落ち着くのを待つ。システム
/// メッセージに応答した時点で、サブツリー先頭のアクターへの配線は完了している。
fn await_connection(reports: Subject(Report)) -> Report {
  let assert Ok(Opened(relay_url, connection, socket, deliver)) =
    process.receive(reports, 2000)
  let _state = system.get_state(connection)
  Opened(relay_url, connection, socket, deliver)
}

/// 監視中のプロセスが停止するのを待つ。
fn await_down(monitor: process.Monitor, timeout_ms: Int) -> Result(Down, Nil) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(timeout_ms)
}

/// テスト用 16 進鍵に対応するアカウント。
fn account_for(key_hex: String) -> Account {
  let assert Ok(account) = account.from_hex(key_hex)
  account
}

/// 実際のクライアントと同じ手順で暗号化・署名した `connect` リクエスト。
/// `secret_arg` が空文字列なら、シークレット無しで接続するクライアントと同じ形に
/// なる（nostr-tools はそのように送る）。
fn connect_request(id: String, secret_arg: String) -> Event {
  let signer = account_for(signer_key)
  request(
    id,
    "connect",
    "[\"" <> signer.pubkey_hex <> "\",\"" <> secret_arg <> "\"]",
  )
}

/// 指定した params を持つ JSON-RPC リクエスト。実際のクライアントと同じく
/// 署名者宛に暗号化し、クライアントの鍵で署名する。
fn request(id: String, method: String, params_json: String) -> Event {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body =
    "{\"id\":\""
    <> id
    <> "\",\"method\":\""
    <> method
    <> "\",\"params\":"
    <> params_json
    <> "}"
  let assert Ok(key) = nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(content) = nip44.encrypt(body, key)
  let unsigned =
    Event(
      id: "",
      pubkey: client.pubkey_hex,
      created_at: time.now_seconds(),
      kind: event.nip46_kind,
      tags: [["p", signer.pubkey_hex]],
      content: content,
      sig: "",
    )
  let assert Ok(signed) = event.finalize(unsigned, client.privkey)
  signed
}

/// 応答イベントの JSON-RPC 本文。クライアントが読むのと同じ形で取り出す。
fn response_body(response: Event) -> String {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let assert Ok(key) = nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(text) = nip44.decrypt(response.content, key)
  text
}

/// 指定した id を持つ最小限の kind 1 イベント。ディスパッチャーは id しか
/// 見ない。
fn event_with_id(id: String) -> Event {
  event_with_kind(id, 1)
}

/// 指定した id と kind を持つ最小限のイベント。
fn event_with_kind(id: String, kind: Int) -> Event {
  Event(
    id: id,
    pubkey: "",
    created_at: 0,
    kind: kind,
    tags: [],
    content: "",
    sig: "",
  )
}

/// ある接続で届いたリクエストには、その接続で応答する。
pub fn bunker_replies_on_its_connection_test() {
  let reports = process.new_subject()
  let tree = start_bunker_tree(reports, process.new_name("test_bunker"))
  let assert Opened(_relay_url, _connection, socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(answered_on, response)) =
    process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(response), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// バンカーアクターを kill しても復帰できる。スーパーバイザーが同じ名前で代替を
/// 起動し、その後ろで再起動した接続が publisher を登録し直すため、往復が再び
/// 成立する。
pub fn bunker_survives_being_killed_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  let assert Ok(killed) = process.named(name)
  process.kill(killed)

  let assert Opened(_relay_url, _connection, socket, deliver) =
    await_connection(reports)
  let assert Ok(restarted) = process.named(name)
  assert restarted != killed
  deliver(connect_request("c2", secret))
  let assert Ok(Published(answered_on, response)) =
    process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(response), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// バンカーの後ろで再起動する接続は、スーパーバイザーが要求した理由で終了する。
/// exit を trap したまま何もしないと、スーパーバイザーの停止タイムアウトで kill
/// されるまで動き続けてしまう。
pub fn connections_shut_down_when_the_bunker_restarts_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, connection, socket, _deliver) =
    await_connection(reports)
  let connection_monitor = process.monitor(connection)
  let socket_monitor = process.monitor(socket)
  let assert Ok(killed) = process.named(name)
  process.kill(killed)

  let assert Ok(process.ProcessDown(reason: reason, ..)) =
    await_down(connection_monitor, 1000)
  assert reason == process.Abnormal(atom.to_dynamic(atom.create("shutdown")))
  // ソケットは接続アクターが保持するリンクを通じて一緒に落ちる。
  let assert Ok(_socket_down) = await_down(socket_monitor, 1000)
  stop_tree(tree)
}

/// セッション状態は接続ではなくバンカーアクターが保持するため、再接続後も残る。
/// クライアントは再度 connect しなくても認可されたままになる。
pub fn session_survives_a_reconnect_test() {
  let reports = process.new_subject()
  let tree = start_bunker_tree(reports, process.new_name("test_bunker"))
  let assert Opened(_relay_url, _connection, socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(answered_on, ack)) = process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(ack), "\"result\":\"ack\"")

  process.kill(socket)
  let assert Opened(_relay_url, _connection, reconnected, deliver) =
    await_connection(reports)
  assert reconnected != socket
  // 2 度目の `connect` は送らない。pong が返るのは認可済みクライアントだけで、
  // 応答は死んだソケットを置き換えた新しいソケットから出ていく。
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(pong_on, pong)) = process.receive(reports, 2000)
  assert pong_on == reconnected
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  stop_tree(tree)
}

/// 管理 UI が使う経路。`connect` 済みのクライアントはセッション一覧に現れ、
/// 取り消すと消え、以降のリクエストは再び認可を求められる。
pub fn sessions_can_be_listed_and_revoked_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert bunker.sessions(name) == []

  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  assert bunker.sessions(name)
    == [engine.Session(signer: signer.pubkey_hex, client: client.pubkey_hex)]

  bunker.revoke(name, signer.pubkey_hex, client.pubkey_hex)
  assert bunker.sessions(name) == []
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, denied)) = process.receive(reports, 2000)
  assert string.contains(response_body(denied), "unauthorized")
  stop_tree(tree)
}

/// 管理 UI が使う経路。シークレット無しの `connect` は承認待ちになり、承認すると
/// 元のリクエストと同じ id の ack が接続から出ていく。
pub fn pending_connections_can_be_approved_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", ""))
  let assert Ok(Published(_socket, asked)) = process.receive(reports, 2000)
  assert string.contains(response_body(asked), "\"result\":\"auth_url\"")

  let client = account_for(client_key)
  let assert [entry] = bunker.pending(name)
  assert entry.client == client.pubkey_hex
  let assert Error(_) = bunker.approve(name, "other-token")

  assert bunker.approve(name, entry.token) == Ok(Nil)
  let assert Ok(Published(answered_on, ack)) = process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(ack), "\"id\":\"c1\"")
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  assert bunker.pending(name) == []
  let signer = account_for(signer_key)
  assert bunker.sessions(name)
    == [engine.Session(signer: signer.pubkey_hex, client: client.pubkey_hex)]
  stop_tree(tree)
}

/// ソケットを失った接続の送信手段は取り下げられる。バンカーリレーを 2 本張り、
/// 片方のソケットを kill すると、以降の応答は生きている側からだけ出ていく。
pub fn a_lost_socket_stops_receiving_responses_test() {
  let reports = process.new_subject()
  let relay_a = named_relay("ws://relay.one")
  let relay_b = named_relay("ws://relay.two")
  let tree =
    start_tree(app.Spec(
      monitor: None,
      bunker: Some(
        app.Bunker(
          name: process.new_name("test_bunker"),
          engine: engine.new([#(account_for(signer_key), secret)], None),
          relays: [relay_a, relay_b],
          subscriptions: fn() { [] },
        ),
      ),
      storage: None,
      admin: None,
      open: fake_open(reports),
      // 再接続で送信手段が戻ってこないよう、テストより十分に長く取る。
      reconnect_delay_ms: 60_000,
    ))
  // `Opened` は接続アクターごとに独立して届くため、到着順ではなく URL で
  // どちらのリレーの報告かを決める。
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(socket_a, socket_b, deliver) = case first_url == relay_a.url {
    True -> #(socket_1, socket_2, deliver_1)
    False -> #(socket_2, socket_1, deliver_2)
  }

  // 2 本とも生きている間は、応答が両方のソケットから出ていく。
  deliver(connect_request("c1", secret))
  let assert Ok(Published(first, _ack)) = process.receive(reports, 2000)
  let assert Ok(Published(second, _same_ack)) = process.receive(reports, 2000)
  assert first != second

  process.kill(socket_a)
  assert await_disconnect(relay_a.name, 2000)
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(answered_on, pong)) = process.receive(reports, 2000)
  assert answered_on == socket_b
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  // 死んだソケットには送られない。生きているのは 1 本だけになっている。
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// DB に到達できなくても監視は動き続ける。到達不能なプール設定で保存サブツリーを
/// 動かし、ツリーが起動すること、イベントが他のプラグインに届くこと、保存アクター
/// が生きていることを確かめる。root は one_for_one なので、保存側の不調は監視側の
/// 再起動にならない。
pub fn monitoring_survives_an_unreachable_database_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let logger = process.new_name("test_postgres_logger")
  let tree =
    start_tree(app.Spec(
      monitor: Some(
        app.Monitor(
          name: process.new_name("test_dedup"),
          plugins: [
            plugin.Plugin(name: "test", handle: process.send(seen, _)),
            postgres_logger.new(logger),
          ],
          dedup_capacity: 8,
          relays: [test_relay()],
          subscriptions: fn() { [] },
        ),
      ),
      bunker: None,
      storage: Some(app.Storage(
        name: logger,
        // 待ち受けのないポート。プールは起動するが接続はできない。
        pool_config: pog.default_config(process.new_name("test_pool"))
          |> pog.port(1),
      )),
      admin: None,
      open: fake_open(reports),
      reconnect_delay_ms: 100,
    ))
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(event_with_id("first"))
  assert process.receive(seen, 2000) == Ok(event_with_id("first"))
  let assert Ok(_logger_pid) = process.named(logger)
  stop_tree(tree)
}

/// 偽リレー 1 本の上で監視だけを動かすツリー。受信したイベントは `seen` に
/// 転送するプラグインへ渡る。
fn start_monitor_tree(
  reports: Subject(Report),
  seen: Subject(Event),
  name: Name(dedup.Msg),
) -> Pid {
  start_tree(app.Spec(
    monitor: Some(
      app.Monitor(
        name: name,
        plugins: [plugin.Plugin(name: "test", handle: process.send(seen, _))],
        dedup_capacity: 8,
        relays: [test_relay()],
        subscriptions: fn() { [] },
      ),
    ),
    bunker: None,
    storage: None,
    admin: None,
    open: fake_open(reports),
    reconnect_delay_ms: 100,
  ))
}

/// バンカー自身の NIP-46 通信は監視の対象外。同じ購読で kind 24133 が届いても
/// プラグインには渡さず、後続の通常イベントだけが渡る。
pub fn monitor_drops_nip46_events_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let tree = start_monitor_tree(reports, seen, process.new_name("test_dedup"))
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(event_with_kind("nip46", event.nip46_kind))
  deliver(event_with_id("normal"))
  // 送信順に処理されるため、最初に届くのが通常イベントであれば kind 24133 は
  // どのプラグインにも渡っていない。
  assert process.receive(seen, 2000) == Ok(event_with_id("normal"))
  stop_tree(tree)
}

/// 監視接続で受信したイベントはプラグインに届き、経由するディスパッチャーを kill
/// した後も届き続ける。
pub fn monitor_dispatcher_survives_being_killed_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let name = process.new_name("test_dedup")
  let tree = start_monitor_tree(reports, seen, name)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(event_with_id("first"))
  assert process.receive(seen, 2000) == Ok(event_with_id("first"))

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(event_with_id("second"))
  assert process.receive(seen, 2000) == Ok(event_with_id("second"))
  stop_tree(tree)
}
