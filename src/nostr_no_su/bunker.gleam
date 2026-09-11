//// 純粋な `engine` を包む薄いアクター。リレーの再接続をまたいでセッション状態を
//// 保持する（リレークライアントは切断のたびに再起動されるため、そこにセッション
//// 状態を置けない）。判断ロジックはすべて `engine` 側に残す。
////
//// アカウントは起動時にストアから読み込む。読み込みは initialiser が自分宛に
//// 積むメッセージ（`LoadAccounts`）で行い、initialiser 自身は DB に触らない。DB が
//// 応答しなくても初期化のタイムアウトに当たらず、サブツリーの起動は失敗しない。
//// 読み込みに失敗したら理由をログに出して再試行を予約するだけで、アクターは
//// 落ちない。
////
//// **読み込みの順序に関する不変条件**：`LoadAccounts` は initialiser が送るので、
//// アクターのメールボックスで必ず最初のメッセージになる。接続は `rest_for_one` で
//// アクターの後に起動するので、接続が購読のために送る `GetSigners` は必ずその後に
//// 処理される。DB が起動時に到達可能なら、どの接続も読み込み済みの署名者で購読
//// する。**`LoadAccounts` の最初の送信を initialiser 以外へ移さないこと。**
////
//// 読み込みの前はエンジンにアカウントが 1 件も無いので、どのリクエストもルーティング
//// で破棄され、リプレイ防止の `seen` への記録も承認待ちもセッションも生じない。
//// そのため、読み込みが成功した時点でエンジンを作り直しても失われる状態は無い。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import nostr_no_su/bunker/engine.{type Pending, type Session}
import nostr_no_su/bunker/vault
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/random
import nostr_no_su/time

/// バンカーが出すログ行の接頭辞。
pub const log_prefix = "bunker"

/// 読み込みに失敗したとき、次に試すまでの既定の待ち時間。
pub const default_retry_delay_ms = 5000

/// 問い合わせの応答を待つ時間。アクターの処理はどれも数ミリ秒で終わるため、
/// これを超えるのはアクターが詰まっているときだけ。アカウントの読み込みは最長で
/// 約 4 秒ループを止めうる（`account_store` のタイムアウト）が、この値に収まる。
const call_timeout_ms = 5000

/// 初期化に許す時間。initialiser は DB に触らないので短くてよい。
const init_timeout_ms = 1000

/// 承認ページの URL に入るトークンのバイト数。承認・拒否そのものは管理 UI の
/// 認証が守るが、トークンは保留の識別子なので、認証を通った管理者が別の要求を
/// 取り違えないよう推測できない長さにする。
const token_bytes = 16

/// バンカーアクターの設定。マスターキーや接続プールは直接持たず、`load` の
/// クロージャーの環境に閉じ込める。アクターの状態を表示してもキーが出ず、テストは
/// DB なしで偽の読み込み関数を渡せる。
pub type Settings {
  Settings(
    /// アカウントを読み込む関数。失敗の理由はログに出すだけなので文字列で返す。
    load: fn() -> Result(vault.Loaded, String),
    /// 承認ページの URL を組み立てる関数。`None` なら承認フローを使わない。
    auth_url: Option(fn(String) -> String),
    /// 読み込みに失敗したとき、次に試すまでの待ち時間。
    retry_delay_ms: Int,
  )
}

/// バンカーアクターが受け取るメッセージ。
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
  /// 1 本のリレー接続の送信手段を取り下げる。接続アクターが `on_disconnect` から
  /// 送るため、死んだソケットへ応答を渡し続けることがない。接続アクター自身が
  /// クラッシュした場合は `on_disconnect` を経ないため、再起動した接続が
  /// `SetPublisher` で上書きするまでは古い送信手段が残る。
  RemovePublisher(relay_url: String)
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
  /// ストアからアカウントを読み込む。initialiser と再試行のタイマーが、アクター
  /// ごとに作る名前なしの subject へ送る。名前付き subject へは誰も送らない。
  LoadAccounts
  /// 現在の署名者 pubkey の一覧を問い合わせる。バンカーリレーの購読が使う。
  GetSigners(reply: Subject(List(String)))
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

/// 現在の署名者 pubkey の一覧。読み込みの前、あるいはアクターが動いていなければ
/// 空。
pub fn signers(name: Name(Msg)) -> List(String) {
  named.call(name, call_timeout_ms, GetSigners)
  |> option.unwrap([])
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

/// アカウントを読み込めているかどうか。
type Accounts {
  /// まだ読み込めていない。`failure` は最後の失敗の理由（まだ失敗していなければ
  /// `None`）。
  Loading(failure: Option(String))
  /// 読み込めた。
  Ready
}

/// バンカーアクターが保持する状態。判断は `engine` が行い、アクターはその状態と、
/// 生きた接続の送信手段と、自分が起動した時刻と、読み込みの進み具合だけを持つ。
/// `not_before` はエンジンではなくここに置く。エンジンは読み込みのたびに作り直す
/// ため、そちらに刻むと起動時刻ではなく読み込みの時刻になってしまう。
type State {
  State(
    engine: engine.Engine,
    publishers: Dict(String, fn(Event) -> Nil),
    not_before: Int,
    settings: Settings,
    /// このアクターのプロセスだけが持つ、読み込み用の名前なしの subject。
    retry: Subject(Msg),
    accounts: Accounts,
  )
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  settings: Settings,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, settings) })
}

/// バンカーアクターを起動する。`name` で登録するため、接続は起動時に生きていた
/// プロセスではなく、現在その名前を保持しているプロセスに到達する。
///
/// スーパーバイザーは再起動のたびにこれを呼ぶため、アクターは承認済みセッション
/// もリプレイ防止の `seen` も引き継がない。記憶していないリクエストを再実行しない
/// よう、ここで起動時刻を刻み、それより古いリクエストはエンジンが受け付けない。
/// アカウントは仕様のスナップショットではなく、起動のたびにストアの最新から読む。
pub fn start(
  name: Name(Msg),
  settings: Settings,
) -> actor.StartResult(Subject(Msg)) {
  actor.new_with_initialiser(init_timeout_ms, fn(self) {
    initialise(settings, self)
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// 読み込みをメッセージとして積み、名前付き subject と読み込み用の subject の
/// 両方を選択する。DB には触らない。
///
/// 読み込みと再試行を名前なしの subject へ送るのは、再起動したアクターに古い
/// タイマーを届けないためである。名前付き subject への `send_after` は名前宛ての
/// タイマーになり、同じ名前で起動し直したアクターに届いて再試行の系列が再起動の
/// たびに増える。名前なしの subject は pid 宛てなので、プロセスが終了すると
/// ランタイムがタイマーを取り消す。
fn initialise(
  settings: Settings,
  self: Subject(Msg),
) -> Result(actor.Initialised(State, Msg, Subject(Msg)), String) {
  let retry = process.new_subject()
  process.send(retry, LoadAccounts)
  // `selecting` を使うと既定の subject は選択されないので、名前付き subject も
  // 明示的に入れる。入れ忘れると問い合わせが届かない。
  let selector =
    process.new_selector()
    |> process.select(self)
    |> process.select(retry)
  State(
    engine: engine.new([], settings.auth_url),
    publishers: dict.new(),
    not_before: time.now_seconds(),
    settings: settings,
    retry: retry,
    accounts: Loading(failure: None),
  )
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

/// アカウントの読み込み、publisher の登録、署名者・セッション・承認待ちの照会、
/// セッションの取り消し、承認待ちの承認と拒否、あるいは受信イベント 1 件をエンジンに
/// 通して生成された応答を全接続へ送信する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    LoadAccounts -> actor.continue(load_accounts(state))
    GetSigners(reply) -> {
      process.send(reply, current_signers(state.engine))
      actor.continue(state)
    }
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
      let next = engine.revoke(state.engine, signer, client)
      process.send(reply, Nil)
      actor.continue(State(..state, engine: next))
    }
    SetPublisher(relay_url, publish) ->
      actor.continue(
        State(
          ..state,
          publishers: dict.insert(state.publishers, relay_url, publish),
        ),
      )
    RemovePublisher(relay_url) ->
      actor.continue(
        State(..state, publishers: dict.delete(state.publishers, relay_url)),
      )
    Incoming(incoming) -> {
      // トークンは受信のたびに引く。使うのは承認待ちを作るときだけだが、そう
      // することでエンジンは乱数を持たずに済む。
      let inputs =
        engine.Inputs(
          now: time.now_seconds(),
          token: random.hex(token_bytes),
          not_before: state.not_before,
        )
      let #(next, outcome) = engine.handle_event(state.engine, incoming, inputs)
      case outcome {
        engine.Reply(response) -> publish(state, response)
        engine.Duplicate -> Nil
        engine.Ignore(reason) -> log.println(log_prefix, "ignored: " <> reason)
      }
      actor.continue(State(..state, engine: next))
    }
  }
}

/// ストアからアカウントを読み込む。成功したらエンジンを作り直し、失敗したら
/// 再試行を予約する。読み込み済みなら何もしない（再試行は失敗したときにしか予約
/// せず、読み込み用の subject はこのプロセスの外に出ないので、通常は起きない）。
fn load_accounts(state: State) -> State {
  case state.accounts {
    Ready -> state
    Loading(failure:) -> {
      let outcome = state.settings.load()
      load_report(failure, outcome, state.settings.retry_delay_ms)
      |> list.each(log.println(log_prefix, _))
      case outcome {
        Ok(loaded) ->
          State(
            ..state,
            engine: engine.new(
              list.map(loaded.accounts, fn(entry) {
                #(entry.account, entry.secret)
              }),
              state.settings.auth_url,
            ),
            accounts: Ready,
          )
        Error(reason) -> {
          let _ =
            process.send_after(
              state.retry,
              state.settings.retry_delay_ms,
              LoadAccounts,
            )
          State(..state, accounts: Loading(failure: Some(reason)))
        }
      }
    }
  }
}

/// 読み込みの結果に対して出すログ行。`previous_failure` は直前の失敗の理由
/// （まだ失敗していなければ `None`）、`retry_delay_ms` は次の再試行までの待ち時間。
///
/// 失敗は始まったときと理由が変わったときだけ報告し、同じ理由の再試行では黙る。
/// 復帰したときは、その旨と、購読が次の再接続まで開かないことを報告する。
pub fn load_report(
  previous_failure: Option(String),
  outcome: Result(vault.Loaded, String),
  retry_delay_ms: Int,
) -> List(String) {
  case outcome, previous_failure {
    Ok(loaded), None -> [loaded_line(loaded), ..skipped_lines(loaded)]
    Ok(loaded), Some(_) -> [
      "account store is back; " <> loaded_line(loaded),
      "bunker relays will subscribe on the next reconnect",
      ..skipped_lines(loaded)
    ]
    Error(reason), Some(previous) if reason == previous -> []
    Error(reason), _ -> [
      "account store unavailable: "
      <> reason
      <> "; retrying every "
      <> int.to_string(retry_delay_ms)
      <> "ms",
    ]
  }
}

/// 読み込みの完了行。飛ばした行があれば全体の件数も添え、全行がマスターキー違いで
/// 飛んだ状況をひと目で分かるようにする。
fn loaded_line(loaded: vault.Loaded) -> String {
  let count = int.to_string(list.length(loaded.accounts))
  case loaded.skipped {
    [] -> "loaded " <> count <> " account(s)"
    skipped ->
      "loaded "
      <> count
      <> " of "
      <> int.to_string(list.length(loaded.accounts) + list.length(skipped))
      <> " account(s)"
  }
}

/// 飛ばした行ごとのログ行。
fn skipped_lines(loaded: vault.Loaded) -> List(String) {
  list.map(loaded.skipped, vault.describe_skipped)
}

/// エンジンが扱っている署名者の pubkey。表示とテストが安定するよう並べる。
fn current_signers(engine: engine.Engine) -> List(String) {
  dict.keys(engine.accounts)
  |> list.sort(string.compare)
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
    True ->
      log.println(log_prefix, "no live relay connection; response dropped")
    False ->
      dict.each(state.publishers, fn(_relay_url, publish) { publish(response) })
  }
}
