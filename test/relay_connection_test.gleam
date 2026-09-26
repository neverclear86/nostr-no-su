import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/option.{None, Some}
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/relay_connection.{type Socket, Socket}
import support/poll

/// 再接続テストを短時間で終わらせつつ、「予約された」と「即時」を区別できる
/// 程度には長い遅延。
const delay_ms = 300

/// 偽の connect 関数と `on_connect` がテストへ報告する内容。
type Report {
  /// 生きた偽ソケットが得られた接続試行。
  Connected(socket: Pid)
  /// リレーに拒否された接続試行。
  Refused
  /// 新しいソケットに対して `on_connect` が実行された。
  Rewired
  /// ソケットを失って `on_disconnect` が実行された。
  Unwired
  /// 生きた偽ソケットが購読の張り直しを依頼された。
  Resubscribed
  /// 生きた偽ソケットにイベントの送信が渡された。
  Published(event: event.Event)
}

/// 偽ソケット。stratus プロセスと同じく、接続アクターにリンクした待機プロセス。
/// これを kill すると切断とまったく同じに見える。張り直しの依頼と送信の依頼は
/// テストへ報告する。
fn spawn_socket(reports: Subject(Report)) -> Socket {
  let pid = process.spawn(fn() { process.sleep_forever() })
  Socket(
    pid: pid,
    publish: fn(sent) { process.send(reports, Published(sent)) },
    resubscribe: fn() { process.send(reports, Resubscribed) },
  )
}

/// 常に新しいソケットを返し、それを報告する connect 関数。
fn connects(reports: Subject(Report)) -> relay_connection.Connector {
  fn() {
    let socket = spawn_socket(reports)
    process.send(reports, Connected(socket.pid))
    Ok(socket)
  }
}

/// 到達できないリレーを模した connect 関数。
fn refuses(reports: Subject(Report)) -> relay_connection.Connector {
  fn() {
    process.send(reports, Refused)
    Error("connection refused")
  }
}

/// 指定した connect 関数で接続アクターを起動し、再配線のたびに報告する。
fn start(reports: Subject(Report), connect: relay_connection.Connector) -> Pid {
  start_named(process.new_name("test_relay"), reports, connect)
}

/// 指定した名前で接続アクターを起動する。状態の問い合わせには名前が要る。
fn start_named(
  name: Name(relay_connection.Msg),
  reports: Subject(Report),
  connect: relay_connection.Connector,
) -> Pid {
  start_with_delay(
    name,
    reports,
    connect,
    Backoff(initial_ms: delay_ms, max_ms: delay_ms),
    relay_connection.default_stable_after_ms,
  )
}

/// 指定した名前と待ち時間の延ばし方、待ち時間を初期値に戻すのに要る接続の
/// 継続時間で接続アクターを起動する。
fn start_with_delay(
  name: Name(relay_connection.Msg),
  reports: Subject(Report),
  connect: relay_connection.Connector,
  reconnect_delay: backoff.Backoff,
  stable_after_ms: Int,
) -> Pid {
  let assert Ok(started) =
    relay_connection.start(relay_connection.Settings(
      name: name,
      relay: "wss://relay.test",
      connect: connect,
      on_connect: fn(_socket) { process.send(reports, Rewired) },
      on_disconnect: fn() { process.send(reports, Unwired) },
      reconnect_delay: reconnect_delay,
      stable_after_ms: stable_after_ms,
    ))
  started.pid
}

/// 接続の試行の回数を 0 から数え、呼ぶ前の値を返す。接続関数は接続アクターの
/// プロセスで呼ばれる。
@external(erlang, "subscription_counter", "next")
fn next_attempt() -> Int

/// 接続アクターを停止する。テストプロセスにリンクしているため、先にリンクを
/// 解除しないとアクターと一緒にテストも落ちる。
fn stop(actor: Pid) -> Nil {
  process.unlink(actor)
  process.kill(actor)
}

/// 指定したミリ秒以内にプロセスが消えるかどうか。
fn died_within(pid: Pid, timeout_ms: Int) -> Bool {
  poll.until(fn() { !process.is_alive(pid) }, timeout_ms, 10)
}

/// アクターは指示されなくても起動時に接続する。
pub fn connects_on_start_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(_socket)) = process.receive(reports, 1000)
  assert process.receive(reports, 1000) == Ok(Rewired)
  stop(actor)
}

/// ソケットが死んでもアクターは道連れにならない。まず `on_disconnect` を実行し
/// （バンカーはこれを受けて、死んだソケットへ向いた送信手段を取り下げる）、
/// 設定した遅延の後に再接続して、呼び出し側を新しいソケットへ再配線する。
pub fn reconnects_after_the_socket_dies_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  process.kill(socket)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  // 遅延が経過するまでは接続し直さない...
  assert process.receive(reports, delay_ms / 3) == Error(Nil)
  // ...その後、2 本目の接続が張られ再配線される。
  let assert Ok(Connected(_reconnected)) = process.receive(reports, 2000)
  assert process.receive(reports, 1000) == Ok(Rewired)
  assert process.is_alive(actor)
  stop(actor)
}

/// 親から停止させられたとき（`relay_list` の `close_relay` が `terminate_child`
/// で止めるとき）も `on_disconnect` を呼ぶ。バンカーはこれで、閉じた接続の
/// 送信手段を確実に取り下げられる。
pub fn calls_on_disconnect_when_stopped_by_the_parent_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(_socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  // アクターのリンク先プロセス（このテスト）からの normal な exit シグナル。
  process.send_exit(actor)
  assert process.receive(reports, 1000) == Ok(Unwired)
}

/// 接続を拒否するリレーには、諦めずに再試行する。
pub fn keeps_retrying_after_a_failed_connect_test() {
  let reports = process.new_subject()
  let actor = start(reports, refuses(reports))
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  assert process.receive(reports, 2000) == Ok(Refused)
  assert process.receive(reports, 2000) == Ok(Unwired)
  assert process.is_alive(actor)
  stop(actor)
}

/// ハンドシェイクに失敗すると、ソケットにならなかった stratus の子プロセスから
/// exit が届く。これは切断とも、スーパーバイザーによる停止要求とも解釈せず、
/// 無視しなければならない。
pub fn exit_from_an_unrelated_process_is_ignored_test() {
  let reports = process.new_subject()
  let connect = fn() {
    // ソケットが引き渡される前に死ぬ、リンク済みのプロセス。
    process.kill(process.spawn(fn() { process.sleep_forever() }))
    let socket = spawn_socket(reports)
    process.send(reports, Connected(socket.pid))
    Ok(socket)
  }
  let actor = start(reports, connect)
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  // 再接続は起きない。この exit はソケットの死とは解釈されていない。
  assert process.receive(reports, delay_ms * 2) == Error(Nil)
  // 監視対象は正しいままなので、ソケットを kill すれば再接続する。
  assert process.is_alive(actor)
  process.kill(socket)
  let assert Ok(Unwired) = process.receive(reports, 2000)
  let assert Ok(Connected(_reconnected)) = process.receive(reports, 2000)
  stop(actor)
}

/// normal な exit はリンク越しにソケットへ伝播しないため、アクターは終了時に
/// 自分でソケットを停止する。
pub fn a_normal_exit_stops_the_socket_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  // アクターのリンク先プロセス（このテスト）からの normal な exit シグナル。
  process.send_exit(actor)
  assert died_within(actor, 1000)
  assert died_within(socket, 1000)
}

/// 管理 UI が見る接続状態は、ソケットを持っているかどうかを反映する。ソケットを
/// kill しても、再接続が完了すれば再び `Connected` を返す。
pub fn status_follows_the_socket_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_relay")
  let actor = start_named(name, reports, connects(reports))
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  assert relay_connection.status(name) == relay_connection.Connected

  process.kill(socket)
  let assert Ok(Unwired) = process.receive(reports, 2000)
  let assert Ok(Connected(_reconnected)) = process.receive(reports, 2000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  assert relay_connection.status(name) == relay_connection.Connected
  stop(actor)
}

/// リレーに拒否されて再接続を待っている間は `Disconnected`。
pub fn status_is_disconnected_while_retrying_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_relay")
  let actor = start_named(name, reports, refuses(reports))
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  assert relay_connection.status(name) == relay_connection.Disconnected
  stop(actor)
}

/// 名前を保持するプロセスがなければ、接続していないものとして扱う。アクターの
/// 再起動中に管理 UI がクラッシュしないことを保証する。
pub fn status_of_an_unregistered_name_is_disconnected_test() {
  let name = process.new_name("test_relay")
  assert relay_connection.status(name) == relay_connection.Disconnected
}

/// 接続中に張り直しを依頼すると、生きたソケットに 1 回だけ転送する。
pub fn resubscribe_is_forwarded_to_the_live_socket_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_relay")
  let actor = start_named(name, reports, connects(reports))
  let assert Ok(Connected(_socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)

  relay_connection.resubscribe(name)
  assert process.receive(reports, 1000) == Ok(Resubscribed)
  assert process.receive(reports, 200) == Error(Nil)
  stop(actor)
}

/// 再接続を待っている間の依頼は何もしない。アクターは落ちず、状態の問い合わせにも
/// 応答し続ける（次の接続が購読を評価し直す）。
pub fn resubscribe_while_retrying_is_ignored_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_relay")
  let actor = start_named(name, reports, refuses(reports))
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)

  relay_connection.resubscribe(name)
  // 依頼の後に送った問い合わせへの応答は、依頼を処理し終えたことを示す。
  assert relay_connection.status(name) == relay_connection.Disconnected
  assert process.is_alive(actor)
  stop(actor)
}

/// 名前を保持するプロセスがなければ、依頼は何もせずに捨てる。
pub fn resubscribe_of_an_unregistered_name_is_dropped_test() {
  let name = process.new_name("test_relay")
  assert relay_connection.resubscribe(name) == Nil
}

/// アクターはリンク先のプロセスが終了すると自身も終了するため、スーパーバイザー
/// による停止をやり過ごすことはできない。
pub fn stops_when_its_parent_exits_test() {
  let started = process.new_subject()
  let parent =
    process.spawn_unlinked(fn() {
      let reports = process.new_subject()
      process.send(started, start(reports, connects(reports)))
      process.sleep_forever()
    })
  let assert Ok(actor) = process.receive(started, 1000)
  process.kill(parent)
  assert died_within(actor, 1000)
}

/// 接続に失敗し続けると、再接続までの待ち時間が失敗のたびに延びる。
pub fn the_reconnect_delay_grows_while_connecting_fails_test() {
  let reports = process.new_subject()
  let actor =
    start_with_delay(
      process.new_name("test_relay"),
      reports,
      refuses(reports),
      Backoff(initial_ms: 100, max_ms: 1600),
      relay_connection.default_stable_after_ms,
    )
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  // 3 回目の後の待ちの基準値は 400ms（下限 320ms）なので、250ms 以内には来ない。
  assert process.receive(reports, 250) == Error(Nil)
  stop(actor)
}

/// 接続の直後に切られる繰り返しは失敗として数え、再接続までの待ち時間が延びる。
pub fn the_reconnect_delay_grows_while_connections_drop_right_away_test() {
  let reports = process.new_subject()
  let actor =
    start_with_delay(
      process.new_name("test_relay"),
      reports,
      connects(reports),
      Backoff(initial_ms: 100, max_ms: 1600),
      relay_connection.default_stable_after_ms,
    )
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  process.kill(socket)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  process.kill(socket)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  process.kill(socket)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  // 3 回目の後の待ちの基準値は 400ms（下限 320ms）なので、250ms 以内には来ない。
  assert process.receive(reports, 250) == Error(Nil)
  stop(actor)
}

/// 接続が一定の時間続いた後に切れると、再接続までの待ち時間は初期値に戻る。
pub fn a_lasting_connection_resets_the_reconnect_delay_test() {
  let reports = process.new_subject()
  let connect = fn() {
    case next_attempt() {
      0 | 1 | 2 -> {
        process.send(reports, Refused)
        Error("connection refused")
      }
      _ -> {
        let socket = spawn_socket(reports)
        process.send(reports, Connected(socket.pid))
        Ok(socket)
      }
    }
  }
  let actor =
    start_with_delay(
      process.new_name("test_relay"),
      reports,
      connect,
      Backoff(initial_ms: 100, max_ms: 3200),
      200,
    )
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  let assert Ok(Connected(socket)) = process.receive(reports, 2000)
  let assert Ok(Rewired) = process.receive(reports, 1000)

  process.sleep(400)
  process.kill(socket)
  let assert Ok(Unwired) = process.receive(reports, 1000)
  // 待ち時間が初期値に戻っていれば 400ms 以内に再接続する
  // （戻さなければ基準値 800ms、下限 640ms）。
  let assert Ok(Connected(_reconnected)) = process.receive(reports, 400)
  stop(actor)
}

/// 再接続の失敗ログは、直前の失敗と理由が同じなら間引き、理由が変わったときと
/// 始まりでは出す。
pub fn reconnect_report_is_silent_while_the_reason_repeats_test() {
  assert relay_connection.reconnect_report(None, "failed to connect: x", 5000)
    == Some("failed to connect: x; reconnecting in 5000ms")
  assert relay_connection.reconnect_report(
      Some("failed to connect: x"),
      "failed to connect: x",
      10_000,
    )
    == None
  assert relay_connection.reconnect_report(
      Some("failed to connect: x"),
      "failed to connect: y",
      10_000,
    )
    == Some("failed to connect: y; reconnecting in 10000ms")
}

/// テスト用の送信対象のイベント。中身は問わない。
fn draft_event() -> event.Event {
  Event(
    id: "",
    pubkey: "s1",
    created_at: 0,
    kind: 1,
    tags: [],
    content: "hi",
    sig: "",
  )
}

/// 接続中は依頼を受け付けて `True` を返し、注入したソケットの `publish` に
/// イベントが渡ったうえで、応答で `True` を返す。
pub fn publish_hands_the_event_to_the_live_socket_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_relay")
  let actor = start_named(name, reports, connects(reports))
  let assert Ok(Connected(_socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)

  let reply = process.new_subject()
  let sent = draft_event()
  assert relay_connection.publish(name, sent, reply) == True
  assert process.receive(reports, 1000) == Ok(Published(sent))
  assert process.receive(reply, 1000) == Ok(True)
  stop(actor)
}

/// ソケットが無いときも依頼は受け付けて `True` を返すが、ソケットには何も渡さず、
/// 応答で `False` を返す。
pub fn publish_replies_false_while_disconnected_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_relay")
  let actor = start_named(name, reports, refuses(reports))
  assert process.receive(reports, 1000) == Ok(Refused)
  let assert Ok(Unwired) = process.receive(reports, 1000)

  let reply = process.new_subject()
  assert relay_connection.publish(name, draft_event(), reply) == True
  assert process.receive(reply, 1000) == Ok(False)
  assert process.receive(reports, 200) == Error(Nil)
  stop(actor)
}
