//// プラグイン API v1 を満たす fixture。`plugin.load` の正常系と、`Plugin.handle`
//// がイベント map をプラグインへ届けることの確認に使う。
////
//// gleeunit は `test/` 配下の全ファイルを eunit に渡すため、関数名を `_test` で
//// 終わらせてはならない。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

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
  // persistent_term:put/2 は atom の ok を返すので、型を偽らず捨てる。
  let _ = put(last_event_key(), event)
  Nil
}

/// 値を persistent_term に退避する。戻り値は atom の ok。
@external(erlang, "persistent_term", "put")
fn put(key: Atom, value: Dynamic) -> Dynamic
