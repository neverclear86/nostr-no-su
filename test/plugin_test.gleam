import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/string
import nostr_no_su/nostr/event.{Event}
import nostr_no_su/plugin
import support/plugin_valid

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

/// 読み込みに失敗した理由の文字列を取り出す。
fn load_error(module_name: String) -> String {
  let assert Error(reason) = plugin.load(atom.create(module_name))
  reason
}

/// API v1 を満たすモジュールを読み込むと、`plugin_name/0` の値が `Plugin.name`
/// になる。
pub fn load_valid_test() {
  let assert Ok(loaded) = plugin.load(atom.create("support@plugin_valid"))
  assert loaded.name == "plugin_valid"
}

/// 必須エクスポートを欠くモジュールは、欠けている関数を名指しで拒否する。
pub fn load_missing_export_test() {
  let reason = load_error("support@plugin_missing_handle")
  assert string.contains(reason, "missing export")
  assert string.contains(reason, "handle_event/1")
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
    "crashed",
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
  let assert Ok(loaded) = plugin.load(atom.create("support@plugin_valid"))
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
  let assert Ok(_) = plugin.load(module)
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
  let assert Ok(loaded) = plugin.load(atom.create("minimal_plugin"))
  assert loaded.name == "minimal_plugin"
}

/// 任意エクスポート `plugin_children/0` を持つモジュールは、子仕様を解決した
/// 状態で読み込まれる。
pub fn load_resolves_children_test() {
  let assert Ok(loaded) =
    plugin.load(atom.create("support@plugin_with_children"))
  assert list.length(loaded.children) == 1
}

/// `plugin_children/0` を持たないモジュールは子を持たない。
pub fn load_without_children_export_test() {
  let assert Ok(loaded) = plugin.load(atom.create("support@plugin_valid"))
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

/// fixture が退避した値を読む。キーが無ければ例外になる。
@external(erlang, "persistent_term", "get")
fn persistent_term_get(key: Atom) -> Dynamic
