//// スーパービジョンツリー。
////
//// ```
//// root (one_for_one)
//// |-- relay_list   (worker)      : 実行時のリレーの一覧と、用途ごとの
//// |                                connections (factory) の子の起動・停止
//// |-- plugins      (one_for_one): プラグインごとのランナー
//// |   |-- children(<plugin>) (one_for_one / Temporary): 子仕様を持つプラグインだけ
//// |   `-- runner(<plugin>)   (worker  / Permanent)
//// |-- bunker       (rest_for_one): アカウントストアの接続プール、ロックのプール、
//// |                                バンカーアクター、次に connections (factory)
//// |-- monitor      (rest_for_one): 重複排除ディスパッチャー、
//// |                                connections (factory)、再開点の保存
//// `-- admin        (mist)        : 管理 UI の HTTP サーバー
//// ```
////
//// `connections (factory, 5/10)` は用途（監視・バンカー）ごとの
//// `factory_supervisor` で、その下にリレーの数だけ `relay_connection` が並ぶ。
//// 静的な `relay_connection × N` ではなく factory にしているのは、`relay_list`
//// が実行時に子を増減できるようにするためである（下の「実行時のリレーの増減」を
//// 参照）。
////
//// 各サブツリーを `rest_for_one` にしているのは、先頭のアクターが再起動した際に
//// 後続の接続もまとめて落とすため。接続は復帰の過程で購読を張り直し publisher を
//// 登録し直すので、再起動したバンカーが再び生きたソケットに配線される。アクター
//// には名前が付いているため、接続は名前で宛先を指定でき、死んだプロセスの
//// subject を握り続けることがない。
////
//// **アカウントの変更はバンカーアクターを再起動しない。** 再起動すると
//// `rest_for_one` で接続も落ち、インメモリのセッションが消えるためである。署名者の
//// 集合が変わったら、アクターは `relay_list` に `ResubscribeAll` を送り、
//// `relay_list` が現在の全接続へ購読の張り直しを依頼し、各接続アクターが生きた
//// ソケットへ転送する。接続アクターを経由するので、接続の途中や再接続を待って
//// いる間の依頼も、変更後の署名者で購読することになる。
////
//// **アカウントストアの接続プールはバンカーのサブツリーの先頭に置く。** pgo は
//// チェックアウト先のプール名が未登録だと、呼び出し側のプロセスを `noproc` で
//// exit させる。プールを先頭に置けば、バンカーアクターはプールが登録された後に
//// しか起動せず、プールが落ちればアクターも止められてから起動し直すので、未登録の
//// プールを叩く状況が構造上生じない。代償はプールの再起動がバンカーアクターの
//// 再起動（インメモリのセッションの消失）を伴うことだが、DB の停止や再起動では
//// プールのプロセスは死なない（pgo が再接続を内部に閉じ込め、クエリーは値で
//// 失敗する）ので、これが起きるのはプール自体のバグか外部からの kill に限られる。
////
//// DB の障害がルートの `restart_tolerance(3, 60)` を消費しないのは、DB の停止が
//// プロセスの死にならず、バンカーアクターがストアの失敗で落ちず（再試行を予約して
//// ログを 1 行出すだけ）、起動時に DB を待たない（読み込みは initialiser が積む
//// メッセージで行う）からである。監視とプラグインはバンカーのサブツリーと兄弟
//// なので、DB の障害に巻き込まれない。
////
//// 監視の購読の評価はバンカーと DB（再開点）への問い合わせに依るが、応答が無ければ
//// 開いている購読を変えない（`relay_client.sync`）。再開点の保存はディスパッチャー
//// とは別のアクターが行う。
////
//// **イベント保存はこのツリーには無い。** 外部プラグイン `event_logger` が
//// `plugin_children/1` で申告する子として `plugins` サブツリーの下で動く。
////
//// 管理 UI は他のどれにも依存しないのでルート直下に置く。状態は名前付きアクター
//// への問い合わせで読むため、UI が再起動しても、問い合わせ先が再起動しても、
//// 互いの配線をやり直す必要がない。
////
//// プラグインのランナーは監視サブツリーの中ではなくルート直下に置く。監視と
//// 独立に、読み込んだプラグインをツリーに載せて管理 UI に状態を見せられるように
//// するためで、ディスパッチャーが再起動してもランナーは巻き添えにならない。
//// プラグイン同士は独立なのでこのサブツリーは `one_for_one` にする。
//// **ルートの子は `relay_list` をすべてより先に、`plugins` を `monitor` より
//// 先に追加すること。** `relay_list` が後だと、起動直後に `connections` の
//// factory が送る `Repopulate` が未登録の名前へ送られて捨てられ、初期のリレーが
//// 起動されない。`plugins` が後だとディスパッチャーが未登録のランナー名へ送り、
//// 起動直後のイベントを取りこぼす。
//// **`bunker` も `monitor` より先に追加すること。** 逆順だと、監視の接続の最初の
//// 購読の評価がバンカーの名前の登録より先に走り、定義を得られずに再試行を待つ。
////
//// ## 実行時のリレーの増減
////
//// `relay_list` は用途（監視・バンカー）ごとの接続の一覧を加えた順に持ち、
//// `open_relay` / `close_relay` / `change_relay_roles` による変更と、
//// `connections` の factory の子の起動・停止を、自分のハンドラーで直列に行う
//// （同時に届く変更の重なりを避けるため）。factory は `rest_for_one` の再起動で
//// 動的な子をすべて失うため、`relay_list` は再起動後に届く `Repopulate` で
//// 一覧から起動し直す。止めた接続（バンカーの用途）は `on_disconnect` を経て
//// `RemovePublisher` が送られ、バンカーの送信先から外れる。署名者の変化による
//// 張り直しは、`relay_list` の `ResubscribeAll` が現在の全接続へ送る。詳細と
//// 既知の窓は `relay_list` のモジュール doc を参照。
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
////   プラグインはランナーが生き続け、イベント処理関数の連続失敗で
////   `disabled: <理由>` になってダッシュボードに残る。**素直に劣化する。**
//// - **起動時の失敗はアプリを止めない。** `Temporary` が効くのは再起動のときだけ
////   なので、初回起動の失敗は空のスーパーバイザーで吸収する
////   （`start_plugin_children`）。失敗の理由は `plugin_children` が子ごとに出す
////   1 行に出る。

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
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine.{type Pending}
import nostr_no_su/dedup
import nostr_no_su/dedup/resume_saver
import nostr_no_su/log
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Verified}
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugin_runner
import nostr_no_su/relay_client.{
  type Acknowledgement, type Authenticator, type Subscriptions,
}
import nostr_no_su/relay_connection.{type Socket, Socket}
import nostr_no_su/relay_list
import nostr_no_su/time
import pog

/// リレー接続の開き方。本番では `open_websocket`、テストでは偽ソケットを使い、
/// ネットワークなしでもツリー全体を動かせるようにする。ハンドラーが受け取るのは
/// 接続のプロセスで id と署名を確かめたイベントと、発行したイベントへの OK
/// （受理・拒否とも）である。AUTH の受け口（応答しない接続は `None`）も渡す。
pub type Open =
  fn(
    String,
    Subscriptions,
    fn(Verified) -> Nil,
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
/// ディスパッチャーと、そこへイベントを流し込むリレー群からなる。`relays` は
/// 起動時に開くリレー（`relay_list` の初期値）で、実行時の増減には
/// `open_relay` などを使う。`subscriptions` はリレー URL からそのリレーの購読の
/// 定義を返す。`save_resume` は再開点を小さくせずに保存する操作で、
/// `resume_saver` が使う。`excludes_kind` が真を返す kind のイベントはプラグイン
/// へ渡さない。
pub type Monitor {
  Monitor(
    name: Name(dedup.Msg),
    dedup_capacity: Int,
    relays: List(relay_list.Connection),
    subscriptions: fn(String) -> Subscriptions,
    save_resume: fn(List(#(String, Int))) -> Result(Nil, String),
    excludes_kind: fn(Int) -> Bool,
  )
}

/// バンカーサブツリー。アカウントストアの接続プールと、NIP-46 アクターと、それが
/// 待ち受け・応答するリレー群。`pool` はパスワードを含みうるので、表示やログに
/// 入れないこと。`lock_pool` は同じ DB に 1 インスタンスだけを許すロック専用の
/// 1 本のプール。`pool` と同じくパスワードを含みうる。`relays` は起動時に開く
/// リレー（`relay_list` の初期値）で、実行時の増減には `open_relay` などを使う。
pub type Bunker {
  Bunker(
    name: Name(bunker.Msg),
    pool: pog.Config,
    lock_pool: pog.Config,
    settings: bunker.Settings,
    relays: List(relay_list.Connection),
    subscriptions: Subscriptions,
  )
}

/// 管理 UI。設定から決まるもの（bind アドレス、ポート、パスワード）だけを持ち、
/// 表示する状態はツリーの他の仕様から導く。
pub type Admin {
  Admin(bind: String, port: Int, password: String)
}

/// 動かすプラグインとバンカー、監視と管理 UI を動かすかどうか、接続をどう開くか、
/// 接続の再接続の待ち時間、実行時のリレーの一覧を持つ `relay_list` の名前。
pub type Spec {
  Spec(
    plugins: List(PluginSpec),
    monitor: Monitor,
    bunker: Bunker,
    admin: Option(Admin),
    open: Open,
    reconnect_delay: backoff.Backoff,
    relay_list: Name(relay_list.Msg),
  )
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
    )
  supervisor.new(supervisor.OneForOne)
  // サブツリーより意図的に厳しく、期間も長く取る。再起動を諦め続けるサブツリー
  // は復旧不能とみなし、ここでループせず終了することで再起動をコンテナーの
  // 再起動ポリシーに委ねる。
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  // relay_list はすべてより先に登録する。逆順だと connections の factory が
  // 起動直後に送る Repopulate が未登録の名前へ送られて捨てられる。
  |> supervisor.add(relay_list.supervised(
    spec.relay_list,
    relay_list.initial(spec.monitor.relays, spec.bunker.relays),
    factories,
  ))
  // ランナーはディスパッチャーより先に登録しておく。逆順だと起動直後のイベントが
  // 未登録の名前へ送られて届かない（件数はディスパッチャーがログに出す）。
  |> add_plugins(spec.plugins)
  // バンカーは監視より先に起動する。監視の接続が購読を組み立てるために送る
  // `GetSigners` を、バンカーの名前の登録と最初の読み込みの後に処理させるため。
  |> supervisor.add(
    supervisor.supervised(bunker_tree(spec, spec.bunker, factories)),
  )
  |> supervisor.add(
    supervisor.supervised(monitor_tree(spec, spec.monitor, factories)),
  )
  |> add_child(spec.admin, admin_child(spec, _))
  |> supervisor.start
}

/// リレーへの実際の WebSocket 接続を開き、接続アクターが監視と送信に使う
/// ソケットとして表現する。
pub fn open_websocket(
  url: String,
  subscriptions: Subscriptions,
  handle_event: fn(Verified) -> Nil,
  handle_ok: fn(Acknowledgement) -> Nil,
  authenticator: Option(Authenticator),
) -> Result(Socket, String) {
  use connection <- result.try(relay_client.start(
    url,
    subscriptions,
    handle_event,
    handle_ok,
    authenticator,
    relay_client.subscription_retry_delay,
    relay_client.keepalive_interval_ms,
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
/// 出す 1 行と、BEAM の supervisor report にある。
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
      supervisor.start(plugin_children_supervisor())
    }
  }
}

/// プラグインのサブツリーのスーパーバイザー。
fn plugins_supervisor() -> Builder {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 10)
}

/// ディスパッチャーが送る宛先の初期値。名前はツリーの起動をまたいで変わらない
/// ので、ディスパッチャーが再起動してもこの値から始めればよい。
fn plugin_targets(specs: List(PluginSpec)) -> List(plugin_runner.Target) {
  use spec <- list.map(specs)
  plugin_runner.target(spec.plugin.name, spec.name)
}

/// 監視サブツリー。ディスパッチャー、そこへイベントを流し込む接続群の
/// `connections` factory、再開点を保存するアクターの順に置く。保存のアクターを
/// 末尾に置くのは、その異常終了で接続を落とさないためである。
fn monitor_tree(
  spec: Spec,
  config: Monitor,
  factories: relay_list.Factories,
) -> Builder {
  subtree()
  |> supervisor.add(dedup.supervised(
    config.name,
    plugin_targets(spec.plugins),
    plugin_runner.dispatch,
    config.dedup_capacity,
  ))
  |> supervisor.add(
    relay_connections_child(
      spec,
      factories,
      relay_list.Monitor,
      config.subscriptions,
      monitor_handler(config.name, config.excludes_kind),
      fn(_relay_url, _ack) { Nil },
      fn(_relay_url) { None },
      fn(_relay_url, _socket) { Nil },
      fn(_relay_url) { Nil },
    ),
  )
  |> supervisor.add(resume_saver.supervised(
    config.name,
    config.save_resume,
    resume_saver.default_interval_ms,
  ))
}

/// 監視接続が受信したイベントをディスパッチャーへ渡すハンドラー。`excludes_kind`
/// が真の kind のイベントはここで落とす。監視とバンカーが同じリレーを使うと
/// バンカーの応答（kind 24133）も監視の購読に届くので、呼び出し側はそれを含む
/// 述語を渡す。
fn monitor_handler(
  name: Name(dedup.Msg),
  excludes_kind: fn(Int) -> Bool,
) -> fn(String, Verified) -> Nil {
  fn(relay_url: String, verified: Verified) {
    let incoming = event.verified_event(verified)
    case excludes_kind(incoming.kind) {
      True -> Nil
      False -> named.send(name, dedup.Incoming(relay_url, incoming))
    }
  }
}

/// バンカーサブツリー。接続プール、ロックのプール、アクター、それが応答に使う
/// 接続群の `connections` factory の順に置く。アクターはプールが登録された後に
/// 起動する必要があり（冒頭の doc を参照）、各接続はアクターに publisher を
/// 登録するため、アクターと一緒に再起動する必要がある。アクターが署名者の変化で
/// 依頼する購読の張り直しは、`relay_list` へ送るだけで待たない（`ResubscribeAll`
/// が監視とバンカーの現在の全接続へ転送する）。`rest_for_one` なので、ロックの
/// プールが再起動するとアクターと接続も再起動し、アクターの読み込みが
/// advisory lock を取り直す。接続が受けた AUTH はアクターへの問い合わせで応答
/// する。
fn bunker_tree(
  spec: Spec,
  config: Bunker,
  factories: relay_list.Factories,
) -> Builder {
  subtree()
  |> supervisor.add(pog.supervised(config.pool))
  |> supervisor.add(pog.supervised(config.lock_pool))
  |> supervisor.add(
    bunker.supervised(config.name, config.settings, fn() {
      relay_list.resubscribe_all(spec.relay_list)
    }),
  )
  |> supervisor.add(
    relay_connections_child(
      spec,
      factories,
      relay_list.Bunker,
      fn(_relay_url) { config.subscriptions },
      fn(_relay_url, incoming) {
        named.send(config.name, bunker.Incoming(incoming))
      },
      fn(relay_url, ack) {
        named.send(config.name, bunker.Acknowledged(relay_url, ack))
      },
      fn(relay_url) { Some(bunker.authenticate(config.name, relay_url, _)) },
      fn(relay_url, socket: Socket) {
        named.send(config.name, bunker.SetPublisher(relay_url, socket.publish))
      },
      fn(relay_url) {
        named.send(config.name, bunker.RemovePublisher(relay_url))
      },
    ),
  )
}

/// 管理 UI。表示する状態は、ツリーの他の仕様から名前を引いて問い合わせる関数
/// として Context に渡す。
fn admin_child(spec: Spec, config: Admin) -> ChildSpecification(Supervisor) {
  let bunker_name = spec.bunker.name
  admin.supervised(
    config.bind,
    config.port,
    admin.Context(
      password: config.password,
      accounts: fn() { account_rows(spec) },
      add_account: fn(added, label) { add_account(spec, added, label) },
      remove_account: bunker.remove_account(bunker_name, _),
      rotate_secret: bunker.rotate_secret(bunker_name, _),
      update_label: fn(signer, label) {
        bunker.update_label(bunker_name, signer, label)
      },
      nsec: bunker.nsec(bunker_name, _),
      plugins: fn() { plugin_rows(spec.plugins) },
      reenable_plugin: reenable_plugin(spec.plugins, _),
      relays: fn() { relay_statuses(spec) },
      sessions: fn() { bunker.sessions(bunker_name) },
      revoke: fn(signer, client) { bunker.revoke(bunker_name, signer, client) },
      pending: fn() { pending_rows(bunker.pending(bunker_name)) },
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

/// リレー 1 件の接続を開き、起動の依頼を終えてから返す。#125 はこれでバンカーの
/// リレーを足す。
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

/// プラグインごとの表示行。状態は各ランナーへ問い合わせて取る。
fn plugin_rows(specs: List(PluginSpec)) -> List(dashboard.PluginRow) {
  use spec <- list.map(specs)
  dashboard.PluginRow(
    name: spec.plugin.name,
    status: plugin_runner.status(spec.name),
  )
}

/// 管理 UI の再有効化。名前でランナーを引き、応答を待つ。名前で引いてよいのは、
/// 読み込みが同名のプラグインを 2 つ目以降で捨てるためである
/// （`plugin_loader.gleam` の重複検査。同梱のプラグイン名も `reserved` として
/// 同じ検査に入る）。
pub fn reenable_plugin(
  specs: List(PluginSpec),
  plugin: String,
) -> Result(Nil, admin.ReenableFailure) {
  use spec <- result.try(
    list.find(specs, fn(spec) { spec.plugin.name == plugin })
    |> result.replace_error(admin.PluginNotFound("plugin not found")),
  )
  plugin_runner.request_reenable(spec.name)
  |> option.to_result(admin.PluginNotAnswered("plugin runner did not answer"))
}

/// 監視・バンカー両サブツリーのリレー接続の現在の状態。`relay_list` は 1 回だけ
/// 引き、監視、次にバンカーの接続の順で並べる。応答が無ければ両方とも空にする
/// （`architecture.md` の「問い合わせが失敗したときはその項目だけ」と同じ
/// 扱い）。
pub fn relay_statuses(spec: Spec) -> List(dashboard.RelayRow) {
  case relay_list.entries(spec.relay_list) {
    Error(Nil) -> []
    Ok(entries) ->
      list.append(
        statuses(
          dashboard.MonitorRelay,
          relay_list.connections(entries, relay_list.Monitor),
        ),
        statuses(
          dashboard.BunkerRelay,
          relay_list.connections(entries, relay_list.Bunker),
        ),
      )
  }
}

/// 指定した用途の接続それぞれについて、接続アクターに状態を問い合わせる。
/// 逐次に問い合わせるため待ち時間はリレー数ぶん積み上がるが、接続アクターが
/// ループをブロックするのは `connect` の実行中だけで、その上限は `relay_client`
/// の connect タイムアウト（3 秒）である。`relay_connection` の問い合わせ
/// タイムアウト（5 秒）はそれを包む安全網であって通常の待ち時間ではない。数本の
/// リレーが同時にハンドシェイク中でも管理 UI の表示が数秒遅れるだけなので、
/// 並列化して部分的な結果を扱う複雑さは引き合わない。
fn statuses(
  role: dashboard.Role,
  connections: List(relay_list.Connection),
) -> List(dashboard.RelayRow) {
  use connection <- list.map(connections)
  dashboard.RelayRow(
    role: role,
    url: connection.url,
    status: relay_connection.status(connection.name),
  )
}

/// Accounts 節の行。`relay_list` が応答しなければその理由を返し
/// （`Snapshot.accounts` の型に合わせる）、応答すればアカウントを得られない
/// ときにバンカーの理由を返す。
pub fn account_rows(spec: Spec) -> Result(List(dashboard.AccountRow), String) {
  use entries <- result.try(
    relay_list.entries(spec.relay_list)
    |> result.replace_error("relay list did not answer"),
  )
  let relay_urls = relay_list.urls(entries, relay_list.Bunker)
  bunker.accounts(spec.bunker.name)
  |> result.map(list.map(_, account_row(relay_urls, _)))
}

/// アカウント 1 件の表示行。接続 URI は、全行に共通のバンカーリレーの URL から
/// 組み立てる。
fn account_row(
  relay_urls: List(String),
  listing: bunker.Listing,
) -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer: listing.signer,
    npub: listing.npub,
    label: listing.label,
    uri: account.bunker_uri(listing.signer, relay_urls, Some(listing.secret)),
    auth_uri: account.bunker_uri(listing.signer, relay_urls, None),
  )
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

/// サブツリーのスーパーバイザー。不正なイベント 1 件で先頭のアクターと後続の
/// 接続がまとめて落ちうるため、許容する再起動の頻度は多めに取ってある。リレーの
/// 停止は接続アクター自身が処理するので、そもそも再起動にはならない。
fn subtree() -> Builder {
  supervisor.new(supervisor.RestForOne)
  |> supervisor.restart_tolerance(intensity: 5, period: 10)
}

/// 用途 `role` の接続を `relay_list` の `connections` factory の子として組む。
/// 購読の定義、受信したイベントのハンドラー、発行した応答への OK のハンドラー、
/// AUTH の受け口、接続・切断の通知には、その接続の URL を渡す。テンプレートは
/// `Connection` を受け取るたびに URL から `Settings` を組み立てる閉包にし、
/// `relay_list.connections_child` へ渡す。
fn relay_connections_child(
  spec: Spec,
  factories: relay_list.Factories,
  role: relay_list.Role,
  subscriptions: fn(String) -> Subscriptions,
  handle_event: fn(String, Verified) -> Nil,
  handle_ok: fn(String, Acknowledgement) -> Nil,
  authenticator: fn(String) -> Option(Authenticator),
  on_connect: fn(String, Socket) -> Nil,
  on_disconnect: fn(String) -> Nil,
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
        relay: relay_client.label(connection.url),
        connect: fn() {
          spec.open(
            connection.url,
            subscriptions(connection.url),
            handle_event(connection.url, _),
            handle_ok(connection.url, _),
            authenticator(connection.url),
          )
        },
        on_connect: on_connect(connection.url, _),
        on_disconnect: fn() { on_disconnect(connection.url) },
        reconnect_delay: spec.reconnect_delay,
      ))
    },
  )
}
