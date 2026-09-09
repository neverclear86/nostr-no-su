import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import nostr_no_su/named

/// 問い合わせに使うメッセージ。`Answer` は応答する宛先、`Ignore` は応答しない
/// 宛先を模す。
type Msg {
  Answer(reply: Subject(String))
  Ignore(reply: Subject(String))
}

/// 指定した名前でメッセージを 1 件受け取るプロセスを起動し、名前が登録される
/// まで待つ。アクターを起動せずに `named` の振る舞いだけを確かめる。
fn spawn_named(name: process.Name(Msg)) -> Nil {
  process.spawn_unlinked(fn() {
    let self = process.named_subject(name)
    let assert Ok(Nil) = process.register(process.self(), name)
    case process.receive(self, 5000) {
      Ok(Answer(reply)) -> process.send(reply, "pong")
      // 応答しないまま生き続ける。呼び出し側はタイムアウトになる。
      Ok(Ignore(_reply)) -> process.sleep(2000)
      Error(Nil) -> Nil
    }
  })
  await_registration(name, 1000)
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

/// 応答する宛先には、その応答がそのまま返る。
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

/// 名前を保持するプロセスが無ければ、送信は何もせずに捨てる。
pub fn send_to_an_unregistered_name_is_dropped_test() {
  let name = process.new_name("test_named")
  assert named.send(name, Answer(process.new_subject())) == Nil
}
