import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/plugin
import nostr_no_su/plugin_config
import support/beam_fixture.{type Fixture, Exported}
import support/page_account_json
import support/plugin_valid
import support/plugin_with_config
import support/plugin_with_localized_pages
import support/plugin_with_pages

/// 読み込みの検証に使うサンプルイベント。
fn sample_event() -> event.Event {
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

/// 読み込みに失敗した理由の文字列を取り出す。設定は空。
fn load_error(module_name: String) -> String {
  load_error_with(module_name, [])
}

/// 設定を与えて読み込み、失敗した理由の文字列を取り出す。
fn load_error_with(
  module_name: String,
  env: List(#(String, String)),
) -> String {
  let assert Error(reason) =
    plugin.load(
      atom.create(module_name),
      dict.from_list(env),
      plugin.default_call_timeout_ms,
    )
  reason
}

/// `source` を `fixture` のモジュールとして compile して読み込み、失敗した理由の
/// 文字列を取り出す。設定は空。
fn compiled_error(fixture: Fixture, source: String) -> String {
  beam_fixture.compile_loadable(fixture, source)
  load_error(fixture.module)
}

/// 戻らない・異常終了する呼び出しのテストに使う短い期限。実時間に依存しないよう小さく取るが、
/// 打ち切りの前に使い捨てのプロセスが Pid を退避できる長さにする。
const short_call_timeout_ms = 1000

/// `short_call_timeout_ms` で打ち切られた呼び出しの理由に入る文言。
fn timed_out() -> String {
  "timed out after " <> int.to_string(short_call_timeout_ms) <> "ms"
}

/// 1 ページ（キー `status`）だけを返す `plugin_pages/0` の本体（Erlang の式）。
const status_pages_body =
  "[#{<<\"key\">> => <<\"status\">>, <<\"title\">> => <<\"Status\">>}]"

/// `source` を `fixture` のモジュールとして compile し、設定を空にして
/// `call_timeout_ms` の期限で読み込む。
fn load_compiled(
  fixture: Fixture,
  source: String,
  call_timeout_ms: Int,
) -> Result(plugin.Plugin, String) {
  beam_fixture.compile_loadable(fixture, source)
  plugin.load(atom.create(fixture.module), dict.new(), call_timeout_ms)
}

/// `plugin_page_content/1` の本体が `content_body`（Erlang の式）の 1 ページのプラグインを
/// `load_compiled` で読み込み、管理 UI の供給を取り出す。
fn load_ui_with_content(
  fixture: Fixture,
  content_body: String,
  call_timeout_ms: Int,
) -> plugin.PluginUi {
  let source =
    beam_fixture.pages_source(
      fixture.module,
      "page_content_plugin",
      status_pages_body,
      content_body,
    )
  let assert Ok(loaded) = load_compiled(fixture, source, call_timeout_ms)
  let assert Some(ui) = loaded.ui
  ui
}

/// 設定を与えて読み込み、成功した `Plugin` を取り出す。
fn load_ok_with(
  module_name: String,
  env: List(#(String, String)),
) -> plugin.Plugin {
  let assert Ok(loaded) =
    plugin.load(
      atom.create(module_name),
      dict.from_list(env),
      plugin.default_call_timeout_ms,
    )
  loaded
}

/// 読み込みに成功した `Plugin` を取り出す。設定は空。
fn load_ok(module_name: String) -> plugin.Plugin {
  load_ok_with(module_name, [])
}

/// 読み込んだプラグインの `plugin_page_action` の呼び出しを取り出す。
fn action_of(
  module_name: String,
) -> fn(String, List(#(String, String)), List(plugin_config.PageAccount)) ->
  Result(Nil, String) {
  let assert Some(ui) = load_ok(module_name).ui
  let assert Some(action) = ui.action
  action
}

/// 退避された設定 map を binary キー・binary 値の Dict として読む。
fn saved_config(key: Atom) -> dict.Dict(String, String) {
  let assert Ok(config) =
    decode.run(
      beam_fixture.saved(key),
      decode.dict(decode.string, decode.string),
    )
  config
}

/// API v1 を満たすモジュールを読み込むと、`plugin_name/0` の値が `Plugin.name`
/// になる。
pub fn load_valid_test() {
  let loaded = load_ok("support@plugin_valid")
  assert loaded.name == "plugin_valid"
}

/// 必須エクスポートを欠くモジュールは、欠けている関数を名指しで拒否する。
/// **`handle_event` はどちらのアリティも無いことを名指しする。** 部分一致を
/// `handle_event/1` だけにすると、緩和が壊れていても通ってしまう。
pub fn load_missing_export_test() {
  let fixture = beam_fixture.new("missing_handle")
  let reason =
    compiled_error(
      fixture,
      beam_fixture.module_source(fixture.module, [
        beam_fixture.api_version_part("1"),
        beam_fixture.name_part(beam_fixture.binary_literal("missing_handle")),
      ]),
    )
  assert string.contains(
    reason,
    "missing export handle_event/1 or handle_event/2",
  )
}

/// `plugin_name/0` を欠くモジュールは、欠けている関数を名指しで拒否する。後続の
/// 呼び出しの失敗の理由と区別するため、完全一致で見る。
pub fn load_missing_plugin_name_export_test() {
  let fixture = beam_fixture.new("missing_name")
  assert compiled_error(
      fixture,
      beam_fixture.module_source(fixture.module, [
        beam_fixture.api_version_part("1"),
        Exported("handle_event/1", "handle_event(_Event) -> ok."),
      ]),
    )
    == "missing export plugin_name/0"
}

/// 本体が対応していない API バージョンは拒否する。
pub fn load_unsupported_version_test() {
  let fixture = beam_fixture.new("bad_version")
  assert string.contains(
    compiled_error(
      fixture,
      beam_fixture.plugin_source(fixture.module, 2, "bad_version"),
    ),
    "unsupported api version",
  )
}

/// `plugin_name/0` が String を返さないモジュールは拒否する。
pub fn load_bad_name_type_test() {
  let fixture = beam_fixture.new("bad_name")
  assert string.contains(
    compiled_error(
      fixture,
      beam_fixture.plugin_name_body_source(fixture.module, 1, "42"),
    ),
    "must return a String",
  )
}

/// 空の名前は拒否する。名前はダッシュボードとログの識別子になるため。
pub fn load_empty_name_test() {
  let fixture = beam_fixture.new("empty_name")
  assert string.contains(
    compiled_error(fixture, beam_fixture.plugin_source(fixture.module, 1, "")),
    "must not be empty",
  )
}

/// メタデータ取得の例外は本体の起動を止めず、理由の文字列になる。
pub fn load_crashing_version_test() {
  let fixture = beam_fixture.new("crashing_version")
  assert string.contains(
    compiled_error(
      fixture,
      beam_fixture.plugin_module(
        fixture.module,
        "error(broken)",
        beam_fixture.binary_literal("crashing_version"),
        [],
      ),
    ),
    "plugin_api_version/0 crashed (error:",
  )
}

/// 存在しない（読み込めない）モジュールは、読み込みの段階で拒否する。
pub fn load_unknown_module_test() {
  assert string.contains(
    load_error("support@plugin_does_not_exist"),
    "cannot load module",
  )
}

/// `Plugin.handle` を呼ぶと、プラグインには binary キーのイベント map が届き、
/// `event.from_map` で元の `Event` に戻せる。
pub fn handle_passes_event_map_test() {
  let loaded = load_ok("support@plugin_valid")
  let original = sample_event()
  loaded.handle(original)
  let assert Ok(received) =
    event.from_map(beam_fixture.saved(plugin_valid.last_event_key()))
  assert received == original
}

/// `plugin_api_version/0` が整数以外を返すモジュールは拒否する。
pub fn load_non_integer_version_test() {
  let fixture = beam_fixture.new("float_version")
  assert string.contains(
    compiled_error(
      fixture,
      beam_fixture.plugin_module(
        fixture.module,
        "1.0",
        beam_fixture.binary_literal("float_version"),
        [],
      ),
    ),
    "must return an Int, got Float",
  )
}

/// 仕様書に載せている Erlang の最小実装が、実際に読み込めること。
pub fn load_erlang_minimal_plugin_test() {
  let loaded = load_ok("minimal_plugin")
  assert loaded.name == "minimal_plugin"
}

/// 任意エクスポート `plugin_children/0` を持つモジュールは、子仕様を解決した
/// 状態で読み込まれる。
pub fn load_resolves_children_test() {
  let loaded = load_ok("support@plugin_with_children")
  assert list.length(loaded.children) == 1
}

/// `plugin_children` をどちらのアリティでも持たないモジュールは子を持たない。
/// **問い合わせを飛ばすことが重要で**、無いエクスポートを呼ぶと `error:undef` に
/// なる。
pub fn load_without_children_export_test() {
  let loaded = load_ok("support@plugin_valid")
  assert loaded.children == []
}

/// API に合わない子仕様は、必須エクスポートの不備と同じくそのプラグインを
/// 読み込まない理由になる。子だけ捨てて読み込むと、症状が真の原因から離れる。
pub fn load_bad_children_test() {
  let reason = load_error("support@plugin_bad_children")
  assert string.contains(reason, "plugin_children/0: child #0: missing id")
}

/// `plugin_children/0` の例外は本体の起動を止めず、理由の文字列になる。
pub fn load_crashing_children_test() {
  assert string.contains(
    load_error("support@plugin_crashing_children"),
    "plugin_children/0 crashed",
  )
}

/// `handle_event/2` だけを持つプラグインも読み込める。設定が必須のプラグインは
/// `handle_event/1` を正しく書けないため、v1 は `/1` と `/2` のどちらか一方を
/// 必須としている。
pub fn load_handle_event_arity_two_test() {
  let loaded = load_ok("support@plugin_with_config")
  assert loaded.name == "plugin_with_config"
}

/// `plugin_children/1` にはプラグイン 1 つぶんの設定 map が届く。キーは接頭辞を
/// 取り除いて小文字にしたもので、他のプラグイン向けの変数は混ざらない。
pub fn children_receives_config_test() {
  let _ =
    load_ok_with("support@plugin_with_config", [
      #("PLUGIN_PLUGIN_WITH_CONFIG_PATH", "/tmp/events.log"),
      #("PLUGIN_COUNTER_LIMIT", "10"),
    ])
  assert saved_config(plugin_with_config.children_config_key())
    == dict.from_list([#("path", "/tmp/events.log")])
}

/// `handle_event/2` があればそちらが呼ばれ、設定 map が第 2 引数に届く。
pub fn handle_receives_config_test() {
  let loaded =
    load_ok_with("support@plugin_with_config", [
      #("PLUGIN_PLUGIN_WITH_CONFIG_PATH", "/tmp/events.log"),
    ])
  loaded.handle(sample_event())
  assert saved_config(plugin_with_config.handle_config_key())
    == dict.from_list([#("path", "/tmp/events.log")])
}

/// `handle_event/1` と `/2` の両方を持つプラグインでは `/2` が呼ばれる。
/// fixture の `/1` は例外を投げるので、呼ばれればこのテストが落ちる。
pub fn handle_prefers_arity_two_test() {
  let loaded = load_ok("plugin_with_both_handlers")
  loaded.handle(sample_event())
}

/// `plugin_children/0` と `/1` の両方を持つプラグインでは `/1` が呼ばれる。
/// fixture の `/0` は例外を投げるので、呼ばれていれば理由が `crashed` になる。
pub fn children_prefers_arity_one_test() {
  let reason = load_error("plugin_rejecting_config")
  assert string.contains(reason, "plugin_children/1 rejected the configuration")
  assert !string.contains(reason, "crashed")
}

/// 設定を受け付けなかったプラグインは読み込まれず、理由と設定の渡し方が 1 行に
/// なる。接頭辞を本体が添えるので、プラグイン作者は理由にキー名だけを書けばよい。
pub fn children_rejecting_config_test() {
  assert load_error("plugin_rejecting_config")
    == "plugin_children/1 rejected the configuration "
    <> "(path is required); configure it with PLUGIN_PLUGIN_REJECTING_CONFIG_*"
}

/// `{error, Reason}` の理由が binary でなければ、設定の拒否ではなく戻り値の形の
/// 誤りとして報告する。
pub fn children_rejecting_config_with_bad_reason_test() {
  assert string.contains(
    load_error_with("plugin_rejecting_config", [
      #("PLUGIN_PLUGIN_REJECTING_CONFIG_REASON", "atom"),
    ]),
    "plugin_children/1: error reason must be a String, got Atom",
  )
}

/// `plugin_pages` と `plugin_page_content` のどちらも無いプラグインは読み込まれ、
/// `ui` は `None`。
pub fn load_without_ui_test() {
  let loaded = load_ok("support@plugin_valid")
  assert loaded.ui == None
}

/// `plugin_pages/1` と `plugin_page_content/2` を持つプラグインは、`ui` に検証
/// 済みのページの一覧が載り、`content(key)` がそのページの記述を返す。
pub fn load_with_pages_test() {
  let loaded = load_ok("support@plugin_with_pages")
  let assert Some(ui) = loaded.ui
  assert ui.pages
    == [
      plugin.PluginPage(
        key: plugin_with_pages.page_key,
        title: plugin_with_pages.page_title,
      ),
    ]
  let assert Ok(description) = ui.content(plugin_with_pages.page_key, "en", [])
  let assert Ok(sections) =
    decode.run(
      description,
      decode.field("sections", decode.list(decode.dynamic), decode.success),
    )
  assert list.length(sections) == 1
}

/// `plugin_pages/2` と `plugin_page_content/3` を持つプラグインは、`ui` に言語ごとの
/// 表示名を持つ `LocalizedPage` が載り、`content` に渡した言語でページの記述が返る。
pub fn load_with_localized_pages_test() {
  let loaded = load_ok("support@plugin_with_localized_pages")
  let assert Some(ui) = loaded.ui
  assert ui.pages
    == [
      plugin.LocalizedPage(
        key: plugin_with_localized_pages.page_key,
        titles: dict.from_list([#("en", "Status"), #("ja", "状態")]),
      ),
    ]
  let assert Ok(description) =
    ui.content(plugin_with_localized_pages.page_key, "ja", [])
  let assert Ok([title]) =
    decode.run(
      description,
      decode.field(
        "sections",
        decode.list(decode.field("title", decode.string, decode.success)),
        decode.success,
      ),
    )
  assert title == "状態"
}

/// 言語が 1 つも無ければ、まとめた一覧は空になる。
pub fn merge_localized_pages_without_languages_is_empty_test() {
  assert plugin.merge_localized_pages([], "plugin_pages/2") == Ok([])
}

/// `title_in` は既知の言語ではその表示名を、未知の言語では `key` を返す。
pub fn localized_page_title_falls_back_to_the_key_test() {
  let page =
    plugin.LocalizedPage(
      key: "status",
      titles: dict.from_list([#("en", "Status"), #("ja", "状態")]),
    )
  assert plugin.title_in(page, "ja") == "状態"
  assert plugin.title_in(page, "fr") == "status"
}

/// `plugin_page_action/3` には送信したキー・値・登録アカウントの一覧
/// （`Accounts`）が届く。成功は `Ok(Nil)`。
pub fn page_action_receives_the_key_values_and_accounts_test() {
  let action = action_of("plugin_with_action")
  let accounts = [
    plugin_config.PageAccount(pubkey: "abcd", npub: "npub1x", label: "main"),
  ]
  let assert Ok(Nil) = action("settings", [#("main", "on")], accounts)
  let stored_decoder = {
    use key <- decode.field(0, decode.string)
    use values <- decode.field(1, decode.dict(decode.string, decode.string))
    use config <- decode.field(2, decode.dynamic)
    decode.success(#(key, values, config))
  }
  let assert Ok(#(key, values, config)) =
    decode.run(
      beam_fixture.saved(atom.create("plugin_with_action")),
      stored_decoder,
    )
  assert key == "settings"
  assert values == dict.from_list([#("main", "on")])
  let assert Ok(accounts_json) =
    decode.run(config, decode.field("Accounts", decode.string, decode.success))
  assert page_account_json.parse(accounts_json)
    == Ok([#("abcd", "npub1x", "main")])
}

/// `plugin_page_action/3` が無く `/2` だけのプラグインは `/2` が呼ばれ、設定 map
/// を渡さない（fixture が退避した値が `{Key, Values}` の 2 要素であることで
/// 確かめる）。
pub fn page_action_arity_two_is_used_when_three_is_missing_test() {
  let action = action_of("plugin_with_action_arity_two")
  let assert Ok(Nil) = action("settings", [#("main", "on")], [])
  let stored_decoder = {
    use key <- decode.field(0, decode.string)
    use values <- decode.field(1, decode.dict(decode.string, decode.string))
    decode.success(#(key, values))
  }
  let assert Ok(#(key, values)) =
    decode.run(
      beam_fixture.saved(atom.create("plugin_with_action_arity_two")),
      stored_decoder,
    )
  assert key == "settings"
  assert values == dict.from_list([#("main", "on")])
}

/// `{error, Reason}` が拒否の理由になる。
pub fn page_action_error_tuple_is_a_reason_test() {
  let action = action_of("plugin_with_action")
  let assert Error(reason) =
    action("settings", [#("reject", "select at least one account")], [])
  assert reason
    == "plugin_with_action: plugin_page_action/3 rejected the request (select at least one account)"
}

/// `ok` でも `{error, _}` でもない戻り値は、その形を報告する理由になる。
pub fn page_action_with_a_bad_return_is_a_reason_test() {
  let action = action_of("plugin_with_action")
  let assert Error(reason) = action("settings", [#("bad-return", "on")], [])
  assert reason
    == "plugin_with_action: plugin_page_action/3 must return ok or {error, Reason}, got Atom"
}

/// 理由の無い `{error}` は拒否ではなく戻り値の形の誤りになる。要素 0 は `error`
/// だが、理由の要素が無い。
pub fn page_action_error_without_a_reason_is_a_bad_return_test() {
  let action = action_of("plugin_with_action")
  let assert Error(reason) =
    action("settings", [#("error-without-reason", "on")], [])
  assert reason
    == "plugin_with_action: plugin_page_action/3 must return ok or {error, Reason}, got Array"
}

/// `{error, Reason}` の `Reason` が binary でなければ、その型を報告する理由になる。
pub fn page_action_error_with_a_non_string_reason_is_a_reason_test() {
  let action = action_of("plugin_with_action")
  let assert Error(reason) =
    action("settings", [#("non-string-reason", "on")], [])
  assert reason
    == "plugin_with_action: plugin_page_action/3: error reason must be a String, got Int"
}

/// 管理 UI の宣言（`plugin_pages`、`plugin_page_content`、`plugin_page_action`）の片方だけの
/// 宣言、言語ごとのキーの食い違い、一覧の中身の誤りを持つプラグインは読み込まれず、
/// 行ごとに決まった理由の `Error` になる。
pub fn invalid_page_declarations_are_not_loaded_test() {
  use #(name, source, expected) <- list.each([
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
        beam_fixture.ui_source(module, name, 1, 3, status_pages_body)
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
  let reason = compiled_error(fixture, source(fixture.module, name))
  assert #(name, string.contains(reason, expected)) == #(name, True)
}

/// `plugin_pages/0` が `body` を返し、`plugin_page_content/1` が空の節を返すプラグインの
/// ソースを、モジュール名とプラグイン名から作る関数。
fn pages_returning(body: String) -> fn(String, String) -> String {
  fn(module, name) {
    beam_fixture.pages_source(module, name, body, "#{<<\"sections\">> => []}")
  }
}

/// `plugin_page_content` の例外は、一覧の検証に影響せず読み込みには成功し、
/// `ui.content` の呼び出しの `Error` として現れる。理由は、モジュール名の接頭辞を 1 つ
/// 付けた 1 行になる。
pub fn page_content_crash_reason_names_the_module_test() {
  let fixture = beam_fixture.new("pages_content_crash_reason")
  let ui =
    load_ui_with_content(
      fixture,
      "erlang:error(boom)",
      plugin.default_call_timeout_ms,
    )
  assert ui.content("status", "en", [])
    == Error(fixture.module <> ": plugin_page_content/1 crashed (error:boom)")
}

/// 戻らない `plugin_page_content` は、読み込みには成功し、`ui.content` の
/// 呼び出しが期限で打ち切られて `Error` になる。
pub fn page_content_timeout_test() {
  let fixture = beam_fixture.new("pages_content_timeout")
  let ui =
    load_ui_with_content(
      fixture,
      "receive after infinity -> ok end",
      short_call_timeout_ms,
    )
  let assert Error(reason) = ui.content("status", "en", [])
  assert string.contains(reason, timed_out())
}

/// 戻らない `plugin_name/0` を持つプラグインは、期限切れの理由で読み込まれない。
/// 打ち切られた呼び出しのプロセスも残らない。
///
/// 期限（`short_call_timeout_ms`）は、使い捨てのプロセスが `plugin_name/0` の先頭で
/// Pid を退避するより十分長い（退避の前に打ち切ると `last_pid` が落ちる）。
pub fn load_hanging_plugin_name_test() {
  let fixture = beam_fixture.new("hanging_metadata")
  let source =
    beam_fixture.plugin_name_body_source(
      fixture.module,
      1,
      "persistent_term:put(?MODULE, self()), receive after infinity -> ok end",
    )
  let assert Error(reason) =
    load_compiled(fixture, source, short_call_timeout_ms)
  assert reason == "plugin_name/0 " <> timed_out()
  assert !process.is_alive(beam_fixture.last_pid(fixture.module))
}

/// 戻らない `-on_load` を持つプラグインは、モジュールの読み込みの時点で期限切れの理由で
/// 読み込まれない。
pub fn load_hanging_on_load_test() {
  let fixture = beam_fixture.new("hanging_on_load")
  let source =
    beam_fixture.hanging_on_load_source(fixture.module, fixture.module)
  let assert Error(reason) =
    load_compiled(fixture, source, short_call_timeout_ms)
  assert reason == "cannot load module (" <> timed_out() <> ")"
}

/// `plugin_name/0` が自プロセスを kill するプラグインは、印の無い DOWN として
/// `crashed` の理由になる（`killed`）。
pub fn load_killed_plugin_name_test() {
  let fixture = beam_fixture.new("killed_metadata")
  let source =
    beam_fixture.plugin_name_body_source(
      fixture.module,
      1,
      "exit(self(), kill)",
    )
  let assert Error(reason) =
    load_compiled(fixture, source, short_call_timeout_ms)
  assert reason == "plugin_name/0 crashed (killed)"
}

/// 宣言した下限より本体の版が小さいと読み込まず、要求と実際の版を並べた
/// 理由になる。`0.1.9` のように patch が違うだけの版でも同じく落ちる。
pub fn min_host_version_older_host_test() {
  assert plugin.check_min_host_version("0.2.0", "0.1.0")
    == Error("requires nostr-no-su 0.2.0 or later, but this is 0.1.0")
  assert plugin.check_min_host_version("0.2.0", "0.1.9")
    == Error("requires nostr-no-su 0.2.0 or later, but this is 0.1.9")
}

/// 本体の版が下限と等しいか大きければ読み込まれる。`0.10.0` は `0.2.0` より
/// 辞書順では小さいが数値比較では大きいので、文字列比較でないことを固定する。
pub fn min_host_version_new_enough_host_test() {
  assert plugin.check_min_host_version("0.2.0", "0.2.0") == Ok(Nil)
  assert plugin.check_min_host_version("0.2.0", "0.2.1") == Ok(Nil)
  assert plugin.check_min_host_version("0.2.0", "0.10.0") == Ok(Nil)
  assert plugin.check_min_host_version("0.2.0", "1.0.0") == Ok(Nil)
}

/// 宣言が `MAJOR.MINOR.PATCH` に読めないと形の誤りの理由になる。
/// pre-release と build metadata もここで弾かれる。
pub fn min_host_version_malformed_declaration_test() {
  let expected = fn(declared: String) {
    Error(
      "plugin_min_host_version/0 must return a version string like \"0.1.0\", got \""
      <> declared
      <> "\"",
    )
  }
  assert plugin.check_min_host_version("0.2", "0.1.0") == expected("0.2")
  assert plugin.check_min_host_version("0.2.0-rc.1", "0.1.0")
    == expected("0.2.0-rc.1")
  assert plugin.check_min_host_version("0.2.0+build.1", "0.1.0")
    == expected("0.2.0+build.1")
}

/// 本体の版が `MAJOR.MINOR.PATCH` に読めないときも読み込まない。
pub fn min_host_version_malformed_host_test() {
  assert plugin.check_min_host_version("0.2.0", "dev")
    == Error(
      "requires nostr-no-su 0.2.0 or later, but the host version \"dev\" is not MAJOR.MINOR.PATCH",
    )
}

/// コードパスに無いアプリケーションが複数あると、名前順で先のものを理由に出す。
pub fn required_versions_report_the_first_missing_app_by_name_test() {
  let fixture = beam_fixture.new("requiring_missing_apps")
  assert compiled_error(
      fixture,
      beam_fixture.required_versions_source(
        fixture.module,
        "requiring_missing_apps",
        "#{<<\"nns_missing_app_b\">> => <<\"1.0.0\">>, "
          <> "<<\"nns_missing_app_a\">> => <<\"2.0.0\">>}",
      ),
    )
    == "requires nns_missing_app_a 2.0.0, but no nns_missing_app_a.app is on the code path"
}

/// UI の任意エクスポートを 1 つも持たない組み合わせは `Ok(None)` になる。
pub fn ui_arities_without_ui_exports_is_none_test() {
  assert plugin.ui_arities(None, None, None) == Ok(None)
}

/// 一覧と中身がそろえば、そのアリティの組の `Ok(Some)` になる。
pub fn ui_arities_with_pages_and_content_test() {
  assert plugin.ui_arities(Some(1), Some(2), None) == Ok(Some(#(1, 2)))
  assert plugin.ui_arities(Some(2), Some(3), Some(3)) == Ok(Some(#(2, 3)))
}
