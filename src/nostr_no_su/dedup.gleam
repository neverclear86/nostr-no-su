//// リレーをまたいだイベントの重複排除ディスパッチャー。
////
//// `dedup/window` が新規として受理した id についてだけイベントを `deliver` へ
//// 渡す薄いアクター。渡した先はプラグインごとの専用プロセス（`plugin_runner`）で、
//// この呼び出しは送信で終わるため、プラグインの実行時間はここに載らない。
////
//// リレーは同じイベントを繰り返し配信する（複数のリレーが同じイベントを持つ、
//// 再接続時に保存済みイベントが再送される）ため、プラグインが同じ id を 2 度
//// 見てはならない。

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/dedup/window.{type Window}
import nostr_no_su/nostr/event.{type Event}

/// ディスパッチャーが受け取るメッセージ。
pub type Msg {
  /// 監視接続のいずれかで受信したイベント。
  Incoming(event: Event)
}

/// ディスパッチャーが保持する状態。
type State {
  State(deliver: fn(Event) -> Nil, window: Window)
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  deliver: fn(Event) -> Nil,
  capacity: Int,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, deliver, capacity) })
}

/// 新規と判定したイベントを `deliver` へ渡すディスパッチャーを起動し、直近の
/// イベント id を少なくとも `capacity` 件記憶する。`name` で登録するため、
/// 再起動後も接続から到達できる。
pub fn start(
  name: Name(Msg),
  deliver: fn(Event) -> Nil,
  capacity: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(deliver: deliver, window: window.new(capacity)))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// ウィンドウがまだ見ていないイベントを `deliver` へ渡し、それ以外は破棄する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  let Incoming(incoming) = msg
  case window.insert(state.window, incoming.id) {
    Error(Nil) -> actor.continue(state)
    Ok(next) -> {
      state.deliver(incoming)
      actor.continue(State(..state, window: next))
    }
  }
}
