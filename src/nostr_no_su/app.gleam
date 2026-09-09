//// スーパービジョンツリー。
////
//// ```
//// root (one_for_one)
//// |-- monitor (rest_for_one): 重複排除ディスパッチャー、次にリレーごとの接続
//// |-- bunker  (rest_for_one): バンカーアクター、        次にリレーごとの接続
//// `-- storage (rest_for_one): Postgres の接続プール、   次にロガーアクター
//// ```
////
//// 各サブツリーを `rest_for_one` にしているのは、先頭のアクターが再起動した際に
//// 後続の接続もまとめて落とすため。接続は復帰の過程で購読を張り直し publisher を
//// 登録し直すので、再起動したバンカーが再び生きたソケットに配線される。アクター
//// には名前が付いているため、接続は名前で宛先を指定でき、死んだプロセスの
//// subject を握り続けることがない。保存サブツリーも同じ形で、接続プールが
//// 再起動するとロガーアクターも作り直され、スキーマの確認からやり直す。

import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Builder} as supervisor
import gleam/result
import nostr_no_su/bunker
import nostr_no_su/bunker/engine.{type Engine}
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

/// 監視サブツリー。プラグインを動かす重複排除ディスパッチャーと、そこへイベントを
/// 流し込むリレー群からなる。
pub type Monitor {
  Monitor(
    name: Name(dedup.Msg),
    plugins: List(Plugin),
    dedup_capacity: Int,
    relay_urls: List(String),
    subscriptions: Subscriptions,
  )
}

/// バンカーサブツリー。NIP-46 アクターと、それが待ち受け・応答するリレー群。
pub type Bunker {
  Bunker(
    name: Name(bunker.Msg),
    engine: Engine,
    relay_urls: List(String),
    subscriptions: Subscriptions,
  )
}

/// イベント保存サブツリー。Postgres の接続プールと、そこへ書き込むロガー
/// アクターからなる。監視サブツリーとは別にしているのは、DB が落ちて再起動が
/// 起きてもリレーの購読を巻き込まないため。
pub type Storage {
  Storage(name: Name(postgres_logger.Msg), pool_config: pog.Config)
}

/// 監視・バンカー・イベント保存のどれを動かすか、接続をどう開くか、接続が
/// 再接続までどれだけ待つか。
pub type Spec {
  Spec(
    monitor: Option(Monitor),
    bunker: Option(Bunker),
    storage: Option(Storage),
    open: Open,
    reconnect_delay_ms: Int,
  )
}

/// ツリーを起動する。サブツリーは互いに独立しているためルートは `one_for_one`。
/// バンカーや DB が壊れても監視を止めてはならず、その逆も同様。
pub fn start(spec: Spec) -> actor.StartResult(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  // サブツリーより意図的に厳しく、期間も長く取る。再起動を諦め続けるサブツリー
  // は復旧不能とみなし、ここでループせず終了することで再起動をコンテナーの
  // 再起動ポリシーに委ねる。
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  |> add_subtree(spec.monitor, fn(config) { monitor_tree(spec, config) })
  |> add_subtree(spec.bunker, fn(config) { bunker_tree(spec, config) })
  |> add_subtree(spec.storage, storage_tree)
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

/// アプリのその半分が設定されている場合にサブツリーのスーパーバイザーを追加する。
fn add_subtree(
  builder: Builder,
  configured: Option(config),
  tree: fn(config) -> Builder,
) -> Builder {
  case configured {
    None -> builder
    Some(config) -> supervisor.add(builder, supervisor.supervised(tree(config)))
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
    config.relay_urls,
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
    config.relay_urls,
    config.subscriptions,
    fn(incoming) { named.send(config.name, bunker.Incoming(incoming)) },
    fn(relay_url, socket: Socket) {
      named.send(config.name, bunker.SetPublisher(relay_url, socket.publish))
    },
  )
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

/// リレー URL ごとにスーパーバイザー配下の接続を 1 つ追加する。購読とハンドラー
/// はサブツリー内で共有する。
fn add_connections(
  builder: Builder,
  spec: Spec,
  relay_urls: List(String),
  subscriptions: Subscriptions,
  handle_event: fn(Event) -> Nil,
  on_connect: fn(String, Socket) -> Nil,
) -> Builder {
  use builder, relay_url <- list.fold(relay_urls, builder)
  supervisor.add(
    builder,
    relay_connection.supervised(relay_connection.Config(
      relay: relay_client.label(relay_url),
      connect: fn() { spec.open(relay_url, subscriptions, handle_event) },
      on_connect: on_connect(relay_url, _),
      reconnect_delay_ms: spec.reconnect_delay_ms,
    )),
  )
}
