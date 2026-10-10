//// プラグイン固有の設定を受け取る fixture。`plugin_children/1` と
//// `handle_event/2` だけをエクスポートし、`handle_event/1` は持たない
//// （`examples/plugins/file_logger` と同じ形）。
////
//// 受け取った設定 map を `persistent_term` へ退避するので、設定が実際に届いた
//// ことをテストから確認できる。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import nostr_no_su/persistent_term

/// `plugin_children/1` が受け取った設定 map を退避する persistent_term のキー。
pub fn children_config_key() -> Atom {
  atom.create("support_plugin_with_config_children")
}

/// `handle_event/2` が受け取った設定 map を退避する persistent_term のキー。
pub fn handle_config_key() -> Atom {
  atom.create("support_plugin_with_config_handle")
}

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// ダッシュボードとログに出る表示名。
pub fn plugin_name() -> String {
  "plugin_with_config"
}

/// 子プロセスは持たない。設定を受け取ったことだけを記録して空のリストを返す。
pub fn plugin_children(config: Dynamic) -> List(Dynamic) {
  let _ = persistent_term.put(children_config_key(), config)
  []
}

/// 受け取った設定 map をテストから読めるように退避する。
pub fn handle_event(_event: Dynamic, config: Dynamic) -> Nil {
  let _ = persistent_term.put(handle_config_key(), config)
  Nil
}
