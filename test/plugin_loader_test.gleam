//// 外部プラグインの走査と読み込みのテスト。
////
//// BEAM は fixture がその場でコンパイルして用意する。モジュール名は fixture ごとに
//// 一意化する。**BEAM のモジュール名前空間はグローバルで、一度読み込むと
//// 再読み込みされない**ため、名前を使い回すと後続のテストが嘘をつく。
////
//// 壊れた BEAM を読ませるテストと、コードパスに足せないディレクトリーを読ませる
//// テストは error_logger の行を出す。これは検証したい振る舞いそのものなので、
//// そのまま出している。

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/plugin
import nostr_no_su/plugin_loader
import support/beam_fixture.{type Fixture}

/// 戻らない・異常終了するメタデータ呼び出しのテストに使う短い期限。実時間に
/// 依存しないよう小さく取る（`plugin_runner_test.gleam` の `limits` と同じ形）が、
/// 同じ呼び出しで正常なプラグインも読み込むテストがあるので、並列に走る他の
/// モジュールと CPU を取り合っても正常な読み込みが収まる長さにする。
const short_call_timeout_ms = 1000

/// `short_call_timeout_ms` で打ち切られた呼び出しの理由に入る文言。
fn timed_out() -> String {
  "timed out after " <> int.to_string(short_call_timeout_ms) <> "ms"
}

/// 報告行のどれかが `text` を含むか。理由の文字列には一時ファイル名などが混ざる
/// ため、完全一致では検査しない。
fn has_note(notes: List(String), text: String) -> Bool {
  list.any(notes, string.contains(_, text))
}

/// fixture の中に `<root>/<module>/<segments...>/ebin` を作り、そのパスを返す。
fn ebin_in(fixture: Fixture, segments: List(String)) -> String {
  let path =
    list.fold(segments, fixture.root, fn(path, segment) {
      path <> "/" <> segment
    })
    <> "/ebin"
  beam_fixture.mkdir(path)
  path
}

/// プラグイン 1 つを `outdir` に用意する。
fn put_plugin(module: String, name: String, outdir: String) -> Nil {
  beam_fixture.compile(
    beam_fixture.plugin_source(module, 1, name),
    module,
    outdir,
  )
}

/// `plugin_dir`（`PLUGIN_DIR` の値。`:` 区切りで複数を並べてよい）を、内蔵プラグイン名と
/// 設定を持たずに既定の期限で読み込む。
fn load_dir(plugin_dir: String) -> plugin_loader.LoadOutcome {
  load_dir_within(plugin_dir, plugin.default_call_timeout_ms)
}

/// `load_dir` と同じ読み込みを、メタデータ呼び出しの期限を `timeout_ms` にして行う。
fn load_dir_within(
  plugin_dir: String,
  timeout_ms: Int,
) -> plugin_loader.LoadOutcome {
  plugin_loader.load_all(Some(plugin_dir), [], dict.new(), timeout_ms)
}

/// `PLUGIN_DIR` が未設定なら、プラグインは 0 件で「無効」の行だけが出る。
pub fn load_all_without_plugin_dir_test() {
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    plugin_loader.load_all(None, [], dict.new(), plugin.default_call_timeout_ms)
  assert plugins == []
  assert list.length(notes) == 1
  assert has_note(notes, "no PLUGIN_DIR set")
}

/// 存在しないディレクトリーを指しても起動は続き、理由が 1 行出る。
pub fn load_all_missing_directory_test() {
  let fixture = beam_fixture.new("missing")
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir(fixture.root <> "/nope")
  assert plugins == []
  assert has_note(notes, "cannot read directory (enoent)")
  assert has_note(notes, "; skipped")
}

/// ディレクトリーでないパスを指した場合も同じ形で報告する。
pub fn load_all_not_a_directory_test() {
  let fixture = beam_fixture.new("not_a_dir")
  let path = fixture.root <> "/file.txt"
  beam_fixture.write(path, "not a directory")
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(path)
  assert plugins == []
  assert has_note(notes, "cannot read directory (enotdir)")
}

/// ルート直下に置いた `.beam` を読み込む。`Plugin.name` は `plugin_name/0` の値。
pub fn load_all_flat_beam_test() {
  let fixture = beam_fixture.new("flat")
  put_plugin(fixture.module, "flat_plugin", fixture.root)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "flat_plugin"
  assert has_note(notes, "loaded 1 plugin(s) from")
}

/// `<name>/ebin/<name>.beam` の形を読み込む。
pub fn load_all_bundle_ebin_test() {
  let fixture = beam_fixture.new("bundle")
  put_plugin(
    fixture.module,
    "bundle_plugin",
    ebin_in(fixture, [fixture.module]),
  )
  let plugin_loader.LoadOutcome(plugins:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "bundle_plugin"
}

/// `gleam export erlang-shipment` が出す `<name>/<app>/ebin/<name>.beam` の形も
/// そのまま読み込む。
pub fn load_all_shipment_layout_test() {
  let fixture = beam_fixture.new("shipment")
  let ebin = ebin_in(fixture, [fixture.module, "some_app"])
  put_plugin(fixture.module, "shipment_plugin", ebin)
  let plugin_loader.LoadOutcome(plugins:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "shipment_plugin"
}

/// 壊れた BEAM は理由付きで飛ばし、同じディレクトリーの他のプラグインは
/// 従来どおり読み込む。
pub fn load_all_broken_beam_test() {
  let fixture = beam_fixture.new("broken")
  let broken = beam_fixture.name(fixture, "aaa")
  let good = beam_fixture.name(fixture, "bbb")
  beam_fixture.write_garbage(fixture.root <> "/" <> broken <> ".beam")
  put_plugin(good, "survivor_plugin", fixture.root)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "survivor_plugin"
  assert has_note(notes, "cannot load module (badfile)")
  assert has_note(notes, "(1 skipped)")
}

/// API バージョンが一致しないモジュールは読み込まれず、`not_loaded` に識別子と理由の構造で
/// 乗る。理由にはモジュール名の接頭辞が付かず、ログの行にだけ付く。
pub fn load_all_reports_not_loaded_test() {
  let fixture = beam_fixture.new("not_loaded")
  beam_fixture.compile(
    beam_fixture.plugin_source(fixture.module, 2, "not_loaded_plugin"),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, not_loaded:) =
    load_dir(fixture.root)
  assert plugins == []
  assert not_loaded
    == [
      plugin_loader.NotLoaded(
        id: fixture.module,
        reason: "unsupported api version 2 (expected 1)",
      ),
    ]
  assert has_note(
    notes,
    fixture.module <> ": unsupported api version 2 (expected 1)",
  )
}

/// ebin を持たないディレクトリーは、期待する置き場所を添えて 1 行報告し、`not_loaded` には
/// ディレクトリー名を `id`、同じ文を `reason` にして乗る。
pub fn load_all_directory_without_ebin_test() {
  let fixture = beam_fixture.new("no_ebin")
  let bundle = beam_fixture.name(fixture, "empty")
  beam_fixture.mkdir(fixture.root <> "/" <> bundle)
  let reason =
    "no ebin directory found (expected "
    <> bundle
    <> "/ebin or "
    <> bundle
    <> "/*/ebin)"
  let plugin_loader.LoadOutcome(plugins:, notes:, not_loaded:) =
    load_dir(fixture.root)
  assert plugins == []
  // 完全一致で検査し、報告の文面が静かに変わらないことを確かめる。
  assert list.contains(notes, "[plugin_loader] " <> bundle <> ": " <> reason)
  assert not_loaded == [plugin_loader.NotLoaded(id: bundle, reason:)]
}

/// 一覧も辿りもできないバンドル（権限 000）は、ebin が無いとは言わずに、読めない
/// ことを理由にして飛ばす。root では権限による拒否が起きない。
pub fn load_all_unreadable_bundle_test() {
  let fixture = beam_fixture.new("unreadable_bundle")
  let bundle = fixture.module
  let path = fixture.root <> "/" <> bundle
  put_plugin(bundle, "unreadable_plugin", ebin_in(fixture, [bundle]))
  beam_fixture.change_mode(path, 0o000)
  let plugin_loader.LoadOutcome(plugins:, not_loaded:, ..) =
    load_dir(fixture.root)
  beam_fixture.change_mode(path, 0o755)
  assert plugins == []
  assert not_loaded
    == [
      plugin_loader.NotLoaded(
        id: bundle,
        reason: "cannot read directory (eacces); skipped",
      ),
    ]
}

/// 辿れるが一覧できないバンドル（権限 111）は、入れ子の ebin の探索だけを諦めて、
/// 直下の ebin から読み込む。root では権限による拒否が起きない。
pub fn load_all_traversable_bundle_test() {
  let fixture = beam_fixture.new("traversable_bundle")
  let bundle = fixture.module
  let path = fixture.root <> "/" <> bundle
  put_plugin(bundle, "traversable_plugin", ebin_in(fixture, [bundle]))
  beam_fixture.change_mode(path, 0o111)
  let plugin_loader.LoadOutcome(plugins:, not_loaded:, ..) =
    load_dir(fixture.root)
  beam_fixture.change_mode(path, 0o755)
  assert list.map(plugins, fn(item) { item.name }) == ["traversable_plugin"]
  assert not_loaded == []
}

/// コードパスに足せない ebin（パスの途中に `.ez` で終わる名前がある）を持つバンドルは、
/// 足せなかった ebin を添えて飛ばす。
pub fn load_all_bundle_rejected_by_code_path_test() {
  let fixture = beam_fixture.new("bundle_code_path")
  let bundle = fixture.module
  put_plugin(bundle, "code_path_plugin", ebin_in(fixture, [bundle, "app.ez"]))
  let plugin_loader.LoadOutcome(plugins:, notes:, not_loaded:) =
    load_dir(fixture.root)
  assert plugins == []
  assert list.map(not_loaded, fn(item) { item.id }) == [bundle]
  // not_loaded の reason は絶対パスを含んで切られることがあるため、文面は
  // 切られない notes の行で見る。
  assert list.any(notes, fn(note) {
    string.starts_with(note, "[plugin_loader] " <> bundle <> ": cannot add /")
    && string.ends_with(
      note,
      "/" <> bundle <> "/app.ez/ebin to code path (bad_directory); skipped",
    )
  })
}

/// コードパスに足せないディレクトリー（パスの途中に `.ez` で終わる名前がある）では、
/// ルート直下の `.beam` をディレクトリーごと飛ばす。
pub fn load_all_flat_rejected_by_code_path_test() {
  let fixture = beam_fixture.new("flat_code_path")
  let dir = fixture.root <> "/flat.ez/plugins"
  beam_fixture.mkdir(dir)
  put_plugin(fixture.module, "flat_code_path_plugin", dir)
  let plugin_loader.LoadOutcome(plugins:, not_loaded:, ..) = load_dir(dir)
  assert plugins == []
  let assert [plugin_loader.NotLoaded(id:, reason:)] = not_loaded
  assert string.ends_with(id, "/flat.ez/plugins")
  assert reason == "cannot add to code path (bad_directory); skipped"
}

/// プラグインでないエントリーは黙って無視する。報告行は集計の 1 行だけで、
/// `skipped` にも数えない。
pub fn load_all_ignores_non_plugin_entries_test() {
  let fixture = beam_fixture.new("junk")
  beam_fixture.write(fixture.root <> "/.gitkeep", "")
  beam_fixture.write(fixture.root <> "/README.md", "# plugins")
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert list.length(notes) == 1
  assert has_note(notes, "loaded no plugins from")
  assert !has_note(notes, "skipped")
}

/// 集計行・影の報告・`PLUGIN_DIR` 未設定はログにだけ出て、`not_loaded` には
/// 入らない。
pub fn load_all_not_loaded_excludes_info_notes_test() {
  let fixture = beam_fixture.new("not_loaded_ok")
  put_plugin(fixture.module, "ok_plugin", fixture.root)
  let plugin_loader.LoadOutcome(not_loaded:, ..) = load_dir(fixture.root)
  assert not_loaded == []

  let plugin_loader.LoadOutcome(not_loaded: without_dir, ..) =
    plugin_loader.load_all(None, [], dict.new(), plugin.default_call_timeout_ms)
  assert without_dir == []
}

/// `plugin_name/0` が重なるプラグインは、名前順で先に読み込んだ方を残す。
pub fn load_all_duplicate_name_test() {
  let fixture = beam_fixture.new("duplicate")
  let first = beam_fixture.name(fixture, "aaa")
  let second = beam_fixture.name(fixture, "bbb")
  put_plugin(first, "same_name", fixture.root)
  put_plugin(second, "same_name", fixture.root)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "same_name"
  assert has_note(notes, second <> ": duplicate plugin name \"same_name\"")
  assert !has_note(notes, first <> ": duplicate")
}

/// 理由が 120 文字を超えるときは、`not_loaded` の `reason` だけ末尾に省略記号を
/// 付けて切る。ログの行は切らない。
pub fn load_all_not_loaded_truncates_long_reason_test() {
  let fixture = beam_fixture.new("long_reason")
  let long_name = string.repeat("a", times: 130)
  let first = beam_fixture.name(fixture, "aaa")
  let second = beam_fixture.name(fixture, "bbb")
  beam_fixture.compile(
    beam_fixture.plugin_source(first, 1, long_name),
    first,
    fixture.root,
  )
  beam_fixture.compile(
    beam_fixture.plugin_source(second, 1, long_name),
    second,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(not_loaded:, notes:, ..) =
    load_dir(fixture.root)
  let assert [plugin_loader.NotLoaded(id:, reason:)] = not_loaded
  assert id == second
  assert string.length(reason) == 123
  assert string.ends_with(reason, "...")
  assert has_note(
    notes,
    second
      <> ": duplicate plugin name \""
      <> long_name
      <> "\"; keeping the first",
  )
}

/// 内蔵プラグインと同名の外部プラグインは採用しない。プラグイン名はダッシュ
/// ボードとログの識別子なので、内蔵・外部を区別せず一意にする。
pub fn load_all_rejects_reserved_name_test() {
  let fixture = beam_fixture.new("reserved")
  put_plugin(fixture.module, "console_logger", fixture.root)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    plugin_loader.load_all(
      Some(fixture.root),
      ["console_logger"],
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  assert plugins == []
  assert has_note(notes, "duplicate plugin name \"console_logger\"")
}

/// `:` 区切りで並べたディレクトリーは左から順に走査する。`first` 側のモジュール
/// 名が辞書順で後ろでも、並びはディレクトリーの順になる。集計行は
/// ディレクトリーごとに出る。
pub fn load_all_multiple_directories_test() {
  let fixture = beam_fixture.new("multi_dir")
  let first = fixture.root <> "/first"
  let second = fixture.root <> "/second"
  beam_fixture.mkdir(first)
  beam_fixture.mkdir(second)
  put_plugin(beam_fixture.name(fixture, "zzz"), "first_dir_plugin", first)
  put_plugin(beam_fixture.name(fixture, "aaa"), "second_dir_plugin", second)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir(first <> ":" <> second)
  assert list.map(plugins, fn(item) { item.name })
    == ["first_dir_plugin", "second_dir_plugin"]
  assert has_note(notes, first <> ": first_dir_plugin")
  assert has_note(notes, second <> ": second_dir_plugin")
}

/// 一覧の中の読めないディレクトリーは飛ばし、後ろのディレクトリーの走査は
/// 続く。行の末尾は `; skipped` で、読み込み全体を無効にはしない。
pub fn load_all_skips_unreadable_directory_in_list_test() {
  let fixture = beam_fixture.new("skip_unreadable")
  let second = fixture.root <> "/second"
  beam_fixture.mkdir(second)
  put_plugin(fixture.module, "survivor_plugin", second)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir(fixture.root <> "/nope" <> ":" <> second)
  let assert [loaded] = plugins
  assert loaded.name == "survivor_plugin"
  assert has_note(notes, "cannot read directory (enoent); skipped")
  assert !has_note(notes, "external plugins disabled")
}

/// 同じエントリーモジュール名を 2 つのディレクトリーに置くと、先の
/// ディレクトリーのものだけが採用され、後ろは影の理由で飛ぶ（先勝ち）。
pub fn load_all_first_directory_shadows_test() {
  let fixture = beam_fixture.new("dir_shadow")
  let first = fixture.root <> "/first"
  let second = fixture.root <> "/second"
  beam_fixture.mkdir(first)
  beam_fixture.mkdir(second)
  put_plugin(fixture.module, "first_dir_plugin", first)
  put_plugin(fixture.module, "second_dir_plugin", second)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir(first <> ":" <> second)
  let assert [loaded] = plugins
  assert loaded.name == "first_dir_plugin"
  assert has_note(
    notes,
    fixture.module
      <> ": module "
      <> fixture.module
      <> " is already provided by the host or another plugin; skipped",
  )
}

/// 別のモジュール名で同じ `plugin_name/0` を名乗るプラグインが後ろの
/// ディレクトリーにあっても採用されない。先のディレクトリーで読み込んだ
/// 名前が `reserved` へ積まれることの検証。
pub fn load_all_duplicate_name_across_directories_test() {
  let fixture = beam_fixture.new("dup_across")
  let first = fixture.root <> "/first"
  let second = fixture.root <> "/second"
  beam_fixture.mkdir(first)
  beam_fixture.mkdir(second)
  let second_module = beam_fixture.name(fixture, "bbb")
  put_plugin(beam_fixture.name(fixture, "aaa"), "same_name", first)
  put_plugin(second_module, "same_name", second)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir(first <> ":" <> second)
  let assert [loaded] = plugins
  assert loaded.name == "same_name"
  assert has_note(
    notes,
    second_module <> ": duplicate plugin name \"same_name\"",
  )
}

/// `:` だけの指定は有効なディレクトリーを 1 つも含まないので、未設定と同じ
/// 1 行になる。
pub fn load_all_only_separators_test() {
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir("::")
  assert plugins == []
  assert list.length(notes) == 1
  assert has_note(notes, "no PLUGIN_DIR set")
}

/// エントリーモジュール名がホストのモジュールと重なるバンドルは、**エントリーの
/// BEAM を同梱していなくても**飛ばす。同梱の有無から判定していると、ホスト側の
/// モジュールを読み込んで `missing export` としか出ず、自分の BEAM が一切読まれ
/// ていないことが利用者に分からない。
pub fn load_all_skips_shadowed_entry_module_bundle_test() {
  let fixture = beam_fixture.new("shadow_bundle")
  let ebin = ebin_in(fixture, ["minimal_plugin"])
  let unrelated = beam_fixture.name(fixture, "unrelated")
  beam_fixture.compile(beam_fixture.value_source(unrelated, 1), unrelated, ebin)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert has_note(
    notes,
    "minimal_plugin: module minimal_plugin is already provided by the host",
  )
  assert !has_note(notes, "missing export")
  assert has_note(notes, "(1 skipped)")
  // コードパスに何も足していないこと。飛ばす判断を `add_code_path` の後に置く
  // 実装（足してから捨てる形）では、同梱した無関係なモジュールがコードパスへ
  // 残ってしまい、ここが真になる。
  assert !beam_fixture.on_code_path(unrelated)
}

/// ルート直下の `.beam` でも同じ規則が働く。読み込みを試す前に飛ばすので、
/// 中身がゴミバイト列でも `badfile` にはならない。
pub fn load_all_skips_shadowed_entry_module_flat_test() {
  let fixture = beam_fixture.new("shadow_flat")
  beam_fixture.write_garbage(fixture.root <> "/minimal_plugin.beam")
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert has_note(
    notes,
    "minimal_plugin: module minimal_plugin is already provided by the host",
  )
  assert !has_note(notes, "badfile")
}

/// 2 つのプラグインが同名のモジュールを同梱した場合、後から読み込む側が影に入る。
/// 報告はバンドルにつき 1 行に集約し、実際に呼んだときも先に読み込まれた側の値が
/// 返る（`code:add_pathz` は末尾追加なので先勝ち）。
pub fn load_all_reports_shadowed_modules_test() {
  let fixture = beam_fixture.new("shadowing")
  let first = beam_fixture.name(fixture, "aaa")
  let second = beam_fixture.name(fixture, "bbb")
  let shared = beam_fixture.name(fixture, "shared")
  let first_ebin = ebin_in(fixture, [first])
  let second_ebin = ebin_in(fixture, [second])
  put_plugin(first, "first_plugin", first_ebin)
  put_plugin(second, "second_plugin", second_ebin)
  beam_fixture.compile(beam_fixture.value_source(shared, 1), shared, first_ebin)
  beam_fixture.compile(
    beam_fixture.value_source(shared, 2),
    shared,
    second_ebin,
  )

  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert list.map(plugins, fn(item) { item.name })
    == ["first_plugin", "second_plugin"]
  assert has_note(notes, second <> ": 1 module(s) already provided")
  assert has_note(notes, "(" <> shared <> ")")
  assert !has_note(notes, first <> ": 1 module(s)")

  // 先に読み込まれた側（aaa）の値が返る。ログ行だけを見ていると、先勝ち・後勝ち
  // が逆転しても気付けない。
  let assert Ok(1) =
    decode.run(apply(atom.create(shared), atom.create("value"), []), decode.int)
}

/// 影に入ったモジュールの報告には、提供元のアプリと版が添えられる（#92 の
/// 受け入れ条件）。版をハードコードせず、被検コードとは別の経路
/// （`application:get_key/2`）で得た値と比べる。
pub fn load_all_reports_shadowed_module_versions_test() {
  let fixture = beam_fixture.new("shadow_versions")
  let ebin = ebin_in(fixture, [fixture.module])
  beam_fixture.write_garbage(ebin <> "/lists.beam")
  put_plugin(fixture.module, "shadow_versions_plugin", ebin)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "shadow_versions_plugin"
  assert has_note(notes, ": 1 module(s) already provided")
  assert has_note(
    notes,
    "(stdlib " <> beam_fixture.loaded_app_version("stdlib") <> ")",
  )
}

/// 要求した版がコードパス上の版と完全一致すれば読み込まれる。
pub fn load_all_required_versions_match_test() {
  let fixture = beam_fixture.new("required_match")
  let ebin = ebin_in(fixture, [fixture.module])
  let app = beam_fixture.name(fixture, "req_app")
  beam_fixture.write_app_file(ebin, app, "1.2.0")
  beam_fixture.compile(
    beam_fixture.required_versions_source(
      fixture.module,
      "required_match_plugin",
      "#{<<\"" <> app <> "\">> => <<\"1.2.0\">>}",
    ),
    fixture.module,
    ebin,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "required_match_plugin"
}

/// 照合の相手は「実行時に実際に使われる版」である。プラグインが偽の
/// `stdlib.app` を同梱していても、本体側の `.app` が先に見つかるので、本物の
/// 版を要求すれば読み込まれる。
pub fn load_all_required_versions_host_wins_test() {
  let fixture = beam_fixture.new("required_host_wins")
  let ebin = ebin_in(fixture, [fixture.module])
  beam_fixture.write_app_file(ebin, "stdlib", "0.0.0")
  beam_fixture.compile(
    beam_fixture.required_versions_source(
      fixture.module,
      "required_host_wins_plugin",
      "#{<<\"stdlib\">> => <<\""
        <> beam_fixture.loaded_app_version("stdlib")
        <> "\">>}",
    ),
    fixture.module,
    ebin,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "required_host_wins_plugin"
}

/// 要求した版がコードパス上の版と食い違うと読み込まれず、理由に両方の版が出る。
pub fn load_all_required_versions_mismatch_test() {
  let fixture = beam_fixture.new("required_mismatch")
  let ebin = ebin_in(fixture, [fixture.module])
  let app = beam_fixture.name(fixture, "req_app")
  beam_fixture.write_app_file(ebin, app, "1.2.0")
  beam_fixture.compile(
    beam_fixture.required_versions_source(
      fixture.module,
      "mismatch_plugin",
      "#{<<\"" <> app <> "\">> => <<\"1.3.0\">>}",
    ),
    fixture.module,
    ebin,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert has_note(
    notes,
    "requires " <> app <> " 1.3.0, but the code path provides 1.2.0",
  )
  assert has_note(notes, "(1 skipped)")
}

/// コードパスのどこにも無いアプリケーションを要求すると読み込まれない。
pub fn load_all_required_versions_missing_app_test() {
  let fixture = beam_fixture.new("required_missing_app")
  let app = beam_fixture.name(fixture, "missing_app")
  beam_fixture.compile(
    beam_fixture.required_versions_source(
      fixture.module,
      "missing_app_plugin",
      "#{<<\"" <> app <> "\">> => <<\"1.0.0\">>}",
    ),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert has_note(notes, "but no " <> app <> ".app is on the code path")
}

/// `plugin_required_versions/0` の戻り値の形が合わないと、`decode` のエラーを
/// 整えた 1 行になる。値が悪い場合とキーの集合自体が悪い（map でない）場合の
/// 両方を確かめる。
pub fn load_all_required_versions_bad_shape_test() {
  let fixture = beam_fixture.new("required_bad_shape")
  let bad_value = beam_fixture.name(fixture, "aaa")
  let bad_list = beam_fixture.name(fixture, "bbb")
  beam_fixture.compile(
    beam_fixture.required_versions_source(
      bad_value,
      "bad_value_plugin",
      "#{<<\"app\">> => 1}",
    ),
    bad_value,
    fixture.root,
  )
  beam_fixture.compile(
    beam_fixture.required_versions_source(bad_list, "bad_list_plugin", "[]"),
    bad_list,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert has_note(
    notes,
    bad_value
      <> ": plugin_required_versions/0 must return a map of application names to version strings (expected String, got Int at app)",
  )
  assert has_note(
    notes,
    bad_list
      <> ": plugin_required_versions/0 must return a map of application names to version strings (expected Dict, got List)",
  )
}

/// 戻らない `plugin_required_versions/0` は他のメタデータ関数と同じ形で
/// タイムアウトになる。
pub fn load_all_required_versions_timeout_test() {
  let fixture = beam_fixture.new("required_timeout")
  beam_fixture.compile(
    beam_fixture.required_versions_source(
      fixture.module,
      "required_timeout_plugin",
      "receive after infinity -> ok end",
    ),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir_within(fixture.root, short_call_timeout_ms)
  assert plugins == []
  assert has_note(
    notes,
    fixture.module <> ": plugin_required_versions/0 " <> timed_out(),
  )
}

/// 要求したアプリケーションの `.app` が形の崩れたものでも、例外にはならず
/// 「見つからない」と同じ理由で読み込みを拒否し、他のプラグインは読み込まれる。
/// `.app` の直読み（`read_app_file/1`）が例外を投げないことの検証を兼ねる。
pub fn load_all_required_versions_broken_app_test() {
  let fixture = beam_fixture.new("required_broken_app")
  let broken = beam_fixture.name(fixture, "aaa")
  let good = beam_fixture.name(fixture, "bbb")
  let ebin = ebin_in(fixture, [broken])
  let app = beam_fixture.name(fixture, "broken_req_app")
  beam_fixture.write(
    ebin <> "/" <> app <> ".app",
    "{application, " <> app <> ", [{vsn, [foo]}]}.\n",
  )
  beam_fixture.compile(
    beam_fixture.required_versions_source(
      broken,
      "broken_req_plugin",
      "#{<<\"" <> app <> "\">> => <<\"1.0.0\">>}",
    ),
    broken,
    ebin,
  )
  put_plugin(good, "survivor_plugin", fixture.root)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "survivor_plugin"
  assert has_note(notes, "but no " <> app <> ".app is on the code path")
  assert has_note(notes, "(1 skipped)")
}

/// 宣言した本体の版の下限より本体が古いと、そのプラグインは読み込まれない。
/// 本体の版はテストの中で読むので、リリースで `gleam.toml` の版が上がっても
/// 固定値がずれない。
pub fn load_all_min_host_version_too_old_test() {
  let fixture = beam_fixture.new("min_host_old")
  beam_fixture.compile(
    beam_fixture.min_host_version_source(
      fixture.module,
      "min_host_old_plugin",
      "<<\"99.0.0\">>",
    ),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert has_note(
    notes,
    fixture.module
      <> ": requires nostr-no-su 99.0.0 or later, but this is "
      <> beam_fixture.loaded_app_version("nostr_no_su"),
  )
  assert has_note(notes, "(1 skipped)")
}

/// `plugin_min_host_version/0` の戻り値の形が合わないと読み込まれない。
/// binary でない値は分類名が、`X.Y.Z` に読めない binary は値そのものが理由に
/// 出る。
pub fn load_all_min_host_version_bad_shape_test() {
  let fixture = beam_fixture.new("min_host_bad")
  let bad_int = beam_fixture.name(fixture, "aaa")
  let bad_pre = beam_fixture.name(fixture, "bbb")
  beam_fixture.compile(
    beam_fixture.min_host_version_source(bad_int, "bad_int_plugin", "1"),
    bad_int,
    fixture.root,
  )
  beam_fixture.compile(
    beam_fixture.min_host_version_source(
      bad_pre,
      "bad_pre_plugin",
      "<<\"0.2.0-rc.1\">>",
    ),
    bad_pre,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert plugins == []
  assert has_note(
    notes,
    bad_int
      <> ": plugin_min_host_version/0 must return a version string like \"0.1.0\", got Int",
  )
  assert has_note(
    notes,
    bad_pre
      <> ": plugin_min_host_version/0 must return a version string like \"0.1.0\", got \"0.2.0-rc.1\"",
  )
}

/// 影の提供元の ebin にある `.app` が形の崩れたものでも、影の行はアプリ不明の
/// 分岐（モジュール名）に落ち、両方のプラグインの読み込みは続く。
pub fn load_all_shadow_broken_app_test() {
  let fixture = beam_fixture.new("shadow_broken_app")
  let first = beam_fixture.name(fixture, "aaa")
  let second = beam_fixture.name(fixture, "bbb")
  let shared = beam_fixture.name(fixture, "shared")
  let first_ebin = ebin_in(fixture, [first])
  let second_ebin = ebin_in(fixture, [second])
  put_plugin(first, "first_plugin", first_ebin)
  beam_fixture.write(
    first_ebin <> "/" <> shared <> "_app.app",
    "{application, " <> shared <> "_app, [{vsn, [foo]}]}.\n",
  )
  beam_fixture.compile(beam_fixture.value_source(shared, 1), shared, first_ebin)
  beam_fixture.compile(
    beam_fixture.value_source(shared, 2),
    shared,
    second_ebin,
  )
  put_plugin(second, "second_plugin", second_ebin)

  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert list.map(plugins, fn(item) { item.name })
    == ["first_plugin", "second_plugin"]
  assert has_note(notes, second <> ": 1 module(s) already provided")
  assert has_note(notes, "(" <> shared <> ")")
}

/// 影に入ったモジュールが複数でも、同じアプリは 1 件に畳まれ、アプリ不明のもの
/// はアプリ分の後にモジュール名で続く。
pub fn load_all_shadow_dedup_and_mixed_test() {
  let fixture = beam_fixture.new("shadow_mixed")
  let first = beam_fixture.name(fixture, "aaa")
  let second = beam_fixture.name(fixture, "bbb")
  let shared = beam_fixture.name(fixture, "shared")
  let first_ebin = ebin_in(fixture, [first])
  let second_ebin = ebin_in(fixture, [second])
  put_plugin(first, "first_plugin", first_ebin)
  beam_fixture.compile(beam_fixture.value_source(shared, 1), shared, first_ebin)
  beam_fixture.write_garbage(second_ebin <> "/lists.beam")
  beam_fixture.write_garbage(second_ebin <> "/maps.beam")
  beam_fixture.compile(
    beam_fixture.value_source(shared, 2),
    shared,
    second_ebin,
  )
  put_plugin(second, "second_plugin", second_ebin)

  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert list.map(plugins, fn(item) { item.name })
    == ["first_plugin", "second_plugin"]
  assert has_note(
    notes,
    second
      <> ": 3 module(s) already provided by the host or another plugin are ignored (stdlib "
      <> beam_fixture.loaded_app_version("stdlib")
      <> ", "
      <> shared
      <> ")",
  )
}

/// 一覧できない ebin（権限 111）は、影を数えずにコードパスへ足して読み込む。root では
/// 権限による拒否が起きない。
pub fn load_all_unlistable_ebin_test() {
  let fixture = beam_fixture.new("unlistable_ebin")
  let ebin = ebin_in(fixture, [fixture.module])
  put_plugin(fixture.module, "unlistable_plugin", ebin)
  beam_fixture.change_mode(ebin, 0o111)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  beam_fixture.change_mode(ebin, 0o755)
  assert list.map(plugins, fn(item) { item.name }) == ["unlistable_plugin"]
  assert !has_note(notes, "already provided")
}

/// アプリの分からない影のモジュールが `shadow_sample_size`（3）件を超えると、先頭の
/// 3 件の後を `, ...` で省く。
pub fn load_all_shadow_sample_is_truncated_test() {
  let fixture = beam_fixture.new("shadow_sample")
  let first = beam_fixture.name(fixture, "aaa")
  let second = beam_fixture.name(fixture, "bbb")
  let first_ebin = ebin_in(fixture, [first])
  let second_ebin = ebin_in(fixture, [second])
  put_plugin(first, "first_plugin", first_ebin)
  put_plugin(second, "second_plugin", second_ebin)
  let shared = list.map(["s1", "s2", "s3", "s4"], beam_fixture.name(fixture, _))
  list.each(shared, fn(module) {
    beam_fixture.write_garbage(first_ebin <> "/" <> module <> ".beam")
    beam_fixture.write_garbage(second_ebin <> "/" <> module <> ".beam")
  })
  let assert [s1, s2, s3, _] = shared
  let plugin_loader.LoadOutcome(notes:, ..) = load_dir(fixture.root)
  assert list.contains(
    notes,
    "[plugin_loader] "
      <> second
      <> ": 4 module(s) already provided by the host or another plugin are ignored ("
      <> s1
      <> ", "
      <> s2
      <> ", "
      <> s3
      <> ", ...)",
  )
}

/// 同梱の例（`examples/plugins/file_logger`）が、設定を与えれば読み込めること
/// を確かめる。gleam のビルド対象外であること（コードパスを足さなければ読めない
/// こと）も同時に示している。`handle_event/2` は `/tmp` にファイルを書くため
/// 呼ばない。
///
/// 設定が足りない場合の検証も**このテストの中で**行う。`file_logger` は
/// モジュール名が固定で一意化できず、2 回目の `load_all` はエントリーが影に
/// 入って「already provided by the host or another plugin」で飛ばされるため、
/// 2 回目は `plugin.load` を直接呼ぶ。
pub fn load_all_example_plugin_test() {
  let fixture = beam_fixture.new("example")
  beam_fixture.compile_file(
    "examples/plugins/file_logger/src/file_logger.erl",
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) =
    plugin_loader.load_all(
      Some(fixture.root),
      [],
      dict.from_list([
        #("PLUGIN_FILE_LOGGER_PATH", "/tmp/nostr-no-su-events.log"),
      ]),
      plugin.default_call_timeout_ms,
    )
  let assert [loaded] = plugins
  assert loaded.name == "file_logger"

  let assert Error(reason) =
    plugin.load(
      atom.create("file_logger"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  assert string.contains(
    reason,
    "plugin_children/1 rejected the configuration (path is required); "
      <> "configure it with PLUGIN_FILE_LOGGER_*",
  )
}

/// プラグイン固有の設定は `plugin.load` まで届き、接頭辞を取り除いた小文字の
/// キーになる。他のプラグイン向けの変数と `PLUGIN_DIR` は混ざらない。
pub fn load_all_passes_config_test() {
  let fixture = beam_fixture.new("config")
  beam_fixture.compile(
    beam_fixture.config_source(fixture.module, "config_plugin"),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) =
    plugin_loader.load_all(
      Some(fixture.root),
      [],
      dict.from_list([
        #("PLUGIN_CONFIG_PLUGIN_PATH", "/tmp/events.log"),
        #("PLUGIN_OTHER_PLUGIN_PATH", "/tmp/other.log"),
        #("PLUGIN_DIR", fixture.root),
      ]),
      plugin.default_call_timeout_ms,
    )
  let assert [_loaded] = plugins
  assert decode.run(
      beam_fixture.last_config(fixture.module),
      decode.dict(decode.string, decode.string),
    )
    == Ok(dict.from_list([#("path", "/tmp/events.log")]))
}

/// 設定が足りないプラグインは読み込まれず、理由が 1 行出る。同じディレクトリーの
/// 他のプラグインは読み込まれ、集計行に飛ばした件数が出る。
pub fn load_all_rejected_config_test() {
  let fixture = beam_fixture.new("rejected_config")
  let good = beam_fixture.name(fixture, "good_config")
  beam_fixture.compile(
    beam_fixture.config_source(fixture.module, "rejected_config_plugin"),
    fixture.module,
    ebin_in(fixture, [fixture.module]),
  )
  beam_fixture.compile(
    beam_fixture.plugin_source(good, 1, "good_config_plugin"),
    good,
    ebin_in(fixture, [good]),
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "good_config_plugin"
  assert has_note(
    notes,
    "plugin_children/1 rejected the configuration (path is required); "
      <> "configure it with PLUGIN_REJECTED_CONFIG_PLUGIN_*",
  )
  assert has_note(notes, "(1 skipped)")
}

/// 同梱の例（`examples/plugins/counter`）が読み込め、申告した子仕様が解決される
/// ことを確かめる。文書 §5 が引用している実物がそのまま通ることの裏付けになる。
/// `plugin_children/0` は評価するだけで子は起こさないので、`counter_store` は
/// 登録されない。`file_logger` と同じくモジュール名は固定なので、テスト実行中に
/// 1 度しか読み込めない。
pub fn load_all_counter_example_test() {
  let fixture = beam_fixture.new("counter_example")
  beam_fixture.compile_file(
    "examples/plugins/counter/src/counter.erl",
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  assert loaded.name == "counter"
  assert list.length(loaded.children) == 1
}

/// 管理 UI の宣言（`plugin_pages`、`plugin_page_content`、`plugin_page_action`）の片方だけの
/// 宣言、言語ごとのキーの食い違い、一覧の中身の誤りを持つプラグインは読み込まれず、
/// 行ごとに決まった理由が注記に出る。
pub fn invalid_page_declarations_are_not_loaded_test() {
  use #(name, source, note) <- list.each([
    #(
      "pages_without_content_export",
      beam_fixture.pages_only_source,
      "plugin_pages/0 but no plugin_page_content/1, /2 or /3",
    ),
    #(
      "page_content_without_pages_export",
      beam_fixture.page_content_only_source,
      "plugin_page_content/1 but no plugin_pages/0, /1 or /2",
    ),
    #(
      "page_action_without_pages",
      beam_fixture.page_action_only_source,
      "plugin_page_action/3 but no plugin_pages/0, /1 or /2",
    ),
    #(
      "localized_pages_without_localized_content",
      fn(module, name) {
        beam_fixture.ui_source(
          module,
          name,
          2,
          2,
          "[#{<<\"key\">> => <<\"status\">>, <<\"title\">> => Language}]",
        )
      },
      "plugin_pages/2 but no plugin_page_content/3",
    ),
    #(
      "localized_content_without_localized_pages",
      fn(module, name) {
        beam_fixture.ui_source(
          module,
          name,
          1,
          3,
          "[#{<<\"key\">> => <<\"status\">>, <<\"title\">> => <<\"Status\">>}]",
        )
      },
      "plugin_page_content/3 but no plugin_pages/2",
    ),
    #(
      "localized_page_keys_differ",
      fn(module, name) {
        beam_fixture.ui_source(
          module,
          name,
          2,
          3,
          "[#{<<\"key\">> => Language, <<\"title\">> => <<\"Status\">>}]",
        )
      },
      "plugin_pages/2: page keys for \"ja\" differ from \"en\"",
    ),
    #(
      "pages_empty",
      pages_returning("[]"),
      "plugin_pages/0 must return at least one page",
    ),
    #(
      "duplicate_page_key",
      pages_returning(
        "[#{<<\"key\">> => <<\"settings\">>, <<\"title\">> => <<\"A\">>}, "
        <> "#{<<\"key\">> => <<\"settings\">>, <<\"title\">> => <<\"B\">>}]",
      ),
      "duplicate page key \"settings\"",
    ),
    #(
      "invalid_page_key",
      pages_returning(
        "[#{<<\"key\">> => <<\"A b\">>, <<\"title\">> => <<\"A\">>}]",
      ),
      "page key \"A b\" must match [a-z0-9_-]+",
    ),
    #(
      "page_title_missing",
      pages_returning("[#{<<\"key\">> => <<\"status\">>}]"),
      "page key \"status\": missing title",
    ),
    #(
      "page_element_not_a_map",
      pages_returning("[{a, b}]"),
      "page #0: must be a page map, got Array",
    ),
    #(
      "pages_not_a_list",
      pages_returning("#{}"),
      "plugin_pages/0 must return a list of page maps, got Dict",
    ),
  ])
  let fixture = beam_fixture.new(name)
  beam_fixture.compile(
    source(fixture.module, name),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) = load_dir(fixture.root)
  assert #(name, plugins, has_note(notes, note)) == #(name, [], True)
}

/// `plugin_pages/0` が `body` を返し、`plugin_page_content/1` が空の節を返すプラグインの
/// ソースを、モジュール名とプラグイン名から作る関数。
fn pages_returning(body: String) -> fn(String, String) -> String {
  fn(module, name) {
    beam_fixture.pages_source(module, name, body, "#{<<\"sections\">> => []}")
  }
}

/// `plugin_page_content` の例外は、一覧の検証に影響せず読み込みには成功し、
/// `ui.content` の呼び出しの `Error` として現れる（決めたこと 8）。
pub fn page_content_crash_test() {
  let fixture = beam_fixture.new("pages_content_crash")
  beam_fixture.compile(
    beam_fixture.pages_source(
      fixture.module,
      "pages_content_crash_plugin",
      "[#{<<\"key\">> => <<\"status\">>, <<\"title\">> => <<\"Status\">>}]",
      "erlang:error(boom)",
    ),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  let assert Some(ui) = loaded.ui
  let assert Error(reason) = ui.content("status", "en", [])
  assert string.contains(reason, "plugin_page_content/1 crashed")
}

/// `plugin_page_content` の失敗の理由は、モジュール名の接頭辞を 1 つ付けた 1 行になる。
pub fn page_content_crash_reason_names_the_module_test() {
  let fixture = beam_fixture.new("pages_content_crash_reason")
  beam_fixture.compile(
    beam_fixture.pages_source(
      fixture.module,
      "pages_content_crash_reason_plugin",
      "[#{<<\"key\">> => <<\"status\">>, <<\"title\">> => <<\"Status\">>}]",
      "erlang:error(boom)",
    ),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) = load_dir(fixture.root)
  let assert [loaded] = plugins
  let assert Some(ui) = loaded.ui
  assert ui.content("status", "en", [])
    == Error(fixture.module <> ": plugin_page_content/1 crashed (error:boom)")
}

/// 戻らない `plugin_page_content` は、読み込みには成功し、`ui.content` の
/// 呼び出しが期限で打ち切られて `Error` になる。
pub fn page_content_timeout_test() {
  let fixture = beam_fixture.new("pages_content_timeout")
  beam_fixture.compile(
    beam_fixture.pages_source(
      fixture.module,
      "pages_content_timeout_plugin",
      "[#{<<\"key\">> => <<\"status\">>, <<\"title\">> => <<\"Status\">>}]",
      "receive after infinity -> ok end",
    ),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, ..) =
    load_dir_within(fixture.root, short_call_timeout_ms)
  let assert [loaded] = plugins
  let assert Some(ui) = loaded.ui
  let assert Error(reason) = ui.content("status", "en", [])
  assert string.contains(reason, timed_out())
}

/// 戻らない `plugin_name/0` を持つプラグインは、理由付きで読み込まれず、
/// 起動は続いて同じディレクトリーの他のプラグインが読み込まれる（受け入れ条件）。
/// 打ち切られた呼び出しのプロセスも残らない。
///
/// 期限（`short_call_timeout_ms`）は、使い捨てのプロセスが `plugin_name/0` の先頭で
/// Pid を退避するより十分長い（退避の前に打ち切ると `last_pid` が `badarg` で落ちる）。
pub fn load_all_hanging_metadata_test() {
  let fixture = beam_fixture.new("hanging_metadata")
  let hanging = beam_fixture.name(fixture, "aaa")
  let good = beam_fixture.name(fixture, "bbb")
  beam_fixture.compile(
    beam_fixture.plugin_name_body_source(
      hanging,
      1,
      "persistent_term:put(?MODULE, self()), receive after infinity -> ok end",
    ),
    hanging,
    fixture.root,
  )
  put_plugin(good, "survivor_plugin", fixture.root)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir_within(fixture.root, short_call_timeout_ms)
  let assert [loaded] = plugins
  assert loaded.name == "survivor_plugin"
  assert has_note(notes, hanging <> ": plugin_name/0 " <> timed_out())
  assert has_note(notes, "(1 skipped)")
  assert !process.is_alive(beam_fixture.last_pid(hanging))
}

/// 戻らない `-on_load` を持つプラグインは、モジュールの読み込みの時点で理由付き
/// で読み込まれず、起動は続いて同じディレクトリーの他のプラグインが読み込まれる
/// （受け入れ条件）。
pub fn load_all_hanging_on_load_test() {
  let fixture = beam_fixture.new("hanging_on_load")
  let hanging = beam_fixture.name(fixture, "aaa")
  let good = beam_fixture.name(fixture, "bbb")
  beam_fixture.compile(
    beam_fixture.hanging_on_load_source(hanging, hanging),
    hanging,
    fixture.root,
  )
  put_plugin(good, "survivor_plugin", fixture.root)
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir_within(fixture.root, short_call_timeout_ms)
  let assert [loaded] = plugins
  assert loaded.name == "survivor_plugin"
  assert has_note(
    notes,
    hanging <> ": cannot load module (" <> timed_out() <> ")",
  )
  assert has_note(notes, "(1 skipped)")
}

/// `plugin_name/0` が自プロセスを kill するプラグインは、印の無い DOWN として
/// `crashed` の理由になる（`killed`）。
pub fn load_all_killed_metadata_test() {
  let fixture = beam_fixture.new("killed_metadata")
  beam_fixture.compile(
    beam_fixture.plugin_name_body_source(
      fixture.module,
      1,
      "exit(self(), kill)",
    ),
    fixture.module,
    fixture.root,
  )
  let plugin_loader.LoadOutcome(plugins:, notes:, ..) =
    load_dir_within(fixture.root, short_call_timeout_ms)
  assert plugins == []
  assert has_note(notes, fixture.module <> ": plugin_name/0 crashed (killed)")
}

/// 末尾にスラッシュを持つディレクトリーでも、区切りは 1 つにする。
pub fn join_absorbs_trailing_slash_test() {
  assert plugin_loader.join("/plugins/", "sample") == "/plugins/sample"
}

/// 影に入ったモジュールを実際に呼ぶために使う。戻り値の型はモジュール次第なので
/// `Dynamic` のまま受ける。
@external(erlang, "erlang", "apply")
fn apply(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic
