import nostr_no_su/time
import support/app_tree.{call_counter}
import support/poll

/// 最初の試しで真なら眠らずに `True` を返す。
pub fn until_returns_at_once_when_the_check_holds_test() {
  let started = time.monotonic_ms()
  assert poll.until(fn() { True }, 1000, 500)
  assert time.monotonic_ms() - started < 500
}

/// 真になった試しで `True` を返し、それ以上試さない。
pub fn until_stops_at_the_first_true_check_test() {
  let next = call_counter()
  assert poll.until(fn() { next() >= 2 }, 1000, 10)
  assert next() == 3
}

/// 偽のままなら、期限 / 間隔 + 1 回試して `False` を返す。
pub fn until_gives_up_after_the_timeout_test() {
  let next = call_counter()
  assert !poll.until(
    fn() {
      next()
      False
    },
    100,
    10,
  )
  assert next() == 11
}
