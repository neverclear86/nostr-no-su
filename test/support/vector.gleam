//// 暗号のテストベクターを読むためのヘルパー。

import nostr_no_su/hex

/// テストベクターの 16 進文字列をバイト列にする。ベクターは正しい前提なので、
/// デコードできないのはテスト自体の誤りとして扱う。
pub fn bytes(text: String) -> BitArray {
  let assert Ok(decoded) = hex.decode(text)
  decoded
}
