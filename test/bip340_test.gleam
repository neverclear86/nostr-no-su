import nostr_no_su/crypto/bip340
import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex

/// テストベクターの 16 進文字列をバイト列にする。ベクターは正しい前提なので、
/// デコードできないのはテスト自体の誤りとして扱う。
fn bytes(text: String) -> BitArray {
  let assert Ok(decoded) = hex.decode(text)
  decoded
}

pub fn xonly_pubkey_vector0_test() {
  let assert Ok(pk) =
    secp256k1.xonly_pubkey(bytes(
      "0000000000000000000000000000000000000000000000000000000000000003",
    ))
  assert hex.encode(pk)
    == "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
}

pub fn xonly_pubkey_vector1_test() {
  let assert Ok(pk) =
    secp256k1.xonly_pubkey(bytes(
      "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef",
    ))
  assert hex.encode(pk)
    == "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659"
}

pub fn xonly_pubkey_rejects_zero_test() {
  let assert Error(_) =
    secp256k1.xonly_pubkey(bytes(
      "0000000000000000000000000000000000000000000000000000000000000000",
    ))
}

pub fn xonly_pubkey_rejects_order_test() {
  // n そのものは範囲外（有効なスカラーは 1..n-1）。
  let assert Error(_) =
    secp256k1.xonly_pubkey(bytes(
      "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",
    ))
}

pub fn sign_vector0_test() {
  let assert Ok(sig) =
    bip340.sign_with_aux(
      bytes("0000000000000000000000000000000000000000000000000000000000000003"),
      bytes("0000000000000000000000000000000000000000000000000000000000000000"),
      bytes("0000000000000000000000000000000000000000000000000000000000000000"),
    )
  assert hex.encode(sig)
    == "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0"
}

pub fn sign_vector1_test() {
  let assert Ok(sig) =
    bip340.sign_with_aux(
      bytes("b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef"),
      bytes("243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89"),
      bytes("0000000000000000000000000000000000000000000000000000000000000001"),
    )
  assert hex.encode(sig)
    == "6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a"
}

pub fn sign_vector2_test() {
  let assert Ok(sig) =
    bip340.sign_with_aux(
      bytes("c90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74020bbea63b14e5c9"),
      bytes("7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c"),
      bytes("c87aa53824b4d7ae2eb035a2b5bbbccc080e76cdc6d1692c4b0b62d798e6d906"),
    )
  assert hex.encode(sig)
    == "5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1bab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7"
}

fn verify_vector(pk: String, msg: String, sig: String) -> Bool {
  bip340.verify(bytes(sig), bytes(msg), bytes(pk))
}

pub fn verify_vector0_test() {
  assert verify_vector(
    "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
    "0000000000000000000000000000000000000000000000000000000000000000",
    "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca821525f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0",
  )
}

pub fn verify_vector1_test() {
  assert verify_vector(
    "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659",
    "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89",
    "6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de33418906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a",
  )
}

pub fn verify_vector2_test() {
  assert verify_vector(
    "dd308afec5777e13121fa72b9cc1b7cc0139715309b086c960e18fd969774eb8",
    "7e2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75c",
    "5831aaeed7b44bb74e5eab94ba9d4294c49bcf2a60728d8b4c200f50dd313c1bab745879a5ad954a72c45a91c3a51d3c7adea98d82f8481e0e1e03674a6f3fb7",
  )
}

pub fn verify_vector5_offcurve_pubkey_test() {
  assert !verify_vector(
    "eefdea4cdb677750a420fee807eacf21eb9898ae79b9768766e4faa04a2d4a34",
    "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89",
    "6cff5c3ba86c69ea4b7376f31a9bcb4f74c1976089b2d9963da2e5543e17776969e89b4c5564d00349106b8497785dd7d1d713a8ae82b32fa79d5f7fc407d39b",
  )
}

pub fn verify_vector6_odd_r_test() {
  assert !verify_vector(
    "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659",
    "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89",
    "fff97bd5755eeea420453a14355235d382f6472f8568a18b2f057a14602975563cc27944640ac607cd107ae10923d9ef7a73c643e166be5ebeafa34b1ac553e2",
  )
}

pub fn sign_random_roundtrip_test() {
  let privkey =
    bytes("0000000000000000000000000000000000000000000000000000000000000042")
  let assert Ok(pk) = secp256k1.xonly_pubkey(privkey)
  let message =
    bytes("2d58d8b3bcdf1abadec7829054f90dda9805aab56c77333024b9d0a508b75cff")
  let assert Ok(sig) = bip340.sign(privkey, message)
  assert bip340.verify(sig, message, pk)
}
