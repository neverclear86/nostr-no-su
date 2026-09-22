//// app_bunker_test、app_plugins_test、app_accounts_test が共有する、偽リレーの
//// 上でスーパービジョンツリーを動かすヘルパー。gleeunit は test/ 配下の全モジュールを
//// eunit に渡すので、関数名を `_test` で終わらせないこと（`beam_fixture.gleam` 冒頭と
//// 同じ注意）。

import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/system
import gleam/result
import nostr_no_su/app
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{Loaded, StoredAccount}
import nostr_no_su/config
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/message
import nostr_no_su/plugin
import nostr_no_su/plugin_runner
import nostr_no_su/relay_client
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/time
import pog
import support/nip46_client.{account_for}
import support/signed_event

/// テスト用の署名者の接続 secret。
pub const secret = "s3cr3t-token"

/// テスト用の署名者の秘密鍵（16 進）。
pub const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

/// ストアの最新の内容が変わったことを表す、2 人目の署名者の鍵。
pub const other_signer_key = "0000000000000000000000000000000000000000000000000000000000000077"

/// テスト用のクライアントの秘密鍵（16 進）。
pub const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

/// 2 人目のクライアントの鍵。承認済みセッションを持たないクライアントとして使う。
pub const other_client_key = "0000000000000000000000000000000000000000000000000000000000000005"

/// 偽のストアの書き込みと読み込みが失敗したときの理由。本物のストアの文言を使う。
pub fn store_failure() -> String {
  account_store.describe(account_store.Unavailable)
}

/// 偽リレーの URL。`fake_open` が報告に添えるだけで、接続先としては使わない。
pub const test_relay_url = "ws://relay.test"

/// 承認ページを載せる管理 UI の公開 URL。承認フローを有効にするために渡す。
const auth_base = "http://admin.test"

/// 偽リレーがテストへ報告する内容。
pub type Report {
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
pub type SubscriptionReport {
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
pub fn fake_open(
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
        handle_event(relay_client.ReceivedEvent(
          config.monitor_subscription_id,
          signed_event.verified(sent),
        ))
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
pub fn start_tree(spec: app.Spec) -> Pid {
  let assert Ok(started) = app.start(spec)
  started.pid
}

/// 偽リレー 1 本ぶんの仕様。URL は `fake_open` が無視するのでラベルでしかない。
pub fn test_relay() -> relay_list.Connection {
  named_relay(test_relay_url)
}

/// 指定した URL の偽リレー 1 本ぶんの仕様。バンカーは publisher を URL で
/// 区別するため、複数本を張るテストは別々の URL を渡す。
pub fn named_relay(url: String) -> relay_list.Connection {
  relay_list.Connection(name: process.new_name("test_relay"), url: url)
}

/// 偽リレー 1 本の上で、指定したストアを持つバンカーだけを動かすツリー。
pub fn start_loading_bunker_tree(
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
pub fn start_loading_bunker_tree_with_open(
  name: Name(bunker.Msg),
  store: bunker.Store,
  retry_delay: backoff.Backoff,
  open: app.Open,
) -> Pid {
  start_tree(app.Spec(
    plugins: [],
    not_loaded_plugins: [],
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
pub const fixed_retry_delay = Backoff(initial_ms: 100, max_ms: 100)

/// バンカーサブツリーの仕様。接続プールとロックのプールは到達できないポートを指し、
/// 偽のストアを使うテストでもサブツリーの形（プール、ロックのプール、アクター、
/// 接続の順）は本番と同じにする。購読は本番と同じく、接続と張り直しのたびに現在の
/// 署名者から組み立て、署名者を問い合わせられなければ定義を得られなかったことにする。
pub fn bunker_spec(
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

/// 監視とバンカーのテストのツリーに載せる、リレーを持たない Monitor。監視の
/// ツリーは常に起動するので載せるが、テストが監視を使わないときに使う。
pub fn idle_monitor() -> app.Monitor {
  app.Monitor(
    name: process.new_name("test_idle_dedup"),
    dedup_capacity: 8,
    relays: [],
    subscriptions: fn(_relay_url) { fn() { Ok([]) } },
    save_resume: discard_resume_points,
    save_plugin_resume: discard_resume_points,
    excludes_kind: event.is_ephemeral,
    accepts_author: fn(_pubkey) { True },
  )
}

/// 偽のストアが受けた書き込み。secret も含めて記録し、DB に書いた値とメモリの値を
/// 比べられるようにする。
pub type StoreCall {
  Inserted(signer: String, secret: String, label: String)
  Deleted(signer: String)
  SecretUpdated(signer: String, secret: String)
  LabelUpdated(signer: String, label: String)
  Wrote(write: engine.Write)
}

/// 指定した読み込み関数を持ち、書き込みはすべて成功する偽のストア。
pub fn store_with_load(
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
pub fn memory_store(
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

/// 指定した秘密鍵の署名者 1 件を、テストの secret 付きで保存した行。
pub fn stored_signer(key_hex: String) -> vault.StoredAccount {
  StoredAccount(account: account_for(key_hex), secret: secret, label: "")
}

/// 指定した秘密鍵の署名者 1 件を、テストの secret 付きで読み込んだ結果。
pub fn load_signer(key_hex: String) -> Result(bunker.Snapshot, String) {
  Ok(accounts_only([stored_signer(key_hex)]))
}

/// アカウントだけがあり、セッションと承認待ちが無い読み込みの結果。
pub fn accounts_only(accounts: List(vault.StoredAccount)) -> bunker.Snapshot {
  bunker.Snapshot(Loaded(accounts: accounts, skipped: []), [], [], [])
}

/// 何もせず成功する、再開点の保存の操作。
pub fn discard_resume_points(
  _points: List(#(String, Int)),
) -> Result(Nil, String) {
  Ok(Nil)
}

/// 受け取ったイベントをテストへ転送するプラグインの仕様。歯止めは既定のまま。
pub fn forwarding_spec(
  name: Name(plugin_runner.Msg),
  seen: Subject(Event),
) -> app.PluginSpec {
  app.PluginSpec(
    name: name,
    plugin: plugin.Plugin(
      name: "forwarding",
      children: [],
      ui: None,
      handle: process.send(seen, _),
    ),
    limits: plugin_runner.default_limits,
  )
}

/// 親プロセスと同じ方法でツリーを停止する。ルートスーパーバイザーは exit
/// シグナルをツリー全体の順序立った停止に変換する。先にリンクを解除するのは、
/// 停止に失敗してもテストプロセスを巻き込まないようにするため。
pub fn stop_tree(tree: Pid) -> Nil {
  process.unlink(tree)
  process.send_exit(tree)
}

/// ツリーが次に開く接続を待ち、そのアクターが落ち着くのを待つ。システム
/// メッセージに応答した時点で、サブツリー先頭のアクターへの配線は完了している。
pub fn await_connection(reports: Subject(Report)) -> Report {
  let assert Ok(Opened(relay_url, connection, socket, deliver)) =
    process.receive(reports, 2000)
  let _state = system.get_state(connection)
  Opened(relay_url, connection, socket, deliver)
}

/// テスト用の署名者とクライアントで組み立てた `connect` リクエスト。
/// `secret_arg` が空文字列なら、シークレット無しで接続するクライアントと同じ形に
/// なる（nostr-tools はそのように送る）。
pub fn connect_request(id: String, secret_arg: String) -> Event {
  let signer = account_for(signer_key)
  signed_request(nip46_client.connect_body(signer, secret_arg, id))
}

/// 指定した params を持つ JSON-RPC リクエスト。
pub fn request(id: String, method: String, params_json: String) -> Event {
  signed_request(nip46_client.request_body(id, method, params_json))
}

/// 指定した本文を、テスト用のクライアントから署名者宛のリクエストイベントに
/// する。ツリーは受付ウィンドウを実時間で見るため、作成時刻は現在時刻にする。
pub fn signed_request(body: String) -> Event {
  nip46_client.request_event(
    account_for(client_key),
    account_for(signer_key),
    body,
    time.now_seconds(),
  )
}

/// 応答イベントの JSON-RPC 本文。クライアントが読むのと同じ形で取り出す。
pub fn response_body(response: Event) -> String {
  nip46_client.decrypt_response(
    account_for(client_key),
    account_for(signer_key),
    response,
  )
}

/// 監視に流す kind 1 の署名済みイベント。`label` を content に入れるので、label が
/// 違えば id も違う（ディスパッチャーは id しか見ない）。作者は登録アカウント
/// （`signer_key`）ではない鍵なので、作者を照合するツリー（`accepts_author` に
/// `bunker.is_signer` を渡すもの）へ登録アカウントのイベントとして流すときは、
/// `signed_event.by(signer_key, …)` を使う。
pub fn note(label: String) -> Event {
  signed_event.new(1, label)
}

/// 連番のイベントの label。
pub fn event_labels(prefix: String, count: Int) -> List(String) {
  use _unit, index <- list.index_map(list.repeat(Nil, count))
  prefix <> int.to_string(index)
}

/// 指定した label のイベントを配信し、転送プラグインが全件を順に受け取ることを
/// 確かめる。
pub fn deliver_and_expect(
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

/// 呼ぶたびに 0, 1, 2, ... を返す関数。`load` はバンカーアクターの中で呼ばれ、
/// Gleam には可変の変数が無いので、回数は別のアクターで数える。
pub fn call_counter() -> fn() -> Int {
  let assert Ok(counter) =
    actor.new(0)
    |> actor.on_message(fn(count, reply: Subject(Int)) {
      process.send(reply, count)
      actor.continue(count + 1)
    })
    |> actor.start
  fn() { process.call(counter.data, 1000, fn(reply) { reply }) }
}

/// バンカーが指定した署名者を持つまで待つ。
pub fn await_signers(
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

// --- 実行中のアカウントの変更 ---

/// 指定したクライアントから、テスト用の署名者宛に送る `connect`。
pub fn connect_request_from(
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
pub fn receive_until(
  subscribed: Subject(SubscriptionReport),
  wanted: fn(SubscriptionReport) -> Bool,
  timeout_ms: Int,
) -> #(List(SubscriptionReport), Result(SubscriptionReport, Nil)) {
  collect_until(subscribed, wanted, time.monotonic_ms() + timeout_ms, [])
}

/// `receive_until` の本体。読み飛ばした報告を逆順に積む。
fn collect_until(
  subscribed: Subject(SubscriptionReport),
  wanted: fn(SubscriptionReport) -> Bool,
  deadline: Int,
  skipped: List(SubscriptionReport),
) -> #(List(SubscriptionReport), Result(SubscriptionReport, Nil)) {
  case process.receive(subscribed, int.max(deadline - time.monotonic_ms(), 0)) {
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
pub fn drain_subscriptions(
  subscribed: Subject(SubscriptionReport),
  quiet_ms: Int,
) -> Nil {
  case process.receive(subscribed, quiet_ms) {
    Ok(_report) -> drain_subscriptions(subscribed, quiet_ms)
    Error(Nil) -> Nil
  }
}

// --- 結果が曖昧な書き込みの後の読み直し ---

/// 偽のデータベースへの操作。
pub type DatabaseMsg {
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
pub fn start_database(rows: List(vault.StoredAccount)) -> Subject(DatabaseMsg) {
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
/// `InsertSession` と同じ規則でセッションを足す。`UpdateSessionPerms` は組の
/// 行の `perms` を差し替え、行が無ければ何もしない。
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
    engine.UpdateSessionPerms(signer:, client:, perms:) ->
      Database(
        ..database,
        sessions: list.map(database.sessions, fn(session) {
          case #(session.signer, session.client) == #(signer, client) {
            True -> engine.Session(..session, perms: perms)
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

/// 偽のデータベースに書き込んだうえで、結果が曖昧な失敗を返すストア。サーバー側で
/// コミットされたのに、クライアント側の期限を過ぎた書き込みを模す。読み込みは
/// 偽のデータベースの現在の内容を返す。セッションと承認待ちの書き込みは偽の
/// データベースに反映して成功を返す。
pub fn committed_but_timed_out_store(
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

/// 接続を開くたびに AUTH の受け口をリレーの URL と一緒に `authenticators` へ送り、
/// あとは `fake_open` と同じに振る舞う偽リレー。
pub fn authenticator_recording_open(
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
