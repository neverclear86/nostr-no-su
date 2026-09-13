//// `event_logger` のログ 1 行を OTP logger に出す。
////
//// 本体（`nostr_no_su/log`）は別プロジェクトなので import できず
//// （`event_logger_test.gleam` の `with_test_database_url` の注釈と同じ事情）、
//// 同じ形をここに持つ。行の形（`<時刻 UTC> <水準> <本文>`）は本体が起動時に
//// 設定する formatter が決めるので、ここでは接頭辞を付けて水準を渡すだけである。

import gleam/dynamic.{type Dynamic}

/// OTP logger の水準。本体の `nostr_no_su/log.Level` と同じ理由で、コンストラ
/// クターの名前は OTP の水準の atom と一致させ、このモジュールでは `Result` の
/// パターンを書かない。
pub type Level {
  Notice
  Warning
  Error
}

/// このプラグインが自分で出すログ行の接頭辞。本体が出す行の接頭辞
/// （`[plugin event_logger]`）とは別物である。
const prefix = "[event_logger] "

/// 接頭辞を付けた 1 行を、水準を添えて OTP logger へ出力する。
pub fn write(level: Level, line: String) -> Nil {
  let _ = logger_log(level, prefix <> line)
  Nil
}

/// OTP logger へ 1 行を渡す。binary の本文は書式として解釈されない。戻り値は使わない。
@external(erlang, "logger", "log")
fn logger_log(level: Level, message: String) -> Dynamic
