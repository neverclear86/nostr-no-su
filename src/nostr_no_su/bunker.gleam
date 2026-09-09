//// 純粋な `engine` を包む薄いアクター。リレーの再接続をまたいでセッション状態を
//// 保持する（リレークライアントは切断のたびに再起動されるため、そこにセッション
//// 状態を置けない）。判断ロジックはすべて `engine` 側に残す。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/io
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/bunker/engine
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/time

pub type Msg {
  /// バンカー接続のいずれかで受信した kind 24133 イベント。
  Incoming(event: Event)
  /// 1 本のリレー接続で応答イベントを送信するための関数を登録する。各接続
  /// アクターは再接続のたびに `on_connect` からこれを送り直すため、応答は生きた
  /// ソケットから出ていく。応答はすべてのバンカーリレーへ送信する。クライアント
  /// は URI の `relay=` ヒントすべてを待ち受けており、重複配信の排除はクライアント
  /// 側の責務（こちら側の重複は `engine` が排除する）なので、生きたリレーが 1 つ
  /// あれば往復は成立する。
  SetPublisher(relay_url: String, publish: fn(Event) -> Nil)
}

type State {
  State(engine: engine.Engine, publishers: Dict(String, fn(Event) -> Nil))
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  initial: engine.Engine,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, initial) })
}

/// 指定したエンジン状態でバンカーアクターを起動する。`name` で登録するため、
/// 接続は起動時に生きていたプロセスではなく、現在その名前を保持しているプロセス
/// に到達する。
pub fn start(
  name: Name(Msg),
  initial: engine.Engine,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(engine: initial, publishers: dict.new()))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// publisher を登録するか、受信イベント 1 件をエンジンに通し、生成された応答を
/// 全接続へ送信する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    SetPublisher(relay_url, publish) ->
      actor.continue(
        State(
          ..state,
          publishers: dict.insert(state.publishers, relay_url, publish),
        ),
      )
    Incoming(incoming) -> {
      let #(next, outcome) =
        engine.handle_event(state.engine, incoming, time.now_seconds())
      case outcome {
        engine.Reply(response) ->
          dict.each(state.publishers, fn(_relay_url, publish) {
            publish(response)
          })
        engine.Duplicate -> Nil
        engine.Ignore(reason) -> io.println("[bunker] ignored: " <> reason)
      }
      actor.continue(State(..state, engine: next))
    }
  }
}
