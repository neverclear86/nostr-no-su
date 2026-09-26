//// プラグイン API v1。モジュール 1 つを読み込んで検証し、`Plugin` にする。
//// `code:ensure_loaded/1` は検証と不可分なのでここに含めるが、コードパスの
//// 追加（`code:add_pathz/1`）とプラグインディレクトリの走査は担当外である。
////
//// 検証はモジュールの読み込み → 必須エクスポート → `plugin_api_version` →
//// `plugin_min_host_version` → `plugin_required_versions` → `plugin_name` →
//// 設定の切り出し → `plugin_children` → `plugin_pages` の順で、最初に
//// 失敗したところで止まる。設定の切り出しは `plugin_name/0` の後にしか
//// できない（環境変数の接頭辞がプラグイン名から決まるため）。
////
//// モジュールの読み込みとメタデータ用のエクスポートの呼び出しは起動時に
//// `main` のプロセスで同期に行われるため、1 回ずつ使い捨てのプロセスで
//// 動かし `call_timeout_ms` で打ち切る。戻らない `-on_load` やメタデータの
//// 関数を持つプラグインは理由の 1 行で読み込まれず、起動は続く。
////
//// 仕様の全文（プラグイン作者向け）は `docs/plugin-api.md` にある。

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/set
import gleam/string
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/plugin_children
import nostr_no_su/plugin_config
import nostr_no_su/plugin_term.{BinaryKey}

/// プラグイン API のバージョン。プラグインの `plugin_api_version/0` はこの値と
/// 完全に一致しなければならない。
const api_version: Int = 1

/// 読み込み時に `plugin_pages/2` を呼ぶ言語のコード。管理 UI の表示の言語
/// （`admin/i18n` の `languages`）と同じ並びで、先頭の言語の一覧をページのキーの
/// 基準にする。
pub const page_languages: List(String) = ["en", "ja"]

/// メタデータ用のエクスポート 1 回の呼び出しを待つ上限（ミリ秒）で、`main` が
/// 渡す既定値。モジュールの読み込みとメタデータの関数は即座に戻る約束で、これは
/// 戻らないことを検出するための期限である。
pub const default_call_timeout_ms: Int = 5000

/// プラグインの API の版を返す必須エクスポートの名前。
const api_version_export = "plugin_api_version"

/// プラグイン名を返す必須エクスポートの名前。
const name_export = "plugin_name"

/// 本体が呼ぶイベント処理関数の名前。アリティは `/1` と `/2` の 2 通りある。
const handle_event_export = "handle_event"

/// 本体の版の下限を宣言する任意エクスポートの名前。
const min_host_version_export = "plugin_min_host_version"

/// 依存する本体側アプリケーションの版を宣言する任意エクスポートの名前。
const required_versions_export = "plugin_required_versions"

/// 本体の版を載せた `.app` のアプリケーション名。
const host_app_name = "nostr_no_su"

/// 理由の文字列に出す本体の名前。
const host_display_name = "nostr-no-su"

/// 管理 UI のページ一覧を返す任意エクスポートの名前。
const pages_export = "plugin_pages"

/// 管理 UI の 1 ページの記述を返す任意エクスポートの名前。
const page_content_export = "plugin_page_content"

/// 管理 UI の 1 ページのフォームの送信を受け取る任意エクスポートの名前。
const page_action_export = "plugin_page_action"

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

/// プラグインが供給するページ 1 つの識別。`key` は URL の path 片で、表示名は
/// `title_in` で引く。
pub type PluginPage {
  /// 表示の言語を受け取らないプラグインのページ。`title` はプラグイン由来の
  /// 英語の表示名。
  PluginPage(key: String, title: String)
  /// `plugin_pages/2` と `plugin_page_content/3` を持つプラグインのページ。
  /// `titles` は `page_languages` の言語のコードから表示名への対応で、ページの
  /// 記述もその言語で返る。
  LocalizedPage(key: String, titles: Dict(String, String))
}

/// `language`（言語のコード）で出すページの表示名。`PluginPage` は言語によらず
/// `title`、`LocalizedPage` はその言語の表示名で、対応が無ければ `key` を返す。
pub fn title_in(page: PluginPage, language: String) -> String {
  case page {
    PluginPage(title:, ..) -> title
    LocalizedPage(key:, titles:) ->
      dict.get(titles, language) |> result.unwrap(key)
  }
}

/// 表示の言語が `language` のとき、そのページのプラグイン由来の文字列が
/// 書かれている言語のコード。`PluginPage` は `"en"`、`LocalizedPage` は
/// `language`。
pub fn text_language(page: PluginPage, language: String) -> String {
  case page {
    PluginPage(..) -> "en"
    LocalizedPage(..) -> language
  }
}

/// プラグインが供給する管理 UI。`pages` は読み込み時に検証した一覧（1 件以上、
/// キーは重複しない）。`content` はページのキーと表示の言語のコードと登録
/// アカウントの一覧を受け取り、そのページの記述を期限付きで取る。言語のコードは
/// 言語を受け取るプラグインにだけ渡る。失敗は 1 行の理由。`action` は
/// `plugin_page_action` を持たなければ `None`。`Ok(Nil)` は `ok`、`Error` は
/// `{error, Reason}` か呼び出しの失敗の理由。
pub type PluginUi {
  PluginUi(
    pages: List(PluginPage),
    content: fn(String, String, List(plugin_config.PageAccount)) ->
      Result(Dynamic, String),
    action: Option(
      fn(String, List(#(String, String)), List(plugin_config.PageAccount)) ->
        Result(Nil, String),
    ),
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
/// する。失敗理由はモジュール名を付けない 1 行で、ログの行では `plugin_loader` が
/// 識別子を前に付ける。
///
/// `env` は `PLUGIN_*` の環境変数全体（`config.plugin_env`）で、本番では本体の
/// 接続先を `plugin_config.with_database_url` で足してある。プラグイン名が決まった
/// 時点でそのプラグインぶんだけを切り出す。切り出し済みの map を渡せないのは、
/// 接頭辞の元になるプラグイン名がこの関数の中でしか分からないためである。
///
/// `call_timeout_ms` はモジュールの読み込みとメタデータ用のエクスポート 1 回
/// ごとの期限で、本番は `default_call_timeout_ms`。
pub fn load(
  module: Atom,
  env: Dict(String, String),
  call_timeout_ms: Int,
) -> Result(Plugin, String) {
  use _ <- result.try(
    ensure_module_loaded_within(module, call_timeout_ms)
    |> result.map_error(fn(failure) {
      "cannot load module ("
      <> describe_failure(failure, call_timeout_ms)
      <> ")"
    }),
  )
  // イベント処理関数のアリティはイベントごとではなく読み込み時に 1 度だけ決め、
  // 下のクロージャーが渡す引数の数に使う。
  use event_arity <- result.try(require_exports(module))
  use _ <- result.try(check_api_version(module, call_timeout_ms))
  use _ <- result.try(check_min_host_version_export(module, call_timeout_ms))
  use _ <- result.try(check_required_versions(module, call_timeout_ms))
  use plugin_name <- result.try(read_plugin_name(module, call_timeout_ms))
  let config = plugin_config.for_plugin(env, plugin_name)
  let config_map = plugin_config.to_map(config)
  use children <- result.try(read_children(
    module,
    plugin_name,
    config_map,
    call_timeout_ms,
  ))
  use ui <- result.try(read_ui(module, config, config_map, call_timeout_ms))
  // atom はイベントごとではなく読み込み時に 1 度だけ作り、クロージャーで捕捉する。
  let handle_event = atom.create(handle_event_export)
  let args = fn(event_map) { list.take([event_map, config_map], event_arity) }
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
/// どちらか一方があればよく、成功ならそのアリティ（両方あれば `2`）を返す。
fn require_exports(module: Atom) -> Result(Int, String) {
  let required = [#(api_version_export, 0), #(name_export, 0)]
  use _ <- result.try(
    list.try_each(required, fn(export) {
      let #(function, arity) = export
      case has_export(module, function, arity) {
        True -> Ok(Nil)
        False ->
          Error("missing export " <> plugin_term.export_label(function, arity))
      }
    }),
  )
  highest_arity(module, handle_event_export, [2, 1])
  |> option.to_result(
    "missing export "
    <> handle_event_export
    <> "/1 or "
    <> handle_event_export
    <> "/2",
  )
}

/// `plugin_api_version/0` を呼び、Int であることと `api_version` と一致すること
/// を確かめる。
fn check_api_version(
  module: Atom,
  call_timeout_ms: Int,
) -> Result(Nil, String) {
  use value <- result.try(call_export(
    module,
    api_version_export,
    [],
    call_timeout_ms,
  ))
  use version <- result.try(
    decode.run(value, decode.int)
    |> result.replace_error(
      api_version_export
      <> "/0 must return an Int, got "
      <> dynamic.classify(value),
    ),
  )
  case version == api_version {
    True -> Ok(Nil)
    False ->
      Error(
        "unsupported api version "
        <> int.to_string(version)
        <> " (expected "
        <> int.to_string(api_version)
        <> ")",
      )
  }
}

/// 任意エクスポート `plugin_min_host_version/0` があれば期限付きで呼び、宣言
/// された下限と本体の版を比べる。エクスポートが無ければ照合しない。
fn check_min_host_version_export(
  module: Atom,
  call_timeout_ms: Int,
) -> Result(Nil, String) {
  case has_export(module, min_host_version_export, 0) {
    False -> Ok(Nil)
    True -> {
      use value <- result.try(call_export(
        module,
        min_host_version_export,
        [],
        call_timeout_ms,
      ))
      use declared <- result.try(
        decode.run(value, decode.string)
        |> result.replace_error(
          min_host_version_export
          <> "/0 must return a version string like \"0.1.0\", got "
          <> dynamic.classify(value),
        ),
      )
      use host <- result.try(
        application_version(host_app_name)
        |> result.replace_error(
          "requires "
          <> host_display_name
          <> " "
          <> declared
          <> " or later, but no "
          <> host_app_name
          <> ".app is on the code path",
        ),
      )
      check_min_host_version(declared, host)
    }
  }
}

/// 宣言された本体の版の下限 `declared` を、本体の版 `host` と比べる。どちらも
/// `MAJOR.MINOR.PATCH` の 3 つの十進整数で、`MAJOR` → `MINOR` → `PATCH` の
/// 順の数値比較で順序を決める。戻りは 4 通りで、`declared` が読めなければ
/// `plugin_min_host_version/0 must return …` の理由、`host` が読めなければ
/// `… but the host version …` の理由、`host` が `declared` より小さければ
/// `requires … or later, but this is …` の理由、それ以外は `Ok(Nil)` である。
/// 理由にモジュール名は付かない（`load` の他の理由と同じ）。
pub fn check_min_host_version(
  declared: String,
  host: String,
) -> Result(Nil, String) {
  let requires =
    "requires " <> host_display_name <> " " <> declared <> " or later"
  use wanted <- result.try(
    parse_version(declared)
    |> result.replace_error(
      min_host_version_export
      <> "/0 must return a version string like \"0.1.0\", got \""
      <> declared
      <> "\"",
    ),
  )
  use found <- result.try(
    parse_version(host)
    |> result.replace_error(
      requires
      <> ", but the host version \""
      <> host
      <> "\" is not MAJOR.MINOR.PATCH",
    ),
  )
  case compare_versions(found, wanted) {
    order.Lt -> Error(requires <> ", but this is " <> host)
    order.Eq | order.Gt -> Ok(Nil)
  }
}

/// `MAJOR.MINOR.PATCH` を 3 つの整数に読む。要素が 3 つでない、十進整数でない
/// （pre-release と build metadata を含む）文字列は `Error(Nil)`。
fn parse_version(value: String) -> Result(#(Int, Int, Int), Nil) {
  case string.split(value, ".") {
    [major, minor, patch] -> {
      use major <- result.try(int.parse(major))
      use minor <- result.try(int.parse(minor))
      use patch <- result.try(int.parse(patch))
      Ok(#(major, minor, patch))
    }
    _ -> Error(Nil)
  }
}

/// 2 つの版の順序。`MAJOR` → `MINOR` → `PATCH` の順に数値で比べる。
fn compare_versions(a: #(Int, Int, Int), b: #(Int, Int, Int)) -> order.Order {
  int.compare(a.0, b.0)
  |> order.break_tie(int.compare(a.1, b.1))
  |> order.break_tie(int.compare(a.2, b.2))
}

/// 任意エクスポート `plugin_required_versions/0` があれば期限付きで呼び、宣言
/// されたアプリケーションの版がコードパス上の `.app` の版と完全一致することを
/// 確かめる。エクスポートが無ければ照合しない。
fn check_required_versions(
  module: Atom,
  call_timeout_ms: Int,
) -> Result(Nil, String) {
  case has_export(module, required_versions_export, 0) {
    False -> Ok(Nil)
    True -> {
      use value <- result.try(call_export(
        module,
        required_versions_export,
        [],
        call_timeout_ms,
      ))
      use required <- result.try(
        decode.run(value, decode.dict(decode.string, decode.string))
        |> result.map_error(fn(errors) {
          required_versions_export
          <> "/0 must return a map of application names to version strings ("
          <> describe_decode_error(errors)
          <> ")"
        }),
      )
      required
      |> dict.to_list
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.try_each(fn(pair) { check_required_version(pair.0, pair.1) })
    }
  }
}

/// アプリケーション 1 つの要求版を、コードパス上の版と照らし合わせる。
fn check_required_version(
  app: String,
  required: String,
) -> Result(Nil, String) {
  use found <- result.try(
    application_version(app)
    |> result.replace_error(
      "requires "
      <> app
      <> " "
      <> required
      <> ", but no "
      <> app
      <> ".app is on the code path",
    ),
  )
  case found == required {
    True -> Ok(Nil)
    False ->
      Error(
        "requires "
        <> app
        <> " "
        <> required
        <> ", but the code path provides "
        <> found,
      )
  }
}

/// `decode` の最初のエラーを `expected X, got Y at a.b` の 1 行にする。エラーが
/// 1 件も無ければ `invalid value` を返す（`decode.run` の `Error` は空のリストを
/// 持たないので、読み込みの経路からは通らない）。
pub fn describe_decode_error(errors: List(decode.DecodeError)) -> String {
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
  call_timeout_ms: Int,
) -> Result(String, String) {
  use value <- result.try(call_export(module, name_export, [], call_timeout_ms))
  use plugin_name <- result.try(
    decode.run(value, decode.string)
    |> result.replace_error(
      name_export <> "/0 must return a String, got " <> dynamic.classify(value),
    ),
  )
  case plugin_name {
    "" -> Error(name_export <> "/0 must not be empty")
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
  plugin_name: String,
  config_map: Dynamic,
  call_timeout_ms: Int,
) -> Result(List(ChildSpecification(Pid)), String) {
  let export = plugin_children.export_name
  case highest_arity(module, export, [1, 0]) {
    // 任意エクスポートを 1 つも持たないプラグインは子を持たない。ここで
    // 問い合わせると `call_export` が `undef` になる。
    None -> Ok([])
    Some(arity) ->
      children(
        module,
        plugin_name,
        list.take([config_map], arity),
        call_timeout_ms,
      )
  }
}

/// `plugin_children` を期限付きで呼び、失敗を 1 行の理由に整える。設定の拒否の
/// ときだけ、運用者がそのまま `grep` や compose の編集に使えるよう環境変数の
/// 接頭辞を添える。
fn children(
  module: Atom,
  plugin_name: String,
  args: List(Dynamic),
  call_timeout_ms: Int,
) -> Result(List(ChildSpecification(Pid)), String) {
  use value <- result.try(call_export(
    module,
    plugin_children.export_name,
    args,
    call_timeout_ms,
  ))
  plugin_children.from_dynamic(value, plugin_name, list.length(args))
  |> result.map_error(fn(rejection) {
    case rejection {
      plugin_children.InvalidSpec(reason) -> reason
      plugin_children.ConfigRejected(reason) ->
        plugin_term.export_label(plugin_children.export_name, list.length(args))
        <> " rejected the configuration ("
        <> reason
        <> "); configure it with "
        <> plugin_config.prefix(plugin_name)
        <> "*"
    }
  })
}

/// 任意エクスポート `plugin_pages/0` `/1` `/2`、`plugin_page_content/1` `/2` `/3`、
/// `plugin_page_action/2` `/3` のうちアリティの大きいものを `highest_arity` で選び、
/// 組み合わせを `ui_arities` で検査して管理 UI の供給を読み込む。組み合わせの誤りは
/// `Error` で、`read_children` と同じく症状を真の原因に近い場所で報告するために
/// そのプラグインを読み込まない。一覧と中身がそろえば一覧を期限付きで呼んで検証する。`plugin_pages/2` は `localized_pages` で言語ごとに呼び、
/// それ以外は `call_pages` で 1 回呼ぶ。実行は任意で、無ければ `action: None`。
fn read_ui(
  module: Atom,
  config: plugin_config.Config,
  config_map: Dynamic,
  call_timeout_ms: Int,
) -> Result(Option(PluginUi), String) {
  let pages_arity = highest_arity(module, pages_export, [2, 1, 0])
  let content_arity = highest_arity(module, page_content_export, [3, 2, 1])
  let action_arity = highest_arity(module, page_action_export, [3, 2])
  use arities <- result.try(ui_arities(pages_arity, content_arity, action_arity))
  case arities {
    None -> Ok(None)
    Some(#(pages_arity, content_arity)) -> {
      use pages <- result.try(case pages_arity {
        2 -> localized_pages(module, config_map, call_timeout_ms)
        _ ->
          call_pages(
            module,
            list.take([config_map], pages_arity),
            call_timeout_ms,
          )
      })
      Ok(
        Some(PluginUi(
          pages: pages,
          content: content_of(module, config, call_timeout_ms, content_arity),
          action: option.map(action_arity, fn(arity) {
            action_of(module, config, call_timeout_ms, arity)
          }),
        )),
      )
    }
  }
}

/// 管理 UI の任意エクスポートのアリティ（`highest_arity` の結果）の組み合わせを
/// 検査する。一覧も中身も実行も無ければ `Ok(None)`、一覧と中身がそろえば
/// `Ok(Some(#(一覧のアリティ, 中身のアリティ)))`。実行だけ、中身だけ、一覧だけ、
/// `plugin_pages/2` と `plugin_page_content/3` の片方だけのときは、モジュール名を
/// 付けない 1 行の理由の `Error`。
pub fn ui_arities(
  pages: Option(Int),
  content: Option(Int),
  action: Option(Int),
) -> Result(Option(#(Int, Int)), String) {
  let no_pages = " but no " <> pages_export <> "/0, /1 or /2"
  case pages, content {
    None, None ->
      case action {
        None -> Ok(None)
        Some(arity) ->
          Error(plugin_term.export_label(page_action_export, arity) <> no_pages)
      }
    None, Some(arity) ->
      Error(plugin_term.export_label(page_content_export, arity) <> no_pages)
    Some(arity), None ->
      Error(
        plugin_term.export_label(pages_export, arity)
        <> " but no "
        <> page_content_export
        <> "/1, /2 or /3",
      )
    Some(2), Some(arity) if arity != 3 ->
      Error(
        plugin_term.export_label(pages_export, 2)
        <> " but no "
        <> plugin_term.export_label(page_content_export, 3),
      )
    Some(arity), Some(3) if arity != 2 ->
      Error(
        plugin_term.export_label(page_content_export, 3)
        <> " but no "
        <> plugin_term.export_label(pages_export, 2),
      )
    Some(pages_arity), Some(content_arity) ->
      Ok(Some(#(pages_arity, content_arity)))
  }
}

/// `arities`（大きい順に並べる）のうち、モジュールがエクスポートする最初の
/// アリティ。どれも無ければ `None`。
fn highest_arity(
  module: Atom,
  function: String,
  arities: List(Int),
) -> Option(Int) {
  arities
  |> list.find(fn(arity) { has_export(module, function, arity) })
  |> option.from_result
}

/// `plugin_pages/2` を `page_languages` の言語ごとに `call_pages` で呼んで検証し、
/// `merge_localized_pages` で `LocalizedPage` の一覧にまとめる。
fn localized_pages(
  module: Atom,
  config_map: Dynamic,
  call_timeout_ms: Int,
) -> Result(List(PluginPage), String) {
  use lists <- result.try(
    list.try_map(page_languages, fn(language) {
      use pages <- result.map(call_pages(
        module,
        [config_map, dynamic.string(language)],
        call_timeout_ms,
      ))
      #(language, pages)
    }),
  )
  merge_localized_pages(lists, plugin_term.export_label(pages_export, 2))
}

/// `plugin_pages` を `args` で期限付きで 1 回呼び、`decode_pages` で検証する。
/// `args` は候補の並び `[設定 map, 言語のコード]` の先頭のアリティ個で、理由に出す
/// アリティはその長さである。
fn call_pages(
  module: Atom,
  args: List(Dynamic),
  call_timeout_ms: Int,
) -> Result(List(PluginPage), String) {
  use value <- result.try(call_export(
    module,
    pages_export,
    args,
    call_timeout_ms,
  ))
  decode_pages(value, plugin_term.export_label(pages_export, list.length(args)))
}

/// 言語ごとに検証したページの一覧（`#(言語のコード, 一覧)` の並びで、先頭の言語の
/// 一覧をキーの基準にする）を、キーごとに言語から表示名への対応を持つ
/// `LocalizedPage` の一覧にまとめる。キーの並びが先頭の言語の一覧と食い違う言語が
/// あれば `Error`。言語が 1 つも無ければ空の一覧を返す。`label` は理由に出す
/// `関数/アリティ`。
pub fn merge_localized_pages(
  lists: List(#(String, List(PluginPage))),
  label: String,
) -> Result(List(PluginPage), String) {
  case lists {
    [] -> Ok([])
    [#(base_language, base), ..rest] -> {
      let keys = list.map(base, fn(page) { page.key })
      use _ <- result.try(
        list.try_each(rest, fn(entry) {
          case list.map(entry.1, fn(page) { page.key }) == keys {
            True -> Ok(Nil)
            False ->
              Error(
                label
                <> ": page keys for \""
                <> entry.0
                <> "\" differ from \""
                <> base_language
                <> "\"",
              )
          }
        }),
      )
      let titles =
        list.map(base, fn(page) {
          [#(base_language, title_in(page, base_language))]
        })
      let titles =
        list.fold(rest, titles, fn(acc, entry) {
          list.map2(acc, entry.1, fn(pairs, page) {
            [#(entry.0, title_in(page, entry.0)), ..pairs]
          })
        })
      Ok(
        list.map2(keys, titles, fn(key, pairs) {
          LocalizedPage(key:, titles: dict.from_list(pairs))
        }),
      )
    }
  }
}

/// `plugin_pages` の戻り値をページの一覧に変換する。形、0 件、重複、
/// 文字集合の順に検査する。
fn decode_pages(
  value: Dynamic,
  label: String,
) -> Result(List(PluginPage), String) {
  use raw <- result.try(
    decode.run(value, decode.list(decode.dynamic))
    |> result.replace_error(
      label
      <> " must return a list of page maps, got "
      <> dynamic.classify(value),
    ),
  )
  use pages <- result.try(
    raw
    |> plugin_term.try_map_indexed(fn(page, index) {
      decode_page(page, index, label)
    }),
  )
  case pages {
    [] -> Error(label <> " must return at least one page")
    _ ->
      case find_duplicate_page_key(pages) {
        Some(key) -> Error(label <> ": duplicate page key \"" <> key <> "\"")
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
  use _ <- result.try(plugin_term.check_map(raw, unlabelled, "a page map"))
  use key <- result.try(plugin_term.required(
    raw,
    BinaryKey,
    "key",
    unlabelled,
    "a String",
    decode.string,
  ))
  case page_key_ok(key) {
    False ->
      Error(label <> ": page key \"" <> key <> "\" must match [a-z0-9_-]+")
    True -> {
      let labelled = label <> ": page key \"" <> key <> "\""
      use title <- result.try(plugin_term.required(
        raw,
        BinaryKey,
        "title",
        labelled,
        "a String",
        decode.string,
      ))
      Ok(PluginPage(key: key, title: title))
    }
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

/// ページの中身を取得するクロージャーを組み立てる。`arity` は
/// `plugin_page_content` のアリティで、呼び出しのたびに候補の並び
/// `[キー, 設定 map, 言語のコード]` の先頭 `arity` 個を渡す。設定 map は `config` と
/// 渡された `accounts` から `plugin_config.page_map` で組む。失敗（例外・期限超過）は
/// `call_export` の 1 行の理由の先頭にモジュール名を付けたものにする。
fn content_of(
  module: Atom,
  config: plugin_config.Config,
  call_timeout_ms: Int,
  arity: Int,
) -> fn(String, String, List(plugin_config.PageAccount)) ->
  Result(Dynamic, String) {
  let name = atom.to_string(module)
  fn(key: String, language: String, accounts: List(plugin_config.PageAccount)) {
    let args =
      list.take(
        [
          dynamic.string(key),
          plugin_config.page_map(config, accounts),
          dynamic.string(language),
        ],
        arity,
      )
    call_export(module, page_content_export, args, call_timeout_ms)
    |> result.map_error(prefix(name, _))
  }
}

/// フォームの送信を実行するクロージャーを組み立てる。`arity` は
/// `plugin_page_action` のアリティで、呼び出しのたびに候補の並び
/// `[キー, 送られた値, 設定 map]` の先頭 `arity` 個を渡す。送られた値は binary
/// キー・binary 値の map に、設定 map は `config` と渡された `accounts` から
/// `plugin_config.page_map` で組む。戻り値は `decode_action_result` で検証し、
/// 呼び出しの失敗と戻り値の不備の理由の先頭にモジュール名を付ける。
fn action_of(
  module: Atom,
  config: plugin_config.Config,
  call_timeout_ms: Int,
  arity: Int,
) -> fn(String, List(#(String, String)), List(plugin_config.PageAccount)) ->
  Result(Nil, String) {
  let name = atom.to_string(module)
  fn(
    key: String,
    values: List(#(String, String)),
    accounts: List(plugin_config.PageAccount),
  ) {
    let values_map =
      values
      |> list.map(fn(pair) { #(dynamic.string(pair.0), dynamic.string(pair.1)) })
      |> dynamic.properties
    let args =
      list.take(
        [
          dynamic.string(key),
          values_map,
          plugin_config.page_map(config, accounts),
        ],
        arity,
      )
    {
      use value <- result.try(call_export(
        module,
        page_action_export,
        args,
        call_timeout_ms,
      ))
      decode_action_result(
        value,
        plugin_term.export_label(page_action_export, arity),
      )
    }
    |> result.map_error(prefix(name, _))
  }
}

/// `plugin_page_action` の戻り値を検証する。`ok` の atom なら成功、
/// `{error, Reason}` で `Reason` が binary ならその理由の拒否、それ以外は
/// 戻り値の形の誤り。
fn decode_action_result(value: Dynamic, label: String) -> Result(Nil, String) {
  let bad_return =
    Error(
      label
      <> " must return ok or {error, Reason}, got "
      <> dynamic.classify(value),
    )
  let is_ok = case decode.run(value, atom.decoder()) {
    Ok(tag) -> atom.to_string(tag) == "ok"
    Error(_) -> False
  }
  case is_ok, plugin_term.is_error_tuple(value) {
    True, _ -> Ok(Nil)
    False, False -> bad_return
    False, True ->
      case plugin_term.error_reason(value) {
        Ok(reason) -> Error(label <> " rejected the request (" <> reason <> ")")
        Error(Some(got)) -> Error(plugin_term.reason_not_a_string(label, got))
        Error(None) -> bad_return
      }
  }
}

/// プラグインのエクスポートを使い捨てのプロセスで期限付きで呼ぶ。失敗は `関数/アリティ` を
/// 先頭に置いた 1 行（`crashed (...)` か `timed out after <ms>ms`）にする。アリティは `args`
/// の長さから決まる。
fn call_export(
  module: Atom,
  function: String,
  args: List(Dynamic),
  call_timeout_ms: Int,
) -> Result(Dynamic, String) {
  let label = plugin_term.export_label(function, list.length(args))
  call_export_within(module, atom.create(function), args, call_timeout_ms)
  |> result.map_error(fn(failure) {
    let detail = describe_failure(failure, call_timeout_ms)
    case failure {
      Crashed(_) -> label <> " crashed (" <> detail <> ")"
      TimedOut -> label <> " " <> detail
    }
  })
}

/// 期限付きの呼び出しの失敗の詳細を 1 行にする。`Crashed` は理由そのもの、`TimedOut` は
/// `timed out after <ms>ms`。前に置く語（`cannot load module` や `crashed`）は呼び出し側が
/// 決める。
fn describe_failure(failure: CallFailure, call_timeout_ms: Int) -> String {
  case failure {
    Crashed(reason) -> reason
    TimedOut -> "timed out after " <> int.to_string(call_timeout_ms) <> "ms"
  }
}

/// 管理 UI から呼ぶ閉包（`content_of` と `action_of`）の失敗理由にモジュール名を付ける。
fn prefix(module_name: String, reason: String) -> String {
  module_name <> ": " <> reason
}

/// `has_export` の実体。関数名は atom で渡す（`atom.create`）。
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
