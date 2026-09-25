//// 条件が真になるまで短い間隔で試す待ち。テストが非同期の変化（名前の登録、
//// アクターの状態、プロセスの停止）を観測するのに使う。

import gleam/erlang/process

/// `check` が真になるまで `interval_ms` ごとに試し、真になれば `True` を返す。
/// 最初の試しは眠らずに行い、眠るたびに `timeout_ms` から `interval_ms` を引く。
/// 0 以下になった後の試しも偽なら `False` を返す。
pub fn until(check: fn() -> Bool, timeout_ms: Int, interval_ms: Int) -> Bool {
  case check(), timeout_ms <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(interval_ms)
      until(check, timeout_ms - interval_ms, interval_ms)
    }
  }
}
