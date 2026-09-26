//// 実行時のリレーの一覧と、それに合わせて用途（監視・バンカー・セッションのリレー）ごとの
//// `factory_supervisor` の子を起動・停止するアクター。
////
//// **接続は用途ごとの factory の子にする。** `static_supervisor` には実行時に
//// 子を足す公開 API が無く、factory（simple_one_for_one）にも子を止める関数は
//// 無いため、止めるのは `nostr_no_su_ffi` の `terminate_dynamic_child/2`
//// （`supervisor:terminate_child/2`）で行う。simple_one_for_one の
//// `terminate_child` は子を止めてから仕様を消すので、止めた接続が再起動される
//// ことはない。
////
//// **一覧はこのアクターが持ち、子の起動と停止をハンドラーで直列に行う。** factory
//// が `rest_for_one` で再起動すると動的な子はすべて消える（simple_one_for_one の
//// 性質）ため、一覧を factory の外に持ち、`Repopulate` で補充する。補充を
//// 子仕様の中で直接行うと、同時に届く `Change` の起動と重なって二重に起動しう
//// るが、1 つのメールボックスで順に処理すれば最後に処理した変更と一覧が一致
//// する（同じ名前の 2 本目の起動は `InitFailed` で失敗するだけ）。
////
//// **既知の窓 1**: 接続がバグで落ちて factory が再起動するまでの間に閉じると、
//// `process.named` が `Error` なので止められず、再起動した接続が一覧から消えた
//// まま残る。落ちる経路はバグに限られるので容認する。
////
//// **既知の窓 2**: このアクター自身が落ちると一覧は空に戻り、
//// 動いている接続とずれる。次にバンカーが読み込みに成功するまで、行は
//// `OpenRegistered` で戻らない。ハンドラーが呼ぶ FFI は落ちる経路（`exit`）を
//// 値にしているため、落ちるのはバグに限られる。セッションのリレーの接続も、次に
//// バンカーのセッションのリレーが変わるまで戻らない。
////
//// **既知の窓 3**: ハンドラーは `terminate_dynamic_child` で、接続の停止のタイム
//// アウト（`factory_supervisor.worker_child` の既定 5000ms）まで待ちうる。変更が
//// 続けて届くと、後ろの問い合わせは `call_timeout_ms` を超えて `NotAnswered` を
//// 返しうるが、`Change` メッセージ自体はメールボックスに残り、後で適用されうる
//// （結果は呼び出し側からは不明）。
////
//// 呼び出し先の factory がまだ登録されていないとき（サブツリーの `rest_for_one`
//// の再起動で factory が止まってから起動し直すまでの間。この間に届いた
//// `Change` で起動できなかった接続は、再起動後の `Repopulate` が起動する。
//// `terminate_dynamic_child` の待ちの最中にサブツリーがさらに factory を止める
//// ときも同様）の `start_dynamic_child` / `terminate_dynamic_child` も同じく
//// FFI で値にする。
////
//// 本体のサブツリーが共有する再起動の許容 `subtree_restart_tolerance` もここに置く。`app` と
//// このモジュールの `connections` の factory の両方が読み、`app` がこのモジュールを import
//// するため（逆向きは循環する）。

import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/relay_client
import nostr_no_su/relay_connection

/// 接続 1 本の識別。名前で接続アクターへ問い合わせたり依頼したりできる。
pub type Connection {
  Connection(name: Name(relay_connection.Msg), url: String)
}

/// 一覧の項目 1 件。用途ごとに `Some` ならその用途で使い、その名前で接続する。
pub type Entry {
  Entry(
    url: String,
    monitor: Option(Name(relay_connection.Msg)),
    bunker: Option(Name(relay_connection.Msg)),
  )
}

/// 開く・用途を変えるときに指定する、リレー 1 件の用途の組。どちらの用途も使わない組は
/// 表せない（一覧から外すのは `close` の役目）。
pub type Roles {
  /// 監視だけに使う。
  MonitorOnly
  /// バンカーだけに使う。
  BunkerOnly
  /// 監視とバンカーの両方に使う。
  Both
}

/// 監視とバンカーの用途を使うかどうかの組を `Roles` にする。どちらも使わないなら `Error(Nil)`。
pub fn roles_from(
  monitor monitor: Bool,
  bunker bunker: Bool,
) -> Result(Roles, Nil) {
  case monitor, bunker {
    True, True -> Ok(Both)
    True, False -> Ok(MonitorOnly)
    False, True -> Ok(BunkerOnly)
    False, False -> Error(Nil)
  }
}

/// `roles` が用途 `role` を含むか。`SessionOnly` は `Roles` の用途ではないので常に `False`。
pub fn has_role(roles: Roles, role: Role) -> Bool {
  case role, roles {
    Monitor, MonitorOnly | Monitor, Both -> True
    Bunker, BunkerOnly | Bunker, Both -> True
    _, _ -> False
  }
}

/// リレーの用途。
pub type Role {
  Monitor
  Bunker
  /// セッションのリレーのうち、バンカーの用途の項目に無い URL の接続。項目
  /// （`Entry`）には載らないので、`connections` と `urls` はこの用途では空を返す。
  SessionOnly
}

/// ストアに登録されたリレー 1 件。DB に依存しないための形。
pub type Registered {
  Registered(url: String, roles: Roles)
}

/// 一覧の変更を拒む理由。
pub type ChangeError {
  /// `relay_client.to_request` が受けない URL（`ws://` か `wss://` で始まらない、
  /// ホストが空、または URL として読めない）。
  InvalidUrl
  /// 同じ URL が既に一覧にある。
  AlreadyListed
  /// 指定した URL が一覧に無い。
  NotListed
  /// このアクターが応答しなかった。変更が適用されたかどうかは分からない
  /// （既知の窓 3）。
  NotAnswered
}

/// 用途ごとの factory の名前の型。
pub type FactoryName =
  Name(factory_supervisor.Message(Connection, Subject(relay_connection.Msg)))

/// 監視用、バンカー用、セッションのリレー用、それぞれの factory の名前。
pub type Factories {
  Factories(monitor: FactoryName, bunker: FactoryName, session: FactoryName)
}

/// このアクターが受け取るメッセージ。
pub type Msg {
  /// 一覧を `apply` で変え、結果を `reply` に送る。`apply` は現在の一覧から
  /// 次の一覧を計算する純粋関数で、検査は `apply` の中で行う。
  Change(
    apply: fn(List(Entry)) -> Result(List(Entry), ChangeError),
    reply: Subject(Result(Nil, ChangeError)),
  )
  /// 現在の一覧を問い合わせる。
  GetEntries(reply: Subject(List(Entry)))
  /// 用途 `role` の factory が（再）起動した。まだ登録されていない接続を
  /// 一覧から起動し直す。
  Repopulate(role: Role)
  /// ストアに登録されたリレーを、一覧に無い URL だけ足す（`open_all`）。バンカーが
  /// 読み込みに成功するたびに送る。
  OpenRegistered(relays: List(Registered))
  /// 用途 `roles` の現在の全接続へ購読の張り直しを依頼する。
  ResubscribeAll(roles: List(Role))
  /// バンカーのセッションのリレーの URL を差し替え、`SessionOnly` の接続を開閉し、
  /// 残った接続の購読を張り直す。バンカーがセッションのリレーの変化のたびに送る。
  SyncSessionRelays(urls: List(String))
}

/// アクターが保持する状態。`session_urls` はバンカーから届いたセッションのリレーの
/// URL、`sessions` はそのうち `SessionOnly` の用途で開いている接続。
type State {
  State(
    entries: List(Entry),
    factories: Factories,
    session_urls: List(String),
    sessions: List(Connection),
  )
}

/// `registered` を順に `open` で一覧の末尾へ足す。すでに一覧にある URL
/// （`AlreadyListed`）は黙って飛ばし、それ以外の拒否は URL と理由の組にして
/// 返す。
pub fn open_all(
  entries: List(Entry),
  registered: List(Registered),
) -> #(List(Entry), List(#(String, ChangeError))) {
  let #(entries, rejections) = {
    use #(entries, rejections), item <- list.fold(registered, #(entries, []))
    case open(entries, item.url, item.roles) {
      Ok(next) -> #(next, rejections)
      Error(AlreadyListed) -> #(entries, rejections)
      Error(error) -> #(entries, [#(item.url, error), ..rejections])
    }
  }
  #(entries, list.reverse(rejections))
}

/// `url` を一覧の末尾に足す。用途ごとに新しい名前を作る。
pub fn open(
  entries: List(Entry),
  url: String,
  roles: Roles,
) -> Result(List(Entry), ChangeError) {
  use Nil <- result.try(check_url(url))
  use Nil <- result.try(check_not_listed(entries, url))
  Ok(
    list.append(entries, [
      Entry(
        url: url,
        monitor: kept_or_new_name(None, has_role(roles, Monitor)),
        bunker: kept_or_new_name(None, has_role(roles, Bunker)),
      ),
    ]),
  )
}

/// `url` を一覧から外す。無ければ `NotListed`。
pub fn close(
  entries: List(Entry),
  url: String,
) -> Result(List(Entry), ChangeError) {
  use Nil <- result.try(check_listed(entries, url))
  Ok(list.filter(entries, fn(entry) { entry.url != url }))
}

/// `url` の項目の位置を保ったまま用途を変える。残る用途は名前を保ち、新たに
/// 得る用途は新しい名前を作り、外す用途は `None` にする。
pub fn change_roles(
  entries: List(Entry),
  url: String,
  roles: Roles,
) -> Result(List(Entry), ChangeError) {
  use Nil <- result.try(check_listed(entries, url))
  Ok(
    list.map(entries, fn(entry) {
      case entry.url == url {
        False -> entry
        True ->
          Entry(
            ..entry,
            monitor: kept_or_new_name(entry.monitor, has_role(roles, Monitor)),
            bunker: kept_or_new_name(entry.bunker, has_role(roles, Bunker)),
          )
      }
    }),
  )
}

/// 指定した用途の接続を、項目の順に並べる。
pub fn connections(entries: List(Entry), role: Role) -> List(Connection) {
  use entry <- list.filter_map(entries)
  case name_for_role(entry, role) {
    Some(name) -> Ok(Connection(name: name, url: entry.url))
    None -> Error(Nil)
  }
}

/// 指定した用途の URL を、項目の順に並べる。
pub fn urls(entries: List(Entry), role: Role) -> List(String) {
  list.map(connections(entries, role), fn(connection) { connection.url })
}

/// `session_urls` のうち、バンカーの用途の項目に無い URL の接続を、重複を除いて
/// `session_urls` の順に並べる。`current` に同じ URL の接続があれば名前を保ち、
/// 無ければ新しい名前を作る。
pub fn session_connections(
  entries: List(Entry),
  session_urls: List(String),
  current: List(Connection),
) -> List(Connection) {
  let base = urls(entries, Bunker)
  session_urls
  |> list.unique
  |> list.filter(fn(url) { !list.contains(base, url) })
  |> list.map(fn(url) {
    case list.find(current, fn(connection) { connection.url == url }) {
      Ok(connection) -> connection
      Error(Nil) -> Connection(name: new_connection_name(), url: url)
    }
  })
}

/// URL が `relay_client.to_request` の受けるリレー URL かを確かめる。
fn check_url(url: String) -> Result(Nil, ChangeError) {
  case relay_client.to_request(url) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error(InvalidUrl)
  }
}

/// `url` がまだ一覧に無いか。
fn check_not_listed(
  entries: List(Entry),
  url: String,
) -> Result(Nil, ChangeError) {
  case is_listed(entries, url) {
    True -> Error(AlreadyListed)
    False -> Ok(Nil)
  }
}

/// `url` が既に一覧にあるか。
fn check_listed(entries: List(Entry), url: String) -> Result(Nil, ChangeError) {
  case is_listed(entries, url) {
    True -> Ok(Nil)
    False -> Error(NotListed)
  }
}

/// 用途を保つなら既存の名前を保ち、新たに得るなら新しい名前を作り、外すなら
/// `None`。
fn kept_or_new_name(
  current: Option(Name(relay_connection.Msg)),
  wanted: Bool,
) -> Option(Name(relay_connection.Msg)) {
  case current, wanted {
    Some(name), True -> Some(name)
    None, True -> Some(new_connection_name())
    _, False -> None
  }
}

/// 接続アクターに付ける新しい名前。
fn new_connection_name() -> Name(relay_connection.Msg) {
  process.new_name("nostr_no_su_relay")
}

/// `url` の項目が一覧にあるか。
fn is_listed(entries: List(Entry), url: String) -> Bool {
  list.any(entries, fn(entry) { entry.url == url })
}

/// 項目のうち、指定した用途で使う名前。
fn name_for_role(
  entry: Entry,
  role: Role,
) -> Option(Name(relay_connection.Msg)) {
  case role {
    Monitor -> entry.monitor
    Bunker -> entry.bunker
    SessionOnly -> None
  }
}

/// 用途に対応する factory の名前。
fn factory_for_role(factories: Factories, role: Role) -> FactoryName {
  case role {
    Monitor -> factories.monitor
    Bunker -> factories.bunker
    SessionOnly -> factories.session
  }
}

/// スーパービジョンツリー用の子仕様。一覧は空で起動する。
pub fn supervised(
  name: Name(Msg),
  factories: Factories,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, [], factories) })
}

/// このアクターを起動する。`name` で登録するため、`open_relay` などの呼び出しは
/// 再起動をまたいで同じ宛先に届く。`initial` は起動時の一覧で、`supervised` は空を渡す。
pub fn start(
  name: Name(Msg),
  initial: List(Entry),
  factories: Factories,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(
    State(
      entries: initial,
      factories: factories,
      session_urls: [],
      sessions: [],
    ),
  )
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// スーパーバイザーが許容する再起動の頻度。`period` 秒の間に `intensity` 回まで。
pub type RestartTolerance {
  RestartTolerance(intensity: Int, period: Int)
}

/// 本体のサブツリー（プラグイン、プラグインの子、監視、バンカー）と、用途ごとの
/// `connections` の factory が共有する再起動の許容。監視とバンカーのサブツリー
/// （`rest_for_one`）では、不正なイベント 1 件で先頭のアクターと後続の接続がまとめて
/// 落ちうるため、多めに取ってある。リレーの停止は接続アクター自身が処理するので、
/// そもそも再起動にはならない。
pub const subtree_restart_tolerance = RestartTolerance(intensity: 5, period: 10)

/// 用途 `role` の接続を factory の子として起動するスーパーバイザーの子仕様。
/// `start` は `Connection` を受け取り接続アクターを起動するテンプレート
/// （`relay_connection.start` を包んだもの）。factory の起動が終わった直後に、
/// `list` へ `Repopulate(role)` を送って現在の一覧から補充させる。
pub fn connections_child(
  list: Name(Msg),
  factories: Factories,
  role: Role,
  start: fn(Connection) -> actor.StartResult(Subject(relay_connection.Msg)),
) -> ChildSpecification(
  factory_supervisor.Supervisor(Connection, Subject(relay_connection.Msg)),
) {
  supervision.supervisor(fn() {
    factory_supervisor.worker_child(start)
    |> factory_supervisor.named(factory_for_role(factories, role))
    |> factory_supervisor.restart_strategy(supervision.Permanent)
    |> factory_supervisor.restart_tolerance(
      intensity: subtree_restart_tolerance.intensity,
      period: subtree_restart_tolerance.period,
    )
    |> factory_supervisor.start
    |> result.map(fn(started) {
      named.send(list, Repopulate(role))
      started
    })
  })
}

/// このアクターが `Change` に応答するまで待つ時間の上限。ハンドラーは用途ごとに
/// `terminate_dynamic_child` で接続の停止のタイムアウト（factory の
/// `worker_child` の既定 5000ms）まで待つことがあり、1 回の変更で 2 用途を
/// 止めうるので、それより十分に長く取る。
const call_timeout_ms = 15_000

/// 一覧を `apply` で変える。応答が無ければ `NotAnswered` にする。`NotAnswered`
/// は結果が不明で、変更は後で適用されうる（既知の窓 3）。
pub fn change(
  name: Name(Msg),
  apply: fn(List(Entry)) -> Result(List(Entry), ChangeError),
) -> Result(Nil, ChangeError) {
  named.call(name, call_timeout_ms, Change(apply, _))
  |> option.unwrap(Error(NotAnswered))
}

/// 現在の一覧。応答が無ければ `Error(Nil)`。
pub fn entries(name: Name(Msg)) -> Result(List(Entry), Nil) {
  named.call(name, call_timeout_ms, GetEntries)
  |> option.to_result(Nil)
}

/// 用途 `roles` の現在の全接続へ購読の張り直しを依頼する。送るだけで待たない。
pub fn resubscribe_all(name: Name(Msg), roles: List(Role)) -> Nil {
  named.send(name, ResubscribeAll(roles))
}

/// ストアに登録されたリレーを一覧へ足す。送るだけで待たない。
pub fn open_registered(name: Name(Msg), relays: List(Registered)) -> Nil {
  named.send(name, OpenRegistered(relays))
}

/// バンカーのセッションのリレーの URL を渡す。送るだけで待たない。
pub fn sync_session_relays(name: Name(Msg), urls: List(String)) -> Nil {
  named.send(name, SyncSessionRelays(urls))
}

/// メッセージの種類ごとに処理する。
fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    Change(apply, reply) -> handle_change(state, apply, reply)
    GetEntries(reply) -> {
      process.send(reply, state.entries)
      actor.continue(state)
    }
    Repopulate(role) -> {
      repopulate(state, role)
      actor.continue(state)
    }
    OpenRegistered(relays) -> {
      let #(next, rejections) = open_all(state.entries, relays)
      list.each(rejections, fn(rejection) {
        let #(url, error) = rejection
        log.write(
          log.Warning,
          log.relay_prefix(url),
          "skipped registered relay: " <> skipped_reason(error),
        )
      })
      actor.continue(apply(state, next, state.session_urls))
    }
    ResubscribeAll(roles) -> {
      list.each(roles, fn(role) {
        list.each(role_connections(state, role), fn(connection) {
          relay_connection.resubscribe(connection.name)
        })
      })
      actor.continue(state)
    }
    SyncSessionRelays(urls) -> {
      let updated = apply(state, state.entries, urls)
      // 前後の両方にある接続は、その URL を持つセッションの署名者が変わりうるので
      // 購読を張り直す。新しく開いた接続は起動時に購読する。
      updated.sessions
      |> list.filter(fn(connection) {
        list.any(state.sessions, fn(kept) { kept.name == connection.name })
      })
      |> list.each(fn(connection) {
        relay_connection.resubscribe(connection.name)
      })
      actor.continue(updated)
    }
  }
}

/// `compute` を現在の一覧に適用し、用途ごとに名前の差分を取って先に止めてから
/// 起動する。同じメールボックスで直列に行うため、最後に処理した変更と一覧が
/// 一致する。
fn handle_change(
  state: State,
  compute: fn(List(Entry)) -> Result(List(Entry), ChangeError),
  reply: Subject(Result(Nil, ChangeError)),
) -> actor.Next(State, Msg) {
  case compute(state.entries) {
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
    Ok(next) -> {
      let updated = apply(state, next, state.session_urls)
      process.send(reply, Ok(Nil))
      actor.continue(updated)
    }
  }
}

/// 一覧を `next`、セッションのリレーを `session_urls` に差し替える。3 つの用途の
/// 名前の差分を取り、止める接続をすべて止めてから起動する（URL が `SessionOnly` と
/// `Bunker` の間を移るとき、先に古い側を止めるため）。
fn apply(state: State, next: List(Entry), session_urls: List(String)) -> State {
  let updated =
    State(
      ..state,
      entries: next,
      session_urls: session_urls,
      sessions: session_connections(next, session_urls, state.sessions),
    )
  let changes =
    list.map([Monitor, Bunker, SessionOnly], fn(role) {
      let before = role_connections(state, role)
      let after = role_connections(updated, role)
      #(role, missing_from(before, after), missing_from(after, before))
    })
  list.each(changes, fn(change) {
    list.each(change.1, stop_connection(state, change.0, _))
  })
  list.each(changes, fn(change) {
    list.each(change.2, start_connection(state, change.0, _))
  })
  updated
}

/// 用途の現在の接続。`SessionOnly` は `state.sessions`、それ以外は項目から。
fn role_connections(state: State, role: Role) -> List(Connection) {
  case role {
    SessionOnly -> state.sessions
    Monitor | Bunker -> connections(state.entries, role)
  }
}

/// 登録されたリレーを飛ばした理由の説明。`open_all` が返す拒否は `InvalidUrl` だけ
/// （`AlreadyListed` は `open_all` の時点で飛ばし、`NotListed` と `NotAnswered` は `open` が
/// 返さない）だが、`ChangeError` を網羅するために残りも扱う。
fn skipped_reason(error: ChangeError) -> String {
  case error {
    InvalidUrl -> "invalid url (use ws:// or wss://)"
    AlreadyListed | NotListed | NotAnswered -> "rejected"
  }
}

/// `xs` のうち、`ys` に同じ名前の接続が無いもの。
fn missing_from(
  xs: List(Connection),
  ys: List(Connection),
) -> List(Connection) {
  list.filter(xs, fn(x) { !list.any(ys, fn(y) { y.name == x.name }) })
}

/// 用途 `role` の接続のうち、まだ登録されていないものを起動する。factory が
/// `rest_for_one` の再起動で子を失ったときの補充と、起動直後の初期一覧の反映を
/// 兼ねる。
fn repopulate(state: State, role: Role) -> Nil {
  role_connections(state, role)
  |> list.filter(fn(connection) { process.named(connection.name) == Error(Nil) })
  |> list.each(start_connection(state, role, _))
}

/// `connection` を用途 `role` の factory の子として起動する。失敗はログに
/// 出すだけで、呼び出し側には返さない（`Change` はすでに一覧を確定させている）。
fn start_connection(state: State, role: Role, connection: Connection) -> Nil {
  case
    start_dynamic_child(factory_for_role(state.factories, role), connection)
  {
    Ok(Nil) -> Nil
    Error(reason) ->
      log.write(
        log.Warning,
        log.relay_prefix(connection.url),
        "could not open connection: " <> reason,
      )
  }
}

/// `connection` を用途 `role` の factory から止める。登録されていなければ何も
/// しない（既知の窓 1）。
fn stop_connection(state: State, role: Role, connection: Connection) -> Nil {
  case process.named(connection.name) {
    Error(Nil) -> Nil
    Ok(pid) ->
      case
        terminate_dynamic_child(factory_for_role(state.factories, role), pid)
      {
        Ok(Nil) -> Nil
        Error(reason) ->
          log.write(
            log.Warning,
            log.relay_prefix(connection.url),
            "could not close connection: " <> reason,
          )
      }
  }
}

/// factory の子を起動する。factory が未登録なら呼び出し側を `exit` させる
/// ため（`supervisor:start_child/2`）、FFI で値に写す。
@external(erlang, "nostr_no_su_ffi", "start_dynamic_child")
fn start_dynamic_child(
  factory: FactoryName,
  connection: Connection,
) -> Result(Nil, String)

/// factory の子を pid で止める（`supervisor:terminate_child/2`）。止めた子は
/// 仕様ごと消えるため再起動されない。factory が未登録なら `start_dynamic_child`
/// と同じく値に写す。
@external(erlang, "nostr_no_su_ffi", "terminate_dynamic_child")
fn terminate_dynamic_child(
  factory: FactoryName,
  pid: Pid,
) -> Result(Nil, String)
