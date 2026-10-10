//// テストが開ける門。使いどころは docs/development.md の「テストの流儀」。

import gleam/erlang/process.{type Subject}

/// 呼び出し側を、テストが開けるまで止める。呼び出し側のプロセスで作った門の
/// subject を `gates` へ渡し、テストがそこへ `Nil` を送るまで戻らない。subject は
/// 所有するプロセスでしか受信できないので、門はテストのプロセスではなく呼び出し側で作る。
pub fn until_released(gates: Subject(Subject(Nil))) -> Nil {
  let gate = process.new_subject()
  process.send(gates, gate)
  process.receive_forever(gate)
}
