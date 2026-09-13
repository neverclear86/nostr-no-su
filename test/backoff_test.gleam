import gleam/list
import nostr_no_su/backoff.{Backoff}

/// 待ち時間は失敗のたびに倍になり、上限で頭打ちになる。
pub fn next_doubles_up_to_the_maximum_test() {
  let retry = Backoff(initial_ms: 5000, max_ms: 120_000)
  let next = backoff.next(retry, _)
  assert next(5000) == 10_000
  assert next(10_000) == 20_000
  assert next(20_000) == 40_000
  assert next(40_000) == 80_000
  assert next(80_000) == 120_000
  assert next(120_000) == 120_000
}

/// 指定したパーセントで揺らす。境界（-20、0、20）は整数の除算で切り捨てる。
pub fn jitter_shifts_by_the_given_percent_test() {
  assert backoff.jitter(1000, -20) == 800
  assert backoff.jitter(1000, 0) == 1000
  assert backoff.jitter(1000, 20) == 1200
}

/// 揺らした値は乱数を使っても常に ±20% の範囲に収まる。
pub fn jittered_stays_within_twenty_percent_test() {
  use _ <- list.each(list.repeat(Nil, 200))
  let value = backoff.jittered(1000)
  assert value >= 800
  assert value <= 1200
}
