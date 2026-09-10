//// `plugin_children/0` が API に合わない子仕様を返す fixture。読み込みが拒否
//// されることの確認に使う。
////
//// gleeunit は `test/` 配下の全ファイルを eunit に渡すため、関数名を `_test` で
//// 終わらせてはならない。

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

/// 対応するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// ダッシュボードとログに出る表示名。
pub fn plugin_name() -> String {
  "plugin_bad_children"
}

/// `id` を欠いた子仕様。検証で弾かれる。
pub fn plugin_children() -> List(Dynamic) {
  [bad_spec(atom.create("no_id"))]
}

/// 検証で弾かれるので呼ばれない。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}

/// 検証で弾かれる子仕様。
@external(erlang, "child_fixture", "bad_spec")
fn bad_spec(kind: Atom) -> Dynamic
