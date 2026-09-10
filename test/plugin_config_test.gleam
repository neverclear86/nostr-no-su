//// プラグイン固有の設定の切り出しと、境界へ渡す map への変換のテスト。

import gleam/dict
import gleam/dynamic/decode
import nostr_no_su/plugin_config

/// テストで使う環境変数の集合。
fn env() -> dict.Dict(String, String) {
  dict.from_list([
    #("PLUGIN_FILE_LOGGER_PATH", "/tmp/events.log"),
    #("PLUGIN_FILE_LOGGER_LEVEL", "debug"),
    #("PLUGIN_COUNTER_LIMIT", "10"),
    #("PLUGIN_DIR", "/plugins"),
  ])
}

/// 接頭辞はプラグイン名を大文字化したもので、**末尾の `_` まで含む**。
/// `[A-Z0-9]` 以外の文字は `_` になるので、区切り文字の違いは潰れる。
pub fn prefix_test() {
  assert plugin_config.prefix("file_logger") == "PLUGIN_FILE_LOGGER_"
  assert plugin_config.prefix("my-plugin") == "PLUGIN_MY_PLUGIN_"
  assert plugin_config.prefix("my_plugin") == "PLUGIN_MY_PLUGIN_"
  // 非 ASCII の名前はすべて `_` に潰れる。環境変数名に非 ASCII は使えないため、
  // これは意図した挙動であり、文書では ASCII の名前を推奨している。
  assert plugin_config.prefix("日本語") == "PLUGIN_____"
}

/// 接頭辞に一致する変数だけを採り、キーは接頭辞を取り除いて小文字にする。
/// 他のプラグイン向けの変数は混ざらない。
pub fn for_plugin_test() {
  assert plugin_config.for_plugin(env(), "file_logger")
    == dict.from_list([#("path", "/tmp/events.log"), #("level", "debug")])
}

/// **`PLUGIN_DIR` はどのプラグインにも一致しない。** 一致しない理由は
/// 接頭辞の末尾の `_` であって（`prefix("dir")` は `"PLUGIN_DIR_"` で、
/// `"PLUGIN_DIR"` はこれで始まらない）、キーが空でないという条件ではない。
pub fn plugin_dir_never_matches_test() {
  assert plugin_config.for_plugin(env(), "dir") == dict.new()
}

/// キーが空の変数（`PLUGIN_FILE_LOGGER_=x`）は落とす。環境変数名としては書けて
/// しまうが、プラグインからは `<<"">>` としてしか読めず意味を持たない。
pub fn empty_key_is_dropped_test() {
  let env = dict.from_list([#("PLUGIN_FILE_LOGGER_", "x")])
  assert plugin_config.for_plugin(env, "file_logger") == dict.new()
}

/// 一致する変数が 1 つも無ければ空になる。`None` にしないのは、プラグイン側の
/// 場合分けを増やさないため。
pub fn no_match_is_empty_test() {
  assert plugin_config.for_plugin(env(), "nothing") == dict.new()
  assert plugin_config.for_plugin(dict.new(), "file_logger") == dict.new()
}

/// 境界に置くのはキーも値も binary の Erlang map。`event.to_map` と同じ表現規則
/// なので、Erlang / Elixir で書いたプラグインからそのまま読める。
pub fn to_map_test() {
  let config = plugin_config.for_plugin(env(), "counter")
  assert decode.run(
      plugin_config.to_map(config),
      decode.dict(decode.string, decode.string),
    )
    == Ok(dict.from_list([#("limit", "10")]))
}
