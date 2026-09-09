import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine
import nostr_no_su/config.{type Config}
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugins/console_logger
import nostr_no_su/plugins/postgres_logger
import nostr_no_su/relay_connection
import nostr_no_su/time
import pog

/// 監視ディスパッチャーがリレー間の重複排除のために記憶する直近イベント id の
/// 件数（正確な上限は `dedup` を参照）。
const dedup_capacity = 4096

/// `wss://` 接続が依存する `ssl` アプリケーションを起動する。
@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

/// 設定されたリレーとアカウントのスーパービジョンツリーを起動し、以降は待機
/// する。ここから先はプロセスの監視・再起動・再配線をすべてツリーが担う。
pub fn main() -> Nil {
  ensure_ssl_started()
  let loaded = config.load()
  io.println(
    "nostr-no-su — monitor relays: " <> describe_relays(loaded.relay_urls),
  )
  // ツリーが起動しないのはバグか設定の不備なので、中途半端な状態で待機せず
  // クラッシュさせる。コンテナーに再起動を促すのは終了コードである。
  let assert Ok(_started) = app.start(spec(loaded))
    as "supervision tree failed to start"
  process.sleep_forever()
}

/// 読み込んだ設定に対して動かすツリー。プロセス名はここで一度だけ生成して下へ
/// 渡すため、再起動したアクターは接続の送信先となる名前を再登録する。
fn spec(loaded: Config) -> app.Spec {
  let storage = storage_spec(loaded)
  let accounts = load_accounts(loaded)
  let admin_accounts = dashboard_accounts(loaded, accounts)
  list.each(admin_accounts, fn(account) {
    io.println("[bunker] " <> account.uri)
  })
  app.Spec(
    monitor: monitor_spec(loaded, storage),
    bunker: bunker_spec(loaded, accounts),
    storage: storage,
    admin: admin_spec(loaded, admin_accounts),
    open: app.open_websocket,
    reconnect_delay_ms: relay_connection.default_reconnect_delay_ms,
  )
}

/// リレー URL ごとに接続 1 本ぶんの仕様を作る。
fn relays(relay_urls: List(String)) -> List(app.Relay) {
  use url <- list.map(relay_urls)
  app.Relay(name: process.new_name("nostr_no_su_relay"), url: url)
}

/// イベント保存サブツリーの仕様。`DATABASE_URL` が未設定、あるいは解釈できない
/// ときは保存を無効にし、監視は従来どおり動かす。
fn storage_spec(loaded: Config) -> Option(app.Storage) {
  case loaded.database_url {
    None -> {
      io.println(
        "[postgres_logger] no DATABASE_URL set; event storage disabled",
      )
      None
    }
    Some(database_url) ->
      case
        pog.url_config(
          process.new_name("nostr_no_su_postgres_logger_pool"),
          database_url,
        )
      {
        Error(Nil) -> {
          io.println(
            "[postgres_logger] DATABASE_URL is not a valid postgres URL;"
            <> " event storage disabled",
          )
          None
        }
        Ok(pool_config) ->
          Some(app.Storage(
            name: process.new_name("nostr_no_su_postgres_logger"),
            // 書き込むのは保存アクター 1 つだけで逐次実行なので、接続は少なく
            // 保つ。既定の 10 本は DB 側の接続枠と idle ping を無駄に使う。
            pool_config: pog.pool_size(pool_config, 2),
          ))
      }
  }
}

/// 設定されたリレーの監視サブツリー。監視対象がなければ None。
fn monitor_spec(
  loaded: Config,
  storage: Option(app.Storage),
) -> Option(app.Monitor) {
  case loaded.relay_urls {
    [] -> {
      io.println("[main] no monitor relays configured; monitoring disabled")
      None
    }
    relay_urls ->
      Some(
        app.Monitor(
          name: process.new_name("nostr_no_su_dedup"),
          plugins: plugins(storage),
          dedup_capacity: dedup_capacity,
          relays: relays(relay_urls),
          subscriptions: fn() { [#("nostr-no-su", config.to_filter(loaded))] },
        ),
      )
  }
}

/// 監視イベントを処理するプラグイン。保存が有効なときだけ Postgres ロガーを
/// 足す。ロガーはアクターを名前で参照するので、アクターより先に組み立ててよい。
fn plugins(storage: Option(app.Storage)) -> List(Plugin) {
  case storage {
    None -> [console_logger.new()]
    Some(storage) -> [console_logger.new(), postgres_logger.new(storage.name)]
  }
}

/// 設定されたアカウントと、それぞれの接続シークレット。鍵を読めないときは理由を
/// 報告して空を返し、バンカーなしの監視のみで動かす。
fn load_accounts(loaded: Config) -> List(#(Account, String)) {
  case account.load_all(loaded.account_keys) {
    Error(reason) -> {
      io.println("[bunker] disabled: " <> reason)
      []
    }
    Ok([]) -> {
      io.println("[bunker] no ACCOUNT_KEYS set; monitor-only mode")
      []
    }
    Ok(accounts) ->
      list.map(accounts, fn(account) { #(account, secret_for(loaded)) })
  }
}

/// 管理 UI に出すアカウント一覧。`bunker://` URI は secret を含むため、起動ログと
/// 認証済みページ以外に出してはならない。
fn dashboard_accounts(
  loaded: Config,
  accounts: List(#(Account, String)),
) -> List(dashboard.Account) {
  use pair <- list.map(accounts)
  dashboard.Account(
    signer: { pair.0 }.pubkey_hex,
    uri: account.bunker_uri(pair.0, loaded.bunker_relay_urls, pair.1),
  )
}

/// 設定されたアカウントのバンカーサブツリー。利用できるアカウントがなければ
/// 監視のみで動作する。
fn bunker_spec(
  loaded: Config,
  accounts: List(#(Account, String)),
) -> Option(app.Bunker) {
  case accounts {
    [] -> None
    accounts -> {
      let signer_pubkeys =
        list.map(accounts, fn(pair) { { pair.0 }.pubkey_hex })
      Some(
        app.Bunker(
          name: process.new_name("nostr_no_su_bunker"),
          engine: engine.new(accounts),
          relays: relays(loaded.bunker_relay_urls),
          subscriptions: fn() {
            [
              #(
                "bunker",
                config.bunker_filter(signer_pubkeys, time.now_seconds() - 60),
              ),
            ]
          },
        ),
      )
    }
  }
}

/// 管理 UI の仕様。`ADMIN_PORT` が空なら黙って無効にし、値が不正なときは理由を
/// 報告してから無効にする。
fn admin_spec(
  loaded: Config,
  accounts: List(dashboard.Account),
) -> Option(app.Admin) {
  case loaded.admin_port {
    config.Disabled -> {
      io.println("[admin] ADMIN_PORT is empty; admin UI disabled")
      None
    }
    config.Invalid(reason) -> {
      io.println("[admin] " <> reason <> "; admin UI disabled")
      None
    }
    config.Listen(port) ->
      Some(app.Admin(
        bind: loaded.admin_bind,
        port: port,
        password: admin_password(loaded),
        accounts: accounts,
      ))
  }
}

/// 管理 UI のパスワード。未設定なら起動ごとに生成してログに出す。
fn admin_password(loaded: Config) -> String {
  case loaded.admin_password {
    Some(password) -> password
    None -> {
      let generated = random_hex()
      io.println("[admin] generated password for user \"admin\": " <> generated)
      generated
    }
  }
}

/// 設定された接続シークレット。未設定ならアカウントごとに乱数で生成する。
fn secret_for(loaded: Config) -> String {
  case loaded.bunker_secret {
    Some(secret) -> secret
    None -> random_hex()
  }
}

/// 16 バイトの乱数を 16 進で表した文字列。接続シークレットと管理 UI の
/// パスワードに使う。
fn random_hex() -> String {
  crypto.strong_random_bytes(16)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// 起動ログ用にリレー一覧を文字列化する。
fn describe_relays(relay_urls: List(String)) -> String {
  case relay_urls {
    [] -> "(none)"
    urls -> string.join(urls, ", ")
  }
}
