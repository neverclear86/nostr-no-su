//// ローダーのテストが使う一時ディレクトリーと BEAM を用意するヘルパー。
////
//// gleeunit は `test/` 配下の全ファイルを eunit に渡すため、関数名を `_test` で
//// 終わらせてはならない。
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
import gleam/string

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

/// 必須 3 関数を持ち、`plugin_name/0` の本体を `body`（Erlang の式）にした
/// プラグインのソース。メタデータの呼び出しが戻らない、プロセスごと終わると
/// いった形の検証に使う。
pub fn plugin_name_body_source(
  module: String,
  version: Int,
  body: String,
) -> String {
  "-module(" <> module <> ").
-export([plugin_api_version/0, plugin_name/0, handle_event/1]).
plugin_api_version() -> " <> int.to_string(version) <> ".
plugin_name() -> " <> body <> ".
handle_event(Event) ->
    persistent_term:put(?MODULE, Event),
    ok.
"
}

/// 必須 3 関数をエクスポートする最小プラグインの Erlang ソース。
/// `handle_event/1` は受け取った map を `persistent_term` へ退避するので、
/// イベントが実際に届いたことをテストから確認できる。キーはモジュール名の atom
/// なので、fixture 同士で衝突しない。
pub fn plugin_source(module: String, version: Int, name: String) -> String {
  plugin_name_body_source(module, version, "<<\"" <> name <> "\">>")
}

/// 任意エクスポート `plugin_children/0` を持つプラグインの Erlang ソース。
/// `store` は子プロセスが自分で登録する名前で、**テストごとに一意にすること**
/// （BEAM の登録名は VM 全体で共有）。`-export` は関数定義より前に置く必要が
/// あるため、`plugin_source` に継ぎ足さずソース全体をここで組み立てる。
pub fn children_source(module: String, name: String, store: String) -> String {
  "-module(" <> module <> ").
-export([plugin_api_version/0, plugin_name/0, plugin_children/0, handle_event/1]).
-export([start_link/0]).
plugin_api_version() -> 1.
plugin_name() -> <<\"" <> name <> "\">>.
plugin_children() ->
    [#{id => " <> store <> ",
       start => {?MODULE, start_link, []},
       restart => permanent,
       shutdown => 5000,
       type => worker}].
start_link() ->
    Pid = spawn_link(fun() -> receive stop -> ok end end),
    register(" <> store <> ", Pid),
    {ok, Pid}.
handle_event(Event) ->
    persistent_term:put(?MODULE, Event),
    ok.
"
}

/// プラグイン固有の設定を受け取るプラグインの Erlang ソース。`plugin_children/1`
/// は `path` が無ければ `{error, Reason}` で設定を拒否し、揃っていれば受け取った
/// 設定 map を `persistent_term` へ退避して空のリストを返す。**`handle_event/1`
/// はエクスポートしない**（`examples/plugins/file_logger` と同じ形）。
pub fn config_source(module: String, name: String) -> String {
  "-module(" <> module <> ").
-export([plugin_api_version/0, plugin_name/0, plugin_children/1, handle_event/2]).
plugin_api_version() -> 1.
plugin_name() -> <<\"" <> name <> "\">>.
plugin_children(Config = #{<<\"path\">> := _}) ->
    persistent_term:put(?MODULE, Config),
    [];
plugin_children(_Config) -> {error, <<\"path is required\">>}.
handle_event(_Event, _Config) -> ok.
"
}

/// `plugin_children/0` が API に合わない子仕様（`id` 無し）を返すプラグインの
/// Erlang ソース。
pub fn bad_children_source(module: String, name: String) -> String {
  "-module(" <> module <> ").
-export([plugin_api_version/0, plugin_name/0, plugin_children/0, handle_event/1]).
plugin_api_version() -> 1.
plugin_name() -> <<\"" <> name <> "\">>.
plugin_children() -> [#{start => {?MODULE, handle_event, [ignored]}}].
handle_event(_Event) -> ok.
"
}

/// 定数を返す関数 1 つだけを持つモジュールの Erlang ソース。プラグインが同梱する
/// 依存を模したもので、影（モジュール名前空間の衝突）の検証に使う。
pub fn value_source(module: String, value: Int) -> String {
  "-module(" <> module <> ").
-export([value/0]).
value() -> " <> int.to_string(value) <> ".
"
}

/// `handle_event/1` が退避したイベント map を読み出す。
pub fn last_event(module: String) -> Dynamic {
  saved(module)
}

/// `plugin_children/1` が退避した設定 map を読み出す。
pub fn last_config(module: String) -> Dynamic {
  saved(module)
}

/// fixture がモジュール名の atom をキーに退避した値。
fn saved(module: String) -> Dynamic {
  persistent_term_get(atom.create(module))
}

/// fixture がモジュール名の atom をキーに退避した Pid を読み出す。
pub fn last_pid(module: String) -> Pid {
  persistent_term_get_pid(atom.create(module))
}

/// Erlang のソース文字列を `<outdir>/<module>.erl` へ書き出してコンパイルする。
/// `compile:file/2` は `-module` 宣言とファイル名の一致を要求するため、ファイル名
/// はモジュール名から決める。
pub fn compile(source: String, module: String, outdir: String) -> Nil {
  let path = outdir <> "/" <> module <> ".erl"
  write(path, source)
  compile_file(path, outdir)
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

/// ファイルへ文字列を書き出す。`file:write_file/2` は binary（Gleam の String）を
/// そのまま受け付ける。
pub fn write(path: String, content: String) -> Nil {
  let _ = write_file(path, content)
  Nil
}

/// モジュールがコードパス上にあるか。エントリーモジュール規則の検証で、飛ばした
/// バンドルの ebin がコードパスへ入っていないことを確かめるのに使う。
pub fn on_code_path(module: String) -> Bool {
  is_on_code_path(atom.create(module))
}

/// テストごとに一意な整数。`[positive]` で常に正の値になる。
@external(erlang, "erlang", "unique_integer")
fn unique_integer(options: List(Atom)) -> Int

/// `.erl` をコンパイルする。charlist への変換は Erlang 側で行う。
@external(erlang, "beam_fixture", "compile_to")
fn compile_to(source: String, outdir: String) -> Result(Nil, String)

/// 戻り値は `ok` か `{error, Reason}` なので Dynamic のまま受けて捨てる。
@external(erlang, "file", "write_file")
fn write_file(path: String, content: String) -> Dynamic

/// 戻り値は `ok` か `{error, Reason}` なので Dynamic のまま受けて捨てる。
@external(erlang, "filelib", "ensure_path")
fn ensure_path(path: String) -> Dynamic

/// 退避したイベント map。キーが無ければ `badarg` で落ちるが、それは
/// `handle_event/1` が呼ばれていないというテストの失敗そのものである。
@external(erlang, "persistent_term", "get")
fn persistent_term_get(key: Atom) -> Dynamic

/// 退避した Pid。`persistent_term_get` とは戻り値の型だけが異なるため別に
/// 宣言する。
@external(erlang, "persistent_term", "get")
fn persistent_term_get_pid(key: Atom) -> Pid

/// ローダーが使うものと同じ判定。テストからも同じ問い合わせを行う。
@external(erlang, "nostr_no_su_ffi", "is_on_code_path")
fn is_on_code_path(module: Atom) -> Bool
