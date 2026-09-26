//// NIP-46 の `perms` の型と解釈（`bunker/permission`）の単体テスト。

import gleam/list
import nostr_no_su/bunker/permission.{
  Nip44Decrypt, Nip44Encrypt, Other, SignAnyKind, SignKind,
}

/// `sign_event`、`sign_event:1`、`nip44_encrypt`、`nip44_decrypt`、そのほかの
/// トークンが、それぞれ対応する変種の並びになる。
pub fn parse_reads_each_token_test() {
  assert permission.parse(
      "sign_event,sign_event:1,nip44_encrypt,nip44_decrypt,get_public_key",
    )
    == [
      SignAnyKind,
      SignKind(1),
      Nip44Encrypt,
      Nip44Decrypt,
      Other("get_public_key"),
    ]
}

/// 空文字列は無宣言として空の一覧になる。
pub fn parse_of_an_empty_string_is_empty_test() {
  assert permission.parse("") == []
}

/// `sign_event:` の後が `int.to_string` の形でないトークン（`01`、`+1`、数でない値、空）と、
/// 前後の空白のあるトークンは `Other` に綴りのまま入る。
pub fn parse_keeps_a_non_canonical_kind_as_other_test() {
  use token <- list.each([
    "sign_event:01", "sign_event:+1", "sign_event:x", "sign_event:",
    " nip44_encrypt",
  ])
  assert permission.parse(token) == [Other(token)]
}

/// カンマ区切りの `perms` が、`parse` して `to_string` で戻すと元の文字列に戻る
/// （空のトークンと負の kind、正規形でない kind を含む）。
pub fn to_string_restores_the_parsed_value_test() {
  let perms =
    "sign_event,sign_event:01,nip44_encrypt,nip44_decrypt,,sign_event:-1,x"
  assert permission.to_string(permission.parse(perms)) == perms
}

/// 無宣言（空の一覧）は既定の集合と照合するので、`sign_event` の署名と NIP-44 を許し、
/// NIP-04 は許さない。
pub fn empty_grants_allow_the_defaults_test() {
  assert permission.allows([], SignKind(1))
  assert permission.allows([], Nip44Encrypt)
  assert permission.allows([], Nip44Decrypt)
  assert !permission.allows([], Other("nip04_encrypt"))
}

/// `sign_event` の宣言はすべての kind の署名を許すが、暗号化は許さない。
pub fn sign_any_kind_allows_every_kind_test() {
  assert permission.allows([SignAnyKind], SignKind(30_023))
  assert !permission.allows([SignAnyKind], Nip44Encrypt)
}

/// `sign_event:<kind>` の宣言は同じ kind だけを許す（接頭辞の一致ではない）。
pub fn sign_kind_allows_only_its_kind_test() {
  assert permission.allows([SignKind(1)], SignKind(1))
  assert !permission.allows([SignKind(1)], SignKind(2))
  assert !permission.allows([SignKind(12)], SignKind(1))
}

/// 宣言のある一覧は既定の集合を使わないので、既定にだけある権限と、
/// 空のトークンだけの宣言では既定の署名は許さない。
pub fn declared_grants_replace_the_defaults_test() {
  assert !permission.allows([Nip44Encrypt], Nip44Decrypt)
  assert !permission.allows([Other("")], SignKind(1))
}

/// `nip04_encrypt` と `nip04_decrypt` が未対応の権限で、`nip44_encrypt`、`sign_event`、
/// `sign_event:1`、`get_public_key` は未対応でない。
pub fn nip04_methods_are_unsupported_test() {
  assert permission.is_unsupported(Other("nip04_encrypt"))
  assert permission.is_unsupported(Other("nip04_decrypt"))
  assert !permission.is_unsupported(Nip44Encrypt)
  assert !permission.is_unsupported(SignAnyKind)
  assert !permission.is_unsupported(SignKind(1))
  assert !permission.is_unsupported(Other("get_public_key"))
}
