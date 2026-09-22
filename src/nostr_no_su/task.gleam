//// 仕事を別プロセスで走らせ、共通の締め切りまで待つ。管理 UI のダッシュボードの
//// 複数の問い合わせと、`plugin_api` の送信の集計が使う。

import gleam/erlang/process.{type Subject}
import gleam/int
import nostr_no_su/time

/// `monotonic_ms` の目盛りでの期限。
pub type Deadline {
  Deadline(at_ms: Int)
}

/// 今から `ms` 後の期限。
pub fn deadline_in(ms: Int) -> Deadline {
  Deadline(at_ms: time.monotonic_ms() + ms)
}

/// 走らせた仕事と、その結果を受け取る subject。
pub opaque type Task(a) {
  Task(reply: Subject(a))
}

/// `run` をリンクしない別プロセスで走らせる。呼び出し元は待たない。`run` が落ちても
/// 呼び出し元は道連れにならず、結果はただ届かない。
pub fn start(run: fn() -> a) -> Task(a) {
  let reply = process.new_subject()
  process.spawn_unlinked(fn() { process.send(reply, run()) })
  Task(reply:)
}

/// 期限までに結果が届けば `Ok`、届かなければ `Error(Nil)`。期限を過ぎていても、
/// 既に届いた結果は取れる。
pub fn await(task: Task(a), deadline: Deadline) -> Result(a, Nil) {
  let Deadline(at_ms) = deadline
  process.receive(task.reply, int.max(0, at_ms - time.monotonic_ms()))
}
