//// プラグイン機構とプラグイン API v1。
////
//// v1 の要点:
////
//// - プラグインは BEAM のモジュールで、`plugin_api_version/0`・`plugin_name/0`・
////   `handle_event/1` の 3 つを必ずエクスポートする。それ以外のエクスポートは
////   すべて任意で、あっても無くても読み込み判定に影響しない。
//// - `handle_event/1` が受け取るイベントは **binary キーの Erlang map**
////   (`nostr_no_su/nostr/event.to_map` の形)。戻り値は無視する。
//// - 任意エクスポート `plugin_children/0` があれば、そのプラグインが自分で
////   起こしたいプロセスの子仕様（OTP の map）を申告できる。検証と変換は
////   `plugin_children` が行い、結果は `Plugin.children` に載る。検証の順序は
////   `plugin_api_version` → `plugin_name` → `plugin_children` で、最初に失敗した
////   ところで止まる。プラグイン固有の設定を渡す必要が出たら、任意エクスポート
////   `plugin_children/1` を足して存在すればそちらを優先する（必須エクスポートの
////   集合は変わらないので API バージョンは上げない）。
//// - `handle_event/1` はイベント 1 件ごとに作られる使い捨てのプロセスで動く
////   （`plugin_runner`）。このモジュールが組み立てる `handle` クロージャーは
////   例外を捕まえない。捕捉はワーカープロセスの中で行われ、その目的は隔離では
////   なく終了理由を短い 1 行に整えることである。隔離そのものはプロセスの境界が
////   担っており、失敗の観測とその後の方針（連続失敗による無効化など）の判断は
////   すべてランナーが行う。
////
//// 仕様の全文（プラグイン作者向け）は `docs/plugin-api.md` にある。
////
//// コードパスの追加（`code:add_pathz/1`）とプラグインディレクトリの走査はこの
//// モジュールの担当ではない。ここが持つのは「モジュール 1 つを検証して `Plugin`
//// にする」ところまでで、`code:ensure_loaded/1` は検証と不可分なのでここに含める。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin_children

/// プラグイン API のバージョン。プラグインの `plugin_api_version/0` はこの値と
/// 完全に一致しなければならない。
pub const api_version: Int = 1

/// プラグインは監視対象アカウントから受信したすべてのイベントを処理する。
/// 状態を持つプラグインは、`handle` クロージャーの中で自前のアクターへの
/// `Subject` を捕捉できる。
///
/// `handle` はプラグインごとのランナーが起こす使い捨てのプロセス上で呼ばれる。
/// 呼び出し側のプロセスに載らないため、時間のかかる処理でも本体は止まらない。
///
/// `Plugin` は本体内蔵のプラグイン（`plugins/console_logger` など）と外部
/// プラグイン（`load` が組み立てるもの）の両方を表す。外部プラグインの `handle`
/// は `erlang:apply/3` を包んだクロージャーである。なお「API バージョンを上げ
/// ない」という約束はプラグインモジュールのエクスポート仕様に対するもので、
/// 本体内部のこのレコードは自由に拡張してよい。
pub type Plugin {
  Plugin(
    name: String,
    /// 起動時に 1 度だけ解決した子プロセスの仕様。内蔵プラグインは空。
    children: List(ChildSpecification(Pid)),
    handle: fn(Event) -> Nil,
  )
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
  use children <- result.try(read_children(module, name, plugin_name))
  // atom はイベントごとではなく読み込み時に 1 度だけ作り、クロージャーで捕捉する。
  let handle_event = atom.create("handle_event")
  Ok(
    Plugin(name: plugin_name, children: children, handle: fn(incoming) {
      // 戻り値はプラグインが自由に決めてよいので捨てる。例外はここで捕まえず、
      // ワーカープロセス側（`plugin_runner`）が短い理由に整えて観測する。
      let _ = apply(module, handle_event, [event.to_map(incoming)])
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

/// 任意エクスポート `plugin_children/0` があれば呼び、子仕様を検証する。
/// エクスポートが無いプラグインは子を持たない（エラーにしない）。API に合わない
/// 子仕様は、必須エクスポートの不備と同じく**そのプラグインを読み込まない**理由に
/// なる。子だけ捨てて読み込むと、ランナーが起動して宛先を失った `handle_event/1`
/// が 5 件後に `disabled` になり、運用者が見る症状が真の原因から離れる。
fn read_children(
  module: Atom,
  name: String,
  plugin_name: String,
) -> Result(List(ChildSpecification(Pid)), String) {
  case has_export(module, plugin_children.export_name, 0) {
    False -> Ok([])
    True ->
      plugin_children.from_export(module, plugin_name)
      |> result.map_error(prefix(name, _))
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
