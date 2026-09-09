//// リレーをまたいだイベントの重複排除。直近のイベント id を保持する純粋な
//// スライディング `Window` と、ウィンドウが受理した id についてプラグインを
//// 実行する薄いアクターからなる。リレーは同じイベントを繰り返し配信する（複数の
//// リレーが同じイベントを持つ、再接続時に保存済みイベントが再送される）ため、
//// プラグインが同じ id を 2 度見てはならない。
////
//// メモリ使用量は 2 世代のウィンドウで有界にする。現在の世代の id が `capacity`
//// 件に達すると前世代に移して新しい世代を開始するため、常に `capacity` 件以上
//// `2 * capacity` 件以下の直近 id を記憶する。

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/set.{type Set}
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}

/// 記憶している id。ウィンドウが埋まったときに最古の世代をまとめて捨てられる
/// よう、2 世代に分けて保持する。
pub opaque type Window {
  Window(capacity: Int, current: Set(String), previous: Set(String))
}

/// 少なくとも `capacity` 件の id を記憶する空のウィンドウ。
pub fn new(capacity: Int) -> Window {
  Window(capacity: capacity, current: set.new(), previous: set.new())
}

/// id を記録し、現在の世代が埋まったら世代を切り替える。ウィンドウがすでに
/// その id を持つ場合は `Error(Nil)` を返す。
pub fn insert(window: Window, id: String) -> Result(Window, Nil) {
  case set.contains(window.current, id) || set.contains(window.previous, id) {
    True -> Error(Nil)
    False -> {
      let current = set.insert(window.current, id)
      case set.size(current) >= window.capacity {
        True -> Ok(Window(..window, previous: current, current: set.new()))
        False -> Ok(Window(..window, current: current))
      }
    }
  }
}

pub type Msg {
  /// 監視接続のいずれかで受信したイベント。
  Incoming(event: Event)
}

type State {
  State(plugins: List(Plugin), window: Window)
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  plugins: List(Plugin),
  capacity: Int,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, plugins, capacity) })
}

/// 指定したプラグイン向けのディスパッチャを起動し、直近のイベント id を少なく
/// とも `capacity` 件記憶する。`name` で登録するため、再起動後も接続から到達
/// できる。
pub fn start(
  name: Name(Msg),
  plugins: List(Plugin),
  capacity: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(plugins: plugins, window: new(capacity)))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// ウィンドウが未受理のイベントについてプラグインを実行し、それ以外は破棄する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Incoming(incoming) = msg
  case insert(state.window, incoming.id) {
    Error(Nil) -> actor.continue(state)
    Ok(window) -> {
      plugin.dispatch(state.plugins, incoming)
      actor.continue(State(..state, window: window))
    }
  }
}
