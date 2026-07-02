//// Minimal secp256k1 field and point arithmetic for BIP-340 / NIP-44.
////
//// Primitives that OpenSSL exposes through OTP's `crypto` module are used
//// directly via FFI: `d*G` (public-key and nonce-point derivation) through
//// `crypto:generate_key`, x-only ECDH through `crypto:compute_key`, and
//// modular exponentiation through `crypto:mod_pow`. Only the arbitrary-point
//// arithmetic that BIP-340 verification needs (`e*P`) is implemented here, in
//// plain affine coordinates with Fermat modular inversion.
////
//// Note: this affine arithmetic is variable-time. That is acceptable for a
//// self-hosted bunker — signing nonces are BIP-340 hash-derived with fresh
//// aux randomness, and verification operates on public data.

import gleam/int

/// Field prime.
pub const p = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F

/// Order of the base point G.
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

/// A 32-byte big-endian encoding of a field/scalar value.
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

/// Modular inverse via Fermat's little theorem: a^(p-2) mod p.
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

/// Scalar multiplication by plain LSB-first double-and-add.
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

/// BIP-340 lift_x: recover the even-y point for a given x-only key.
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

/// The full `d*G` point (with y), computed natively.
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

/// The x-only public key (32 bytes) for a private key.
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

/// `scalar*G` computed natively. `scalar` must satisfy 1 <= scalar < n.
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

/// x-coordinate of `privkey * lift_x(pubkey)`, the NIP-44 ECDH shared secret.
/// The 0x02 prefix takes the even-y lift of the peer key, per NIP-44.
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
