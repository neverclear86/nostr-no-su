//// プラグイン API v1 を満たす fixture。`plugin.load` の正常系と、`Plugin.handle`
//// がイベント map をプラグインへ届けることの確認に使う。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import nostr_no_su/persistent_term

/// 受け取ったイベント map を退避する persistent_term のキー。
pub fn last_event_key() -> Atom {
  atom.create("support_plugin_valid_last_event")
}

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// ダッシュボードとログに出る表示名。
pub fn plugin_name() -> String {
  "plugin_valid"
}

/// 受け取ったイベント map をテストから読めるように退避する。
pub fn handle_event(event: Dynamic) -> Nil {
  let _ = persistent_term.put(last_event_key(), event)
  Nil
}
