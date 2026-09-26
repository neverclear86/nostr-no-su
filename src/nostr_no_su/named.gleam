//// 名前で登録されたアクターへの送信と問い合わせ。

import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/option.{type Option, None, Some}

/// 名前付きアクターへ送信する。名前を保持するプロセスがなければメッセージを
/// 捨てる。その状況での名前付き subject への送信は送信側を panic させるため、
/// 名前を引いて保持するプロセスがあるときだけ送る。
///
/// 名前の確認から送信までの間に宛先が終了する窓は残る。これを閉じるには
/// `erlang:send/2` を FFI で呼んで `badarg` を握り潰すしかなく、gleam_erlang が
/// 名前付き subject に使う封筒の形（`#(name, message)`）へ依存することになる。
/// 窓に当たって失われるのはその瞬間のメッセージ 1 件だけなので、内部表現への
/// 依存を増やさないこの実装を選んでいる。
pub fn send(name: Name(msg), message: msg) -> Nil {
  let _ = try_send(name, message)
  Nil
}

/// `send` と同じく送信し、名前を保持するプロセスが無くて捨てたときは `Error(Nil)`
/// を返す。捨てた件数を数える呼び出し側のため。名前の確認から送信までの窓は
/// `send` と同じで、そこで宛先が消えると送信側が panic するか、消えた pid へ
/// 黙って送られて `Ok(Nil)` になる。どちらの 1 件も数えない（`send` の doc を
/// 参照）。
pub fn try_send(name: Name(msg), message: msg) -> Result(Nil, Nil) {
  case process.named(name) {
    Ok(_pid) -> Ok(process.send(process.named_subject(name), message))
    Error(Nil) -> Error(Nil)
  }
}

/// 名前付きアクターへ問い合わせて応答を待つ。名前を保持するプロセスがない、
/// 宛先が応答する前に終了した（タイムアウトを待たずに返る）、`timeout_ms` 以内に
/// 応答が来なかった、のいずれでも `None` を返す。呼び出し側を巻き込まないため
/// `process.call` は使わない。あちらはどの失敗も panic にする。
///
/// 返信先は OTP の `gen:do_call` と同じく、宛先を監視する monitor の alias で
/// ある。タイムアウトの後に届いた応答はランタイムが捨てるので、呼び出し側の
/// メールボックスにも警告ログにも出ず、応答が秘密（接続 secret など）を含んでも
/// 遅延応答から漏れることはない。
///
/// `request` で宛先へ渡す返信用の subject は `process.send` にだけ使う。owner は
/// pid ではなく alias の参照なので、`process.subject_owner` や `process.receive`
/// に渡してはならない。
pub fn call(
  name: Name(msg),
  timeout_ms: Int,
  request: fn(Subject(reply)) -> msg,
) -> Option(reply) {
  case process.named(name) {
    Error(Nil) -> None
    Ok(pid) -> {
      let #(monitor, reply) = reply_alias(pid)
      // 名前の確認から送信までの間に宛先が終了することがあるため、panic しない
      // `send` を使う。その場合は監視が `DOWN` を届けるので `None` になる。
      send(name, request(reply))
      process.new_selector()
      |> process.select_map(reply, Some)
      |> process.select_specific_monitor(monitor, fn(_down) { None })
      |> process.selector_receive(timeout_ms)
      |> finish_call(monitor, reply)
    }
  }
}

/// 受信の結果から応答を取り出し、監視と alias を後始末する。
fn finish_call(
  received: Result(Option(reply), Nil),
  monitor: Monitor,
  reply: Subject(reply),
) -> Option(reply) {
  case received {
    Ok(Some(answer)) -> {
      // 応答の受信で監視は外れているが、宛先が応答の直後に終了したときの
      // `DOWN` がすでに届きうるので、flush 付きで捨てる。
      process.demonitor_process(monitor)
      Some(answer)
    }
    // `DOWN` を受けた。監視は発火して外れ、alias も無効になっている。理由は
    // 引数や状態の断片を含みうるので検査せず、文字列にする経路も作らない。
    Ok(None) -> None
    Error(Nil) -> {
      // 監視を外して alias を無効にする。タイムアウトから無効にするまでの間に
      // 届いた応答はメールボックスに残るので、1 度だけ取り出す。
      process.demonitor_process(monitor)
      process.new_selector()
      |> process.select(reply)
      |> process.selector_receive(0)
      |> option.from_result
    }
  }
}

// `process.send` が owner へ `erlang:send/2` で送ることに依存する
// （`erlang:send/2` は alias を宛先に受け付ける）。gleam_erlang が owner を pid
// として検査するように変わると、応答は届かなくなる。
/// 宛先を監視し、応答だけを受け付ける alias と、それを宛先にした subject を作る。
@external(erlang, "nostr_no_su_ffi", "reply_alias")
fn reply_alias(pid: Pid) -> #(Monitor, Subject(reply))
