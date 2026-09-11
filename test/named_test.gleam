import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import nostr_no_su/named

/// 問い合わせに使うメッセージ。宛先の振る舞いを模す。
type Msg {
  /// すぐに応答し、その後もしばらく生き続ける。
  Answer(reply: Subject(String))
  /// 応答しないまま生き続ける。呼び出し側はタイムアウトになる。
  Ignore(reply: Subject(String))
  /// 呼び出し側のタイムアウトより後に応答する。
  AnswerLate(reply: Subject(String))
  /// 応答せずに終了する。
  Exit(reply: Subject(String))
}

/// 宛先が応答するまでの遅れ。`AnswerLate` の問い合わせのタイムアウトより長い。
const late_reply_ms = 300

/// 指定した名前でメッセージを 1 件受け取るプロセスを起動し、名前が登録される
/// まで待つ。アクターを起動せずに `named` の振る舞いだけを確かめる。
fn spawn_named(name: process.Name(Msg)) -> Pid {
  let pid =
    process.spawn_unlinked(fn() {
      let self = process.named_subject(name)
      let assert Ok(Nil) = process.register(process.self(), name)
      case process.receive(self, 5000) {
        Ok(Answer(reply)) -> {
          process.send(reply, "pong")
          process.sleep(2000)
        }
        Ok(Ignore(_reply)) -> process.sleep(2000)
        Ok(AnswerLate(reply)) -> {
          process.sleep(late_reply_ms)
          process.send(reply, "late-secret")
          process.sleep(2000)
        }
        Ok(Exit(_reply)) | Error(Nil) -> Nil
      }
    })
  await_registration(name, 1000)
  pid
}

/// 名前が登録されるまで待つ。
fn await_registration(name: process.Name(Msg), timeout_ms: Int) -> Nil {
  case process.named(name), timeout_ms <= 0 {
    Ok(_pid), _ -> Nil
    _, True -> Nil
    _, False -> {
      process.sleep(10)
      await_registration(name, timeout_ms - 10)
    }
  }
}

/// 呼び出し側を別のプロセスにして `call` を実行し、その結果と、`settle_ms` 待った
/// 後の呼び出し側のメールボックスに残ったメッセージの数を返す。テストプロセスの
/// メールボックスは他の受信に使うので、残りの検査には使わない。
fn call_in_a_fresh_process(
  call: fn() -> Option(String),
  after_call: fn() -> Nil,
  settle_ms: Int,
) -> #(Option(String), Int) {
  let results = process.new_subject()
  process.spawn(fn() {
    let answer = call()
    after_call()
    process.sleep(settle_ms)
    process.send(results, #(answer, message_queue_len()))
  })
  let assert Ok(outcome) = process.receive(results, settle_ms + 5000)
  outcome
}

/// 自プロセスの未処理メッセージ数。
@external(erlang, "nostr_no_su_ffi", "message_queue_len")
fn message_queue_len() -> Int

/// 単調増加する時計の現在値。
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

/// 応答する宛先には、その応答がそのまま返る。
///
/// 返信先は alias を owner にした subject なので、このテストは「`process.send` が
/// owner へ `erlang:send/2` で送る」ことへの依存も検出する。gleam_erlang が owner を
/// pid として検査するように変われば、ここで落ちる。
pub fn call_returns_the_reply_test() {
  let name = process.new_name("test_named")
  spawn_named(name)
  assert named.call(name, 1000, Answer) == Some("pong")
}

/// 名前を保持するプロセスが無ければ、送らずに None を返す。
pub fn call_of_an_unregistered_name_is_none_test() {
  let name = process.new_name("test_named")
  assert named.call(name, 100, Answer) == None
}

/// 登録はされているが応答しない宛先には、呼び出し側を巻き込まずタイムアウト
/// して None を返す。`process.call` と違い panic しない。
pub fn call_times_out_without_a_reply_test() {
  let name = process.new_name("test_named")
  spawn_named(name)
  assert named.call(name, 100, Ignore) == None
}

/// タイムアウトの後に届いた応答は、呼び出し側のメールボックスに残らない。残ると
/// 呼び出し側のアクターが未知のメッセージとして応答の全文をログに出す。
pub fn a_late_reply_does_not_reach_the_caller_test() {
  let name = process.new_name("test_named")
  spawn_named(name)
  let outcome =
    call_in_a_fresh_process(
      fn() { named.call(name, 100, AnswerLate) },
      fn() { Nil },
      late_reply_ms * 2,
    )
  assert outcome == #(None, 0)
}

/// 宛先が応答せずに終了したら、タイムアウトを待たずに None を返す。
pub fn call_returns_early_when_the_target_exits_test() {
  let name = process.new_name("test_named")
  spawn_named(name)
  let started = monotonic_time(atom.create("millisecond"))
  assert named.call(name, 3000, Exit) == None
  assert monotonic_time(atom.create("millisecond")) - started < 500
}

/// 応答を受け取った後に宛先が終了しても、監視の `DOWN` は呼び出し側に残らない。
pub fn no_down_message_remains_after_a_reply_test() {
  let name = process.new_name("test_named")
  let target = spawn_named(name)
  let outcome =
    call_in_a_fresh_process(
      fn() { named.call(name, 1000, Answer) },
      fn() { process.kill(target) },
      200,
    )
  assert outcome == #(Some("pong"), 0)
}

/// 名前を保持するプロセスが無ければ、送信は何もせずに捨てる。
pub fn send_to_an_unregistered_name_is_dropped_test() {
  let name = process.new_name("test_named")
  assert named.send(name, Answer(process.new_subject())) == Nil
}
