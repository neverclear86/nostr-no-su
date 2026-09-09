//// リレーへのスーパーバイザー配下の接続 1 本。
////
//// アクターがソケットプロセスを所有する。自身のループから接続を開き、ソケットが
//// 死んだときは道連れにならず再接続を予約するため、不安定なリレーがスーパー
//// バイザーの再起動許容回数を消費することがない。これには exit の trap が必要で、
//// その結果、ツリー停止時にスーパーバイザーが送る exit シグナルもメッセージとして
//// 届くようになる。`handle` は pid で両者を区別し、後者は再送出する。

import gleam/erlang/process.{type ExitMessage, type Name, type Pid, type Subject}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}

/// 接続が切れた、あるいは拒否された後、再接続するまでの待ち時間。
pub const default_reconnect_delay_ms = 5000

/// 状態の問い合わせを待つ時間。接続試行はアクターのループをブロックするため、
/// `relay_client` の connect タイムアウト（3 秒）より長く取る。
const status_timeout_ms = 5000

/// 生きている接続。切断検知のために監視するプロセスと、そこからイベントを
/// 送信する手段を持つ。
pub type Socket {
  Socket(pid: Pid, publish: fn(Event) -> Nil)
}

/// ソケットの開き方。再接続ロジックを WebSocket なしでテストできるよう注入する。
pub type Open =
  fn() -> Result(Socket, String)

/// 外から見た接続の状態。生きたソケットを保持していれば `Connected`。
pub type Status {
  Connected
  Disconnected
}

/// 接続 1 本に必要なものすべて。状態を問い合わせるためのプロセス名、ログ行に
/// 付けるラベル、ソケットの開き方、新しいソケットごとに行う処理、再接続までの
/// 待ち時間。
pub type Config {
  Config(
    name: Name(Msg),
    relay: String,
    connect: Open,
    on_connect: fn(Socket) -> Nil,
    reconnect_delay_ms: Int,
  )
}

pub type Msg {
  /// ソケットを開く。初期化処理と再接続タイマーから送られる。
  Connect
  /// リンクしたプロセスが終了した。ソケットか、このアクターを停止させようと
  /// しているスーパーバイザーのいずれか。
  Exited(exit: ExitMessage)
  /// 現在の接続状態を問い合わせる。管理 UI が使う。
  GetStatus(reply: Subject(Status))
}

/// 接続アクターに現在の状態を問い合わせる。名前を保持するプロセスがない
/// （再起動中など）ときは接続していないものとして扱う。
pub fn status(name: Name(Msg)) -> Status {
  case named.call(name, status_timeout_ms, GetStatus) {
    Some(status) -> status
    None -> Disconnected
  }
}

type State {
  State(config: Config, parent: Pid, self: Subject(Msg), socket: Option(Pid))
}

/// スーパービジョンツリー用の子仕様。ワーカーの既定の停止タイムアウト 5000ms が
/// 適用される。`connect` の実行中はアクターがブロックされるため、それより長く
/// ブロックしうる `connect` を注入すると、正常に停止できずハンドシェイクの
/// 途中で kill される。
pub fn supervised(config: Config) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(config) })
}

/// 接続アクターを起動する。リレーに到達できなくても起動は成功するため、URL が
/// 1 つ不正でもサブツリー全体の起動が失敗することはない。`name` で登録するため、
/// 管理 UI は再起動をまたいで同じ宛先に状態を問い合わせられる。
pub fn start(config: Config) -> actor.StartResult(Subject(Msg)) {
  // `start` はアクターをリンクするプロセス上で動く。スーパーバイザー配下では
  // それはスーパーバイザー自身であり、そこからの exit は停止要求を意味する。
  let parent = process.self()
  actor.new_with_initialiser(1000, fn(self) { initialise(config, parent, self) })
  |> actor.named(config.name)
  |> actor.on_message(handle)
  |> actor.start
}

/// ソケットの死をメッセージとして受け取れるよう exit を trap し、最初の接続試行を
/// キューに積む。ここで接続するとスーパーバイザーの起動をブロックしてしまう。
fn initialise(
  config: Config,
  parent: Pid,
  self: Subject(Msg),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  process.trap_exits(True)
  process.send(self, Connect)
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select_trapped_exits(Exited)
  State(config: config, parent: parent, self: self, socket: None)
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

/// ソケットを開くか、状態を報告するか、リンクしたプロセスの死に対応する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Connect -> open(state)
    GetStatus(reply) -> {
      process.send(reply, current_status(state))
      actor.continue(state)
    }
    Exited(exit) ->
      case exit.pid == state.parent, Some(exit.pid) == state.socket {
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
    Some(_pid) -> Connected
    None -> Disconnected
  }
}

/// ソケットを開き、新しいソケットを `on_connect` に渡す。リレーに到達できない
/// ときは再試行を予約する。
fn open(state: State) -> actor.Next(State, Msg) {
  case state.config.connect() {
    Ok(socket) -> {
      state.config.on_connect(socket)
      actor.continue(State(..state, socket: Some(socket.pid)))
    }
    Error(reason) -> reconnect(state, "failed to connect: " <> reason)
  }
}

/// ソケットが失われた理由をログ出力し、次の試行を予約する。
fn reconnect(state: State, reason: String) -> actor.Next(State, Msg) {
  let delay = state.config.reconnect_delay_ms
  io.println(
    "[relay "
    <> state.config.relay
    <> "] "
    <> reason
    <> "; reconnecting in "
    <> int.to_string(delay)
    <> "ms",
  )
  let _ = process.send_after(state.self, delay, Connect)
  actor.continue(State(..state, socket: None))
}

/// 停止を要求する exit シグナルを受けて終了する。アクターのループは trap した
/// exit を通常のメッセージとして扱うため、スーパーバイザーが待っている理由で
/// 終了するには、trap を解除してシグナルを送り直す必要がある。ソケットはリンクを
/// 通じて一緒に死ぬ。
fn shutdown(
  state: State,
  reason: process.ExitReason,
) -> actor.Next(State, Msg) {
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
      process.unlink(socket)
      process.kill(socket)
    }
    None -> Nil
  }
}
