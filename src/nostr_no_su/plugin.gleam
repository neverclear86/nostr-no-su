//// プラグイン機構とプラグイン API v1。
////
//// v1 の要点:
////
//// - プラグインは BEAM のモジュールで、`plugin_api_version/0`・`plugin_name/0`
////   と、`handle_event/1` **または** `handle_event/2` のどちらか一方を必ず
////   エクスポートする。未知のエクスポートは読み込みに影響しない。本体が使う
////   任意エクスポート（`plugin_children`、`plugin_required_versions`、
////   `plugin_pages`、`plugin_page_content`）は存在するときだけ呼ばれ、その
////   結果で読み込まれないことがある。
//// - イベント処理関数が受け取るイベントは **binary キーの Erlang map**
////   (`nostr_no_su/nostr/event.to_map` の形)。戻り値は無視する。
//// - **プラグイン固有の設定を受け取る口は「アリティ +1 の任意エクスポート」と
////   いう 1 つの規則で足す。** 設定は環境変数 `PLUGIN_<NAME>_<KEY>` から
////   `plugin_config` が切り出した binary キーの map で、`plugin_children/1` と
////   `handle_event/2` が第 1・第 2 引数として受け取る。どちらも `/0` `/1` が
////   あればそちらでも動くので、既存のプラグインは無変更で読み込まれる。
//// - **`handle_event` だけは必須側のアリティが 2 通りになる。** 設定が必須の
////   プラグインは `handle_event/1` を正しく書けない（設定が無いのだから既定値に
////   落とすか、落ちるだけの死んだ節を書くしかない）ため、`/1` または `/2` の
////   どちらか一方があればよいことにしている。**これは破壊的変更にあたらない。**
////   `handle_event/1` を持つ既存プラグインは 1 つも落ちず、必須エクスポートの
////   削除でもアリティの変更でもないので、**API バージョンは 1 のまま**である。
////   両方あれば `/2` を優先する。判定は**読み込み時に 1 度だけ**行い、設定 map
////   ごとクロージャーに捕捉するので、イベントごとのコストは増えない。
//// - 任意エクスポート `plugin_children/0` `plugin_children/1` があれば、その
////   プラグインが自分で起こしたいプロセスの子仕様（OTP の map）を申告できる。
////   `/1` があればそちらを優先し、設定 map を渡す。検証と変換は
////   `plugin_children` が行い、結果は `Plugin.children` に載る。子仕様の代わりに
////   `{error, Reason}` を返すと「設定が足りないので読み込まないでほしい」という
////   申告になり、そのプラグインだけが無効になる。
//// - 任意エクスポート `plugin_required_versions/0` があれば、依存する本体側の
////   アプリケーションと版（binary キー・binary 値の map）を宣言できる。読み込み
////   時にコードパス上の `.app` の版と完全一致で照合し、1 件でも合わなければその
////   プラグインを読み込まない。
//// - 任意エクスポート `plugin_pages/0` `plugin_pages/1`（ページの一覧）と
////   `plugin_page_content/1` `plugin_page_content/2`（1 ページの記述）が
////   あれば、そのプラグインは管理 UI のページを供給できる。どちらも無ければ
////   UI を持たない。片方だけでは読み込まない（`plugin_children` の不備と
////   同じ扱い）。`/1` `/2` があればそちらを優先し、設定 map を渡す。
////   `plugin_pages` は読み込み時に 1 度だけ検証するが、`plugin_page_content`
////   はページの表示のたびに期限付きで呼ぶ（起動時のメタデータの呼び出しには
////   含まれない）。仕様の全文は `docs/plugin-api.md` の第 13 章にある。
//// - 検証の順序はモジュールの読み込み → 必須エクスポート →
////   `plugin_api_version` → `plugin_required_versions` → `plugin_name` →
////   設定の切り出し → `plugin_children` → `plugin_pages` で、最初に失敗した
////   ところで止まる。**設定の切り出しは `plugin_name/0` の後にしかできない**
////   （環境変数の接頭辞がプラグイン名から決まるため）。
//// - モジュールの読み込み（`code:ensure_loaded/1`）とメタデータの呼び出し
////   （`plugin_api_version/0`、`plugin_required_versions/0`、`plugin_name/0`、
////   `plugin_children/0,1`、`plugin_pages/0,1`）は `main` のプロセスで起動時に
////   同期に行われるので、1 回ずつ使い捨てのプロセスで動かし `call_timeout_ms`
////   で打ち切る。戻らない
////   `-on_load` や戻らないメタデータの関数を持つプラグインは理由の 1 行で
////   読み込まれず、起動は続く。
//// - イベント処理関数はイベント 1 件ごとに作られる使い捨てのプロセスで動く
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

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/set
import gleam/string
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin_children
import nostr_no_su/plugin_config

/// プラグイン API のバージョン。プラグインの `plugin_api_version/0` はこの値と
/// 完全に一致しなければならない。
pub const api_version: Int = 1

/// メタデータ用のエクスポート 1 回の呼び出しを待つ上限（ミリ秒）で、`main` が
/// 渡す既定値。モジュールの読み込みとメタデータの関数は即座に戻る約束で、これは
/// 戻らないことを検出するための期限である。
pub const default_call_timeout_ms: Int = 5000

/// 本体が呼ぶイベント処理関数の名前。アリティは `/1` と `/2` の 2 通りある。
const handle_event_name = "handle_event"

/// 本体が読み込み時に照合する任意エクスポートの名前。
const required_versions_name = "plugin_required_versions"

/// 本体が問い合わせる、管理 UI のページ一覧を返す任意エクスポートの名前。
const pages_export_name = "plugin_pages"

/// 本体が問い合わせる、管理 UI の 1 ページの記述を返す任意エクスポートの名前。
const page_content_export_name = "plugin_page_content"

/// UI のページのキーに許す文字。`plugin_config.gleam` の `normalize` と同じく、
/// 許す文字を並べた定数と `string.contains` で判定する。
const page_key_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_-"

/// プラグインはバンカーに登録したアカウントから受信したすべてのイベントを処理する。
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
    /// 管理 UI のページの供給。`plugin_pages` と `plugin_page_content` の両方を
    /// 持たないプラグインは `None`。
    ui: Option(PluginUi),
  )
}

/// プラグインが供給するページ 1 つの識別。`key` は URL の path 片、`title` は
/// プラグイン由来の英語の表示名。
pub type PluginPage {
  PluginPage(key: String, title: String)
}

/// プラグインが供給する管理 UI。`pages` は読み込み時に検証した一覧（1 件以上、
/// キーは重複しない）。`content` はページのキーを受け取り、そのページの記述を
/// 期限付きで取る。失敗は 1 行の理由。
pub type PluginUi {
  PluginUi(
    pages: List(PluginPage),
    content: fn(String) -> Result(Dynamic, String),
  )
}

/// 期限付きの呼び出し（メタデータ用のエクスポートとモジュールの読み込み）が
/// 値を返さなかった理由。FFI の `{crashed, Reason}` と `timed_out` に対応する。
type CallFailure {
  /// 例外を投げたか、呼び出しのプロセスが異常終了したか、呼び出し自身が理由を
  /// 返した（`code:ensure_loaded/1` の `nofile` など）。理由は 1 行。
  Crashed(reason: String)
  /// 期限までに戻らなかった。
  TimedOut
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
///
/// `env` は `PLUGIN_*` の環境変数全体（`config.plugin_env`）で、プラグイン名が
/// 決まった時点でそのプラグインぶんだけを切り出す。切り出し済みの map を渡せない
/// のは、接頭辞の元になるプラグイン名がこの関数の中でしか分からないためである。
///
/// `call_timeout_ms` はモジュールの読み込みとメタデータ用のエクスポート 1 回
/// ごとの期限で、本番は `default_call_timeout_ms`。
pub fn load(
  module: Atom,
  env: Dict(String, String),
  call_timeout_ms: Int,
) -> Result(Plugin, String) {
  let name = atom.to_string(module)
  use _ <- result.try(
    ensure_module_loaded_within(module, call_timeout_ms)
    |> result.map_error(fn(failure) {
      let reason = case failure {
        Crashed(reason) -> reason
        TimedOut -> "timed out after " <> int.to_string(call_timeout_ms) <> "ms"
      }
      prefix(name, "cannot load module (" <> reason <> ")")
    }),
  )
  // `has_export` はイベントごとではなく読み込み時に 1 度だけ呼ぶ。必須エクスポート
  // の判定と、下のクロージャーが渡す引数の決定の両方でこの値を使う。
  let takes_config = has_export(module, handle_event_name, 2)
  use _ <- result.try(require_exports(module, name, takes_config))
  use _ <- result.try(check_api_version(module, name, call_timeout_ms))
  use _ <- result.try(check_required_versions(module, name, call_timeout_ms))
  use plugin_name <- result.try(read_plugin_name(module, name, call_timeout_ms))
  let config_map =
    plugin_config.to_map(plugin_config.for_plugin(env, plugin_name))
  use children <- result.try(read_children(
    module,
    name,
    plugin_name,
    config_map,
    call_timeout_ms,
  ))
  use ui <- result.try(read_ui(module, name, config_map, call_timeout_ms))
  // atom はイベントごとではなく読み込み時に 1 度だけ作り、クロージャーで捕捉する。
  let handle_event = atom.create(handle_event_name)
  let args = case takes_config {
    True -> fn(event_map) { [event_map, config_map] }
    False -> fn(event_map) { [event_map] }
  }
  Ok(
    Plugin(name: plugin_name, children: children, ui: ui, handle: fn(incoming) {
      // 戻り値はプラグインが自由に決めてよいので捨てる。例外はここで捕まえず、
      // ワーカープロセス側（`plugin_runner`）が短い理由に整えて観測する。
      let _ = apply(module, handle_event, args(event.to_map(incoming)))
      Nil
    }),
  )
}

/// 必須エクスポートの存在を宣言順に確かめ、最初に欠けたものを報告する。
/// イベント処理関数だけは `handle_event/1` **または** `handle_event/2` の
/// どちらか一方があればよい（`takes_config` は `/2` の有無）。
fn require_exports(
  module: Atom,
  name: String,
  takes_config: Bool,
) -> Result(Nil, String) {
  let required = [#("plugin_api_version", 0), #("plugin_name", 0)]
  use _ <- result.try(
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
    }),
  )
  case takes_config || has_export(module, handle_event_name, 1) {
    True -> Ok(Nil)
    False ->
      Error(prefix(
        name,
        "missing export "
          <> handle_event_name
          <> "/1 or "
          <> handle_event_name
          <> "/2",
      ))
  }
}

/// `plugin_api_version/0` を呼び、Int であることと `api_version` と一致すること
/// を確かめる。
fn check_api_version(
  module: Atom,
  name: String,
  call_timeout_ms: Int,
) -> Result(Nil, String) {
  use value <- result.try(call_export(
    module,
    name,
    "plugin_api_version",
    [],
    call_timeout_ms,
  ))
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

/// 任意エクスポート `plugin_required_versions/0` があれば期限付きで呼び、宣言
/// されたアプリケーションの版がコードパス上の `.app` の版と完全一致することを
/// 確かめる。エクスポートが無ければ照合しない。
fn check_required_versions(
  module: Atom,
  name: String,
  call_timeout_ms: Int,
) -> Result(Nil, String) {
  case has_export(module, required_versions_name, 0) {
    False -> Ok(Nil)
    True -> {
      use value <- result.try(call_export(
        module,
        name,
        required_versions_name,
        [],
        call_timeout_ms,
      ))
      use required <- result.try(
        decode.run(value, decode.dict(decode.string, decode.string))
        |> result.map_error(fn(errors) {
          prefix(
            name,
            required_versions_name
              <> "/0 must return a map of application names to version strings ("
              <> describe_decode_error(errors)
              <> ")",
          )
        }),
      )
      required
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.try_each(fn(pair) { check_required_version(name, pair.0, pair.1) })
    }
  }
}

/// アプリケーション 1 つの要求版を、コードパス上の版と照らし合わせる。
fn check_required_version(
  name: String,
  app: String,
  required: String,
) -> Result(Nil, String) {
  use found <- result.try(
    application_version(app)
    |> result.replace_error(prefix(
      name,
      "requires "
        <> app
        <> " "
        <> required
        <> ", but no "
        <> app
        <> ".app is on the code path",
    )),
  )
  case found == required {
    True -> Ok(Nil)
    False ->
      Error(prefix(
        name,
        "requires "
          <> app
          <> " "
          <> required
          <> ", but the code path provides "
          <> found,
      ))
  }
}

/// `decode` の最初のエラーを `expected X, got Y at a.b` の 1 行にする。エラーの
/// リストが空になることは `decode.run` の `Error` では起きないが、網羅のために
/// 節を置く。
fn describe_decode_error(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "invalid value"
    [error, ..] -> {
      let location = case error.path {
        [] -> ""
        path -> " at " <> string.join(path, ".")
      }
      "expected " <> error.expected <> ", got " <> error.found <> location
    }
  }
}

/// `plugin_name/0` を呼び、空でない String であることを確かめる。
fn read_plugin_name(
  module: Atom,
  name: String,
  call_timeout_ms: Int,
) -> Result(String, String) {
  use value <- result.try(call_export(
    module,
    name,
    "plugin_name",
    [],
    call_timeout_ms,
  ))
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

/// 任意エクスポート `plugin_children/1` か `plugin_children/0` があれば呼び、
/// 子仕様を検証する。**`/1` を優先し、設定 map を渡す。** エクスポートが無い
/// プラグインは子を持たない（エラーにしない）。API に合わない子仕様は、必須
/// エクスポートの不備と同じく**そのプラグインを読み込まない**理由になる。子だけ
/// 捨てて読み込むと、ランナーが起動して宛先を失ったイベント処理関数が 5 件後に
/// `disabled` になり、運用者が見る症状が真の原因から離れる。
fn read_children(
  module: Atom,
  name: String,
  plugin_name: String,
  config_map: Dynamic,
  call_timeout_ms: Int,
) -> Result(List(ChildSpecification(Pid)), String) {
  let export = plugin_children.export_name
  case has_export(module, export, 1), has_export(module, export, 0) {
    // 任意エクスポートを 1 つも持たないプラグインは子を持たない。ここで
    // 問い合わせると `call_export` が `undef` になる。
    False, False -> Ok([])
    True, _ ->
      children(module, name, plugin_name, [config_map], call_timeout_ms)
    False, True -> children(module, name, plugin_name, [], call_timeout_ms)
  }
}

/// `plugin_children` を期限付きで呼び、失敗を 1 行の理由に整える。設定の拒否の
/// ときだけ、運用者がそのまま `grep` や compose の編集に使えるよう環境変数の
/// 接頭辞を添える。
fn children(
  module: Atom,
  name: String,
  plugin_name: String,
  args: List(Dynamic),
  call_timeout_ms: Int,
) -> Result(List(ChildSpecification(Pid)), String) {
  use value <- result.try(call_export(
    module,
    name,
    plugin_children.export_name,
    args,
    call_timeout_ms,
  ))
  plugin_children.from_dynamic(value, plugin_name, list.length(args))
  |> result.map_error(fn(rejection) {
    case rejection {
      plugin_children.InvalidSpec(reason) -> prefix(name, reason)
      plugin_children.ConfigRejected(reason) ->
        prefix(
          name,
          plugin_children.export_label(list.length(args))
            <> " rejected the configuration ("
            <> reason
            <> "); configure it with "
            <> plugin_config.prefix(plugin_name)
            <> "*",
        )
    }
  })
}

/// 任意エクスポート `plugin_pages/0` `/1` と `plugin_page_content/1` `/2` の
/// 有無を見て、管理 UI の供給を読み込む。どちらも無ければ `Ok(None)`、片方だけ
/// なら `Error`（`read_children` と同じく、症状を真の原因に近い場所で報告する
/// ため）。両方あれば `plugin_pages` を期限付きで呼んで一覧を検証する。`/1`
/// `/2` を優先して設定 map を渡す。
fn read_ui(
  module: Atom,
  name: String,
  config_map: Dynamic,
  call_timeout_ms: Int,
) -> Result(Option(PluginUi), String) {
  let has_pages_0 = has_export(module, pages_export_name, 0)
  let has_pages_1 = has_export(module, pages_export_name, 1)
  let has_content_1 = has_export(module, page_content_export_name, 1)
  let has_content_2 = has_export(module, page_content_export_name, 2)
  case has_pages_0 || has_pages_1, has_content_1 || has_content_2 {
    False, False -> Ok(None)
    False, True ->
      Error(prefix(
        name,
        content_label(has_content_2)
          <> " but no "
          <> pages_export_name
          <> "/0 or /1",
      ))
    True, False ->
      Error(prefix(
        name,
        pages_label(has_pages_1)
          <> " but no "
          <> page_content_export_name
          <> "/1 or /2",
      ))
    True, True -> {
      let label = pages_label(has_pages_1)
      let args = case has_pages_1 {
        True -> [config_map]
        False -> []
      }
      use value <- result.try(call_export(
        module,
        name,
        pages_export_name,
        args,
        call_timeout_ms,
      ))
      use pages <- result.try(decode_pages(value, name, label))
      Ok(
        Some(PluginUi(
          pages: pages,
          content: content_of(
            module,
            name,
            config_map,
            call_timeout_ms,
            has_content_2,
          ),
        )),
      )
    }
  }
}

/// `plugin_pages` の理由の文字列に出すラベル。`/1` があればそちらを優先する。
fn pages_label(has_pages_1: Bool) -> String {
  case has_pages_1 {
    True -> pages_export_name <> "/1"
    False -> pages_export_name <> "/0"
  }
}

/// `plugin_page_content` の理由の文字列に出すラベル。`/2` があればそちらを
/// 優先する。
fn content_label(has_content_2: Bool) -> String {
  case has_content_2 {
    True -> page_content_export_name <> "/2"
    False -> page_content_export_name <> "/1"
  }
}

/// `plugin_pages` の戻り値をページの一覧に変換する。決めたこと 3 の検査
/// （形、0 件、重複、文字集合）を順に当てる。
fn decode_pages(
  value: Dynamic,
  name: String,
  label: String,
) -> Result(List(PluginPage), String) {
  use raw <- result.try(
    decode.run(value, decode.list(decode.dynamic))
    |> result.replace_error(prefix(
      name,
      label
        <> " must return a list of page maps, got "
        <> dynamic.classify(value),
    )),
  )
  use pages <- result.try(
    raw
    |> list.index_map(fn(page, index) { #(page, index) })
    |> list.try_map(fn(pair) { decode_page(pair.0, pair.1, label) })
    |> result.map_error(fn(reason) { prefix(name, reason) }),
  )
  case pages {
    [] -> Error(prefix(name, label <> " must return at least one page"))
    _ ->
      case find_duplicate_page_key(pages) {
        Some(key) ->
          Error(prefix(name, label <> ": duplicate page key \"" <> key <> "\""))
        None -> Ok(pages)
      }
  }
}

/// ページの記述 1 件を検証する。`key` が読める前は `page #<index>`、読めた後は
/// `page key "<key>"` で位置を示す（`plugin_children.spec` と同じ考え方）。
fn decode_page(
  raw: Dynamic,
  index: Int,
  label: String,
) -> Result(PluginPage, String) {
  let unlabelled = label <> ": page #" <> int.to_string(index)
  use _ <- result.try(check_page_map(raw, unlabelled))
  use key <- result.try(required_page_field(raw, "key", unlabelled))
  case page_key_ok(key) {
    False ->
      Error(label <> ": page key \"" <> key <> "\" must match [a-z0-9_-]+")
    True -> {
      let labelled = label <> ": page key \"" <> key <> "\""
      use title <- result.try(required_page_field(raw, "title", labelled))
      Ok(PluginPage(key: key, title: title))
    }
  }
}

/// ページの記述が map であることを先に確かめる。map でない要素（例えば
/// `{key, title}` のタプル）を渡されたとき、キーが 1 つも読めないことを
/// 「`key` が無い」と報告すると作者が原因にたどり着けない
/// （`plugin_children.check_map` と同じ考え方）。
fn check_page_map(raw: Dynamic, label: String) -> Result(Nil, String) {
  case dynamic.classify(raw) {
    "Dict" -> Ok(Nil)
    other -> Error(label <> ": must be a page map, got " <> other)
  }
}

/// `page_key_alphabet` だけからなり、空でないこと。
fn page_key_ok(key: String) -> Bool {
  key != ""
  && key
  |> string.to_graphemes
  |> list.all(fn(character) { string.contains(page_key_alphabet, character) })
}

/// ページの一覧の中で最初に重複したキーを探す。
fn find_duplicate_page_key(pages: List(PluginPage)) -> Option(String) {
  find_duplicate_page_key_loop(pages, set.new())
}

/// `find_duplicate_page_key` の実体。`seen` に見たキーを積みながら 1 件ずつ確かめる。
fn find_duplicate_page_key_loop(
  pages: List(PluginPage),
  seen: set.Set(String),
) -> Option(String) {
  case pages {
    [] -> None
    [page, ..rest] ->
      case set.contains(seen, page.key) {
        True -> Some(page.key)
        False -> find_duplicate_page_key_loop(rest, set.insert(seen, page.key))
      }
  }
}

/// ページの記述の必須フィールドを binary キーの map から読む。欠けていれば
/// `<label>: missing <key>`、String でなければ型の不一致を報告する。
fn required_page_field(
  raw: Dynamic,
  key: String,
  label: String,
) -> Result(String, String) {
  let decoder =
    decode.optional_field(
      key,
      None,
      decode.map(decode.dynamic, Some),
      decode.success,
    )
  case decode.run(raw, decoder) |> result.unwrap(None) {
    None -> Error(label <> ": missing " <> key)
    Some(value) ->
      decode.run(value, decode.string)
      |> result.replace_error(
        label
        <> ": "
        <> key
        <> " must be a String, got "
        <> dynamic.classify(value),
      )
  }
}

/// ページの中身を取得するクロージャーを組み立てる。`/2` があれば設定 map も
/// 渡す。失敗（例外・期限超過）は `call_export` がそのまま 1 行の理由にする。
fn content_of(
  module: Atom,
  name: String,
  config_map: Dynamic,
  call_timeout_ms: Int,
  has_content_2: Bool,
) -> fn(String) -> Result(Dynamic, String) {
  fn(key: String) {
    let args = case has_content_2 {
      True -> [dynamic.string(key), config_map]
      False -> [dynamic.string(key)]
    }
    call_export(module, name, page_content_export_name, args, call_timeout_ms)
  }
}

/// プラグインのエクスポートを使い捨てのプロセスで期限付きで呼ぶ。失敗は
/// モジュール名と `関数/アリティ` を付けた 1 行（`crashed (...)` か
/// `timed out after <ms>ms`）にする。アリティは `args` の長さから決まる。
fn call_export(
  module: Atom,
  name: String,
  function: String,
  args: List(Dynamic),
  call_timeout_ms: Int,
) -> Result(Dynamic, String) {
  let label = function <> "/" <> int.to_string(list.length(args))
  call_export_within(module, atom.create(function), args, call_timeout_ms)
  |> result.map_error(fn(failure) {
    case failure {
      Crashed(reason) -> prefix(name, label <> " crashed (" <> reason <> ")")
      TimedOut ->
        prefix(
          name,
          label <> " timed out after " <> int.to_string(call_timeout_ms) <> "ms",
        )
    }
  })
}

/// 失敗理由にモジュール名を付ける。
fn prefix(module_name: String, reason: String) -> String {
  module_name <> ": " <> reason
}

/// 未読み込みのモジュールに対しては常に `False` を返すため、`load` の入口で
/// `ensure_module_loaded_within` を通してから使う。3 引数すべてが atom でなければ
/// `badarg` で落ちるので、関数名は `atom.create` を通す。
@external(erlang, "erlang", "function_exported")
fn function_exported(module: Atom, function: Atom, arity: Int) -> Bool

/// 戻り値の型はプラグインが決めるので `Dynamic` のままにする。呼び出し側で
/// 捨てること。
@external(erlang, "erlang", "apply")
fn apply(module: Atom, function: Atom, args: List(Dynamic)) -> Dynamic

/// モジュールをコードパスから期限付きで読み込む。`-on_load` が戻らない
/// モジュールを検出するため、使い捨てのプロセスで動かす。
@external(erlang, "nostr_no_su_ffi", "ensure_module_loaded_within")
fn ensure_module_loaded_within(
  module: Atom,
  timeout_ms: Int,
) -> Result(Nil, CallFailure)

/// 例外と戻らない呼び出しを `CallFailure` にしてエクスポートを呼ぶ。
@external(erlang, "nostr_no_su_ffi", "call_export_within")
fn call_export_within(
  module: Atom,
  function: Atom,
  args: List(Dynamic),
  timeout_ms: Int,
) -> Result(Dynamic, CallFailure)

/// コードパス上で最初に見つかる `<app>.app` の `vsn`。
@external(erlang, "nostr_no_su_ffi", "application_version")
fn application_version(app: String) -> Result(String, Nil)
