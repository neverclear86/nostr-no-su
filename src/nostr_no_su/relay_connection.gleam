//// リレーへのスーパーバイザー配下の接続 1 本。
////
//// アクターがソケットプロセスを所有する。自身のループから接続を開き、ソケットが
//// 死んだときは道連れにならず再接続を予約するため、不安定なリレーがスーパー
//// バイザーの再起動許容回数を消費することがない。これには exit の trap が必要で、
//// その結果、ツリー停止時にスーパーバイザーが送る exit シグナルもメッセージとして
//// 届くようになる。`handle` は pid で両者を区別し、後者は再送出する。

import gleam/erlang/process.{type ExitMessage, type Name, type Pid, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/backoff
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}

/// 接続が切れた、あるいは拒否された後の再接続の待ち時間。5 秒から倍にして 5 分で
/// 頭打ちにし、接続できたら 5 秒から数え直す。
pub const default_reconnect_delay = backoff.Backoff(
  initial_ms: 5000,
  max_ms: 300_000,
)

/// 状態の問い合わせを待つ時間。接続試行はアクターのループをブロックするため、
/// `relay_client` の connect タイムアウト（3 秒）より長く取る。
const status_timeout_ms = 5000

/// 生きている接続。切断検知のために監視するプロセスと、そこからイベントを
/// 送信する手段と、購読を現在の定義へ合わせ直させる手段を持つ。
pub type Socket {
  Socket(pid: Pid, publish: fn(Event) -> Nil, resubscribe: fn() -> Nil)
}

/// ソケットの開き方。再接続ロジックを WebSocket なしでテストできるよう注入する。
/// 型の名前を `Msg` のバリアント `Connect` と分けておくと、注釈だけを見たときに
/// 関数型かメッセージかを迷わない。
pub type Connector =
  fn() -> Result(Socket, String)

/// 外から見た接続の状態。生きたソケットを保持していれば `Connected`。
pub type Status {
  Connected
  Disconnected
}

/// 接続 1 本に必要なものすべて。状態を問い合わせるためのプロセス名、ログ行に
/// 付けるラベル、ソケットの開き方、新しいソケットごとに行う処理、ソケットを
/// 失ったとき（再接続を待つ間、および親（スーパーバイザー）からの停止）に
/// 行う処理、再接続の待ち時間の延ばし方。
pub type Settings {
  Settings(
    name: Name(Msg),
    relay: String,
    connect: Connector,
    on_connect: fn(Socket) -> Nil,
    on_disconnect: fn() -> Nil,
    reconnect_delay: backoff.Backoff,
  )
}

/// 接続アクターが受け取るメッセージ。
pub type Msg {
  /// ソケットを開く。初期化処理と再接続タイマーから送られる。
  Connect
  /// リンクしたプロセスが終了した。ソケットか、このアクターを停止させようと
  /// しているスーパーバイザーのいずれか。
  Exited(exit: ExitMessage)
  /// 現在の接続状態を問い合わせる。管理 UI が使う。
  GetStatus(reply: Subject(Status))
  /// 生きたソケットに購読を合わせ直させる。接続していなければ何もしない
  /// （次の接続が購読を評価し直すため）。
  Resubscribe
}

/// 接続アクターに現在の状態を問い合わせる。名前を保持するプロセスがない
/// （再起動中など）、あるいは応答が返らないときは接続していないものとして扱う。
pub fn status(name: Name(Msg)) -> Status {
  named.call(name, status_timeout_ms, GetStatus)
  |> option.unwrap(Disconnected)
}

/// 接続アクターに購読の張り直しを依頼する。名前を保持するプロセスがなければ
/// 何もしない。依頼は接続アクターのメールボックスを通るので、接続の途中に届いた
/// 依頼は新しいソケットを保持した後に転送され、再接続を待っている間の依頼は次の
/// 接続が購読を評価し直すことで満たされる。
pub fn resubscribe(name: Name(Msg)) -> Nil {
  named.send(name, Resubscribe)
}

/// 接続アクターが保持する状態。生きたソケットを持つかどうかが、外から見た
/// 接続状態そのものになる。
type State {
  State(
    settings: Settings,
    parent: Pid,
    self: Subject(Msg),
    socket: Option(Socket),
    /// 直前の失敗の理由。接続中や未失敗なら `None`。
    failure: Option(String),
    /// 次に失敗したときの、ジッターを掛ける前の待ち時間。
    delay_ms: Int,
  )
}

/// スーパービジョンツリー用の子仕様。ワーカーの既定の停止タイムアウト 5000ms が
/// 適用される。`connect` の実行中はアクターがブロックされるため、それより長く
/// ブロックしうる `connect` を注入すると、正常に停止できずハンドシェイクの
/// 途中で kill される。
pub fn supervised(settings: Settings) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(settings) })
}

/// 接続アクターを起動する。リレーに到達できなくても起動は成功するため、1 つの
/// リレーの障害でサブツリー全体の起動が失敗することはない（URL の形は起動時に
/// 検査する）。`name` で登録するため、管理 UI は再起動をまたいで同じ宛先に状態を
/// 問い合わせられる。
pub fn start(settings: Settings) -> actor.StartResult(Subject(Msg)) {
  // `start` はアクターをリンクするプロセス上で動く。スーパーバイザー配下では
  // それはスーパーバイザー自身であり、そこからの exit は停止要求を意味する。
  let parent = process.self()
  actor.new_with_initialiser(1000, fn(self) {
    initialise(settings, parent, self)
  })
  |> actor.named(settings.name)
  |> actor.on_message(handle)
  |> actor.start
}

/// ソケットの死をメッセージとして受け取れるよう exit を trap し、最初の接続試行を
/// キューに積む。ここで接続するとスーパーバイザーの起動をブロックしてしまう。
fn initialise(
  settings: Settings,
  parent: Pid,
  self: Subject(Msg),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  process.trap_exits(True)
  process.send(self, Connect)
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select_trapped_exits(Exited)
  State(
    settings: settings,
    parent: parent,
    self: self,
    socket: None,
    failure: None,
    delay_ms: settings.reconnect_delay.initial_ms,
  )
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

/// ソケットを開くか、状態を報告するか、購読の張り直しを転送するか、リンクした
/// プロセスの死に対応する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Connect -> open(state)
    GetStatus(reply) -> {
      process.send(reply, current_status(state))
      actor.continue(state)
    }
    Resubscribe -> {
      case state.socket {
        Some(socket) -> socket.resubscribe()
        None -> Nil
      }
      actor.continue(state)
    }
    Exited(exit) ->
      case exit.pid == state.parent, Some(exit.pid) == socket_pid(state) {
        True, _ -> shutdown(state, exit.reason)
        _, True -> reconnect(state, "disconnected")
        // どちらでもない場合。ハンドシェイクに失敗すると、ソケットにならな
        // かった stratus の子プロセスからの exit が残るが、これは反応すべき
        // ものではない。
        False, False -> actor.continue(state)
      }
  }
}

/// 生きたソケットを保持しているかどうか。再接続待ちの間は `Disconnected`。
fn current_status(state: State) -> Status {
  case state.socket {
    Some(_socket) -> Connected
    None -> Disconnected
  }
}

/// 保持しているソケットのプロセス。`Socket` は関数を持ち `==` で比べられない
/// ため、終了したプロセスとの照合はこの pid で行う。
fn socket_pid(state: State) -> Option(Pid) {
  option.map(state.socket, fn(socket) { socket.pid })
}

/// ソケットを開き、新しいソケットを `on_connect` に渡す。リレーに到達できない
/// ときは再試行を予約する。失敗の後に接続できたらその旨を 1 行出し、待ち時間を
/// 初期値に戻す。
fn open(state: State) -> actor.Next(State, Msg) {
  case state.settings.connect() {
    Ok(socket) -> {
      case state.failure {
        Some(_) ->
          log.write(
            log.Notice,
            log.relay_prefix(state.settings.relay),
            "connected",
          )
        None -> Nil
      }
      state.settings.on_connect(socket)
      actor.continue(
        State(
          ..state,
          socket: Some(socket),
          failure: None,
          delay_ms: state.settings.reconnect_delay.initial_ms,
        ),
      )
    }
    Error(reason) -> reconnect(state, "failed to connect: " <> reason)
  }
}

/// ソケットが失われた理由をログ出力し、`on_connect` で配った送信手段を撤回して
/// もらったうえで、次の試行を予約する。接続そのものに失敗した場合も通るが、
/// 配っていない送信手段の撤回は何も起こさないため区別しない。同じ理由の失敗が
/// 続く間はログを出さない。待ち時間は失敗のたびに延ばす。
fn reconnect(state: State, reason: String) -> actor.Next(State, Msg) {
  state.settings.on_disconnect()
  let delay = backoff.jittered(state.delay_ms)
  case reconnect_report(state.failure, reason, delay) {
    Some(line) ->
      log.write(log.Warning, log.relay_prefix(state.settings.relay), line)
    None -> Nil
  }
  let _ = process.send_after(state.self, delay, Connect)
  actor.continue(
    State(
      ..state,
      socket: None,
      failure: Some(reason),
      delay_ms: backoff.next(state.settings.reconnect_delay, state.delay_ms),
    ),
  )
}

/// 再接続を予約するときに出すログ行。直前の失敗と同じ理由なら `None`、それ以外は
/// `<reason>; reconnecting in <delay_ms>ms`。`bunker.load_report` と同じく、
/// 失敗の始まりと理由の変化だけを報告する。
pub fn reconnect_report(
  previous_failure: Option(String),
  reason: String,
  delay_ms: Int,
) -> Option(String) {
  case previous_failure {
    Some(previous) if previous == reason -> None
    _ -> Some(reason <> "; reconnecting in " <> int.to_string(delay_ms) <> "ms")
  }
}

/// 停止を要求する exit シグナルを受けて終了する。アクターのループは trap した
/// exit を通常のメッセージとして扱うため、スーパーバイザーが待っている理由で
/// 終了するには、trap を解除してシグナルを送り直す必要がある。ソケットはリンクを
/// 通じて一緒に死ぬ。生きたソケットを持っていれば、`reconnect` と同じく
/// `on_disconnect` を呼んで送信手段を撤回してもらう。`relay_list` の
/// `close_relay` はこの終了を待ってから戻るため、戻った時点で撤回は依頼済みに
/// なる。
fn shutdown(
  state: State,
  reason: process.ExitReason,
) -> actor.Next(State, Msg) {
  case state.socket {
    Some(_socket) -> state.settings.on_disconnect()
    None -> Nil
  }
  process.trap_exits(False)
  case reason {
    // `Normal` な exit はリンク越しに伝播しないため、ソケットがアクターより長く
    // 生き残ってしまう。スーパーバイザーは `shutdown` か `kill` で停止を求める
    // ので、ここに来るのはそれ以外の要因でアクターが停止した場合だけ。
    process.Normal -> stop_socket(state)
    process.Killed -> process.kill(process.self())
    process.Abnormal(reason) ->
      process.send_abnormal_exit(process.self(), reason)
  }
  actor.stop()
}

/// ソケットが自動では落ちない終了理由のときに、ソケットを落とす。先にリンクを
/// 解除するのは、この時点では exit を trap していないため、kill がリンクを
/// 逆流してアクターの終了のしかたを左右してしまうから。
fn stop_socket(state: State) -> Nil {
  case state.socket {
    Some(socket) -> {
      process.unlink(socket.pid)
      process.kill(socket.pid)
    }
    None -> Nil
  }
}
