//// 名前で登録されたアクターへの送信と問い合わせ。

import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option, None}

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
/// 正しい。応答用の subject は呼び出しごとに作るため、タイムアウト後に届いた応答が
/// 他の問い合わせと混ざることはない。遅れて届いた応答は、呼び出し元がアクター
/// ならそのループが「想定外のメッセージ」として警告を出して捨てる。
pub fn call(
  name: Name(msg),
  timeout_ms: Int,
  request: fn(Subject(reply)) -> msg,
) -> Option(reply) {
  case process.named(name) {
    Error(Nil) -> None
    Ok(_pid) -> {
      let reply = process.new_subject()
      // 名前の確認から送信までの間に宛先が終了することがあるため、panic しない
      // `send` を使う。その場合は応答が来ず、タイムアウトで `None` になる。
      send(name, request(reply))
      process.receive(reply, timeout_ms) |> option.from_result
    }
  }
}
