//// ログ 1 行の組み立てと、OTP logger への出力。
////
//// 出力される行は `<時刻 UTC> <水準> [接頭辞] 本文` の形になる。水準は
//// `Notice`（通常）、`Warning`（失敗したが動き続ける）、`Error`（続けられずに止まる。
//// 起動の中止、`cannot continue`、プラグインの停止）の 3 つで、呼び出し側が渡す。
//// OTP のクラッシュレポートも `Error` の行として同じ形で出る。
////
//// 接頭辞は「どのモジュールが出した行か」を示すもので、そのモジュールが定数
//// として持つ。起動時の報告のように別のモジュールが代わりに出力する行も、
//// 接頭辞の定義は 1 か所で済む。
////
//// リレーやイベントなど外部由来の文字列は、改行や制御文字を含みうるので、
//// ログ行に入れる前に必ず `sanitize`（または `sanitize_external`）を通す。

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/string

/// リレーやイベント由来の値をログに入れるときの既定の上限（コードポイントの数）。
/// id と pubkey（64 文字）は切られない。
pub const max_external_chars = 200

/// OTP logger の水準。本体は primary level の既定（notice）以上だけを使う。
/// コンストラクターの名前は OTP の水準の atom（`notice` / `warning` / `error`）と
/// 一致させ、FFI で変換しない。
pub type Level {
  Notice
  Warning
  Error
}

/// 接頭辞を付けたログ 1 行。
pub fn line(prefix: String, message: String) -> String {
  "[" <> prefix <> "] " <> message
}

/// 接頭辞を付けたログ 1 行を、水準を添えて OTP logger へ出力する。
pub fn write(level: Level, prefix: String, message: String) -> Nil {
  write_line(level, line(prefix, message))
}

/// 組み立て済みの 1 行（起動時の notes など）を、水準を添えて OTP logger へ
/// 出力する。
pub fn write_line(level: Level, line: String) -> Nil {
  let _ = logger_log(level, line)
  Nil
}

/// 起動の最初に 1 回呼ぶ。既定のハンドラーの formatter を `<時刻 UTC> <水準>
/// <本文>` の 1 行形式にし、流量制限と欠落を切って `io.println` と同じく行を
/// 落とさないようにする。`gleam test` は呼ばないので、テストの出力は OTP
/// 既定の形のまま出る。
@external(erlang, "nostr_no_su_ffi", "configure_logger")
pub fn configure() -> Nil

/// 既定のハンドラーに溜まった行を書き終えるまで待つ。既定のハンドラーは
/// 少ない件数を非同期に書くため、`halt` の直前に呼ばないと直前の行が消える
/// ことがある。
@external(erlang, "nostr_no_su_ffi", "flush_logger")
pub fn flush() -> Nil

/// OTP logger へ 1 行を渡す。binary の本文は書式として解釈されない。戻り値は使わない。
@external(erlang, "logger", "log")
fn logger_log(level: Level, message: String) -> Dynamic

/// リレー 1 本に関する行の接頭辞。接続そのもの（`relay_connection`）と、その上を
/// 流れるメッセージ（`relay_client`）が同じ接頭辞を使うため、ここに置く。
pub fn relay_prefix(relay: String) -> String {
  "relay " <> relay
}

/// プラグインに関するログ行の接頭辞。ランナーも、子プロセスの起動失敗の報告も
/// これを使う。プラグインごとに分かれるので関数にする。
pub fn plugin_prefix(name: String) -> String {
  "plugin " <> name
}

/// 外部由来の文字列を 1 行に収める。先頭の `max` コードポイントだけを取り、
/// 改行と端末の制御を含む制御文字を空白 1 文字に置き換え、切った場合は `...`
/// を付ける。書記素ではなくコードポイントで数えるので、戻り値は UTF-8 で
/// `4 * max + 3` バイト以下になる。
pub fn sanitize(text: String, max: Int) -> String {
  let codepoints = string.to_utf_codepoints(text)
  let body =
    codepoints
    |> list.take(max)
    |> list.map(fn(codepoint) {
      case is_control(codepoint) {
        True -> " "
        False -> string.from_utf_codepoints([codepoint])
      }
    })
    |> string.concat
  case list.length(codepoints) > max {
    True -> body <> "..."
    False -> body
  }
}

/// リレーやイベント由来の値を既定の上限 `max_external_chars` で `sanitize` する。
pub fn sanitize_external(text: String) -> String {
  sanitize(text, max_external_chars)
}

/// ログ行を分けたり端末の表示を変えたりしうるコードポイントか。C0
/// （U+0000〜U+001F）、DEL と C1（U+007F〜U+009F）、行区切りと段落区切り
/// （U+2028、U+2029）が対象である。
fn is_control(codepoint: UtfCodepoint) -> Bool {
  let code = string.utf_codepoint_to_int(codepoint)
  code < 0x20
  || { code >= 0x7f && code < 0xa0 }
  || code == 0x2028
  || code == 0x2029
}
