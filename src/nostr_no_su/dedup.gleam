//// リレーをまたいだイベントの重複排除ディスパッチャー。
////
//// `dedup/window` が新規として受理した id についてだけイベントを `deliver` へ
//// 渡す薄いアクター。渡した先はプラグインごとの専用プロセス（`plugin_runner`）で、
//// この呼び出しは送信で終わるため、プラグインの実行時間はここに載らない。
//// `deliver` は配送先の状態（`plugin_runner` では取りこぼしの件数）を受け取って
//// 更新したものを返し、アクターがそれを次のイベントへ持ち越す。
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

/// ディスパッチャーが保持する状態。`targets` は配送先の状態で、`deliver` が
/// イベントごとに更新する。
type State(targets) {
  State(
    targets: targets,
    deliver: fn(targets, Event) -> targets,
    window: Window,
  )
}

/// スーパービジョンツリー用の子仕様。再起動したディスパッチャーは `targets` の
/// 初期値から始めるので、それまでの配送先の状態は失われる。`plugin_runner` の
/// 宛先なら、再起動の前から続く取りこぼしの復帰の行は出ず、ランナーがまだ
/// 居なければ取りこぼしの開始の行がもう一度出る。
pub fn supervised(
  name: Name(Msg),
  targets: targets,
  deliver: fn(targets, Event) -> targets,
  capacity: Int,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, targets, deliver, capacity) })
}

/// 新規と判定したイベントを `deliver` へ渡すディスパッチャーを起動し、直近の
/// イベント id を少なくとも `capacity` 件記憶する。`name` で登録するため、
/// 再起動後も接続から到達できる。
pub fn start(
  name: Name(Msg),
  targets: targets,
  deliver: fn(targets, Event) -> targets,
  capacity: Int,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(
    targets: targets,
    deliver: deliver,
    window: window.new(capacity),
  ))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// ウィンドウがまだ見ていないイベントを `deliver` へ渡し、それ以外は破棄する。
fn handle(state: State(targets), msg: Msg) -> actor.Next(State(targets), Msg) {
  let Incoming(incoming) = msg
  case window.insert(state.window, incoming.id) {
    Error(Nil) -> actor.continue(state)
    Ok(next) ->
      actor.continue(
        State(
          ..state,
          targets: state.deliver(state.targets, incoming),
          window: next,
        ),
      )
  }
}
