//// `log.redact_secrets` と `app.redactable_secrets` のテスト。
////
//// OTP logger の primary filter とハンドラーは VM 全体に効く。`eunit_runner` は
//// モジュールを並列に走らせるので、登録を触るテストはこの 1 モジュールに閉じ、
//// モジュール内の直列実行に頼る。秘密の値を登録するテストは一意な値を使い、
//// 最後に `log.redact_secrets([])` で登録を外し、捕まえるハンドラーも消す。

import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process.{type Name, type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/app
import nostr_no_su/config
import nostr_no_su/log
import nostr_no_su/time
import pog
import support/app_tree
import support/erl.{unique_integer}
import support/log_capture.{type Capture}

/// `pool` のプールの接続プロセスを見つけて、未処理の cast を送って落とす。
/// 見つからなければ `Error`。
@external(erlang, "pgo_fixture", "crash_connection")
fn crash_connection(pool: Name(pog.Message)) -> Result(Pid, Nil)

/// `msg` に Msg、meta に目印を入れたイベントへ filter を適用する。meta が
/// 変わっていれば照合で落ちる。置き換わった msg を返す。
@external(erlang, "redact_probe", "redact")
fn probe_redact(msg: String, secrets: List(String)) -> String

/// "prefix <secret> suffix" の charlist に filter を適用し、結果を binary に
/// 戻して返す。
@external(erlang, "redact_probe", "charlist")
fn probe_charlist(secret: String) -> String

/// tuple・list・map の入れ子に filter を適用して返す。
@external(erlang, "redact_probe", "nested")
fn probe_nested(
  secret: String,
) -> #(String, List(String), dict.Dict(String, String))

/// improper list に filter を適用し、{1 要素目, 2 要素目, 末尾の項} を返す。
@external(erlang, "redact_probe", "improper")
fn probe_improper(secret: String) -> #(String, String, String)

/// pid や ref を含む meta が `=:=` で変わらず返るか。
@external(erlang, "redact_probe", "meta_intact")
fn probe_meta_intact(secret: String) -> Bool

/// filter が例外を起こす経路を再現し、置き換わった msg の binary を返す。
@external(erlang, "redact_probe", "crashing")
fn probe_crashing(secret: String) -> String

/// `redact_secrets` という id の primary filter の本数。
@external(erlang, "redact_probe", "filter_count")
fn probe_filter_count() -> Int

/// テストごとに一意な秘密の値。登録は VM 全体に効くので、別の登録と衝突しない
/// 値にする。
fn unique_secret(label: String) -> String {
  label <> "-" <> int.to_string(unique_integer([atom.create("positive")]))
}

/// `wanted` を満たす行が捕まるまで待つ。捕まれば `True`、期限までに無ければ
/// `False`。
fn await_line(
  capture: Capture,
  wanted: fn(String) -> Bool,
  timeout_ms: Int,
) -> Bool {
  poll_lines(capture, wanted, time.monotonic_ms() + timeout_ms)
}

/// `await_line` の本体。期限までは短い間隔で表を読み直す。
fn poll_lines(
  capture: Capture,
  wanted: fn(String) -> Bool,
  deadline: Int,
) -> Bool {
  case list.any(log_capture.lines(capture), wanted) {
    True -> True
    False ->
      case time.monotonic_ms() < deadline {
        True -> {
          process.sleep(10)
          poll_lines(capture, wanted, deadline)
        }
        False -> False
      }
  }
}

/// binary の中に埋め込まれた登録値は、部分列として `[redacted]` に置き換わる。
pub fn redacts_a_secret_inside_a_binary_test() {
  assert probe_redact("prefix s3cr3t suffix", ["s3cr3t"])
    == "prefix [redacted] suffix"
}

/// charlist の中の登録値も置き換わり、結果はリスト形のまま戻る。
pub fn redacts_a_secret_inside_a_charlist_test() {
  assert probe_charlist("s3cr3t") == "prefix [redacted] suffix"
}

/// tuple・map・proper list は要素を再帰的に走査して置き換える。map のキー側の
/// 値も置き換わる。
pub fn redacts_secrets_inside_tuples_maps_and_lists_test() {
  assert probe_nested("s3cr3t")
    == #(
      "[redacted]",
      ["a [redacted]"],
      dict.from_list([#("key-[redacted]", "[redacted]")]),
    )
}

/// improper list の末尾の項も走査して置き換える。
pub fn redacts_the_tail_of_an_improper_list_test() {
  assert probe_improper("s3cr3t") == #("pre", "[redacted]", "tail-[redacted]")
}

/// 複数の登録値は順に全出現置き換えられ、重複した登録は無害。
pub fn replaces_multiple_and_duplicate_secret_values_test() {
  assert probe_redact("a s1 b s2 c s1", ["s1", "s2", "s1"])
    == "a [redacted] b [redacted] c [redacted]"
}

/// 登録値の一方が他方の接頭辞のとき、短い方が先に一致しても、長い方の出現全体が
/// `[redacted]` に置き換わる（末尾が平文で残らない）。
pub fn redacts_the_longer_value_even_when_a_shorter_one_is_its_prefix_test() {
  assert probe_redact("x abcdef y", ["abc", "abcdef"]) == "x [redacted] y"
}

/// meta は `=:=` で変わらず、msg だけが置き換わる。
pub fn leaves_meta_unchanged_and_changes_only_msg_test() {
  assert probe_meta_intact("s3cr3t")
}

/// filter の中で例外が起きても、秘密を含む元の msg ではなく固定の文に
/// 置き換わる。
pub fn does_not_leak_a_secret_when_the_filter_fails_test() {
  assert probe_crashing("s3cr3t") == "[log redacted: formatting failed]"
}

/// 登録した値を含む行を OTP logger に出すと、捕まえた行では値が `[redacted]`
/// に置き換わる。
pub fn redacts_a_secret_embedded_in_a_log_line_test() {
  let capture = log_capture.install()
  let secret = unique_secret("log-line-secret")
  log.redact_secrets([secret])
  log.write(log.Notice, "test", "token is " <> secret <> " ok")
  let assert Ok(line) =
    list.find(log_capture.lines(capture), string.contains(_, "token"))
  assert string.contains(line, "[redacted]")
  assert !string.contains(line, secret)
  log.redact_secrets([])
  log_capture.remove(capture)
}

/// 登録した値を含まない行はそのまま通る。
pub fn keeps_lines_without_a_secret_unchanged_test() {
  let capture = log_capture.install()
  log.redact_secrets([unique_secret("absent-secret")])
  log.write(log.Notice, "test", "ordinary line")
  let assert Ok(line) =
    list.find(log_capture.lines(capture), string.contains(_, "ordinary"))
  assert !string.contains(line, "[redacted]")
  log.redact_secrets([])
  log_capture.remove(capture)
}

/// 何度呼んでも filter は 1 本だけ。
pub fn installs_a_single_filter_across_repeated_calls_test() {
  let secret = unique_secret("install-secret")
  log.redact_secrets([secret])
  log.redact_secrets([secret])
  assert probe_filter_count() == 1
  log.redact_secrets([])
}

/// 空文字列だけを登録すると filter が外れ、続く行は置き換わらない。
pub fn ignores_an_empty_secret_test() {
  log.redact_secrets([unique_secret("remove-secret")])
  assert probe_filter_count() == 1
  let capture = log_capture.install()
  log.redact_secrets(["", ""])
  assert probe_filter_count() == 0
  log.write(log.Notice, "test", "line with only empty secrets registered")
  let assert Ok(line) =
    list.find(log_capture.lines(capture), string.contains(_, "empty secrets"))
  assert !string.contains(line, "[redacted]")
  log.redact_secrets([])
  log_capture.remove(capture)
  assert probe_filter_count() == 0
}

/// 2 回目の登録の後は、1 回目の値は伏せられず 2 回目の値だけが伏せられる。
pub fn replaces_the_previous_registration_test() {
  let capture = log_capture.install()
  let first = unique_secret("first-secret")
  let second = unique_secret("second-secret")
  log.redact_secrets([first])
  log.redact_secrets([second])
  log.write(log.Notice, "test", first <> " and " <> second)
  let assert Ok(line) =
    list.find(log_capture.lines(capture), string.contains(_, " and "))
  assert string.contains(line, first)
  assert !string.contains(line, second)
  assert string.contains(line, "[redacted]")
  log.redact_secrets([])
  log_capture.remove(capture)
}

/// 死んだポートを指すプールの接続を落とすと、クラッシュレポートにも登録した
/// DB のパスワードが出ない。
pub fn redacts_the_database_password_in_a_pgo_crash_report_test() {
  let capture = log_capture.install()
  let secret = unique_secret("db-password")
  log.redact_secrets([secret])
  let pool_name = process.new_name("log_redaction_test_pool")
  let config =
    pog.default_config(pool_name)
    |> pog.port(1)
    |> pog.password(Some(secret))
    |> pog.pool_size(1)
  let assert Ok(started) = pog.start(config)
  let assert Ok(_conn) = crash_connection(pool_name)
  // 伏せられたクラッシュレポートが届くまで待つ。`terminating` だけだと、別の
  // レーンで同時に落ちたプロセスの行で門を通り抜けてしまうので、`[redacted]`
  // を含むことまで条件にする。
  let arrived =
    await_line(
      capture,
      fn(line) {
        string.contains(line, "terminating")
        && string.contains(line, "[redacted]")
      },
      2000,
    )
  assert arrived
  assert !list.any(log_capture.lines(capture), string.contains(_, secret))
  log.redact_secrets([])
  log_capture.remove(capture)
  app_tree.stop_tree(started.pid)
}

/// `pool` と `admin` だけが変わるテスト用の Spec。他の欄は
/// `redactable_secrets` が読まないが、仕様の形を本番と同じに保つため既存の
/// fixture で埋める。
fn spec(pool: pog.Config, admin: Option(config.AdminListen)) -> app.Spec {
  app.Spec(
    plugins: [],
    not_loaded_plugins: [],
    monitor: app_tree.idle_monitor(),
    bunker: app.Bunker(
      ..app_tree.bunker_spec(
        process.new_name("log_redaction_bunker"),
        app_tree.store_with_load(fn() { Ok(app_tree.accounts_only([])) }),
        [],
        app_tree.fixed_retry_delay,
      ),
      pool: pool,
    ),
    admin:,
    open: fn(_url, _subscriptions, _on_event, _on_ok, _authenticator) {
      Error("unused")
    },
    reconnect_delay: app_tree.fixed_retry_delay,
    relay_list: process.new_name("log_redaction_relay_list"),
  )
}

/// 指定したパスワードを持つプールの設定。他は到達不能な既定値のまま。
fn pool_with_password(password: Option(String)) -> pog.Config {
  pog.default_config(process.new_name("log_redaction_spec_pool"))
  |> pog.port(1)
  |> pog.password(password)
}

/// DB のパスワードと管理パスワードの両方を返す。
pub fn redactable_secrets_collects_the_database_and_admin_passwords_test() {
  let spec =
    spec(
      pool_with_password(Some("db-secret")),
      Some(config.AdminListen(
        bind: "127.0.0.1",
        port: 8080,
        password: "admin-secret",
      )),
    )
  assert app.redactable_secrets(spec) == ["db-secret", "admin-secret"]
}

/// `admin` が無く URL にパスワードも無い Spec では空のリストを返す。
pub fn redactable_secrets_skips_a_missing_admin_and_password_test() {
  assert app.redactable_secrets(spec(pool_with_password(None), None)) == []
}
