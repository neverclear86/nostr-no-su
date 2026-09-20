import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/plugin
import support/plugin_valid
import support/plugin_with_config
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
  let assert Ok(description) = ui.content(plugin_with_pages.page_key)
  let assert Ok(sections) =
    decode.run(
      description,
      decode.field("sections", decode.list(decode.dynamic), decode.success),
    )
  assert list.length(sections) == 1
}

/// fixture が退避した値を読む。キーが無ければ例外になる。
@external(erlang, "persistent_term", "get")
fn persistent_term_get(key: Atom) -> Dynamic
