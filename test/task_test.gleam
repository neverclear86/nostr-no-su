import gleam/erlang/process
import gleam/list
import nostr_no_su/task
import nostr_no_su/time

/// 期限内に終わる仕事は `Ok` になる。
pub fn await_returns_the_value_test() {
  let job = task.start(fn() { 7 })
  assert task.await(job, task.deadline_in(1000)) == Ok(7)
}

/// 3 秒眠る仕事を 300ms の期限で待つと `Error(Nil)` になり、経過は期限に収まる
/// （1 秒未満）。
pub fn await_gives_up_at_the_deadline_test() {
  let job =
    task.start(fn() {
      process.sleep(3000)
      7
    })
  let started_at = time.monotonic_ms()
  assert task.await(job, task.deadline_in(300)) == Error(Nil)
  assert time.monotonic_ms() - started_at < 1000
}

/// 3 秒眠る仕事 3 件を 1 つの締め切りで待つと、全て `Error(Nil)` になり、合計の
/// 経過は 1 秒未満に収まる（#88 の完了条件の骨格：締め切りは待ちの合計ではなく、
/// 仕事の数によらず一定）。
pub fn a_shared_deadline_bounds_the_total_wait_test() {
  let sleeper = fn() {
    process.sleep(3000)
    7
  }
  let jobs = [task.start(sleeper), task.start(sleeper), task.start(sleeper)]
  let deadline = task.deadline_in(300)
  let started_at = time.monotonic_ms()
  let results = list.map(jobs, task.await(_, deadline))
  assert results == [Error(Nil), Error(Nil), Error(Nil)]
  assert time.monotonic_ms() - started_at < 1000
}

/// 期限を過ぎていても、すでに届いた結果は取れる。
pub fn a_result_that_already_arrived_is_taken_after_the_deadline_test() {
  let job = task.start(fn() { 7 })
  process.sleep(50)
  assert task.await(job, task.deadline_in(0)) == Ok(7)
}

/// `panic` する仕事は `Error(Nil)` になり、呼び出し元は道連れにならず後続の
/// `await` も動く。
pub fn a_crashed_task_does_not_kill_the_caller_test() {
  let job = task.start(fn() { panic as "boom" })
  assert task.await(job, task.deadline_in(300)) == Error(Nil)
  assert task.await(task.start(fn() { 1 }), task.deadline_in(300)) == Ok(1)
}
