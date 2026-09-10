//// ログ 1 行の組み立て。
////
//// 接頭辞は「どのモジュールが出した行か」を示すもので、そのモジュールが定数
//// として持つ。起動時の報告のように別のモジュールが代わりに出力する行も、
//// 接頭辞の定義は 1 か所で済む。

import gleam/io

/// 接頭辞を付けたログ 1 行。
pub fn line(prefix: String, message: String) -> String {
  "[" <> prefix <> "] " <> message
}

/// 接頭辞を付けたログ 1 行を出力する。
pub fn println(prefix: String, message: String) -> Nil {
  io.println(line(prefix, message))
}

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
