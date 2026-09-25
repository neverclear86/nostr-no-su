//// `bunker/vault` のテスト。`Account` と `MasterKey` は関数を捕捉しているので
//// `==` で比べず、`pubkey_hex`、`secret`、`label` のような比べられる値を取り出して
//// 比べる。

import gleam/bit_array
import gleam/list
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/vault.{
  type MasterKey, Loaded, PendingMacRow, Row, SessionMacRow, Skipped,
  StoredAccount,
}
import nostr_no_su/hex
import support/vector.{bytes, contains_bytes}

/// テスト用のマスターキー（16 進）。
const master_key_hex = "8c1d4e7f2a5b3c6d9e0f1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f"

/// 別のマスターキー（16 進）。
const other_master_key_hex = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

/// 行 A の秘密鍵。
const privkey_a = "0000000000000000000000000000000000000000000000000000000000000042"

/// 行 B の秘密鍵。
const privkey_b = "0000000000000000000000000000000000000000000000000000000000000009"

/// 行 A の接続 secret。
const secret_a = "5ecre7-a"

/// 固定の nonce（秘密鍵用）。
const privkey_nonce = "000102030405060708090a0b"

/// 固定の nonce（secret 用）。
const secret_nonce = "0c0d0e0f1011121314151617"

/// 16 進から作ったマスターキー。テストの値は正しい前提。
fn master_key(raw: String) -> MasterKey {
  let assert Ok(key) = vault.master_key_from_hex(raw)
  key
}

/// 16 進の秘密鍵から作ったアカウント。
fn signer(privkey_hex: String) -> Account {
  let assert Ok(signer) = account.from_privkey(bytes(privkey_hex))
  signer
}

/// 行 A を固定の nonce で暗号化した行。
fn row_a() -> vault.Row {
  let assert Ok(row) =
    vault.seal_row(
      master_key(master_key_hex),
      StoredAccount(account: signer(privkey_a), secret: secret_a, label: "main"),
      bytes(privkey_nonce),
      bytes(secret_nonce),
    )
  row
}

/// `vault.seal` の結果を取り出す。テストが渡す nonce は正しい前提。
fn sealed(
  purpose: vault.Purpose,
  pubkey: BitArray,
  plaintext: BitArray,
) -> BitArray {
  let assert Ok(sealed) =
    vault.seal(
      master_key(master_key_hex),
      purpose,
      pubkey,
      plaintext,
      bytes(privkey_nonce),
    )
  sealed
}

/// 行を開いた結果の理由。成功したらテストを失敗させる。
fn open_error(row: vault.Row) -> vault.RowError {
  let assert Error(reason) = vault.open_row(master_key(master_key_hex), row)
  reason
}

/// 64 桁の 16 進は大文字でも小文字でも、前後に空白があっても受け付ける。
pub fn master_key_accepts_64_hex_characters_test() {
  let assert Ok(_) = vault.master_key_from_hex(master_key_hex)
  let assert Ok(_) = vault.master_key_from_hex(string.uppercase(master_key_hex))
  let assert Ok(_) = vault.master_key_from_hex(" " <> master_key_hex <> "\n")
}

/// 63 桁、65 桁、16 進でない文字、空文字列を拒否し、理由に入力を含めない。
pub fn master_key_rejects_malformed_input_test() {
  let inputs = [
    string.drop_end(master_key_hex, 1),
    master_key_hex <> "0",
    string.drop_end(master_key_hex, 2) <> "zz",
    "",
  ]
  use input <- list.each(inputs)
  let assert Error(reason) = vault.master_key_from_hex(input)
  assert reason == "ACCOUNT_MASTER_KEY must be 64 hex characters (32 bytes)"
}

/// マスターキーを表示しても、16 進表現もバイト列の表示も出ない。
pub fn inspecting_a_master_key_does_not_reveal_it_test() {
  let shown = string.inspect(master_key(master_key_hex))
  assert !string.contains(string.lowercase(shown), master_key_hex)
  assert !string.contains(shown, string.inspect(bytes(master_key_hex)))
}

/// 暗号化した行を開くと、公開鍵、秘密鍵、secret、ラベルが元に戻る。nonce を
/// 固定しているので、行（関数を含まない）は同じ入力から同じ値になる。
pub fn sealed_rows_open_to_the_same_account_test() {
  let row = row_a()
  assert row == row_a()
  assert row.pubkey == account.pubkey_hex(signer(privkey_a))
  assert row.label == "main"

  let assert Ok(StoredAccount(account: opened, secret:, label:)) =
    vault.open_row(master_key(master_key_hex), row)
  assert account.pubkey_hex(opened) == row.pubkey
  assert account.privkey(opened) == bytes(privkey_a)
  assert secret == secret_a
  assert label == "main"
}

/// 秘密鍵の箱は 60 バイトで、どちらの箱も平文を部分列として含まない。
pub fn sealed_boxes_do_not_contain_the_plaintext_test() {
  let row = row_a()
  assert bit_array.byte_size(row.encrypted_privkey) == 60
  assert !contains_bytes(row.encrypted_privkey, bytes(privkey_a))
  assert !contains_bytes(row.encrypted_secret, bit_array.from_string(secret_a))
}

/// 別のマスターキーでは秘密鍵を開けない。
pub fn a_different_master_key_cannot_open_the_row_test() {
  assert vault.open_row(master_key(other_master_key_hex), row_a())
    == Error(vault.UndecryptablePrivateKey)
}

/// 秘密鍵の暗号文と secret の暗号文を入れ替えた行は開けない。用途ラベルが AAD に
/// 入っているため、長さを揃えてもタグの検証で落ちる。
pub fn swapping_the_privkey_and_secret_boxes_fails_test() {
  let row = row_a()
  let secret_as_privkey =
    sealed(
      vault.ConnectionSecret,
      account.pubkey(signer(privkey_a)),
      bytes(privkey_a),
    )
  // secret の列に入る 60 バイトの箱を秘密鍵の列へ移すと、長さの検査を通っても
  // 用途ラベルの違いで開けない。
  assert open_error(Row(..row, encrypted_privkey: secret_as_privkey))
    == vault.UndecryptablePrivateKey
  assert open_error(Row(..row, encrypted_secret: row.encrypted_privkey))
    == vault.UndecryptableSecret
}

/// 行 A の秘密鍵の暗号文を行 B に移すと開けない。公開鍵が AAD に入っているため。
pub fn moving_a_privkey_box_to_another_row_fails_test() {
  let row_b = Row(..row_a(), pubkey: account.pubkey_hex(signer(privkey_b)))
  assert open_error(row_b) == vault.UndecryptablePrivateKey
}

/// 行 B の公開鍵を AAD にして行 A の秘密鍵を正しく暗号化した行は、タグは通るが
/// 復号後の照合で落ちる。
pub fn a_privkey_that_does_not_match_the_pubkey_is_rejected_test() {
  let signer_b = signer(privkey_b)
  let row =
    Row(
      ..row_a(),
      pubkey: account.pubkey_hex(signer_b),
      encrypted_privkey: sealed(
        vault.PrivateKey,
        account.pubkey(signer_b),
        bytes(privkey_a),
      ),
    )
  assert open_error(row) == vault.PublicKeyMismatch
}

/// すべて 0 の秘密鍵を暗号化した行は、復号できても秘密鍵として不正。
pub fn a_zero_privkey_is_rejected_test() {
  let row = row_a()
  let assert Ok(pubkey) = hex.decode(row.pubkey)
  let row =
    Row(..row, encrypted_privkey: sealed(vault.PrivateKey, pubkey, <<0:256>>))
  assert open_error(row) == vault.InvalidPrivateKey
}

/// 32 バイトの 16 進として読めない `pubkey` 列は `MalformedPubkey` で、説明に列の
/// 値を含めない。
pub fn a_malformed_pubkey_is_not_echoed_test() {
  let row = Row(..row_a(), pubkey: "not-a-pubkey-marker")
  assert open_error(row) == vault.MalformedPubkey
  let described =
    vault.describe_skipped(Skipped(
      "not-a-pubkey-marker",
      "",
      vault.MalformedPubkey,
    ))
  assert !string.contains(described, "not-a-pubkey-marker")
}

/// UTF-8 でない secret と空の secret は `InvalidSecret`。
pub fn invalid_secrets_are_rejected_test() {
  let row = row_a()
  let assert Ok(pubkey) = hex.decode(row.pubkey)
  use plaintext <- list.each([<<0xff, 0xfe>>, <<>>])
  let row =
    Row(
      ..row,
      encrypted_secret: sealed(vault.ConnectionSecret, pubkey, plaintext),
    )
  assert open_error(row) == vault.InvalidSecret
}

/// 壊れた行だけを飛ばし、残りの行は元の順序のまま読み込む。
pub fn open_rows_skips_only_the_broken_rows_test() {
  let good_a = row_a()
  let assert Ok(good_b) =
    vault.seal_row(
      master_key(master_key_hex),
      StoredAccount(account: signer(privkey_b), secret: "b", label: ""),
      bytes(privkey_nonce),
      bytes(secret_nonce),
    )
  let broken = Row(..good_b, encrypted_secret: good_a.encrypted_secret)
  let Loaded(accounts:, skipped:) =
    vault.open_rows(master_key(master_key_hex), [good_a, broken, good_b])
  assert list.map(accounts, fn(entry) { account.pubkey_hex(entry.account) })
    == [good_a.pubkey, good_b.pubkey]
  assert list.map(skipped, fn(entry) { #(entry.pubkey, entry.reason) })
    == [#(good_b.pubkey, vault.UndecryptableSecret)]
}

/// 飛ばした行の説明は、公開鍵と理由だけを含む。
pub fn skipped_rows_are_described_by_pubkey_and_reason_test() {
  let pubkey = account.pubkey_hex(signer(privkey_a))
  assert vault.describe_skipped(Skipped(
      pubkey,
      "",
      vault.UndecryptablePrivateKey,
    ))
    == "skipped account "
    <> pubkey
    <> ": private key could not be decrypted (wrong ACCOUNT_MASTER_KEY or tampered row)"
}

/// MAC を計算するセッションの行。
fn session_mac_row() -> vault.MacRow {
  SessionMacRow(
    signer: "signer-a",
    client: "client-a",
    perms: "sign_event",
    created_at: 1_700_000_000,
    last_used_at: 1_700_000_100,
    relays: [],
  )
}

/// MAC を計算する承認待ちの行。共通の列は `session_mac_row` と同じ値にしてある。
fn pending_mac_row() -> vault.MacRow {
  PendingMacRow(
    token: "token-a",
    signer: "signer-a",
    client: "client-a",
    request_id: "req-1",
    perms: "sign_event",
    secret_mismatch: False,
    created_at: 1_700_000_000,
  )
}

/// 同じ行と同じ鍵では検証が通り、MAC は 32 バイトである。
pub fn the_same_row_and_key_verify_test() {
  let key = master_key(master_key_hex)
  use row <- list.each([session_mac_row(), pending_mac_row()])
  let mac = vault.row_mac(key, row)
  assert bit_array.byte_size(mac) == 32
  assert vault.verify_row_mac(key, row, mac)
}

/// 行の各列を 1 つずつ変えた行の一覧。列を 1 つ変えると検証が通らないことを
/// 全列について確かめるために使う。
fn tampered_mac_rows(row: vault.MacRow) -> List(vault.MacRow) {
  case row {
    SessionMacRow(..) -> [
      SessionMacRow(..row, signer: "tampered"),
      SessionMacRow(..row, client: "tampered"),
      SessionMacRow(..row, perms: "tampered"),
      SessionMacRow(..row, created_at: row.created_at + 1),
      SessionMacRow(..row, last_used_at: row.last_used_at + 1),
      SessionMacRow(..row, relays: ["wss://tampered.example"]),
    ]
    PendingMacRow(..) -> [
      PendingMacRow(..row, token: "tampered"),
      PendingMacRow(..row, signer: "tampered"),
      PendingMacRow(..row, client: "tampered"),
      PendingMacRow(..row, request_id: "tampered"),
      PendingMacRow(..row, perms: "tampered"),
      PendingMacRow(..row, secret_mismatch: !row.secret_mismatch),
      PendingMacRow(..row, created_at: row.created_at + 1),
    ]
  }
}

/// どの列を 1 つ変えても検証は通らない。
pub fn changing_one_column_fails_verification_test() {
  let key = master_key(master_key_hex)
  use row <- list.each([session_mac_row(), pending_mac_row()])
  let mac = vault.row_mac(key, row)
  use tampered <- list.each(tampered_mac_rows(row))
  assert !vault.verify_row_mac(key, tampered, mac)
}

/// 共通の列が同じ値でも、セッションの MAC は承認待ちの行として検証できない。
pub fn a_session_mac_does_not_verify_as_a_pending_row_test() {
  let key = master_key(master_key_hex)
  let mac = vault.row_mac(key, session_mac_row())
  assert !vault.verify_row_mac(key, pending_mac_row(), mac)
}

/// 別のマスターキーでは検証が通らない。
pub fn a_different_master_key_does_not_verify_a_row_test() {
  use row <- list.each([session_mac_row(), pending_mac_row()])
  let mac = vault.row_mac(master_key(master_key_hex), row)
  assert !vault.verify_row_mac(master_key(other_master_key_hex), row, mac)
}

/// 固定の行の MAC は、鍵の導出と入力の形から独立に計算した既知の値に一致する。
pub fn row_macs_match_the_known_answers_test() {
  let key = master_key(master_key_hex)
  assert vault.row_mac(key, session_mac_row())
    == bytes("02738cc4cc3b744edc8073364047ca8b7c5ff7e91ebc07e669b172d70263ffdc")
  assert vault.row_mac(key, pending_mac_row())
    == bytes("21c41e6ab89127133b42af4ae99d8569bce978aa7c7964eec8b688c929af8100")
}

/// `relays` を持つセッションの行の MAC は、要素をバイト数つきで連結した 1 列を
/// 末尾に足した入力から独立に計算した既知の値に一致する。
pub fn a_session_row_mac_with_relays_matches_the_known_answer_test() {
  let key = master_key(master_key_hex)
  let assert SessionMacRow(..) as row = session_mac_row()
  let row =
    SessionMacRow(..row, relays: [
      "wss://relay.example",
      "ws://relay.example:7777",
    ])
  assert vault.row_mac(key, row)
    == bytes("fc0cdc5eae537b4aad240ad88584f0ebd4655a86ba3f891f2e378c68ae5b96af")
}

/// MAC の合わない行の説明はテーブル名、署名者、1 行に収めたクライアントで行を
/// 指し、権限と承認待ちのトークンを含めない。
pub fn rejected_rows_are_described_without_perms_or_token_test() {
  let forged =
    SessionMacRow(
      signer: "signer-a",
      client: "client\nforged: line",
      perms: "sign_event",
      created_at: 1_700_000_000,
      last_used_at: 1_700_000_100,
      relays: [],
    )
  assert vault.describe_rejected(forged)
    == "skipped a bunker_sessions row with a mismatched MAC: signer signer-a, client client forged: line"
  assert vault.describe_rejected(pending_mac_row())
    == "skipped a bunker_pending row with a mismatched MAC: signer signer-a, client client-a"
}
