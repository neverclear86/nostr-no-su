//// 名前で登録されたアクターへの送信。

import gleam/erlang/process.{type Name}

/// 名前付きアクターへ送信する。名前を保持するプロセスがなければメッセージを
/// 捨てる。その状況で名前付き subject を使うと送信側が panic するため、宛先の
/// 再起動中に送信したリレー接続（`on_connect` 内。サブツリーの再起動を 1 回
/// 消費する）や stratus プロセス（イベントハンドラー内。接続がソケットを失う）
/// が巻き添えで落ちてしまう。
pub fn send(name: Name(msg), message: msg) -> Nil {
  case process.named(name) {
    Ok(_pid) -> process.send(process.named_subject(name), message)
    Error(Nil) -> Nil
  }
}
