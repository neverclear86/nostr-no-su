//// 暗号のテストベクターを読むためのヘルパー。

import gleam/bit_array
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import nostr_no_su/hex

/// ファイルの中身を読む。
@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// テストベクターの 16 進文字列をバイト列にする。ベクターは正しい前提なので、
/// デコードできないのはテスト自体の誤りとして扱う。
pub fn bytes(text: String) -> BitArray {
  let assert Ok(decoded) = hex.decode(text)
  decoded
}

/// `test/vectors/` に置いた公式テストベクターのファイルを、文字列として読む。
/// 取得元と同じバイト列であることを SHA-256 で確かめてから返す。`gleam test` は
/// プロジェクトのルートで実行されるので、パスはルートからの相対で組み立てる。
pub fn read(name: String, sha256: String) -> String {
  let assert Ok(content) = read_file("test/vectors/" <> name)
  assert hex.encode(crypto.hash(crypto.Sha256, content)) == sha256
    as "test vector file differs from the pinned upstream version"
  let assert Ok(text) = bit_array.to_string(content)
  text
}
