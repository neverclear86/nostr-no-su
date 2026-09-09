import envoy
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter, Filter}

const default_relay_url = "wss://relay.damus.io"

/// 管理 UI が待ち受けるポート。`ADMIN_PORT` で上書きする。
const default_admin_port = 8080

/// 管理 UI が bind するアドレス。既定はループバックのみ。ページには secret 入りの
/// `bunker://` URI が載るため、外部に出すかどうかは明示的な設定にする。
const default_admin_bind = "127.0.0.1"

/// `ADMIN_PORT` の解釈結果。無効化には「明示的に空にした」と「値が不正だった」の
/// 2 通りがあり、後者だけ起動時に理由を報告する。
pub type AdminPort {
  /// このポートで管理 UI を待ち受ける。
  Listen(port: Int)
  /// 空文字列で明示的に無効化された。
  Disabled
  /// 値が不正なので無効にする。理由は呼び出し側が報告する。
  Invalid(reason: String)
}

/// 環境変数から読み込んだ設定の全体。
pub type Config {
  Config(
    relay_urls: List(String),
    bunker_relay_urls: List(String),
    pubkeys: List(String),
    account_keys: List(String),
    bunker_secret: Option(String),
    database_url: Option(String),
    admin_port: AdminPort,
    admin_bind: String,
    admin_password: Option(String),
    admin_base_url: Option(String),
  )
}

/// 環境変数から設定全体を読み込む。
pub fn load() -> Config {
  let relay_urls =
    envoy.get("RELAY_URL")
    |> result.unwrap(default_relay_url)
    |> parse_list
  Config(
    relay_urls: relay_urls,
    bunker_relay_urls: pick_bunker_relays(
      envoy.get("BUNKER_RELAY_URL") |> result.unwrap("") |> parse_list,
      relay_urls,
    ),
    pubkeys: envoy.get("PUBKEYS") |> result.unwrap("") |> parse_list,
    account_keys: envoy.get("ACCOUNT_KEYS")
      |> result.unwrap("")
      |> parse_list,
    bunker_secret: optional("BUNKER_SECRET"),
    database_url: optional("DATABASE_URL"),
    admin_port: admin_port(),
    admin_bind: optional("ADMIN_BIND") |> option.unwrap(default_admin_bind),
    admin_password: optional("ADMIN_PASSWORD"),
    admin_base_url: optional("ADMIN_BASE_URL")
      |> option.map(strip_trailing_slashes),
  )
}

/// 承認ページ（`auth_url`）の URL の土台。`ADMIN_BASE_URL` があればそれを、
/// 無ければ待ち受けポートから既定値を組み立てる。承認は管理 UI の上で行うため、
/// 管理 UI が無効なら承認フローも無効として `None` を返す。
pub fn auth_url_base(config: Config) -> Option(String) {
  case config.admin_port {
    Disabled | Invalid(_) -> None
    Listen(port) ->
      Some(option.unwrap(
        config.admin_base_url,
        "http://localhost:" <> int.to_string(port),
      ))
  }
}

/// 末尾のスラッシュを取り除く。`ADMIN_BASE_URL` にはパスを足して承認ページの URL
/// を組み立てるため、`http://host:8080/` と書かれてもスラッシュが重ならないように
/// する。
fn strip_trailing_slashes(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> strip_trailing_slashes(string.drop_end(url, 1))
    False -> url
  }
}

/// 任意の環境変数を読む。docker compose は未設定の変数を空文字列として渡す
/// ため、空文字列も未設定として扱う。
fn optional(name: String) -> Option(String) {
  case envoy.get(name) {
    Ok("") | Error(Nil) -> None
    Ok(value) -> Some(value)
  }
}

/// 管理 UI の待ち受けポート。未設定なら既定ポートを使う。他の任意設定と違い未設定
/// と空文字列で意味が分かれるのは、既定で有効な設定を明示的に切れるようにする
/// ため。範囲外の値をそのまま渡すと待ち受け開始時に badarg でクラッシュするので、
/// ここで弾く。
fn admin_port() -> AdminPort {
  case envoy.get("ADMIN_PORT") {
    Error(Nil) -> Listen(default_admin_port)
    Ok(raw) ->
      case string.trim(raw) {
        "" -> Disabled
        trimmed ->
          case int.parse(trimmed) {
            Ok(port) if port >= 1 && port <= 65_535 -> Listen(port)
            _ ->
              Invalid(
                "ADMIN_PORT must be an integer between 1 and 65535, got \""
                <> trimmed
                <> "\"",
              )
          }
      }
  }
}

/// バンカーが待ち受け・応答するリレー。明示的な上書きが空でなければそれを、
/// 無ければ監視用リレーを、それも無ければ既定のリレーを使う。
pub fn pick_bunker_relays(
  override: List(String),
  relay_urls: List(String),
) -> List(String) {
  case override, relay_urls {
    [], [] -> [default_relay_url]
    [], urls -> urls
    urls, _ -> urls
  }
}

/// カンマ区切りのリスト（pubkey、鍵、リレー URL）をパースする。前後の空白は
/// 無視し、空の要素は除外する。
pub fn parse_list(raw: String) -> List(String) {
  raw
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(entry) { entry != "" })
}

/// 設定されたアカウントを購読する。pubkey が未設定なら直近イベントを少数だけ
/// 購読する。
pub fn to_filter(config: Config) -> Filter {
  case config.pubkeys {
    [] -> Filter(..filter.new(), limit: Some(20))
    pubkeys -> Filter(..filter.new(), authors: Some(pubkeys))
  }
}

/// 指定した署名者 pubkey 宛の NIP-46 リクエストを購読する。
pub fn bunker_filter(signer_pubkeys: List(String), since: Int) -> Filter {
  Filter(
    ..filter.new(),
    kinds: Some([event.nip46_kind]),
    p_tags: Some(signer_pubkeys),
    since: Some(since),
  )
}
