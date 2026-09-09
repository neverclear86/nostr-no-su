import nostr_no_su/crypto/nip44
import nostr_no_su/hex

/// テストベクターの 16 進文字列をバイト列にする。ベクターは正しい前提なので、
/// デコードできないのはテスト自体の誤りとして扱う。
fn bytes(text: String) -> BitArray {
  let assert Ok(decoded) = hex.decode(text)
  decoded
}

pub fn conversation_key_vector1_test() {
  let assert Ok(key) =
    nip44.conversation_key(
      bytes("315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268"),
      bytes("c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133"),
    )
  assert hex.encode(key)
    == "3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1"
}

pub fn conversation_key_vector2_test() {
  let assert Ok(key) =
    nip44.conversation_key(
      bytes("a1e37752c9fdc1273be53f68c5f74be7c8905728e8de75800b94262f9497c86e"),
      bytes("03bb7947065dde12ba991ea045132581d0954f042c84e06d8c00066e23c1a800"),
    )
  assert hex.encode(key)
    == "4d14f36e81b8452128da64fe6f1eae873baae2f444b02c950b90e43553f2178b"
}

pub fn conversation_key_rejects_seckey_over_n_test() {
  let assert Error(_) =
    nip44.conversation_key(
      bytes("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
      bytes("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"),
    )
}

const conv_key_1 = "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d"

pub fn encrypt_vector1_test() {
  let assert Ok(payload) =
    nip44.encrypt_with_nonce(
      "a",
      bytes(conv_key_1),
      bytes("0000000000000000000000000000000000000000000000000000000000000001"),
    )
  assert payload
    == "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"
}

pub fn decrypt_vector1_test() {
  let assert Ok(text) =
    nip44.decrypt(
      "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb",
      bytes(conv_key_1),
    )
  assert text == "a"
}

pub fn encrypt_vector2_test() {
  let assert Ok(payload) =
    nip44.encrypt_with_nonce(
      "🍕🫃",
      bytes(conv_key_1),
      bytes("f00000000000000000000000000000f00000000000000000000000000000000f"),
    )
  assert payload
    == "AvAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAPSKSK6is9ngkX2+cSq85Th16oRTISAOfhStnixqZziKMDvB0QQzgFZdjLTPicCJaV8nDITO+QfaQ61+KbWQIOO2Yj"
}

pub fn decrypt_vector2_test() {
  let assert Ok(text) =
    nip44.decrypt(
      "AvAAAAAAAAAAAAAAAAAAAPAAAAAAAAAAAAAAAAAAAAAPSKSK6is9ngkX2+cSq85Th16oRTISAOfhStnixqZziKMDvB0QQzgFZdjLTPicCJaV8nDITO+QfaQ61+KbWQIOO2Yj",
      bytes(conv_key_1),
    )
  assert text == "🍕🫃"
}

const conv_key_3 = "3e2b52a63be47d34fe0a80e34e73d436d6963bc8f39827f327057a9986c20a45"

const plaintext_3 = "表ポあA鷗ŒéＢ逍Üßªąñ丂㐀𠀀"

const payload_3 = "ArY1I2xC2yDwIbuNHN/1ynXdGgzHLqdCrXUPMwELJPc7s7JqlCMJBAIIjfkpHReBPXeoMCyuClwgbT419jUWU1PwaNl4FEQYKCDKVJz+97Mp3K+Q2YGa77B6gpxB/lr1QgoqpDf7wDVrDmOqGoiPjWDqy8KzLueKDcm9BVP8xeTJIxs="

pub fn encrypt_vector3_test() {
  let assert Ok(payload) =
    nip44.encrypt_with_nonce(
      plaintext_3,
      bytes(conv_key_3),
      bytes("b635236c42db20f021bb8d1cdff5ca75dd1a0cc72ea742ad750f33010b24f73b"),
    )
  assert payload == payload_3
}

pub fn decrypt_vector3_test() {
  let assert Ok(text) = nip44.decrypt(payload_3, bytes(conv_key_3))
  assert text == plaintext_3
}

pub fn calc_padded_len_table_test() {
  let cases = [
    #(1, 32),
    #(32, 32),
    #(33, 64),
    #(37, 64),
    #(45, 64),
    #(49, 64),
    #(64, 64),
    #(65, 96),
    #(100, 128),
    #(111, 128),
    #(200, 224),
    #(250, 256),
    #(320, 320),
    #(383, 384),
    #(384, 384),
    #(400, 448),
    #(500, 512),
    #(512, 512),
    #(515, 640),
    #(700, 768),
    #(800, 896),
    #(900, 1024),
    #(1020, 1024),
    #(65_536, 65_536),
  ]
  assert list_all_padded(cases)
}

fn list_all_padded(cases: List(#(Int, Int))) -> Bool {
  case cases {
    [] -> True
    [#(input, expected), ..rest] ->
      nip44.calc_padded_len(input) == expected && list_all_padded(rest)
  }
}

pub fn decrypt_rejects_hash_prefix_test() {
  let assert Error(nip44.UnsupportedVersion) =
    nip44.decrypt(
      "#Atqupco0WyaOW2IGDKcshwxI9xO8HgD/P8Ddt46CbxDbrhdG8VmJdU0MIDf06CUvEvdnr1cp1fiMtlM/GrE92xAc1K5odTpCzUB+mjXgbaqtntBUbTToSUoT0ovrlPwzGjyp",
      bytes("ca2527a037347b91bea0c8a30fc8d9600ffd81ec00038671e3a0f0cb0fc9f642"),
    )
}

pub fn decrypt_rejects_version_zero_test() {
  let assert Error(nip44.UnsupportedVersion) =
    nip44.decrypt(
      "AK1AjUvoYW3IS7C/BGRUoqEC7ayTfDUgnEPNeWTF/reBZFaha6EAIRueE9D1B1RuoiuFScC0Q94yjIuxZD3JStQtE8JMNacWFs9rlYP+ZydtHhRucp+lxfdvFlaGV/sQlqZz",
      bytes("36f04e558af246352dcf73b692fbd3646a2207bd8abd4b1cd26b234db84d9481"),
    )
}

pub fn decrypt_rejects_tampered_mac_test() {
  // ベクター 1 のペイロードの末尾付近（MAC 領域）を 1 文字書き換えたもの。
  let assert Error(_) =
    nip44.decrypt(
      "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsc",
      bytes(conv_key_1),
    )
}

pub fn encrypt_rejects_empty_plaintext_test() {
  let assert Error(nip44.InvalidPlaintextLength) =
    nip44.encrypt_with_nonce(
      "",
      bytes(conv_key_1),
      bytes("0000000000000000000000000000000000000000000000000000000000000001"),
    )
}

pub fn encrypt_decrypt_roundtrip_test() {
  let assert Ok(payload) = nip44.encrypt("hello nostr", bytes(conv_key_1))
  let assert Ok(text) = nip44.decrypt(payload, bytes(conv_key_1))
  assert text == "hello nostr"
}
