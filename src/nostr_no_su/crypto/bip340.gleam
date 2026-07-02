//// BIP-340 Schnorr signatures over secp256k1.
////
//// Signing performs no arbitrary-point arithmetic: both `d*G` and the nonce
//// point `k*G` are computed natively (see `secp256k1.mul_g`). Verification is
//// the only path that needs `secp256k1`'s affine point math, for `s*G - e*P`.

import gleam/crypto
import gleam/int
import nostr_no_su/crypto/secp256k1.{Point}

pub type SignError {
  InvalidSecretKey
  SigningFailed
}

/// BIP-340 tagged hash: sha256(sha256(tag) || sha256(tag) || data).
pub fn tagged_hash(tag: String, data: BitArray) -> BitArray {
  let tag_hash = crypto.hash(crypto.Sha256, <<tag:utf8>>)
  crypto.hash(crypto.Sha256, <<tag_hash:bits, tag_hash:bits, data:bits>>)
}

/// Sign a 32-byte message with fresh auxiliary randomness.
pub fn sign(
  privkey: BitArray,
  message: BitArray,
) -> Result(BitArray, SignError) {
  sign_with_aux(privkey, message, crypto.strong_random_bytes(32))
}

/// Deterministic signing seam: `aux` is the 32-byte auxiliary randomness. The
/// official BIP-340 test vectors fix `aux`, so tests call this directly.
pub fn sign_with_aux(
  privkey: BitArray,
  message: BitArray,
  aux: BitArray,
) -> Result(BitArray, SignError) {
  let d0 = secp256k1.int_from_bytes(privkey)
  case d0 >= 1 && d0 < secp256k1.n {
    False -> Error(InvalidSecretKey)
    True ->
      case secp256k1.pubkey_point(privkey) {
        Error(_) -> Error(SigningFailed)
        Ok(secp256k1.Infinity) -> Error(SigningFailed)
        Ok(Point(px, py)) -> {
          let px_bytes = secp256k1.int_to_bytes32(px)
          // BIP-340 uses the even-y variant of the key, negating d if needed.
          let d = case py % 2 == 0 {
            True -> d0
            False -> secp256k1.n - d0
          }
          let aux_hash = tagged_hash("BIP0340/aux", aux)
          let t =
            int.bitwise_exclusive_or(d, secp256k1.int_from_bytes(aux_hash))
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
          case k0 == 0 {
            True -> Error(SigningFailed)
            False ->
              case secp256k1.mul_g(k0) {
                Error(_) -> Error(SigningFailed)
                Ok(secp256k1.Infinity) -> Error(SigningFailed)
                Ok(Point(rx, ry)) -> {
                  let k = case ry % 2 == 0 {
                    True -> k0
                    False -> secp256k1.n - k0
                  }
                  let rx_bytes = secp256k1.int_to_bytes32(rx)
                  let e =
                    secp256k1.int_from_bytes(
                      tagged_hash("BIP0340/challenge", <<
                        rx_bytes:bits,
                        px_bytes:bits,
                        message:bits,
                      >>),
                    )
                    % secp256k1.n
                  let s = { k + e * d } % secp256k1.n
                  let sig = <<rx_bytes:bits, secp256k1.int_to_bytes32(s):bits>>
                  // BIP-340 recommends verifying before returning.
                  case verify(sig, message, px_bytes) {
                    True -> Ok(sig)
                    False -> Error(SigningFailed)
                  }
                }
              }
          }
        }
      }
  }
}

/// Verify a 64-byte BIP-340 signature against a 32-byte message and x-only key.
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
              let e =
                secp256k1.int_from_bytes(
                  tagged_hash("BIP0340/challenge", <<
                    rx_bytes:bits,
                    pubkey:bits,
                    message:bits,
                  >>),
                )
                % secp256k1.n
              // R = s*G - e*P
              let sg = case s {
                0 -> secp256k1.Infinity
                _ ->
                  case secp256k1.mul_g(s) {
                    Ok(point) -> point
                    Error(_) -> secp256k1.Infinity
                  }
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
