//// secp256k1 の点演算と整数表現のテスト。
////
//// アフィン座標の演算（`point_add` / `point_double` / `point_mul`）は、群の恒等式と、
//// OpenSSL で計算する `mul_g` との一致で確かめる。

import nostr_no_su/crypto/secp256k1.{Infinity, Point}
import qcheck

/// `point_mul` を含む性質の件数。1 件に数 ms かかるため、qcheck の既定の 1000 件から
/// 減らす。
const point_mul_test_count = 100

/// ベースポイント G。
fn base_point() -> secp256k1.Point {
  mul_g_point(1)
}

/// OpenSSL で計算した `scalar*G` を、アフィン座標の演算に渡せる `Point` にする。
fn mul_g_point(scalar: Int) -> secp256k1.Point {
  let assert Ok(#(x, y)) = secp256k1.mul_g(scalar)
  Point(x, y)
}

/// 1 以上 n 未満のスカラーを生成する。
fn scalar() -> qcheck.Generator(Int) {
  use bytes <- qcheck.map(qcheck.fixed_size_byte_aligned_bit_array(32))
  secp256k1.int_from_bytes(bytes) % { secp256k1.n - 1 } + 1
}

/// `point_mul` を含む性質を、件数を `point_mul_test_count` にして回す。
fn run_with_point_mul(
  generator: qcheck.Generator(a),
  property: fn(a) -> Nil,
) -> Nil {
  qcheck.default_config()
  |> qcheck.with_test_count(point_mul_test_count)
  |> qcheck.run(generator, property)
}

/// 32 バイトの整数表現は、整数として読んで書き戻すと元のバイト列に戻る。
pub fn int_bytes32_round_trip_property_test() {
  use bytes <- qcheck.given(qcheck.fixed_size_byte_aligned_bit_array(32))
  assert secp256k1.int_to_bytes32(secp256k1.int_from_bytes(bytes)) == bytes
}

/// 小さな整数も、上位を 0 で埋めた 32 バイトにする。
pub fn int_to_bytes32_pads_with_zeros_test() {
  assert secp256k1.int_to_bytes32(1) == <<0:size(248), 1>>
}

/// 無限遠点は加算の単位元で、2 倍算、反転、スカラー倍算の結果も無限遠点になる。
pub fn infinity_is_identity_test() {
  let g = base_point()
  assert secp256k1.point_add(Infinity, g) == g
  assert secp256k1.point_add(g, Infinity) == g
  assert secp256k1.point_double(Infinity) == Infinity
  assert secp256k1.point_negate(Infinity) == Infinity
  assert secp256k1.point_mul(Infinity, 5) == Infinity
  assert secp256k1.point_mul(g, 0) == Infinity
}

/// G に n - 1 を掛けると G の反転になり、n を掛けると無限遠点になる。
pub fn point_mul_by_order_test() {
  let g = base_point()
  assert secp256k1.point_mul(g, secp256k1.n - 1) == secp256k1.point_negate(g)
  assert secp256k1.point_mul(g, secp256k1.n) == Infinity
}

/// 任意のスカラー k、l と P = kG、Q = lG で、アフィン座標の加算と 2 倍算が
/// OpenSSL の `mul_g` と一致する。P + Q == (k + l)G、2P == P + P == (2k)G、
/// P + (-P) == 無限遠点が成り立つ。
pub fn point_add_matches_mul_g_property_test() {
  use #(k, l) <- qcheck.given(qcheck.tuple2(scalar(), scalar()))
  let p = mul_g_point(k)
  let q = mul_g_point(l)
  // k + l が n の倍数になる（和が無限遠点になる）確率は無視できる。
  let sum = mul_g_point({ k + l } % secp256k1.n)
  let double = mul_g_point({ 2 * k } % secp256k1.n)
  assert secp256k1.point_add(p, q) == sum
  assert secp256k1.point_double(p) == double
  assert secp256k1.point_add(p, p) == double
  assert secp256k1.point_add(p, secp256k1.point_negate(p)) == Infinity
}

/// 任意のスカラー k で、アフィン座標の `point_mul(G, k)` が OpenSSL の `mul_g(k)`
/// と一致し、その点 P に n を掛けると無限遠点になる。
pub fn point_mul_property_test() {
  let g = base_point()
  use k <- run_with_point_mul(scalar())
  let p = mul_g_point(k)
  assert secp256k1.point_mul(g, k) == p
  assert secp256k1.point_mul(p, secp256k1.n) == Infinity
}

/// lift_x は x 座標から y が偶数の点を復元する。y が奇数の点の x からは、その点の
/// 反転が返る。
pub fn lift_x_property_test() {
  use k <- qcheck.given(scalar())
  let assert Ok(#(x, y)) = secp256k1.mul_g(k)
  let p = Point(x, y)
  let expected = case y % 2 == 0 {
    True -> p
    False -> secp256k1.point_negate(p)
  }
  assert secp256k1.lift_x(secp256k1.int_to_bytes32(x)) == Ok(expected)
}

/// x が 0 のとき、p 以上のとき、x^3 + 7 が平方剰余でない（曲線上に点が無い）ときは
/// 拒否する。
pub fn lift_x_rejects_invalid_x_test() {
  assert secp256k1.lift_x(secp256k1.int_to_bytes32(0))
    == Error(secp256k1.InvalidPublicKey)
  assert secp256k1.lift_x(secp256k1.int_to_bytes32(secp256k1.p))
    == Error(secp256k1.InvalidPublicKey)
  // 5^3 + 7 は法 p で平方剰余でない。
  assert secp256k1.lift_x(secp256k1.int_to_bytes32(5))
    == Error(secp256k1.InvalidPublicKey)
}

/// 32 バイトでない入力は、整数としては有効な x でも拒否する。
pub fn lift_x_rejects_input_that_is_not_32_bytes_test() {
  let assert Ok(#(x, _y)) = secp256k1.mul_g(1)
  let too_long = <<0:size(8), secp256k1.int_to_bytes32(x):bits>>
  assert secp256k1.lift_x(too_long) == Error(secp256k1.InvalidPublicKey)
}
