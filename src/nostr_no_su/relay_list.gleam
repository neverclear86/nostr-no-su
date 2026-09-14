//// 実行時のリレーの一覧と、それに合わせて用途（監視・バンカー）ごとの
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
//// **既知の窓 2**: このアクター自身が落ちると一覧は起動時の値に戻り、動いて
//// いる接続とずれる。ハンドラーが呼ぶ FFI は落ちる経路（`exit`）を値にしている
//// ため、落ちるのはバグに限られる。一覧の出どころは #231 で DB に移る。
////
//// **既知の窓 3**: ハンドラーは `terminate_dynamic_child` で、接続の停止のタイム
//// アウト（`factory_supervisor.worker_child` の既定 5000ms）まで待ちうる。変更が
//// 続けて届くと、後ろの問い合わせは `call_timeout_ms` を超えて `NotAnswered` を
//// 返しうるが、`Change` メッセージ自体はメールボックスに残り、後で適用されうる
//// （結果は呼び出し側からは不明）。
////
//// 呼び出し先の factory がまだ登録されていないとき（起動直後で `Repopulate` が
//// まだ届いていない、`root` の先頭に置く前提が崩れたとき）の `start_dynamic_child`
//// / `terminate_dynamic_child` も同じく FFI で値にする。

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

/// 開く・用途を変えるときに指定する、リレー 1 件の用途の組。
pub type Roles {
  Roles(monitor: Bool, bunker: Bool)
}

/// リレーの用途。
pub type Role {
  Monitor
  Bunker
}

/// 一覧の変更を拒む理由。
pub type ChangeError {
  /// `relay_client.to_request` で解釈できない URL。
  InvalidUrl
  /// 同じ URL が既に一覧にある。
  AlreadyListed
  /// 指定した URL が一覧に無い。
  NotListed
  /// 用途が監視・バンカーのどちらも偽。閉じるのは `close` の役目。
  NoRole
  /// このアクターが応答しなかった。変更が適用されたかどうかは分からない
  /// （既知の窓 3）。
  NotAnswered
}

/// 用途ごとの factory の名前の型。
pub type FactoryName =
  Name(factory_supervisor.Message(Connection, Subject(relay_connection.Msg)))

/// 監視用とバンカー用、それぞれの factory の名前。
pub type Factories {
  Factories(monitor: FactoryName, bunker: FactoryName)
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
  /// 全接続（両用途）へ購読の張り直しを依頼する。
  ResubscribeAll
}

/// アクターが保持する状態。
type State {
  State(entries: List(Entry), factories: Factories)
}

/// 起動時の一覧を、監視の一覧を先に、その後にバンカーの一覧のうち未出の URL を
/// 並べて作る。両方にある URL は 1 項目にまとめ、バンカーの名前を足す。
pub fn initial(
  monitor: List(Connection),
  bunker: List(Connection),
) -> List(Entry) {
  let from_monitor =
    list.map(monitor, fn(connection) {
      Entry(url: connection.url, monitor: Some(connection.name), bunker: None)
    })
  use entries, connection <- list.fold(bunker, from_monitor)
  case list.any(entries, fn(entry) { entry.url == connection.url }) {
    True ->
      list.map(entries, fn(entry) {
        case entry.url == connection.url {
          True -> Entry(..entry, bunker: Some(connection.name))
          False -> entry
        }
      })
    False ->
      list.append(entries, [
        Entry(url: connection.url, monitor: None, bunker: Some(connection.name)),
      ])
  }
}

/// `url` を一覧の末尾に足す。用途ごとに新しい名前を作る。
pub fn open(
  entries: List(Entry),
  url: String,
  roles: Roles,
) -> Result(List(Entry), ChangeError) {
  use Nil <- result.try(check_url(url))
  use Nil <- result.try(check_roles(roles))
  use Nil <- result.try(check_not_listed(entries, url))
  Ok(
    list.append(entries, [
      Entry(
        url: url,
        monitor: wanted_name(roles.monitor),
        bunker: wanted_name(roles.bunker),
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
  use Nil <- result.try(check_roles(roles))
  use Nil <- result.try(check_listed(entries, url))
  Ok(
    list.map(entries, fn(entry) {
      case entry.url == url {
        False -> entry
        True ->
          Entry(
            ..entry,
            monitor: kept_or_new_name(entry.monitor, roles.monitor),
            bunker: kept_or_new_name(entry.bunker, roles.bunker),
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

/// URL の形を `relay_client.to_request` と同じ判定で確かめる。
fn check_url(url: String) -> Result(Nil, ChangeError) {
  case relay_client.to_request(url) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error(InvalidUrl)
  }
}

/// 用途が最低 1 つ立っているか。
fn check_roles(roles: Roles) -> Result(Nil, ChangeError) {
  case roles.monitor || roles.bunker {
    True -> Ok(Nil)
    False -> Error(NoRole)
  }
}

/// `url` がまだ一覧に無いか。
fn check_not_listed(
  entries: List(Entry),
  url: String,
) -> Result(Nil, ChangeError) {
  case list.any(entries, fn(entry) { entry.url == url }) {
    True -> Error(AlreadyListed)
    False -> Ok(Nil)
  }
}

/// `url` が既に一覧にあるか。
fn check_listed(entries: List(Entry), url: String) -> Result(Nil, ChangeError) {
  case list.any(entries, fn(entry) { entry.url == url }) {
    True -> Ok(Nil)
    False -> Error(NotListed)
  }
}

/// その用途を望むなら新しい接続名を作り、望まないなら `None`。
fn wanted_name(wanted: Bool) -> Option(Name(relay_connection.Msg)) {
  case wanted {
    True -> Some(process.new_name("nostr_no_su_relay"))
    False -> None
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
    None, True -> Some(process.new_name("nostr_no_su_relay"))
    _, False -> None
  }
}

/// 項目のうち、指定した用途で使う名前。
fn name_for_role(
  entry: Entry,
  role: Role,
) -> Option(Name(relay_connection.Msg)) {
  case role {
    Monitor -> entry.monitor
    Bunker -> entry.bunker
  }
}

/// 用途に対応する factory の名前。
fn factory_for_role(factories: Factories, role: Role) -> FactoryName {
  case role {
    Monitor -> factories.monitor
    Bunker -> factories.bunker
  }
}

/// スーパービジョンツリー用の子仕様。
pub fn supervised(
  name: Name(Msg),
  initial: List(Entry),
  factories: Factories,
) -> ChildSpecification(Subject(Msg)) {
  supervision.worker(fn() { start(name, initial, factories) })
}

/// このアクターを起動する。`name` で登録するため、`open_relay` などの呼び出しは
/// 再起動をまたいで同じ宛先に届く。
pub fn start(
  name: Name(Msg),
  initial: List(Entry),
  factories: Factories,
) -> actor.StartResult(Subject(Msg)) {
  actor.new(State(entries: initial, factories: factories))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

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
    |> factory_supervisor.restart_tolerance(intensity: 5, period: 10)
    |> factory_supervisor.start
    |> result.map(fn(started) {
      named.send(list, Repopulate(role))
      started
    })
  })
}

/// このアクターが `Change` に応答するまで待つ時間の上限。ハンドラーは用途ごとに
/// `terminate_dynamic_child` で接続の停止のタイムアウト（factory の
/// `worker_child` の既定 5000ms）まで待ちうり、1 回の変更で 2 用途を止めうる
/// ので、それより十分に長く取る。
pub const call_timeout_ms = 15_000

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

/// 現在の全接続へ購読の張り直しを依頼する。送るだけで待たない。
pub fn resubscribe_all(name: Name(Msg)) -> Nil {
  named.send(name, ResubscribeAll)
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
    ResubscribeAll -> {
      list.each([Monitor, Bunker], fn(role) {
        list.each(connections(state.entries, role), fn(connection) {
          relay_connection.resubscribe(connection.name)
        })
      })
      actor.continue(state)
    }
  }
}

/// `apply` を現在の一覧に適用し、用途ごとに名前の差分を取って先に止めてから
/// 起動する。同じメールボックスで直列に行うため、最後に処理した変更と一覧が
/// 一致する。
fn handle_change(
  state: State,
  apply: fn(List(Entry)) -> Result(List(Entry), ChangeError),
  reply: Subject(Result(Nil, ChangeError)),
) -> actor.Next(State, Msg) {
  case apply(state.entries) {
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
    Ok(next) -> {
      list.each([Monitor, Bunker], fn(role) {
        let before = connections(state.entries, role)
        let after = connections(next, role)
        list.each(missing_from(before, after), stop_connection(state, role, _))
        list.each(missing_from(after, before), start_connection(state, role, _))
      })
      process.send(reply, Ok(Nil))
      actor.continue(State(..state, entries: next))
    }
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
  connections(state.entries, role)
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
        log.relay_prefix(relay_client.label(connection.url)),
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
            log.relay_prefix(relay_client.label(connection.url)),
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
