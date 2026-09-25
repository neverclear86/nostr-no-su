//// `plugin_name/0` を欠くプラグイン fixture。

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// 何もしない。
pub fn handle_event(_event: a) -> Nil {
  Nil
}
