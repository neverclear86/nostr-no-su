//// `plugin_name/0` が String 以外を返すプラグイン fixture。

import gleam/dynamic.{type Dynamic}

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// 仕様に反して Int を返す。
pub fn plugin_name() -> Int {
  42
}

/// 名前の検証で弾かれるため呼ばれない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}
