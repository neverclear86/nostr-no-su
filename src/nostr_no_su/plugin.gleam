//// プラグイン機構とプラグイン API v1。
////
//// v1 の要点:
////
//// - プラグインは BEAM のモジュールで、`plugin_api_version/0`・`plugin_name/0`・
////   `handle_event/1` の 3 つを必ずエクスポートする。それ以外のエクスポートは
////   すべて任意で、あっても無くても読み込み判定に影響しない。
//// - `handle_event/1` が受け取るイベントは **binary キーの Erlang map**
////   (`nostr_no_su/nostr/event.to_map` の形)。戻り値は無視する。
//// - `handle_event/1` の例外は握り潰さずディスパッチャーへ伝播する。障害の隔離
////   は専用プロセスを導入する別の変更で行う。ここで捕まえると、隔離が働いている
////   かどうかを検証できなくなる。
////
//// 仕様の全文（プラグイン作者向け）は `docs/plugin-api.md` にある。
////
//// コードパスの追加（`code:add_pathz/1`）とプラグインディレクトリの走査はこの
//// モジュールの担当ではない。ここが持つのは「モジュール 1 つを検証して `Plugin`
//// にする」ところまでで、`code:ensure_loaded/1` は検証と不可分なのでここに含める。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/result
import nostr_no_su/nostr/event.{type Event}

/// プラグイン API のバージョン。プラグインの `plugin_api_version/0` はこの値と
/// 完全に一致しなければならない。
pub const api_version: Int = 1

/// プラグインは監視対象アカウントから受信したすべてのイベントを処理する。
/// 状態を持つプラグインは、`handle` クロージャーの中で自前のアクターへの
/// `Subject` を捕捉できる。
///
/// `Plugin` は本体内蔵のプラグイン（`plugins/console_logger` など）と外部
/// プラグイン（`load` が組み立てるもの）の両方を表す。外部プラグインの `handle`
/// は `erlang:apply/3` を包んだクロージャーである。なお「API バージョンを上げ
/// ない」という約束はプラグインモジュールのエクスポート仕様に対するもので、
/// 本体内部のこのレコードは自由に拡張してよい。
pub type Plugin {
  Plugin(name: String, handle: fn(Event) -> Nil)
}

/// イベント 1 件をすべてのプラグインに渡す。プラグインは登録順に実行する。
pub fn dispatch(plugins: List(Plugin), event: Event) -> Nil {
  list.each(plugins, fn(plugin) { plugin.handle(event) })
}

/// モジュールが指定した名前・アリティの関数をエクスポートしているか。任意
/// エクスポートの有無を問い合わせるためのプリミティブで、本体は真のときだけ
/// その関数を呼ぶ。
///
/// **`load` が成功したモジュールに対して呼ぶことを前提とする。**
/// `erlang:function_exported/3` は未読み込みのモジュールに対して常に `False` を
/// 返すため、読み込み前に呼ぶと「関数が無い」と区別が付かない。
/// `code:ensure_loaded/1` の呼び出しを `load` の 1 か所に集約するための判断で、
/// 任意エクスポートを探す側は必ず `load` を通った後なので実害はない。
pub fn has_export(module: Atom, name: String, arity: Int) -> Bool {
  function_exported(module, atom.create(name), arity)
}

/// モジュールを読み込み、プラグイン API v1 を満たすことを検証して `Plugin` に
/// する。失敗理由は先頭にモジュール名を付けた 1 行で、そのままログに出せる。
pub fn load(module: Atom) -> Result(Plugin, String) {
  let name = atom.to_string(module)
  use _ <- result.try(
    ensure_module_loaded(module)
    |> result.map_error(fn(reason) {
      prefix(name, "cannot load module (" <> reason <> ")")
    }),
  )
  use _ <- result.try(require_exports(module, name))
  use _ <- result.try(check_api_version(module, name))
  use plugin_name <- result.try(read_plugin_name(module, name))
  Ok(
    Plugin(name: plugin_name, handle: fn(incoming) {
      // 戻り値はプラグインが自由に決めてよいので捨てる。例外は捕まえない。
      let _ =
        apply(module, atom.create("handle_event"), [event.to_map(incoming)])
      Nil
    }),
  )
}

/// 必須エクスポートの存在を宣言順に確かめ、最初に欠けたものを報告する。
fn require_exports(module: Atom, name: String) -> Result(Nil, String) {
  let required = [
    #("plugin_api_version", 0),
    #("plugin_name", 0),
    #("handle_event", 1),
  ]
  list.try_each(required, fn(export) {
    let #(function, arity) = export
    case has_export(module, function, arity) {
      True -> Ok(Nil)
      False ->
        Error(prefix(
          name,
          "missing export " <> function <> "/" <> int.to_string(arity),
        ))
    }
  })
}

/// `plugin_api_version/0` を呼び、Int であることと `api_version` と一致すること
/// を確かめる。
fn check_api_version(module: Atom, name: String) -> Result(Nil, String) {
  use value <- result.try(meta(module, name, "plugin_api_version"))
  use version <- result.try(
    decode.run(value, decode.int)
    |> result.replace_error(prefix(
      name,
      "plugin_api_version/0 must return an Int, got " <> dynamic.classify(value),
    )),
  )
  case version == api_version {
    True -> Ok(Nil)
    False ->
      Error(prefix(
        name,
        "unsupported api version "
          <> int.to_string(version)
          <> " (expected "
          <> int.to_string(api_version)
          <> ")",
      ))
  }
}

/// `plugin_name/0` を呼び、空でない String であることを確かめる。
fn read_plugin_name(module: Atom, name: String) -> Result(String, String) {
  use value <- result.try(meta(module, name, "plugin_name"))
  use plugin_name <- result.try(
    decode.run(value, decode.string)
    |> result.replace_error(prefix(
      name,
      "plugin_name/0 must return a String, got " <> dynamic.classify(value),
    )),
  )
  case plugin_name {
    "" -> Error(prefix(name, "plugin_name/0 must not be empty"))
    _ -> Ok(plugin_name)
  }
}

/// メタデータ用のエクスポートを引数なしで呼ぶ。壊れたモジュールが本体の起動を
/// 止めないよう、例外は理由の文字列に変える。
fn meta(
  module: Atom,
  name: String,
  function: String,
) -> Result(Dynamic, String) {
  call_export(module, atom.create(function), [])
  |> result.map_error(fn(reason) {
    prefix(name, function <> "/0 crashed (" <> reason <> ")")
  })
}

/// 失敗理由にモジュール名を付ける。
fn prefix(module_name: String, reason: String) -> String {
  module_name <> ": " <> reason
}

/// 未読み込みのモジュールに対しては常に `False` を返すため、`load` の入口で
/// `ensure_module_loaded` を通してから使う。3 引数すべてが atom でなければ
/// `badarg` で落ちるので、関数名は `atom.create` を通す。
@external(erlang, "erlang", "function_exported")
fn function_exported(module: Atom, function: Atom, arity: Int) -> Bool

/// 戻り値の型はプラグインが決めるので `Dynamic` のままにする。呼び出し側で
/// 捨てること。
@external(erlang, "erlang", "apply")
fn apply(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic

/// モジュールをコードパスから読み込む。失敗理由（`nofile` など）は文字列で返る。
@external(erlang, "nostr_no_su_ffi", "ensure_module_loaded")
fn ensure_module_loaded(module: Atom) -> Result(Nil, String)

/// 例外を捕まえてメタデータ用のエクスポートを呼ぶ。理由は 1 行の文字列になる。
@external(erlang, "nostr_no_su_ffi", "call_export")
fn call_export(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
) -> Result(Dynamic, String)
