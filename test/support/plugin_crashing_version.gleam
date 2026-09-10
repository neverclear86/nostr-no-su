//// `plugin_api_version/0` が例外を投げるプラグイン fixture。

import gleam/dynamic.{type Dynamic}

/// 呼ぶと必ずクラッシュする。
pub fn plugin_api_version() -> Int {
  panic as "plugin_api_version is broken"
}

/// 表示名。
pub fn plugin_name() -> String {
  "plugin_crashing_version"
}

/// バージョン取得で弾かれるため呼ばれない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}
