//// 任意エクスポート `plugin_children/0` を持つ fixture。子仕様の map は
//// `child_fixture` が組み立てる（Gleam で atom キーの map を作らないため）。
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
  "plugin_with_children"
}

/// 自分で起こしたいプロセスの子仕様。読み込みの検証にしか使わないので、
/// 実際に起動されることはない。
pub fn plugin_children() -> List(Dynamic) {
  [spec(atom.create("store"), atom.create("plugin_with_children_store"))]
}

/// このプラグインは状態を持たないので、イベントは捨てる。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}

/// 検証を通る子仕様。
@external(erlang, "child_fixture", "spec")
fn spec(kind: Atom, name: Atom) -> Dynamic
