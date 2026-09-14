import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Down, type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/system
import gleam/result
import gleam/string
import nostr_no_su
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{Loaded, StoredAccount}
import nostr_no_su/config
import nostr_no_su/dedup
import nostr_no_su/hex
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/message
import nostr_no_su/plugin
import nostr_no_su/plugin_children
import nostr_no_su/plugin_runner
import nostr_no_su/random
import nostr_no_su/relay_client
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/time
import pog
import support/nip46_client.{account_for}
import support/postgres
import support/signed_event

const secret = "s3cr3t-token"

const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

/// ストアの最新の内容が変わったことを表す、2 人目の署名者の鍵。
const other_signer_key = "0000000000000000000000000000000000000000000000000000000000000077"

const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

/// 2 人目のクライアントの鍵。承認済みセッションを持たないクライアントとして使う。
const other_client_key = "0000000000000000000000000000000000000000000000000000000000000005"

/// 書き込みが遅いストアで、書き込みの途中に積まれる追加の対象になる署名者の鍵。
const slow_signer_key = "0000000000000000000000000000000000000000000000000000000000000055"

/// 実行時のリレーの増減のテストで、3 人目として追加する署名者の鍵。
const third_signer_key = "0000000000000000000000000000000000000000000000000000000000000099"

/// 偽のストアの書き込みと読み込みが失敗したときの理由。本物のストアの文言を使う。
fn store_failure() -> String {
  account_store.describe(account_store.Unavailable)
}

/// 偽リレーの URL。`fake_open` が報告に添えるだけで、接続先としては使わない。
const test_relay_url = "ws://relay.test"

/// 承認ページを載せる管理 UI の公開 URL。承認フローを有効にするために渡す。
const auth_base = "http://admin.test"

/// 偽リレーがテストへ報告する内容。
type Report {
  /// 接続が開かれた。どのリレーの接続か、所有するアクター、監視対象のソケット
  /// プロセス、そして実際のソケットと同じようにサブツリーへイベントを流し込む
  /// ハンドラーを伴う。ハンドラーは本番の `relay_client` と同じく検証を通した
  /// イベントだけを渡し、検証に通らないイベントを渡すとテストが落ちる。
  Opened(
    relay_url: String,
    connection: Pid,
    socket: Pid,
    deliver: fn(Event) -> Nil,
  )
  /// イベントが送信された。送信に使われたソケットを伴う。
  Published(socket: Pid, event: Event)
}

/// 偽ソケットのプロセスが行った購読の照合の報告。`Report` とは別の subject へ
/// 送る。ソケットのプロセスと接続アクターは別々に送るので、同じ subject に混ぜると
/// 届く順序が決まらず、`reports` を直接受信する既存のテストが不安定になる。
type SubscriptionReport {
  /// 照合で送るはずの REQ と CLOSE。予約した再試行のタイマーが古くて評価しな
  /// かったときも、空の列で報告する。
  Subscribed(relay_url: String, messages: List(message.ClientMessage))
  /// 定義を得られず、再試行を予約した。
  Retrying(relay_url: String)
}

/// 偽ソケットが自分宛てに予約する再試行の待ち時間の延ばし方。
const fake_retry_delay = Backoff(initial_ms: 100, max_ms: 100)

/// 偽リレー。接続をすべて報告し、WebSocket の代わりに監視用の待機プロセスを
/// ツリーへ渡し、送信されたイベントをテストへ転送する。`subscribed` があれば、
/// 本番の `relay_client` と同じく接続アクターとは別のプロセス（ソケット）の中で、
/// 接続直後と張り直しの依頼のたびに `relay_client.sync` で購読を照合して報告する。
fn fake_open(
  reports: Subject(Report),
  subscribed: Option(Subject(SubscriptionReport)),
) -> app.Open {
  fn(relay_url, subscriptions, handle_event, _handle_ok, _authenticator) {
    let ready = process.new_subject()
    let socket =
      process.spawn(fn() {
        let triggers = process.new_subject()
        process.send(ready, triggers)
        case subscribed {
          Some(target) -> {
            process.send(triggers, relay_client.Requested)
            fake_socket_loop(
              target,
              relay_url,
              subscriptions,
              triggers,
              relay_client.new_subscription_state(fake_retry_delay),
            )
          }
          None -> process.sleep_forever()
        }
      })
    let assert Ok(triggers) = process.receive(ready, 1000)
    process.send(
      reports,
      Opened(relay_url, process.self(), socket, fn(sent) {
        handle_event(signed_event.verified(sent))
      }),
    )
    Ok(
      relay_connection.Socket(
        pid: socket,
        publish: fn(published) {
          process.send(reports, Published(socket, published))
        },
        resubscribe: fn() { process.send(triggers, relay_client.Requested) },
      ),
    )
  }
}

/// 偽ソケットの照合のループ。判断は本番と同じ `relay_client.sync` が行い、ここは
/// 結果を報告し、予約の世代を載せた再試行を自分へ送り、状態を置き換えるだけである。
fn fake_socket_loop(
  target: Subject(SubscriptionReport),
  relay_url: String,
  subscriptions: relay_client.Subscriptions,
  triggers: Subject(relay_client.Trigger),
  state: relay_client.SubscriptionState,
) -> Nil {
  let trigger = process.receive_forever(triggers)
  let synced =
    relay_client.sync(state, trigger, subscriptions, fake_retry_delay)
  case synced.schedule_retry {
    Some(reservation) -> {
      process.send(target, Retrying(relay_url))
      let _ =
        process.send_after(
          triggers,
          reservation.delay_ms,
          relay_client.Retried(reservation.generation),
        )
      Nil
    }
    None -> process.send(target, Subscribed(relay_url, synced.messages))
  }
  fake_socket_loop(target, relay_url, subscriptions, triggers, synced.state)
}

/// ツリーを起動する。起動できなければテストを失敗させる。
fn start_tree(spec: app.Spec) -> Pid {
  let assert Ok(started) = app.start(spec)
  started.pid
}

/// 偽リレー 1 本ぶんの仕様。URL は `fake_open` が無視するのでラベルでしかない。
fn test_relay() -> relay_list.Connection {
  named_relay(test_relay_url)
}

/// 指定した URL の偽リレー 1 本ぶんの仕様。バンカーは publisher を URL で
/// 区別するため、複数本を張るテストは別々の URL を渡す。
fn named_relay(url: String) -> relay_list.Connection {
  relay_list.Connection(name: process.new_name("test_relay"), url: url)
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

/// 偽リレー 1 本の上でバンカーだけを動かすツリー。アカウントの読み込みは
/// 署名者 1 件ですぐに成功する。
fn start_bunker_tree(reports: Subject(Report), name: Name(bunker.Msg)) -> Pid {
  start_loading_bunker_tree(
    reports,
    None,
    name,
    store_with_load(fn() { load_signer(signer_key) }),
    fixed_retry_delay,
  )
}

/// 偽リレー 1 本の上で、指定したストアを持つバンカーだけを動かすツリー。
fn start_loading_bunker_tree(
  reports: Subject(Report),
  subscribed: Option(Subject(SubscriptionReport)),
  name: Name(bunker.Msg),
  store: bunker.Store,
  retry_delay: backoff.Backoff,
) -> Pid {
  start_loading_bunker_tree_with_open(
    name,
    store,
    retry_delay,
    fake_open(reports, subscribed),
  )
}

/// `start_loading_bunker_tree` から接続の開き方だけを差し替えられるようにした版。
/// AUTH の受け口など `fake_open` が捨てる引数を確かめるテストが使う。
fn start_loading_bunker_tree_with_open(
  name: Name(bunker.Msg),
  store: bunker.Store,
  retry_delay: backoff.Backoff,
  open: app.Open,
) -> Pid {
  start_tree(app.Spec(
    plugins: [],
    monitor: idle_monitor(),
    bunker: bunker_spec(name, store, [test_relay()], retry_delay),
    admin: None,
    open: open,
    reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    relay_list: process.new_name("test_relay_list"),
  ))
}

/// テストの読み込みの再試行の待ち時間。初期値と上限を同じにして延ばさない。既存の
/// テストは一定の間隔を前提に、読み込みの回数と待ち時間を数える。
const fixed_retry_delay = Backoff(initial_ms: 100, max_ms: 100)

/// バンカーサブツリーの仕様。接続プールとロックのプールは到達できないポートを指し、
/// 偽のストアを使うテストでもサブツリーの形（プール、ロックのプール、アクター、
/// 接続の順）は本番と同じにする。購読は本番と同じく、接続と張り直しのたびに現在の
/// 署名者から組み立て、署名者を問い合わせられなければ定義を得られなかったことにする。
fn bunker_spec(
  name: Name(bunker.Msg),
  store: bunker.Store,
  relays: List(relay_list.Connection),
  retry_delay: backoff.Backoff,
) -> app.Bunker {
  app.Bunker(
    name: name,
    pool: pog.default_config(process.new_name("test_account_pool"))
      |> pog.port(1),
    lock_pool: pog.default_config(process.new_name("test_account_lock_pool"))
      |> pog.port(1),
    settings: bunker.Settings(
      store: store,
      auth_url: Some(fn(token) { auth_base <> "/approve/" <> token }),
      retry_delay: retry_delay,
    ),
    relays: relays,
    subscriptions: fn() {
      bunker.signers(name)
      |> option.to_result(Nil)
      |> result.map(config.bunker_subscriptions(_, 0))
    },
  )
}

/// 監視とプラグインのテストのツリーに載せる、リレーを持たないバンカー。ツリーは常に
/// バンカーを含むので載せるが、テストはバンカーを使わない。リレーを持たせないのは、
/// バンカーの接続が同じ `reports` へ `Opened` を送り、監視の接続の報告と区別できなく
/// なるためである。
fn idle_bunker() -> app.Bunker {
  bunker_spec(
    process.new_name("test_bunker"),
    store_with_load(fn() { Ok(accounts_only([])) }),
    [],
    fixed_retry_delay,
  )
}

/// 監視とバンカーのテストのツリーに載せる、リレーを持たない Monitor。監視の
/// ツリーは常に起動するので載せるが、テストが監視を使わないときに使う。
fn idle_monitor() -> app.Monitor {
  app.Monitor(
    name: process.new_name("test_idle_dedup"),
    dedup_capacity: 8,
    relays: [],
    subscriptions: fn(_relay_url) { fn() { Ok([]) } },
    save_resume: discard_resume_points,
    excludes_kind: event.is_ephemeral,
  )
}

/// 偽のストアが受けた書き込み。secret も含めて記録し、DB に書いた値とメモリの値を
/// 比べられるようにする。
type StoreCall {
  Inserted(signer: String, secret: String, label: String)
  Deleted(signer: String)
  SecretUpdated(signer: String, secret: String)
  LabelUpdated(signer: String, label: String)
  Wrote(write: engine.Write)
}

/// 指定した読み込み関数を持ち、書き込みはすべて成功する偽のストア。
fn store_with_load(
  load: fn() -> Result(bunker.Snapshot, String),
) -> bunker.Store {
  bunker.Store(
    load: load,
    insert: fn(_entry) { Ok(Nil) },
    delete: fn(_signer) { Ok(Nil) },
    update_secret: fn(_signer, _secret) { Ok(Nil) },
    update_label: fn(_signer, _label) { Ok(Nil) },
    write: fn(_write) { Ok(Nil) },
  )
}

/// 書き込みを `calls` へ報告する偽のストア。読み込みは `initial` を返す。`failing`
/// なら書き込みはすべて固定の理由で失敗する。
fn memory_store(
  calls: Subject(StoreCall),
  initial: List(vault.StoredAccount),
  failing: Bool,
) -> bunker.Store {
  let written = fn(call) {
    process.send(calls, call)
    case failing {
      True -> Error(bunker.NotWritten(store_failure()))
      False -> Ok(Nil)
    }
  }
  bunker.Store(
    load: fn() { Ok(accounts_only(initial)) },
    insert: fn(entry: vault.StoredAccount) {
      written(Inserted(
        account.pubkey_hex(entry.account),
        entry.secret,
        entry.label,
      ))
    },
    delete: fn(signer) { written(Deleted(signer)) },
    update_secret: fn(signer, secret) { written(SecretUpdated(signer, secret)) },
    update_label: fn(signer, label) { written(LabelUpdated(signer, label)) },
    write: fn(change) { written(Wrote(change)) },
  )
}

/// `memory_store` と同じく書き込みを `calls` へ報告し、最初の書き込みだけ成功して
/// 以降は固定の理由で失敗する偽のストア。前提の `connect` を書いてから、確かめる
/// 書き込みを失敗させるテストが使う。
fn first_write_succeeds_store(
  calls: Subject(StoreCall),
  initial: List(vault.StoredAccount),
) -> bunker.Store {
  let next_write = call_counter()
  bunker.Store(..memory_store(calls, initial, False), write: fn(write) {
    process.send(calls, Wrote(write))
    case next_write() {
      0 -> Ok(Nil)
      _ -> Error(bunker.NotWritten(store_failure()))
    }
  })
}

/// 指定した秘密鍵の署名者 1 件を、テストの secret 付きで保存した行。
fn stored_signer(key_hex: String) -> vault.StoredAccount {
  StoredAccount(account: account_for(key_hex), secret: secret, label: "")
}

/// 指定した秘密鍵の署名者 1 件を、テストの secret 付きで読み込んだ結果。
fn load_signer(key_hex: String) -> Result(bunker.Snapshot, String) {
  Ok(accounts_only([stored_signer(key_hex)]))
}

/// アカウントだけがあり、セッションと承認待ちが無い読み込みの結果。
fn accounts_only(accounts: List(vault.StoredAccount)) -> bunker.Snapshot {
  bunker.Snapshot(Loaded(accounts: accounts, skipped: []), [], [], [])
}

/// どのリレーにも `stored` を返す、再開点の読み込みの操作。
fn fixed_resume_point(
  stored: Result(Option(Int), String),
) -> fn(String) -> Result(Option(Int), String) {
  fn(_relay_url) { stored }
}

/// 何もせず成功する、再開点の保存の操作。
fn discard_resume_points(_points: List(#(String, Int))) -> Result(Nil, String) {
  Ok(Nil)
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

/// 監視に流す kind 1 の署名済みイベント。`label` を content に入れるので、label が
/// 違えば id も違う（ディスパッチャーは id しか見ない）。
fn note(label: String) -> Event {
  signed_event.new(1, label)
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
  assert bunker.sessions(name) == Ok([])
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

/// バンカーが動いていなければ、承認・拒否・取り消しは `SessionMaybeApplied`
/// （応答が無ければアクターが処理しうる）、一覧は理由を返す。
pub fn session_calls_without_a_bunker_are_not_answered_test() {
  let name = process.new_name("test_bunker")
  assert bunker.revoke(name, "signer", "client")
    == Error(bunker.SessionMaybeApplied(bunker.BunkerDidNotRespond))
  assert bunker.approve(name, "token")
    == Error(bunker.SessionMaybeApplied(bunker.BunkerDidNotRespond))
  assert bunker.deny(name, "token")
    == Error(bunker.SessionMaybeApplied(bunker.BunkerDidNotRespond))
  assert bunker.sessions(name) == Error("bunker is not responding")
  assert bunker.pending(name) == Error("bunker is not responding")
}

/// 管理 UI が使う経路。`connect` 済みのクライアントはセッション一覧に現れ、
/// 取り消すと消え、以降のリクエストは再び認可を求められる。取り消し済みの組を
/// もう一度取り消すと `SessionNotFound` になる。
pub fn sessions_can_be_listed_and_revoked_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert bunker.sessions(name) == Ok([])

  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let assert Ok([session]) = bunker.sessions(name)
  assert session.signer == account.pubkey_hex(signer)
  assert session.client == account.pubkey_hex(client)
  assert session.perms == ""

  assert bunker.revoke(
      name,
      account.pubkey_hex(signer),
      account.pubkey_hex(client),
    )
    == Ok(Nil)
  assert bunker.sessions(name) == Ok([])
  let assert Error(bunker.SessionNotFound(_)) =
    bunker.revoke(name, account.pubkey_hex(signer), account.pubkey_hex(client))
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
  let assert Ok([entry]) = bunker.pending(name)
  assert entry.client == account.pubkey_hex(client)
  assert bunker.approve(name, "other-token")
    == Error(bunker.SessionNotFound(engine.approval_request_not_found))

  assert bunker.approve(name, entry.token) == Ok(Nil)
  let assert Ok(Published(answered_on, ack)) = process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(ack), "\"id\":\"c1\"")
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  assert bunker.pending(name) == Ok([])
  let signer = account_for(signer_key)
  let assert Ok([session]) = bunker.sessions(name)
  assert session.signer == account.pubkey_hex(signer)
  assert session.client == account.pubkey_hex(client)
  assert session.perms == ""
  stop_tree(tree)
}

/// 書き込めなかった承認・拒否は、メモリの承認待ちを変えず、応答イベントを発行
/// しない（#126 の完了条件）。
pub fn failed_decisions_keep_the_pending_request_and_publish_nothing_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let store = first_write_succeeds_store(calls, [stored_signer(signer_key)])
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", ""))
  let assert Ok(Published(_socket, asked)) = process.receive(reports, 2000)
  assert string.contains(response_body(asked), "\"result\":\"auth_url\"")
  let assert Ok([entry]) = bunker.pending(name)
  let assert Ok(Wrote(engine.InsertPending(..))) = process.receive(calls, 1000)

  assert bunker.approve(name, entry.token)
    == Error(bunker.SessionNotApplied(store_failure()))
  let assert Ok(Wrote(engine.ApprovePending(token: approved_token, ..))) =
    process.receive(calls, 1000)
  assert approved_token == entry.token

  assert bunker.deny(name, entry.token)
    == Error(bunker.SessionNotApplied(store_failure()))
  let assert Ok(Wrote(engine.DeletePending(token: denied_token))) =
    process.receive(calls, 1000)
  assert denied_token == entry.token

  assert bunker.pending(name) == Ok([entry])
  assert bunker.sessions(name) == Ok([])
  assert process.receive(reports, 300) == Error(Nil)

  assert bunker.approve(name, "unknown-token")
    == Error(bunker.SessionNotFound(engine.approval_request_not_found))
  assert bunker.deny(name, "unknown-token")
    == Error(bunker.SessionNotFound(engine.approval_request_not_found))
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// 書き込めなかった取り消しは、メモリのセッションを変えない。
pub fn a_failed_revocation_keeps_the_session_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let store = first_write_succeeds_store(calls, [stored_signer(signer_key)])
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)
  let assert Ok([session]) = bunker.sessions(name)
  let assert Ok(Wrote(engine.InsertSession(..))) = process.receive(calls, 1000)

  assert bunker.revoke(name, session.signer, session.client)
    == Error(bunker.SessionNotApplied(store_failure()))
  let assert Ok(Wrote(engine.DeleteSession(signer:, client:))) =
    process.receive(calls, 1000)
  assert #(signer, client) == #(session.signer, session.client)
  assert bunker.sessions(name) == Ok([session])

  let assert Error(bunker.SessionNotFound(_reason)) =
    bunker.revoke(name, session.signer, other_client_key)
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// `connect` の書き込みがすべて失敗しても、secret の一致した `connect` でも
/// 承認待ちを作る `connect` でもメモリを変えずに `connection_not_saved` を返し、
/// ストアの理由をクライアントへ漏らさない。承認待ちを作る `connect` も
/// `auth_url` を返さない。
pub fn failed_connects_keep_the_memory_and_hide_the_reason_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let store =
    memory_store(process.new_subject(), [stored_signer(signer_key)], True)
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, refused)) = process.receive(reports, 2000)
  let body = response_body(refused)
  assert string.contains(body, "\"id\":\"c1\"")
  assert string.contains(body, engine.connection_not_saved)
  assert !string.contains(body, store_failure())
  assert bunker.sessions(name) == Ok([])

  deliver(connect_request("c2", ""))
  let assert Ok(Published(_socket, refused)) = process.receive(reports, 2000)
  let body = response_body(refused)
  assert string.contains(body, "\"id\":\"c2\"")
  assert string.contains(body, engine.connection_not_saved)
  assert !string.contains(body, "auth_url")
  assert !string.contains(body, store_failure())
  assert bunker.pending(name) == Ok([])
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// `logout` の `DeleteSession` の書き込みが失敗しても、クライアントの後始末を
/// 止めないため `ack` を返し、セッションはメモリに残る。
pub fn a_failed_logout_acknowledges_and_keeps_the_session_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let store =
    bunker.Store(
      ..memory_store(process.new_subject(), [stored_signer(signer_key)], False),
      write: fn(write) {
        case write {
          engine.DeleteSession(..) -> Error(bunker.NotWritten(store_failure()))
          _ -> Ok(Nil)
        }
      },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)
  let assert Ok([session]) = bunker.sessions(name)

  deliver(request("l1", "logout", "[]"))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  let body = response_body(ack)
  assert string.contains(body, "\"id\":\"l1\"")
  assert string.contains(body, "\"result\":\"ack\"")
  assert !string.contains(body, store_failure())
  assert bunker.sessions(name) == Ok([session])
  stop_tree(tree)
}

/// 書き込みに失敗した `connect` のイベント id は `seen` に残るので、リレーが
/// 同じイベントを再配送しても 2 度目の書き込みも応答も起きない。
pub fn a_redelivered_failed_connect_is_not_answered_again_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_write = call_counter()
  let store =
    bunker.Store(
      ..memory_store(process.new_subject(), [stored_signer(signer_key)], False),
      write: fn(_write) {
        case next_write() {
          0 -> Error(bunker.NotWritten(store_failure()))
          _ -> Ok(Nil)
        }
      },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let connect = connect_request("c1", "")
  deliver(connect)
  let assert Ok(Published(_socket, refused)) = process.receive(reports, 2000)
  assert string.contains(response_body(refused), engine.connection_not_saved)

  deliver(connect)
  assert process.receive(reports, 300) == Error(Nil)
  assert bunker.pending(name) == Ok([])
  assert next_write() == 1
  stop_tree(tree)
}

/// NIP-46 の書き込みの結果が曖昧だったときも読み直しに移るが、`Loading` の間に
/// 届いた書き込みでは読み直しを積み増さない。再試行の待ちは、再試行のタイマーが
/// 待ちの間に発火しないよう既定より長くする。
pub fn unconfirmed_nip46_writes_reload_once_and_not_while_loading_test() {
  let reports = process.new_subject()
  let loads = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_load = call_counter()
  let store =
    bunker.Store(
      ..memory_store(process.new_subject(), [], False),
      load: fn() {
        process.send(loads, Nil)
        case next_load() {
          0 -> load_signer(signer_key)
          _ -> Error(store_failure())
        }
      },
      write: fn(_write) { Error(bunker.MaybeWritten(store_failure())) },
    )
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store,
      Backoff(initial_ms: 5000, max_ms: 5000),
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(Nil) = process.receive(loads, 2000)

  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, refused)) = process.receive(reports, 2000)
  assert string.contains(response_body(refused), engine.connection_not_saved)
  let assert Ok(Nil) = process.receive(loads, 1000)
  assert bunker.accounts(name)
    == Error("account store unavailable: " <> store_failure())

  deliver(connect_request("c2", ""))
  let assert Ok(Published(_socket, refused)) = process.receive(reports, 2000)
  assert string.contains(response_body(refused), engine.connection_not_saved)
  assert process.receive(loads, 500) == Error(Nil)
  assert bunker.accounts(name)
    == Error("account store unavailable: " <> store_failure())
  assert bunker.sessions(name)
    == Error("account store unavailable: " <> store_failure())
  assert bunker.pending(name)
    == Error("account store unavailable: " <> store_failure())
  stop_tree(tree)
}

/// バンカーが読み込み済みか問い合わせ続け、`Ok` になるまで待つ。
fn await_loaded(name: Name(bunker.Msg), remaining: Int) -> Bool {
  case bunker.accounts(name) {
    Ok(_) -> True
    Error(_) ->
      case remaining <= 0 {
        True -> False
        False -> {
          process.sleep(20)
          await_loaded(name, remaining - 20)
        }
      }
  }
}

/// 承認の書き込みの結果が曖昧だったときは、承認待ちとセッションを変えずに読み
/// 直しへ移り、`ack` を発行しない。読み直しが成功した後、同じトークンで承認し
/// 直すと `Ok` になり、`ack` が 1 回発行される（#220 の方針 1 節）。
pub fn an_unconfirmed_approval_reloads_once_and_can_be_approved_again_test() {
  let reports = process.new_subject()
  let loads = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let base = committed_but_timed_out_store(database)
  let next_write = call_counter()
  let store =
    bunker.Store(
      ..base,
      load: fn() {
        process.send(loads, Nil)
        base.load()
      },
      write: fn(write) {
        case next_write() {
          1 -> Error(bunker.MaybeWritten(store_failure()))
          _ -> base.write(write)
        }
      },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, socket, deliver) =
    await_connection(reports)
  let assert Ok(Nil) = process.receive(loads, 2000)

  deliver(connect_request("c1", ""))
  let assert Ok(Published(_socket, asked)) = process.receive(reports, 2000)
  assert string.contains(response_body(asked), "\"result\":\"auth_url\"")
  let assert Ok([entry]) = bunker.pending(name)

  assert bunker.approve(name, entry.token)
    == Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))
  let assert Ok(Nil) = process.receive(loads, 1000)
  assert process.receive(loads, 300) == Error(Nil)
  assert process.receive(reports, 300) == Error(Nil)
  assert bunker.pending(name) == Ok([entry])
  assert bunker.sessions(name) == Ok([])

  assert await_loaded(name, 2000)
  assert bunker.approve(name, entry.token) == Ok(Nil)
  let assert Ok(Published(answered_on, ack)) = process.receive(reports, 2000)
  assert answered_on == socket
  assert string.contains(response_body(ack), "\"id\":\"c1\"")
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// 承認が実は書けていて、読み直しの後にも `ack` を発行しないとき、クライアントは
/// 応答を受け取れないが、承認済みのセッションは残る。
pub fn a_committed_but_unconfirmed_approval_is_reloaded_without_an_ack_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let base = committed_but_timed_out_store(database)
  let store =
    bunker.Store(..base, write: fn(write) {
      case write {
        engine.ApprovePending(..) -> {
          let _ = base.write(write)
          Error(bunker.MaybeWritten(store_failure()))
        }
        _ -> base.write(write)
      }
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", ""))
  let assert Ok(Published(_socket, asked)) = process.receive(reports, 2000)
  assert string.contains(response_body(asked), "\"result\":\"auth_url\"")
  let assert Ok([entry]) = bunker.pending(name)

  assert bunker.approve(name, entry.token)
    == Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))

  assert await_loaded(name, 2000)
  assert bunker.pending(name) == Ok([])
  let assert Ok([session]) = bunker.sessions(name)
  assert session.client == account.pubkey_hex(account_for(client_key))
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// 拒否と取り消しの書き込みの結果が曖昧だったときも、同じ読み直しに移り、理由を
/// 報告する。
pub fn unconfirmed_denials_and_revocations_are_reported_test() {
  let reports = process.new_subject()
  let loads = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let base = committed_but_timed_out_store(database)
  let store =
    bunker.Store(
      ..base,
      load: fn() {
        process.send(loads, Nil)
        base.load()
      },
      write: fn(write) {
        case write {
          engine.DeletePending(..) | engine.DeleteSession(..) ->
            Error(bunker.MaybeWritten(store_failure()))
          _ -> base.write(write)
        }
      },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(Nil) = process.receive(loads, 2000)

  deliver(connect_request("c1", ""))
  let assert Ok(Published(_socket, asked)) = process.receive(reports, 2000)
  assert string.contains(response_body(asked), "\"result\":\"auth_url\"")
  let assert Ok([pending]) = bunker.pending(name)

  assert bunker.deny(name, pending.token)
    == Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))
  let assert Ok(Nil) = process.receive(loads, 1000)
  assert bunker.pending(name) == Ok([pending])
  assert bunker.sessions(name) == Ok([])

  assert await_loaded(name, 2000)
  deliver(connect_request_from(other_client_key, "c2", secret))
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)
  let assert Ok([session]) = bunker.sessions(name)

  assert bunker.revoke(name, session.signer, session.client)
    == Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))
  let assert Ok(Nil) = process.receive(loads, 1000)
  assert bunker.pending(name) == Ok([pending])
  assert bunker.sessions(name) == Ok([session])
  stop_tree(tree)
}

/// 読み込みが終わっていない間の承認・拒否・取り消しはストアを呼ばずに拒否する
/// （#202 の方針 3 節）。
pub fn decisions_and_revocations_before_loading_do_not_reach_the_store_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_load = call_counter()
  let store =
    bunker.Store(
      ..memory_store(calls, [], False),
      load: fn() {
        case next_load() {
          0 -> load_signer(signer_key)
          _ -> Error(store_failure())
        }
      },
      insert: fn(entry: vault.StoredAccount) {
        process.send(
          calls,
          Inserted(account.pubkey_hex(entry.account), entry.secret, entry.label),
        )
        Error(bunker.MaybeWritten(store_failure()))
      },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", ""))
  let assert Ok(Published(_socket, _asked)) = process.receive(reports, 2000)
  let assert Ok([pending]) = bunker.pending(name)
  let assert Ok(Wrote(engine.InsertPending(..))) = process.receive(calls, 1000)
  deliver(connect_request_from(other_client_key, "c2", secret))
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)
  let assert Ok([session]) = bunker.sessions(name)
  let assert Ok(Wrote(engine.InsertSession(..))) = process.receive(calls, 1000)

  // 読み直しの失敗が続く状態にする。
  let assert Error(bunker.MaybeApplied(_)) =
    bunker.add_account(name, account_for(other_signer_key), "")
  let assert Ok(Inserted(..)) = process.receive(calls, 1000)

  assert bunker.approve(name, pending.token)
    == Error(bunker.SessionNotReady("accounts are not loaded yet"))
  assert bunker.deny(name, pending.token)
    == Error(bunker.SessionNotReady("accounts are not loaded yet"))
  assert bunker.revoke(name, session.signer, session.client)
    == Error(bunker.SessionNotReady("accounts are not loaded yet"))
  assert process.receive(calls, 100) == Error(Nil)
  // メモリを変えていないことは、直前の `calls` が空であることで確かめている
  // （読み直しの失敗が続く間、一覧そのものは理由を返す）。
  let assert Error(_) = bunker.pending(name)
  let assert Error(_) = bunker.sessions(name)
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
      monitor: idle_monitor(),
      bunker: bunker_spec(
        process.new_name("test_bunker"),
        store_with_load(fn() { load_signer(signer_key) }),
        [relay_a, relay_b],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      // 再接続で送信手段が戻ってこないよう、テストより十分に長く取る。
      reconnect_delay: Backoff(initial_ms: 60_000, max_ms: 60_000),
      relay_list: process.new_name("test_relay_list"),
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

/// 偽リレー 1 本の上で監視だけを動かすツリー。受信したイベントは `seen` に
/// 転送するプラグインへ渡る。
fn start_monitor_tree(
  reports: Subject(Report),
  seen: Subject(Event),
  name: Name(dedup.Msg),
  excludes_kind: fn(Int) -> Bool,
) -> Pid {
  start_monitor_tree_with_open(
    seen,
    name,
    excludes_kind,
    fake_open(reports, None),
  )
}

/// `start_monitor_tree` から接続の開き方だけを差し替えられるようにした版。
/// AUTH の受け口など `fake_open` が捨てる引数を確かめるテストが使う。
fn start_monitor_tree_with_open(
  seen: Subject(Event),
  name: Name(dedup.Msg),
  excludes_kind: fn(Int) -> Bool,
  open: app.Open,
) -> Pid {
  start_tree(app.Spec(
    plugins: [forwarding_spec(process.new_name("test_plugin_forwarding"), seen)],
    monitor: app.Monitor(
      name: name,
      dedup_capacity: 8,
      relays: [test_relay()],
      subscriptions: fn(_relay_url) { fn() { Ok([]) } },
      save_resume: discard_resume_points,
      excludes_kind: excludes_kind,
    ),
    bunker: idle_bunker(),
    admin: None,
    open: open,
    reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    relay_list: process.new_name("test_relay_list"),
  ))
}

/// ephemeral イベント（kind 20000〜29999。バンカー自身の NIP-46 通信を含む）
/// は監視の対象外。同じ購読で届いても、プラグインには渡らず後続の非 ephemeral
/// イベントだけが渡る。
pub fn monitor_drops_ephemeral_events_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let tree =
    start_monitor_tree(
      reports,
      seen,
      process.new_name("test_dedup"),
      event.is_ephemeral,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let below_range = signed_event.new(19_999, "below-range")
  let above_range = signed_event.new(30_000, "above-range")
  deliver(signed_event.new(20_000, "lower-bound"))
  deliver(signed_event.new(event.nip46_kind, "nip46"))
  deliver(signed_event.new(29_999, "upper-bound"))
  deliver(below_range)
  deliver(above_range)
  // 送信順に処理されるため、ephemeral の 3 件がすべて落ちていれば範囲外の
  // 2 件だけがこの順で届く。
  assert process.receive(seen, 2000) == Ok(below_range)
  assert process.receive(seen, 2000) == Ok(above_range)
  stop_tree(tree)
}

/// `excludes_kind` は `Monitor` の仕様から渡した述語がそのまま効き、既定の
/// ephemeral 判定に固定されていない。
pub fn monitor_uses_configured_excluded_kinds_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let tree =
    start_monitor_tree(reports, seen, process.new_name("test_dedup"), fn(kind) {
      kind == 1
    })
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let nip46 = signed_event.new(event.nip46_kind, "nip46")
  deliver(note("dropped"))
  deliver(nip46)
  // kind 1 を落とす述語なので、kind 1 のイベントは届かず kind 24133 が届く。
  assert process.receive(seen, 2000) == Ok(nip46)
  stop_tree(tree)
}

/// 監視接続で受信したイベントはプラグインに届き、経由するディスパッチャーを kill
/// した後も届き続ける。
pub fn monitor_dispatcher_survives_being_killed_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let name = process.new_name("test_dedup")
  let tree = start_monitor_tree(reports, seen, name, event.is_ephemeral)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let first = note("first")
  deliver(first)
  assert process.receive(seen, 2000) == Ok(first)

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let second = note("second")
  deliver(second)
  assert process.receive(seen, 2000) == Ok(second)
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
    monitor: app.Monitor(
      name: dedup_name,
      dedup_capacity: 64,
      relays: [test_relay()],
      subscriptions: fn(_relay_url) { fn() { Ok([]) } },
      save_resume: discard_resume_points,
      excludes_kind: event.is_ephemeral,
    ),
    bunker: idle_bunker(),
    admin: None,
    open: fake_open(reports, None),
    reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    relay_list: process.new_name("test_relay_list"),
  ))
}

/// 連番のイベントの label。
fn event_labels(prefix: String, count: Int) -> List(String) {
  use _unit, index <- list.index_map(list.repeat(Nil, count))
  prefix <> int.to_string(index)
}

/// 指定した label のイベントを配信し、転送プラグインが全件を順に受け取ることを
/// 確かめる。
fn deliver_and_expect(
  deliver: fn(Event) -> Nil,
  seen: Subject(Event),
  labels: List(String),
  timeout_ms: Int,
) -> Nil {
  let events = list.map(labels, note)
  list.each(events, deliver)
  use sent <- list.each(events)
  assert process.receive(seen, timeout_ms) == Ok(sent)
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

  deliver_and_expect(deliver, seen, event_labels("crash", 20), 2000)

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

/// crashing と forwarding を載せたツリーを起動し、crashing を無効にする。呼び出し側が
/// 続きを検証できるよう、ツリー、仕様の一覧、配信関数、転送先、ランナーの名前と無効化
/// 前の pid を返す。
fn start_tree_with_a_disabled_plugin() -> #(
  Pid,
  List(app.PluginSpec),
  fn(Event) -> Nil,
  Subject(Event),
  Name(plugin_runner.Msg),
  Pid,
) {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let crashing = process.new_name("test_plugin_crashing")
  let specs = [
    crashing_spec(crashing, plugin_runner.default_limits),
    forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
  ]
  let tree = start_plugins_tree(reports, process.new_name("test_dedup"), specs)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(runner_before) = process.named(crashing)

  deliver_and_expect(deliver, seen, event_labels("crash", 20), 2000)
  let assert Some(plugin_runner.Disabled(..)) = plugin_runner.status(crashing)

  #(tree, specs, deliver, seen, crashing, runner_before)
}

/// 無効化されたプラグインがいても、他のプラグインにはイベントが届き続ける。
pub fn disabled_plugin_keeps_the_others_running_test() {
  let #(tree, _specs, deliver, seen, crashing, runner_before) =
    start_tree_with_a_disabled_plugin()

  deliver_and_expect(deliver, seen, event_labels("after", 5), 2000)
  assert process.named(crashing) == Ok(runner_before)
  stop_tree(tree)
}

/// 管理 UI の再有効化は名前でランナーを引き、無効化されたプラグインを
/// `Running` に戻す。ランナーのプロセスは不変である。
pub fn reenable_plugin_finds_the_runner_by_name_test() {
  let #(tree, specs, _deliver, _seen, crashing, runner_before) =
    start_tree_with_a_disabled_plugin()

  assert app.reenable_plugin(specs, "crashing") == Ok(Nil)
  assert plugin_runner.status(crashing) == Some(plugin_runner.Running)
  assert process.named(crashing) == Ok(runner_before)
  stop_tree(tree)
}

/// 名前に一致するプラグインが無ければ `PluginNotFound` を返す。
pub fn reenable_plugin_with_an_unknown_name_is_not_found_test() {
  assert app.reenable_plugin([], "missing")
    == Error(admin.PluginNotFound("plugin not found"))
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
  deliver_and_expect(deliver, seen, event_labels("slow", 3), 1000)
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
      0,
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

  list.each(event_labels("counted", 3), fn(label) { deliver(note(label)) })
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
  deliver(note("after_kill"))
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
  deliver_and_expect(deliver, seen, event_labels("orphan", 5), 2000)
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

/// 単調増加する時計の現在値。
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

/// 単調増加する時計の現在値（ミリ秒）。
fn monotonic_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

/// 呼ぶたびに 0, 1, 2, ... を返す関数。`load` はバンカーアクターの中で呼ばれ、
/// Gleam には可変の変数が無いので、回数は別のアクターで数える。
fn call_counter() -> fn() -> Int {
  let assert Ok(counter) =
    actor.new(0)
    |> actor.on_message(fn(count, reply: Subject(Int)) {
      process.send(reply, count)
      actor.continue(count + 1)
    })
    |> actor.start
  fn() { process.call(counter.data, 1000, fn(reply) { reply }) }
}

/// `duration_ms` の間に届いたメッセージの件数。
fn count_within(subject: Subject(Nil), duration_ms: Int) -> Int {
  count_until(subject, monotonic_ms() + duration_ms, 0)
}

/// 期限までに届いたメッセージを数える。
fn count_until(subject: Subject(Nil), deadline: Int, count: Int) -> Int {
  let remaining = deadline - monotonic_ms()
  case remaining > 0 && process.receive(subject, remaining) == Ok(Nil) {
    True -> count_until(subject, deadline, count + 1)
    False -> count
  }
}

/// すでに届いているメッセージを捨てる。
fn drain(subject: Subject(Nil)) -> Nil {
  case process.receive(subject, 0) {
    Ok(Nil) -> drain(subject)
    Error(Nil) -> Nil
  }
}

/// バンカーが指定した署名者を持つまで待つ。
fn await_signers(
  name: Name(bunker.Msg),
  expected: List(String),
  remaining: Int,
) -> Bool {
  case bunker.signers(name) == Some(expected), remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(20)
      await_signers(name, expected, remaining - 20)
    }
  }
}

/// テスト用のクライアントから、指定した署名者宛に secret 付きで送る `connect`。
fn connect_request_to(signer_key_hex: String, id: String) -> Event {
  let signer = account_for(signer_key_hex)
  nip46_client.request_event(
    account_for(client_key),
    signer,
    nip46_client.connect_body(signer, secret, id),
    time.now_seconds(),
  )
}

/// 読み込みが遅くても、接続が最初に開く購読には読み込んだ署名者が入る。
/// `LoadAccounts` を initialiser が送るので、接続が送る `GetSigners` は必ず読み込みの
/// 後に処理される。送信を initialiser 以外へ移すと、最初の購読が空になって落ちる。
pub fn the_first_subscription_includes_the_loaded_signers_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      process.new_name("test_bunker"),
      store_with_load(fn() {
        process.sleep(300)
        load_signer(signer_key)
      }),
      fixed_retry_delay,
    )
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, filter)])) =
    process.receive(subscribed, 3000)
  assert filter.p_tags == Some([account.pubkey_hex(account_for(signer_key))])
  stop_tree(tree)
}

/// ストアに到達できない間はリクエストに応答せず、読み込みが成功した後に応答する。
/// 起動時に開いた購読は空で、読み込みの成功で再接続を待たずに張り直され、署名者が
/// 入る。
pub fn a_bunker_recovers_when_the_account_store_comes_back_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_call = call_counter()
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      store_with_load(fn() {
        case next_call() < 2 {
          True -> Error("database is unreachable or timed out")
          False -> load_signer(signer_key)
        }
      }),
      // 失敗の間にリクエストを確実に届けられるよう、再試行を遅めにする。
      Backoff(initial_ms: 500, max_ms: 500),
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(Subscribed(_relay_url, [])) = process.receive(subscribed, 2000)
  deliver(connect_request("c1", secret))
  assert process.receive(reports, 200) == Error(Nil)

  assert await_signers(name, [signer], 3000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, filter)])) =
    process.receive(subscribed, 2000)
  assert filter.p_tags == Some([signer])
  deliver(connect_request("c2", secret))
  // 次の報告が応答であることが、接続が開き直されていないことを示す。
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 読み込みに失敗し続けるバンカーを kill しても、再試行の系列は増えない。再試行を
/// 名前付き subject へ予約すると、古いタイマーが再起動後のアクターに届いて系列が
/// 再起動のたびに 1 本ずつ増え、再起動後の回数が約 2 倍になる。
pub fn retries_do_not_multiply_across_restarts_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store_with_load(fn() {
        process.send(calls, Nil)
        Error("database is unreachable or timed out")
      }),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  let before = count_within(calls, 1000)
  assert before >= 5

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  drain(calls)
  let after = count_within(calls, 1000)
  assert after * 2 <= before * 3
  stop_tree(tree)
}

/// 読み込みの再試行の待ち時間は失敗のたびに倍に延び、読み込みに成功した後の失敗では
/// 初期値から数え直す。タイマーは予約した時間より早く鳴らないので、延びたことは次の
/// 読み込みが待ち時間より前に来ないことで確かめる。
pub fn load_retries_back_off_and_start_over_after_a_success_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_call = call_counter()
  let store =
    bunker.Store(
      ..store_with_load(fn() {
        process.send(calls, Nil)
        case next_call() {
          4 -> load_signer(signer_key)
          _ -> Error("database is unreachable or timed out")
        }
      }),
      insert: fn(_entry) { Error(bunker.MaybeWritten(store_failure())) },
    )
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store,
      Backoff(initial_ms: 50, max_ms: 3200),
    )
  // 1 回目と 2 回目の失敗の間は 50ms。以後は 100、200、400ms と延びる。窓は延びた後の
  // 待ち時間より短く、延びる前の待ち時間の 1.5 倍にする。
  let assert Ok(Nil) = process.receive(calls, 2000)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert process.receive(calls, 75) == Error(Nil)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert process.receive(calls, 150) == Error(Nil)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert process.receive(calls, 300) == Error(Nil)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert await_signers(
    name,
    [account.pubkey_hex(account_for(signer_key))],
    2000,
  )

  // 結果が曖昧な書き込みの後の読み直しはすぐに行われて失敗する。待ち時間が初期値に
  // 戻っていれば次は 50ms 後で、延びたままなら 800ms 後になる。
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let assert Ok(Nil) = process.receive(calls, 2000)
  let assert Ok(Nil) = process.receive(calls, 700)
  stop_tree(tree)
}

/// 再起動したバンカーは、起動時の仕様ではなくストアの最新からアカウントを読み直す。
pub fn a_restarted_bunker_reloads_the_accounts_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_call = call_counter()
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store_with_load(fn() {
        case next_call() {
          0 -> load_signer(signer_key)
          _ -> load_signer(other_signer_key)
        }
      }),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert bunker.signers(name)
    == Some([account.pubkey_hex(account_for(signer_key))])

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert bunker.signers(name)
    == Some([account.pubkey_hex(account_for(other_signer_key))])
  deliver(connect_request_to(other_signer_key, "c1"))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  let body =
    nip46_client.decrypt_response(
      account_for(client_key),
      account_for(other_signer_key),
      ack,
    )
  assert string.contains(body, "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 再起動しても、接続済みのクライアントは再 `connect` なしで署名でき、承認待ちは
/// DB に保存した経過時間のまま残って承認できる（#215 の受け入れ条件）。
pub fn a_restarted_bunker_restores_sessions_and_pending_requests_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)
  let assert Ok([session]) = bunker.sessions(name)

  deliver(connect_request_from(other_client_key, "c2", ""))
  let assert Ok(Published(_socket, _asked)) = process.receive(reports, 2000)
  let assert Ok([entry]) = bunker.pending(name)

  // DB の作成時刻だけをずらし、メモリではなく DB から読み込んだことを見分ける。
  let shifted = engine.Pending(..entry, created_at: entry.created_at - 300)
  process.call(database, 1000, ApplyWrite(
    engine.InsertPending(pending: shifted, replaced: [entry.token], evicted: []),
    _,
  ))

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert bunker.sessions(name) == Ok([session])
  assert bunker.pending(name) == Ok([shifted])

  let draft = "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}"
  deliver(request("s1", "sign_event", "[\"" <> draft <> "\"]"))
  let assert Ok(Published(_socket, signed)) = process.receive(reports, 2000)
  let signed_body = response_body(signed)
  assert string.contains(signed_body, "\"id\":\"s1\"")
  assert string.contains(signed_body, "\\\"sig\\\"")

  assert bunker.approve(name, entry.token) == Ok(Nil)
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  let ack_body =
    nip46_client.decrypt_response(
      account_for(other_client_key),
      account_for(signer_key),
      ack,
    )
  assert string.contains(ack_body, "\"id\":\"c2\"")
  assert string.contains(ack_body, "\"result\":\"ack\"")
  stop_tree(tree)
}

/// ストアの読み込みに失敗し続けても、監視のプラグインにはイベントが届き続け、
/// バンカーもルートも再起動しない。読み込みでアクターのループが止まっていても、
/// 問い合わせは `named.call` のタイムアウトより前に応答する。
pub fn a_failing_account_store_does_not_affect_the_monitor_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let monitor_relay = test_relay()
  let tree =
    start_tree(app.Spec(
      plugins: [
        forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
      ],
      monitor: app.Monitor(
        name: process.new_name("test_dedup"),
        dedup_capacity: 8,
        relays: [monitor_relay],
        subscriptions: fn(_relay_url) { fn() { Ok([]) } },
        save_resume: discard_resume_points,
        excludes_kind: event.is_ephemeral,
      ),
      bunker: bunker_spec(
        bunker_name,
        store_with_load(fn() {
          // 到達できない DB に対するチェックアウト待ちを模す。
          process.sleep(1500)
          Error("database is unreachable or timed out")
        }),
        [named_relay("ws://bunker.test")],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    ))
  let assert Opened(first_url, _connection_1, _socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, _socket_2, deliver_2) =
    await_connection(reports)
  let deliver = case first_url == monitor_relay.url {
    True -> deliver_1
    False -> deliver_2
  }
  let assert Ok(bunker_before) = process.named(bunker_name)

  deliver_and_expect(deliver, seen, event_labels("while-failing", 3), 2000)
  let asked_at = monotonic_ms()
  // 読み込めていない間 `bunker.sessions` は理由を返すので、応答したことは
  // `named.call` の `Some` で確かめる。
  let assert Some(_) = named.call(bunker_name, 5000, bunker.GetSessions)
  assert monotonic_ms() - asked_at < 5000
  assert process.named(bunker_name) == Ok(bunker_before)
  assert process.is_alive(tree)
  stop_tree(tree)
}

// --- 監視の購読 ---

/// バンカーにリレーを持たせず、監視だけがリレー接続を持つツリー。購読は本番と
/// 同じ `nostr_no_su.monitor_subscriptions` から組み立てる。バンカーにリレーを
/// 持たせないのは、購読の報告（`subscribed`）がすべて監視の接続のものになる
/// ようにするためである。
fn monitored_accounts_spec(
  reports: Subject(Report),
  subscribed: Subject(SubscriptionReport),
  bunker_name: Name(bunker.Msg),
  store: bunker.Store,
  relays: List(relay_list.Connection),
  load_resume: fn(String) -> Result(Option(Int), String),
) -> app.Spec {
  let dedup_name = process.new_name("test_dedup")
  app.Spec(
    plugins: [],
    monitor: app.Monitor(
      name: dedup_name,
      dedup_capacity: 64,
      relays: relays,
      subscriptions: nostr_no_su.monitor_subscriptions(
        bunker_name,
        dedup_name,
        load_resume,
        _,
      ),
      save_resume: discard_resume_points,
      excludes_kind: event.is_ephemeral,
    ),
    bunker: bunker_spec(bunker_name, store, [], fixed_retry_delay),
    admin: None,
    open: fake_open(reports, Some(subscribed)),
    reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
    relay_list: process.new_name("test_relay_list"),
  )
}

/// 報告が、指定したリレーの接続の REQ 1 件か。
fn requests_on(report: SubscriptionReport, relay_url: String) -> Bool {
  case report {
    Subscribed(url, [message.Req(..)]) -> url == relay_url
    _ -> False
  }
}

/// 起動直後の監視の購読は、読み込みに時間がかかっても読み込み済みの署名者を含み、
/// 読み込みの成功による張り直しで同じ内容の REQ が 1 回余計に送られる（決定 11）。
pub fn the_first_monitor_subscription_includes_the_loaded_signers_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_tree(monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() {
        // 読み込みが接続の最初の評価より遅れて終わることを模す。
        process.sleep(300)
        load_signer(signer_key)
      }),
      [test_relay()],
      fixed_resume_point(Ok(Some(1234))),
    ))
  let assert Ok(Subscribed(_relay_url, [message.Req("nostr-no-su", filter)])) =
    process.receive(subscribed, 2000)
  assert filter.authors == Some([signer])
  assert filter.since == Some(1234)

  let #(_skipped, second) =
    receive_until(subscribed, requests_on(_, test_relay_url), 2000)
  assert second
    == Ok(Subscribed(test_relay_url, [message.Req("nostr-no-su", filter)]))
  stop_tree(tree)
}

/// 監視の購読は、登録アカウントの追加・削除に合わせて張り直される。追加の時刻は
/// 追加の呼び出しの前後の現在時刻の範囲に収まり、以後の張り直しでも遡らない。
pub fn the_monitor_subscription_follows_account_changes_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let other_signer = account.pubkey_hex(account_for(other_signer_key))
  let spec =
    monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      memory_store(calls, [], False),
      [test_relay()],
      fixed_resume_point(Ok(None)),
    )
  let tree = start_tree(spec)
  assert process.receive(subscribed, 2000) == Ok(Subscribed(test_relay_url, []))

  let before_first_add = time.now_seconds()
  assert app.add_account(spec, account_for(signer_key), "main") == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, first_filter)])) =
    process.receive(subscribed, 2000)
  assert first_filter.authors == Some([signer])
  let assert Some(since_after_first_add) = first_filter.since
  assert since_after_first_add >= before_first_add
  assert since_after_first_add <= time.now_seconds()

  assert app.add_account(spec, account_for(other_signer_key), "second")
    == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, second_filter)])) =
    process.receive(subscribed, 2000)
  assert second_filter.authors
    == Some(list.sort([signer, other_signer], string.compare))
  let assert Some(since_after_second_add) = second_filter.since
  assert since_after_second_add >= since_after_first_add

  assert bunker.remove_account(bunker_name, other_signer) == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, third_filter)])) =
    process.receive(subscribed, 2000)
  assert third_filter.authors == Some([signer])
  assert third_filter.since == Some(since_after_second_add)

  assert bunker.remove_account(bunker_name, signer) == Ok(Nil)
  assert process.receive(subscribed, 2000)
    == Ok(Subscribed(test_relay_url, [message.Close("nostr-no-su")]))
  stop_tree(tree)
}

/// 再接続したリレーは、切断前にそのリレーで受け取った最新イベントの `created_at`
/// から購読し直す。イベントを受け取っていないリレーは保存済みの再開点（無ければ
/// `None`）から購読する。
pub fn a_reconnected_monitor_relay_resumes_from_its_latest_event_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let first = named_relay("ws://first.test")
  let second = named_relay("ws://second.test")
  let tree =
    start_tree(monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() { load_signer(signer_key) }),
      [first, second],
      fixed_resume_point(Ok(None)),
    ))
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(first_socket, second_socket, deliver_first) = case
    first_url == first.url
  {
    True -> #(socket_1, socket_2, deliver_1)
    False -> #(socket_2, socket_1, deliver_2)
  }
  // 接続直後の評価（起動時の読み込みによる張り直しの分を含む、決定 11）を
  // 読み捨ててから、切断後の張り直しだけを見る。
  drain_subscriptions(subscribed, 300)

  let received = note("received")
  deliver_first(received)

  process.kill(first_socket)
  let #(_skipped, first_requested) =
    receive_until(subscribed, requests_on(_, first.url), 2000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, first_after_kill)])) =
    first_requested
  assert first_after_kill.since == Some(received.created_at)

  process.kill(second_socket)
  let #(_skipped, second_requested) =
    receive_until(subscribed, requests_on(_, second.url), 2000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, second_after_kill)])) =
    second_requested
  assert second_after_kill.since == None
  stop_tree(tree)
}

/// 再開点を読めない間は、監視の購読を張らずに再試行を続ける（開いている購読を
/// 閉じない）。
pub fn an_unreadable_resume_point_keeps_the_monitor_relay_unsubscribed_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let tree =
    start_tree(monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() { load_signer(signer_key) }),
      [test_relay()],
      fixed_resume_point(Error("unavailable")),
    ))
  let assert Ok(first) = process.receive(subscribed, 2000)
  assert first == Retrying(test_relay_url)
  assert_never_requests(subscribed, monotonic_ms() + 500)
  stop_tree(tree)
}

/// `deadline`（`monotonic_ms` の単位）まで、`subscribed` に届く報告が `Retrying` か
/// 空の `Subscribed` だけであることを検査する。
fn assert_never_requests(
  subscribed: Subject(SubscriptionReport),
  deadline: Int,
) -> Nil {
  case process.receive(subscribed, int.max(deadline - monotonic_ms(), 0)) {
    Error(Nil) -> Nil
    Ok(report) -> {
      assert report == Retrying(test_relay_url)
        || report == Subscribed(test_relay_url, [])
      assert_never_requests(subscribed, deadline)
    }
  }
}

// --- 登録されたリレー ---

/// 仕様の `relays: []` の Bunker でも、最初の読み込みで届いた `Snapshot.relays`
/// から接続が開く。
pub fn registered_relays_open_after_the_first_load_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let url = "ws://registered.test"
  let store =
    store_with_load(fn() {
      use snapshot <- result.try(load_signer(signer_key))
      Ok(
        bunker.Snapshot(..snapshot, relays: [
          relay_list.Registered(
            url: url,
            roles: relay_list.Roles(monitor: False, bunker: True),
          ),
        ]),
      )
    })
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(name, store, [], fixed_retry_delay),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Opened(opened_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert opened_url == url
  assert role_url_pairs(spec) == [#(relay_list.Bunker, url)]
  stop_tree(tree)
}

/// 読み込みが失敗している間はリレーを開かず、ストアが復旧して読み込みに成功した
/// 後に開く。
pub fn registered_relays_open_after_the_store_recovers_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let url = "ws://registered-after-recovery.test"
  let next_load = call_counter()
  let store =
    store_with_load(fn() {
      case next_load() {
        0 -> Error(store_failure())
        _ -> {
          use snapshot <- result.try(load_signer(signer_key))
          Ok(
            bunker.Snapshot(..snapshot, relays: [
              relay_list.Registered(
                url: url,
                roles: relay_list.Roles(monitor: False, bunker: True),
              ),
            ]),
          )
        }
      }
    })
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(
        name,
        store,
        [],
        Backoff(initial_ms: 300, max_ms: 300),
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  // 最初の読み込みが失敗している間は開かない。
  assert process.receive(reports, 100) == Error(Nil)
  let assert Opened(opened_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert opened_url == url
  stop_tree(tree)
}

// --- 実行時のリレーの増減 ---

/// `relay_list` の一覧を、監視、バンカーの順の `#(用途, URL)` にする。
fn role_url_pairs(spec: app.Spec) -> List(#(relay_list.Role, String)) {
  let assert Ok(entries) = relay_list.entries(spec.relay_list)
  [relay_list.Monitor, relay_list.Bunker]
  |> list.flat_map(fn(role) {
    list.map(relay_list.urls(entries, role), fn(url) { #(role, url) })
  })
}

/// `merge_relay_rows` は DB の行の順を保ち、`relay_list` にだけある URL を出さない。
/// 用途を使っていて接続があれば `status` の結果を、無ければ未接続を、用途を
/// 使っていなければ `None` を返す。
pub fn merged_relay_rows_follow_the_store_test() {
  let monitor_a = process.new_name("test_merge_monitor_a")
  let bunker_a = process.new_name("test_merge_bunker_a")
  let relays = [
    relay_store.Relay(
      id: 1,
      url: "wss://a",
      roles: relay_list.Roles(monitor: True, bunker: True),
    ),
    relay_store.Relay(
      id: 2,
      url: "wss://b",
      roles: relay_list.Roles(monitor: True, bunker: False),
    ),
    relay_store.Relay(
      id: 3,
      url: "wss://c",
      roles: relay_list.Roles(monitor: False, bunker: True),
    ),
  ]
  let entries = [
    relay_list.Entry(
      url: "wss://a",
      monitor: Some(monitor_a),
      bunker: Some(bunker_a),
    ),
    relay_list.Entry(
      url: "wss://only-in-relay-list",
      monitor: Some(process.new_name("test_merge_extra")),
      bunker: None,
    ),
  ]
  let status = fn(name) {
    case name == monitor_a, name == bunker_a {
      True, _ -> relay_connection.Connected
      _, True -> relay_connection.Disconnected
      _, _ -> panic as "unexpected name"
    }
  }
  assert app.merge_relay_rows(relays, entries, status)
    == [
      dashboard.RelayRow(
        id: 1,
        url: "wss://a",
        monitor: Some(relay_connection.Connected),
        bunker: Some(relay_connection.Disconnected),
      ),
      dashboard.RelayRow(
        id: 2,
        url: "wss://b",
        monitor: Some(relay_connection.Disconnected),
        bunker: None,
      ),
      dashboard.RelayRow(
        id: 3,
        url: "wss://c",
        monitor: None,
        bunker: Some(relay_connection.Disconnected),
      ),
    ]
}

/// `relay_list` が応答しなければ、DB を読まずにその理由を返す。
pub fn relay_rows_without_the_relay_list_test() {
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: idle_bunker(),
      admin: None,
      open: fake_open(process.new_subject(), None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list_unanswered"),
    )
  assert app.relay_rows(spec) == Error("relay list did not answer")
}

/// 監視のリレー 0 本の木で `open_relay` を呼ぶと、後から足したリレーで受信した
/// イベントもプラグインに届く。
pub fn a_monitor_relay_opened_at_runtime_delivers_events_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let spec =
    app.Spec(
      plugins: [
        forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
      ],
      monitor: idle_monitor(),
      bunker: idle_bunker(),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Ok(Nil) =
    app.open_relay(
      spec,
      test_relay_url,
      relay_list.Roles(monitor: True, bunker: False),
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver_and_expect(deliver, seen, event_labels("runtime", 3), 2000)
  stop_tree(tree)
}

/// `app.add_relay` は DB に挿入してから接続を開く。同じ URL の 2 回目は
/// `DuplicateRelay`、`relay_list` にすでにある URL への追加は `ConnectionsNotConfirmed`
/// になるが、どちらも先に挿入は確かめる。`TEST_DATABASE_URL` があるときだけ実行する
/// （CI では未設定なら失敗する）。
pub fn add_relay_saves_the_row_before_opening_test() {
  use database_url <- postgres.with_test_database_url("app")
  let schema = "app_relay_schema_" <> random.hex(8)
  let admin_db = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin_db, "CREATE SCHEMA " <> schema)

  // 移行を実行する。
  let assert Ok(_loaded) =
    account_store.load(
      postgres.start_pool(database_url, Some(schema)),
      random_master_key(),
      account_store.default_timeouts,
    )

  let assert Ok(config) =
    pog.url_config(process.new_name("test_app_relay_pool"), database_url)
  let config = pog.connection_parameter(config, "search_path", schema)
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: app.Bunker(..idle_bunker(), pool: config),
      admin: None,
      open: fake_open(process.new_subject(), None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_app_relay_add"),
    )
  let tree = start_tree(spec)
  let db = pog.named_connection(config.pool_name)

  let assert Ok(Nil) =
    app.add_relay(
      spec,
      "ws://added.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
  assert role_url_pairs(spec) == [#(relay_list.Monitor, "ws://added.test")]
  let assert Ok(rows) = relay_store.list(db, account_store.default_timeouts)
  assert list.map(rows, fn(row) { row.url }) == ["ws://added.test"]

  assert app.add_relay(
      spec,
      "ws://added.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
    == Error(admin.DuplicateRelay)

  let assert Ok(Nil) =
    app.open_relay(
      spec,
      "ws://listed.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
  assert app.add_relay(
      spec,
      "ws://listed.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
    == Error(admin.ConnectionsNotConfirmed)
  let assert Ok(rows_after) =
    relay_store.list(db, account_store.default_timeouts)
  assert list.map(rows_after, fn(row) { row.url })
    == ["ws://added.test", "ws://listed.test"]

  stop_tree(tree)
  postgres.run_statement(admin_db, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// `app.update_relay_roles` と `app.delete_relay` は DB に書いてから接続を変えるので、
/// 再起動なしで `registered_relays` と `relay_list` の両方に反映される。行を消した後は、
/// 同じ行への変更と削除がどちらも `UnregisteredRelay` になる。`TEST_DATABASE_URL` が
/// あるときだけ実行する（CI では未設定なら失敗する）。
pub fn update_and_delete_relay_write_the_row_then_the_connections_test() {
  use database_url <- postgres.with_test_database_url("app")
  let schema = "app_relay_update_schema_" <> random.hex(8)
  let admin_db = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin_db, "CREATE SCHEMA " <> schema)

  let assert Ok(_loaded) =
    account_store.load(
      postgres.start_pool(database_url, Some(schema)),
      random_master_key(),
      account_store.default_timeouts,
    )

  let assert Ok(config) =
    pog.url_config(process.new_name("test_app_relay_update_pool"), database_url)
  let config = pog.connection_parameter(config, "search_path", schema)
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: app.Bunker(..idle_bunker(), pool: config),
      admin: None,
      open: fake_open(process.new_subject(), None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_app_relay_update"),
    )
  let tree = start_tree(spec)

  let assert Ok(Nil) =
    app.add_relay(
      spec,
      "ws://update.test",
      relay_list.Roles(monitor: True, bunker: False),
    )
  let assert Ok([relay]) = app.registered_relays(spec)
  assert relay.url == "ws://update.test"
  assert relay.roles == relay_list.Roles(monitor: True, bunker: False)

  let assert Ok(Nil) =
    app.update_relay_roles(
      spec,
      relay,
      relay_list.Roles(monitor: False, bunker: True),
    )
  let assert Ok([updated]) = app.registered_relays(spec)
  assert updated.roles == relay_list.Roles(monitor: False, bunker: True)
  assert role_url_pairs(spec) == [#(relay_list.Bunker, "ws://update.test")]

  let assert Ok(Nil) = app.delete_relay(spec, updated)
  assert app.registered_relays(spec) == Ok([])
  assert role_url_pairs(spec) == []

  assert app.update_relay_roles(
      spec,
      updated,
      relay_list.Roles(monitor: True, bunker: True),
    )
    == Error(admin.UnregisteredRelay)
  assert app.delete_relay(spec, updated) == Error(admin.UnregisteredRelay)

  stop_tree(tree)
  postgres.run_statement(admin_db, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// 乱数のマスターキー。実行のたびに違う鍵を使う。
fn random_master_key() -> vault.MasterKey {
  let assert Ok(key) =
    vault.master_key_from_hex(hex.encode(crypto.strong_random_bytes(32)))
  key
}

/// `open_relay` / `change_relay_roles` / `close_relay` の直後、`relay_list` の
/// 一覧と `relay=` は一覧の順のまま反映される。
pub fn runtime_relay_changes_are_listed_in_order_test() {
  let reports = process.new_subject()
  let a = "ws://a.test"
  let b = "ws://b.test"
  let c = "ws://c.test"
  let signer = account.pubkey_hex(account_for(signer_key))
  let spec =
    app.Spec(
      plugins: [],
      monitor: app.Monitor(
        name: process.new_name("test_dedup"),
        dedup_capacity: 8,
        relays: [named_relay(a)],
        subscriptions: fn(_relay_url) { fn() { Ok([]) } },
        save_resume: discard_resume_points,
        excludes_kind: event.is_ephemeral,
      ),
      bunker: bunker_spec(
        process.new_name("test_bunker"),
        store_with_load(fn() { load_signer(signer_key) }),
        [named_relay(b)],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, a),
      #(relay_list.Bunker, b),
    ]

  let assert Ok(Nil) =
    app.open_relay(spec, c, relay_list.Roles(monitor: True, bunker: True))
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, a),
      #(relay_list.Monitor, c),
      #(relay_list.Bunker, b),
      #(relay_list.Bunker, c),
    ]

  let assert Ok(Nil) =
    app.change_relay_roles(
      spec,
      a,
      relay_list.Roles(monitor: False, bunker: True),
    )
  assert role_url_pairs(spec)
    == [
      #(relay_list.Monitor, c),
      #(relay_list.Bunker, a),
      #(relay_list.Bunker, b),
      #(relay_list.Bunker, c),
    ]

  let assert Ok(Nil) = app.close_relay(spec, c)
  assert role_url_pairs(spec)
    == [
      #(relay_list.Bunker, a),
      #(relay_list.Bunker, b),
    ]

  let assert Ok(rows) = app.account_rows(spec)
  let assert [row] = rows
  assert row.uri == account.bunker_uri(signer, [a, b], Some(secret))
  stop_tree(tree)
}

/// バンカーのリレーを閉じると、送信手段がバンカーの送信先から外れて再起動も
/// されない。閉じていない側のリレーは応答を送り続ける。
pub fn a_closed_bunker_relay_is_unpublished_and_not_restarted_test() {
  let reports = process.new_subject()
  let x = named_relay("ws://x.test")
  let y = named_relay("ws://y.test")
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(
        process.new_name("test_bunker"),
        store_with_load(fn() { load_signer(signer_key) }),
        [x, y],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      // 再接続で送信手段が戻ってこないよう、テストより十分に長く取る。
      reconnect_delay: Backoff(initial_ms: 60_000, max_ms: 60_000),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(socket_y, deliver_y) = case first_url == x.url {
    True -> #(socket_2, deliver_2)
    False -> #(socket_1, deliver_1)
  }

  let assert Ok(Nil) = app.close_relay(spec, x.url)
  assert process.named(x.name) == Error(Nil)
  // 300ms 待っても x は再起動されない（新しい `Opened` が届かない）。
  assert process.receive(reports, 300) == Error(Nil)
  assert process.named(x.name) == Error(Nil)

  deliver_y(connect_request("c1", secret))
  let assert Ok(Published(answered_on, _ack)) = process.receive(reports, 2000)
  assert answered_on == socket_y
  // 死んだ x の送信手段には送られないので、続く応答は来ない。
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// 実行時に足した監視のリレーは、アカウントの変更に合わせて購読が張り直され、
/// アカウントの追加の再開点の対象になる。閉じたリレーは対象から外れる。
pub fn a_runtime_monitor_relay_follows_account_changes_and_resume_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let other_signer = account.pubkey_hex(account_for(other_signer_key))
  let spec =
    monitored_accounts_spec(
      reports,
      subscribed,
      bunker_name,
      store_with_load(fn() { load_signer(signer_key) }),
      [],
      fixed_resume_point(Ok(None)),
    )
  let tree = start_tree(spec)
  let r = "ws://runtime-monitor.test"
  let assert Ok(Nil) =
    app.open_relay(spec, r, relay_list.Roles(monitor: True, bunker: False))
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, opened_filter)])) =
    receive_until(subscribed, requests_on(_, r), 2000).1
  assert opened_filter.authors == Some([signer])

  assert app.add_account(spec, account_for(other_signer_key), "second")
    == Ok(Nil)
  // 張り直しの評価は、変更前の一覧を含む古い内容が 1 回余計に届きうる
  // （読み込みの成功による張り直しで同じ内容の REQ が 1 回余計に送られるのと
  // 同じ理由である）。両方揃った内容が届くまで読み飛ばす。
  let both_signers = Some(list.sort([signer, other_signer], string.compare))
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, added_filter)])) =
    receive_until(
      subscribed,
      fn(report) {
        case report {
          Subscribed(url, [message.Req(_, filter)]) ->
            url == r && filter.authors == both_signers
          _ -> False
        }
      },
      2000,
    ).1
  assert added_filter.authors == both_signers
  let assert Ok(Some(_)) = dedup.since(spec.monitor.name, r)

  let assert Ok(Nil) = app.close_relay(spec, r)
  assert bunker.remove_account(bunker_name, other_signer) == Ok(Nil)
  // r は閉じられているので、以降のアカウントの変更で REQ は届かない。
  assert process.receive(subscribed, 300) == Error(Nil)

  let r2 = "ws://runtime-monitor-2.test"
  let assert Ok(Nil) =
    app.open_relay(spec, r2, relay_list.Roles(monitor: True, bunker: False))
  let assert Ok(Nil) = app.close_relay(spec, r2)
  assert app.add_account(spec, account_for(third_signer_key), "third")
    == Ok(Nil)
  // r2 は、監視の一覧に居た間に一度もアカウントの追加を知らされていない。
  assert dedup.since(spec.monitor.name, r2) == Ok(None)
  stop_tree(tree)
}

/// バンカーのリレーを実行時に足すと、バンカーアクターが再起動して
/// `connections` の factory ごと落ちても、`connections` の起動のたびに
/// `relay_list` へ送られる `Repopulate` が未登録の接続を起動し直す。
pub fn runtime_relays_are_reopened_when_the_bunker_restarts_test() {
  let reports = process.new_subject()
  let bunker_name = process.new_name("test_bunker")
  let spec =
    app.Spec(
      plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(
        bunker_name,
        store_with_load(fn() { load_signer(signer_key) }),
        [],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Ok(Nil) =
    app.open_relay(
      spec,
      "ws://z.test",
      relay_list.Roles(monitor: False, bunker: True),
    )
  let assert Opened("ws://z.test", _connection, _socket, _deliver) =
    await_connection(reports)

  let assert Ok(bunker_pid) = process.named(bunker_name)
  process.kill(bunker_pid)
  let assert Opened("ws://z.test", _connection_2, _socket_2, _deliver_2) =
    await_connection(reports)
  stop_tree(tree)
}

// --- 実行中のアカウントの変更 ---

/// 指定したクライアントから、テスト用の署名者宛に送る `connect`。
fn connect_request_from(
  client_key_hex: String,
  id: String,
  secret_arg: String,
) -> Event {
  let signer = account_for(signer_key)
  nip46_client.request_event(
    account_for(client_key_hex),
    signer,
    nip46_client.connect_body(signer, secret_arg, id),
    time.now_seconds(),
  )
}

/// `wanted` を満たす購読の報告が届くまで待ち、それまでに読み飛ばした報告と、届いた
/// 報告（期限までに届かなければ `Error`）を返す。
fn receive_until(
  subscribed: Subject(SubscriptionReport),
  wanted: fn(SubscriptionReport) -> Bool,
  timeout_ms: Int,
) -> #(List(SubscriptionReport), Result(SubscriptionReport, Nil)) {
  collect_until(subscribed, wanted, monotonic_ms() + timeout_ms, [])
}

/// `receive_until` の本体。読み飛ばした報告を逆順に積む。
fn collect_until(
  subscribed: Subject(SubscriptionReport),
  wanted: fn(SubscriptionReport) -> Bool,
  deadline: Int,
  skipped: List(SubscriptionReport),
) -> #(List(SubscriptionReport), Result(SubscriptionReport, Nil)) {
  case process.receive(subscribed, int.max(deadline - monotonic_ms(), 0)) {
    Error(Nil) -> #(list.reverse(skipped), Error(Nil))
    Ok(report) ->
      case wanted(report) {
        True -> #(list.reverse(skipped), Ok(report))
        False ->
          collect_until(subscribed, wanted, deadline, [report, ..skipped])
      }
  }
}

/// 購読の報告が `quiet_ms` の間途切れるまで読み捨てる。起動時の読み込みが 1 件
/// 以上だと、接続直後の照合に続いて同じ内容の張り直しが 1 回届きうるので、変更の
/// 前にそれを片付ける。
fn drain_subscriptions(
  subscribed: Subject(SubscriptionReport),
  quiet_ms: Int,
) -> Nil {
  case process.receive(subscribed, quiet_ms) {
    Ok(_report) -> drain_subscriptions(subscribed, quiet_ms)
    Error(Nil) -> Nil
  }
}

/// 報告が、署名者の購読を開き直すただ 1 件の REQ か。
fn subscribes(report: SubscriptionReport, signers: List(String)) -> Bool {
  case report {
    Subscribed(_relay_url, [message.Req(_id, filter)]) ->
      filter.p_tags == Some(signers)
    _ -> False
  }
}

/// 報告が、バンカーの購読を閉じる CLOSE を含むか。
fn closes(report: SubscriptionReport) -> Bool {
  case report {
    Subscribed(_relay_url, messages) ->
      list.contains(messages, message.Close("bunker"))
    Retrying(_relay_url) -> False
  }
}

/// アカウント 0 件で起動したバンカーに実行中に追加したアカウントは、接続を開き
/// 直さずに購読の #p に入り、ストアに書いた secret で接続できる。一覧の secret は
/// ストアに書いた secret と一致する。
pub fn an_account_added_at_runtime_answers_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      memory_store(calls, [], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert process.receive(subscribed, 2000) == Ok(Subscribed(test_relay_url, []))
  assert bunker.accounts(name) == Ok([])

  assert bunker.add_account(name, account_for(signer_key), "main") == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, filter)])) =
    process.receive(subscribed, 2000)
  assert filter.p_tags == Some([signer])
  let assert Ok(Inserted(inserted_signer, inserted_secret, "main")) =
    process.receive(calls, 1000)
  assert inserted_signer == signer
  assert bunker.accounts(name)
    == Ok([
      bunker.Listing(
        signer: signer,
        npub: account.npub(account_for(signer_key)),
        label: "main",
        secret: inserted_secret,
      ),
    ])

  deliver(connect_request("c1", inserted_secret))
  // 次の報告が応答であることが、接続が開き直されていないことを示す。
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 削除したアカウントは購読から外れ（CLOSE）、そのアカウント宛のリクエストには
/// 応答しない。セッションも消える。
pub fn a_removed_account_stops_answering_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      memory_store(calls, [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(Wrote(engine.InsertSession(..))) = process.receive(calls, 1000)

  assert bunker.remove_account(name, signer) == Ok(Nil)
  let #(_skipped, closed) = receive_until(subscribed, closes, 2000)
  assert closed == Ok(Subscribed(test_relay_url, [message.Close("bunker")]))
  assert process.receive(calls, 1000) == Ok(Deleted(signer))
  deliver(request("p1", "ping", "[]"))
  deliver(connect_request("c2", secret))
  assert process.receive(reports, 300) == Error(Nil)
  assert bunker.sessions(name) == Ok([])
  stop_tree(tree)
}

/// アカウントを追加・削除し、secret を作り直し、ラベルを差し替えても、バンカー
/// アクターは再起動せず、接続も開き直さず、既存のセッションは残る。作り直した後は
/// 古い secret での新規の `connect` を承認なしには通さない。
pub fn account_changes_keep_the_bunker_and_its_sessions_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let other = account.pubkey_hex(account_for(other_signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      memory_store(process.new_subject(), [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(before) = process.named(name)

  assert bunker.add_account(name, account_for(other_signer_key), "other")
    == Ok(Nil)
  assert bunker.remove_account(name, other) == Ok(Nil)
  assert bunker.rotate_secret(name, signer) == Ok(Nil)
  assert bunker.update_label(name, signer, "renamed") == Ok(Nil)
  assert process.named(name) == Ok(before)
  let assert Ok([
    bunker.Listing(signer: listed, label: "renamed", secret: rotated, ..),
  ]) = bunker.accounts(name)
  assert listed == signer
  assert rotated != secret

  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  deliver(connect_request_from(other_client_key, "c2", secret))
  let assert Ok(Published(_socket, asked)) = process.receive(reports, 2000)
  let body =
    nip46_client.decrypt_response(
      account_for(other_client_key),
      account_for(signer_key),
      asked,
    )
  assert string.contains(body, "\"result\":\"auth_url\"")
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// ストアへの書き込みが失敗したら、一覧も購読も変えず、削除に失敗した署名者は
/// 応答し続ける。
pub fn a_failed_write_changes_nothing_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      bunker.Store(
        ..memory_store(process.new_subject(), [stored_signer(signer_key)], True),
        write: fn(_write) { Ok(Nil) },
      ),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(Subscribed(_relay_url, [message.Req(..)])) =
    process.receive(subscribed, 2000)
  drain_subscriptions(subscribed, 200)
  let listed =
    Ok([
      bunker.Listing(
        signer: signer,
        npub: account.npub(account_for(signer_key)),
        label: "",
        secret: secret,
      ),
    ])
  assert bunker.accounts(name) == listed

  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.NotApplied(store_failure()))
  assert bunker.accounts(name) == listed
  assert process.receive(subscribed, 300) == Error(Nil)

  assert bunker.remove_account(name, signer)
    == Error(bunker.NotApplied(store_failure()))
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 読み込みの前の変更はストアを呼ばずに拒否し、一覧は読み込めない理由を返す。
pub fn changes_before_loading_do_not_reach_the_store_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let store =
    bunker.Store(..memory_store(calls, [], False), load: fn() {
      Error(store_failure())
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  assert bunker.add_account(name, account_for(signer_key), "")
    == Error(bunker.NotReady("accounts are not loaded yet"))
  assert process.receive(calls, 100) == Error(Nil)
  assert bunker.accounts(name)
    == Error("account store unavailable: " <> store_failure())
  stop_tree(tree)
}

/// 遅い書き込みの間に届いたリクエストは捨てられず、書き込みの応答の後に処理される。
pub fn requests_during_a_slow_write_are_not_dropped_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let results = process.new_subject()
  let name = process.new_name("test_bunker")
  let store = memory_store(calls, [stored_signer(signer_key)], False)
  let slow =
    bunker.Store(..store, insert: fn(entry) {
      let written = store.insert(entry)
      process.sleep(1500)
      written
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, slow, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(Wrote(engine.InsertSession(..))) = process.receive(calls, 1000)

  // `add_account` は応答まで呼び出し側を止めるので、別のプロセスから呼ぶ。
  process.spawn(fn() {
    process.send(
      results,
      bunker.add_account(name, account_for(other_signer_key), ""),
    )
  })
  let assert Ok(Inserted(..)) = process.receive(calls, 1000)
  deliver(request("p1", "ping", "[]"))
  assert process.receive(reports, 1000) == Error(Nil)
  assert process.receive(results, 2000) == Ok(Ok(Nil))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  stop_tree(tree)
}

/// ラベルの差し替えは一覧とストアに届く。メモリに無い署名者への変更と、登録済みの
/// 公開鍵の追加は、ストアを呼ばずに拒否する。
pub fn labels_and_registration_checks_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let stranger = account.pubkey_hex(account_for(other_signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      memory_store(calls, [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  assert bunker.update_label(name, signer, "renamed") == Ok(Nil)
  assert process.receive(calls, 1000) == Ok(LabelUpdated(signer, "renamed"))
  assert bunker.accounts(name)
    == Ok([
      bunker.Listing(
        signer: signer,
        npub: account.npub(account_for(signer_key)),
        label: "renamed",
        secret: secret,
      ),
    ])

  let not_registered = Error(bunker.NotApplied("account is not registered"))
  assert bunker.update_label(name, stranger, "x") == not_registered
  assert bunker.rotate_secret(name, stranger) == not_registered
  assert bunker.remove_account(name, stranger) == not_registered
  assert bunker.add_account(name, account_for(signer_key), "again")
    == Error(bunker.NotApplied("account is already registered"))
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// 署名者の問い合わせがタイムアウトしても、開いている購読を閉じない。X の追加で
/// 張り直しが起きたとき、その問い合わせは Y の書き込みの後ろに積まれて 5000ms を超える。
/// 購読は変わらずに再試行が予約され、Y の失敗の後の再試行で A と X の REQ になる。
/// 問い合わせの失敗を署名者 0 件として扱う実装では、ここで CLOSE が届いて落ちる。
///
/// 順序は時間の余裕ではなく、偽の書き込みを止める門で作る。X の書き込みを止めている
/// 間に Y の追加がアクターのメールボックスに積まれたことを確かめてから X を通し、Y の
/// 書き込みは再試行の予約を確かめるまで止めておく。
pub fn a_timed_out_signer_query_does_not_close_live_subscriptions_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let results = process.new_subject()
  let gates = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let fast = account.pubkey_hex(account_for(other_signer_key))
  let slow = account.pubkey_hex(account_for(slow_signer_key))
  let store =
    memory_store(process.new_subject(), [stored_signer(signer_key)], False)
  let gated =
    bunker.Store(..store, insert: fn(entry: vault.StoredAccount) {
      let written = account.pubkey_hex(entry.account)
      // 門はアクターのプロセスで作るので、アクターの中で受信できる。
      let gate = process.new_subject()
      process.send(gates, #(written, gate))
      process.receive_forever(gate)
      case written == slow {
        True -> Error(bunker.NotWritten(store_failure()))
        False -> store.insert(entry)
      }
    })
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      gated,
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  let assert Ok(Subscribed(_relay_url, [message.Req(..)])) =
    process.receive(subscribed, 2000)
  drain_subscriptions(subscribed, 200)
  let assert Ok(actor) = process.named(name)

  process.spawn(fn() {
    process.send(
      results,
      bunker.add_account(name, account_for(other_signer_key), ""),
    )
  })
  let assert Ok(#(blocked_first, release_first)) = process.receive(gates, 2000)
  assert blocked_first == fast
  process.spawn(fn() {
    process.send(
      results,
      bunker.add_account(name, account_for(slow_signer_key), ""),
    )
  })
  assert await_queued(actor, 2000)
  process.send(release_first, Nil)
  let assert Ok(#(blocked_second, release_second)) =
    process.receive(gates, 2000)
  assert blocked_second == slow

  let #(before_retry, retrying) =
    receive_until(
      subscribed,
      fn(report) { report == Retrying(test_relay_url) },
      7000,
    )
  assert retrying == Ok(Retrying(test_relay_url))
  assert !list.any(before_retry, closes)
  process.send(release_second, Nil)
  let #(before_request, requested) =
    receive_until(
      subscribed,
      subscribes(_, list.sort([signer, fast], string.compare)),
      3000,
    )
  assert !list.any(before_request, closes)
  let assert Ok(_request) = requested
  // 呼び出し側のプロセスが結果を転送するのは偽ソケットの報告とは別の送信なので、
  // 届く順序は決まらない。十分に待つ。
  assert process.receive(results, 1000) == Ok(Ok(Nil))
  assert process.receive(results, 1000)
    == Ok(Error(bunker.NotApplied(store_failure())))
  assert process.receive(reports, 0) == Error(Nil)
  stop_tree(tree)
}

/// アクターのメールボックスにメッセージが積まれるまで待つ。
fn await_queued(actor: Pid, remaining: Int) -> Bool {
  let #(_item, queued) = process_info(actor, atom.create("message_queue_len"))
  case queued > 0, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_queued(actor, remaining - 10)
    }
  }
}

/// プロセスの情報 1 項目。
@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, item: Atom) -> #(Atom, Int)

// --- 結果が曖昧な書き込みの後の読み直し ---

/// 偽のデータベースへの操作。
type DatabaseMsg {
  /// 現在の内容を読む。読み込みを失敗させている間は `Error`。
  ReadRows(reply: Subject(Result(bunker.Snapshot, Nil)))
  /// アカウントの行を書き換える。
  WriteRows(
    change: fn(List(vault.StoredAccount)) -> List(vault.StoredAccount),
    reply: Subject(Nil),
  )
  /// セッションと承認待ちの書き込み 1 件を反映する。
  ApplyWrite(write: engine.Write, reply: Subject(Nil))
  /// 読み込みを失敗させるかどうかを切り替える。
  FailReads(failing: Bool)
}

/// 偽のデータベースの状態。アカウントの行、セッション、承認待ち、読み込みを
/// 失敗させているかどうか。
type Database {
  Database(
    rows: List(vault.StoredAccount),
    sessions: List(engine.Session),
    pending: List(engine.Pending),
    failing_reads: Bool,
  )
}

/// アカウントの行を持ち、セッションと承認待ちが空の偽のデータベースを起動する。
fn start_database(rows: List(vault.StoredAccount)) -> Subject(DatabaseMsg) {
  let assert Ok(started) =
    actor.new(Database(
      rows: rows,
      sessions: [],
      pending: [],
      failing_reads: False,
    ))
    |> actor.on_message(fn(database, msg) {
      case msg {
        ReadRows(reply) -> {
          process.send(reply, case database.failing_reads {
            True -> Error(Nil)
            False ->
              Ok(
                bunker.Snapshot(
                  Loaded(accounts: database.rows, skipped: []),
                  database.sessions,
                  database.pending,
                  [],
                ),
              )
          })
          actor.continue(database)
        }
        WriteRows(change, reply) -> {
          process.send(reply, Nil)
          actor.continue(Database(..database, rows: change(database.rows)))
        }
        ApplyWrite(write, reply) -> {
          process.send(reply, Nil)
          actor.continue(apply_write(database, write))
        }
        FailReads(failing) ->
          actor.continue(Database(..database, failing_reads: failing))
      }
    })
    |> actor.start
  started.data
}

/// 書き込み 1 件を、`account_store` の対応する関数と同じ意味で偽のデータベースに
/// 反映する。`InsertSession` は同じ（signer, client）の行が無いときだけ末尾に足し、
/// あれば何もしない（`ON CONFLICT DO NOTHING`。DB では先の値が残る）。挿入の後に
/// `evicted` の組を除く。`DeleteSession` は組で除く。`TouchSession` は組の行の
/// `last_used_at` を `int.max(現在の値, last_used_at)` にし、行が無ければ何もしない。
/// `InsertPending` は `replaced` と `evicted` の token を除いてから足す。
/// `DeletePending` は token で除く。`ApprovePending` は `DeletePending` の後に
/// `InsertSession` と同じ規則でセッションを足す。
fn apply_write(database: Database, write: engine.Write) -> Database {
  case write {
    engine.InsertSession(session:, evicted:) ->
      Database(
        ..database,
        sessions: evict(insert_session(database.sessions, session), evicted),
      )
    engine.DeleteSession(signer:, client:) ->
      Database(
        ..database,
        sessions: list.filter(database.sessions, fn(session) {
          #(session.signer, session.client) != #(signer, client)
        }),
      )
    engine.TouchSession(signer:, client:, last_used_at:) ->
      Database(
        ..database,
        sessions: list.map(database.sessions, fn(session) {
          case #(session.signer, session.client) == #(signer, client) {
            True ->
              engine.Session(
                ..session,
                last_used_at: int.max(session.last_used_at, last_used_at),
              )
            False -> session
          }
        }),
      )
    engine.InsertPending(pending:, replaced:, evicted:) ->
      Database(..database, pending: [
        pending,
        ..list.filter(database.pending, fn(entry) {
          !list.contains(replaced, entry.token)
          && !list.contains(evicted, entry.token)
        })
      ])
    engine.DeletePending(token:) ->
      Database(
        ..database,
        pending: list.filter(database.pending, fn(entry) {
          entry.token != token
        }),
      )
    engine.ApprovePending(token:, session:, evicted:) ->
      Database(
        ..database,
        pending: list.filter(database.pending, fn(entry) {
          entry.token != token
        }),
        sessions: evict(insert_session(database.sessions, session), evicted),
      )
  }
}

/// `ON CONFLICT (signer, client) DO NOTHING` と同じ規則でセッションを足す。
fn insert_session(
  sessions: List(engine.Session),
  session: engine.Session,
) -> List(engine.Session) {
  case
    list.any(sessions, fn(existing) {
      #(existing.signer, existing.client) == #(session.signer, session.client)
    })
  {
    True -> sessions
    False -> list.append(sessions, [session])
  }
}

/// `pairs` に載る（signer, client）の組の行を除く。
fn evict(
  sessions: List(engine.Session),
  pairs: List(#(String, String)),
) -> List(engine.Session) {
  list.filter(sessions, fn(session) {
    !list.contains(pairs, #(session.signer, session.client))
  })
}

/// 偽のデータベースの行を、バンカーの一覧と同じ形（署名者の昇順）にする。
fn database_listings(database: Subject(DatabaseMsg)) -> List(bunker.Listing) {
  let assert Ok(snapshot) = process.call(database, 1000, ReadRows)
  snapshot.accounts.accounts
  |> list.map(fn(row) {
    bunker.Listing(
      signer: account.pubkey_hex(row.account),
      npub: account.npub(row.account),
      label: row.label,
      secret: row.secret,
    )
  })
  |> list.sort(fn(left, right) { string.compare(left.signer, right.signer) })
}

/// 偽のデータベースに書き込んだうえで、結果が曖昧な失敗を返すストア。サーバー側で
/// コミットされたのに、クライアント側の期限を過ぎた書き込みを模す。読み込みは
/// 偽のデータベースの現在の内容を返す。セッションと承認待ちの書き込みは偽の
/// データベースに反映して成功を返す。
fn committed_but_timed_out_store(
  database: Subject(DatabaseMsg),
) -> bunker.Store {
  let write = fn(change) {
    process.call(database, 1000, WriteRows(change, _))
    Error(bunker.MaybeWritten(
      "database did not answer in time or the connection was lost",
    ))
  }
  let modify = fn(signer, update) {
    write(
      list.map(_, fn(row: vault.StoredAccount) {
        case account.pubkey_hex(row.account) == signer {
          True -> update(row)
          False -> row
        }
      }),
    )
  }
  bunker.Store(
    load: fn() {
      process.call(database, 1000, ReadRows)
      |> result.replace_error(store_failure())
    },
    insert: fn(entry) { write(list.append(_, [entry])) },
    delete: fn(signer) {
      write(
        list.filter(_, fn(row: vault.StoredAccount) {
          account.pubkey_hex(row.account) != signer
        }),
      )
    },
    update_secret: fn(signer, secret) {
      modify(signer, fn(row) { StoredAccount(..row, secret: secret) })
    },
    update_label: fn(signer, label) {
      modify(signer, fn(row) { StoredAccount(..row, label: label) })
    },
    write: fn(change) {
      process.call(database, 1000, ApplyWrite(change, _))
      Ok(Nil)
    },
  )
}

/// バンカーの一覧が期待どおりになるまで待つ。
fn await_accounts(
  name: Name(bunker.Msg),
  expected: List(bunker.Listing),
  remaining: Int,
) -> Bool {
  case bunker.accounts(name) == Ok(expected), remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(20)
      await_accounts(name, expected, remaining - 20)
    }
  }
}

/// 結果が曖昧な追加がコミットされていたら、読み直してメモリを DB に合わせる。追加した
/// 署名者は購読に入り、既存の署名者のセッションは残る。合わせた後は、登録済みとしての
/// 拒否、削除、追加し直しがそれぞれ DB と一致したまま動く。
pub fn an_ambiguous_add_is_reconciled_with_the_store_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let signer = account.pubkey_hex(account_for(signer_key))
  let other = account.pubkey_hex(account_for(other_signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(before) = process.named(name)

  assert bunker.add_account(name, account_for(other_signer_key), "other")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let stored = database_listings(database)
  assert list.map(stored, fn(listing) { listing.signer })
    == list.sort([signer, other], string.compare)
  assert bunker.accounts(name) == Ok(stored)
  let #(_skipped, resubscribed) =
    receive_until(
      subscribed,
      subscribes(_, list.sort([signer, other], string.compare)),
      2000,
    )
  let assert Ok(_request) = resubscribed
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")

  assert bunker.add_account(name, account_for(other_signer_key), "again")
    == Error(bunker.NotApplied("account is already registered"))
  assert bunker.remove_account(name, other)
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert list.map(database_listings(database), fn(listing) { listing.signer })
    == [signer]
  assert bunker.accounts(name) == Ok(database_listings(database))
  assert bunker.add_account(name, account_for(other_signer_key), "back")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert list.length(database_listings(database)) == 2
  assert bunker.accounts(name) == Ok(database_listings(database))
  assert process.named(name) == Ok(before)
  stop_tree(tree)
}

/// 結果が曖昧な secret の作り直しがコミットされていたら、読み直して新しい secret を
/// メモリに反映する。セッションは残り、新しい secret で接続できる。
pub fn an_ambiguous_secret_rotation_is_reconciled_with_the_store_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")

  assert bunker.rotate_secret(name, signer)
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let assert [bunker.Listing(secret: rotated, ..)] = database_listings(database)
  assert rotated != secret
  assert bunker.accounts(name) == Ok(database_listings(database))

  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  deliver(connect_request_from(other_client_key, "c2", rotated))
  let assert Ok(Published(_socket, joined)) = process.receive(reports, 2000)
  let body =
    nip46_client.decrypt_response(
      account_for(other_client_key),
      account_for(signer_key),
      joined,
    )
  assert string.contains(body, "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 読み直しに失敗したら、メモリのアカウントのまま NIP-46 に応答し続け、変更を拒否し、
/// 一覧は理由を返す。読み込めるようになったら、再試行で DB と一致する。
pub fn a_failed_reload_keeps_the_accounts_and_retries_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  assert bunker.accounts(name) == Ok(database_listings(database))

  process.send(database, FailReads(True))
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert bunker.accounts(name)
    == Error("account store unavailable: " <> store_failure())
  assert bunker.add_account(name, account_for(slow_signer_key), "")
    == Error(bunker.NotReady("accounts are not loaded yet"))
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")

  process.send(database, FailReads(False))
  assert await_accounts(name, database_listings(database), 2000)
  assert list.length(database_listings(database)) == 2
  stop_tree(tree)
}

/// ストアが登録済みを返す追加の失敗。
fn already_stored() -> Result(Nil, bunker.WriteFailure) {
  Error(
    bunker.AlreadyStored(account_store.describe(account_store.AlreadyRegistered)),
  )
}

/// DB にだけある行の公開鍵を追加すると、応答の前に読み直してメモリに入れ、登録済み
/// として応答する。
pub fn adding_a_row_that_only_the_store_has_reads_it_back_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let store =
    bunker.Store(..committed_but_timed_out_store(database), insert: fn(_entry) {
      already_stored()
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert bunker.accounts(name) == Ok(database_listings(database))

  // 読み直しに見えなかった書き込みで、DB だけが先行している状態を作る。
  process.call(database, 1000, WriteRows(
    list.append(_, [stored_signer(other_signer_key)]),
    _,
  ))
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.NotApplied("account is already registered"))
  let stored = database_listings(database)
  assert list.length(stored) == 2
  assert bunker.accounts(name) == Ok(stored)
  stop_tree(tree)
}

/// 読み込みで飛ばされる行の公開鍵を追加すると、読み直してもメモリに入らないので、
/// 何度追加しても「反映されたかもしれない」ではなく登録済みとして拒否する。
pub fn adding_a_skipped_row_is_rejected_as_registered_test() {
  let reports = process.new_subject()
  let loads = process.new_subject()
  let name = process.new_name("test_bunker")
  let skipped = account.pubkey_hex(account_for(other_signer_key))
  let store =
    bunker.Store(
      ..store_with_load(fn() {
        process.send(loads, Nil)
        Ok(
          bunker.Snapshot(
            ..accounts_only([]),
            accounts: Loaded(accounts: [], skipped: [
              vault.Skipped(
                pubkey: skipped,
                reason: vault.UndecryptablePrivateKey,
              ),
            ]),
          ),
        )
      }),
      insert: fn(_entry) { already_stored() },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert process.receive(loads, 1000) == Ok(Nil)

  list.each([1, 2], fn(_attempt) {
    assert bunker.add_account(name, account_for(other_signer_key), "")
      == Error(bunker.NotApplied("account is already registered"))
    // 追加のたびに読み直している。
    assert process.receive(loads, 0) == Ok(Nil)
    assert bunker.accounts(name) == Ok([])
  })
  stop_tree(tree)
}

// --- 秘密鍵の再表示の問い合わせ ---

/// 読み込みの前は、秘密鍵の問い合わせを拒否し、ストアを呼ばない。
pub fn nsec_is_refused_before_the_accounts_are_loaded_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let store =
    bunker.Store(..memory_store(calls, [], False), load: fn() {
      Error(store_failure())
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  assert bunker.nsec(name, account.pubkey_hex(account_for(signer_key)))
    == Error("accounts are not loaded yet")
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// 読み込んだ後は、登録済みの署名者に nsec を返し、未登録の署名者は拒否する。どちらも
/// ストアを呼ばない。一覧の npub は `account.npub` と一致する。
pub fn nsec_answers_for_a_registered_signer_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let registered = account_for(signer_key)
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      memory_store(calls, [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  let assert Ok([listing]) = bunker.accounts(name)
  assert listing.npub == account.npub(registered)
  assert bunker.nsec(name, account.pubkey_hex(account_for(other_signer_key)))
    == Error("account is not registered")
  assert bunker.nsec(name, account.pubkey_hex(registered))
    == Ok(account.nsec(registered))
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// 結果が曖昧な書き込みの後、読み直しが成功するまでは秘密鍵の問い合わせを拒否する。
pub fn nsec_is_refused_until_an_ambiguous_write_is_reloaded_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert bunker.nsec(name, signer) == Ok(account.nsec(account_for(signer_key)))

  process.send(database, FailReads(True))
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert bunker.nsec(name, signer) == Error("accounts are not loaded yet")

  process.send(database, FailReads(False))
  assert await_accounts(name, database_listings(database), 2000)
  assert bunker.nsec(name, signer) == Ok(account.nsec(account_for(signer_key)))
  stop_tree(tree)
}

/// 接続を開くたびに AUTH の受け口をリレーの URL と一緒に `authenticators` へ送り、
/// あとは `fake_open` と同じに振る舞う偽リレー。
fn authenticator_recording_open(
  reports: Subject(Report),
  authenticators: Subject(#(String, Option(relay_client.Authenticator))),
) -> app.Open {
  fn(relay_url, subscriptions, handle_event, handle_ok, authenticator) {
    process.send(authenticators, #(relay_url, authenticator))
    fake_open(reports, None)(
      relay_url,
      subscriptions,
      handle_event,
      handle_ok,
      authenticator,
    )
  }
}

/// バンカーの接続が受けた AUTH の受け口は、登録アカウントの鍵で署名した kind 22242
/// を、その接続のリレー URL と challenge を載せて返す。
pub fn bunker_connections_answer_authentication_test() {
  let reports = process.new_subject()
  let authenticators = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree_with_open(
      name,
      store_with_load(fn() { load_signer(signer_key) }),
      fixed_retry_delay,
      authenticator_recording_open(reports, authenticators),
    )
  let assert Ok(#(relay_url, Some(authenticate))) =
    process.receive(authenticators, 2000)
  assert relay_url == test_relay_url
  assert await_signers(name, [signer], 3000)
  let assert Ok([signed]) = authenticate("challenge-1")
  assert signed.pubkey == signer
  assert signed.kind == event.auth_kind
  assert signed.tags
    == [["relay", test_relay_url], ["challenge", "challenge-1"]]
  let assert Ok(_verified) = event.verify(signed)
  stop_tree(tree)
}

/// 監視の接続は AUTH の受け口を受けない。
pub fn monitor_connections_do_not_answer_authentication_test() {
  let reports = process.new_subject()
  let authenticators = process.new_subject()
  let tree =
    start_monitor_tree_with_open(
      process.new_subject(),
      process.new_name("test_dedup"),
      event.is_ephemeral,
      authenticator_recording_open(reports, authenticators),
    )
  let assert Ok(#(relay_url, None)) = process.receive(authenticators, 2000)
  assert relay_url == test_relay_url
  stop_tree(tree)
}

/// `app.session_rows` は時刻をそのまま写し、perms は行に含めない。
pub fn session_rows_keep_times_and_drop_perms_test() {
  let sessions = [
    engine.Session(
      signer: "ab",
      client: "cd",
      perms: "sign_event:1",
      created_at: 10,
      last_used_at: 20,
    ),
  ]
  assert app.session_rows(sessions)
    == [
      dashboard.SessionRow(
        signer: "ab",
        client: "cd",
        created_at: 10,
        last_used_at: 20,
      ),
    ]
}
