//// プラグイン固有の設定。環境変数 `PLUGIN_<NAME>_<KEY>` を集めて、プラグイン
//// ごとの binary キーの map にする。
////
//// **環境変数を読むのはこのモジュールではない**（`config.gleam` が 1 か所で
//// 読む）。ここが持つのは、集めた環境変数からプラグイン 1 つぶんの設定を切り
//// 出す規則と、境界へ渡す map への変換だけである。
////
//// **境界に置くのはキーも値も binary の Erlang map** であって Gleam の Dict や
//// レコードではない。イベント map（`event.to_map`）と同じ理由で、Erlang /
//// Elixir で書いたプラグインからそのまま読めることを優先する。
////
//// 値は変換しない。環境変数はすべて文字列であり、整数として読むべきか URL と
//// して読むべきかを本体は知らない。**変換はプラグインの責任**で、失敗は
//// `plugin_children/1` の `{error, Reason}` として報告できる。
////
//// **接頭辞は隔離ではない。** 名前で整理して何が渡るかを読めるようにするための
//// 規約であって、プラグインは `os:getenv/1` を自由に呼べる（`docs/plugin-api.md`
//// 第 1 章の信頼モデル）。

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string

/// プラグインへ渡す環境変数の共通接頭辞。
pub const env_prefix = "PLUGIN_"

/// プラグイン名の正規化で残す文字。これ以外はすべて `_` にする。
const name_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

/// プラグイン 1 つぶんの設定。キーは小文字、値は環境変数の文字列そのまま。
pub type Config =
  Dict(String, String)

/// プラグイン名に対応する環境変数の接頭辞。`file_logger` なら
/// `PLUGIN_FILE_LOGGER_`。名前は大文字化し、`[A-Z0-9]` 以外は `_` にする
/// （環境変数名に使えない文字を含むプラグイン名があるため）。**末尾の `_` まで
/// 含めて接頭辞である。** これがあるおかげで `PLUGIN_DIR` はどのプラグインにも
/// 一致しない（`PLUGIN_DIR` は `PLUGIN_DIR_` で始まらない）。
pub fn prefix(plugin_name: String) -> String {
  env_prefix <> normalize(plugin_name) <> "_"
}

/// プラグイン名を環境変数名の一部として使える形にする。
fn normalize(plugin_name: String) -> String {
  string.uppercase(plugin_name)
  |> string.to_graphemes
  |> list.map(fn(character) {
    case string.contains(name_alphabet, character) {
      True -> character
      False -> "_"
    }
  })
  |> string.join("")
}

/// 集めた `PLUGIN_*` からプラグイン 1 つぶんの設定を切り出す。接頭辞に一致し、
/// かつ**残りが空でない**ものだけを採り、キーは小文字にする。一致しなければ空。
///
/// 「残りが空でない」条件が弾くのは `PLUGIN_FILE_LOGGER_=x` のような**キーが空の
/// 変数**である。空のキーは環境変数名としては書けてしまうが、プラグインからは
/// `<<"">>` としてしか読めず意味を持たない。
pub fn for_plugin(env: Dict(String, String), plugin_name: String) -> Config {
  let prefix = prefix(plugin_name)
  let prefix_length = string.length(prefix)
  dict.fold(env, dict.new(), fn(config, name, value) {
    case string.starts_with(name, prefix) {
      False -> config
      True ->
        case string.drop_start(name, prefix_length) {
          "" -> config
          key -> dict.insert(config, string.lowercase(key), value)
        }
    }
  })
}

/// プラグイン境界へ渡す map。`event.to_map` と同じく `dynamic.properties/1` で
/// binary キー・binary 値の Erlang map を作る。
pub fn to_map(config: Config) -> Dynamic {
  dict.to_list(config)
  |> list.map(fn(entry) { #(dynamic.string(entry.0), dynamic.string(entry.1)) })
  |> dynamic.properties
}
