//// 番号付きの項目を並べるための整数の一覧。`gleam/list` に範囲の一覧が無く、`int.range`
//// は畳み込みで、終端を含まず、終端が始点より小さいと降順に進む。昇順で、空にもなりうる
//// 一覧をここで 1 つにする。

import gleam/int
import gleam/list

/// `0` から `count - 1` までの整数を昇順に並べる。`count` が 0 以下なら空にする。
pub fn below(count: Int) -> List(Int) {
  case count > 0 {
    True -> int.range(from: count - 1, to: -1, with: [], run: list.prepend)
    False -> []
  }
}

/// `1` から `count` までの整数を昇順に並べる。`count` が 0 以下なら空にする。
pub fn up_to(count: Int) -> List(Int) {
  list.map(below(count), fn(index) { index + 1 })
}
