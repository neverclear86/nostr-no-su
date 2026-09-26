//// 仕事を別プロセスで走らせ、共通の締め切りまで待つ。締め切り（`Deadline`）と
//// その残り時間、締め切りまでの subject からの受信、項目ごとの並行な実行を持つ。

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import nostr_no_su/time

/// `monotonic_ms` の目盛りでの期限。
pub opaque type Deadline {
  Deadline(at_ms: Int)
}

/// 今から `ms` 後の期限。
pub fn deadline_in(ms: Int) -> Deadline {
  Deadline(at_ms: time.monotonic_ms() + ms)
}

/// 期限までの残りのミリ秒。期限を過ぎていれば 0。
pub fn remaining_ms(deadline: Deadline) -> Int {
  int.max(0, deadline.at_ms - time.monotonic_ms())
}

/// `subject` から期限まで 1 件受け取る。期限までに届かなければ `Error(Nil)`。期限を
/// 過ぎていても、既に届いたメッセージは取れる。
pub fn receive(subject: Subject(a), deadline: Deadline) -> Result(a, Nil) {
  process.receive(subject, remaining_ms(deadline))
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
  receive(task.reply, deadline)
}

/// `items` の各項目に `run` を別々の `start` で同時に走らせ、全部を同じ期限で
/// `await` する。結果は `items` の順に並ぶ。
pub fn map_within(
  items: List(a),
  deadline: Deadline,
  run: fn(a) -> b,
) -> List(Result(b, Nil)) {
  items
  |> list.map(fn(item) { start(fn() { run(item) }) })
  |> list.map(await(_, deadline))
}
