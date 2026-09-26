//// バンカーの保存形式のうち、マスターキーで守る部分。
////
//// マスターキー、用途ラベルと AAD、DB の行と `Account` の相互変換、セッションと
//// 承認待ちの行の MAC を持つ。DB にもプロセスにも触れない純粋なモジュールで、
//// nonce は呼び出し側が渡す。
////
//// 秘密鍵も接続 secret も、AES-256-GCM の「nonce(12) || 暗号文 || タグ(16)」の
//// 箱として保存する。AAD は用途ラベル、NUL 1 バイト、x-only 公開鍵の 32 バイトを
//// この順に連結したもので、ある行の暗号文を別の列や別の行へ移す改ざんはタグの
//// 検証で失敗する。ラベル末尾の `v1` は形式の版である。
////
//// セッション（`bunker_sessions`）と承認待ち（`bunker_pending`）の行には
//// HMAC-SHA256 の MAC を付ける。MAC の鍵は用途の文字列をマスターキーで HMAC して
//// 導き、アカウントの暗号化の鍵（マスターキーそのもの）と用途を分ける。入力は
//// テーブル名と主キーを含む全列（セッションの `relays` は空でないときだけ）を、
//// それぞれバイト数を前に付けて連結したもので、列の値を書き換えた行や、
//// 別のテーブルの行へ移した MAC は検証で失敗する。

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/crypto/aes_gcm
import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex
import nostr_no_su/log
import nostr_no_su/secret.{type Secret}

/// 32 バイトのマスターキー。値は `Secret` に閉じ込めて持つ。
pub opaque type MasterKey {
  MasterKey(bytes: Secret(BitArray))
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

/// 復号済みのアカウント 1 件。
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
/// `describe_skipped` が決める。ラベルは平文の列から取り、ログには出さない。
pub type Skipped {
  Skipped(pubkey: String, label: String, reason: RowError)
}

/// MAC の対象になる行。`bunker_sessions` と `bunker_pending` の 1 行ぶんの値を
/// 持ち、変種がテーブルの区別になる。
pub type MacRow {
  /// `bunker_sessions` の 1 行（承認済みのセッション）。
  SessionMacRow(
    /// 署名者の公開鍵（16 進、小文字）。
    signer: String,
    /// クライアントの公開鍵（16 進、小文字）。
    client: String,
    /// セッション内の要求を照合する権限。空文字列は既定の集合（engine の
    /// `default_perms`）で照合する。
    perms: String,
    /// 作成した Unix 秒。
    created_at: Int,
    /// 最後に使った Unix 秒。新しい組では `created_at` と同じ値。
    last_used_at: Int,
    /// `nostrconnect://` の URI に現れたリレー（URI の順）。`bunker://` の
    /// `connect` と承認で開いたセッションは空。
    relays: List(String),
  )
  /// `bunker_pending` の 1 行（承認待ちの接続要求）。
  PendingMacRow(
    /// 承認ページの URL に入るトークン。
    token: String,
    /// 署名者の公開鍵（16 進、小文字）。
    signer: String,
    /// クライアントの公開鍵（16 進、小文字）。
    client: String,
    /// 元の `connect` リクエストの id。
    request_id: String,
    /// 要求された権限。空文字列は要求なし。
    perms: String,
    /// secret が一致しなかったか。
    secret_mismatch: Bool,
    /// 作成した Unix 秒。
    created_at: Int,
  )
}

/// 64 桁の 16 進からマスターキーを作る。前後の空白は無視し、大文字も受け付ける。
/// 理由の文字列は入力を含まない。
pub fn master_key_from_hex(raw: String) -> Result(MasterKey, String) {
  hex.decode_exact(string.trim(raw), aes_gcm.key_bytes)
  |> result.map(fn(bytes) { MasterKey(bytes: secret.new(bytes)) })
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
  aes_gcm.seal(secret.reveal(key.bytes), nonce, plaintext, aad(purpose, pubkey))
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
      != aes_gcm.nonce_bytes + account.privkey_bytes + aes_gcm.tag_bytes,
    Error(UndecryptablePrivateKey),
  )
  use privkey <- result.try(
    aes_gcm.open(
      secret.reveal(key.bytes),
      row.encrypted_privkey,
      aad(PrivateKey, pubkey),
    )
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
      secret.reveal(key.bytes),
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
      open_row(key, row) |> result.map_error(Skipped(row.pubkey, row.label, _))
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

/// MAC の合わない行 1 件のログ用の説明。テーブル名、署名者、クライアントで行を
/// 指し、権限と承認待ちのトークンは含めない。クライアントの列は DB に書ける者が
/// 任意の文字列にできるので `log.sanitize_external` で 1 行に収める。署名者の列は
/// `bunker_accounts(pubkey)` の外部キーで 64 桁の 16 進に限られるので、そのまま
/// 出す。
pub fn describe_rejected(row: MacRow) -> String {
  let #(table, signer, client) = case row {
    SessionMacRow(signer:, client:, ..) -> #("bunker_sessions", signer, client)
    PendingMacRow(signer:, client:, ..) -> #("bunker_pending", signer, client)
  }
  "skipped a "
  <> table
  <> " row with a mismatched MAC: signer "
  <> signer
  <> ", client "
  <> log.sanitize_external(client)
}

/// 1 行の MAC（HMAC-SHA256、32 バイト）を計算する。MAC の鍵は呼び出しのたびに
/// マスターキーから導く。
pub fn row_mac(key: MasterKey, row: MacRow) -> BitArray {
  crypto.hmac(mac_input(row), crypto.Sha256, mac_key(key))
}

/// `mac` が 1 行の MAC と一致するか。一致した長さが応答時間に現れないよう
/// `crypto.secure_compare` で比べる。長さが違えば早く `False` になるが、MAC は
/// 32 バイト固定なので長さで漏れる情報は無い。
pub fn verify_row_mac(key: MasterKey, row: MacRow, mac: BitArray) -> Bool {
  crypto.secure_compare(row_mac(key, row), mac)
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
  hex.decode_exact(pubkey, secp256k1.xonly_pubkey_bytes)
  |> result.replace_error(MalformedPubkey)
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

/// MAC 用の鍵。アカウントの暗号化の鍵（マスターキーそのもの）と用途を分けるため、
/// 用途の文字列をマスターキーで HMAC して導く。ラベル末尾の `v1` は形式の版である。
fn mac_key(key: MasterKey) -> BitArray {
  crypto.hmac(
    <<"nostr-no-su:bunker-row-mac:v1":utf8>>,
    crypto.Sha256,
    secret.reveal(key.bytes),
  )
}

/// 行の MAC の入力。テーブル名を先頭に、主キーを含む全列を表の列の順で
/// `length_prefixed` で連結する。文字列は UTF-8、Int は 8 バイトのビッグ
/// エンディアン、Bool は `bool_byte` の 1 バイトにする。セッションの `relays` は
/// `last_used_at` の後に置き、空の一覧のときは列ごと入れない（`relays_field`）。
fn mac_input(row: MacRow) -> BitArray {
  case row {
    SessionMacRow(signer:, client:, perms:, created_at:, last_used_at:, relays:) ->
      length_prefixed(list.append(
        [
          <<"bunker_sessions":utf8>>,
          <<signer:utf8>>,
          <<client:utf8>>,
          <<perms:utf8>>,
          <<created_at:size(64)>>,
          <<last_used_at:size(64)>>,
        ],
        relays_field(relays),
      ))
    PendingMacRow(
      token:,
      signer:,
      client:,
      request_id:,
      perms:,
      secret_mismatch:,
      created_at:,
    ) ->
      length_prefixed([
        <<"bunker_pending":utf8>>,
        <<token:utf8>>,
        <<signer:utf8>>,
        <<client:utf8>>,
        <<request_id:utf8>>,
        <<perms:utf8>>,
        bool_byte(secret_mismatch),
        <<created_at:size(64)>>,
      ])
  }
}

/// セッションの `relays` の MAC の入力の列。空の一覧は列を持たず、それ以外は
/// 各要素（UTF-8）を `length_prefixed` で連結した 1 列にする。列の有無と要素の
/// 境界が入力に現れるので、空の一覧と空文字列 1 件、区切りだけが違う一覧は
/// 別の MAC になる。
fn relays_field(relays: List(String)) -> List(BitArray) {
  case relays {
    [] -> []
    _ -> [length_prefixed(list.map(relays, bit_array.from_string))]
  }
}

/// 各要素の前にバイト数（4 バイトのビッグエンディアン）を付けて連結する。要素の
/// 境界が一意に決まるので、区切り位置だけが違う入力は同じバイト列にならない。
fn length_prefixed(fields: List(BitArray)) -> BitArray {
  fields
  |> list.map(fn(field) { <<bit_array.byte_size(field):size(32), field:bits>> })
  |> bit_array.concat
}

/// Bool を 1 バイトの 0 / 1 にする。
fn bool_byte(value: Bool) -> BitArray {
  case value {
    True -> <<1>>
    False -> <<0>>
  }
}
