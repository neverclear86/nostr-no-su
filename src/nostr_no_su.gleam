import gleam/erlang/process.{type Name}
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/vault
import nostr_no_su/config.{type Config}
import nostr_no_su/log
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/plugins/console_logger
import nostr_no_su/relay_connection
import nostr_no_su/time
import pog

/// 起動処理そのものが出すログ行の接頭辞。
const log_prefix = "main"

/// 監視ディスパッチャーがリレー間の重複排除のために記憶する直近イベント id の
/// 件数（正確な上限は `dedup` を参照）。
const dedup_capacity = 4096

/// バンカーの購読が現在時刻からどれだけ遡るか。切断していた間に届いたリクエストを
/// 取りこぼさないための猶予。クライアントは数十秒で応答を諦めるため、これより古い
/// リクエストには待っている相手がいない。
const bunker_since_lookback_seconds = 60

/// `wss://` 接続が依存する `ssl` アプリケーションを起動する。
@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

/// 終了コード `status` で VM を直ちに止める。それまでに標準出力へ書いた行は書き出して
/// から止まる。`main` が返ると、生成されたエントリーポイントが終了コード 0 で止める
/// ので、失敗として終了するときはこれを使う。
@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

/// 起動時に組み立てたツリーの仕様と、その報告行。組み立てから出力を分けることで、
/// 何をどう報告するかが `main` の 1 か所に集まる。
type Startup {
  Startup(spec: app.Spec, notes: List(String))
}

/// 設定されたリレーとアカウントのスーパービジョンツリーを起動し、以降は待機
/// する。ここから先はプロセスの監視・再起動・再配線をすべてツリーが担う。
/// バンカーか管理 UI を起動できない設定なら、理由を 1 行出して終了コード 1 で終了する。
pub fn main() -> Nil {
  ensure_ssl_started()
  case startup(config.load()) {
    Error(reason) -> {
      log.println(log_prefix, "cannot start: " <> reason)
      halt(1)
    }
    Ok(started) -> {
      list.each(started.notes, io.println)
      // ツリーが起動しないのはバグか設定の不備なので、中途半端な状態で待機せず
      // クラッシュさせる。コンテナーの再起動はプロセスの終了で起き、終了コードは
      // 失敗を示す。
      let assert Ok(_started) = app.start(started.spec)
        as "supervision tree failed to start"
      process.sleep_forever()
    }
  }
}

/// 読み込んだ設定に対して動かすツリーと、その報告行。プロセス名はここで一度だけ
/// 生成して下へ渡すため、再起動したアクターは接続の送信先となる名前を再登録する。
/// 出力は行わず、報告する内容は文字列として返す。
/// バンカーか管理 UI を起動できない設定なら、プラグインの読み込みより前にその
/// 理由を返す。
///
/// 外部プラグインの読み込みは監視の有無に関わらず行う。読み込んだプラグインは
/// ルート直下の `plugins` サブツリーで動き、ダッシュボードにも状態が出る。
/// 監視が無効な構成（`RELAY_URL` が空）なら、配信されるイベントが無いだけである。
fn startup(loaded: Config) -> Result(Startup, String) {
  use #(bunker, bunker_notes) <- result.try(bunker_spec(loaded))
  use #(admin, admin_notes) <- result.map(admin_spec(loaded))
  let builtin = builtin_plugins()
  let #(external, plugin_notes) =
    plugin_loader.load_all(
      loaded.plugin_dir,
      list.map(builtin, fn(item) { item.name }),
      loaded.plugin_env,
      plugin.default_call_timeout_ms,
    )
  let specs = plugin_specs(list.append(builtin, external))
  let #(monitor, monitor_notes) = monitor_spec(loaded)
  Startup(
    spec: app.Spec(
      plugins: specs,
      monitor: monitor,
      bunker: bunker,
      admin: admin,
      open: app.open_websocket,
      reconnect_delay_ms: relay_connection.default_reconnect_delay_ms,
    ),
    notes: list.flatten([
      monitor_notes,
      plugin_notes,
      bunker_notes,
      admin_notes,
    ]),
  )
}

/// リレー URL ごとに接続 1 本ぶんの仕様を作る。
fn relays(relay_urls: List(String)) -> List(app.Relay) {
  use url <- list.map(relay_urls)
  app.Relay(name: process.new_name("nostr_no_su_relay"), url: url)
}

/// プラグインごとにランナープロセスの名前を作る。名前はここで 1 度だけ作り、
/// ディスパッチャーの宛先と管理 UI の問い合わせ先に共用する。再起動したランナー
/// は同じ名前を登録し直すので、どちらの配線もやり直す必要がない。
fn plugin_specs(plugins: List(Plugin)) -> List(app.PluginSpec) {
  use item <- list.map(plugins)
  app.PluginSpec(
    name: process.new_name("nostr_no_su_plugin"),
    plugin: item,
    limits: plugin_runner.default_limits,
  )
}

/// 設定されたリレーの監視サブツリー。監視対象がなければ None。
fn monitor_spec(loaded: Config) -> #(Option(app.Monitor), List(String)) {
  case loaded.relay_urls {
    [] -> #(None, [
      log.line(log_prefix, "no monitor relays configured; monitoring disabled"),
    ])
    relay_urls -> #(
      Some(
        app.Monitor(
          name: process.new_name("nostr_no_su_dedup"),
          dedup_capacity: dedup_capacity,
          relays: relays(relay_urls),
          subscriptions: fn() {
            Ok([#("nostr-no-su", config.to_filter(loaded))])
          },
        ),
      ),
      [log.line(log_prefix, "monitor relays: " <> describe(relay_urls))],
    )
  }
}

/// 本体に内蔵されたプラグイン。外部プラグインはローダーが返し、このリストの
/// 後ろに繋がれる。並び順が決めるのは読み込みと表示の順序だけで、実行は
/// プラグインごとの独立したランナーが行う。内蔵プラグインは子仕様を持たない
/// （`children: []`）。イベント保存は外部プラグイン `event_logger` の仕事に
/// なったので、ここには含まれない。
/// **内蔵プラグインは `plugin.load` を通らないので設定 map を受け取らない。**
/// その設定は従来どおり `config.gleam` が持つため、`PLUGIN_CONSOLE_LOGGER_*` の
/// ような変数を書いても誰も読まない。
fn builtin_plugins() -> List(Plugin) {
  [console_logger.new()]
}

/// 承認待ちの token から、クライアントへ渡す承認ページの URL を組み立てる関数。
/// 管理 UI の公開 URL に承認ページのパスを繋ぐだけで、パスの形を知っているのは
/// 管理 UI 側（`dashboard`）だけになる。管理 UI が無効なら承認フローも無効。
fn auth_url(loaded: Config) -> Option(fn(String) -> String) {
  use base <- option.map(config.auth_url_base(loaded))
  fn(token) { base <> dashboard.approve_path(token) }
}

/// バンカーサブツリーと、その報告行。アカウントストアの設定が揃わないか不正なら、
/// その理由を返す。アカウントはアクターが起動後にストアから読むので、ここでは
/// アカウントの件数を知らず、0 件でも起動する。
///
/// マスターキーはストアの操作のクロージャーにだけ捕捉され、ツリーの仕様の他の部分と
/// 管理 UI には渡らない。購読は接続と張り直しのたびに現在の署名者から組み立て直す
/// ため、`since` もその時点の現在時刻から決まる。署名者を問い合わせられなければ
/// 定義を得られなかったことにし、開いている購読を閉じない。
fn bunker_spec(loaded: Config) -> Result(#(app.Bunker, List(String)), String) {
  use #(pool, master_key) <- result.map(bunker_store(loaded))
  let name = process.new_name("nostr_no_su_bunker")
  #(
    app.Bunker(
      name: name,
      pool: pool,
      settings: bunker.Settings(
        store: account_store_operations(
          pool.pool_name,
          master_key,
          account_store.default_timeouts,
        ),
        auth_url: auth_url(loaded),
        retry_delay: bunker.default_retry_delay,
      ),
      relays: relays(loaded.bunker_relay_urls),
      subscriptions: fn() {
        bunker.signers(name)
        |> option.to_result(Nil)
        |> result.map(config.bunker_subscriptions(
          _,
          time.now_seconds() - bunker_since_lookback_seconds,
        ))
      },
    ),
    [
      log.line(
        log_prefix,
        "bunker relays: " <> describe(loaded.bunker_relay_urls),
      ),
    ],
  )
}

/// アカウントストアの操作。プールの名前とマスターキーはこのクロージャーにだけ
/// 捕捉される。失敗は値を含まない説明に写し、書き込みの失敗は書き込まれていることが
/// あるかどうかを区別する。削除は行が無いことを成功として扱う。
///
/// 追加の `AlreadyRegistered` は `bunker.AlreadyStored` に写す。バンカーはメモリに無い
/// 公開鍵にだけ追加を書き込むので、DB に行があるのは、DB がメモリより先行しているか、
/// 読み込みで飛ばされた行があることを意味し、バンカーはそれを読み直して確かめる。
///
/// 期限を受け取るのは、実際の DB を使う統合テストが負荷の高い環境でも収まる期限を
/// 渡せるようにするためである。本番は `account_store.default_timeouts` を渡す。
///
/// 読み込みが `SchemaTooNew` を返したら、再試行しても変わらないので、理由を 1 行
/// 出して VM を止める（`halt_if_schema_too_new`）。バンカーアクターには戻らない。
pub fn account_store_operations(
  pool: Name(pog.Message),
  master_key: vault.MasterKey,
  timeouts: account_store.Timeouts,
) -> bunker.Store {
  let db = pog.named_connection(pool)
  bunker.Store(
    load: fn() {
      account_store.load(pool, master_key, timeouts)
      |> halt_if_schema_too_new
      |> result.map_error(account_store.describe)
    },
    insert: fn(entry) {
      account_store.insert(db, master_key, entry, timeouts)
      |> result.map_error(fn(error) {
        case error {
          account_store.AlreadyRegistered ->
            bunker.AlreadyStored(account_store.describe(error))
          _ -> write_failure(error)
        }
      })
    },
    delete: fn(signer) {
      account_store.delete(db, signer, timeouts)
      |> account_store.deleted_or_absent
      |> result.map_error(write_failure)
    },
    update_secret: fn(signer, secret) {
      account_store.update_secret(db, master_key, signer, secret, timeouts)
      |> result.map_error(write_failure)
    },
    update_label: fn(signer, label) {
      account_store.update_label(db, signer, label, timeouts)
      |> result.map_error(write_failure)
    },
  )
}

/// 読み込みの結果が、DB のスキーマがこのビルドより新しいことを示していたら、
/// `cannot continue: <理由>` を 1 行出して終了コード 1 で VM を止める。古いビルドの
/// まま新しい版の DB を読み書きさせないためである。`halt` は戻らないので、それ以外の
/// 結果だけがそのまま返る。
fn halt_if_schema_too_new(
  loaded: Result(vault.Loaded, account_store.StoreError),
) -> Result(vault.Loaded, account_store.StoreError) {
  case loaded {
    Error(account_store.SchemaTooNew(..) as error) -> {
      log.println(
        log_prefix,
        "cannot continue: " <> account_store.describe(error),
      )
      halt(1)
      loaded
    }
    _ -> loaded
  }
}

/// 書き込みの失敗を、書き込まれていることがあるかどうかの区別つきでバンカーへ渡す形に
/// 写す。
fn write_failure(error: account_store.StoreError) -> bunker.WriteFailure {
  let reason = account_store.describe(error)
  case account_store.may_have_been_written(error) {
    True -> bunker.MaybeWritten(reason)
    False -> bunker.NotWritten(reason)
  }
}

/// アカウントストアの接続プールの設定とマスターキー。設定が揃わない、あるいは
/// `DATABASE_URL` を解釈できなければ理由を返す。理由は値を含まない。
fn bunker_store(
  loaded: Config,
) -> Result(#(pog.Config, vault.MasterKey), String) {
  case loaded.account_store {
    config.AccountStoreUnavailable(reason) -> Error(reason)
    config.AccountStore(database_url:, master_key:) ->
      account_store.pool_config(
        process.new_name("nostr_no_su_account_pool"),
        database_url,
      )
      |> result.map(fn(pool) { #(pool, master_key) })
  }
}

/// 管理 UI の仕様と、その報告行。`ADMIN_PORT` が空なら黙って無効にし、値が不正な
/// ときは理由を報告してから無効にする。待ち受けるのに `ADMIN_PASSWORD` が無ければ、
/// その理由を返す。
fn admin_spec(
  loaded: Config,
) -> Result(#(Option(app.Admin), List(String)), String) {
  case loaded.admin_ui {
    config.MissingPassword(reason) -> Error(reason)
    config.Disabled ->
      Ok(
        #(None, [
          log.line(admin.log_prefix, "ADMIN_PORT is empty; admin UI disabled"),
        ]),
      )
    config.Invalid(reason) ->
      Ok(#(None, [log.line(admin.log_prefix, reason <> "; admin UI disabled")]))
    config.Listen(port:, password:) ->
      Ok(#(Some(app.Admin(bind: loaded.admin_bind, port:, password:)), []))
  }
}

/// 起動ログ用にリレー一覧を文字列化する。
fn describe(relay_urls: List(String)) -> String {
  case relay_urls {
    [] -> "(none)"
    urls -> string.join(urls, ", ")
  }
}
