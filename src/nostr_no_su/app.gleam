//// スーパービジョンツリーの組み立て。ルートの子と、その下のサブツリーの形は次のとおり。
////
//// ```
//// root (one_for_one)
//// |-- relay_list (worker)      : リレーの一覧と connections (factory) の子の起動・停止
//// |-- plugins    (one_for_one) : children(<plugin>) (Temporary) と runner(<plugin>)
//// |-- bunker     (rest_for_one): 接続プール、ロックのプール、アクター、connections、
//// |                              session_connections
//// |-- monitor    (rest_for_one): dedup、connections、再開点の保存
//// |-- avatars    (worker)      : アカウントのアイコンの URL のキャッシュ
//// `-- admin      (mist)        : 管理 UI の HTTP サーバー
//// ```
////
//// **ルートの子は `relay_list` をすべてより先に、`plugins` と `bunker` を `monitor` より
//// 先に追加すること。** 逆順で壊れる配線は `start` の行内コメントにある。
////
//// 戦略と許容回数、プールの置き場所、再起動の許容回数に頼らない設計は
//// `docs/architecture.md` の「スーパービジョンツリー」に、判断の理由は
//// `docs/design-decisions.md` の「スーパービジョンツリー」と「プラグインが申告した
//// 子プロセスは Temporary で載せる」にある。

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/static_supervisor.{type Builder, type Supervisor} as supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/avatars
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/connection_uri
import nostr_no_su/bunker/delivery
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/nostrconnect
import nostr_no_su/bunker/session.{type Pending, type Session}
import nostr_no_su/bunker/vault
import nostr_no_su/config
import nostr_no_su/db
import nostr_no_su/dedup
import nostr_no_su/hex
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event
import nostr_no_su/nostr/nip19
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugin_config
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/relay_client.{
  type Acknowledgement, type Authenticator, type Received, type Subscriptions,
}
import nostr_no_su/relay_connection.{type Socket, Socket}
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/resume/saver
import nostr_no_su/subscriptions
import nostr_no_su/task
import nostr_no_su/time
import pog

/// リレー接続の開き方。本番では `open_websocket`、テストでは偽ソケットを使い、
/// ネットワークなしでもツリー全体を動かせるようにする。ハンドラーが受け取るのは
/// 接続のプロセスで id と署名を確かめたイベントか保存済みイベントの終わり
/// （`relay_client.Received`）と、発行したイベントへの OK（受理・拒否とも）
/// である。AUTH の受け口（応答しない接続は `None`）も渡す。
pub type Open =
  fn(
    String,
    Subscriptions,
    fn(Received) -> Nil,
    fn(Acknowledgement) -> Nil,
    Option(Authenticator),
  ) -> Result(Socket, String)

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
/// ディスパッチャーと、そこへイベントを流し込むリレー群からなる。リレーは
/// バンカーの読み込みから `OpenRegistered` で届き、実行時の増減には `open_relay`
/// などを使う。`subscriptions` はリレー URL からそのリレーの購読の定義を返す。
/// `save_resume` は再開点を小さくせずに保存する操作で、`resume_saver` が使う。
/// `save_plugin_resume` はプラグインごとの再開点を保存する操作で、2 本目の
/// `resume_saver` が使う。`excludes_kind` が真を返す kind のイベントは
/// プラグインへ渡さない。`accepts_author` はイベントの作者の pubkey が登録
/// アカウントのものかを返す述語で、偽になるイベントはプラグインへ渡さない。
pub type Monitor {
  Monitor(
    name: Name(dedup.Msg),
    dedup_capacity: Int,
    subscriptions: fn(String) -> Subscriptions,
    save_resume: fn(List(#(String, Int))) -> Result(Nil, String),
    save_plugin_resume: fn(List(#(String, Int))) -> Result(Nil, String),
    excludes_kind: fn(Int) -> Bool,
    accepts_author: fn(String) -> Bool,
  )
}

/// バンカーサブツリー。アカウントストアの接続プールと、NIP-46 アクターと、それが
/// 待ち受け・応答するリレー群。`pool` はパスワードを含みうるので、表示やログに
/// 入れないこと。`lock_pool` は同じ DB に 1 インスタンスだけを許すロック専用の
/// 1 本のプール。`pool` と同じくパスワードを含みうる。リレーはバンカーの読み込みから
/// `OpenRegistered` で届き、実行時の増減には `open_relay` などを使う。`subscriptions`
/// は署名者の問い合わせ（応答が無ければ `None`）から購読の定義を作る関数で、基本の
/// 接続には全署名者、セッションのリレーの接続にはその URL を持つセッションと取り置きの
/// 署名者の問い合わせ（`bunker.session_signers`）を渡す。
pub type Bunker {
  Bunker(
    name: Name(bunker.Msg),
    pool: pog.Config,
    lock_pool: pog.Config,
    settings: bunker.Settings,
    subscriptions: fn(fn() -> Option(List(String))) -> Subscriptions,
  )
}

/// 動かすプラグインと、起動時に読み込めなかったプラグインの一覧と、バンカーと
/// 監視、管理 UI を動かすかどうか、接続をどう開くか、接続の再接続の待ち時間、
/// 実行時のリレーの一覧を持つ `relay_list` の名前。`not_loaded_plugins` は
/// 起動時に確定し、管理 UI がそのまま出す。
pub type Spec {
  Spec(
    plugins: List(PluginSpec),
    not_loaded_plugins: List(plugin_loader.NotLoaded),
    monitor: Monitor,
    bunker: Bunker,
    admin: Option(config.AdminListen),
    open: Open,
    reconnect_delay: backoff.Backoff,
    relay_list: Name(relay_list.Msg),
  )
}

/// ツリーに渡る秘密のうち、他のライブラリーのプロセスの状態や起動引数に生の
/// 文字列として入りうるもの（pgo に渡す DB のパスワードと、mist と wisp に渡る
/// 管理パスワード）。`log.redact_secrets` に渡してログから伏せる。空の値は
/// 含めない。`lock_pool` は別に集めない。`db.lock_pool_config` が
/// `pool` から `pog.Config(..pool, ...)` で作るため、パスワードは `pool` と
/// 同じ値である。
pub fn redactable_secrets(spec: Spec) -> List(String) {
  let admin_password = option.map(spec.admin, fn(a) { a.password })
  [spec.bunker.pool.password, admin_password]
  |> option.values
  |> list.filter(fn(value) { value != "" })
}

/// ツリーを起動する。子は互いに独立しているためルートは `one_for_one`。
/// バンカーや DB が壊れても監視を止めてはならず、その逆も同様。
///
/// 用途ごとの `connections` の factory の名前はここで 1 度だけ作る。`spec` が
/// 持つ名前（`nostr_no_su.gleam` が作る）は `app` の外が呼ぶ宛先で、factory の
/// 名前は `app` と `relay_list` の中でしか使わないためである。`start` はツリー
/// ごとに 1 回だけ走るので、`rest_for_one` の再起動で作り直された factory も
/// 同じ名前を再登録する。
pub fn start(spec: Spec) -> actor.StartResult(Supervisor) {
  let factories =
    relay_list.Factories(
      monitor: process.new_name("nostr_no_su_relay_connections_monitor"),
      bunker: process.new_name("nostr_no_su_relay_connections_bunker"),
      session: process.new_name("nostr_no_su_relay_connections_session"),
    )
  let avatars_name = process.new_name("nostr_no_su_avatars")
  supervisor.new(supervisor.OneForOne)
  // サブツリーより意図的に厳しく、期間も長く取る。再起動を諦め続けるサブツリー
  // は復旧不能とみなし、ここでループせず終了することで再起動をコンテナーの
  // 再起動ポリシーに委ねる。
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  // relay_list はすべてより先に登録する。逆順だと connections の factory が
  // 起動直後に送る Repopulate が未登録の名前へ送られて捨てられる。
  |> supervisor.add(relay_list.supervised(spec.relay_list, factories))
  // ランナーはディスパッチャーより先に登録しておく。逆順だと起動直後のイベントが
  // 未登録の名前へ送られて届かない（件数はディスパッチャーがログに出す）。
  |> add_plugins(spec)
  // バンカーは監視より先に起動する。監視の接続が購読を組み立てるために送る
  // `GetSigners` を、バンカーの名前の登録と最初の読み込みの後に処理させるため。
  // 逆順だと最初の購読の評価が定義を得られず、再試行を待つ。
  |> supervisor.add(
    supervisor.supervised(bunker_tree(spec, spec.bunker, factories)),
  )
  |> supervisor.add(
    supervisor.supervised(monitor_tree(spec, spec.monitor, factories)),
  )
  |> add_child(spec.admin, fn(_config) {
    avatars.supervised(
      avatars_name,
      avatars.default_ttl_ms,
      avatars.default_retry_ms,
    )
  })
  |> add_child(spec.admin, admin_child(spec, avatars_name, _))
  |> supervisor.start
}

/// リレーへの実際の WebSocket 接続を開き、接続アクターが監視と送信に使う
/// ソケットとして表現する。
pub fn open_websocket(
  url: String,
  subscriptions: Subscriptions,
  handle_event: fn(Received) -> Nil,
  handle_ok: fn(Acknowledgement) -> Nil,
  authenticator: Option(Authenticator),
) -> Result(Socket, String) {
  use connection <- result.try(relay_client.start(
    url,
    relay_client.Handlers(
      subscriptions:,
      handle_incoming: handle_event,
      handle_ok:,
      authenticator:,
    ),
    relay_client.default_timing,
  ))
  // 接続の subject は名前付きではないため、必ず所有プロセスが存在する。
  let assert Ok(pid) = process.subject_owner(connection)
  Ok(
    Socket(
      pid: pid,
      publish: relay_client.publish(connection, _),
      resubscribe: fn() { relay_client.resubscribe(connection) },
    ),
  )
}

/// アプリのその部分が設定されている場合にルートの子を追加する。
fn add_child(
  builder: Builder,
  configured: Option(config),
  child: fn(config) -> ChildSpecification(data),
) -> Builder {
  case configured {
    None -> builder
    Some(config) -> supervisor.add(builder, child(config))
  }
}

/// プラグインが 1 つも無ければサブツリーごと置かない。空のスーパーバイザーを
/// 足しても害は無いが、ツリーの形が構成を素直に映すほうがよい。
fn add_plugins(builder: Builder, spec: Spec) -> Builder {
  case spec.plugins {
    [] -> builder
    _specs -> supervisor.add(builder, supervisor.supervised(plugins_tree(spec)))
  }
}

/// プラグインのサブツリー。プラグイン同士は独立なので `one_for_one`。ランナーに渡す
/// 張り直しは監視の用途の接続だけへ送る（バンカーの購読はプラグインに関わらない）。
fn plugins_tree(spec: Spec) -> Builder {
  let resubscribe = fn() {
    relay_list.resubscribe_all(spec.relay_list, [relay_list.Monitor])
  }
  use builder, plugin_spec <- list.fold(
    spec.plugins,
    subtree_supervisor(supervisor.OneForOne),
  )
  builder
  |> add_plugin_children(plugin_spec.plugin)
  |> supervisor.add(plugin_runner.supervised(
    plugin_spec.name,
    plugin_spec.plugin,
    resubscribe,
    plugin_spec.limits,
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

/// プラグイン 1 つぶんの子プロセスのスーパーバイザーを、`Temporary` の子仕様にする。
/// 理由は `docs/design-decisions.md` の「プラグインが申告した子プロセスは Temporary で載せる」。
fn plugin_children_tree(
  name: String,
  children: List(ChildSpecification(Pid)),
) -> ChildSpecification(Supervisor) {
  // 子同士は独立なので one_for_one。
  let builder =
    list.fold(
      children,
      subtree_supervisor(supervisor.OneForOne),
      supervisor.add,
    )
  supervision.supervisor(fn() { start_plugin_children(name, builder) })
  |> supervision.restart(supervision.Temporary)
}

/// 本体のサブツリーのスーパーバイザー。許容する再起動の頻度は
/// `relay_list.subtree_restart_tolerance` で共通にし、戦略 `strategy` だけを呼び出し元が選ぶ。
fn subtree_supervisor(strategy: supervisor.Strategy) -> Builder {
  supervisor.new(strategy)
  |> supervisor.restart_tolerance(
    intensity: relay_list.subtree_restart_tolerance.intensity,
    period: relay_list.subtree_restart_tolerance.period,
  )
}

/// 子の起動に失敗しても本体の起動は止めず、Warning を 1 行出して空のスーパーバイザーで代える。
/// `StartError` は `gleam_otp_external` が `InitFailed("shutdown")` に潰して理由を持たないので
/// 整形しない。理由は `plugin_children` が子ごとに出す 1 行と supervisor report にある。
fn start_plugin_children(
  name: String,
  builder: Builder,
) -> actor.StartResult(Supervisor) {
  case supervisor.start(builder) {
    Ok(started) -> Ok(started)
    Error(_reason) -> {
      log.write(
        log.Warning,
        log.plugin_prefix(name),
        "children failed to start; the reason is in the child line above, "
          <> "or in the supervisor report; running without them",
      )
      supervisor.start(subtree_supervisor(supervisor.OneForOne))
    }
  }
}

/// ディスパッチャーが送る宛先の初期値。名前はツリーの起動をまたいで変わらない
/// ので、ディスパッチャーが再起動してもこの値から始めればよい。
fn plugin_targets(specs: List(PluginSpec)) -> List(plugin_runner.Target) {
  use spec <- list.map(specs)
  plugin_runner.target(spec.plugin.name, spec.name)
}

/// プラグイン名から、そのランナーの登録名への対応。取り直しの購読 id の
/// 振り分けに使う。
fn plugin_runner_names(
  specs: List(PluginSpec),
) -> Dict(String, Name(plugin_runner.Msg)) {
  specs
  |> list.map(fn(spec) { #(spec.plugin.name, spec.name) })
  |> dict.from_list
}

/// 各ランナーへ `plugin_runner.resume` で問い合わせ、応答があって再開点を持つ
/// ものだけをプラグイン名をキーに集めた辞書を返す操作を作る。応答が無い
/// ランナー（再起動中、遅い実行の最中）はその周期では入れない。プラグインが
/// 0 件でも空の辞書を返すので、`Result` は常に `Ok`。
fn plugin_resume_points(
  specs: List(PluginSpec),
) -> fn() -> Result(Dict(String, Int), Nil) {
  fn() {
    specs
    |> list.filter_map(fn(spec) {
      case plugin_runner.resume(spec.name) {
        Ok(Some(since)) -> Ok(#(spec.plugin.name, since))
        _ -> Error(Nil)
      }
    })
    |> dict.from_list
    |> Ok
  }
}

/// 各ランナーへ `plugin_runner.catchup` で問い合わせ、応答があって取り直しの
/// 要求を持つものだけをプラグイン名と組にして返す操作を作る。1 つでも答えない
/// ランナーがあれば `Error(Nil)` にする。答えないランナーを黙って落とすと、その
/// プラグインの取り直しの購読が定義から消え、開いている購読へ照合で CLOSE を
/// 送ってしまうためである（`relay_client.sync`）。この問い合わせは監視のリレー
/// 接続のプロセスが購読を評価するたびに呼ばれ、呼び出し側を最大
/// `1000ms × プラグイン数` だけ塞ぐ（`plugin_runner` の問い合わせの期限）。
pub fn plugin_catchups(
  specs: List(PluginSpec),
) -> fn() -> Result(List(#(String, plugin_runner.Catchup)), Nil) {
  fn() {
    use answered <- result.try(
      list.try_map(specs, fn(spec) {
        use catchup <- result.map(plugin_runner.catchup(spec.name))
        #(spec.plugin.name, catchup)
      }),
    )
    list.filter_map(answered, fn(pair) {
      case pair.1 {
        Some(catchup) -> Ok(#(pair.0, catchup))
        None -> Error(Nil)
      }
    })
    |> Ok
  }
}

/// 監視サブツリー。ディスパッチャー、そこへイベントを流し込む接続群の
/// `connections` factory、監視の再開点を保存するアクター、プラグインの再開点を
/// 保存するアクターの順に置く。保存のアクターを末尾に置くのは、その異常終了で
/// 接続を落とさないためである。
fn monitor_tree(
  spec: Spec,
  config: Monitor,
  factories: relay_list.Factories,
) -> Builder {
  subtree_supervisor(supervisor.RestForOne)
  |> supervisor.add(dedup.supervised(
    config.name,
    plugin_targets(spec.plugins),
    plugin_runner.dispatch,
    config.dedup_capacity,
  ))
  |> supervisor.add(relay_connections_child(
    spec,
    factories,
    relay_list.Monitor,
    config.subscriptions,
    ConnectionHandlers(
      ..silent_handlers(),
      handle_event: monitor_handler(
        config.name,
        config.excludes_kind,
        config.accepts_author,
        plugin_runner_names(spec.plugins),
      ),
    ),
  ))
  |> supervisor.add(saver.supervised(
    fn() { dedup.points(config.name) },
    config.save_resume,
    "resume_saver",
    saver.default_interval_ms,
  ))
  |> supervisor.add(saver.supervised(
    plugin_resume_points(spec.plugins),
    config.save_plugin_resume,
    "plugin_resume_saver",
    saver.default_interval_ms,
  ))
}

/// 監視接続が受信したものを振り分けるハンドラー。イベントは kind、購読 id、
/// 作者の順に照合する。`excludes_kind` が真の kind のイベントは数えずに落とす。
/// 監視とバンカーが同じリレーを使うとバンカーの応答（kind 24133）も監視の購読に
/// 届くので、呼び出し側はそれを含む述語を渡す。購読 id が監視の購読
/// （`subscriptions.monitor_subscription_id`）でも取り直しの購読
/// （`subscriptions.catchup_plugin`）でもないイベントと、作者が `accepts_author` に通らない
/// イベントは落とし、ディスパッチャーに `dedup.Rejected` で数えさせる。照合を通ったイベントは、
/// 取り直しの購読のものならそのプラグインのランナーへ直接送り、監視の購読のもの
/// ならディスパッチャーへ渡す。終わり（EOSE）は、取り直しの購読のものだけを
/// ランナーに取り直しの完了として伝える。
pub fn monitor_handler(
  name: Name(dedup.Msg),
  excludes_kind: fn(Int) -> Bool,
  accepts_author: fn(String) -> Bool,
  runners: Dict(String, Name(plugin_runner.Msg)),
) -> fn(String, Received) -> Nil {
  fn(relay_url: String, received: Received) {
    case received {
      relay_client.ReceivedEvent(subscription_id, verified) -> {
        let incoming = event.verified_event(verified)
        use <- bool.guard(excludes_kind(incoming.kind), Nil)
        let reject = fn() { named.send(name, dedup.Rejected(relay_url)) }
        let if_accepted = fn(deliver: fn() -> Nil) {
          bool.lazy_guard(!accepts_author(incoming.pubkey), reject, deliver)
        }
        case
          subscriptions.catchup_plugin(subscription_id),
          subscription_id == subscriptions.monitor_subscription_id
        {
          Some(plugin), _ ->
            if_accepted(fn() {
              send_to_runner(
                runners,
                plugin,
                plugin_runner.HandleCatchup(incoming),
              )
            })
          None, True ->
            if_accepted(fn() {
              named.send(name, dedup.Incoming(relay_url, incoming))
            })
          None, False -> reject()
        }
      }
      relay_client.ReceivedEose(subscription_id) ->
        case subscriptions.catchup_plugin(subscription_id) {
          Some(plugin) ->
            send_to_runner(runners, plugin, plugin_runner.CatchupEnded)
          None -> Nil
        }
    }
  }
}

/// 取り直しの購読 id の振り分け先のランナーへメッセージを送る。ランナーが
/// 居なければ捨てる。
fn send_to_runner(
  runners: Dict(String, Name(plugin_runner.Msg)),
  plugin: String,
  message: plugin_runner.Msg,
) -> Nil {
  case dict.get(runners, plugin) {
    Ok(name) -> named.send(name, message)
    Error(Nil) -> Nil
  }
}

/// バンカーサブツリー。接続プール、ロックのプール、アクター、基本のバンカーリレーの
/// 接続の `connections` factory、セッションのリレーの接続の factory の順に置く。
/// アクターはプールが登録された後に起動する必要があり（`docs/architecture.md` の
/// 「スーパービジョンツリー」を参照）、各接続はアクターに publisher を登録するため、
/// アクターと一緒に再起動する必要がある。
/// アクターが署名者の変化で依頼する購読の張り直しは、`relay_list` へ送るだけで
/// 待たない（`ResubscribeAll` が監視とバンカーの現在の全接続へ転送する）。
/// セッションのリレーの変化は `relay_list.sync_session_relays` へ送る。
/// `rest_for_one` なので、ロックのプールが再起動するとアクターと接続も再起動し、
/// アクターの読み込みが advisory lock を取り直す。接続が受けた AUTH は、接続の範囲を
/// 添えたアクターへの問い合わせで応答する。
fn bunker_tree(
  spec: Spec,
  config: Bunker,
  factories: relay_list.Factories,
) -> Builder {
  subtree_supervisor(supervisor.RestForOne)
  |> supervisor.add(pog.supervised(config.pool))
  |> supervisor.add(pog.supervised(config.lock_pool))
  |> supervisor.add(
    bunker.supervised(
      config.name,
      config.settings,
      fn() {
        relay_list.resubscribe_all(spec.relay_list, [
          relay_list.Monitor,
          relay_list.Bunker,
        ])
      },
      relay_list.open_registered(spec.relay_list, _),
      relay_list.sync_session_relays(spec.relay_list, _),
    ),
  )
  |> supervisor.add(
    bunker_connections_child(
      spec,
      factories,
      config,
      relay_list.Bunker,
      delivery.BaseRelay,
      fn(_relay_url) { bunker.signers(config.name) },
    ),
  )
  |> supervisor.add(
    bunker_connections_child(
      spec,
      factories,
      config,
      relay_list.SessionOnly,
      delivery.SessionRelay,
      bunker.session_signers(config.name, _),
    ),
  )
}

/// バンカーの接続の用途 `role` の子。購読は `signers` が返す署名者から、AUTH と
/// 送信手段の登録と取り下げは `scope` の範囲で行う。
fn bunker_connections_child(
  spec: Spec,
  factories: relay_list.Factories,
  config: Bunker,
  role: relay_list.Role,
  scope: delivery.RelayScope,
  signers: fn(String) -> Option(List(String)),
) -> ChildSpecification(
  factory_supervisor.Supervisor(
    relay_list.Connection,
    Subject(relay_connection.Msg),
  ),
) {
  relay_connections_child(
    spec,
    factories,
    role,
    fn(relay_url) { config.subscriptions(fn() { signers(relay_url) }) },
    ConnectionHandlers(
      handle_event: fn(_relay_url, received) {
        case received {
          relay_client.ReceivedEvent(_, verified) ->
            named.send(config.name, bunker.Incoming(verified))
          relay_client.ReceivedEose(_) -> Nil
        }
      },
      handle_ok: fn(relay_url, ack) {
        named.send(config.name, bunker.Acknowledged(relay_url, ack))
      },
      authenticator: fn(relay_url) {
        Some(bunker.authenticate(config.name, relay_url, scope, _))
      },
      on_connect: fn(relay_url, socket: Socket) {
        named.send(
          config.name,
          bunker.SetPublisher(relay_url, scope, socket.publish),
        )
      },
      on_disconnect: fn(relay_url) {
        named.send(config.name, bunker.RemovePublisher(relay_url, scope))
      },
    ),
  )
}

/// 管理 UI。bind アドレス、ポート、パスワードは `listen` から取り、表示する状態は、
/// ツリーの他の仕様から名前を引いて問い合わせる関数として Context に渡す。
fn admin_child(
  spec: Spec,
  avatars_name: Name(avatars.Msg),
  listen: config.AdminListen,
) -> ChildSpecification(Supervisor) {
  let bunker_name = spec.bunker.name
  admin.supervised(
    listen.bind,
    listen.port,
    admin.Context(
      password: listen.password,
      client_address: admin.unknown_client_address,
      authentication_delay: fn() {
        process.sleep(admin.authentication_failure_delay)
      },
      accounts: fn() {
        account_rows(spec, avatars.pictures(avatars_name, spec.relay_list, _))
      },
      skipped: fn() { skipped_rows(spec) },
      add_account: fn(added, label) { add_account(spec, added, label) },
      remove_account: bunker.remove_account(bunker_name, _),
      rotate_secret: bunker.rotate_secret(bunker_name, _),
      update_label: fn(signer, label) {
        bunker.update_label(bunker_name, signer, label)
      },
      nsec: bunker.nsec(bunker_name, _),
      reload_accounts: fn() { bunker.reload_accounts(bunker_name) },
      plugins: fn(deadline) { plugin_rows(spec.plugins, deadline) },
      not_loaded_plugins: spec.not_loaded_plugins,
      reenable_plugin: reenable_plugin(spec.plugins, _),
      plugin_page_content: fn(plugin, key, language, accounts) {
        plugin_page_content(
          spec.plugins,
          plugin,
          key,
          i18n.code(language),
          accounts,
        )
      },
      page_accounts: fn() { page_accounts(spec) },
      plugin_page_action: fn(plugin, key) {
        plugin_page_action(spec.plugins, plugin, key)
      },
      relays: fn(deadline) { relay_rows(spec, deadline) },
      add_relay: fn(url, roles) { add_relay(spec, url, roles) },
      registered_relays: fn() { registered_relays(spec) },
      update_relay_roles: fn(relay, roles) {
        update_relay_roles(spec, relay, roles)
      },
      delete_relay: fn(relay) { delete_relay(spec, relay) },
      connect_client: fn(request, signer) {
        connect_nostrconnect(spec, request, signer)
      },
      sessions: fn() { result.map(bunker.sessions(bunker_name), session_rows) },
      revoke: fn(signer, client) { bunker.revoke(bunker_name, signer, client) },
      update_perms: fn(signer, client, perms) {
        bunker.update_perms(bunker_name, signer, client, perms)
      },
      pending: fn() { result.map(bunker.pending(bunker_name), pending_rows) },
      approve: bunker.approve(bunker_name, _),
      deny: bunker.deny(bunker_name, _),
    ),
  )
}

/// アカウントを追加し、反映されるまで待つ。先にディスパッチャーへ追加の時刻と
/// その時点の監視リレーの URL を知らせる。知らせは送るだけで待たないが、追加の
/// 成功でバンカーが依頼する監視の購読の張り直しの問い合わせより先にディスパッチ
/// ャーへ届くので、張り直した購読の `since` はこの時刻を下回らない。バンカーが
/// 読み込めていなければ知らせずに `NotReady` を返す。時刻が保存済みの再開点を
/// 追い越し、読み込みの後の購読が停止中のイベントを求めなくなるためである。
/// アカウントを追加する経路はすべてこの関数を通すこと。管理 UI の Context が使う。
///
/// `relay_list` が応答しなければ URL を `[]` で知らせる。再開点は引き上がらず、
/// 張り直した購読は保存済みの再開点から求めるので、起こるのは取りこぼしでは
/// なく取りすぎである。応答が無いのは変更の処理が長引いたとき（`relay_list` の
/// 既知の窓 3）かバグのときで、`NotReady` に揃えないのはどちらも `[]` を送る
/// のと同じだけ取りすぎになるためである。
pub fn add_account(
  spec: Spec,
  added: account.Account,
  label: String,
) -> Result(Nil, bunker.ChangeFailure) {
  use _listings <- result.try(
    bunker.accounts(spec.bunker.name) |> result.map_error(bunker.NotReady),
  )
  dedup.adding_account(spec.monitor.name, monitor_urls(spec))
  bunker.add_account(spec.bunker.name, added, label)
}

/// 現在の監視リレーの URL。`relay_list` が応答しなければ `[]`。
fn monitor_urls(spec: Spec) -> List(String) {
  relay_list.entries(spec.relay_list)
  |> result.map(relay_list.urls(_, relay_list.Monitor))
  |> result.unwrap([])
}

/// リレー 1 件の接続を開き、起動の依頼を終えてから返す。
pub fn open_relay(
  spec: Spec,
  url: String,
  roles: relay_list.Roles,
) -> Result(Nil, relay_list.ChangeError) {
  relay_list.change(spec.relay_list, relay_list.open(_, url, roles))
}

/// 接続を止め、一覧から外してから返す。止めたバンカーの接続は `on_disconnect`
/// で送信先から外れる。
pub fn close_relay(
  spec: Spec,
  url: String,
) -> Result(Nil, relay_list.ChangeError) {
  relay_list.change(spec.relay_list, relay_list.close(_, url))
}

/// 位置を保って用途を変え、外した用途の接続を止め、得た用途の接続を開く。
pub fn change_relay_roles(
  spec: Spec,
  url: String,
  roles: relay_list.Roles,
) -> Result(Nil, relay_list.ChangeError) {
  relay_list.change(spec.relay_list, relay_list.change_roles(_, url, roles))
}

/// プラグインごとの表示行。状態は各ランナーへ並行に問い合わせ、締め切りまでに
/// 答えなかったランナーは `None`（応答なし）にする。
pub fn plugin_rows(
  specs: List(PluginSpec),
  deadline: task.Deadline,
) -> List(dashboard.PluginRow) {
  let statuses =
    task.map_within(specs, deadline, fn(spec) {
      plugin_runner.status(spec.name)
    })
  use spec, status <- list.map2(specs, statuses)
  dashboard.PluginRow(
    name: spec.plugin.name,
    status: result.unwrap(status, None),
    pages: plugin_ui_pages(spec.plugin.ui),
  )
}

/// プラグインが供給するページの一覧。UI を持たないプラグインは空。
fn plugin_ui_pages(ui: Option(plugin.PluginUi)) -> List(plugin.PluginPage) {
  case ui {
    Some(ui) -> ui.pages
    None -> []
  }
}

/// 名前でプラグインの仕様を引く。名前で引いてよいのは、読み込みが同名のプラグインを
/// 2 つ目以降で捨てるためである（`plugin_loader.gleam` の重複検査。同梱のプラグイン名も
/// `reserved` として同じ検査に入る）。
fn find_plugin(
  specs: List(PluginSpec),
  name: String,
) -> Result(PluginSpec, Nil) {
  list.find(specs, fn(spec) { spec.plugin.name == name })
}

/// 管理 UI の再有効化。名前でランナーを引き、応答を待つ。
pub fn reenable_plugin(
  specs: List(PluginSpec),
  plugin: String,
) -> Result(Nil, admin.ReenableFailure) {
  use spec <- result.try(
    find_plugin(specs, plugin)
    |> result.replace_error(admin.PluginNotFound("plugin not found")),
  )
  plugin_runner.request_reenable(spec.name)
  |> option.to_result(admin.PluginNotAnswered("plugin runner did not answer"))
}

/// 管理 UI のプラグインのページの中身。`language` は表示の言語のコードで、言語を
/// 受け取るプラグインにだけ渡る。UI を持たないプラグイン、または一覧に無い名前は 1 行の
/// 理由を返す（`admin.plugin_page` が行の一覧で先に 404 にするので、名前で引けないことは
/// 通常起きない）。
pub fn plugin_page_content(
  specs: List(PluginSpec),
  plugin: String,
  key: String,
  language: String,
  accounts: List(plugin_config.PageAccount),
) -> Result(Dynamic, String) {
  use spec <- result.try(
    find_plugin(specs, plugin)
    |> result.replace_error("plugin not found"),
  )
  case spec.plugin.ui {
    Some(ui) -> ui.content(key, language, accounts)
    None -> Error("plugin has no pages")
  }
}

/// プラグイン名とページのキーで、フォームの送信を受け取る実行の口を探す。
/// プラグインが見つからない、UI が無い、`plugin_page_action` を持たないの
/// いずれも `None` に畳む（`admin.plugin_page` はこれで 405 にする）。
pub fn plugin_page_action(
  specs: List(PluginSpec),
  plugin: String,
  key: String,
) -> Option(plugin_config.PageAction) {
  use spec <- option.then(
    find_plugin(specs, plugin)
    |> option.from_result,
  )
  use ui <- option.then(spec.plugin.ui)
  use action <- option.map(ui.action)
  fn(values, accounts) { action(key, values, accounts) }
}

/// 管理 UI のページと実行の呼び出しに渡す、登録アカウントの一覧。`bunker.accounts`
/// の一覧を `plugin_config.PageAccount` に写す。
pub fn page_accounts(
  spec: Spec,
) -> Result(List(plugin_config.PageAccount), String) {
  use listings <- result.try(bunker.accounts(spec.bunker.name))
  Ok(
    list.map(listings, fn(listing) {
      plugin_config.PageAccount(
        pubkey: listing.signer,
        npub: listing.npub,
        label: listing.label,
      )
    }),
  )
}

/// `relay_list` の現在の一覧。応答が無ければ、管理 UI の節に出す理由
/// `relay list did not answer` を返す。
fn relay_entries(spec: Spec) -> Result(List(relay_list.Entry), String) {
  relay_list.entries(spec.relay_list)
  |> result.replace_error("relay list did not answer")
}

/// リレーの節の行。`relay_list` が応答しなければその理由を、DB の `relays` を
/// 読めなければその理由を返す。DB の行の URL に対応する接続の名前を集めて
/// `relay_statuses` で並行に問い合わせ、締め切りまでに答えなかった接続は
/// `dashboard.Unanswered` にする。
///
/// `relay_list` の応答（15 秒）と DB の読み込み（3 秒）の待ちは締め切りの外で、
/// 最悪 18 秒になる。どちらもローカルのアクターと DB の待ちで、リレーの無応答では
/// 起きない。
pub fn relay_rows(
  spec: Spec,
  deadline: task.Deadline,
) -> Result(List(dashboard.RelayRow), String) {
  use entries <- result.try(relay_entries(spec))
  use relays <- result.map(registered_relays(spec))
  let relay_urls = list.map(relays, fn(relay) { relay.url })
  let names =
    entries
    |> list.filter(fn(entry) { list.contains(relay_urls, entry.url) })
    |> list.flat_map(fn(entry) { option.values([entry.monitor, entry.bunker]) })
  let statuses = relay_statuses(names, deadline)
  let status = fn(name) { list.key_find(statuses, name) |> result.unwrap(None) }
  merge_relay_rows(relays, entries, status)
}

/// 名前ごとの接続の状態を並行に問い合わせる。締め切りまでに答えなかった接続は
/// `None`。
pub fn relay_statuses(
  names: List(Name(relay_connection.Msg)),
  deadline: task.Deadline,
) -> List(#(Name(relay_connection.Msg), Option(relay_connection.Status))) {
  let statuses = task.map_within(names, deadline, relay_connection.status)
  use name, status <- list.map2(names, statuses)
  #(name, option.from_result(status))
}

/// DB の `relays` の全行。読めなければ英語の理由を返す。管理 UI の Context が使う。
pub fn registered_relays(
  spec: Spec,
) -> Result(List(relay_store.Relay), String) {
  relay_store.list(store_connection(spec), db.default_timeouts)
  |> result.map_error(db.describe)
}

/// バンカーの接続プールへの名前つき接続。リレーの読み書きが共有する。
fn store_connection(spec: Spec) -> pog.Connection {
  pog.named_connection(spec.bunker.pool.pool_name)
}

/// `write` で DB の `relays` に書いてから、`change` で `relay_list` の一覧を変える。DB に
/// 書けなければ一覧を変えず、その失敗を `store_failure` で写す。一覧の変更を確かめられ
/// なければ `ConnectionsNotConfirmed`。
fn write_then_change(
  spec: Spec,
  write: fn(pog.Connection) -> Result(a, db.StoreError),
  change: fn(Spec) -> Result(Nil, relay_list.ChangeError),
) -> Result(Nil, admin.RelayChangeFailure) {
  use _written <- result.try(
    write(store_connection(spec))
    |> result.map_error(store_failure),
  )
  change(spec)
  |> result.replace_error(admin.ConnectionsNotConfirmed)
}

/// リレーを DB に登録してから接続を開く。DB に書けなければ接続を開かない。管理 UI の
/// Context が使う。
pub fn add_relay(
  spec: Spec,
  url: String,
  roles: relay_list.Roles,
) -> Result(Nil, admin.RelayChangeFailure) {
  write_then_change(
    spec,
    relay_store.insert(_, url, roles, db.default_timeouts),
    open_relay(_, url, roles),
  )
}

/// 用途を DB に書いてから接続の用途を変える。DB に書けなければ接続を変えない。管理 UI の
/// Context が使う。
pub fn update_relay_roles(
  spec: Spec,
  relay: relay_store.Relay,
  roles: relay_list.Roles,
) -> Result(Nil, admin.RelayChangeFailure) {
  write_then_change(
    spec,
    relay_store.update_roles(_, relay.id, roles, db.default_timeouts),
    change_relay_roles(_, relay.url, roles),
  )
}

/// 行を DB から消してから接続を閉じる。管理 UI の Context が使う。
pub fn delete_relay(
  spec: Spec,
  relay: relay_store.Relay,
) -> Result(Nil, admin.RelayChangeFailure) {
  write_then_change(
    spec,
    relay_store.delete(_, relay.id, db.default_timeouts),
    close_relay(_, relay.url),
  )
}

/// `db.StoreError` を管理 UI の `admin.RelayChangeFailure` に写す。
fn store_failure(error: db.StoreError) -> admin.RelayChangeFailure {
  case error {
    db.Duplicate -> admin.DuplicateRelay
    db.NotFound -> admin.UnregisteredRelay
    _ ->
      case db.may_have_been_written(error) {
        True -> admin.RelayMaybeSaved
        False -> admin.RelayNotSaved(db.describe(error))
      }
  }
}

/// DB の行ごとに、用途の状態を `relay_list` の項目から求める。行の順は `relays`
/// のままで、`entries` にだけある URL は出さない。使う用途は、その用途の接続が
/// あれば `status` の結果（締め切りまでに答えなければ `Unanswered`）、無ければ
/// 未接続にする。
pub fn merge_relay_rows(
  relays: List(relay_store.Relay),
  entries: List(relay_list.Entry),
  status: fn(Name(relay_connection.Msg)) -> Option(relay_connection.Status),
) -> List(dashboard.RelayRow) {
  use relay <- list.map(relays)
  let entry =
    list.find(entries, fn(entry) { entry.url == relay.url })
    |> option.from_result
  dashboard.RelayRow(
    id: relay.id,
    url: relay.url,
    monitor: role_status(
      relay_list.has_role(relay.roles, relay_list.Monitor),
      option.then(entry, fn(entry) { entry.monitor }),
      status,
    ),
    bunker: role_status(
      relay_list.has_role(relay.roles, relay_list.Bunker),
      option.then(entry, fn(entry) { entry.bunker }),
      status,
    ),
  )
}

/// 1 つの用途の状態。使っていなければ `Unused`、接続が締め切りまでに答えなければ
/// `Unanswered`。
fn role_status(
  used: Bool,
  connection: Option(Name(relay_connection.Msg)),
  status: fn(Name(relay_connection.Msg)) -> Option(relay_connection.Status),
) -> dashboard.RoleState {
  case used, connection {
    False, _ -> dashboard.Unused
    True, None -> dashboard.Reported(relay_connection.Disconnected)
    True, Some(name) ->
      case status(name) {
        Some(value) -> dashboard.Reported(value)
        None -> dashboard.Unanswered
      }
  }
}

/// URI のリレーが応答の発行先に現れたかを確かめる間隔。
const publisher_poll_interval_ms = 100

/// 解釈済みの `nostrconnect://` の（署名者, クライアント）に URI のリレーをバンカーで
/// 取り置いてそのリレーの接続を開かせ、どれかが応答の発行先になるのを待ってから、
/// セッションを開いて `connect` の応答を発行する。URI のリレーは `relays` テーブルに
/// 登録せず、開いたセッションが持つ。取り置きは結果にかかわらず最後に外す（セッション
/// が開けばそのリレーの接続はセッションのリレーとして残り、開けなければ閉じる）。
pub fn connect_nostrconnect(
  spec: Spec,
  request: nostrconnect.ConnectRequest,
  signer: String,
) -> Result(Nil, admin.NostrconnectFailure) {
  bunker.reserve_session_relays(
    spec.bunker.name,
    signer,
    request.client,
    request.relays,
  )
  let outcome = case
    await_publisher(
      spec,
      request.relays,
      nostrconnect.connect_wait_seconds * 1000,
    )
  {
    False -> Error(admin.RelayNotConnected)
    True ->
      bunker.open_client_session(
        spec.bunker.name,
        signer,
        request.client,
        request.perms,
        request.relays,
        request.secret,
      )
      |> result.map_error(admin.SessionNotOpened)
  }
  bunker.release_session_relays(spec.bunker.name, signer, request.client)
  outcome
}

/// URI のリレーの URL のどれかが応答の発行先に現れるまで待つ。取り置いたリレーの
/// 接続は、繋がると `SetPublisher` で発行先になる。応答は発行先として配られた
/// 送信関数から出ていくため、接続の状態ではなく発行先そのものを見る。アクターが
/// 答えなければ未到達として次の周期へ回す。残りが尽きたら `False`。
fn await_publisher(spec: Spec, urls: List(String), remaining_ms: Int) -> Bool {
  let reached = case bunker.publisher_urls(spec.bunker.name) {
    Some(publishers) -> list.any(urls, list.contains(publishers, _))
    None -> False
  }
  case reached, remaining_ms <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(publisher_poll_interval_ms)
      await_publisher(spec, urls, remaining_ms - publisher_poll_interval_ms)
    }
  }
}

/// Accounts 節の行。`relay_list` が応答しなければその理由を返し
/// （`Snapshot.accounts` の型に合わせる）、応答すればアカウントを得られない
/// ときにバンカーの理由を返す。アイコンの URL は、全行の署名者を 1 度に
/// `pictures` へ渡して引く。
pub fn account_rows(
  spec: Spec,
  pictures: fn(List(String)) -> Dict(String, String),
) -> Result(List(dashboard.AccountRow), String) {
  use entries <- result.try(relay_entries(spec))
  let relay_urls = relay_list.urls(entries, relay_list.Bunker)
  use listings <- result.map(bunker.accounts(spec.bunker.name))
  let found = pictures(list.map(listings, fn(listing) { listing.signer }))
  list.map(listings, account_row(relay_urls, found, _))
}

/// アカウント 1 件の表示行。接続 URI とカメラ用のコピー用の文字列は、全行に共通の
/// バンカーリレーの URL から組み立て、アイコンの URL は `found` から引く。
fn account_row(
  relay_urls: List(String),
  found: Dict(String, String),
  listing: bunker.Listing,
) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer: listing.signer,
    npub: listing.npub,
    label: listing.label,
    uri: connection_uri.bunker_uri(
      listing.signer,
      relay_urls,
      Some(listing.secret),
    ),
    auth_uri: connection_uri.bunker_uri(listing.signer, relay_urls, None),
    uri_camera_text: connection_uri.camera_copy_text(
      listing.signer,
      relay_urls,
      Some(listing.secret),
    ),
    auth_uri_camera_text: connection_uri.camera_copy_text(
      listing.signer,
      relay_urls,
      None,
    ),
    picture: dict.get(found, listing.signer) |> option.from_result,
  )
}

/// 直近の読み込みで飛ばされた行の表示行。読み込み前、読み直しの前、アクターが
/// 応答しないときは理由を返す。
pub fn skipped_rows(spec: Spec) -> Result(List(dashboard.SkippedRow), String) {
  bunker.skipped(spec.bunker.name) |> result.map(list.map(_, skipped_row))
}

/// 飛ばした行 1 件の表示行。npub は `pubkey` 列を 32 バイトの 16 進として読めたときだけ導き、
/// 読めない行（`MalformedPubkey` の行）では `None` にする。その行は識別を描かない。
fn skipped_row(row: vault.Skipped) -> dashboard.SkippedRow {
  let npub =
    hex.decode(row.pubkey)
    |> result.try(fn(bytes) {
      nip19.encode(bytes, nip19.Npub) |> result.replace_error(Nil)
    })
    |> option.from_result
  dashboard.SkippedRow(
    pubkey: row.pubkey,
    npub: npub,
    label: row.label,
    reason: row.reason,
  )
}

/// 承認待ちを管理 UI の行にする。失効までの残り秒は問い合わせた時点で求める。
pub fn pending_rows(pending: List(Pending)) -> List(dashboard.PendingRow) {
  let now = time.now_seconds()
  use entry <- list.map(pending)
  dashboard.PendingRow(
    token: entry.token,
    signer: entry.signer,
    client: entry.client,
    expires_in_seconds: entry.created_at + engine.pending_ttl_seconds - now,
    secret_mismatch: entry.secret_mismatch,
    perms: entry.perms,
  )
}

/// 承認済みセッションを管理 UI の行にする。
pub fn session_rows(sessions: List(Session)) -> List(dashboard.SessionRow) {
  use session <- list.map(sessions)
  dashboard.SessionRow(
    signer: session.signer,
    client: session.client,
    perms: session.perms,
    created_at: session.created_at,
    last_used_at: session.last_used_at,
  )
}

/// 接続 1 本ぶんのハンドラー。どれも第 1 引数に接続の URL を受け取る。`handle_event` は
/// 受信したイベントと保存済みイベントの終わり、`handle_ok` は発行したイベントへの OK、
/// `authenticator` は AUTH の受け口（応答しない接続は `None`）、`on_connect` と
/// `on_disconnect` は接続と切断の通知を受ける。
type ConnectionHandlers {
  ConnectionHandlers(
    handle_event: fn(String, Received) -> Nil,
    handle_ok: fn(String, Acknowledgement) -> Nil,
    authenticator: fn(String) -> Option(Authenticator),
    on_connect: fn(String, Socket) -> Nil,
    on_disconnect: fn(String) -> Nil,
  )
}

/// 何もしないハンドラー。AUTH には応答しない。用途ごとに要るものだけを
/// `ConnectionHandlers(..silent_handlers(), ...)` で差し替える。
fn silent_handlers() -> ConnectionHandlers {
  ConnectionHandlers(
    handle_event: fn(_relay_url, _received) { Nil },
    handle_ok: fn(_relay_url, _ack) { Nil },
    authenticator: fn(_relay_url) { None },
    on_connect: fn(_relay_url, _socket) { Nil },
    on_disconnect: fn(_relay_url) { Nil },
  )
}

/// 用途 `role` の接続を `relay_list` の `connections` factory の子として組む。
/// 購読の定義と `handlers` の各ハンドラーには、その接続の URL を渡す。テンプレートは
/// `Connection` を受け取るたびに URL から `Settings` を組み立てる閉包にし、
/// `relay_list.connections_child` へ渡す。
fn relay_connections_child(
  spec: Spec,
  factories: relay_list.Factories,
  role: relay_list.Role,
  subscriptions: fn(String) -> Subscriptions,
  handlers: ConnectionHandlers,
) -> ChildSpecification(
  factory_supervisor.Supervisor(
    relay_list.Connection,
    Subject(relay_connection.Msg),
  ),
) {
  relay_list.connections_child(
    spec.relay_list,
    factories,
    role,
    fn(connection: relay_list.Connection) {
      relay_connection.start(relay_connection.Settings(
        name: connection.name,
        relay: connection.url,
        connect: fn() {
          spec.open(
            connection.url,
            subscriptions(connection.url),
            handlers.handle_event(connection.url, _),
            handlers.handle_ok(connection.url, _),
            handlers.authenticator(connection.url),
          )
        },
        on_connect: handlers.on_connect(connection.url, _),
        on_disconnect: fn() { handlers.on_disconnect(connection.url) },
        reconnect_delay: spec.reconnect_delay,
        stable_after_ms: relay_connection.default_stable_after_ms,
      ))
    },
  )
}
