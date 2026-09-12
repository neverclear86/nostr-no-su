//// BIP-340 の Schnorr 署名のテスト。
////
//// 公式のテストベクターは `test/vectors/bip340-test-vectors.csv` に置き、全行を回す。
//// 取得元は bitcoin/bips の commit 200f9b26fe0a2f235a2af8b30c4be9f12f6bc9cb の
//// `bip-0340/test-vectors.csv`（このファイルを最後に変えた commit）である。
//// https://raw.githubusercontent.com/bitcoin/bips/200f9b26fe0a2f235a2af8b30c4be9f12f6bc9cb/bip-0340/test-vectors.csv

import gleam/list
import gleam/string
import nostr_no_su/crypto/bip340
import nostr_no_su/crypto/secp256k1
import support/vector.{bytes}

/// 取得元のファイルの SHA-256。
const vectors_sha256 = "34c9d1d9c3a88d524bc80778540dc43f8306ec249a7485293063c376db851c2d"

/// 公式ベクターの 1 行。検証だけの行では、秘密鍵と補助乱数が空文字列になる。
type Vector {
  Vector(
    index: String,
    secret_key: String,
    public_key: String,
    aux_rand: String,
    message: String,
    signature: String,
    valid: Bool,
  )
}

/// 公式ベクターの全行を読む。ファイルは CRLF の CSV で、先頭行は見出し。
fn vectors() -> List(Vector) {
  let assert [_header, ..rows] =
    vector.read("bip340-test-vectors.csv", vectors_sha256)
    |> string.split("\r\n")
    |> list.filter(fn(line) { line != "" })
  list.map(rows, parse_row)
}

/// CSV の 1 行を読む。どの値もカンマを含まないので、カンマで 8 列に分ける。
fn parse_row(row: String) -> Vector {
  let assert [
    index,
    secret_key,
    public_key,
    aux_rand,
    message,
    signature,
    result,
    _comment,
  ] = string.split(row, ",")
  Vector(
    index:,
    secret_key:,
    public_key:,
    aux_rand:,
    message:,
    signature:,
    valid: result == "TRUE",
  )
}

/// 署名を再現できる行（秘密鍵を持つ行）かどうか。
fn signable(vector: Vector) -> Bool {
  vector.secret_key != ""
}

/// 公式ベクターの 19 行を読み、そのうち 8 行が秘密鍵を持つ。
pub fn vectors_count_test() {
  let vectors = vectors()
  assert list.length(vectors) == 19
  assert list.count(vectors, signable) == 8
}

/// 全行で、検証の結果がベクターの期待（TRUE / FALSE）と一致する。
pub fn verify_vectors_test() {
  use v <- list.each(vectors())
  let verified =
    bip340.verify(bytes(v.signature), bytes(v.message), bytes(v.public_key))
  assert #(v.index, verified) == #(v.index, v.valid)
}

/// 秘密鍵を持つ行で、同じ x-only 公開鍵を導き、同じ補助乱数で同じ署名を再現する。
pub fn sign_vectors_test() {
  use v <- list.each(list.filter(vectors(), signable))
  let secret_key = bytes(v.secret_key)
  assert #(v.index, secp256k1.xonly_pubkey(secret_key))
    == #(v.index, Ok(bytes(v.public_key)))
  assert #(
      v.index,
      bip340.sign_with_aux(secret_key, bytes(v.message), bytes(v.aux_rand)),
    )
    == #(v.index, Ok(bytes(v.signature)))
}

/// 0 は有効なスカラーではないため、公開鍵を導けない。
pub fn xonly_pubkey_rejects_zero_test() {
  let assert Error(_) =
    secp256k1.xonly_pubkey(bytes(
      "0000000000000000000000000000000000000000000000000000000000000000",
    ))
}

/// 位数 n も範囲外なので、公開鍵を導けない。
pub fn xonly_pubkey_rejects_order_test() {
  // n そのものは範囲外（有効なスカラーは 1..n-1）。
  let assert Error(_) =
    secp256k1.xonly_pubkey(bytes(
      "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
    ))
}

/// 乱数の補助値で署名しても、自分で検証できる署名になる。
pub fn sign_random_roundtrip_test() {
  let privkey =
    bytes("0000000000000000000000000000000000000000000000000000000000000042")
  let assert Ok(pk) = secp256k1.xonly_pubkey(privkey)
  let message =
    bytes("2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75cff")
  let assert Ok(sig) = bip340.sign(privkey, message)
  assert bip340.verify(sig, message, pk)
}
