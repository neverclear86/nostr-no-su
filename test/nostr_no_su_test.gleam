import gleam/dict
import gleam/dynamic/decode
import gleam/option.{None, Some}
import nostr_no_su
import nostr_no_su/config
import support/beam_fixture
import support/random_account.{random_master_key}

/// 同じ DB の advisory lock（インスタンスのロック）を取り合うモジュール。並列に
/// 走らせると一方のロックの取得が他方の保持で失敗するので、この順で直列に走らせる。
/// 専用の database を作る E2E（`nip46_relay_test`）は別の database のロックを取るので
/// 入れない。
const ordered_modules = ["account_store_test", "account_reconcile_test"]

/// モジュールを同時に走らせるレーンの数。壁時間はいちばん長いモジュールで決まるので、
/// これ以上増やしても縮まらず、CPU の取り合いで「N ms 以内に応答する」の検査（TLS の
/// 接続の期限など）が落ちやすくなるだけである。
const lanes = 8

/// テスト全体のエントリポイント。test/ 配下の全モジュールの `*_test` 関数を eunit で
/// 実行する（`support/eunit_runner`）。モジュールは `lanes` 本のレーンで同時に走り
/// （空いたレーンが次のモジュールを取る）、`ordered_modules` は 1 本のレーンでその
/// 順に走る。同じモジュールの中のテストは順に走る。
///
/// 並列に走るので、モジュールをまたいで共有する状態（環境変数、固定の名前の
/// プロセス、固定の名前の BEAM モジュール、同じ DB の advisory lock）を使うテストは
/// 他のモジュールと干渉する。新しいモジュールでそれらが要るなら、`ordered_modules`
/// に足す（docs/development.md の「テストの流儀」）。
///
/// 出力に混ざる行（`=SUPERVISOR REPORT=` など）の由来は docs/development.md にある。
pub fn main() -> Nil {
  run_tests(ordered_modules, lanes)
}

/// test/ 配下の全モジュールを eunit で走らせ、失敗があれば終了コード 1 で VM を
/// 止める。`ordered` は 1 本のレーンでその順に、残りは `lanes` 本のレーンで同時に走る。
@external(erlang, "eunit_runner", "run")
fn run_tests(ordered: List(String), lanes: Int) -> Nil

/// `startup` はアカウントストアの接続先（`DATABASE_URL`）を予約キー `DatabaseUrl`
/// でプラグインへ渡す。`plugin_children/1` が受け取った設定 map に本体の接続先が
/// 入っていることを確かめる。
pub fn startup_passes_the_database_url_to_plugins_test() {
  let fixture = beam_fixture.new("config")
  beam_fixture.compile(
    beam_fixture.config_source(fixture.module, "config_plugin"),
    fixture.module,
    fixture.root,
  )
  let url = "postgres://nostr:nostr@127.0.0.1:5432/nostr_no_su"
  let loaded =
    config.Config(
      account_store: Ok(config.AccountStore(
        database_url: url,
        master_key: random_master_key(),
      )),
      plugin_dir: Some(fixture.root),
      plugin_env: dict.from_list([
        #("PLUGIN_CONFIG_PLUGIN_PATH", "/tmp/events.log"),
      ]),
      admin_ui: config.Disabled,
      admin_base_url: None,
      console_logger_enabled: Ok(False),
      dedup_capacity: Ok(4096),
    )
  let assert Ok(_started) = nostr_no_su.startup(loaded)
  assert decode.run(
      beam_fixture.last_config(fixture.module),
      decode.dict(decode.string, decode.string),
    )
    == Ok(
      dict.from_list([
        #("path", "/tmp/events.log"),
        #("DatabaseUrl", url),
      ]),
    )
}
