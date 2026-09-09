//// 名前で登録されたアクターへの送信。

import gleam/erlang/process.{type Name}

/// 名前付きアクターへ送信する。名前を保持するプロセスがなければメッセージを
/// 捨てる。その状況で名前付き subject を使うと panic するため、送信側（リレー
/// 接続やプラグインを動かすディスパッチャー）が、再起動中の宛先を道連れにして
/// 落ちてしまう。
pub fn send(name: Name(msg), message: msg) -> Nil {
  case process.named(name) {
    Ok(_pid) -> process.send(process.named_subject(name), message)
    Error(Nil) -> Nil
  }
}
