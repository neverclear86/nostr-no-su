import gleam/dict
import gleam/dynamic/decode
import gleam/option.{None, Some}
import nostr_no_su
import nostr_no_su/config
import nostr_no_su/plugin_runner
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
/// 出力には次の行が混ざる。どれも検証したい振る舞いそのものなので、logger の水準を
/// 下げず、標準出力も抑えずにそのまま出している。並列に走るので、行は別の
/// モジュールのテストのものと入り混じる。
///
/// - `=SUPERVISOR REPORT=`: スーパービジョンツリーの復帰を確かめるテストがアクターや
///   プラグインの子を kill するためと、到達できない DB を使うテストでプール
///   （`pgo_pool_sup`）が接続に失敗するため
/// - `=ERROR REPORT=` の `beam_load` の行: プラグインローダーが壊れた BEAM を拒否する
///   ことを確かめているため
/// - `=NOTICE REPORT=`: バンカーの読み込み完了や管理 UI の操作など、アプリ自身が
///   通常運転として出す 1 行ログが OTP logger の notice 水準で出るため
/// - `=WARNING REPORT=`: wisp の `csrf_known_header_protection` が出す
///   `Origin-host mismatch`（別オリジンや `Host` の食い違う POST を拒否する管理 UI の
///   テスト）と、バンカー・管理 UI・プラグインが障害や無効化を報告する 1 行ログ
/// - アプリの 1 行ログ（`[bunker]`、`[admin]`、`[relay <中継名>]`、
///   `[plugin <プラグイン名>]`、`relay_client_test` の中継名の `[test]`、保存の再試行
///   を報告する `[resume_saver]`）: 障害や変更を起こすテストが本番と同じログの経路を
///   通るため
/// - `[account_store]`、`[account_reconcile]`、`[app]`、`[resume_store]`、
///   `[plugin_resume_store]` の skip の行:
///   `TEST_DATABASE_URL` が無いときに統合テストを飛ばしたことを知らせる
/// - `coverage:` の行: `COVERAGE` を設定して走らせたときだけ、実行の最後に
///   `src/` のカバレッジの合計を 1 行出すため（`docs/development.md` の
///   「カバレッジ」）
pub fn main() -> Nil {
  run_tests(ordered_modules, lanes)
}

/// test/ 配下の全モジュールを eunit で走らせ、失敗があれば終了コード 1 で VM を
/// 止める。`ordered` は 1 本のレーンでその順に、残りは `lanes` 本のレーンで同時に走る。
@external(erlang, "eunit_runner", "run")
fn run_tests(ordered: List(String), lanes: Int) -> Nil

/// 取り直しの要求の `since` は、ランナーのメモリの再開点を優先し、無ければ
/// 保存済みの値を使う。保存済みも無い要求は落とし、要求の順は保つ。
pub fn catchup_since_resolves_each_request_test() {
  let stored = fn(plugin: String) {
    case plugin {
      "logger" -> Ok(Some(100))
      _ -> Ok(None)
    }
  }
  assert nostr_no_su.catchup_since(
      [
        #("logger", plugin_runner.Catchup(since: None, until: 200)),
        #("echo", plugin_runner.Catchup(since: Some(50), until: 300)),
        #("unsaved", plugin_runner.Catchup(since: None, until: 400)),
      ],
      stored,
    )
    == Ok([#("logger", 100, 200), #("echo", 50, 300)])
}

/// 保存済みの再開点を 1 つでも読めなければ、解決は全体を失敗にする（その評価では
/// 購読を 1 本も定義しない）。
pub fn catchup_since_fails_as_a_whole_on_a_read_error_test() {
  assert nostr_no_su.catchup_since(
      [#("logger", plugin_runner.Catchup(since: None, until: 200))],
      fn(_plugin) { Error("unavailable") },
    )
    == Error(Nil)
}

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
      account_store: config.AccountStore(
        database_url: url,
        master_key: random_master_key(),
      ),
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
