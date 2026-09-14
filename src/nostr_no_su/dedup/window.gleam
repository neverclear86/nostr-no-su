//// 直近に見たイベント id のスライディングウィンドウ。
////
//// プロセスにも IO にも触れない純粋な値なので、監視のディスパッチャー（`dedup`）
//// と NIP-46 のリプレイ防止（`bunker/engine`）の両方が、アクターに依存せずこれ
//// だけを使える。
////
//// メモリ使用量は 2 世代で有界にする。現在の世代の id が `capacity` 件に達すると
//// 前世代に移して新しい世代を開始するため、常に `capacity` 件以上 `2 * capacity`
//// 件以下の直近 id を記憶する。
////
//// `capacity` は 1 以上を前提とする（0 以下は 1 と同じ振る舞いになる）。

import gleam/set.{type Set}

/// 記憶している id。ウィンドウが埋まったときに最古の世代をまとめて捨てられる
/// よう、2 世代に分けて保持する。
pub opaque type Window {
  Window(capacity: Int, current: Set(String), previous: Set(String))
}

/// 少なくとも `capacity` 件の id を記憶する空のウィンドウ。
pub fn new(capacity: Int) -> Window {
  Window(capacity: capacity, current: set.new(), previous: set.new())
}

/// id を記録し、現在の世代が埋まったら世代を切り替える。ウィンドウがすでに
/// その id を持つ場合は `Error(Nil)` を返す。
pub fn insert(window: Window, id: String) -> Result(Window, Nil) {
  case set.contains(window.current, id) || set.contains(window.previous, id) {
    True -> Error(Nil)
    False -> {
      let current = set.insert(window.current, id)
      case set.size(current) >= window.capacity {
        True -> Ok(Window(..window, previous: current, current: set.new()))
        False -> Ok(Window(..window, current: current))
      }
    }
  }
}
