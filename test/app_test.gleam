import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Down, type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/engine
import nostr_no_su/dedup
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin
import nostr_no_su/plugin_children
import nostr_no_su/plugin_runner
import nostr_no_su/plugins/event_logger
import nostr_no_su/relay_connection
import nostr_no_su/time
import pog
import support/nip46_client.{account_for}

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
    plugins: [],
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
    event_logger: None,
    admin: None,
    open: fake_open(reports),
    reconnect_delay_ms: 100,
  ))
}

/// 受け取ったイベントをテストへ転送するプラグインの仕様。歯止めは既定のまま。
fn forwarding_spec(
  name: Name(plugin_runner.Msg),
  seen: Subject(Event),
) -> app.PluginSpec {
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(
      name: "forwarding",
      children: [],
      handle: process.send(seen, _),
    ),
    limits: plugin_runner.default_limits,
  )
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

/// 指定した秒より時計が進むまで待つ。バンカーアクターの起点の判定は秒単位なので、
/// 秒をまたいでおかないと、再起動の前に作られたリクエストと起動時刻が並んでしまう。
fn await_next_second(from: Int) -> Nil {
  case time.now_seconds() > from {
    True -> Nil
    False -> {
      process.sleep(50)
      await_next_second(from)
    }
  }
}

/// 監視中のプロセスが停止するのを待つ。
fn await_down(monitor: process.Monitor, timeout_ms: Int) -> Result(Down, Nil) {
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(down) { down })
  |> process.selector_receive(timeout_ms)
}

/// テスト用の署名者とクライアントで組み立てた `connect` リクエスト。
/// `secret_arg` が空文字列なら、シークレット無しで接続するクライアントと同じ形に
/// なる（nostr-tools はそのように送る）。
fn connect_request(id: String, secret_arg: String) -> Event {
  let signer = account_for(signer_key)
  signed_request(nip46_client.connect_body(signer, secret_arg, id))
}

/// 指定した params を持つ JSON-RPC リクエスト。
fn request(id: String, method: String, params_json: String) -> Event {
  signed_request(nip46_client.request_body(id, method, params_json))
}

/// 指定した本文を、テスト用のクライアントから署名者宛のリクエストイベントに
/// する。ツリーは受付ウィンドウを実時間で見るため、作成時刻は現在時刻にする。
fn signed_request(body: String) -> Event {
  nip46_client.request_event(
    account_for(client_key),
    account_for(signer_key),
    body,
    time.now_seconds(),
  )
}

/// 応答イベントの JSON-RPC 本文。クライアントが読むのと同じ形で取り出す。
fn response_body(response: Event) -> String {
  nip46_client.decrypt_response(
    account_for(client_key),
    account_for(signer_key),
    response,
  )
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

/// バンカーアクターが再起動したあとは、リレーが再配送した処理済みのリクエストを
/// 実行しない。アクターが変わるとリプレイ防止の `seen` は空になるため、実行して
/// しまうと応答が再発行され、取り消したはずのセッションまで復活する。
pub fn restarted_bunker_ignores_requests_from_before_it_started_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, socket, deliver) =
    await_connection(reports)
  let request = connect_request("c1", secret)
  deliver(request)
  let assert Ok(Published(answered_on, ack)) = process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  // 同じアクターが生きている間は、再配送を `seen` が落とす。
  deliver(request)
  let assert Error(Nil) = process.receive(reports, 200)

  await_next_second(request.created_at)
  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(request)
  let assert Error(Nil) = process.receive(reports, 500)
  assert bunker.sessions(name) == []
  stop_tree(tree)
}

/// 切断していた間に届いたリクエストは、再接続後に実行する。アクターが生き続けて
/// いる限り起点は動かないため、購読が現在時刻から遡って拾い直したリクエストは、
/// 秒をまたいでいても処理される。
pub fn reconnected_bunker_handles_requests_from_the_outage_test() {
  let reports = process.new_subject()
  let tree = start_bunker_tree(reports, process.new_name("test_bunker"))
  let assert Opened(_relay_url, _connection, socket, _deliver) =
    await_connection(reports)
  let request = connect_request("c1", secret)
  // 秒をまたいでから接続を落とす。起点が再接続で更新されていれば、このリクエストは
  // 起点より古いものとして落ちる。
  await_next_second(request.created_at)

  process.kill(socket)
  let assert Opened(_relay_url, _connection, reconnected, deliver) =
    await_connection(reports)
  assert reconnected != socket
  deliver(request)
  let assert Ok(Published(answered_on, ack)) = process.receive(reports, 2000)
  assert answered_on == reconnected
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
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
      plugins: [],
      monitor: None,
      bunker: Some(
        app.Bunker(
          name: process.new_name("test_bunker"),
          engine: engine.new([#(account_for(signer_key), secret)], None),
          relays: [relay_a, relay_b],
          subscriptions: fn() { [] },
        ),
      ),
      event_logger: None,
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
  let logger = process.new_name("test_event_logger")
  let tree =
    start_tree(app.Spec(
      plugins: [
        forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
        app.PluginSpec(
          name: process.new_name("test_plugin_event_logger"),
          plugin: event_logger.new(logger),
          limits: plugin_runner.default_limits,
        ),
      ],
      monitor: Some(
        app.Monitor(
          name: process.new_name("test_dedup"),
          dedup_capacity: 8,
          relays: [test_relay()],
          subscriptions: fn() { [] },
        ),
      ),
      bunker: None,
      event_logger: Some(app.EventLogger(
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
    plugins: [forwarding_spec(process.new_name("test_plugin_forwarding"), seen)],
    monitor: Some(
      app.Monitor(
        name: name,
        dedup_capacity: 8,
        relays: [test_relay()],
        subscriptions: fn() { [] },
      ),
    ),
    bunker: None,
    event_logger: None,
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

/// 常にクラッシュするプラグインの仕様。
fn crashing_spec(
  name: Name(plugin_runner.Msg),
  limits: plugin_runner.Limits,
) -> app.PluginSpec {
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(name: "crashing", children: [], handle: fn(_incoming) {
      panic as "boom"
    }),
    limits: limits,
  )
}

/// 決して戻らないプラグインの仕様。1 件目の実行が打ち切られるまでランナーは
/// 次のイベントを読まない。
fn hanging_spec(
  name: Name(plugin_runner.Msg),
  limits: plugin_runner.Limits,
) -> app.PluginSpec {
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(name: "hanging", children: [], handle: fn(_incoming) {
      process.sleep_forever()
    }),
    limits: limits,
  )
}

/// プラグインを載せた監視ツリー。イベントは偽リレー経由で流し込む。
fn start_plugins_tree(
  reports: Subject(Report),
  dedup_name: Name(dedup.Msg),
  plugins: List(app.PluginSpec),
) -> Pid {
  start_tree(app.Spec(
    plugins: plugins,
    monitor: Some(
      app.Monitor(
        name: dedup_name,
        dedup_capacity: 64,
        relays: [test_relay()],
        subscriptions: fn() { [] },
      ),
    ),
    bunker: None,
    event_logger: None,
    admin: None,
    open: fake_open(reports),
    reconnect_delay_ms: 100,
  ))
}

/// 連番のイベント id。
fn event_ids(prefix: String, count: Int) -> List(String) {
  use _unit, index <- list.index_map(list.repeat(Nil, count))
  prefix <> int.to_string(index)
}

/// 指定した id のイベントを配信し、転送プラグインが全件を順に受け取ることを
/// 確かめる。
fn deliver_and_expect(
  deliver: fn(Event) -> Nil,
  seen: Subject(Event),
  ids: List(String),
  timeout_ms: Int,
) -> Nil {
  list.each(ids, fn(id) { deliver(event_with_id(id)) })
  use id <- list.each(ids)
  assert process.receive(seen, timeout_ms) == Ok(event_with_id(id))
}

/// 名前が新しいプロセスへ再登録されるのを待つ。`named.send` は名前が未登録の
/// あいだメッセージを捨てるため、再登録を待たずに配信すると取りこぼす。
fn await_restart(
  name: Name(plugin_runner.Msg),
  previous: Pid,
  remaining: Int,
) -> Pid {
  case process.named(name), remaining {
    Ok(pid), _ if pid != previous -> pid
    _, 0 -> panic as "the plugin runner was not restarted"
    _, _ -> {
      process.sleep(20)
      await_restart(name, previous, remaining - 1)
    }
  }
}

/// クラッシュし続けるプラグインは監視を巻き添えにしない。ランナーは死なないので
/// スーパーバイザーの再起動が起きず、無効化されるまで自分のプロセスの中で完結
/// する。ディスパッチャーも監視接続も他のプラグインも影響を受けない。
///
/// ワーカーが自分で例外を捕まえて短い理由で exit するため、**このテストでも
/// BEAM の `=ERROR REPORT=` は出ない**。代わりにランナーが 1 行ログ
/// （`handle_event failed (...); n/5`）を最大 5 行出す。
pub fn crashing_plugin_does_not_take_down_the_monitor_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let crashing = process.new_name("test_plugin_crashing")
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      crashing_spec(crashing, plugin_runner.default_limits),
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let assert Opened(_relay_url, connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(crashing)
  let assert Ok(dedup_before) = process.named(dedup_name)

  deliver_and_expect(deliver, seen, event_ids("crash", 20), 2000)

  // ランナーの pid が不変であることが、「スーパーバイザーの再起動が 1 度も
  // 起きていない」という主張そのものである。ワーカーとリンクを張る実装では
  // ここで pid が変わる。
  assert process.named(crashing) == Ok(runner_before)
  // 連続失敗が数え上がって無効化まで到達している。リンクを張る実装ではランナー
  // ごと再起動するため、状態は `Running` に戻ってしまう。
  let assert Some(plugin_runner.Disabled(..)) = plugin_runner.status(crashing)
  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  // 接続が張り直されていない（`rest_for_one` が発火していない）。
  assert process.receive(reports, 300) == Error(Nil)
  assert process.is_alive(tree)
  stop_tree(tree)
}

/// 無効化されたプラグインがいても、他のプラグインにはイベントが届き続ける。
pub fn disabled_plugin_keeps_the_others_running_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let crashing = process.new_name("test_plugin_crashing")
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      crashing_spec(crashing, plugin_runner.default_limits),
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(crashing)

  deliver_and_expect(deliver, seen, event_ids("crash", 20), 2000)
  let assert Some(plugin_runner.Disabled(..)) = plugin_runner.status(crashing)

  deliver_and_expect(deliver, seen, event_ids("after", 5), 2000)
  assert process.named(crashing) == Ok(runner_before)
  stop_tree(tree)
}

/// 決して戻らないプラグインがいても、他のプラグインは待たされない。遅い側は
/// 自分のランナーの中で打ち切られる。
///
/// 打ち切りまでの時間（5000ms）は受信窓（1000ms）より意図的に長く取る。こうする
/// と、ランナーごとに打ち切りを同期で待つ実装ではこのテストが通らない。
pub fn slow_plugin_does_not_block_other_plugins_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      hanging_spec(
        process.new_name("test_plugin_hanging"),
        plugin_runner.Limits(
          handle_timeout_ms: 5000,
          max_queue_len: 1000,
          max_failures: 5,
        ),
      ),
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver_and_expect(deliver, seen, event_ids("slow", 3), 1000)
  stop_tree(tree)
}

/// ランナーを強制終了するとスーパーバイザーが作り直し、次のイベントから配信が
/// 再開する。安全網の確認であり、無効化されたプラグインを再有効化する唯一の
/// 運用手段の確認でもある。
pub fn plugin_runner_is_restarted_when_killed_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let forwarding = process.new_name("test_plugin_forwarding")
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      forwarding_spec(forwarding, seen),
    ])
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver_and_expect(deliver, seen, ["before"], 2000)

  let assert Ok(killed) = process.named(forwarding)
  process.kill(killed)
  let restarted = await_restart(forwarding, killed, 100)
  assert restarted != killed
  deliver_and_expect(deliver, seen, ["after"], 2000)
  stop_tree(tree)
}

/// 子仕様を持つプラグインのテストで使う一意な登録名。BEAM の登録名は VM 全体で
/// 共有なので、テストごとに作り直す。
fn unique_store() -> Atom {
  atom.create(
    "app_test_store_"
    <> int.to_string(unique_integer([atom.create("positive")])),
  )
}

/// fixture の子仕様を本番と同じ経路（`plugin_children.from_dynamic`）で変換する。
fn resolved_children(kinds: List(#(String, Atom))) -> List(Dynamic) {
  use pair <- list.map(kinds)
  child_spec_map(atom.create(pair.0), pair.1)
}

/// 子仕様を申告し、イベントごとに store を 1 つ数え上げるプラグインの仕様。
/// **`!` で送るのは、store が居ないことをランナーに失敗として観測させるため。**
/// `gen_server:cast` 相当だと宛先が居なくても成功し、障害が黙って消える。
fn counting_spec(
  name: Name(plugin_runner.Msg),
  store: Atom,
  kinds: List(#(String, Atom)),
) -> app.PluginSpec {
  let assert Ok(children) =
    plugin_children.from_dynamic(
      dynamic.list(resolved_children(kinds)),
      "counting",
    )
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(
      name: "counting",
      children: children,
      handle: fn(_incoming) {
        store_bump(store)
        Nil
      },
    ),
    limits: plugin_runner.default_limits,
  )
}

/// 登録名が使われる（あるいは解放される）まで待つ。
fn await_registered(store: Atom, registered: Bool, remaining: Int) -> Bool {
  case is_registered(store) == registered, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_registered(store, registered, remaining - 10)
    }
  }
}

/// store が数えた件数が期待どおりになるまで待つ。
fn await_count(store: Atom, expected: Int, remaining: Int) -> Bool {
  case is_registered(store) && store_count(store) == expected, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_count(store, expected, remaining - 10)
    }
  }
}

/// 子仕様を申告したプラグインの子はツリーに載り、`handle_event/1` から名前で
/// 到達できる。状態は呼び出しをまたいで残る。
pub fn stateful_plugin_children_run_in_the_tree_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      counting_spec(process.new_name("test_plugin_counting"), store, [
        #("store", store),
      ]),
    ])
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert is_registered(store)

  list.each(event_ids("counted", 3), fn(id) { deliver(event_with_id(id)) })
  assert await_count(store, 3, 2000)
  stop_tree(tree)
}

/// 子を kill すると専用のスーパーバイザーが作り直し、プラグインは同じ名前で
/// 到達し続ける。作り直された子は状態を失うので 0 から数え直す。監視サブツリーは
/// 巻き添えにならない。
pub fn killed_plugin_child_is_restarted_and_the_plugin_recovers_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      counting_spec(process.new_name("test_plugin_counting"), store, [
        #("store", store),
      ]),
    ])
  let assert Opened(_relay_url, connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(dedup_before) = process.named(dedup_name)
  let before = whereis_name(store)

  kill_registered(store)
  assert await_restarted(store, before, 2000)
  deliver(event_with_id("after_kill"))
  assert await_count(store, 1, 2000)

  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  // 監視接続が張り直されていない（`rest_for_one` が発火していない）。
  assert process.receive(reports, 300) == Error(Nil)
  assert process.is_alive(tree)
  stop_tree(tree)
}

/// クラッシュループする子はプラグイン専用のスーパーバイザーの中で完結する。
/// 許容回数を超えると**そのプラグインの子だけ**がまとめて諦められ、親は再起動も
/// 許容回数の消費もしない。ランナーは生き続け、宛先を失った `handle_event/1` が
/// 連続失敗して `disabled` になる。他のプラグインと監視は影響を受けない。
///
/// このテストは BEAM の `=CRASH REPORT=` / `=SUPERVISOR REPORT=` を出す。
/// **検証したい振る舞いそのもの**なので抑制しない。
pub fn crash_looping_plugin_child_does_not_take_down_the_app_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let store = unique_store()
  let counting = process.new_name("test_plugin_counting")
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      counting_spec(counting, store, [
        #("store", store),
        #("flaky", unique_store()),
      ]),
      forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
    ])
  let assert Opened(_relay_url, connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(counting)
  let assert Ok(dedup_before) = process.named(dedup_name)

  // 専用のスーパーバイザーが諦めると、store も一緒に落ちて名前が解放される。
  assert await_registered(store, False, 5000)
  assert process.is_alive(tree)
  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  assert process.named(counting) == Ok(runner_before)

  // 宛先を失ったプラグインは連続失敗で無効化され、他のプラグインには届き続ける。
  deliver_and_expect(deliver, seen, event_ids("orphan", 5), 2000)
  let assert Some(plugin_runner.Disabled(..)) = plugin_runner.status(counting)
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// プラグイン専用のスーパーバイザーを外から繰り返し強制終了しても、親は再起動を
/// 消費しない。**`Temporary` を選んだ根拠 (b) の回帰テスト**（`app.gleam` 冒頭の
/// doc を参照）。
///
/// Temporary の子は決して再起動されないので、1 度目の kill でその子仕様ごと消え、
/// 以後は kill する対象すら残らない。`Transient` にすると kill のたびに再起動が
/// 起き、その再起動が `plugins`（5/10）の許容回数を消費して、やがてサブツリーが
/// 落ちてランナーが作り直される。下の「ランナーの pid が不変」がその差を捉える。
pub fn killed_plugin_children_supervisor_is_not_restarted_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let counting = process.new_name("test_plugin_counting")
  let dedup_name = process.new_name("test_dedup")
  let tree =
    start_plugins_tree(reports, dedup_name, [
      counting_spec(counting, store, [#("store", store)]),
    ])
  let assert Opened(_relay_url, connection, _socket, _deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(counting)
  let assert Ok(dedup_before) = process.named(dedup_name)

  kill_children_supervisor(store, 8)

  assert process.is_alive(tree)
  assert process.named(counting) == Ok(runner_before)
  assert process.named(dedup_name) == Ok(dedup_before)
  assert process.is_alive(connection)
  // 監視接続が張り直されていない（サブツリーが再起動していない）。
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// store のスーパーバイザーを、生きているあいだ繰り返し強制終了する。Temporary
/// なら 1 度目で対象が消えるので、残りの回は空振りして待つだけになる。
fn kill_children_supervisor(store: Atom, remaining: Int) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      case is_registered(store) {
        True -> process.kill(supervisor_of(store))
        False -> Nil
      }
      process.sleep(20)
      kill_children_supervisor(store, remaining - 1)
    }
  }
}

/// 子の起動に失敗してもアプリの起動は止まらない。理由は 1 行ログに出て、
/// プラグインは子なしで動き続ける（ダッシュボードにも出る）。
pub fn plugin_children_that_fail_to_start_do_not_stop_the_tree_test() {
  let reports = process.new_subject()
  let store = unique_store()
  let counting = process.new_name("test_plugin_counting")
  let tree =
    start_plugins_tree(reports, process.new_name("test_dedup"), [
      counting_spec(counting, store, [#("failing", store)]),
    ])
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert process.is_alive(tree)
  let assert Ok(_runner) = process.named(counting)
  let assert Some(plugin_runner.Running) = plugin_runner.status(counting)
  stop_tree(tree)
}

/// 登録名が別のプロセスに付け替わるまで待つ。
fn await_restarted(store: Atom, previous: Dynamic, remaining: Int) -> Bool {
  case is_registered(store) && whereis_name(store) != previous, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_restarted(store, previous, remaining - 10)
    }
  }
}

/// 検証を通る子仕様。
@external(erlang, "child_fixture", "spec")
fn child_spec_map(kind: Atom, name: Atom) -> Dynamic

/// 登録名が使われているか。
@external(erlang, "child_fixture", "is_registered")
fn is_registered(name: Atom) -> Bool

/// 登録名が指すプロセス（未登録なら atom の `undefined`）。
@external(erlang, "child_fixture", "whereis_name")
fn whereis_name(name: Atom) -> Dynamic

/// store の現在の件数。宛先が居なければ落ちる。
@external(erlang, "child_fixture", "count")
fn store_count(name: Atom) -> Int

/// store を 1 つ数え上げる。宛先が居なければ落ちる。
@external(erlang, "child_fixture", "bump")
fn store_bump(name: Atom) -> Dynamic

/// store を監視しているプラグイン専用のスーパーバイザー。
@external(erlang, "child_fixture", "supervisor_of")
fn supervisor_of(name: Atom) -> Pid

/// 登録名が指すプロセスを強制終了する。
@external(erlang, "child_fixture", "kill_registered")
fn kill_registered(name: Atom) -> Nil

/// テストごとに一意な整数。
@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(Atom)) -> Int
