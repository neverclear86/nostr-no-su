//// 失敗を繰り返す処理の再試行の待ち時間。初期値から失敗のたびに倍にして上限で
//// 頭打ちにし、予約の直前にジッターを掛けて、同時に失敗した複数の再試行が
//// そろって叩かないようにする。

import gleam/int

/// ジッターの揺らし幅（パーセント）。`jittered` はこの範囲で一様に揺らす。
const jitter_percent = 20

/// 再試行の待ち時間の延ばし方。最初の失敗の後は `initial_ms` 待ち、失敗が続く
/// たびに倍にして `max_ms` で頭打ちにする。`max_ms` は基準値の上限で、ジッターを
/// 掛けた実際の待ちは最大でその 1.2 倍になる。
pub type Backoff {
  Backoff(initial_ms: Int, max_ms: Int)
}

/// `delay_ms` 待った後の試行も失敗したときの、次の待ち時間。倍にして上限で
/// 頭打ちにする。
pub fn next(backoff: Backoff, delay_ms: Int) -> Int {
  int.min(delay_ms * 2, backoff.max_ms)
}

/// `delay_ms` を `percent`％ずらした値（整数の除算で切り捨て）。`percent` は
/// `jittered` が -20〜20 で選ぶ。
pub fn jitter(delay_ms: Int, percent: Int) -> Int {
  delay_ms * { 100 + percent } / 100
}

/// `delay_ms` を ±20% の範囲で一様に揺らした値。乱数を使うので、決定的に検査
/// するときは `jitter` を使う。
pub fn jittered(delay_ms: Int) -> Int {
  jitter(delay_ms, int.random(2 * jitter_percent + 1) - jitter_percent)
}
