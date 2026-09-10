//// 外部プラグインの走査と読み込みのテスト。
////
//// BEAM は fixture がその場でコンパイルして用意する。モジュール名はテストごとに
//// 一意化する。**BEAM のモジュール名前空間はグローバルで、一度読み込むと
//// 再読み込みされない**ため、名前を使い回すと後続のテストが嘘をつく。
////
//// 壊れた BEAM を読ませるテストは error_logger の行を出す。これは検証したい
//// 振る舞いそのものなので、そのまま出している。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/plugin_loader
import support/beam_fixture.{type Fixture}

/// 配信の確認に使うサンプルイベント。
fn sample_event() -> Event {
  Event(
    id: "556f29ae53faa7a9ca840c4389f4c5e19f67c2b69b6b8a029c96d43286b02385",
    pubkey: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    created_at: 1_700_000_000,
    kind: 1,
    tags: [["t", "test"]],
    content: "hello プラグイン",
    sig: "00",
  )
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

/// `PLUGIN_DIR` が未設定なら、プラグインは 0 件で「無効」の行だけが出る。
pub fn load_all_without_plugin_dir_test() {
  let #(plugins, notes) = plugin_loader.load_all(None, [])
  assert plugins == []
  assert list.length(notes) == 1
  assert has_note(notes, "no PLUGIN_DIR set")
}

/// 存在しないディレクトリーを指しても起動は続き、理由が 1 行出る。
pub fn load_all_missing_directory_test() {
  let fixture = beam_fixture.new("missing")
  let #(plugins, notes) =
    plugin_loader.load_all(Some(fixture.root <> "/nope"), [])
  assert plugins == []
  assert has_note(notes, "cannot read directory (enoent)")
  assert has_note(notes, "external plugins disabled")
}

/// ディレクトリーでないパスを指した場合も同じ形で報告する。
pub fn load_all_not_a_directory_test() {
  let fixture = beam_fixture.new("not_a_dir")
  let path = fixture.root <> "/file.txt"
  beam_fixture.write(path, "not a directory")
  let #(plugins, notes) = plugin_loader.load_all(Some(path), [])
  assert plugins == []
  assert has_note(notes, "cannot read directory (enotdir)")
}

/// ルート直下に置いた `.beam` を読み込む。`Plugin.name` は `plugin_name/0` の値。
pub fn load_all_flat_beam_test() {
  let fixture = beam_fixture.new("flat")
  put_plugin(fixture.module, "flat_plugin", fixture.root)
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
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
  let #(plugins, _notes) = plugin_loader.load_all(Some(fixture.root), [])
  let assert [loaded] = plugins
  assert loaded.name == "bundle_plugin"
}

/// `gleam export erlang-shipment` が出す `<name>/<app>/ebin/<name>.beam` の形も
/// そのまま読み込む。
pub fn load_all_shipment_layout_test() {
  let fixture = beam_fixture.new("shipment")
  let ebin = ebin_in(fixture, [fixture.module, "some_app"])
  put_plugin(fixture.module, "shipment_plugin", ebin)
  let #(plugins, _notes) = plugin_loader.load_all(Some(fixture.root), [])
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
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
  let assert [loaded] = plugins
  assert loaded.name == "survivor_plugin"
  assert has_note(notes, "cannot load module (badfile)")
  assert has_note(notes, "(1 skipped)")
}

/// API バージョンが一致しないモジュールは読み込まない。
pub fn load_all_api_mismatch_test() {
  let fixture = beam_fixture.new("mismatch")
  beam_fixture.compile(
    beam_fixture.plugin_source(fixture.module, 2, "mismatch_plugin"),
    fixture.module,
    fixture.root,
  )
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
  assert plugins == []
  assert has_note(notes, "unsupported api version 2")
}

/// ebin を持たないディレクトリーは、期待する置き場所を添えて 1 行報告する。
pub fn load_all_directory_without_ebin_test() {
  let fixture = beam_fixture.new("no_ebin")
  let bundle = beam_fixture.name(fixture, "empty")
  beam_fixture.mkdir(fixture.root <> "/" <> bundle)
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
  assert plugins == []
  assert has_note(notes, "no ebin directory found")
  assert has_note(notes, bundle <> "/ebin or " <> bundle <> "/*/ebin")
}

/// プラグインでないエントリーは黙って無視する。報告行は集計の 1 行だけで、
/// `skipped` にも数えない。
pub fn load_all_ignores_non_plugin_entries_test() {
  let fixture = beam_fixture.new("junk")
  beam_fixture.write(fixture.root <> "/.gitkeep", "")
  beam_fixture.write(fixture.root <> "/README.md", "# plugins")
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
  assert plugins == []
  assert list.length(notes) == 1
  assert has_note(notes, "loaded no plugins from")
  assert !has_note(notes, "skipped")
}

/// `plugin_name/0` が重なるプラグインは、名前順で先に読み込んだ方を残す。
pub fn load_all_duplicate_name_test() {
  let fixture = beam_fixture.new("duplicate")
  let first = beam_fixture.name(fixture, "aaa")
  let second = beam_fixture.name(fixture, "bbb")
  put_plugin(first, "same_name", fixture.root)
  put_plugin(second, "same_name", fixture.root)
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
  let assert [loaded] = plugins
  assert loaded.name == "same_name"
  assert has_note(notes, second <> ": duplicate plugin name \"same_name\"")
  assert !has_note(notes, first <> ": duplicate")
}

/// 内蔵プラグインと同名の外部プラグインは採用しない。プラグイン名はダッシュ
/// ボードとログの識別子なので、内蔵・外部を区別せず一意にする。
pub fn load_all_rejects_reserved_name_test() {
  let fixture = beam_fixture.new("reserved")
  put_plugin(fixture.module, "console_logger", fixture.root)
  let #(plugins, notes) =
    plugin_loader.load_all(Some(fixture.root), ["console_logger"])
  assert plugins == []
  assert has_note(notes, "duplicate plugin name \"console_logger\"")
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
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
  assert plugins == []
  assert has_note(
    notes,
    "minimal_plugin: module minimal_plugin is already provided by the host",
  )
  assert !has_note(notes, "missing export")
  assert has_note(notes, "(1 skipped)")
}

/// ルート直下の `.beam` でも同じ規則が働く。読み込みを試す前に飛ばすので、
/// 中身がゴミバイト列でも `badfile` にはならない。
pub fn load_all_skips_shadowed_entry_module_flat_test() {
  let fixture = beam_fixture.new("shadow_flat")
  beam_fixture.write_garbage(fixture.root <> "/minimal_plugin.beam")
  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
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

  let #(plugins, notes) = plugin_loader.load_all(Some(fixture.root), [])
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

/// 読み込んだ `Plugin.handle` にイベントを渡すと、プラグインへイベント map が
/// 届く。
pub fn load_all_dispatches_event_test() {
  let fixture = beam_fixture.new("dispatch")
  put_plugin(fixture.module, "dispatch_plugin", fixture.root)
  let #(plugins, _notes) = plugin_loader.load_all(Some(fixture.root), [])
  let assert [loaded] = plugins
  loaded.handle(sample_event())
  assert event.from_map(beam_fixture.last_event(fixture.module))
    == Ok(sample_event())
}

/// 同梱の例（`examples/plugins/file_logger`）が読み込めることを確かめる。
/// gleam のビルド対象外であること（コードパスを足さなければ読めないこと）も
/// 同時に示している。`handle_event/1` は `/tmp` にファイルを書くため呼ばない。
pub fn load_all_example_plugin_test() {
  let fixture = beam_fixture.new("example")
  beam_fixture.compile_file(
    "examples/plugins/file_logger/src/file_logger.erl",
    fixture.root,
  )
  let #(plugins, _notes) = plugin_loader.load_all(Some(fixture.root), [])
  let assert [loaded] = plugins
  assert loaded.name == "file_logger"
}

/// 影に入ったモジュールを実際に呼ぶために使う。戻り値の型はモジュール次第なので
/// `Dynamic` のまま受ける。
@external(erlang, "erlang", "apply")
fn apply(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic
