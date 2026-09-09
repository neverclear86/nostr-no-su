//// リレーをまたいだイベントの重複排除ディスパッチャー。
////
//// `dedup/window` が新規として受理した id についてだけプラグインを実行する薄い
//// アクター。リレーは同じイベントを繰り返し配信する（複数のリレーが同じイベント
//// を持つ、再接続時に保存済みイベントが再送される）ため、プラグインが同じ id を
//// 2 度見てはならない。

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/dedup/window.{type Window}
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}

/// ディスパッチャーが受け取るメッセージ。
pub type Msg {
  /// 監視接続のいずれかで受信したイベント。
  Incoming(event: Event)
}

/// ディスパッチャーが保持する状態。
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

/// 指定したプラグイン向けのディスパッチャーを起動し、直近のイベント id を少なく
/// とも `capacity` 件記憶する。`name` で登録するため、再起動後も接続から到達
/// できる。
pub fn start(
  name: Name(Msg),
  plugins: List(Plugin),
  capacity: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(plugins: plugins, window: window.new(capacity)))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// ウィンドウがまだ見ていないイベントについてプラグインを実行し、それ以外は
/// 破棄する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Incoming(incoming) = msg
  case window.insert(state.window, incoming.id) {
    Error(Nil) -> actor.continue(state)
    Ok(next) -> {
      plugin.dispatch(state.plugins, incoming)
      actor.continue(State(..state, window: next))
    }
  }
}
