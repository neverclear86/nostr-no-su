//// 名前で登録されたアクターへの送信と問い合わせ。

import gleam/erlang/process.{type Name, type Subject}
import gleam/option.{type Option, None, Some}

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

/// 名前付きアクターへ問い合わせて応答を待つ。名前を保持するプロセスがなければ
/// `None` を返す。`timeout_ms` は宛先アクターがループ内でブロックしうる最長時間
/// より長く取ること。超えると呼び出し側が panic する。
pub fn call(
  name: Name(msg),
  timeout_ms: Int,
  request: fn(Subject(reply)) -> msg,
) -> Option(reply) {
  case process.named(name) {
    Ok(_pid) ->
      Some(process.call(process.named_subject(name), timeout_ms, request))
    Error(Nil) -> None
  }
}
