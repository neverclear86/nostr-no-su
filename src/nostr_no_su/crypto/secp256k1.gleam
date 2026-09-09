//// BIP-340 / NIP-44 のための最小限の secp256k1 有限体・点演算。
////
//// OpenSSL が OTP の `crypto` モジュール経由で公開しているプリミティブは FFI で
//// 直接使う。`d*G`（公開鍵と nonce 点の導出）は `crypto:generate_key`、x-only の
//// ECDH は `crypto:compute_key`、冪剰余は `crypto:mod_pow`。ここで実装するのは
//// BIP-340 の検証に必要な任意点の演算（`e*P`）だけで、素朴なアフィン座標と
//// フェルマーの小定理によるモジュラ逆元で行う。
////
//// 注意: このアフィン演算の実行時間は入力に依存する。セルフホストのバンカーでは
//// これを許容できる。署名 nonce は毎回新しい補助乱数から BIP-340 のハッシュで
//// 導出され、検証は公開データのみを扱うため。

import gleam/int

/// 有限体の法となる素数。
pub const p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

/// ベースポイント G の位数。
pub const n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

pub type Point {
  Point(x: Int, y: Int)
  Infinity
}

pub type KeyError {
  InvalidPrivateKey
  InvalidPublicKey
}

@external(erlang, "nostr_no_su_ffi", "mod_pow")
fn ffi_mod_pow(base: Int, exp: Int, mod: Int) -> Int

@external(erlang, "nostr_no_su_ffi", "ec_point_from_priv")
fn ffi_ec_point_from_priv(priv: BitArray) -> Result(#(BitArray, BitArray), Nil)

@external(erlang, "nostr_no_su_ffi", "ecdh_x")
fn ffi_ecdh_x(compressed_pub: BitArray, priv: BitArray) -> Result(BitArray, Nil)

@external(erlang, "nostr_no_su_ffi", "int_from_bytes")
pub fn int_from_bytes(bytes: BitArray) -> Int

/// 体の元またはスカラーを 32 バイトのビッグエンディアンで表現する。
pub fn int_to_bytes32(value: Int) -> BitArray {
  <<value:size(256)>>
}

fn mod_p(a: Int) -> Int {
  let r = a % p
  case r < 0 {
    True -> r + p
    False -> r
  }
}

/// フェルマーの小定理によるモジュラ逆元: a^(p-2) mod p。
fn mod_inv(a: Int) -> Int {
  ffi_mod_pow(mod_p(a), p - 2, p)
}

pub fn point_negate(point: Point) -> Point {
  case point {
    Infinity -> Infinity
    Point(x, y) -> Point(x, mod_p(p - y))
  }
}

pub fn point_double(point: Point) -> Point {
  case point {
    Infinity -> Infinity
    Point(_, 0) -> Infinity
    Point(x, y) -> {
      let l = mod_p(3 * x * x * mod_inv(2 * y))
      let x3 = mod_p(l * l - 2 * x)
      let y3 = mod_p(l * { x - x3 } - y)
      Point(x3, y3)
    }
  }
}

pub fn point_add(a: Point, b: Point) -> Point {
  case a, b {
    Infinity, _ -> b
    _, Infinity -> a
    Point(x1, y1), Point(x2, y2) ->
      case x1 == x2 {
        True ->
          case mod_p(y1 + y2) == 0 {
            True -> Infinity
            False -> point_double(a)
          }
        False -> {
          let l = mod_p({ y2 - y1 } * mod_inv(x2 - x1))
          let x3 = mod_p(l * l - x1 - x2)
          let y3 = mod_p(l * { x1 - x3 } - y1)
          Point(x3, y3)
        }
      }
  }
}

/// 素朴な LSB 先行の double-and-add によるスカラー倍算。
pub fn point_mul(point: Point, scalar: Int) -> Point {
  point_mul_loop(point, scalar, Infinity)
}

fn point_mul_loop(point: Point, scalar: Int, acc: Point) -> Point {
  case scalar {
    0 -> acc
    _ -> {
      let acc = case int.bitwise_and(scalar, 1) {
        1 -> point_add(acc, point)
        _ -> acc
      }
      point_mul_loop(
        point_double(point),
        int.bitwise_shift_right(scalar, 1),
        acc,
      )
    }
  }
}

/// BIP-340 の lift_x。与えられた x-only 鍵から y が偶数となる点を復元する。
pub fn lift_x(xonly: BitArray) -> Result(Point, KeyError) {
  let x = int_from_bytes(xonly)
  case x >= p || x == 0 {
    True -> Error(InvalidPublicKey)
    False -> {
      let c = mod_p(x * x * x + 7)
      let y = ffi_mod_pow(c, { p + 1 } / 4, p)
      case mod_p(y * y) == c {
        False -> Error(InvalidPublicKey)
        True ->
          case y % 2 == 0 {
            True -> Ok(Point(x, y))
            False -> Ok(Point(x, p - y))
          }
      }
    }
  }
}

fn valid_scalar(value: Int) -> Bool {
  value >= 1 && value < n
}

/// `d*G` の完全な点（y 座標を含む）をネイティブに計算する。
pub fn pubkey_point(privkey: BitArray) -> Result(Point, KeyError) {
  case valid_scalar(int_from_bytes(privkey)) {
    False -> Error(InvalidPrivateKey)
    True ->
      case ffi_ec_point_from_priv(privkey) {
        Ok(#(x, y)) -> Ok(Point(int_from_bytes(x), int_from_bytes(y)))
        Error(_) -> Error(InvalidPrivateKey)
      }
  }
}

/// 秘密鍵に対応する x-only 公開鍵（32 バイト）。
pub fn xonly_pubkey(privkey: BitArray) -> Result(BitArray, KeyError) {
  case valid_scalar(int_from_bytes(privkey)) {
    False -> Error(InvalidPrivateKey)
    True ->
      case ffi_ec_point_from_priv(privkey) {
        Ok(#(x, _)) -> Ok(x)
        Error(_) -> Error(InvalidPrivateKey)
      }
  }
}

/// `scalar*G` をネイティブに計算する。`scalar` は 1 <= scalar < n を満たす
/// 必要がある。
pub fn mul_g(scalar: Int) -> Result(Point, KeyError) {
  case valid_scalar(scalar) {
    False -> Error(InvalidPrivateKey)
    True ->
      case ffi_ec_point_from_priv(int_to_bytes32(scalar)) {
        Ok(#(x, y)) -> Ok(Point(int_from_bytes(x), int_from_bytes(y)))
        Error(_) -> Error(InvalidPrivateKey)
      }
  }
}

/// `privkey * lift_x(pubkey)` の x 座標。NIP-44 の ECDH 共有秘密にあたる。
/// 先頭の 0x02 は、NIP-44 に従い相手鍵の y が偶数となる側の点を選ぶ指定。
pub fn ecdh_x(
  privkey: BitArray,
  pubkey_xonly: BitArray,
) -> Result(BitArray, KeyError) {
  case valid_scalar(int_from_bytes(privkey)) {
    False -> Error(InvalidPrivateKey)
    True ->
      case ffi_ecdh_x(<<0x02, pubkey_xonly:bits>>, privkey) {
        Ok(x) -> Ok(x)
        Error(_) -> Error(InvalidPublicKey)
      }
  }
}
