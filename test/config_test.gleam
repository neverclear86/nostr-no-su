import envoy
import exception
import gleam/dict
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/config
import nostr_no_su/nostr/filter.{Filter}

/// 環境変数を一時的に設定して `run` を実行し、終了後に元の値へ戻す。`run` が
/// assert の失敗などでクラッシュしても、戻してからそのクラッシュを伝える。設定と
/// 復元を 1 か所にまとめることで、テストごとに散らばる後始末と、その書き忘れを防ぐ。
fn with_env(name: String, value: String, run: fn() -> a) -> a {
  let previous = envoy.get(name)
  envoy.set(name, value)
  exception.defer(fn() { restore_env(name, previous) }, run)
}

/// 環境変数を一時的に未設定にして `run` を実行し、終了後に元の値へ戻す。`run` が
/// クラッシュしても戻す。
fn without_env(name: String, run: fn() -> a) -> a {
  let previous = envoy.get(name)
  envoy.unset(name)
  exception.defer(fn() { restore_env(name, previous) }, run)
}

/// 環境変数を、`envoy.get` で読んだ時点の状態に戻す。値があれば設定し、無ければ
/// 未設定にする。
fn restore_env(name: String, previous: Result(String, Nil)) -> Nil {
  case previous {
    Ok(value) -> envoy.set(name, value)
    Error(Nil) -> envoy.unset(name)
  }
}

/// 指定した環境変数をすべて設定して読み込んだ設定。読み込みを終えた時点で環境
/// 変数は元に戻るため、assert が失敗しても後続のテストに影響しない。
fn config_with(vars: List(#(String, String))) -> config.Config {
  case vars {
    [] -> config.load()
    [#(name, value), ..rest] -> {
      use <- with_env(name, value)
      config_with(rest)
    }
  }
}

/// 指定した環境変数を未設定にして読み込んだ設定。
fn config_without(name: String) -> config.Config {
  use <- without_env(name)
  config.load()
}

/// 環境変数を値があれば設定し、`None` なら未設定にして `run` を実行する。
fn with_optional_env(name: String, value: Option(String), run: fn() -> a) -> a {
  case value {
    Some(value) -> with_env(name, value, run)
    None -> without_env(name, run)
  }
}

/// テスト用のマスターキー（16 進）。
const master_key_hex = "8c1d4e7f2a5b3c6d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f"

/// テスト用の `DATABASE_URL`。パスワードに目印を入れ、理由の文字列に URL が
/// 混ざらないことを確かめられるようにする。
const database_url = "postgres://nostr:pw-marker@db.test:5432/nostr_no_su"

/// 指定した `DATABASE_URL` と `ACCOUNT_MASTER_KEY` で読み込んだストアの設定。
/// `None` の変数は未設定にする。
fn account_store_for(
  url: Option(String),
  master_key: Option(String),
) -> config.AccountStore {
  use <- with_optional_env("DATABASE_URL", url)
  use <- with_optional_env("ACCOUNT_MASTER_KEY", master_key)
  config.load().account_store
}

/// `DATABASE_URL` と `ACCOUNT_MASTER_KEY` が揃えばストアが有効になる。マスター
/// キーは `==` で比べられないので、パターンで取り出して URL だけを比べる。
pub fn account_store_is_configured_with_both_variables_test() {
  let assert config.AccountStore(database_url: url, ..) =
    account_store_for(Some(database_url), Some(master_key_hex))
  assert url == database_url
}

/// どちらかが無ければ、何が足りないかを入力値を含めずに報告する。
pub fn account_store_reports_missing_variables_test() {
  assert account_store_for(None, None)
    == config.AccountStoreUnavailable(
      "DATABASE_URL and ACCOUNT_MASTER_KEY are not set",
    )
  assert account_store_for(None, Some(master_key_hex))
    == config.AccountStoreUnavailable("DATABASE_URL is not set")
  assert account_store_for(Some(database_url), None)
    == config.AccountStoreUnavailable(
      "ACCOUNT_MASTER_KEY is not set (generate one with: openssl rand -hex 32)",
    )
}

/// 空文字列は未設定として扱う。docker compose は未設定の変数を空文字列として
/// 渡すため。
pub fn empty_account_store_variables_are_unset_test() {
  assert account_store_for(Some(""), Some(""))
    == config.AccountStoreUnavailable(
      "DATABASE_URL and ACCOUNT_MASTER_KEY are not set",
    )
}

/// 不正なマスターキーは理由を報告し、理由にマスターキーも URL も含めない。
pub fn an_invalid_master_key_is_reported_without_its_value_test() {
  let assert config.AccountStoreUnavailable(reason) =
    account_store_for(Some(database_url), Some("zz-key-marker"))
  assert reason == "ACCOUNT_MASTER_KEY must be 64 hex characters (32 bytes)"
  assert !string.contains(reason, "key-marker")
  assert !string.contains(reason, "pw-marker")
}

/// 秘密のファイルのフィクスチャーのパス。`gleam test` はプロジェクトの直下で
/// 動く。
fn secret_file(name: String) -> String {
  "test/support/secrets/" <> name
}

/// マスターキーをファイルから読める。`master_key_from_hex` が trim するので、
/// このテストは改行の除去を検証しない（除去は
/// `admin_password_is_read_from_a_file_test` で確かめる）。
pub fn account_store_reads_the_master_key_from_a_file_test() {
  use <- with_env("DATABASE_URL", database_url)
  use <- without_env("ACCOUNT_MASTER_KEY")
  use <- with_env(
    "ACCOUNT_MASTER_KEY_FILE",
    secret_file("master_key_with_newline"),
  )
  let assert config.AccountStore(database_url: url, ..) =
    config.load().account_store
  assert url == database_url
}

/// 秘密の環境変数と `<名前>_FILE` の両方が設定されていると起動を中止する。
/// `DATABASE_URL` も `ACCOUNT_MASTER_KEY` と同じ形の理由になる。
pub fn a_secret_and_its_file_cannot_both_be_set_test() {
  with_env("DATABASE_URL", database_url, fn() {
    with_env("ACCOUNT_MASTER_KEY", master_key_hex, fn() {
      with_env("ACCOUNT_MASTER_KEY_FILE", secret_file("missing"), fn() {
        assert config.load().account_store
          == config.AccountStoreUnavailable(
            "ACCOUNT_MASTER_KEY and ACCOUNT_MASTER_KEY_FILE are both set; set only one",
          )
      })
    })
  })

  with_env("ACCOUNT_MASTER_KEY", master_key_hex, fn() {
    with_env("DATABASE_URL", database_url, fn() {
      with_env("DATABASE_URL_FILE", secret_file("missing"), fn() {
        assert config.load().account_store
          == config.AccountStoreUnavailable(
            "DATABASE_URL and DATABASE_URL_FILE are both set; set only one",
          )
      })
    })
  })
}

/// 読めないファイルの理由にはパスを含めない。
pub fn an_unreadable_secret_file_is_reported_without_its_path_test() {
  use <- with_env("DATABASE_URL", database_url)
  use <- without_env("ACCOUNT_MASTER_KEY")
  use <- with_env("ACCOUNT_MASTER_KEY_FILE", secret_file("missing"))
  assert config.load().account_store
    == config.AccountStoreUnavailable(
      "ACCOUNT_MASTER_KEY_FILE could not be read (enoent)",
    )
}

/// 空のファイルは「未設定」ではなく専用の理由で報告する。
pub fn an_empty_secret_file_is_reported_test() {
  use <- with_env("DATABASE_URL", database_url)
  use <- without_env("ACCOUNT_MASTER_KEY")
  use <- with_env("ACCOUNT_MASTER_KEY_FILE", secret_file("empty"))
  assert config.load().account_store
    == config.AccountStoreUnavailable("ACCOUNT_MASTER_KEY_FILE is empty")
}

/// UTF-8 でないファイルは専用の理由で報告する。
pub fn a_secret_file_that_is_not_utf8_is_reported_test() {
  use <- with_env("DATABASE_URL", database_url)
  use <- without_env("ACCOUNT_MASTER_KEY")
  use <- with_env("ACCOUNT_MASTER_KEY_FILE", secret_file("invalid_utf8"))
  assert config.load().account_store
    == config.AccountStoreUnavailable(
      "ACCOUNT_MASTER_KEY_FILE could not be read (not valid UTF-8)",
    )
}

/// `load` は 3 つの秘密（`DATABASE_URL`、`ACCOUNT_MASTER_KEY`、
/// `ADMIN_PASSWORD`）を読み込んだ後にプロセスの環境から消す。同じ VM で動く
/// プラグインが `os:getenv/1` で読めないようにするため。
pub fn load_removes_secrets_from_the_environment_test() {
  use <- with_env("DATABASE_URL", database_url)
  use <- with_env("ACCOUNT_MASTER_KEY", master_key_hex)
  use <- with_env("ADMIN_PASSWORD", test_password)
  let _ = config.load()
  assert envoy.get("DATABASE_URL") == Error(Nil)
  assert envoy.get("ACCOUNT_MASTER_KEY") == Error(Nil)
  assert envoy.get("ADMIN_PASSWORD") == Error(Nil)
}

/// `<名前>_FILE`（パス）は秘密ではないので、`load` の後も環境に残る。
pub fn load_keeps_secret_file_variables_test() {
  use <- without_env("ACCOUNT_MASTER_KEY")
  use <- with_env("DATABASE_URL", database_url)
  use <- with_env(
    "ACCOUNT_MASTER_KEY_FILE",
    secret_file("master_key_with_newline"),
  )
  let _ = config.load()
  assert envoy.get("ACCOUNT_MASTER_KEY_FILE")
    == Ok(secret_file("master_key_with_newline"))
}

/// `PLUGIN_DIR` は未設定・空文字列なら None（外部プラグインの読み込みを無効に
/// する）。値があればそのまま走査対象のディレクトリーになる。
pub fn plugin_dir_test() {
  assert config_without("PLUGIN_DIR").plugin_dir == None
  assert config_with([#("PLUGIN_DIR", "")]).plugin_dir == None
  assert config_with([#("PLUGIN_DIR", "/plugins")]).plugin_dir
    == Some("/plugins")
}

/// `PLUGIN_*` の環境変数だけが `plugin_env` に集まる。プラグインごとの切り出しは
/// `plugin_config.for_plugin` の仕事なので、ここでは接頭辞での絞り込みしか行わない
/// （`PLUGIN_DIR` もこの時点では残る）。
pub fn plugin_env_test() {
  let loaded =
    config_with([
      #("PLUGIN_FILE_LOGGER_PATH", "/tmp/events.log"),
      #("ADMIN_BIND", "0.0.0.0"),
    ])
  assert dict.get(loaded.plugin_env, "PLUGIN_FILE_LOGGER_PATH")
    == Ok("/tmp/events.log")
  assert dict.get(loaded.plugin_env, "ADMIN_BIND") == Error(Nil)
}

/// 空文字列の `PLUGIN_*` は落とす。`optional/1` と同じ規則で、docker compose が
/// 未設定の変数を空文字列として渡すため。これを通すと、設定の必須チェックが
/// 空文字列を「設定されている」と読んでしまう。
pub fn plugin_env_drops_empty_values_test() {
  let loaded = config_with([#("PLUGIN_FILE_LOGGER_PATH", "")])
  assert dict.get(loaded.plugin_env, "PLUGIN_FILE_LOGGER_PATH") == Error(Nil)
}

/// テスト用の管理パスワード。
const test_password = "test-admin-password"

/// 指定した `ADMIN_BIND` / `ADMIN_PORT` / `ADMIN_PASSWORD` で読み込んだ管理 UI の
/// 設定。`None` の変数は未設定にする。
fn admin_ui_for(
  bind: Option(String),
  port: Option(String),
  password: Option(String),
) -> config.AdminUi {
  use <- with_optional_env("ADMIN_BIND", bind)
  use <- with_optional_env("ADMIN_PORT", port)
  use <- with_optional_env("ADMIN_PASSWORD", password)
  config.load().admin_ui
}

/// `ADMIN_PORT` は未設定なら既定ポート、明示的な空文字列なら無効。
pub fn admin_ui_port_test() {
  assert admin_ui_for(None, None, Some(test_password))
    == config.Listen("127.0.0.1", 8080, test_password)
  assert admin_ui_for(None, Some("9000"), Some(test_password))
    == config.Listen("127.0.0.1", 9000, test_password)
  assert admin_ui_for(None, Some(" 9000 "), Some(test_password))
    == config.Listen("127.0.0.1", 9000, test_password)
  // 上限の境界。1 つ上の 65536 は `Invalid` になる（下のテストを参照）。
  assert admin_ui_for(None, Some("65535"), Some(test_password))
    == config.Listen("127.0.0.1", 65_535, test_password)
  assert admin_ui_for(None, Some(""), Some(test_password)) == config.Disabled
}

/// 範囲外や数値でない `ADMIN_PORT` は、理由付きで無効として報告する。範囲を
/// 検証しないと待ち受け開始時に badarg でクラッシュする。
pub fn admin_ui_rejects_invalid_ports_test() {
  let assert config.Invalid(_) =
    admin_ui_for(None, Some("not-a-port"), Some(test_password))
  let assert config.Invalid(_) =
    admin_ui_for(None, Some("0"), Some(test_password))
  let assert config.Invalid(_) =
    admin_ui_for(None, Some("-1"), Some(test_password))
  let assert config.Invalid(_) =
    admin_ui_for(None, Some("65536"), Some(test_password))
}

/// `"localhost"` と IPv4 / IPv6 のアドレス以外の `ADMIN_BIND` は、理由付きで
/// 無効として報告する。検証しないと待ち受け開始時に panic する。
pub fn admin_ui_rejects_invalid_binds_test() {
  let assert config.Invalid(_) =
    admin_ui_for(Some("not-an-address"), None, Some(test_password))
  let assert config.Invalid(_) =
    admin_ui_for(Some("256.0.0.1"), None, Some(test_password))
  let assert config.Invalid(_) =
    admin_ui_for(Some("127.0.0.1:8080"), None, Some(test_password))
  let assert config.Invalid(_) =
    admin_ui_for(Some("   "), None, Some(test_password))
}

/// 管理 UI を待ち受けるのに `ADMIN_PASSWORD` が未設定か空なら、起動を中止する
/// 理由を返す。空文字列も未設定として扱うのは、docker compose が未設定の変数を
/// 空文字列として渡すため。
pub fn admin_ui_requires_a_password_when_listening_test() {
  let missing =
    config.MissingPassword(
      "ADMIN_PASSWORD is not set (generate one with: openssl rand -base64 24)",
    )
  assert admin_ui_for(None, None, None) == missing
  assert admin_ui_for(None, Some("9000"), None) == missing
  assert admin_ui_for(None, Some("9000"), Some("")) == missing
}

/// `ADMIN_PASSWORD` をファイルから読める。末尾の改行（`\r\n` を含む）は落ちる
/// が、それ以外の空白（先頭の空白）は残る。読めないファイルは理由を返す。
pub fn admin_password_is_read_from_a_file_test() {
  use <- without_env("ADMIN_BIND")
  use <- without_env("ADMIN_PORT")
  use <- without_env("ADMIN_PASSWORD")
  with_env("ADMIN_PASSWORD_FILE", secret_file("password_with_newlines"), fn() {
    assert config.load().admin_ui
      == config.Listen("127.0.0.1", 8080, " file password")
  })
  with_env("ADMIN_PASSWORD_FILE", secret_file("password_with_crlf"), fn() {
    assert config.load().admin_ui
      == config.Listen("127.0.0.1", 8080, "crlf password")
  })
  with_env("ADMIN_PASSWORD_FILE", secret_file("missing"), fn() {
    assert config.load().admin_ui
      == config.MissingPassword(
        "ADMIN_PASSWORD_FILE could not be read (enoent)",
      )
  })
}

/// 管理 UI を待ち受けない構成（空の `ADMIN_PORT`、不正な `ADMIN_PORT`、不正な
/// `ADMIN_BIND`）では `ADMIN_PASSWORD` を求めない。
pub fn admin_ui_without_a_listener_needs_no_password_test() {
  assert admin_ui_for(None, Some(""), None) == config.Disabled
  let assert config.Invalid(_) = admin_ui_for(None, Some("not-a-port"), None)
  let assert config.Invalid(_) =
    admin_ui_for(Some("not-an-address"), None, None)
}

/// `ADMIN_BIND` は未設定と空文字列ならループバックのみ。前後の空白は落とす。
/// ページに secret が載るため、外部へ出すのは明示的な設定にする。
pub fn admin_bind_test() {
  let assert config.Listen(bind:, ..) =
    admin_ui_for(None, None, Some(test_password))
  assert bind == "127.0.0.1"
  let assert config.Listen(bind:, ..) =
    admin_ui_for(Some(""), None, Some(test_password))
  assert bind == "127.0.0.1"
  let assert config.Listen(bind:, ..) =
    admin_ui_for(Some("0.0.0.0"), None, Some(test_password))
  assert bind == "0.0.0.0"
  let assert config.Listen(bind:, ..) =
    admin_ui_for(Some(" ::1 "), None, Some(test_password))
  assert bind == "::1"
  let assert config.Listen(bind:, ..) =
    admin_ui_for(Some("localhost"), None, Some(test_password))
  assert bind == "localhost"
}

/// `ADMIN_BASE_URL` は未設定なら None。末尾のスラッシュは、承認ページのパスと
/// 重ならないよう取り除く。
pub fn admin_base_url_test() {
  assert config_without("ADMIN_BASE_URL").admin_base_url == None
  assert config_with([#("ADMIN_BASE_URL", "https://bunker.example")]).admin_base_url
    == Some("https://bunker.example")
  assert config_with([#("ADMIN_BASE_URL", "https://bunker.example//")]).admin_base_url
    == Some("https://bunker.example")
  assert config_with([#("ADMIN_BASE_URL", "")]).admin_base_url == None
}

/// 承認ページの URL の土台。`ADMIN_BASE_URL` が優先され、未設定なら待ち受け
/// ポートから既定値を組み立てる。管理 UI が無効なら承認フローも無効。
pub fn auth_url_base_test() {
  // 空文字列は未設定として扱われるため、`ADMIN_BASE_URL` を明示的に外せる。
  let from_port =
    config_with([
      #("ADMIN_PORT", "9000"),
      #("ADMIN_PASSWORD", test_password),
      #("ADMIN_BASE_URL", ""),
    ])
  assert config.auth_url_base(from_port) == Some("http://localhost:9000")

  let from_base_url =
    config_with([
      #("ADMIN_PORT", "9000"),
      #("ADMIN_PASSWORD", test_password),
      #("ADMIN_BASE_URL", "https://bunker.example"),
    ])
  assert config.auth_url_base(from_base_url) == Some("https://bunker.example")

  assert config.auth_url_base(config_with([#("ADMIN_PORT", "")])) == None
  assert config.auth_url_base(config_with([#("ADMIN_PORT", "not-a-port")]))
    == None
}

/// 未設定なら有効（`True`）に倒す。docker compose は未設定の変数を空文字列で
/// 渡すため、`optional/1` を経由した `None` もここに含まれる。
pub fn parse_enabled_defaults_to_true_test() {
  assert config.parse_enabled("PLUGIN_CONSOLE_LOGGER_ENABLED", None) == Ok(True)
}

/// `"true"` / `"false"` はその値になる。
pub fn parse_enabled_reads_true_and_false_test() {
  assert config.parse_enabled("PLUGIN_CONSOLE_LOGGER_ENABLED", Some("true"))
    == Ok(True)
  assert config.parse_enabled("PLUGIN_CONSOLE_LOGGER_ENABLED", Some("false"))
    == Ok(False)
}

/// それ以外の値は、変数名と値を含む理由で拒否する。誤記（`flase` など）を
/// 黙って既定に倒すと、切ったつもりで出続けてしまうため。
pub fn parse_enabled_rejects_other_values_test() {
  assert config.parse_enabled("PLUGIN_CONSOLE_LOGGER_ENABLED", Some("flase"))
    == Error(
      "PLUGIN_CONSOLE_LOGGER_ENABLED must be true or false, got \"flase\"",
    )
}

/// `load` は `PLUGIN_CONSOLE_LOGGER_ENABLED` を読んで `console_logger_enabled`
/// に持つ。
pub fn load_reads_console_logger_enabled_test() {
  assert config_with([#("PLUGIN_CONSOLE_LOGGER_ENABLED", "false")]).console_logger_enabled
    == Ok(False)
  assert config_without("PLUGIN_CONSOLE_LOGGER_ENABLED").console_logger_enabled
    == Ok(True)
}

/// 指定した `DEDUP_CAPACITY` で読み込んだ重複排除の容量の解析結果。`None` は
/// 未設定にする。
fn dedup_capacity_for(raw: Option(String)) -> Result(Int, String) {
  use <- with_optional_env("DEDUP_CAPACITY", raw)
  config.load().dedup_capacity
}

/// `DEDUP_CAPACITY` は未設定と空文字列なら既定の 4096、整数なら前後の空白を
/// 落とした値。下限の 1 も受け取る。
pub fn dedup_capacity_test() {
  assert dedup_capacity_for(None) == Ok(4096)
  assert dedup_capacity_for(Some("")) == Ok(4096)
  assert dedup_capacity_for(Some("100")) == Ok(100)
  assert dedup_capacity_for(Some(" 100 ")) == Ok(100)
  assert dedup_capacity_for(Some("1")) == Ok(1)
}

/// 0 以下や数値でない `DEDUP_CAPACITY` は起動を中止する理由にする。容量が 1
/// 未満だとウィンドウが毎回の挿入で世代を切り替え、重複排除が効かなくなるため。
pub fn dedup_capacity_rejects_invalid_values_test() {
  let assert Error(_) = dedup_capacity_for(Some("0"))
  let assert Error(_) = dedup_capacity_for(Some("-1"))
  let assert Error(_) = dedup_capacity_for(Some("abc"))
}

/// 署名者が 0 件なら購読を定義せず、継続を評価しない。署名者がいれば継続を呼び、
/// 監視のフィルターに `authors` と `since` を入れて、足す購読をそのまま後ろに並べる。
/// 継続が `Error(Nil)` なら定義を得られなかったことにする。
pub fn monitor_subscriptions_test() {
  assert config.monitor_subscriptions([], fn() { panic as "must not be called" })
    == Ok([])
  assert config.monitor_subscriptions(["pk1", "pk2"], fn() { Ok(#(None, [])) })
    == Ok([
      #("nostr-no-su", Filter(..filter.new(), authors: Some(["pk1", "pk2"]))),
    ])
  let assert Ok([#(_id, with_since)]) =
    config.monitor_subscriptions(["pk1"], fn() { Ok(#(Some(1000), [])) })
  assert with_since.since == Some(1000)
  assert config.monitor_subscriptions(["pk1"], fn() {
      Ok(#(Some(1000), [#("nostr-no-su-catchup-a", filter.new())]))
    })
    == Ok([
      #(
        "nostr-no-su",
        Filter(..filter.new(), authors: Some(["pk1"]), since: Some(1000)),
      ),
      #("nostr-no-su-catchup-a", filter.new()),
    ])
  assert config.monitor_subscriptions(["pk1"], fn() { Error(Nil) })
    == Error(Nil)
}

/// 署名者が 0 件なら取り直しの購読も定義しない。署名者がいれば、要求ごとに
/// プラグイン名を繋げた id で、`authors` と閉じた範囲 `since`〜`until` を持つ
/// フィルターを作る。
pub fn catchup_subscriptions_test() {
  assert config.catchup_subscriptions([], [#("a", 100, 200)]) == []
  assert config.catchup_subscriptions(["pk1"], [
      #("logger", 100, 200),
      #("echo", 300, 400),
    ])
    == [
      #(
        "nostr-no-su-catchup-logger",
        Filter(
          ..filter.new(),
          authors: Some(["pk1"]),
          since: Some(100),
          until: Some(200),
        ),
      ),
      #(
        "nostr-no-su-catchup-echo",
        Filter(
          ..filter.new(),
          authors: Some(["pk1"]),
          since: Some(300),
          until: Some(400),
        ),
      ),
    ]
}

/// 取り直しの購読 id からはプラグイン名が戻る。監視の購読 id とそれ以外は
/// `None` になる。
pub fn catchup_plugin_test() {
  assert config.catchup_plugin("nostr-no-su-catchup-a") == Some("a")
  assert config.catchup_plugin("nostr-no-su") == None
  assert config.catchup_plugin("other") == None
}

/// 署名者がいれば `#p` に入れて購読し、いなければ購読そのものを開かない。
pub fn bunker_subscriptions_test() {
  assert config.bunker_subscriptions([], 1000) == []
  assert config.bunker_subscriptions(["pk1"], 1000)
    == [#("bunker", config.bunker_filter(["pk1"], 1000))]
}

/// バンカーのフィルターは、署名者宛の直近の kind 24133 イベントを選択する。
pub fn bunker_filter_test() {
  assert config.bunker_filter(["pk1", "pk2"], 1000)
    == Filter(
      ..filter.new(),
      kinds: Some([24_133]),
      p_tags: Some(["pk1", "pk2"]),
      since: Some(1000),
    )
}

/// 復元の検査に使う、他のテストが読まない環境変数の名前。
const scratch_env = "NOSTR_NO_SU_TEST_SCRATCH"

/// `scratch_env` を `initial` の状態にしてから、`wrap` の中で assert をわざと
/// 失敗させ、その後の `scratch_env` の値を返す。検査の後は未設定に戻す。
fn scratch_env_after_failed_assert(
  initial: Option(String),
  wrap: fn(fn() -> Nil) -> Nil,
) -> Result(String, Nil) {
  case initial {
    Some(value) -> envoy.set(scratch_env, value)
    None -> envoy.unset(scratch_env)
  }
  let assert Error(_) =
    exception.rescue(fn() {
      use <- wrap
      assert envoy.get(scratch_env) == Ok("unreachable")
    })
  let after = envoy.get(scratch_env)
  envoy.unset(scratch_env)
  after
}

/// `with_env` の中で assert が失敗しても、環境変数は設定前の状態に戻る。
pub fn with_env_restores_after_a_failed_assert_test() {
  let wrap = with_env(scratch_env, "during", _)
  assert scratch_env_after_failed_assert(Some("before"), wrap) == Ok("before")
  assert scratch_env_after_failed_assert(None, wrap) == Error(Nil)
}

/// `without_env` の中で assert が失敗しても、環境変数は元の値に戻る。
pub fn without_env_restores_after_a_failed_assert_test() {
  let wrap = without_env(scratch_env, _)
  assert scratch_env_after_failed_assert(Some("before"), wrap) == Ok("before")
}
