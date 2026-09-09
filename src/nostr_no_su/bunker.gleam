//// 純粋な `engine` を包む薄いアクター。リレーの再接続をまたいでセッション状態を
//// 保持する（リレークライアントは切断のたびに再起動されるため、そこにセッション
//// 状態を置けない）。判断ロジックはすべて `engine` 側に残す。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/io
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/bunker/engine.{type Pending, type Session}
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/random
import nostr_no_su/time

/// 問い合わせの応答を待つ時間。アクターの処理はどれも数ミリ秒で終わるため、
/// これを超えるのはアクターが詰まっているときだけ。
const call_timeout_ms = 5000

/// 承認ページの URL に入るトークンのバイト数。承認・拒否そのものは管理 UI の
/// 認証が守るが、トークンは保留の識別子なので、認証を通った管理者が別の要求を
/// 取り違えないよう推測できない長さにする。
const token_bytes = 16

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
  /// 承認待ちの接続要求の一覧を問い合わせる。
  GetPending(reply: Subject(List(Pending)))
  /// 承認待ちの接続要求を承認する。承認を状態に反映し、登録済みの接続へ応答
  /// イベントを送る。要求が見つからなければ理由を返す。
  Approve(token: String, reply: Subject(Result(Nil, String)))
  /// 承認待ちの接続要求を拒否する。
  Deny(token: String, reply: Subject(Result(Nil, String)))
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

/// 承認待ちの接続要求の一覧。アクターが動いていなければ空。
pub fn pending(name: Name(Msg)) -> List(Pending) {
  named.call(name, call_timeout_ms, GetPending)
  |> option.unwrap([])
}

/// 接続要求を 1 件承認し、応答イベントを送り出すまで待つ。
pub fn approve(name: Name(Msg), token: String) -> Result(Nil, String) {
  call_decision(name, Approve(token, _))
}

/// 接続要求を 1 件拒否し、応答イベントを送り出すまで待つ。
pub fn deny(name: Name(Msg), token: String) -> Result(Nil, String) {
  call_decision(name, Deny(token, _))
}

/// 承認・拒否をアクターへ送って結果を待つ。アクターが動いていなければエラーに
/// する。承認したつもりのまま待たせ続けるより、UI に失敗として出す方がよい。
fn call_decision(
  name: Name(Msg),
  request: fn(Subject(Result(Nil, String))) -> Msg,
) -> Result(Nil, String) {
  named.call(name, call_timeout_ms, request)
  |> option.unwrap(Error("bunker is not running"))
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

/// publisher の登録、セッションと承認待ちの照会、セッションの取り消し、承認待ちの
/// 承認と拒否、あるいは受信イベント 1 件をエンジンに通して生成された応答を全接続
/// へ送信する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    GetPending(reply) -> {
      process.send(reply, engine.pending(state.engine, time.now_seconds()))
      actor.continue(state)
    }
    Approve(token, reply) ->
      apply_decision(state, reply, engine.approve(state.engine, token, _))
    Deny(token, reply) ->
      apply_decision(state, reply, engine.deny(state.engine, token, _))
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
      // トークンは受信のたびに引く。使うのは承認待ちを作るときだけだが、そう
      // することでエンジンは乱数を持たずに済む。
      let context =
        engine.Context(now: time.now_seconds(), token: random.hex(token_bytes))
      let #(next, outcome) =
        engine.handle_event(state.engine, incoming, context)
      case outcome {
        engine.Reply(response) -> publish(state, response)
        engine.Duplicate -> Nil
        engine.Ignore(reason) -> io.println("[bunker] ignored: " <> reason)
      }
      actor.continue(State(..state, engine: next))
    }
  }
}

/// 承認・拒否の結果を状態に反映し、待たせているクライアントへ応答イベントを
/// 発行する。token が不明・失効していれば状態は変えずに理由を返す。
fn apply_decision(
  state: State,
  reply: Subject(Result(Nil, String)),
  decision: fn(Int) -> Result(#(engine.Engine, Event), String),
) -> actor.Next(State, Msg) {
  case decision(time.now_seconds()) {
    Error(reason) -> {
      process.send(reply, Error(reason))
      actor.continue(state)
    }
    Ok(#(next, response)) -> {
      publish(state, response)
      process.send(reply, Ok(Nil))
      actor.continue(State(..state, engine: next))
    }
  }
}

/// 応答イベントを全バンカーリレーへ発行する。接続が 1 本も生きていなければ送る
/// 先が無いので、応答を落としたことをログに残す（クライアントは接続が戻った
/// あとの再送で回復する）。
fn publish(state: State, response: Event) -> Nil {
  case dict.is_empty(state.publishers) {
    True -> io.println("[bunker] no live relay connection; response dropped")
    False ->
      dict.each(state.publishers, fn(_relay_url, publish) { publish(response) })
  }
}
