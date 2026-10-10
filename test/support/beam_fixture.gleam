//// 一時ディレクトリーと、Erlang ソースを組み立てて compile した BEAM を用意するテストのヘルパー。
////
//// 使ううえでの注意が 3 点ある。
////
//// 1. `compile` の失敗理由には、compile が書き込みに使う一時ファイル名
////    （`good_mod.bea#`。書き込み後に `.beam` へ rename される）が混ざる。
////    **テストで失敗理由を完全一致で検査しないこと。** 部分一致で見る。
//// 2. `examples/plugins/file_logger` だけはモジュール名が `file_logger` で
////    固定なので一意化できず、テスト実行中に 1 度しか読み込めない（2 度目以降は
////    最初に読み込まれた BEAM が使われる）。
//// 3. `file_logger.handle_event/2` は `/tmp` にファイルを書くため、読み込みの
////    確認だけに使い、配信は行わない。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/string
import nostr_no_su/persistent_term
import support/erl.{unique_integer}

/// 1 回のテストが使う一時ディレクトリーと、そこに置くモジュールの名前。
/// **両方を同じトークンから作る。** エントリーモジュール名はバンドルの
/// ディレクトリー名と一致していなければならないため、名前を別々に受け取ると
/// 規約が破れる。
pub type Fixture {
  Fixture(root: String, module: String, token: String)
}

/// テストごとに一意な fixture を作り、その一時ディレクトリーを用意する。
/// `module` は `<label>_<unique>`、`root` は `build/tmp/<module>` になる。
///
/// 一意化は必須である。**BEAM のモジュール名前空間はグローバルで、一度読み込むと
/// `code:ensure_loaded` は再読み込みしない。** 名前を使い回すと、前のテストが
/// 読み込んだ古い BEAM が使われて後続のテストが嘘をつく。
///
/// `build/tmp` を使うのは `/build` が gitignore 済みで、`gleam build` /
/// `gleam test` がここを消さないため。
pub fn new(label: String) -> Fixture {
  let token = int.to_string(unique_integer([atom.create("positive")]))
  let module = label <> "_" <> token
  let fixture = Fixture(root: "build/tmp/" <> module, module:, token:)
  mkdir(fixture.root)
  fixture
}

/// 同じ fixture の中で使う 2 つ目以降のモジュール名。トークンを共有するので
/// 一意性は保たれ、`label` の違いが読み込み順（名前順）を決める。
pub fn name(fixture: Fixture, label: String) -> String {
  label <> "_" <> fixture.token
}

/// ソースを組み立てる部品。
pub type Part {
  /// エクスポートする関数。`name_arity` は `plugin_name/0` の形、`clauses` は
  /// その関数の節（末尾のピリオドまで）。
  Exported(name_arity: String, clauses: String)
  /// エクスポートしない定義。`-on_load` の属性と、それが指す関数に使う。
  Local(source: String)
}

/// `-module` と、`parts` の `Exported` を並べた `-export` に続けて、`parts` の
/// 定義を順に置いた Erlang ソース。
pub fn module_source(module: String, parts: List(Part)) -> String {
  let exports =
    list.filter_map(parts, fn(part) {
      case part {
        Exported(name_arity:, ..) -> Ok(name_arity)
        Local(..) -> Error(Nil)
      }
    })
  let definitions =
    list.map(parts, fn(part) {
      case part {
        Exported(clauses:, ..) -> clauses
        Local(source:) -> source
      }
    })
  "-module("
  <> module
  <> ").\n-export(["
  <> string.join(exports, ", ")
  <> "]).\n"
  <> string.join(definitions, "\n")
  <> "\n"
}

/// `plugin_api_version/0` の部品。`body` は Erlang の式。
pub fn api_version_part(body: String) -> Part {
  Exported("plugin_api_version/0", "plugin_api_version() -> " <> body <> ".")
}

/// `plugin_name/0` の部品。`body` は Erlang の式。
pub fn name_part(body: String) -> Part {
  Exported("plugin_name/0", "plugin_name() -> " <> body <> ".")
}

/// 何もせず `ok` を返す `handle_event` の部品。引数の数は `arity`（1 か 2）。
fn handle_event_part(arity: Int) -> Part {
  let params = list.take(["_Event", "_Config"], arity)
  Exported(
    "handle_event/" <> int.to_string(arity),
    "handle_event(" <> string.join(params, ", ") <> ") -> ok.",
  )
}

/// 文字列を Erlang の binary のリテラルにする。
pub fn binary_literal(text: String) -> String {
  "<<\"" <> text <> "\">>"
}

/// 必須 3 関数（`plugin_api_version/0`、`plugin_name/0`、`handle_event/1`）に
/// `extras` を足したプラグインの Erlang ソース。`version` と `name` は Erlang の式。
/// `-on_load` などの属性は関数の定義より前に要るので、`extras` を必須 3 関数の前に置く。
pub fn plugin_module(
  module: String,
  version: String,
  name: String,
  extras: List(Part),
) -> String {
  module_source(
    module,
    list.append(extras, [
      api_version_part(version),
      name_part(name),
      handle_event_part(1),
    ]),
  )
}

/// 戻らない `-on_load` を持つプラグインのソース。モジュールの読み込みが戻らない
/// 形の検証に使う。
pub fn hanging_on_load_source(module: String, name: String) -> String {
  plugin_module(module, "1", binary_literal(name), [
    Local("-on_load(init/0)."),
    Local("init() ->\n    receive after infinity -> ok end."),
  ])
}

/// 必須 3 関数を持ち、`plugin_name/0` の本体を `body`（Erlang の式）にした
/// プラグインのソース。メタデータの呼び出しが戻らない、プロセスごと終わると
/// いった形の検証に使う。
pub fn plugin_name_body_source(
  module: String,
  version: Int,
  body: String,
) -> String {
  plugin_module(module, int.to_string(version), body, [])
}

/// 必須 3 関数と `plugin_min_host_version/0` を持ち、その本体を `body`
/// （Erlang の式）にしたプラグインのソース。本体の版の下限の検証に使う。
pub fn min_host_version_source(
  module: String,
  name: String,
  body: String,
) -> String {
  plugin_module(module, "1", binary_literal(name), [
    Exported(
      "plugin_min_host_version/0",
      "plugin_min_host_version() -> " <> body <> ".",
    ),
  ])
}

/// 必須 3 関数と `plugin_required_versions/0` を持ち、その本体を `body`
/// （Erlang の式）にしたプラグインのソース。版の照合の検証に使う。
pub fn required_versions_source(
  module: String,
  name: String,
  body: String,
) -> String {
  plugin_module(module, "1", binary_literal(name), [
    Exported(
      "plugin_required_versions/0",
      "plugin_required_versions() -> " <> body <> ".",
    ),
  ])
}

/// 必須 3 関数をエクスポートする最小プラグインの Erlang ソース。
pub fn plugin_source(module: String, version: Int, name: String) -> String {
  plugin_name_body_source(module, version, binary_literal(name))
}

/// プラグイン固有の設定を受け取るプラグインの Erlang ソース。`plugin_children/1`
/// は `path` が無ければ `{error, Reason}` で設定を拒否し、揃っていれば受け取った
/// 設定 map を `persistent_term` へ退避して空のリストを返す。**`handle_event/1`
/// はエクスポートしない**（`examples/plugins/file_logger` と同じ形）。
pub fn config_source(module: String, name: String) -> String {
  module_source(module, [
    api_version_part("1"),
    name_part(binary_literal(name)),
    Exported(
      "plugin_children/1",
      "plugin_children(Config = #{<<\"path\">> := _}) ->
    persistent_term:put(?MODULE, Config),
    [];
plugin_children(_Config) -> {error, <<\"path is required\">>}.",
    ),
    handle_event_part(2),
  ])
}

/// `plugin_pages/0` だけを持ち、`plugin_page_content` を持たないプラグインの
/// Erlang ソース。片方だけの宣言の検証に使う。
pub fn pages_only_source(module: String, name: String) -> String {
  plugin_module(module, "1", binary_literal(name), [
    Exported(
      "plugin_pages/0",
      "plugin_pages() -> [#{<<\"key\">> => <<\"status\">>, <<\"title\">> => <<\"Status\">>}].",
    ),
  ])
}

/// `plugin_page_content/1` だけを持ち、`plugin_pages` を持たないプラグインの
/// Erlang ソース。片方だけの宣言の検証に使う。
pub fn page_content_only_source(module: String, name: String) -> String {
  plugin_module(module, "1", binary_literal(name), [
    Exported(
      "plugin_page_content/1",
      "plugin_page_content(_Key) -> #{<<\"sections\">> => []}.",
    ),
  ])
}

/// `plugin_page_action/3` だけを持ち、`plugin_pages` を持たないプラグインの
/// Erlang ソース。実行だけの宣言の検証に使う。
pub fn page_action_only_source(module: String, name: String) -> String {
  plugin_module(module, "1", binary_literal(name), [
    Exported(
      "plugin_page_action/3",
      "plugin_page_action(_Key, _Values, _Config) -> ok.",
    ),
  ])
}

/// `plugin_pages/0` と `plugin_page_content/1` を持つプラグインの Erlang
/// ソース。`plugin_pages` の本体を `pages_body`、`plugin_page_content` の本体を
/// `content_body`（どちらも Erlang の式）にする。一覧の検証（0 件、重複、形の
/// 不一致、キーの文字集合）と、`plugin_page_content` が落ちる・戻らない形の
/// 検証に使う。
pub fn pages_source(
  module: String,
  name: String,
  pages_body: String,
  content_body: String,
) -> String {
  plugin_module(module, "1", binary_literal(name), [
    Exported("plugin_pages/0", "plugin_pages() -> " <> pages_body <> "."),
    Exported(
      "plugin_page_content/1",
      "plugin_page_content(_Key) -> " <> content_body <> ".",
    ),
  ])
}

/// `plugin_pages/<pages_arity>` と `plugin_page_content/<content_arity>` を持つ
/// プラグインの Erlang ソース。`plugin_pages/2` の第 2 引数は変数 `Language` で、
/// `pages_body`（Erlang の式）から参照できる。`plugin_page_content` は空の
/// `sections` を返す。表示の言語を受け取るエクスポートの組み合わせとキーの照合の
/// 検証に使う。
pub fn ui_source(
  module: String,
  name: String,
  pages_arity: Int,
  content_arity: Int,
  pages_body: String,
) -> String {
  let pages_params = list.take(["_Config", "Language"], pages_arity)
  let content_params =
    list.take(["_Key", "_Config", "_Language"], content_arity)
  plugin_module(module, "1", binary_literal(name), [
    Exported(
      "plugin_pages/" <> int.to_string(pages_arity),
      "plugin_pages("
        <> string.join(pages_params, ", ")
        <> ") -> "
        <> pages_body
        <> ".",
    ),
    Exported(
      "plugin_page_content/" <> int.to_string(content_arity),
      "plugin_page_content("
        <> string.join(content_params, ", ")
        <> ") -> #{<<\"sections\">> => []}.",
    ),
  ])
}

/// 定数を返す関数 1 つだけを持つモジュールの Erlang ソース。プラグインが同梱する
/// 依存を模したもので、影（モジュール名前空間の衝突）の検証に使う。
pub fn value_source(module: String, value: Int) -> String {
  module_source(module, [
    Exported("value/0", "value() -> " <> int.to_string(value) <> "."),
  ])
}

/// `plugin_children/1` が退避した設定 map を読み出す。
pub fn last_config(module: String) -> Dynamic {
  saved(atom.create(module))
}

/// fixture やプラグインが `key` に退避した値。キーが無ければ、退避する関数が呼ばれて
/// いないというテストの失敗として落ちる。
pub fn saved(key: Atom) -> Dynamic {
  let value = persistent_term.get(key, dynamic.nil())
  assert value != dynamic.nil()
  value
}

/// fixture がモジュール名の atom をキーに退避した Pid を読み出す。キーが無ければ
/// `saved` と同じく落ちる。
pub fn last_pid(module: String) -> Pid {
  let absent = process.self()
  let pid = persistent_term.get(atom.create(module), absent)
  assert pid != absent
  pid
}

/// Erlang のソース文字列を `<outdir>/<module>.erl` へ書き出してコンパイルする。
/// `compile:file/2` は `-module` 宣言とファイル名の一致を要求するため、ファイル名
/// はモジュール名から決める。
pub fn compile(source: String, module: String, outdir: String) -> Nil {
  let path = outdir <> "/" <> module <> ".erl"
  write(path, source)
  compile_file(path, outdir)
}

/// `source` を `fixture.module` として `fixture.root` に compile し、`fixture.root` を
/// コードパスに足す。`plugin.load(atom.create(fixture.module), ..)` が読み込める。
pub fn compile_loadable(fixture: Fixture, source: String) -> Nil {
  compile(source, fixture.module, fixture.root)
  let assert Ok(Nil) = add_code_path(fixture.root)
    as { "failed to add to the code path: " <> fixture.root }
  Nil
}

/// 既存の `.erl` ファイルを指定ディレクトリーへコンパイルする。同梱の例
/// （`examples/plugins/file_logger`）をテストから読み込むために使う。
pub fn compile_file(source: String, outdir: String) -> Nil {
  let assert Ok(Nil) = compile_to(source, outdir)
    as { "failed to compile " <> source }
  Nil
}

/// BEAM として読めないゴミバイト列を書き出す。`code:ensure_loaded` は `badfile`
/// で失敗する。
pub fn write_garbage(path: String) -> Nil {
  write(path, string.repeat("not a beam file ", 4))
}

/// ディレクトリーを（親ごと）作る。
pub fn mkdir(path: String) -> Nil {
  // filelib:ensure_path/1 は ok か {error, Reason} を返す。後続の書き込みや
  // コンパイルが失敗すればそちらで気付けるので、ここでは戻り値を捨てる。
  let _ = ensure_path(path)
  Nil
}

/// パスの権限を `mode`（`0o755` など）にする。読めないディレクトリーを作るのに使う。
/// `build/tmp` は消されずに残るので、読めなくしたパスは assert の前に `0o755` へ戻す。
/// 失敗は後続の読み込みの結果で気付けるので、戻り値を捨てる。
pub fn change_mode(path: String, mode: Int) -> Nil {
  let _ = file_change_mode(path, mode)
  Nil
}

/// ファイルへ文字列を書き出す。`file:write_file/2` は binary（Gleam の String）を
/// そのまま受け付ける。
pub fn write(path: String, content: String) -> Nil {
  let _ = write_file(path, content)
  Nil
}

/// `<ebin>/<app>.app` に `{application, <app>, [{vsn, "<vsn>"}]}.` を書く。本体
/// 側の版の直読み（`nostr_no_su_plugin_ffi:read_app_file/1`）が読める最小の `.app`。
pub fn write_app_file(ebin: String, app: String, vsn: String) -> Nil {
  write(
    ebin <> "/" <> app <> ".app",
    "{application, " <> app <> ", [{vsn, \"" <> vsn <> "\"}]}.\n",
  )
}

/// ロード済みアプリの版。被検コード（`.app` の直読み）と別の経路
/// （`application:get_key/2`）で期待値を得るために使う。
@external(erlang, "beam_fixture", "loaded_app_version")
pub fn loaded_app_version(app: String) -> String

/// モジュールがコードパス上にあるか。エントリーモジュール規則の検証で、飛ばした
/// バンドルの ebin がコードパスへ入っていないことを確かめるのに使う。
pub fn on_code_path(module: String) -> Bool {
  is_on_code_path(atom.create(module))
}

/// `.erl` をコンパイルする。charlist への変換は Erlang 側で行う。
@external(erlang, "beam_fixture", "compile_to")
fn compile_to(source: String, outdir: String) -> Result(Nil, String)

/// 戻り値は `ok` か `{error, Reason}` なので Dynamic のまま受けて捨てる。
@external(erlang, "file", "write_file")
fn write_file(path: String, content: String) -> Dynamic

/// 戻り値は `ok` か `{error, Reason}` なので Dynamic のまま受けて捨てる。
@external(erlang, "filelib", "ensure_path")
fn ensure_path(path: String) -> Dynamic

/// `file:change_mode/2` は ok か {error, Reason} を返す。
@external(erlang, "file", "change_mode")
fn file_change_mode(path: String, mode: Int) -> Dynamic

/// ローダーが使うものと同じ判定。テストからも同じ問い合わせを行う。
@external(erlang, "nostr_no_su_plugin_ffi", "is_on_code_path")
fn is_on_code_path(module: Atom) -> Bool

/// ディレクトリーをコードパスの末尾に足す。
@external(erlang, "nostr_no_su_plugin_ffi", "add_code_path")
fn add_code_path(path: String) -> Result(Nil, String)
