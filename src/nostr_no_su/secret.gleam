//// 秘密の値を関数に閉じ込めて持つ型。

/// 関数に閉じ込めた秘密の値。
///
/// opaque 型も実行時にはただのタプルなので、値を直接持たせると `string.inspect`、
/// `sys:get_state/1`、`let assert` の失敗値、クラッシュレポートのどれにもそのまま出て
/// しまう。関数に閉じ込めれば、これらの表示は関数の中身を含まない。同じ VM のコードは
/// 関数を呼んで値を読めるので、隔離ではない（`docs/design-decisions.md` の「秘密が
/// ログとクラッシュレポートに出る経路」と「復号した秘密鍵は同じ VM から読める」）。
///
/// 関数の比較は捕捉した値を比べるので、`==` は閉じ込めた値どうしの比較になる。
/// 定数時間ではないので、外から提示された値との照合には使わない。
pub opaque type Secret(a) {
  Secret(value: fn() -> a)
}

/// 値を閉じ込める。
pub fn new(value: a) -> Secret(a) {
  Secret(fn() { value })
}

/// 閉じ込めた値を取り出す。
pub fn reveal(secret: Secret(a)) -> a {
  secret.value()
}
