import envoy
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/bunker/vault
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter, Filter}
import nostr_no_su/plugin_config

/// ファイルからも読め、読み込みの後にプロセスの環境から消す秘密の環境変数。
/// `account_store/0` と `listening_admin_ui/1` が `secret/1` で読む名前と
/// 一致させる。
const secret_names = ["DATABASE_URL", "ACCOUNT_MASTER_KEY", "ADMIN_PASSWORD"]

/// 管理 UI が待ち受けるポート。`ADMIN_PORT` で上書きする。
const default_admin_port = 24_133

/// 管理 UI が bind するアドレス。既定はループバックのみ。ページには secret 入りの
/// `bunker://` URI が載るため、外部に出すかどうかは明示的な設定にする。
const default_admin_bind = "127.0.0.1"

/// `DEDUP_CAPACITY` の既定値。監視の重複排除が記憶する直近のイベント id の件数
/// （実際に記憶するのはこの 1〜2 倍。`dedup/window`）。
const default_dedup_capacity = 4096

/// `ADMIN_BIND` / `ADMIN_PORT` / `ADMIN_PASSWORD` の解釈結果。無効化には
/// 「明示的に空にした」と「bind かポートが不正だった」の 2 通りがあり、後者だけ
/// 起動時に理由を報告する。待ち受けるのにパスワードが無ければ、無効化ではなく
/// 起動を中止する。`password` は秘密なので、表示やログに入れないこと。
pub type AdminUi {
  /// この bind・ポート・パスワードで管理 UI を待ち受ける。
  Listen(bind: String, port: Int, password: String)
  /// `ADMIN_PORT` の空文字列で明示的に無効化された。
  Disabled
  /// `ADMIN_PORT` か `ADMIN_BIND` が不正なので無効にし、起動は続ける。理由は
  /// 呼び出し側が報告する。
  Invalid(reason: String)
  /// 待ち受けるのに `ADMIN_PASSWORD` が得られないので起動を中止する。理由は
  /// 値を含まない。
  MissingPassword(reason: String)
}

/// バンカーのアカウントストアの設定。揃っていなければ起動を中止する。
///
/// マスターキーは読み込みの時点で `MasterKey`（関数に閉じた値）にし、生の 16 進
/// 文字列を持たない。`database_url` はパスワードを含みうるので、表示やログに
/// 入れないこと。
pub type AccountStore {
  /// `DATABASE_URL` と `ACCOUNT_MASTER_KEY` が揃っている。
  AccountStore(database_url: String, master_key: vault.MasterKey)
  /// どちらかが未設定か不正か、ファイルを読めない。理由は値を含まない。
  AccountStoreUnavailable(reason: String)
}

/// 環境変数から読み込んだ設定の全体。秘密（マスターキー、`DATABASE_URL` の
/// パスワード、管理パスワード）を含むので、表示やログに入れないこと。
pub type Config {
  Config(
    account_store: AccountStore,
    plugin_dir: Option(String),
    /// プラグインへ渡す候補になる環境変数（`PLUGIN_*`）。プラグインごとの
    /// 切り出しは `plugin_config.for_plugin` が行うので、ここでは接頭辞で
    /// 絞り込んだままの形で持つ。
    plugin_env: Dict(String, String),
    admin_ui: AdminUi,
    admin_base_url: Option(String),
    /// `PLUGIN_CONSOLE_LOGGER_ENABLED` の解析結果。`Error` は起動を中止する理由。
    console_logger_enabled: Result(Bool, String),
    /// `DEDUP_CAPACITY` の解析結果。`Error` は起動を中止する理由。
    dedup_capacity: Result(Int, String),
  )
}

/// 環境変数から設定全体を読み込む。秘密の環境変数（`secret_names`）は読んだ後に
/// 環境から消すので、環境変数で渡した秘密は 2 回目の呼び出しでは読めない
/// （`<名前>_FILE` は残るのでファイルからは読める）。
pub fn load() -> Config {
  let loaded =
    Config(
      account_store: account_store(),
      plugin_dir: optional("PLUGIN_DIR"),
      plugin_env: plugin_env(),
      admin_ui: admin_ui(),
      admin_base_url: optional("ADMIN_BASE_URL")
        |> option.map(strip_trailing(_, "/")),
      console_logger_enabled: parse_enabled(
        "PLUGIN_CONSOLE_LOGGER_ENABLED",
        optional("PLUGIN_CONSOLE_LOGGER_ENABLED"),
      ),
      dedup_capacity: dedup_capacity(),
    )
  list.each(secret_names, envoy.unset)
  loaded
}

/// 承認ページ（`auth_url`）の URL の土台。`ADMIN_BASE_URL` があればそれを、
/// 無ければ待ち受けポートから既定値を組み立てる。承認は管理 UI の上で行うため、
/// 管理 UI が無効なら承認フローも無効として `None` を返す。
pub fn auth_url_base(config: Config) -> Option(String) {
  case config.admin_ui {
    Disabled | Invalid(_) | MissingPassword(_) -> None
    Listen(port:, ..) ->
      Some(option.unwrap(
        config.admin_base_url,
        "http://localhost:" <> int.to_string(port),
      ))
  }
}

/// 末尾の `suffix` を繰り返し取り除く。書記素の単位で比べるので、`suffix` が
/// `\n` なら `\r\n` も取り除く。`ADMIN_BASE_URL` の末尾のスラッシュと、秘密の
/// ファイルの末尾の改行に使う。
fn strip_trailing(text: String, suffix: String) -> String {
  case string.ends_with(text, suffix) {
    True -> strip_trailing(string.drop_end(text, string.length(suffix)), suffix)
    False -> text
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

/// 有効か無効かを表す任意の環境変数を読む。`None`（未設定か空。`optional/1` が
/// 空文字列も `None` にする）は `True`、`"true"` / `"false"` はその値、それ以外は
/// 変数名と値を含む理由にする。値は秘密ではないので理由に含めてよい。
pub fn parse_enabled(
  name: String,
  raw: Option(String),
) -> Result(Bool, String) {
  case raw {
    None -> Ok(True)
    Some("true") -> Ok(True)
    Some("false") -> Ok(False)
    Some(other) ->
      Error(name <> " must be true or false, got \"" <> other <> "\"")
  }
}

/// 監視の重複排除が記憶する直近のイベント id の件数。未設定と空文字列は既定値。
/// 0 以下と数値でない値は、起動を中止する理由にする。
fn dedup_capacity() -> Result(Int, String) {
  case optional("DEDUP_CAPACITY") {
    None -> Ok(default_dedup_capacity)
    Some(raw) -> {
      let trimmed = string.trim(raw)
      case int.parse(trimmed) {
        Ok(capacity) if capacity >= 1 -> Ok(capacity)
        _ ->
          Error(
            "DEDUP_CAPACITY must be an integer of at least 1, got \""
            <> trimmed
            <> "\"",
          )
      }
    }
  }
}

/// ファイルの中身。失敗理由は `enoent` などの文字列。
@external(erlang, "nostr_no_su_ffi", "read_file")
fn read_file(path: String) -> Result(String, String)

/// 秘密の環境変数 `name` を、値そのものか `<name>_FILE` が指すファイルから読む。
/// どちらも未設定なら `None`。両方あるとき、ファイルを読めないとき、中身が空の
/// ときは起動を中止する理由を返す。ファイルの末尾の改行（`\r\n` を含む）は
/// 落とす。理由は値もパスも含まない。
fn secret(name: String) -> Result(Option(String), String) {
  let file_variable = name <> "_FILE"
  case optional(name), optional(file_variable) {
    None, None -> Ok(None)
    Some(value), None -> Ok(Some(value))
    Some(_), Some(_) ->
      Error(name <> " and " <> file_variable <> " are both set; set only one")
    None, Some(path) ->
      case read_file(path) {
        Error(reason) ->
          Error(file_variable <> " could not be read (" <> reason <> ")")
        Ok(content) ->
          case strip_trailing(content, "\n") {
            "" -> Error(file_variable <> " is empty")
            value -> Ok(Some(value))
          }
      }
  }
}

/// バンカーのアカウントストアの設定。`<名前>_FILE` からも読む（`secret/1`）。
fn account_store() -> AccountStore {
  case secret("DATABASE_URL"), secret("ACCOUNT_MASTER_KEY") {
    Error(reason), _ | _, Error(reason) -> AccountStoreUnavailable(reason)
    Ok(database_url), Ok(raw_master_key) ->
      account_store_from(database_url, raw_master_key)
  }
}

/// `database_url` と `raw_master_key` が揃っていればアカウントストアを組み立てる。
/// 理由の文字列は固定の文言にし、入力値を含めない。`DATABASE_URL` の URL として
/// の妥当性は、プール名が要るため起動処理（`account_store.pool_config`）で検査
/// する。マスターキーは自動生成しない。
fn account_store_from(
  database_url: Option(String),
  raw_master_key: Option(String),
) -> AccountStore {
  case database_url, raw_master_key {
    None, None ->
      AccountStoreUnavailable("DATABASE_URL and ACCOUNT_MASTER_KEY are not set")
    None, Some(_) -> AccountStoreUnavailable("DATABASE_URL is not set")
    Some(_), None ->
      AccountStoreUnavailable(
        "ACCOUNT_MASTER_KEY is not set (generate one with: openssl rand -hex 32)",
      )
    Some(database_url), Some(raw_master_key) ->
      case vault.master_key_from_hex(raw_master_key) {
        Ok(master_key) -> AccountStore(database_url:, master_key:)
        Error(reason) -> AccountStoreUnavailable(reason)
      }
  }
}

/// プラグインへ渡す候補になる環境変数（`PLUGIN_*`）。切り出しは
/// `plugin_config.for_plugin` が行うので、ここでは接頭辞での絞り込みと、
/// 空文字列の除去だけを行う。空文字列を落とすのは `optional/1` と同じ理由で、
/// docker compose が未設定の変数を空文字列として渡すためである。
fn plugin_env() -> Dict(String, String) {
  envoy.all()
  |> dict.filter(fn(name, value) {
    string.starts_with(name, plugin_config.env_prefix) && value != ""
  })
}

/// 管理 UI の設定。`ADMIN_PORT` が未設定なら既定ポートを使う。他の任意設定と違い
/// 未設定と空文字列で意味が分かれるのは、既定で有効な設定を明示的に切れるように
/// するため。範囲外の値をそのまま渡すと待ち受け開始時に badarg でクラッシュする
/// ので、ここで弾く。待ち受けるときの bind とパスワードは `listening_admin_ui`
/// が読む。
fn admin_ui() -> AdminUi {
  case envoy.get("ADMIN_PORT") {
    Error(Nil) -> listening_admin_ui(default_admin_port)
    Ok(raw) ->
      case string.trim(raw) {
        "" -> Disabled
        trimmed ->
          case int.parse(trimmed) {
            Ok(port) if port >= 1 && port <= 65_535 -> listening_admin_ui(port)
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

/// `port` で待ち受ける管理 UI の設定。`ADMIN_BIND` が不正なら、`ADMIN_PASSWORD`
/// を求めずに理由付きで無効にする。bind が有効でも `ADMIN_PASSWORD` が未設定か
/// 空、または `ADMIN_PASSWORD_FILE` を読めなければ、起動を中止する理由を返す。
/// パスワードは自動生成しない。
fn listening_admin_ui(port: Int) -> AdminUi {
  case admin_bind(), secret("ADMIN_PASSWORD") {
    Error(reason), _ -> Invalid(reason)
    Ok(bind), Ok(Some(password)) -> Listen(bind:, port:, password:)
    Ok(_), Ok(None) ->
      MissingPassword(
        "ADMIN_PASSWORD is not set (generate one with: openssl rand -base64 24)",
      )
    Ok(_), Error(reason) -> MissingPassword(reason)
  }
}

/// 管理 UI が bind するアドレス。未設定と空文字列（`optional/1` が `None` に
/// する）は既定のループバックにする。前後の空白は落とす。空白だけの値を含め、
/// `"localhost"` と IPv4 / IPv6 のアドレス以外は待ち受け開始時に panic するので、
/// ここで理由にして弾く。値は秘密ではないので理由に含めてよい。
fn admin_bind() -> Result(String, String) {
  case optional("ADMIN_BIND") {
    None -> Ok(default_admin_bind)
    Some(value) -> {
      let raw = string.trim(value)
      case raw == "localhost" || is_ip_address(raw) {
        True -> Ok(raw)
        False ->
          Error(
            "ADMIN_BIND must be \"localhost\" or an IPv4/IPv6 address, got \""
            <> raw
            <> "\"",
          )
      }
    }
  }
}

/// `value` が IPv4 か IPv6 のアドレスとして読めるか。
@external(erlang, "nostr_no_su_ffi", "is_ip_address")
fn is_ip_address(value: String) -> Bool

/// 監視の購読 id。
pub const monitor_subscription_id = "nostr-no-su"

/// プラグインの取り直しの購読 id の接頭辞。プラグイン名を繋げて使う。
const catchup_subscription_prefix = "nostr-no-su-catchup-"

/// 購読 id が取り直しのものなら、そのプラグイン名。`catchup_subscriptions` が
/// 組み立てる id の逆である。
pub fn catchup_plugin(subscription_id: String) -> Option(String) {
  case string.starts_with(subscription_id, catchup_subscription_prefix) {
    True ->
      Some(string.drop_start(
        subscription_id,
        string.length(catchup_subscription_prefix),
      ))
    False -> None
  }
}

/// 登録アカウントが書いたイベントの購読。署名者がいなければ購読を定義せず、継続
/// を評価しない（開いている購読は照合で CLOSE になる、`relay_client.sync`）。継続
/// は署名者がいるときだけ呼び、`since` と足す購読（プラグインの取り直し、
/// `catchup_subscriptions`）を返す。`since` が `Ok(None)` なら保存済みのイベントを
/// すべて求め、`Error(Nil)` なら定義を得られなかったことにする。
pub fn monitor_subscriptions(
  signer_pubkeys: List(String),
  continuation: fn() -> Result(#(Option(Int), List(#(String, Filter))), Nil),
) -> Result(List(#(String, Filter)), Nil) {
  case signer_pubkeys {
    [] -> Ok([])
    signer_pubkeys -> {
      use #(since, extra) <- result.map(continuation())
      [
        #(
          monitor_subscription_id,
          Filter(..filter.new(), authors: Some(signer_pubkeys), since: since),
        ),
        ..extra
      ]
    }
  }
}

/// 復帰したプラグインの取り直しの購読。署名者がいなければ購読を定義しない。
/// 購読 id はプラグイン名で分け、それぞれ `until` で範囲を閉じる（それより後の
/// イベントは通常の監視の購読が運ぶ）。`monitor_since` はこの接続の監視の購読の
/// `since` で、`Some` なら `until` をそれ以下に切り詰め、範囲が残らない取り直しは
/// 定義しない（切り詰めた範囲は監視の購読が運ぶ。境界の秒は両方が運ぶ）。`None`
/// なら範囲を変えない（`since` の無い監視の購読はリレーの件数の上限で切られうる）。
pub fn catchup_subscriptions(
  signer_pubkeys: List(String),
  monitor_since: Option(Int),
  catchups: List(#(String, Int, Int)),
) -> List(#(String, Filter)) {
  case signer_pubkeys {
    [] -> []
    signer_pubkeys ->
      list.filter_map(catchups, fn(catchup) {
        let #(plugin, since, until) = catchup
        let until = case monitor_since {
          None -> until
          Some(monitor) -> int.min(until, monitor)
        }
        case since <= until {
          False -> Error(Nil)
          True ->
            Ok(#(
              catchup_subscription_prefix <> plugin,
              Filter(
                ..filter.new(),
                authors: Some(signer_pubkeys),
                since: Some(since),
                until: Some(until),
              ),
            ))
        }
      })
  }
}

/// 署名者宛の NIP-46 リクエストの購読。署名者がいなければ購読を定義しない。空の
/// `#p` の扱いはリレーによって異なるため REQ を送らず、開いている購読は照合で
/// CLOSE になる（`relay_client.sync`）。
pub fn bunker_subscriptions(
  signer_pubkeys: List(String),
  since: Int,
) -> List(#(String, Filter)) {
  case signer_pubkeys {
    [] -> []
    signer_pubkeys -> [#("bunker", bunker_filter(signer_pubkeys, since))]
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
