import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/i18n
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/plugin
import nostr_no_su/plugin_config
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
  let assert Error(reason) =
    plugin.load(
      atom.create(module_name),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  reason
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

/// 退避された設定 map を binary キー・binary 値の Dict として読む。
fn saved_config(key: Atom) -> dict.Dict(String, String) {
  let assert Ok(config) =
    decode.run(
      persistent_term_get(key),
      decode.dict(decode.string, decode.string),
    )
  config
}

/// API v1 を満たすモジュールを読み込むと、`plugin_name/0` の値が `Plugin.name`
/// になる。
pub fn load_valid_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_valid"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  assert loaded.name == "plugin_valid"
}

/// 必須エクスポートを欠くモジュールは、欠けている関数を名指しで拒否する。
/// **`handle_event` はどちらのアリティも無いことを名指しする。** 部分一致を
/// `handle_event/1` だけにすると、緩和が壊れていても通ってしまう。
pub fn load_missing_export_test() {
  let reason = load_error("support@plugin_missing_handle")
  assert string.contains(
    reason,
    "missing export handle_event/1 or handle_event/2",
  )
}

/// 本体が対応していない API バージョンは拒否する。
pub fn load_unsupported_version_test() {
  assert string.contains(
    load_error("support@plugin_bad_version"),
    "unsupported api version",
  )
}

/// `plugin_name/0` が String を返さないモジュールは拒否する。
pub fn load_bad_name_type_test() {
  assert string.contains(
    load_error("support@plugin_bad_name"),
    "must return a String",
  )
}

/// 空の名前は拒否する。名前はダッシュボードとログの識別子になるため。
pub fn load_empty_name_test() {
  assert string.contains(
    load_error("support@plugin_empty_name"),
    "must not be empty",
  )
}

/// メタデータ取得の例外は本体の起動を止めず、理由の文字列になる。
pub fn load_crashing_version_test() {
  assert string.contains(
    load_error("support@plugin_crashing_version"),
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
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_valid"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  let original = sample_event()
  loaded.handle(original)
  let assert Ok(received) =
    event.from_map(persistent_term_get(plugin_valid.last_event_key()))
  assert received == original
}

/// `has_export` は読み込み済みモジュールのエクスポートを名前とアリティの両方で
/// 判定する。
pub fn has_export_test() {
  let module = atom.create("support@plugin_valid")
  let assert Ok(_) =
    plugin.load(module, dict.new(), plugin.default_call_timeout_ms)
  assert plugin.has_export(module, "handle_event", 1)
  assert !plugin.has_export(module, "handle_event", 2)
  assert !plugin.has_export(module, "no_such_function", 0)
}

/// `plugin_api_version/0` が整数以外を返すモジュールは拒否する。
pub fn load_non_integer_version_test() {
  assert string.contains(
    load_error("float_version"),
    "must return an Int, got Float",
  )
}

/// 仕様書に載せている Erlang の最小実装が、実際に読み込めること。
pub fn load_erlang_minimal_plugin_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("minimal_plugin"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  assert loaded.name == "minimal_plugin"
}

/// 任意エクスポート `plugin_children/0` を持つモジュールは、子仕様を解決した
/// 状態で読み込まれる。
pub fn load_resolves_children_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_with_children"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  assert list.length(loaded.children) == 1
}

/// `plugin_children` をどちらのアリティでも持たないモジュールは子を持たない。
/// **問い合わせを飛ばすことが重要で**、無いエクスポートを呼ぶと `error:undef` に
/// なる。
pub fn load_without_children_export_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_valid"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
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
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_with_config"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  assert loaded.name == "plugin_with_config"
}

/// `plugin_children/1` にはプラグイン 1 つぶんの設定 map が届く。キーは接頭辞を
/// 取り除いて小文字にしたもので、他のプラグイン向けの変数は混ざらない。
pub fn children_receives_config_test() {
  let assert Ok(_) =
    plugin.load(
      atom.create("support@plugin_with_config"),
      dict.from_list([
        #("PLUGIN_PLUGIN_WITH_CONFIG_PATH", "/tmp/events.log"),
        #("PLUGIN_COUNTER_LIMIT", "10"),
      ]),
      plugin.default_call_timeout_ms,
    )
  assert saved_config(plugin_with_config.children_config_key())
    == dict.from_list([#("path", "/tmp/events.log")])
}

/// `handle_event/2` があればそちらが呼ばれ、設定 map が第 2 引数に届く。
pub fn handle_receives_config_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_with_config"),
      dict.from_list([#("PLUGIN_PLUGIN_WITH_CONFIG_PATH", "/tmp/events.log")]),
      plugin.default_call_timeout_ms,
    )
  loaded.handle(sample_event())
  assert saved_config(plugin_with_config.handle_config_key())
    == dict.from_list([#("path", "/tmp/events.log")])
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
    == "plugin_rejecting_config: plugin_children/1 rejected the configuration "
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

/// `plugin_pages` と `plugin_page_content` のどちらも無いプラグインは今までどおり
/// 読み込まれ、`ui` は `None`。
pub fn load_without_ui_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_valid"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  assert loaded.ui == None
}

/// `plugin_pages/1` と `plugin_page_content/2` を持つプラグインは、`ui` に検証
/// 済みのページの一覧が載り、`content(key)` がそのページの記述を返す。
pub fn load_with_pages_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_with_pages"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
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
  let assert Ok(loaded) =
    plugin.load(
      atom.create("support@plugin_with_localized_pages"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
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

/// `plugin_pages/2` を呼ぶ言語は、管理 UI の表示の言語と同じ並びである。
pub fn page_languages_are_the_admin_languages_test() {
  assert plugin.page_languages == list.map(i18n.languages, i18n.code)
}

/// アカウント 1 件の map を読む decoder。
fn page_account_decoder() -> decode.Decoder(#(String, String, String)) {
  use pubkey <- decode.field("pubkey", decode.string)
  use npub <- decode.field("npub", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(#(pubkey, npub, label))
}

/// `plugin_page_action/3` があればそちらを優先して呼び、送信したキー・値・
/// 登録アカウントの一覧（`Accounts`）が届く。成功は `Ok(Nil)`。
pub fn plugin_with_a_page_action_is_loaded_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("plugin_with_action"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  let assert Some(ui) = loaded.ui
  let assert Some(action) = ui.action
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
      persistent_term_get(atom.create("plugin_with_action")),
      stored_decoder,
    )
  assert key == "settings"
  assert values == dict.from_list([#("main", "on")])
  let assert Ok(accounts_json) =
    decode.run(config, decode.field("Accounts", decode.string, decode.success))
  let assert Ok(decoded_accounts) =
    json.parse(accounts_json, decode.list(page_account_decoder()))
  assert decoded_accounts == [#("abcd", "npub1x", "main")]
}

/// `plugin_page_action/3` が無く `/2` だけのプラグインは `/2` が呼ばれ、設定 map
/// を渡さない（fixture が退避した値が `{Key, Values}` の 2 要素であることで
/// 確かめる）。
pub fn page_action_arity_two_is_used_when_three_is_missing_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("plugin_with_action_arity_two"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  let assert Some(ui) = loaded.ui
  let assert Some(action) = ui.action
  let assert Ok(Nil) = action("settings", [#("main", "on")], [])
  let stored_decoder = {
    use key <- decode.field(0, decode.string)
    use values <- decode.field(1, decode.dict(decode.string, decode.string))
    decode.success(#(key, values))
  }
  let assert Ok(#(key, values)) =
    decode.run(
      persistent_term_get(atom.create("plugin_with_action_arity_two")),
      stored_decoder,
    )
  assert key == "settings"
  assert values == dict.from_list([#("main", "on")])
}

/// `{error, Reason}` が拒否の理由になる。
pub fn page_action_error_tuple_is_a_reason_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("plugin_with_action"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  let assert Some(ui) = loaded.ui
  let assert Some(action) = ui.action
  let assert Error(reason) =
    action("settings", [#("reject", "select at least one account")], [])
  assert reason
    == "plugin_with_action: plugin_page_action/3 rejected the request (select at least one account)"
}

/// `ok` でも `{error, _}` でもない戻り値は、その形を報告する理由になる。
pub fn page_action_with_a_bad_return_is_a_reason_test() {
  let assert Ok(loaded) =
    plugin.load(
      atom.create("plugin_with_action"),
      dict.new(),
      plugin.default_call_timeout_ms,
    )
  let assert Some(ui) = loaded.ui
  let assert Some(action) = ui.action
  let assert Error(reason) = action("settings", [#("bad-return", "on")], [])
  assert reason
    == "plugin_with_action: plugin_page_action/3 must return ok or {error, Reason}, got Atom"
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

/// fixture が退避した値を読む。キーが無ければ例外になる。
@external(erlang, "persistent_term", "get")
fn persistent_term_get(key: Atom) -> Dynamic
