//// 純粋な `engine` を包む薄いアクター。リレーの再接続をまたいでセッション状態を
//// 保持する（リレークライアントは切断のたびに再起動されるため、そこにセッション
//// 状態を置けない）。判断ロジックはすべて `engine` 側に残す。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/io
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/bunker/engine.{type Session}
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/time

/// 問い合わせの応答を待つ時間。アクターの処理はどれも数ミリ秒で終わるため、
/// これを超えるのはアクターが詰まっているときだけ。
const call_timeout_ms = 5000

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
  /// 承認済みセッションの一覧を問い合わせる。
  GetSessions(reply: Subject(List(Session)))
  /// セッションを 1 件取り消す（`logout` 相当）。取り消し後の画面が古い一覧を
  /// 読まないよう、完了を待てるように応答する。
  Revoke(signer: String, client: String, reply: Subject(Nil))
}

/// バンカーが保持する承認済みセッションの一覧。アクターが動いていなければ空。
pub fn sessions(name: Name(Msg)) -> List(Session) {
  named.call(name, call_timeout_ms, GetSessions)
  |> option.unwrap([])
}

/// セッションを 1 件取り消し、反映されるまで待つ。アクターが動いていなければ
/// 何もしない。
pub fn revoke(name: Name(Msg), signer: String, client: String) -> Nil {
  named.call(name, call_timeout_ms, Revoke(signer, client, _))
  |> option.unwrap(Nil)
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

/// publisher の登録、セッションの照会と取り消し、あるいは受信イベント 1 件を
/// エンジンに通して生成された応答を全接続へ送信する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    GetSessions(reply) -> {
      process.send(reply, engine.sessions(state.engine))
      actor.continue(state)
    }
    Revoke(signer, client, reply) -> {
      let engine = engine.revoke(state.engine, signer, client)
      process.send(reply, Nil)
      actor.continue(State(..state, engine: engine))
    }
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
