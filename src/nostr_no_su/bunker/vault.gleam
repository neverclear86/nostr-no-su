//// バンカーアカウントの暗号化された保存形式。
////
//// マスターキー、用途ラベルと AAD、DB の行と `Account` の相互変換を持つ。DB にも
//// プロセスにも触れない純粋なモジュールで、nonce は呼び出し側が渡す。
////
//// 秘密鍵も接続 secret も、AES-256-GCM の「nonce(12) || 暗号文 || タグ(16)」の
//// 箱として保存する。AAD は用途ラベル、NUL 1 バイト、x-only 公開鍵の 32 バイトを
//// この順に連結したもので、ある行の暗号文を別の列や別の行へ移す改ざんはタグの
//// 検証で失敗する。ラベル末尾の `v1` は形式の版である。

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/crypto/aes_gcm
import nostr_no_su/hex

/// 秘密鍵のバイト数。
const privkey_bytes = 32

/// x-only 公開鍵のバイト数。
const pubkey_bytes = 32

/// 32 バイトのマスターキー。
///
/// 値は関数に閉じ込めて持つ。opaque 型も実行時にはただのタプルなので、バイト列を
/// 直接持たせると `string.inspect`、`sys:get_state/1`、`let assert` の失敗値、
/// クラッシュレポートのどれにもそのまま出てしまうためである。代償として、
/// **同じ値から作ったマスターキー同士でも `==` は `False` になる。**
pub opaque type MasterKey {
  MasterKey(bytes: fn() -> BitArray)
}

/// 暗号文の用途。AAD のラベルを決める。
pub type Purpose {
  /// 32 バイトの秘密鍵。
  PrivateKey
  /// 接続 secret の UTF-8 バイト列。
  ConnectionSecret
}

/// DB の 1 行（復号前）。
pub type Row {
  Row(
    pubkey: String,
    label: String,
    encrypted_privkey: BitArray,
    encrypted_secret: BitArray,
  )
}

/// 復号済みのアカウント 1 件。`Account` を含むので `==` では比べられない。
pub type StoredAccount {
  StoredAccount(account: Account, secret: String, label: String)
}

/// 1 行を読み込めなかった理由。
pub type RowError {
  /// `pubkey` 列が 32 バイトの 16 進として読めない。
  MalformedPubkey
  /// 秘密鍵の暗号文を開けない（マスターキー違いか改ざん）。
  UndecryptablePrivateKey
  /// 復号した秘密鍵が secp256k1 の秘密鍵として不正。
  InvalidPrivateKey
  /// 復号した秘密鍵の公開鍵が `pubkey` 列と一致しない。
  PublicKeyMismatch
  /// secret の暗号文を開けない（マスターキー違いか改ざん）。
  UndecryptableSecret
  /// 復号した secret が空か、UTF-8 として不正。
  InvalidSecret
}

/// 読み込めた行と、飛ばした行。どちらも元の行の順序を保つ。
pub type Loaded {
  Loaded(accounts: List(StoredAccount), skipped: List(Skipped))
}

/// 飛ばした行 1 件。pubkey は列の値のまま持ち、ログに出すかどうかは
/// `describe_skipped` が決める。
pub type Skipped {
  Skipped(pubkey: String, reason: RowError)
}

/// 64 桁の 16 進からマスターキーを作る。前後の空白は無視し、大文字も受け付ける。
/// 理由の文字列は入力を含まない。
pub fn master_key_from_hex(raw: String) -> Result(MasterKey, String) {
  decode_fixed_hex(string.trim(raw), aes_gcm.key_bytes)
  |> result.map(fn(bytes) { MasterKey(bytes: fn() { bytes }) })
  |> result.replace_error(
    "ACCOUNT_MASTER_KEY must be 64 hex characters (32 bytes)",
  )
}

/// 用途と公開鍵から AAD を組み立て、平文を暗号化する。nonce が 12 バイトでなければ
/// Error(Nil)。
pub fn seal(
  key: MasterKey,
  purpose: Purpose,
  pubkey: BitArray,
  plaintext: BitArray,
  nonce: BitArray,
) -> Result(BitArray, Nil) {
  aes_gcm.seal(key.bytes(), nonce, plaintext, aad(purpose, pubkey))
}

/// 1 行を暗号化する。`seal` を秘密鍵と secret に 1 回ずつ使う。nonce は別々に
/// 受け取る。
pub fn seal_row(
  key: MasterKey,
  entry: StoredAccount,
  privkey_nonce: BitArray,
  secret_nonce: BitArray,
) -> Result(Row, Nil) {
  let pubkey = account.pubkey(entry.account)
  use encrypted_privkey <- result.try(seal(
    key,
    PrivateKey,
    pubkey,
    account.privkey(entry.account),
    privkey_nonce,
  ))
  use encrypted_secret <- result.map(seal(
    key,
    ConnectionSecret,
    pubkey,
    bit_array.from_string(entry.secret),
    secret_nonce,
  ))
  Row(
    pubkey: account.pubkey_hex(entry.account),
    label: entry.label,
    encrypted_privkey: encrypted_privkey,
    encrypted_secret: encrypted_secret,
  )
}

/// 1 行を復号して検証する。公開鍵の解釈、秘密鍵の復号、秘密鍵の検査、公開鍵の
/// 照合、secret の復号、secret の検査の順に行い、最初に失敗した段の理由を返す。
pub fn open_row(key: MasterKey, row: Row) -> Result(StoredAccount, RowError) {
  use pubkey <- result.try(decode_pubkey(row.pubkey))
  use <- bool.guard(
    bit_array.byte_size(row.encrypted_privkey)
      != aes_gcm.nonce_bytes + privkey_bytes + aes_gcm.tag_bytes,
    Error(UndecryptablePrivateKey),
  )
  use privkey <- result.try(
    aes_gcm.open(key.bytes(), row.encrypted_privkey, aad(PrivateKey, pubkey))
    |> result.replace_error(UndecryptablePrivateKey),
  )
  use signer <- result.try(
    account.from_privkey(privkey) |> result.replace_error(InvalidPrivateKey),
  )
  use <- bool.guard(
    account.pubkey_hex(signer) != row.pubkey,
    Error(PublicKeyMismatch),
  )
  use secret <- result.try(
    aes_gcm.open(
      key.bytes(),
      row.encrypted_secret,
      aad(ConnectionSecret, pubkey),
    )
    |> result.replace_error(UndecryptableSecret),
  )
  case bit_array.to_string(secret) {
    Ok("") | Error(Nil) -> Error(InvalidSecret)
    Ok(secret) -> Ok(StoredAccount(account: signer, secret:, label: row.label))
  }
}

/// 行の列を、読み込めた行と飛ばした行に分ける。
pub fn open_rows(key: MasterKey, rows: List(Row)) -> Loaded {
  let #(accounts, skipped) =
    rows
    |> list.map(fn(row) {
      open_row(key, row) |> result.map_error(Skipped(row.pubkey, _))
    })
    |> result.partition
  // `result.partition` は元の順序を逆にして返す。
  Loaded(accounts: list.reverse(accounts), skipped: list.reverse(skipped))
}

/// 飛ばした行 1 件のログ用の説明。秘密の値を含まない。`pubkey` 列が形式不正の
/// ときは、何が入っているか分からないので列の値を出さない。
pub fn describe_skipped(skipped: Skipped) -> String {
  case skipped.reason {
    MalformedPubkey -> "skipped a row with a malformed pubkey"
    reason ->
      "skipped account " <> skipped.pubkey <> ": " <> describe_row_error(reason)
  }
}

/// 読み込めなかった理由の説明。GCM の失敗からはマスターキー違いと改ざんを
/// 区別できないので、両方の可能性を併記する。
fn describe_row_error(reason: RowError) -> String {
  case reason {
    MalformedPubkey -> "malformed pubkey"
    UndecryptablePrivateKey ->
      "private key could not be decrypted (wrong ACCOUNT_MASTER_KEY or tampered row)"
    InvalidPrivateKey -> "decrypted private key is not a valid secp256k1 key"
    PublicKeyMismatch -> "decrypted private key does not match the pubkey"
    UndecryptableSecret ->
      "connection secret could not be decrypted (wrong ACCOUNT_MASTER_KEY or tampered row)"
    InvalidSecret -> "decrypted connection secret is empty or not valid UTF-8"
  }
}

/// `pubkey` 列を 32 バイトの公開鍵として読む。
fn decode_pubkey(pubkey: String) -> Result(BitArray, RowError) {
  decode_fixed_hex(pubkey, pubkey_bytes)
  |> result.replace_error(MalformedPubkey)
}

/// 指定したバイト数ちょうどの 16 進をバイト列にする。
fn decode_fixed_hex(text: String, byte_count: Int) -> Result(BitArray, Nil) {
  use bytes <- result.try(hex.decode(text))
  case bit_array.byte_size(bytes) == byte_count {
    True -> Ok(bytes)
    False -> Error(Nil)
  }
}

/// 用途ラベル || 0x00 || 公開鍵(32 バイト)。ラベルは NUL を含まず公開鍵は固定長
/// なので、連結の境界は一意に決まる。
fn aad(purpose: Purpose, pubkey: BitArray) -> BitArray {
  <<purpose_label(purpose):utf8, 0, pubkey:bits>>
}

/// AAD に入れる用途ラベル。
fn purpose_label(purpose: Purpose) -> String {
  case purpose {
    PrivateKey -> "nostr-no-su:bunker-account:privkey:v1"
    ConnectionSecret -> "nostr-no-su:bunker-account:secret:v1"
  }
}
