//// 名前で登録されたアクターへの送信と問い合わせ。

import gleam/erlang/process.{type Monitor, type Name, type Pid, type Subject}
import gleam/option.{type Option, None, Some}

/// 名前付きアクターへ送信する。名前を保持するプロセスがなければメッセージを
/// 捨てる。その状況で名前付き subject を使うと送信側が panic するため、宛先の
/// 再起動中に送信したリレー接続（`on_connect` 内。サブツリーの再起動を 1 回
/// 消費する）や stratus プロセス（イベントハンドラー内。接続がソケットを失う）
/// が巻き添えで落ちてしまう。
///
/// 名前の確認から送信までの間に宛先が終了する窓は残る。これを閉じるには
/// `erlang:send/2` を FFI で呼んで `badarg` を握り潰すしかなく、gleam_erlang が
/// 名前付き subject に使う封筒の形（`#(name, message)`）へ依存することになる。
/// 窓に当たって失われるのはその瞬間のメッセージ 1 件で、送信元はいずれも再接続
/// または再送で回復するため、内部表現への依存を増やさずこの実装を選んでいる。
pub fn send(name: Name(msg), message: msg) -> Nil {
  case process.named(name) {
    Ok(_pid) -> process.send(process.named_subject(name), message)
    Error(Nil) -> Nil
  }
}

/// 名前付きアクターへ問い合わせて応答を待つ。名前を保持するプロセスがない、
/// 宛先が応答する前に終了した、`timeout_ms` 以内に応答が来なかった、のいずれでも
/// 呼び出し側を巻き込まず `None` を返す。`process.call` を使わないのはこのため
/// で、あちらはどの失敗も panic にする。呼び出し側は部分的に欠けた状態を描画
/// できる。
///
/// `timeout_ms` は宛先アクターがループ内でブロックしうる最長時間より長く取る
/// こと。ただし、応答が無いことを正常な結果として扱える呼び出し（状態表示など）
/// はこの限りでない。長く待つと呼び出し側が止まるため、短く切って諦めるほうが
/// 正しい。
///
/// 返信先は OTP の `gen:do_call` と同じく、宛先を監視する monitor の alias で
/// ある。次の性質と規則がある。
///
/// - タイムアウトの後に届いた応答はランタイムが捨てるので、呼び出し側の
///   メールボックスにも、呼び出し側がアクターならその警告ログにも出ない。応答が
///   秘密（接続 secret など）を含んでも、遅延応答から漏れることはない。
/// - 宛先が応答する前に終了したときは、タイムアウトを待たずに `None` を返す。
/// - `DOWN` の理由は受け取るが検査しない。宛先のクラッシュの理由は引数や状態の
///   断片を含みうるので、それを文字列にする経路を作らない。
/// - 名前を引いてから送るまでの間に宛先が再起動して同じ名前を取ると、要求は新しい
///   プロセスに届く。監視しているのは古い pid なので即座に `None` が返り、新しい
///   プロセスの応答は無効になった alias に届いて捨てられる。応答したのに `None`
///   になるのはこの窓に限られる。
/// - 宛先へ渡す返信用の subject は `process.send` にだけ使う。owner は pid では
///   なく alias の参照なので、`process.subject_owner` や `process.receive` に
///   渡してはならない。
///
/// この実装は「`process.send` が owner へ `erlang:send/2` で送る」ことに依存する
/// （`erlang:send/2` は alias を宛先に受け付ける）。gleam_erlang がここで pid を
/// 検査するように変われば、`named_test` の `call_returns_the_reply_test` が失敗して
/// 検出する。
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
      // `DOWN` がすでに届いていうるので、flush 付きで捨てる。
      process.demonitor_process(monitor)
      Some(answer)
    }
    // `DOWN` を受けた。監視は発火して外れ、alias も無効になっている。
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

/// 宛先を監視し、応答だけを受け付ける alias と、それを宛先にした subject を作る。
@external(erlang, "nostr_no_su_ffi", "reply_alias")
fn reply_alias(pid: Pid) -> #(Monitor, Subject(reply))
