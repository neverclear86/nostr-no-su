//// 偽リレーの上のツリーで、バンカーの応答、再起動、再接続、セッションと承認待ちの
//// 読み直しを確かめるテスト。`nostrconnect://` から開くセッションの発行、発行先の
//// 問い合わせ、セッションの権限の更新、セッションのリレーだけの接続の購読と
//// 取り消しで閉じることもここで確かめる。セッションの変更と最終利用の記録の書き込みの
//// 成功と失敗のログの行も、偽のストアで確かめる。

import gleam/erlang/atom
import gleam/erlang/process.{type Down, type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/session
import nostr_no_su/bunker/vault
import nostr_no_su/log
import nostr_no_su/nostr/event
import nostr_no_su/nostr/message
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/time
import support/app_tree.{
  type Report, type StoreCall, type SubscriptionReport, Inserted, Opened,
  Published, Subscribed, Wrote, accounts_only, authenticator_recording_open,
  await_connection, await_signers, bunker_spec, call_counter, client_key,
  committed_but_timed_out_store, connect_request, connect_request_from,
  connection_name, fake_open, fixed_retry_delay, idle_monitor, load_signer,
  memory_store, other_client_key, other_signer_key, request, response_body,
  secret, signed_request, signer_key, start_database, start_loading_bunker_tree,
  start_loading_bunker_tree_with_open, start_tree_with_relays, stop_tree,
  store_failure, store_with_load, stored_signer, test_relay_url,
}
import support/log_capture
import support/nip46_client.{account_for}
import support/poll

/// 接続が切断状態になるまで待つ。切断を観測できた時点で、接続アクターは
/// `on_disconnect` を実行し終えている。
fn await_disconnect(name: Name(relay_connection.Msg), timeout_ms: Int) -> Bool {
  poll.until(
    fn() { relay_connection.status(name) == relay_connection.Disconnected },
    timeout_ms,
    10,
  )
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

/// 捕まえた行に、`bunker` の接頭辞を付けた `message` で終わる行があるか。
fn has_bunker_line(capture: log_capture.Capture, message: String) -> Bool {
  bunker_line_count(capture, message) > 0
}

/// 捕まえた行のうち、`bunker` の接頭辞を付けた `message` で終わる行の数。行末まで合わせるのは、
/// 同じ文の後に理由を続けた行（結果が曖昧な書き込みの行）と区別するためである。
fn bunker_line_count(capture: log_capture.Capture, message: String) -> Int {
  list.count(log_capture.lines(capture), string.ends_with(
    _,
    log.line(bunker.log_prefix, message) <> "\n",
  ))
}

/// 他のテストが使わない 64 桁の 16 進の鍵。承認待ちを作るときはクライアントの秘密鍵に、
/// `open_client_session` ではクライアントの公開鍵に使う。`log_capture` は VM 全体の行を
/// 捕まえるので、行を数えるテストが、並走する他のモジュールのテストの同じ組の行を数えないために使う。
fn unshared_client_key(suffix: String) -> String {
  string.pad_start(suffix, 64, "0")
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

/// #418 の症状。`sign_event:1` のセッションで kind 10002 が `permission denied` に
/// なり、`bunker.update_perms` で `sign_event:1,sign_event:10002` にすると署名が
/// 返る。
pub fn session_permissions_can_be_updated_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  deliver(
    signed_request(nip46_client.connect_body_with_perms(
      signer,
      secret,
      "sign_event:1",
      "c1",
    )),
  )
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)

  let draft_10002 = "{\\\"kind\\\":10002,\\\"content\\\":\\\"\\\"}"
  deliver(request("r1", "sign_event", "[\"" <> draft_10002 <> "\"]"))
  let assert Ok(Published(_socket, denied)) = process.receive(reports, 2000)
  assert string.contains(response_body(denied), "permission denied")

  assert bunker.update_perms(
      name,
      account.pubkey_hex(signer),
      account.pubkey_hex(client),
      "sign_event:1,sign_event:10002",
    )
    == Ok(Nil)

  deliver(request("r2", "sign_event", "[\"" <> draft_10002 <> "\"]"))
  let assert Ok(Published(_socket, signed)) = process.receive(reports, 2000)
  assert string.contains(response_body(signed), "\\\"sig\\\"")
  stop_tree(tree)
}

/// `nostrconnect://` から開いたセッションは、応答がバンカーのリレーから発行され、
/// その `result` は URI の secret になる。セッションは承認済みとして残る。
pub fn a_nostrconnect_session_is_published_to_the_bunker_relay_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  assert bunker.open_client_session(
      name,
      account.pubkey_hex(signer),
      account.pubkey_hex(client),
      "",
      [],
      "uri-secret",
    )
    == Ok(Nil)
  let assert Ok(Published(_socket, response)) = process.receive(reports, 2000)
  assert string.contains(response_body(response), "\"result\":\"uri-secret\"")
  let assert Ok([session]) = bunker.sessions(name)
  assert session.signer == account.pubkey_hex(signer)
  assert session.client == account.pubkey_hex(client)
  stop_tree(tree)
}

/// `publisher_urls` は、応答の発行先として登録されているリレーの URL を返す。
pub fn publisher_urls_lists_the_connected_relay_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree = start_bunker_tree(reports, name)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert bunker.publisher_urls(name) == Some([test_relay_url])
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

/// 権限の差し替えの書き込みが失敗したら `SessionNotApplied` で理由を返し、権限を変えずに失敗の
/// 行を出す。承認済みでない組の差し替えは、書き込まずに `SessionNotFound` になる。
pub fn a_failed_permissions_update_keeps_the_perms_and_logs_the_failure_test() {
  let capture = log_capture.install()
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

  assert bunker.update_perms(name, session.signer, session.client, "ping")
    == Error(bunker.SessionNotApplied(store_failure()))
  let assert Ok(Wrote(engine.UpdateSessionPerms(..))) =
    process.receive(calls, 1000)
  assert bunker.sessions(name) == Ok([session])
  assert has_bunker_line(
    capture,
    "failed to update the permissions of the session of client "
      <> session.client
      <> " to signer "
      <> session.signer
      <> ": "
      <> store_failure(),
  )

  let assert Error(bunker.SessionNotFound(_reason)) =
    bunker.update_perms(name, session.signer, other_client_key, "ping")
  assert process.receive(calls, 100) == Error(Nil)
  log_capture.remove(capture)
  stop_tree(tree)
}

/// 権限の差し替えの書き込みの結果が曖昧なら `SessionMaybeApplied` を返して読み直しに移り、
/// 読み直しの前に届いた一覧の問い合わせには `accounts are being loaded` を返す。問い合わせを
/// 書き込みの間に積むため、偽のストアは書き込みの中で `release` が届くまで待ち、テストは
/// 問い合わせを `release` より先にアクターへ送る。
pub fn an_unconfirmed_permissions_update_answers_lists_as_being_loaded_test() {
  let reports = process.new_subject()
  let gates = process.new_subject()
  let name = process.new_name("test_bunker")
  let store =
    bunker.Store(
      ..memory_store(process.new_subject(), [stored_signer(signer_key)], False),
      write: fn(write) {
        case write {
          engine.UpdateSessionPerms(..) -> {
            let release = process.new_subject()
            process.send(gates, release)
            let _ = process.receive(release, 2000)
            Error(bunker.MaybeWritten(store_failure()))
          }
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

  let updated = process.new_subject()
  let listed = process.new_subject()
  let inbox = process.named_subject(name)
  process.send(
    inbox,
    bunker.UpdatePerms(session.signer, session.client, "ping", updated),
  )
  let assert Ok(release) = process.receive(gates, 2000)
  process.send(inbox, bunker.GetSessions(listed))
  process.send(release, Nil)

  assert process.receive(updated, 1000)
    == Ok(Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm)))
  assert process.receive(listed, 1000) == Ok(Error("accounts are being loaded"))
  stop_tree(tree)
}

/// セッションの最終利用の書き込みが失敗しても応答は返し、失敗の行を出す。書き込みが起きる
/// よう、最終利用の古いセッションを読み込んでおく。
pub fn a_failed_session_use_record_still_answers_and_logs_the_failure_test() {
  let capture = log_capture.install()
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let client = account.pubkey_hex(account_for(client_key))
  let session =
    session.Session(
      signer: signer,
      client: client,
      perms: "",
      created_at: 0,
      last_used_at: 0,
      relays: [],
    )
  let store =
    bunker.Store(
      ..store_with_load(fn() {
        Ok(
          bunker.Snapshot(
            ..accounts_only([stored_signer(signer_key)]),
            sessions: [session],
          ),
        )
      }),
      write: fn(_write) { Error(bunker.NotWritten(store_failure())) },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  assert has_bunker_line(
    capture,
    "failed to record the use of the session of client "
      <> client
      <> " to signer "
      <> signer
      <> ": "
      <> store_failure(),
  )
  log_capture.remove(capture)
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
  assert process.receive(loads, 300) == Error(Nil)
  assert bunker.accounts(name)
    == Error("account store unavailable: " <> store_failure())
  assert bunker.sessions(name)
    == Error("account store unavailable: " <> store_failure())
  assert bunker.pending(name)
    == Error("account store unavailable: " <> store_failure())
  stop_tree(tree)
}

/// バンカーが読み込み済みか問い合わせ続け、`Ok` になるまで待つ。
fn await_loaded(name: Name(bunker.Msg), timeout_ms: Int) -> Bool {
  poll.until(fn() { result.is_ok(bunker.accounts(name)) }, timeout_ms, 20)
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

/// 読み込みが終わっていない間の承認・拒否・取り消し・権限の差し替えと、`nostrconnect://` から
/// のセッションの開始は、ストアを呼ばずに `SessionNotReady` で拒否する。`nostrconnect://` の
/// 開始は、送られた（署名者, クライアント）で失敗の行を出す。
pub fn session_changes_before_loading_do_not_reach_the_store_test() {
  let capture = log_capture.install()
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
  assert bunker.update_perms(name, session.signer, session.client, "ping")
    == Error(bunker.SessionNotReady("accounts are not loaded yet"))
  assert bunker.open_client_session(
      name,
      session.signer,
      other_client_key,
      "",
      [],
      "uri-secret",
    )
    == Error(bunker.SessionNotReady("accounts are not loaded yet"))
  assert has_bunker_line(
    capture,
    "failed to open the session of client "
      <> other_client_key
      <> " to signer "
      <> session.signer
      <> ": accounts are not loaded yet",
  )
  assert process.receive(calls, 100) == Error(Nil)
  // メモリを変えていないことは、直前の `calls` が空であることで確かめている
  // （読み直しの失敗が続く間、一覧そのものは理由を返す）。
  let assert Error(_) = bunker.pending(name)
  let assert Error(_) = bunker.sessions(name)
  log_capture.remove(capture)
  stop_tree(tree)
}

/// 管理 UI からの承認・拒否・`nostrconnect://` の接続・権限の差し替え・取り消しは、
/// 書き込みの成功ごとに成功の行を 1 回だけ出す。承認待ちを作った NIP-46 の `connect` の
/// 書き込みの成功では行を出さない。
pub fn session_changes_log_one_line_after_a_successful_write_test() {
  let capture = log_capture.install()
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
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
  assert await_loaded(name, 2000)
  let signer = account.pubkey_hex(account_for(signer_key))
  let client_b1 = account.pubkey_hex(account_for(unshared_client_key("b1")))
  let client_b2 = account.pubkey_hex(account_for(unshared_client_key("b2")))
  let client_b3 = unshared_client_key("b3")

  deliver(connect_request_from(unshared_client_key("b1"), "c1", ""))
  let assert Ok(Published(_socket, _asked)) = process.receive(reports, 2000)
  deliver(connect_request_from(unshared_client_key("b2"), "c2", ""))
  let assert Ok(Published(_socket, _asked)) = process.receive(reports, 2000)
  let assert Ok(pending) = bunker.pending(name)
  let assert Ok(entry_b1) =
    list.find(pending, fn(entry) { entry.client == client_b1 })
  let assert Ok(entry_b2) =
    list.find(pending, fn(entry) { entry.client == client_b2 })

  assert bunker.approve(name, entry_b1.token) == Ok(Nil)
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)
  assert bunker.deny(name, entry_b2.token) == Ok(Nil)
  let assert Ok(Published(_socket, _denied)) = process.receive(reports, 2000)
  assert bunker.open_client_session(
      name,
      signer,
      client_b3,
      "",
      [],
      "uri-secret",
    )
    == Ok(Nil)
  let assert Ok(Published(_socket, _response)) = process.receive(reports, 2000)
  assert bunker.update_perms(name, signer, client_b3, "ping") == Ok(Nil)
  assert bunker.revoke(name, signer, client_b3) == Ok(Nil)

  assert bunker_line_count(
      capture,
      "approved the connection of client "
        <> entry_b1.client
        <> " to signer "
        <> entry_b1.signer,
    )
    == 1
  assert bunker_line_count(
      capture,
      "denied the connection of client "
        <> entry_b2.client
        <> " to signer "
        <> entry_b2.signer,
    )
    == 1
  assert bunker_line_count(
      capture,
      "connected client " <> client_b3 <> " to signer " <> signer,
    )
    == 1
  assert bunker_line_count(
      capture,
      "updated the permissions of client "
        <> client_b3
        <> " to signer "
        <> signer,
    )
    == 1
  assert bunker_line_count(
      capture,
      "revoked the session of client " <> client_b3 <> " to signer " <> signer,
    )
    == 1
  assert bunker_line_count(
      capture,
      "recorded the pending connection of client "
        <> entry_b1.client
        <> " to signer "
        <> entry_b1.signer,
    )
    == 0
  assert bunker_line_count(
      capture,
      "recorded the pending connection of client "
        <> entry_b2.client
        <> " to signer "
        <> entry_b2.signer,
    )
    == 0
  log_capture.remove(capture)
  stop_tree(tree)
}

/// 書き込みが失敗したか結果が曖昧な操作では、成功の行は出ない。
/// 書き込まれていないことが確定した失敗の行は、送られた（署名者, クライアント）で出る。
pub fn unapplied_session_changes_log_no_success_line_test() {
  let capture = log_capture.install()
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let client_b4 = unshared_client_key("b4")
  let client_b5 = unshared_client_key("b5")
  let store =
    bunker.Store(
      ..memory_store(process.new_subject(), [stored_signer(signer_key)], False),
      write: fn(write) {
        case write {
          engine.InsertSession(session:, ..) if session.client == client_b4 ->
            Error(bunker.NotWritten(store_failure()))
          _ -> Error(bunker.MaybeWritten(store_failure()))
        }
      },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert await_loaded(name, 2000)
  let signer = account.pubkey_hex(account_for(signer_key))

  assert bunker.open_client_session(
      name,
      signer,
      client_b4,
      "",
      [],
      "uri-secret",
    )
    == Error(bunker.SessionNotApplied(store_failure()))
  assert has_bunker_line(
    capture,
    "failed to open the session of client "
      <> client_b4
      <> " to signer "
      <> signer
      <> ": "
      <> store_failure(),
  )

  assert bunker.open_client_session(
      name,
      signer,
      client_b5,
      "",
      [],
      "uri-secret",
    )
    == Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))

  assert bunker_line_count(
      capture,
      "connected client " <> client_b4 <> " to signer " <> signer,
    )
    == 0
  assert bunker_line_count(
      capture,
      "connected client " <> client_b5 <> " to signer " <> signer,
    )
    == 0
  log_capture.remove(capture)
  stop_tree(tree)
}

/// ソケットを失った接続の送信手段は取り下げられる。バンカーリレーを 2 本張り、
/// 片方のソケットを kill すると、以降の応答は生きている側からだけ出ていく。
pub fn a_lost_socket_stops_receiving_responses_test() {
  let reports = process.new_subject()
  let relay_a = "ws://relay.one"
  let relay_b = "ws://relay.two"
  let spec =
    app.Spec(
      plugins: [],
      not_loaded_plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(
        process.new_name("test_bunker"),
        store_with_load(fn() { load_signer(signer_key) }),
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      // 再接続で送信手段が戻ってこないよう、テストより十分に長く取る。
      reconnect_delay: Backoff(initial_ms: 60_000, max_ms: 60_000),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree_with_relays(spec, [], [relay_a, relay_b])
  // `Opened` は接続アクターごとに独立して届くため、到着順ではなく URL で
  // どちらのリレーの報告かを決める。
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(socket_a, socket_b, deliver) = case first_url == relay_a {
    True -> #(socket_1, socket_2, deliver_1)
    False -> #(socket_2, socket_1, deliver_2)
  }

  // 2 本とも生きている間は、応答が両方のソケットから出ていく。
  deliver(connect_request("c1", secret))
  let assert Ok(Published(first, _ack)) = process.receive(reports, 2000)
  let assert Ok(Published(second, _same_ack)) = process.receive(reports, 2000)
  assert first != second

  process.kill(socket_a)
  assert await_disconnect(
    connection_name(spec, relay_a, relay_list.Bunker),
    2000,
  )
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(answered_on, pong)) = process.receive(reports, 2000)
  assert answered_on == socket_b
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  // 死んだソケットには送られない。生きているのは 1 本だけになっている。
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
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

/// `app.pending_rows` は失効までの残り秒を問い合わせた時点の時刻から求め、他の値は
/// そのまま写す。
pub fn pending_rows_count_down_to_the_expiry_test() {
  let before = time.now_seconds()
  let pending =
    session.Pending(
      token: "tok",
      signer: "ab",
      client: "cd",
      request_id: "req",
      perms: "sign_event:1",
      secret_mismatch: True,
      created_at: before - 100,
    )
  let assert [row] = app.pending_rows([pending])
  let after = time.now_seconds()
  assert row.expires_in_seconds <= engine.pending_ttl_seconds - 100
  assert row.expires_in_seconds
    >= engine.pending_ttl_seconds - 100 - { after - before }
  assert row
    == dashboard.PendingRow(
      token: "tok",
      signer: "ab",
      client: "cd",
      expires_in_seconds: row.expires_in_seconds,
      secret_mismatch: True,
      perms: "sign_event:1",
    )
}

/// セッションのリレーだけの接続の URL。基本の接続（`test_relay_url`）とは別にする。
const session_relay_url = "ws://session.test"

/// `relay_urls` の接続がそれぞれ最初に送る REQ の `#p` を、`relay_urls` の順に
/// 待って返す。`seen` はここまでに受けた（URL, `#p`）の組。REQ を含まない報告と
/// 2 件目以降の REQ は読み捨てる。
fn await_first_p_tags(
  subscribed: Subject(SubscriptionReport),
  relay_urls: List(String),
  seen: List(#(String, Option(List(String)))),
) -> List(Option(List(String))) {
  case list.try_map(relay_urls, list.key_find(seen, _)) {
    Ok(p_tags) -> p_tags
    Error(Nil) -> {
      let assert Ok(report) = process.receive(subscribed, 2000)
      let request = case report {
        Subscribed(url, messages) ->
          list.find_map(messages, fn(sent) {
            case sent {
              message.Req(_id, filter) -> Ok(#(url, filter.p_tags))
              _ -> Error(Nil)
            }
          })
        _ -> Error(Nil)
      }
      let seen = case request {
        Ok(#(url, p_tags)) ->
          case list.key_find(seen, url) {
            Ok(_) -> seen
            Error(Nil) -> [#(url, p_tags), ..seen]
          }
        Error(Nil) -> seen
      }
      await_first_p_tags(subscribed, relay_urls, seen)
    }
  }
}

/// 応答の発行先が `expected` になるまで待つ。
fn await_publisher_urls(
  name: Name(bunker.Msg),
  expected: List(String),
  timeout_ms: Int,
) -> Bool {
  poll.until(
    fn() {
      option.map(bunker.publisher_urls(name), list.sort(_, string.compare))
      == Some(expected)
    },
    timeout_ms,
    20,
  )
}

/// 基本の組に無いセッションのリレーは、そのセッションの署名者だけの `#p` で購読する
/// 接続として開き、取り消すと閉じて応答の発行先から外れる（受け入れ条件 2・3）。
pub fn a_session_only_relay_subscribes_its_signers_and_closes_on_revoke_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let name = process.new_name("test_bunker")
  let first = stored_signer(signer_key)
  let second = stored_signer(other_signer_key)
  let first_hex = account.pubkey_hex(first.account)
  let second_hex = account.pubkey_hex(second.account)
  let client_hex = account.pubkey_hex(account_for(client_key))
  let session =
    session.Session(
      signer: first_hex,
      client: client_hex,
      perms: "",
      created_at: time.now_seconds(),
      last_used_at: time.now_seconds(),
      relays: [session_relay_url],
    )
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      store_with_load(fn() {
        Ok(
          bunker.Snapshot(
            vault.Loaded(accounts: [first, second], skipped: []),
            [session],
            [],
            [],
          ),
        )
      }),
      fixed_retry_delay,
    )

  assert await_first_p_tags(subscribed, [session_relay_url, test_relay_url], [])
    == [
      Some([first_hex]),
      Some(list.sort([first_hex, second_hex], string.compare)),
    ]
  assert await_publisher_urls(
    name,
    list.sort([session_relay_url, test_relay_url], string.compare),
    3000,
  )

  let assert Ok(Nil) = bunker.revoke(name, first_hex, client_hex)
  assert await_publisher_urls(name, [test_relay_url], 3000)
  stop_tree(tree)
}
