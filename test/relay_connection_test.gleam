import gleam/erlang/process.{type Name, type Pid, type Subject}
import nostr_no_su/relay_connection.{type Socket, Socket}

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
}

/// 偽ソケット。stratus プロセスと同じく、接続アクターにリンクした待機プロセス。
/// これを kill すると切断とまったく同じに見える。
fn spawn_socket() -> Socket {
  let pid = process.spawn(fn() { process.sleep_forever() })
  Socket(pid: pid, publish: fn(_event) { Nil })
}

/// 常に新しいソケットを返し、それを報告する connect 関数。
fn connects(reports: Subject(Report)) -> relay_connection.Open {
  fn() {
    let socket = spawn_socket()
    process.send(reports, Connected(socket.pid))
    Ok(socket)
  }
}

/// 到達できないリレーを模した connect 関数。
fn refuses(reports: Subject(Report)) -> relay_connection.Open {
  fn() {
    process.send(reports, Refused)
    Error("connection refused")
  }
}

/// 指定した connect 関数で接続アクターを起動し、再配線のたびに報告する。
fn start(reports: Subject(Report), connect: relay_connection.Open) -> Pid {
  start_named(process.new_name("test_relay"), reports, connect)
}

/// 指定した名前で接続アクターを起動する。状態の問い合わせには名前が要る。
fn start_named(
  name: Name(relay_connection.Msg),
  reports: Subject(Report),
  connect: relay_connection.Open,
) -> Pid {
  let assert Ok(started) =
    relay_connection.start(relay_connection.Config(
      name: name,
      relay: "relay.test",
      connect: connect,
      on_connect: fn(_socket) { process.send(reports, Rewired) },
      reconnect_delay_ms: delay_ms,
    ))
  started.pid
}

/// 接続アクターを停止する。テストプロセスにリンクしているため、先にリンクを
/// 解除しないとアクターと一緒にテストも落ちる。
fn stop(actor: Pid) -> Nil {
  process.unlink(actor)
  process.kill(actor)
}

/// 指定したミリ秒以内にプロセスが消えるかどうか。
fn died_within(pid: Pid, timeout_ms: Int) -> Bool {
  case process.is_alive(pid), timeout_ms <= 0 {
    False, _ -> True
    True, True -> False
    True, False -> {
      process.sleep(10)
      died_within(pid, timeout_ms - 10)
    }
  }
}

/// アクターは指示されなくても起動時に接続する。
pub fn connects_on_start_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(_socket)) = process.receive(reports, 1000)
  assert process.receive(reports, 1000) == Ok(Rewired)
  stop(actor)
}

/// ソケットが死んでもアクターは道連れにならない。設定した遅延の後に再接続し、
/// 呼び出し側を新しいソケットへ再配線する。
pub fn reconnects_after_the_socket_dies_test() {
  let reports = process.new_subject()
  let actor = start(reports, connects(reports))
  let assert Ok(Connected(socket)) = process.receive(reports, 1000)
  let assert Ok(Rewired) = process.receive(reports, 1000)
  process.kill(socket)
  // 遅延が経過するまでは何も起きない...
  assert process.receive(reports, delay_ms / 3) == Error(Nil)
  // ...その後、2 本目の接続が張られ再配線される。
  let assert Ok(Connected(_reconnected)) = process.receive(reports, 2000)
  assert process.receive(reports, 1000) == Ok(Rewired)
  assert process.is_alive(actor)
  stop(actor)
}

/// 接続を拒否するリレーには、諦めずに再試行する。
pub fn keeps_retrying_after_a_failed_connect_test() {
  let reports = process.new_subject()
  let actor = start(reports, refuses(reports))
  assert process.receive(reports, 1000) == Ok(Refused)
  assert process.receive(reports, 2000) == Ok(Refused)
  assert process.receive(reports, 2000) == Ok(Refused)
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
    let socket = spawn_socket()
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
  assert relay_connection.status(name) == relay_connection.Disconnected
  stop(actor)
}

/// 名前を保持するプロセスがなければ、接続していないものとして扱う。アクターの
/// 再起動中に管理 UI がクラッシュしないことを保証する。
pub fn status_of_an_unregistered_name_is_disconnected_test() {
  let name = process.new_name("test_relay")
  assert relay_connection.status(name) == relay_connection.Disconnected
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
