//// `plugin_children/0` が例外を投げる fixture。壊れたモジュールが本体の起動を
//// 止めないことの確認に使う。
////
//// gleeunit は `test/` 配下の全ファイルを eunit に渡すため、関数名を `_test` で
//// 終わらせてはならない。

import gleam/dynamic.{type Dynamic}

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// ダッシュボードとログに出る表示名。
pub fn plugin_name() -> String {
  "plugin_crashing_children"
}

/// 子仕様の問い合わせで落ちる。
pub fn plugin_children() -> List(Dynamic) {
  panic as "boom"
}

/// 読み込みが拒否されるので呼ばれない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}
