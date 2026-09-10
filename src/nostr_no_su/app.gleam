//// スーパービジョンツリー。
////
//// ```
//// root (one_for_one)
//// |-- plugins      (one_for_one): プラグインごとのランナー
//// |   |-- children(<plugin>) (one_for_one / Temporary): 子仕様を持つプラグインだけ
//// |   `-- runner(<plugin>)   (worker  / Permanent)
//// |-- monitor      (rest_for_one): 重複排除ディスパッチャー、次にリレーごとの接続
//// |-- bunker       (rest_for_one): バンカーアクター、        次にリレーごとの接続
//// |-- event_logger (rest_for_one): Postgres の接続プール、   次にロガーアクター
//// `-- admin        (mist)        : 管理 UI の HTTP サーバー
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
////
//// プラグインのランナーは監視サブツリーの中ではなくルート直下に置く。監視が
//// 無効な構成でも、読み込んだプラグインをツリーに載せて管理 UI に状態を見せ
//// られるようにするためで、ディスパッチャーが再起動してもランナーは巻き添えに
//// ならない。プラグイン同士は独立なのでこのサブツリーは `one_for_one` にする。
//// **ルートの子は `plugins` を `monitor` より先に追加すること。** 逆順だと
//// ディスパッチャーが未登録のランナー名へ送り、起動直後のイベントを取りこぼす。
////
//// このサブツリーの `restart_tolerance` は安全網であって、設計の拠りどころでは
//// ない。プラグインの例外・異常終了・ハングはランナーの中で完結して**プロセスの
//// 死にならない**（`plugin_runner` を参照）ため、プラグインの不調では再起動が
//// 起きず、ルートの `restart_tolerance(3, 60)` に到達しようがない。毎イベントで
//// クラッシュするプラグインに対して有限の再起動許容回数は原理的に成立しないため、
//// この構造で保証している。
////
//// **プラグインが申告した子プロセス**（任意エクスポート `plugin_children/0`）は
//// 普通にクラッシュループしうるため、ランナーと同じ扱いでは上の主張が崩れる。
//// 歯止めは段を増やすことではなく**再起動の型**で作る。プラグイン 1 つぶんの子を
//// 専用のスーパーバイザーにまとめ、その子仕様を **`Temporary`** にする。
////
//// - **段を挟むだけでは足りない。** クラッシュループはどの階層の有限な
////   `intensity` も必ず超えるので、段を増やしても親に到達するまでの時間が
////   延びるだけである。
//// - 子スーパーバイザーが自分の許容回数を超えると、**理由 `shutdown`** で終了
////   する。親でこれが当たるのは理由ベースの `do_restart(shutdown, ...)`
////   （stdlib-8.0.1 / OTP 29.0.2、`supervisor.erl:1432-1434`）で、この節は
////   `del_child/2` を呼んで終わり **`add_restart/1`（:2260-2281）を通らない**。
////   ゆえに親の許容回数は消費されない。**これは Temporary でも Transient でも
////   同じ**である。
//// - **Temporary を選ぶ理由は 2 つ。** (a) `del_child/2`（:1825-1836）が子の仕様
////   ごと削除するのは `temporary` のときだけで、Transient は `pid = undefined` の
////   まま `which_children` に残り続ける。(b) 許容回数超過**以外**の理由（外からの
////   `exit(Pid, kill)` など）で子スーパーバイザーが落ちたとき、Transient は再起動
////   され、その再起動が `add_restart/1` を通って親の許容回数を消費する。ループ
////   すれば親を道連れにする。**Temporary にはこの経路が無い。**
//// - **捨てたもの**: Transient なら仕様が `pid=undefined` で残るため、将来
////   `supervisor:restart_child/2` の FFI を足せば実行時に子を復帰させる道が残る。
////   Temporary はその道を捨てて (b) の耐性を買っている。
//// - **代償**: 一度あきらめた子は仕様ごと消えるため、**ランナーを kill しても子は
////   戻らない**。復帰は本体の再起動のみである（`static_supervisor` には
////   `start_child` 相当の公開 API が無く、`Supervisor` も opaque）。子を失った
////   プラグインはランナーが生き続け、`handle_event/1` の連続失敗で
////   `disabled: <理由>` になってダッシュボードに残る。**素直に劣化する。**
//// - **起動時の失敗はアプリを止めない。** `Temporary` が効くのは再起動のときだけ
////   なので、初回起動の失敗は空のスーパーバイザーで吸収する
////   （`start_plugin_children`）。失敗の理由は `plugin_children` が子ごとに出す
////   1 行に出る。

import gleam/erlang/process.{type Name, type Pid}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Builder, type Supervisor} as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/bunker
import nostr_no_su/bunker/engine.{type Engine, type Pending}
import nostr_no_su/dedup
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugin_runner
import nostr_no_su/plugins/event_logger
import nostr_no_su/relay_client.{type Subscriptions}
import nostr_no_su/relay_connection.{type Socket, Socket}
import nostr_no_su/time
import pog

/// バンカーが無効なときの、承認・拒否の結果。
const disabled: Result(Nil, String) = Error("bunker is disabled")

/// リレー接続の開き方。本番では `open_websocket`、テストでは偽ソケットを使い、
/// ネットワークなしでもツリー全体を動かせるようにする。
pub type Open =
  fn(String, Subscriptions, fn(Event) -> Nil) -> Result(Socket, String)

/// リレー接続 1 本ぶんの識別情報。名前を付けておくと、管理 UI が接続アクターに
/// 状態を問い合わせられる。
pub type Relay {
  Relay(name: Name(relay_connection.Msg), url: String)
}

/// プラグイン 1 つぶんの仕様。ランナープロセスの名前、プラグイン本体、実行時の
/// 歯止め。名前は起動時に 1 度だけ作り、ディスパッチャーの宛先と管理 UI の
/// 問い合わせ先の両方になる。`limits` を仕様に持たせているのは、テストが短い
/// タイムアウトと小さい失敗上限でツリーごと動かせるようにするためで、プラグイン
/// 固有の設定から与えるときの受け口にもなる。子プロセスの仕様はここには持たせず、
/// プラグイン自身（`plugin.children`）が持つ。
pub type PluginSpec {
  PluginSpec(
    name: Name(plugin_runner.Msg),
    plugin: Plugin,
    limits: plugin_runner.Limits,
  )
}

/// 監視サブツリー。受信したイベントをプラグインのランナーへ配る重複排除
/// ディスパッチャーと、そこへイベントを流し込むリレー群からなる。
pub type Monitor {
  Monitor(
    name: Name(dedup.Msg),
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

/// 管理 UI。設定から決まるもの（bind アドレス、ポート、パスワード、認証済み
/// ページにだけ出す接続 URI）だけを持ち、表示するその他の状態はツリーの他の
/// 仕様から導く。
pub type Admin {
  Admin(
    bind: String,
    port: Int,
    password: String,
    accounts: List(dashboard.AccountRow),
  )
}

/// イベント保存サブツリー。Postgres の接続プールと、そこへ書き込むロガー
/// アクターからなる。監視サブツリーとは別にしているのは、DB が落ちて再起動が
/// 起きてもリレーの購読を巻き込まないため。
pub type EventLogger {
  EventLogger(name: Name(event_logger.Msg), pool_config: pog.Config)
}

/// 監視・バンカー・イベント保存・管理 UI のどれを動かすか、接続をどう開くか、
/// 接続が再接続までどれだけ待つか。
pub type Spec {
  Spec(
    plugins: List(PluginSpec),
    monitor: Option(Monitor),
    bunker: Option(Bunker),
    event_logger: Option(EventLogger),
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
  // ランナーはディスパッチャーより先に登録しておく。逆順だと起動直後のイベントが
  // 未登録の名前へ送られて黙って消える。
  |> add_plugins(spec.plugins)
  |> add_child(spec.monitor, fn(config) {
    supervisor.supervised(monitor_tree(spec, config))
  })
  |> add_child(spec.bunker, fn(config) {
    supervisor.supervised(bunker_tree(spec, config))
  })
  |> add_child(spec.event_logger, fn(config) {
    supervisor.supervised(event_logger_tree(config))
  })
  |> add_child(spec.admin, admin_child(spec, _))
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

/// プラグインが 1 つも無ければサブツリーごと置かない。空のスーパーバイザーを
/// 足しても害は無いが、ツリーの形が構成を素直に映すほうがよい。
fn add_plugins(builder: Builder, specs: List(PluginSpec)) -> Builder {
  case specs {
    [] -> builder
    specs -> supervisor.add(builder, supervisor.supervised(plugins_tree(specs)))
  }
}

/// プラグインのサブツリー。プラグイン同士は独立なので `one_for_one`。ここの
/// 許容回数は安全網であって、設計の拠りどころではない。プラグインの例外・異常
/// 終了・ハングはランナーの中で完結して**プロセスの死にならない**ため、この
/// 回数はプラグインの不調では消費されない。消費されるのは外部からの強制終了の
/// ような、イベントストリームでは誘発できない事象だけである（冒頭の doc も
/// 参照）。
fn plugins_tree(specs: List(PluginSpec)) -> Builder {
  use builder, spec <- list.fold(specs, plugins_supervisor())
  builder
  |> add_plugin_children(spec.plugin)
  |> supervisor.add(plugin_runner.supervised(
    spec.name,
    spec.plugin,
    spec.limits,
  ))
}

/// 子仕様を持つプラグインにだけ専用のスーパーバイザーを足す。**ランナーより先に
/// 置く。** 順序が意味を持つのは起動順だけだが、子が先に居ないと起動直後の
/// イベントが未登録の宛先に当たって失敗として数えられる。
fn add_plugin_children(builder: Builder, plugin: Plugin) -> Builder {
  case plugin.children {
    [] -> builder
    children ->
      supervisor.add(builder, plugin_children_tree(plugin.name, children))
  }
}

/// プラグイン 1 つぶんの子プロセス。**`Temporary` にすることが歯止めそのもの**
/// で、子がクラッシュループしてこのスーパーバイザーが諦めても、親は再起動せず
/// 許容回数も消費しない。外から kill されたときに再起動されないことも Temporary
/// が担っている（冒頭の doc を参照）。
fn plugin_children_tree(
  name: String,
  children: List(ChildSpecification(Pid)),
) -> ChildSpecification(Supervisor) {
  let builder =
    list.fold(children, plugin_children_supervisor(), supervisor.add)
  supervision.supervisor(fn() { start_plugin_children(name, builder) })
  |> supervision.restart(supervision.Temporary)
}

/// プラグインの子プロセスのスーパーバイザー。子同士は独立なので `one_for_one`。
fn plugin_children_supervisor() -> Builder {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 10)
}

/// 子の起動に失敗しても本体の起動は止めない。理由を 1 行出し、空のスーパー
/// バイザーで代替する。ここで Error を返すと `plugins` の起動が失敗し、ルート
/// まで伝播してアプリが起動しなくなる（Temporary は初回起動には効かない）。
///
/// **`StartError` は整形しない。** `gleam_otp_external` が
/// `{shutdown, {failed_to_start_child, Id, Reason}}` を `InitFailed("shutdown")`
/// に潰すため、ここには理由が届かない。真の理由は `plugin_children` が子ごとに
/// 出す 1 行と、BEAM の `=SUPERVISOR REPORT=` にある。
fn start_plugin_children(
  name: String,
  builder: Builder,
) -> actor.StartResult(Supervisor) {
  case supervisor.start(builder) {
    Ok(started) -> Ok(started)
    Error(_reason) -> {
      log.println(
        log.plugin_prefix(name),
        "children failed to start; the reason is in the child line above, "
          <> "or in the =SUPERVISOR REPORT=; running without them",
      )
      supervisor.start(plugin_children_supervisor())
    }
  }
}

/// プラグインのサブツリーのスーパーバイザー。
fn plugins_supervisor() -> Builder {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 10)
}

/// ディスパッチャーが送る宛先。名前はツリーの起動をまたいで変わらないので、
/// ここで 1 度だけ取り出してクロージャーに捕捉させる。
fn plugin_targets(specs: List(PluginSpec)) -> List(Name(plugin_runner.Msg)) {
  list.map(specs, fn(spec) { spec.name })
}

/// 監視サブツリー。ディスパッチャーと、そこへイベントを流し込む接続群。
fn monitor_tree(spec: Spec, config: Monitor) -> Builder {
  subtree()
  |> supervisor.add(dedup.supervised(
    config.name,
    plugin_runner.dispatch(plugin_targets(spec.plugins), _),
    config.dedup_capacity,
  ))
  |> add_connections(
    spec,
    config.relays,
    config.subscriptions,
    monitor_handler(config.name),
    fn(_relay_url, _socket) { Nil },
    fn(_relay_url) { Nil },
  )
}

/// 監視接続が受信したイベントをディスパッチャーへ渡すハンドラー。バンカー自身の
/// NIP-46 通信はここで落とす。NIP-01 のフィルターに kind の否定は無く、`PUBKEYS`
/// に署名者を含む標準的な構成では自分の応答イベントが監視購読にも届くため、
/// 除外は受信側で行うほかない。
fn monitor_handler(name: Name(dedup.Msg)) -> fn(Event) -> Nil {
  fn(incoming: Event) {
    case incoming.kind == event.nip46_kind {
      True -> Nil
      False -> named.send(name, dedup.Incoming(incoming))
    }
  }
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
    fn(relay_url) { named.send(config.name, bunker.RemovePublisher(relay_url)) },
  )
}

/// 管理 UI。表示する状態は、ツリーの他の仕様から名前を引いて問い合わせる関数
/// として Context に渡す。
fn admin_child(spec: Spec, config: Admin) -> ChildSpecification(Supervisor) {
  admin.supervised(
    config.bind,
    config.port,
    admin.Context(
      password: config.password,
      accounts: config.accounts,
      plugins: fn() { plugin_rows(spec.plugins) },
      event_logger_enabled: option.is_some(spec.event_logger),
      relays: fn() { relay_statuses(spec) },
      sessions: fn() { with_bunker(spec.bunker, [], bunker.sessions) },
      revoke: fn(signer, client) {
        with_bunker(spec.bunker, Nil, bunker.revoke(_, signer, client))
      },
      pending: fn() {
        with_bunker(spec.bunker, [], fn(name) {
          pending_rows(bunker.pending(name))
        })
      },
      approve: fn(token) {
        with_bunker(spec.bunker, disabled, bunker.approve(_, token))
      },
      deny: fn(token) {
        with_bunker(spec.bunker, disabled, bunker.deny(_, token))
      },
    ),
  )
}

/// 設定されているサブツリーにだけ問い合わせ、無効なら既定値を返す。管理 UI は
/// 一部が無効でも表示できなければならないため、無効は欠損ではなく既定値にする。
fn if_enabled(
  configured: Option(subtree),
  default: answer,
  ask: fn(subtree) -> answer,
) -> answer {
  configured
  |> option.map(ask)
  |> option.unwrap(default)
}

/// プラグインごとの表示行。状態は各ランナーへ問い合わせて取る。
fn plugin_rows(specs: List(PluginSpec)) -> List(dashboard.PluginRow) {
  use spec <- list.map(specs)
  dashboard.PluginRow(
    name: spec.plugin.name,
    status: plugin_runner.status(spec.name),
  )
}

/// 監視・バンカー両サブツリーのリレー接続の現在の状態。
fn relay_statuses(spec: Spec) -> List(dashboard.RelayRow) {
  let monitor_rows = {
    use monitor <- if_enabled(spec.monitor, [])
    statuses(dashboard.MonitorRelay, monitor.relays)
  }
  let bunker_rows = {
    use configured <- if_enabled(spec.bunker, [])
    statuses(dashboard.BunkerRelay, configured.relays)
  }
  list.append(monitor_rows, bunker_rows)
}

/// 指定した用途のリレーそれぞれについて、接続アクターに状態を問い合わせる。
/// 逐次に問い合わせるため待ち時間はリレー数ぶん積み上がるが、接続アクターが
/// ループをブロックするのは `connect` の実行中だけで、その上限は `relay_client`
/// の connect タイムアウト（3 秒）である。`relay_connection` の問い合わせ
/// タイムアウト（5 秒）はそれを包む安全網であって通常の待ち時間ではない。数本の
/// リレーが同時にハンドシェイク中でも管理 UI の表示が数秒遅れるだけなので、
/// 並列化して部分的な結果を扱う複雑さは引き合わない。
fn statuses(
  role: dashboard.Role,
  relays: List(Relay),
) -> List(dashboard.RelayRow) {
  use relay <- list.map(relays)
  dashboard.RelayRow(
    role: role,
    url: relay.url,
    status: relay_connection.status(relay.name),
  )
}

/// バンカーアクターの名前を使って問い合わせる。バンカーが無効なら、問い合わせず
/// 既定値を返す。
fn with_bunker(
  config: Option(Bunker),
  default: answer,
  ask: fn(Name(bunker.Msg)) -> answer,
) -> answer {
  use config <- if_enabled(config, default)
  ask(config.name)
}

/// 承認待ちを管理 UI の行にする。経過時間は問い合わせた時点で求める。
fn pending_rows(pending: List(Pending)) -> List(dashboard.PendingRow) {
  let now = time.now_seconds()
  use entry <- list.map(pending)
  dashboard.PendingRow(
    token: entry.token,
    signer: entry.signer,
    client: entry.client,
    age_seconds: now - entry.created_at,
  )
}

/// イベント保存サブツリー。プールを先に起動し、ロガーアクターがその名前を宛先に
/// する。プールが再起動するとロガーも再起動し、スキーマの確認からやり直す。
fn event_logger_tree(config: EventLogger) -> Builder {
  subtree()
  |> supervisor.add(pog.supervised(config.pool_config))
  |> supervisor.add(event_logger.supervised(
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
/// サブツリー内で共有し、接続・切断の通知にはそのリレーの URL を添える。
fn add_connections(
  builder: Builder,
  spec: Spec,
  relays: List(Relay),
  subscriptions: Subscriptions,
  handle_event: fn(Event) -> Nil,
  on_connect: fn(String, Socket) -> Nil,
  on_disconnect: fn(String) -> Nil,
) -> Builder {
  use builder, relay <- list.fold(relays, builder)
  supervisor.add(
    builder,
    relay_connection.supervised(relay_connection.Settings(
      name: relay.name,
      relay: relay_client.label(relay.url),
      connect: fn() { spec.open(relay.url, subscriptions, handle_event) },
      on_connect: on_connect(relay.url, _),
      on_disconnect: fn() { on_disconnect(relay.url) },
      reconnect_delay_ms: spec.reconnect_delay_ms,
    )),
  )
}
