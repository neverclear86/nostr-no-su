import gleam/erlang/process
import gleam/list
import nostr_no_su/task
import nostr_no_su/time
import support/erl.{message_queue_len}
import support/poll

/// 期限内に終わる仕事は `Ok` になる。
pub fn await_returns_the_value_test() {
  let job = task.start(fn() { 7 })
  assert task.await(job, task.deadline_in(1000)) == Ok(7)
}

/// 3 秒眠る仕事を 100ms の期限で待つと `Error(Nil)` になり、経過は期限に収まる
/// （1 秒未満）。仕事の眠りは待たずに終わるので、テストの時間は期限だけである。
pub fn await_gives_up_at_the_deadline_test() {
  let job =
    task.start(fn() {
      process.sleep(3000)
      7
    })
  let started_at = time.monotonic_ms()
  assert task.await(job, task.deadline_in(100)) == Error(Nil)
  assert time.monotonic_ms() - started_at < 1000
}

/// 3 秒眠る仕事 3 件を 1 つの締め切りで待つと、全て `Error(Nil)` になり、合計の
/// 経過は 1 秒未満に収まる（締め切りは待ちの合計ではなく、仕事の数によらず一定）。
pub fn a_shared_deadline_bounds_the_total_wait_test() {
  let sleeper = fn() {
    process.sleep(3000)
    7
  }
  let jobs = [task.start(sleeper), task.start(sleeper), task.start(sleeper)]
  let deadline = task.deadline_in(100)
  let started_at = time.monotonic_ms()
  let results = list.map(jobs, task.await(_, deadline))
  assert results == [Error(Nil), Error(Nil), Error(Nil)]
  assert time.monotonic_ms() - started_at < 1000
}

/// 期限を過ぎていても、すでに届いた結果は取れる。結果が届いたことは待ち時間ではなく
/// メールボックスのメッセージの数で確かめる。テストプロセスのメールボックスには同じ
/// レーンの前のテストが残したメッセージがあるので、空のメールボックスを持つ別の
/// プロセスで確かめる。
pub fn a_result_that_already_arrived_is_taken_after_the_deadline_test() {
  let results = process.new_subject()
  process.spawn(fn() {
    let job = task.start(fn() { 7 })
    let arrived = poll.until(fn() { message_queue_len() > 0 }, 1000, 10)
    process.send(results, #(arrived, task.await(job, task.deadline_in(0))))
  })
  assert process.receive(results, 2000) == Ok(#(True, Ok(7)))
}

/// `panic` する仕事は `Error(Nil)` になり、呼び出し元は道連れにならず後続の
/// `await` も動く。
pub fn a_crashed_task_does_not_kill_the_caller_test() {
  let job = task.start(fn() { panic as "boom" })
  assert task.await(job, task.deadline_in(100)) == Error(Nil)
  assert task.await(task.start(fn() { 1 }), task.deadline_in(300)) == Ok(1)
}

/// `remaining_ms` は期限までの残りを返し、期限を過ぎていれば 0 で頭打ちになる。
pub fn remaining_ms_is_zero_after_the_deadline_test() {
  let remaining = task.remaining_ms(task.deadline_in(10_000))
  assert remaining > 9000 && remaining <= 10_000
  assert task.remaining_ms(task.deadline_in(-100)) == 0
}

/// `receive` は期限を過ぎていても、すでに届いたメッセージは取れる。
pub fn receive_takes_a_queued_message_after_the_deadline_test() {
  let subject = process.new_subject()
  process.send(subject, 7)
  assert task.receive(subject, task.deadline_in(-100)) == Ok(7)
}

/// `receive` は期限までメッセージを待つ。50ms 後に送る別プロセスのメッセージを
/// 1 秒の期限で受け取れる。
pub fn receive_waits_for_a_message_before_the_deadline_test() {
  let subject = process.new_subject()
  process.spawn(fn() {
    process.sleep(50)
    process.send(subject, 7)
  })
  assert task.receive(subject, task.deadline_in(1000)) == Ok(7)
}

/// `receive` は期限までに届かなければ `Error(Nil)` になり、経過は期限に収まる
/// （1 秒未満）。
pub fn receive_gives_up_at_the_deadline_test() {
  let subject = process.new_subject()
  let started_at = time.monotonic_ms()
  assert task.receive(subject, task.deadline_in(100)) == Error(Nil)
  assert time.monotonic_ms() - started_at < 1000
}

/// `map_within` は全項目を別々のプロセスで同時に走らせる。200ms 眠る 3 件を
/// 1 秒の期限で待つと全部 `Ok` になり、経過は直列の 600ms より短い 500ms 未満に
/// 収まる。
pub fn map_within_runs_the_items_concurrently_test() {
  let started_at = time.monotonic_ms()
  let results =
    task.map_within([10, 20, 30], task.deadline_in(1000), fn(item) {
      process.sleep(200)
      item
    })
  assert results == [Ok(10), Ok(20), Ok(30)]
  assert time.monotonic_ms() - started_at < 500
}

/// `map_within` は期限切れの項目だけ `Error(Nil)` にし、結果は項目の順に並ぶ。
/// 経過は眠る項目の 3 秒を待たず 1 秒未満に収まる。
pub fn map_within_gives_up_on_slow_items_at_the_deadline_test() {
  let started_at = time.monotonic_ms()
  let results =
    task.map_within([0, 3000], task.deadline_in(100), fn(ms) {
      process.sleep(ms)
      ms
    })
  assert results == [Ok(0), Error(Nil)]
  assert time.monotonic_ms() - started_at < 1000
}
