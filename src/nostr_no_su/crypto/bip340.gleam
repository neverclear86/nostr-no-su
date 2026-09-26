//// secp256k1 上の BIP-340 Schnorr 署名。
////
//// 署名では任意点の演算を行わない。`d*G` も nonce 点 `k*G` もネイティブに計算
//// する（`secp256k1.mul_g` を参照）。`secp256k1` のアフィン座標演算が必要なのは、
//// `s*G - e*P` を求める検証経路だけ。

import gleam/crypto
import gleam/int
import gleam/result
import nostr_no_su/crypto/secp256k1.{Point}

/// 署名できなかった理由。
pub type SignError {
  InvalidSecretKey
  SigningFailed
}

/// BIP-340 の tagged hash: sha256(sha256(tag) || sha256(tag) || data)。
pub fn tagged_hash(tag: String, data: BitArray) -> BitArray {
  let tag_hash = crypto.hash(crypto.Sha256, <<tag:utf8>>)
  crypto.hash(crypto.Sha256, <<tag_hash:bits, tag_hash:bits, data:bits>>)
}

/// メッセージを、新たに生成した補助乱数で署名する。BIP-340 はメッセージの長さを
/// 問わない（Nostr が署名するのは 32 バイトのイベント id）。
pub fn sign(
  privkey: BitArray,
  message: BitArray,
) -> Result(BitArray, SignError) {
  sign_with_aux(privkey, message, crypto.strong_random_bytes(32))
}

/// 決定的に署名するための差し込み口。`aux` は 32 バイトの補助乱数。BIP-340 の
/// 公式テストベクターは `aux` を固定するため、テストはこちらを直接呼ぶ。
pub fn sign_with_aux(
  privkey: BitArray,
  message: BitArray,
  aux: BitArray,
) -> Result(BitArray, SignError) {
  let d0 = secp256k1.int_from_bytes(privkey)
  use #(px, py) <- result.try(
    secp256k1.mul_g(d0) |> result.replace_error(InvalidSecretKey),
  )
  let px_bytes = secp256k1.int_to_bytes32(px)
  let d = with_even_y(d0, py)
  let aux_hash = tagged_hash("BIP0340/aux", aux)
  let t = int.bitwise_exclusive_or(d, secp256k1.int_from_bytes(aux_hash))
  let t_bytes = secp256k1.int_to_bytes32(t)
  let k0 =
    secp256k1.int_from_bytes(
      tagged_hash("BIP0340/nonce", <<
        t_bytes:bits,
        px_bytes:bits,
        message:bits,
      >>),
    )
    % secp256k1.n
  // k0 が 0 のときは mul_g が誤りを返す。
  use #(rx, ry) <- result.try(
    secp256k1.mul_g(k0) |> result.replace_error(SigningFailed),
  )
  let k = with_even_y(k0, ry)
  let rx_bytes = secp256k1.int_to_bytes32(rx)
  let e = challenge(rx_bytes, px_bytes, message)
  let s = { k + e * d } % secp256k1.n
  let sig = <<rx_bytes:bits, secp256k1.int_to_bytes32(s):bits>>
  // BIP-340 は返す前に検証することを推奨している。
  case verify(sig, message, px_bytes) {
    True -> Ok(sig)
    False -> Error(SigningFailed)
  }
}

/// BIP-340 は y が偶数となる側の点を使う。点 `scalar*G` の y 座標 `y` が奇数なら
/// スカラーを `n - scalar` に反転する。
fn with_even_y(scalar: Int, y: Int) -> Int {
  case y % 2 == 0 {
    True -> scalar
    False -> secp256k1.n - scalar
  }
}

/// BIP-340 の challenge `e`。R の x 座標、x-only 公開鍵、メッセージの tagged hash を
/// 位数 n で還元した値で、署名と検証で共用する。
fn challenge(rx_bytes: BitArray, px_bytes: BitArray, message: BitArray) -> Int {
  secp256k1.int_from_bytes(
    tagged_hash("BIP0340/challenge", <<
      rx_bytes:bits,
      px_bytes:bits,
      message:bits,
    >>),
  )
  % secp256k1.n
}

/// 64 バイトの BIP-340 署名を、任意の長さのメッセージと x-only 鍵で検証する。
pub fn verify(sig: BitArray, message: BitArray, pubkey: BitArray) -> Bool {
  case sig {
    <<rx_bytes:bytes-size(32), s_bytes:bytes-size(32)>> ->
      case secp256k1.lift_x(pubkey) {
        Error(_) -> False
        Ok(point) -> {
          let rx = secp256k1.int_from_bytes(rx_bytes)
          let s = secp256k1.int_from_bytes(s_bytes)
          case rx >= secp256k1.p || s >= secp256k1.n {
            True -> False
            False -> {
              let e = challenge(rx_bytes, pubkey, message)
              // R = s*G - e*P。s は n 未満と確かめたので、mul_g の誤りは s == 0 のときだけ。
              let sg = case secp256k1.mul_g(s) {
                Ok(#(x, y)) -> Point(x, y)
                Error(_) -> secp256k1.Infinity
              }
              let ep = secp256k1.point_mul(secp256k1.point_negate(point), e)
              case secp256k1.point_add(sg, ep) {
                secp256k1.Infinity -> False
                Point(computed_rx, ry) -> ry % 2 == 0 && computed_rx == rx
              }
            }
          }
        }
      }
    _ -> False
  }
}
