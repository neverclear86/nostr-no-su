import gleam/list
import nostr_no_su/nostr/nip19.{
  EmptyPrefix, InvalidCharacter, InvalidChecksum, InvalidLength, InvalidPadding,
  MissingSeparator, MixedCase, Npub, Nsec, PrefixMismatch, TooLong, TooShort,
}
import support/vector.{bytes}

const spec_npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

const spec_npub_key = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"

const spec_nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"

const spec_nsec_key = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

/// 文字列と 16 進の鍵が、指定した接頭辞で両方向に対応することを確かめる。
fn assert_round_trip(text: String, key: String, prefix: nip19.Prefix) -> Nil {
  assert nip19.decode(text, prefix) == Ok(bytes(key))
  assert nip19.encode(bytes(key), prefix) == Ok(text)
}

/// NIP-19 の仕様に載っている npub の例を両方向で再現する。
pub fn npub_spec_vector_test() {
  assert_round_trip(spec_npub, spec_npub_key, Npub)
}

/// NIP-19 の仕様に載っている nsec の例を両方向で再現する。
pub fn nsec_spec_vector_test() {
  assert_round_trip(spec_nsec, spec_nsec_key, Nsec)
}

/// NIP-19 の仕様の「Bare keys and ids」の npub の例を両方向で再現する。
pub fn npub_bare_key_example_test() {
  assert_round_trip(
    "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6",
    "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    Npub,
  )
}

/// BIP-340 の公式ベクター 0 の秘密鍵と x-only 公開鍵を両方向で再現する。
pub fn bip340_vector0_keys_test() {
  assert_round_trip(
    "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re",
    "0000000000000000000000000000000000000000000000000000000000000003",
    Nsec,
  )
  assert_round_trip(
    "npub1lycg5qvjtrp3qjf5f7zl382j9x6nrjz9sdhenvyxq8c3808qxmus6gq266",
    "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
    Npub,
  )
}

/// すべて大文字の文字列も同じ鍵になる。
pub fn decode_accepts_uppercase_test() {
  assert nip19.decode(
      "NSEC1VL029MGPSPEDVA04G90VLTKH6FVH240ZQTV9K0T9AF8935KE9LAQSNLFE5",
      Nsec,
    )
    == Ok(bytes(spec_nsec_key))
}

/// 前後の空白は取り除いてから読む。
pub fn decode_trims_surrounding_whitespace_test() {
  assert nip19.decode(" \n " <> spec_nsec <> "\t", Nsec)
    == Ok(bytes(spec_nsec_key))
}

/// 符号化した文字列を復号すると、どちらの接頭辞でも元の鍵に戻る。
pub fn round_trip_test() {
  let keys = [
    <<0:size(256)>>,
    <<-1:size(256)>>,
    bytes(spec_npub_key),
    bytes(spec_nsec_key),
  ]
  use key <- list.each(keys)
  use prefix <- list.each([Npub, Nsec])
  let assert Ok(text) = nip19.encode(key, prefix)
  assert nip19.decode(text, prefix) == Ok(key)
}

/// 正しい bech32 でも、期待と違う接頭辞なら拒否する。
pub fn decode_rejects_wrong_prefix_test() {
  assert nip19.decode(spec_npub, Nsec) == Error(PrefixMismatch(expected: Nsec))
  assert nip19.decode(spec_nsec, Npub) == Error(PrefixMismatch(expected: Npub))
}

/// 末尾の 1 文字を変えた文字列はチェックサムで拒否する。
pub fn decode_rejects_invalid_checksum_test() {
  assert nip19.decode(
      "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe4",
      Nsec,
    )
    == Error(InvalidChecksum)
}

/// 大文字と小文字が混ざった文字列は拒否する。
pub fn decode_rejects_mixed_case_test() {
  assert nip19.decode(
      "Nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5",
      Nsec,
    )
    == Error(MixedCase)
}

/// データ部に文字集合外の文字（`b`）がある文字列は拒否する。
pub fn decode_rejects_invalid_data_character_test() {
  assert nip19.decode(
      "nsec1vl029bgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5",
      Nsec,
    )
    == Error(InvalidCharacter)
}

/// 途中の空白は取り除かず、不正な文字として拒否する。
pub fn decode_rejects_inner_whitespace_test() {
  assert nip19.decode(
      "nsec1vl029mgpspedva04g90vl tkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5",
      Nsec,
    )
    == Error(InvalidCharacter)
}

/// 空の入力と空白だけの入力は区切り文字が無いものとして拒否する。
pub fn decode_rejects_empty_input_test() {
  assert nip19.decode("", Nsec) == Error(MissingSeparator)
  assert nip19.decode("   ", Nsec) == Error(MissingSeparator)
}

/// チェックサムが正しくても 31 バイトの鍵は拒否する。
pub fn decode_rejects_short_key_test() {
  assert nip19.decode(
      "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dmup82t8f",
      Npub,
    )
    == Error(InvalidLength)
}

/// チェックサムが正しくても 33 バイトの鍵は拒否する。
pub fn decode_rejects_long_key_test() {
  assert nip19.decode(
      "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qqlhqg6v",
      Npub,
    )
    == Error(InvalidLength)
}

/// 5 ビット値が 51 個で余りが 7 ビットになる文字列は拒否する。
pub fn decode_rejects_excess_padding_test() {
  assert nip19.decode(
      "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma85c8cls",
      Npub,
    )
    == Error(InvalidPadding)
}

/// 余りのビットが 0 でない文字列は拒否する。
pub fn decode_rejects_non_zero_padding_test() {
  assert nip19.decode(
      "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8pl6x5k6",
      Npub,
    )
    == Error(InvalidPadding)
}

/// 256 ビットでない鍵は符号化しない。
pub fn encode_rejects_non_32_byte_key_test() {
  let keys = [<<>>, <<0:size(248)>>, <<0:size(264)>>, <<0:size(255)>>]
  use key <- list.each(keys)
  assert nip19.encode(key, Npub) == Error(InvalidLength)
}

/// エラーの説明は入力によらない固定の文字列になる。
pub fn describe_returns_fixed_text_test() {
  let assert Error(error) =
    nip19.decode(
      "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe4",
      Nsec,
    )
  assert nip19.describe(error) == "invalid bech32 checksum"
  assert nip19.describe(PrefixMismatch(expected: Nsec))
    == "expected nsec prefix"
}

/// BIP-173 の有効な文字列はチェックサムの検証を通り、接頭辞の検査まで進む。
pub fn decode_accepts_bip173_valid_checksums_test() {
  let inputs = [
    "A12UEL5L",
    "a12uel5l",
    "an83characterlonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1tt5tgs",
    "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
    "11qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqc8247j",
    "split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w",
    "?1ezyfcl",
  ]
  use input <- list.each(inputs)
  assert #(input, nip19.decode(input, Npub))
    == #(input, Error(PrefixMismatch(expected: Npub)))
}

/// BIP-173 の不正な文字列は、検査順序で最初に失敗した段の理由で拒否する。
pub fn decode_rejects_bip173_invalid_vectors_test() {
  let cases = [
    // 前後の空白を先に除くので、HRP が空になる。
    #("\u{0020}1nwldj5", EmptyPrefix),
    #("\u{007F}1axkwrx", InvalidCharacter),
    #("\u{0080}1eym55h", InvalidCharacter),
    #(
      "an84characterslonghumanreadablepartthatcontainsthenumber1andtheexcludedcharactersbio1569pvx",
      TooLong,
    ),
    #("pzry9x0s0muk", MissingSeparator),
    #("1pzry9x0s0muk", EmptyPrefix),
    #("x1b4n0q5v", InvalidCharacter),
    #("li1dgmt3", TooShort),
    #("de1lg7wt\u{00FF}", InvalidCharacter),
    #("A1G7SGD8", InvalidChecksum),
    #("10a06t8", EmptyPrefix),
    #("1qzzfhee", EmptyPrefix),
    #(
      "tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sL5k7",
      MixedCase,
    ),
    #("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5", InvalidChecksum),
  ]
  use #(input, expected) <- list.each(cases)
  assert #(input, nip19.decode(input, Npub)) == #(input, Error(expected))
}
