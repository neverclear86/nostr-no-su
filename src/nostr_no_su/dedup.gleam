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
////
//// 監視の購読で届き、監視のハンドラーの照合を通ったイベントがすべて通る
//// アクターなので、購読の再開点（`dedup/resume`）もここで記録する。照合で
//// 落としたイベントは再開点を動かさない。監視の接続は購読を組み立てるたびに
//// 再開点を問い合わせ、`dedup/resume_saver` は周期ごとに写しを取って DB に
//// 保存する。再起動したディスパッチャーは記録を失い、次の購読は DB の再開点
//// から始まる。
////
//// プラグインの取り直しの購読のイベントはここを通らず、`app.monitor_handler`
//// から対象のランナーへ直接渡る（監視の再開点を動かしてはならず、大域の
//// ウィンドウで弾いてもならないため）。
////
//// 監視のハンドラーが落としたイベント（購読していない id のものと、登録していない
//// 作者のもの）も、リレーごとにここで数える。件数が 1、10、100 と桁を上げるたびに
//// Warning の行を出し（`record_rejection`）、1 件ごとには出さない。取り直しの
//// 購読で落としたものも数える。件数はディスパッチャーの再起動で 0 に戻る。

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import nostr_no_su/dedup/resume.{type Resume}
import nostr_no_su/dedup/window.{type Window}
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/relay_client
import nostr_no_su/time

/// 再開点の問い合わせを待つ時間。処理は IO を含まないが、積まれた `Incoming` の
/// 後に処理されるので、起動直後の流入のさなかは超えうる。超えたとき、購読の評価は
/// 定義を得られなかったことになり、`relay_client` の再試行を待つ。
const call_timeout_ms = 1000

/// ディスパッチャーが受け取るメッセージ。
pub type Msg {
  /// リレー `relay_url` から受信したイベント。
  Incoming(relay_url: String, event: Event)
  /// これからアカウントを追加することの知らせ。現在時刻と、その時点の監視
  /// リレーの URL を伴う（呼び出し側の `relay_list` から渡る。`dedup` は
  /// 一覧の出どころを知らない）。
  AddingAccount(at: Int, relay_urls: List(String))
  /// リレー `relay_url` のメモリ上の再開点の問い合わせ。
  GetSince(relay_url: String, reply: Subject(Option(Int)))
  /// 保存のための再開点の写しの問い合わせ。
  GetPoints(reply: Subject(Dict(String, Int)))
  /// 監視のハンドラーが、リレー `relay_url` から届いたイベントを、購読していない
  /// id か登録していない作者のものとして落とした知らせ。
  Rejected(relay_url: String)
}

/// ディスパッチャーが保持する状態。`targets` は配送先の状態で、`deliver` が
/// イベントごとに更新する。
type State(targets) {
  State(
    targets: targets,
    deliver: fn(targets, Event) -> targets,
    window: Window,
    resume: Resume,
    /// リレーごとの、落としたイベントの件数。
    rejected: Dict(String, Int),
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
    resume: resume.new(),
    rejected: dict.new(),
  ))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// リレーのメモリ上の再開点。ディスパッチャーが応答しなければ `Error(Nil)` を返し、
/// 再開点が無いこと（`Ok(None)`）と区別する。
pub fn since(name: Name(Msg), relay_url: String) -> Result(Option(Int), Nil) {
  named.call(name, call_timeout_ms, GetSince(relay_url, _))
  |> option.to_result(Nil)
}

/// これからアカウントを追加することを、現在時刻とその時点の監視リレーの URL
/// とともに知らせる。ディスパッチャーが動いていなければ何もしない。
pub fn adding_account(name: Name(Msg), relay_urls: List(String)) -> Nil {
  named.send(name, AddingAccount(time.now_seconds(), relay_urls))
}

/// 保存のための再開点の写し。応答が無ければ `Error(Nil)`。
pub fn points(name: Name(Msg)) -> Result(Dict(String, Int), Nil) {
  named.call(name, call_timeout_ms, GetPoints)
  |> option.to_result(Nil)
}

/// メッセージの種類ごとに処理する。
fn handle(state: State(targets), msg: Msg) -> actor.Next(State(targets), Msg) {
  case msg {
    Incoming(relay_url, incoming) ->
      actor.continue(receive(state, relay_url, incoming))
    AddingAccount(at, relay_urls) ->
      actor.continue(
        State(
          ..state,
          resume: resume.adding_account(state.resume, relay_urls, at),
        ),
      )
    GetSince(relay_url, reply) -> {
      process.send(reply, resume.since(state.resume, relay_url))
      actor.continue(state)
    }
    GetPoints(reply) -> {
      process.send(reply, resume.points(state.resume))
      actor.continue(state)
    }
    Rejected(relay_url) -> {
      let #(rejected, line) = record_rejection(state.rejected, relay_url)
      case line {
        Some(text) ->
          log.write(
            log.Warning,
            log.relay_prefix(relay_client.label(relay_url)),
            text,
          )
        None -> Nil
      }
      actor.continue(State(..state, rejected: rejected))
    }
  }
}

/// ウィンドウがまだ見ていないイベントを `deliver` へ渡し、それ以外は破棄する。
/// 受け取った時点で再開点も記録する。
fn receive(
  state: State(targets),
  relay_url: String,
  incoming: Event,
) -> State(targets) {
  let resume =
    resume.observe(
      state.resume,
      relay_url,
      incoming.created_at,
      time.now_seconds(),
    )
  case window.insert(state.window, incoming.id) {
    Error(Nil) -> State(..state, resume: resume)
    Ok(next) ->
      State(
        ..state,
        targets: state.deliver(state.targets, incoming),
        window: next,
        resume: resume,
      )
  }
}

/// リレー `relay_url` の落とした件数を 1 つ増やした一覧と、そのとき出すログ行の
/// 本文を返す。本文は増やした後の件数が 1、10、100 のような 10 の冪のときだけ
/// `Some` で、それ以外は `None`（1 件ごとには出さない）。件数はリレーごとに独立に
/// 数える。テストが直接呼べるよう公開する。
pub fn record_rejection(
  rejected: Dict(String, Int),
  relay_url: String,
) -> #(Dict(String, Int), Option(String)) {
  let count = case dict.get(rejected, relay_url) {
    Ok(existing) -> existing + 1
    Error(Nil) -> 1
  }
  #(dict.insert(rejected, relay_url, count), rejection_report(count))
}

/// 落とした件数が `count` になったときに出すログ行の本文。`count` が 10 の冪の
/// ときだけ `Some` を返す。
fn rejection_report(count: Int) -> Option(String) {
  case is_power_of_ten(count) {
    True ->
      Some(
        "dropped events outside the monitor subscriptions: "
        <> int.to_string(count)
        <> " so far",
      )
    False -> None
  }
}

/// `count` が 10 の冪（1 を含む）か。
fn is_power_of_ten(count: Int) -> Bool {
  case count {
    1 -> True
    _ if count > 1 && count % 10 == 0 -> is_power_of_ten(count / 10)
    _ -> False
  }
}
