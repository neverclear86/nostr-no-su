//// `plugin_name/0` が空文字列を返すプラグイン fixture。

import gleam/dynamic.{type Dynamic}

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// 仕様に反して空の名前を返す。
pub fn plugin_name() -> String {
  ""
}

/// 名前の検証で弾かれるため呼ばれない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}
