//// 本体が対応していない API バージョンを名乗るプラグイン fixture。

import gleam/dynamic.{type Dynamic}

/// 本体（v1）が受け付けないバージョン。
pub fn plugin_api_version() -> Int {
  2
}

/// 表示名。
pub fn plugin_name() -> String {
  "plugin_bad_version"
}

/// バージョン検証で弾かれるため呼ばれない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}
