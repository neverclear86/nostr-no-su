import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/app
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
import nostr_no_su/config.{type Config}
import nostr_no_su/plugins/console_logger
import nostr_no_su/relay_connection
import nostr_no_su/time

/// 監視ディスパッチャがリレー間の重複排除のために記憶する直近イベント id の
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
  // クラッシュさせる。コンテナに再起動を促すのは終了コードである。
  let assert Ok(_started) = app.start(spec(loaded))
    as "supervision tree failed to start"
  process.sleep_forever()
}

/// 読み込んだ設定に対して動かすツリー。プロセス名はここで一度だけ生成して下へ
/// 渡すため、再起動したアクターは接続の送信先となる名前を再登録する。
fn spec(loaded: Config) -> app.Spec {
  app.Spec(
    monitor: monitor_spec(loaded),
    bunker: bunker_spec(loaded),
    open: app.open_websocket,
    reconnect_delay_ms: relay_connection.default_reconnect_delay_ms,
  )
}

/// 設定されたリレーの監視サブツリー。監視対象がなければ None。
fn monitor_spec(loaded: Config) -> Option(app.Monitor) {
  case loaded.relay_urls {
    [] -> {
      io.println("[main] no monitor relays configured; monitoring disabled")
      None
    }
    relay_urls ->
      Some(
        app.Monitor(
          name: process.new_name("nostr_no_su_dedup"),
          plugins: [console_logger.new()],
          dedup_capacity: dedup_capacity,
          relay_urls: relay_urls,
          subscriptions: fn() { [#("nostr-no-su", config.to_filter(loaded))] },
        ),
      )
  }
}

/// 設定されたアカウントのバンカーサブツリー。アカウントごとに接続 URI を 1 件
/// ログ出力する。利用できるアカウントがなければ監視のみで動作する。
fn bunker_spec(loaded: Config) -> Option(app.Bunker) {
  case account.load_all(loaded.account_keys) {
    Error(reason) -> {
      io.println("[bunker] disabled: " <> reason)
      None
    }
    Ok([]) -> {
      io.println("[bunker] no ACCOUNT_KEYS set; monitor-only mode")
      None
    }
    Ok(accounts) -> {
      let with_secrets =
        list.map(accounts, fn(account) { #(account, secret_for(loaded)) })
      list.each(with_secrets, fn(pair) {
        io.println(
          "[bunker] "
          <> account.bunker_uri(pair.0, loaded.bunker_relay_urls, pair.1),
        )
      })
      let signer_pubkeys =
        list.map(accounts, fn(account) { account.pubkey_hex })
      Some(
        app.Bunker(
          name: process.new_name("nostr_no_su_bunker"),
          engine: engine.new(with_secrets),
          relay_urls: loaded.bunker_relay_urls,
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

/// 設定された接続シークレット。未設定ならアカウントごとに乱数で生成する。
fn secret_for(loaded: Config) -> String {
  case loaded.bunker_secret {
    Some(secret) -> secret
    None ->
      crypto.strong_random_bytes(16)
      |> bit_array.base16_encode
      |> string.lowercase
  }
}

/// 起動ログ用にリレー一覧を文字列化する。
fn describe_relays(relay_urls: List(String)) -> String {
  case relay_urls {
    [] -> "(none)"
    urls -> string.join(urls, ", ")
  }
}
