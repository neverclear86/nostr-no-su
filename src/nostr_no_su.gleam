import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/config.{type Config}
import nostr_no_su/log
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/plugins/console_logger
import nostr_no_su/plugins/event_logger
import nostr_no_su/random
import nostr_no_su/relay_connection
import nostr_no_su/time
import pog

/// 起動処理そのものが出すログ行の接頭辞。
const log_prefix = "main"

/// 監視ディスパッチャーがリレー間の重複排除のために記憶する直近イベント id の
/// 件数（正確な上限は `dedup` を参照）。
const dedup_capacity = 4096

/// 生成する接続シークレットと管理 UI パスワードのバイト数。
const random_bytes = 16

/// バンカーの購読が現在時刻からどれだけ遡るか。切断していた間に届いたリクエストを
/// 取りこぼさないための猶予。クライアントは数十秒で応答を諦めるため、これより古い
/// リクエストには待っている相手がいない。
const bunker_since_lookback_seconds = 60

/// `wss://` 接続が依存する `ssl` アプリケーションを起動する。
@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

/// 起動時に組み立てたツリーの仕様と、その報告行。組み立てから出力を分けることで、
/// 何をどう報告するかが `main` の 1 か所に集まる。
type Startup {
  Startup(spec: app.Spec, notes: List(String))
}

/// 設定されたリレーとアカウントのスーパービジョンツリーを起動し、以降は待機
/// する。ここから先はプロセスの監視・再起動・再配線をすべてツリーが担う。
pub fn main() -> Nil {
  ensure_ssl_started()
  let started = startup(config.load())
  list.each(started.notes, io.println)
  // ツリーが起動しないのはバグか設定の不備なので、中途半端な状態で待機せず
  // クラッシュさせる。コンテナーに再起動を促すのは終了コードである。
  let assert Ok(_started) = app.start(started.spec)
    as "supervision tree failed to start"
  process.sleep_forever()
}

/// 読み込んだ設定に対して動かすツリーと、その報告行。プロセス名はここで一度だけ
/// 生成して下へ渡すため、再起動したアクターは接続の送信先となる名前を再登録する。
/// 出力は行わず、報告する内容は文字列として返す。
///
/// 外部プラグインの読み込みは監視の有無に関わらず行う。読み込んだプラグインは
/// ルート直下の `plugins` サブツリーで動き、ダッシュボードにも状態が出る。
/// 監視が無効な構成（`RELAY_URL` が空）なら、配信されるイベントが無いだけである。
fn startup(loaded: Config) -> Startup {
  let #(logger, logger_notes) = event_logger_spec(loaded)
  let builtin = builtin_plugins(logger)
  let #(external, plugin_notes) =
    plugin_loader.load_all(
      loaded.plugin_dir,
      list.map(builtin, fn(item) { item.name }),
      loaded.plugin_env,
    )
  let specs = plugin_specs(list.append(builtin, external))
  let #(monitor, monitor_notes) = monitor_spec(loaded)
  let #(accounts, account_notes) = load_accounts(loaded)
  let admin_accounts = dashboard_accounts(loaded, accounts)
  let #(bunker, bunker_notes) = bunker_spec(loaded, accounts, auth_url(loaded))
  let #(admin, admin_notes) = admin_spec(loaded, admin_accounts)
  Startup(
    spec: app.Spec(
      plugins: specs,
      monitor: monitor,
      bunker: bunker,
      event_logger: logger,
      admin: admin,
      open: app.open_websocket,
      reconnect_delay_ms: relay_connection.default_reconnect_delay_ms,
    ),
    notes: list.flatten([
      monitor_notes,
      plugin_notes,
      logger_notes,
      account_notes,
      bunker_notes,
      uri_notes(admin_accounts),
      admin_notes,
    ]),
  )
}

/// 接続 URI の報告。`bunker://` URI は secret を含むため、起動ログと認証済み
/// ページ以外に出してはならない。
fn uri_notes(accounts: List(dashboard.AccountRow)) -> List(String) {
  use account <- list.map(accounts)
  log.line(bunker.log_prefix, account.uri)
}

/// リレー URL ごとに接続 1 本ぶんの仕様を作る。
fn relays(relay_urls: List(String)) -> List(app.Relay) {
  use url <- list.map(relay_urls)
  app.Relay(name: process.new_name("nostr_no_su_relay"), url: url)
}

/// イベント保存サブツリーの仕様。`DATABASE_URL` が未設定、あるいは解釈できない
/// ときは保存を無効にし、監視は従来どおり動かす。
fn event_logger_spec(
  loaded: Config,
) -> #(Option(app.EventLogger), List(String)) {
  case loaded.database_url {
    None -> #(None, [
      log.line(
        event_logger.log_prefix,
        "no DATABASE_URL set; event storage disabled",
      ),
    ])
    Some(database_url) ->
      case
        pog.url_config(
          process.new_name("nostr_no_su_event_logger_pool"),
          database_url,
        )
      {
        Error(Nil) -> #(None, [
          log.line(
            event_logger.log_prefix,
            "DATABASE_URL is not a valid postgres URL; event storage disabled",
          ),
        ])
        Ok(pool_config) -> #(
          Some(app.EventLogger(
            name: process.new_name("nostr_no_su_event_logger"),
            // 書き込むのは保存アクター 1 つだけで逐次実行なので、接続は少なく
            // 保つ。既定の 10 本は DB 側の接続枠と idle ping を無駄に使う。
            pool_config: pog.pool_size(pool_config, 2),
          )),
          [],
        )
      }
  }
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
          subscriptions: fn() { [#("nostr-no-su", config.to_filter(loaded))] },
        ),
      ),
      [log.line(log_prefix, "monitor relays: " <> describe(relay_urls))],
    )
  }
}

/// 本体に内蔵されたプラグイン。保存が有効なときだけイベントロガーを足す。
/// ロガーはアクターを名前で参照するので、アクターより先に組み立ててよい。
/// 外部プラグインはローダーが返し、このリストの後ろに繋がれる。並び順が決めるのは
/// 読み込みと表示の順序だけで、実行はプラグインごとの独立したランナーが行う。
/// 内蔵プラグインは子仕様を持たない（`children: []`）。イベント保存の接続プール
/// はプラグインの子ではなく、ルート直下の専用サブツリーで動く。
/// **内蔵プラグインは `plugin.load` を通らないので設定 map を受け取らない。**
/// その設定は従来どおり `config.gleam` が持つため、`PLUGIN_CONSOLE_LOGGER_*` の
/// ような変数を書いても誰も読まない。
fn builtin_plugins(logger: Option(app.EventLogger)) -> List(Plugin) {
  case logger {
    None -> [console_logger.new()]
    Some(logger) -> [console_logger.new(), event_logger.new(logger.name)]
  }
}

/// 設定されたアカウントと、それぞれの接続シークレット。鍵を読めないときは理由を
/// 報告して空を返し、バンカーなしの監視のみで動かす。
fn load_accounts(loaded: Config) -> #(List(#(Account, String)), List(String)) {
  case account.load_all(loaded.account_keys) {
    Error(reason) -> #([], [
      log.line(bunker.log_prefix, "disabled: " <> reason),
    ])
    Ok([]) -> #([], [
      log.line(bunker.log_prefix, "no ACCOUNT_KEYS set; monitor-only mode"),
    ])
    Ok(accounts) -> #(
      list.map(accounts, fn(account) { #(account, secret_for(loaded)) }),
      [],
    )
  }
}

/// 管理 UI に出すアカウント一覧。
fn dashboard_accounts(
  loaded: Config,
  accounts: List(#(Account, String)),
) -> List(dashboard.AccountRow) {
  use pair <- list.map(accounts)
  dashboard.AccountRow(
    signer: { pair.0 }.pubkey_hex,
    uri: account.bunker_uri(pair.0, loaded.bunker_relay_urls, Some(pair.1)),
    auth_uri: account.bunker_uri(pair.0, loaded.bunker_relay_urls, None),
  )
}

/// 承認待ちの token から、クライアントへ渡す承認ページの URL を組み立てる関数。
/// 管理 UI の公開 URL に承認ページのパスを繋ぐだけで、パスの形を知っているのは
/// 管理 UI 側（`dashboard`）だけになる。管理 UI が無効なら承認フローも無効。
fn auth_url(loaded: Config) -> Option(fn(String) -> String) {
  use base <- option.map(config.auth_url_base(loaded))
  fn(token) { base <> dashboard.approve_path(token) }
}

/// 設定されたアカウントのバンカーサブツリー。利用できるアカウントがなければ
/// 監視のみで動作する。購読は接続のたびに組み立て直すため、`since` は接続時点の
/// 現在時刻から決まる。
fn bunker_spec(
  loaded: Config,
  accounts: List(#(Account, String)),
  auth_url: Option(fn(String) -> String),
) -> #(Option(app.Bunker), List(String)) {
  case accounts {
    // 無効にした理由は `load_accounts` が報告済み。
    [] -> #(None, [])
    accounts -> {
      let signer_pubkeys =
        list.map(accounts, fn(pair) { { pair.0 }.pubkey_hex })
      #(
        Some(
          app.Bunker(
            name: process.new_name("nostr_no_su_bunker"),
            engine: engine.new(accounts, auth_url),
            relays: relays(loaded.bunker_relay_urls),
            subscriptions: fn() {
              [
                #(
                  "bunker",
                  config.bunker_filter(
                    signer_pubkeys,
                    time.now_seconds() - bunker_since_lookback_seconds,
                  ),
                ),
              ]
            },
          ),
        ),
        [
          log.line(
            log_prefix,
            "bunker relays: " <> describe(loaded.bunker_relay_urls),
          ),
        ],
      )
    }
  }
}

/// 管理 UI の仕様。`ADMIN_PORT` が空なら黙って無効にし、値が不正なときは理由を
/// 報告してから無効にする。
fn admin_spec(
  loaded: Config,
  accounts: List(dashboard.AccountRow),
) -> #(Option(app.Admin), List(String)) {
  case loaded.admin_port {
    config.Disabled -> #(None, [
      log.line(admin.log_prefix, "ADMIN_PORT is empty; admin UI disabled"),
    ])
    config.Invalid(reason) -> #(None, [
      log.line(admin.log_prefix, reason <> "; admin UI disabled"),
    ])
    config.Listen(port) -> {
      let #(password, notes) = admin_password(loaded)
      #(
        Some(app.Admin(
          bind: loaded.admin_bind,
          port: port,
          password: password,
          accounts: accounts,
        )),
        notes,
      )
    }
  }
}

/// 管理 UI のパスワード。未設定なら起動ごとに生成して報告する。
fn admin_password(loaded: Config) -> #(String, List(String)) {
  case loaded.admin_password {
    Some(password) -> #(password, [])
    None -> {
      let generated = random.hex(random_bytes)
      #(generated, [
        log.line(
          admin.log_prefix,
          "generated password for user \"admin\": " <> generated,
        ),
      ])
    }
  }
}

/// 設定された接続シークレット。未設定ならアカウントごとに乱数で生成する。
fn secret_for(loaded: Config) -> String {
  case loaded.bunker_secret {
    Some(secret) -> secret
    None -> random.hex(random_bytes)
  }
}

/// 起動ログ用にリレー一覧を文字列化する。
fn describe(relay_urls: List(String)) -> String {
  case relay_urls {
    [] -> "(none)"
    urls -> string.join(urls, ", ")
  }
}
