//// スーパービジョンツリー。
////
//// ```
//// root (one_for_one)
//// |-- monitor (rest_for_one): 重複排除ディスパッチャー、次にリレーごとの接続
//// |-- bunker  (rest_for_one): バンカーアクター、        次にリレーごとの接続
//// |-- storage (rest_for_one): Postgres の接続プール、   次にロガーアクター
//// `-- admin   (mist)        : 管理 UI の HTTP サーバー
//// ```
////
//// 各サブツリーを `rest_for_one` にしているのは、先頭のアクターが再起動した際に
//// 後続の接続もまとめて落とすため。接続は復帰の過程で購読を張り直し publisher を
//// 登録し直すので、再起動したバンカーが再び生きたソケットに配線される。アクター
//// には名前が付いているため、接続は名前で宛先を指定でき、死んだプロセスの
//// subject を握り続けることがない。保存サブツリーも同じ形で、接続プールが
//// 再起動するとロガーアクターも作り直され、スキーマの確認からやり直す。
////
//// 管理 UI は他のどれにも依存しないのでルート直下に置く。状態は名前付きアクター
//// への問い合わせで読むため、UI が再起動しても、問い合わせ先が再起動しても、
//// 互いの配線をやり直す必要がない。

import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Builder, type Supervisor} as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker
import nostr_no_su/bunker/engine.{type Engine, type Session}
import nostr_no_su/dedup
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugins/postgres_logger
import nostr_no_su/relay_client.{type Subscriptions}
import nostr_no_su/relay_connection.{type Socket, Socket}
import pog

/// リレー接続の開き方。本番では `open_websocket`、テストでは偽ソケットを使い、
/// ネットワークなしでもツリー全体を動かせるようにする。
pub type Open =
  fn(String, Subscriptions, fn(Event) -> Nil) -> Result(Socket, String)

/// リレー接続 1 本ぶんの識別情報。名前を付けておくと、管理 UI が接続アクターに
/// 状態を問い合わせられる。
pub type Relay {
  Relay(name: Name(relay_connection.Msg), url: String)
}

/// 監視サブツリー。プラグインを動かす重複排除ディスパッチャーと、そこへイベントを
/// 流し込むリレー群からなる。
pub type Monitor {
  Monitor(
    name: Name(dedup.Msg),
    plugins: List(Plugin),
    dedup_capacity: Int,
    relays: List(Relay),
    subscriptions: Subscriptions,
  )
}

/// バンカーサブツリー。NIP-46 アクターと、それが待ち受け・応答するリレー群。
pub type Bunker {
  Bunker(
    name: Name(bunker.Msg),
    engine: Engine,
    relays: List(Relay),
    subscriptions: Subscriptions,
  )
}

/// 管理 UI。設定から決まるもの（ポート、パスワード、認証済みページにだけ出す
/// 接続 URI）だけを持ち、表示するその他の状態はツリーの他の仕様から導く。
pub type Admin {
  Admin(port: Int, password: String, accounts: List(dashboard.Account))
}

/// イベント保存サブツリー。Postgres の接続プールと、そこへ書き込むロガー
/// アクターからなる。監視サブツリーとは別にしているのは、DB が落ちて再起動が
/// 起きてもリレーの購読を巻き込まないため。
pub type Storage {
  Storage(name: Name(postgres_logger.Msg), pool_config: pog.Config)
}

/// 監視・バンカー・イベント保存・管理 UI のどれを動かすか、接続をどう開くか、
/// 接続が再接続までどれだけ待つか。
pub type Spec {
  Spec(
    monitor: Option(Monitor),
    bunker: Option(Bunker),
    storage: Option(Storage),
    admin: Option(Admin),
    open: Open,
    reconnect_delay_ms: Int,
  )
}

/// ツリーを起動する。子は互いに独立しているためルートは `one_for_one`。
/// バンカーや DB が壊れても監視を止めてはならず、その逆も同様。
pub fn start(spec: Spec) -> actor.StartResult(Supervisor) {
  supervisor.new(supervisor.OneForOne)
  // サブツリーより意図的に厳しく、期間も長く取る。再起動を諦め続けるサブツリー
  // は復旧不能とみなし、ここでループせず終了することで再起動をコンテナーの
  // 再起動ポリシーに委ねる。
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  |> add_child(spec.monitor, fn(config) {
    supervisor.supervised(monitor_tree(spec, config))
  })
  |> add_child(spec.bunker, fn(config) {
    supervisor.supervised(bunker_tree(spec, config))
  })
  |> add_child(spec.storage, fn(config) {
    supervisor.supervised(storage_tree(config))
  })
  |> add_child(spec.admin, fn(config) { admin_child(spec, config) })
  |> supervisor.start
}

/// リレーへの実際の WebSocket 接続を開き、接続アクターが監視と送信に使う
/// ソケットとして表現する。
pub fn open_websocket(
  url: String,
  subscriptions: Subscriptions,
  handle_event: fn(Event) -> Nil,
) -> Result(Socket, String) {
  use connection <- result.try(relay_client.start(
    url,
    subscriptions,
    handle_event,
  ))
  // 接続の subject は名前付きではないため、必ず所有プロセスが存在する。
  let assert Ok(pid) = process.subject_owner(connection)
  Ok(Socket(pid: pid, publish: relay_client.publish(connection, _)))
}

/// アプリのその部分が設定されている場合にルートの子を追加する。
fn add_child(
  builder: Builder,
  configured: Option(config),
  child: fn(config) -> ChildSpecification(Supervisor),
) -> Builder {
  case configured {
    None -> builder
    Some(config) -> supervisor.add(builder, child(config))
  }
}

/// 監視サブツリー。ディスパッチャーと、そこへイベントを流し込む接続群。
fn monitor_tree(spec: Spec, config: Monitor) -> Builder {
  subtree()
  |> supervisor.add(dedup.supervised(
    config.name,
    config.plugins,
    config.dedup_capacity,
  ))
  |> add_connections(
    spec,
    config.relays,
    config.subscriptions,
    fn(incoming) { named.send(config.name, dedup.Incoming(incoming)) },
    fn(_relay_url, _socket) { Nil },
  )
}

/// バンカーサブツリー。アクターと、それが応答に使う接続群。各接続はアクターに
/// publisher を登録するため、アクターと一緒に再起動する必要がある。
fn bunker_tree(spec: Spec, config: Bunker) -> Builder {
  subtree()
  |> supervisor.add(bunker.supervised(config.name, config.engine))
  |> add_connections(
    spec,
    config.relays,
    config.subscriptions,
    fn(incoming) { named.send(config.name, bunker.Incoming(incoming)) },
    fn(relay_url, socket: Socket) {
      named.send(config.name, bunker.SetPublisher(relay_url, socket.publish))
    },
  )
}

/// 管理 UI。表示する状態は、ツリーの他の仕様から名前を引いて問い合わせる関数
/// として Context に渡す。
fn admin_child(spec: Spec, config: Admin) -> ChildSpecification(Supervisor) {
  admin.supervised(
    config.port,
    admin.Context(
      password: config.password,
      accounts: config.accounts,
      plugins: plugin_names(spec.monitor),
      storage_enabled: option.is_some(spec.storage),
      relays: fn() { relay_statuses(spec) },
      sessions: fn() { bunker_sessions(spec.bunker) },
      revoke: fn(signer, client) { revoke_session(spec.bunker, signer, client) },
    ),
  )
}

/// 監視サブツリーで有効なプラグインの名前。監視が無効なら空。
fn plugin_names(monitor: Option(Monitor)) -> List(String) {
  case monitor {
    None -> []
    Some(monitor) -> list.map(monitor.plugins, fn(item) { item.name })
  }
}

/// 監視・バンカー両サブツリーのリレー接続の現在の状態。
fn relay_statuses(spec: Spec) -> List(dashboard.Relay) {
  let monitor = case spec.monitor {
    None -> []
    Some(monitor) -> statuses(dashboard.Monitor, monitor.relays)
  }
  let bunker = case spec.bunker {
    None -> []
    Some(bunker) -> statuses(dashboard.Bunker, bunker.relays)
  }
  list.append(monitor, bunker)
}

/// 指定した用途のリレーそれぞれについて、接続アクターに状態を問い合わせる。
fn statuses(
  role: dashboard.Role,
  relays: List(Relay),
) -> List(dashboard.Relay) {
  use relay <- list.map(relays)
  dashboard.Relay(
    role: role,
    url: relay.url,
    status: relay_connection.status(relay.name),
  )
}

/// バンカーが保持する承認済みセッション。バンカーが無効なら空。
fn bunker_sessions(config: Option(Bunker)) -> List(Session) {
  case config {
    None -> []
    Some(config) -> bunker.sessions(config.name)
  }
}

/// セッションを 1 件取り消す。バンカーが無効なら何もしない。
fn revoke_session(
  config: Option(Bunker),
  signer: String,
  client: String,
) -> Nil {
  case config {
    None -> Nil
    Some(config) -> bunker.revoke(config.name, signer, client)
  }
}

/// イベント保存サブツリー。プールを先に起動し、ロガーアクターがその名前を宛先に
/// する。プールが再起動するとロガーも再起動し、スキーマの確認からやり直す。
fn storage_tree(config: Storage) -> Builder {
  subtree()
  |> supervisor.add(pog.supervised(config.pool_config))
  |> supervisor.add(postgres_logger.supervised(
    config.name,
    config.pool_config.pool_name,
  ))
}

/// サブツリーのスーパーバイザー。不正なイベント 1 件で先頭のアクターと後続の
/// 接続がまとめて落ちうるため、許容する再起動の頻度は多めに取ってある。リレーの
/// 停止は接続アクター自身が処理するので、そもそも再起動にはならない。
fn subtree() -> Builder {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 10)
}

/// リレーごとにスーパーバイザー配下の接続を 1 つ追加する。購読とハンドラーは
/// サブツリー内で共有する。
fn add_connections(
  builder: Builder,
  spec: Spec,
  relays: List(Relay),
  subscriptions: Subscriptions,
  handle_event: fn(Event) -> Nil,
  on_connect: fn(String, Socket) -> Nil,
) -> Builder {
  use builder, relay <- list.fold(relays, builder)
  supervisor.add(
    builder,
    relay_connection.supervised(relay_connection.Config(
      name: relay.name,
      relay: relay_client.label(relay.url),
      connect: fn() { spec.open(relay.url, subscriptions, handle_event) },
      on_connect: on_connect(relay.url, _),
      reconnect_delay_ms: spec.reconnect_delay_ms,
    )),
  )
}
