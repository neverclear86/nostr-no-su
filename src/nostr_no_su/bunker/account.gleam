//// バンカーアカウント。バンカーが代理で署名する 1 つのアイデンティティ
//// （鍵ペア）の鍵素材。

import gleam/bit_array
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex
import nostr_no_su/nostr/nip19
import nostr_no_su/secret.{type Secret}

/// 秘密鍵のバイト数。
pub const privkey_bytes = 32

/// バンカーが代理で署名する 1 つのアイデンティティ。x-only 公開鍵は署名にも
/// ルーティングにも使うため、バイト列と 16 進表現の両方を持つ。
///
/// 構築の経路は `from_privkey` だけなので、秘密鍵と公開鍵が食い違う値は作れない。
/// 秘密鍵は `Secret` に閉じ込めて持つ。
pub opaque type Account {
  Account(privkey: Secret(BitArray), pubkey: BitArray, pubkey_hex: String)
}

/// `from_privkey` が秘密鍵を拒否した理由。値は鍵を含まない。
pub type PrivateKeyError {
  /// 32 バイトではない。
  WrongLength
  /// スカラーが 1 以上で位数 n 未満の範囲にない。
  OutOfRange
}

/// 32 バイトの秘密鍵からアカウントを構築する。長さが違えば `WrongLength`、範囲外の
/// スカラーなら `OutOfRange` で拒否する。
pub fn from_privkey(privkey: BitArray) -> Result(Account, PrivateKeyError) {
  use <- bool.guard(
    bit_array.byte_size(privkey) != privkey_bytes,
    Error(WrongLength),
  )
  use pubkey <- result.map(
    secp256k1.xonly_pubkey(privkey) |> result.replace_error(OutOfRange),
  )
  Account(
    privkey: secret.new(privkey),
    pubkey: pubkey,
    pubkey_hex: hex.encode(pubkey),
  )
}

/// 乱数から秘密鍵を作り、アカウントを構築する。範囲外のスカラーを引いたら引き直す。
/// `random_bytes` は指定したバイト数の乱数を返す関数で、本番では
/// `crypto.strong_random_bytes` を渡す。32 バイト以外を返し続ける関数を渡すと終わらない。
pub fn generate(random_bytes: fn(Int) -> BitArray) -> Account {
  case from_privkey(random_bytes(privkey_bytes)) {
    Ok(generated) -> generated
    Error(_) -> generate(random_bytes)
  }
}

/// 署名と会話鍵の導出に使う 32 バイトの秘密鍵。
pub fn privkey(account: Account) -> BitArray {
  secret.reveal(account.privkey)
}

/// x-only 公開鍵の 32 バイト。
pub fn pubkey(account: Account) -> BitArray {
  account.pubkey
}

/// x-only 公開鍵の小文字 16 進。署名者の識別子とルーティングに使う。
pub fn pubkey_hex(account: Account) -> String {
  account.pubkey_hex
}

/// 表示用の npub 文字列。
pub fn npub(account: Account) -> String {
  // 構築の経路は `from_privkey` だけで、公開鍵は常に 32 バイトなので失敗しない。
  // 失敗の値は `Error(InvalidLength)` で、鍵を含まない。
  let assert Ok(text) = nip19.encode(account.pubkey, nip19.Npub)
    as "an Account always holds a 32-byte public key"
  text
}

/// 秘密鍵を表示するための nsec 文字列。登録の手続きと、管理パスワードを再入力した
/// 再表示にだけ使う。
pub fn nsec(account: Account) -> String {
  // `from_privkey` が 32 バイトであることを検査しているので失敗しない。
  let assert Ok(text) = nip19.encode(secret.reveal(account.privkey), nip19.Nsec)
    as "an Account always holds a 32-byte private key"
  text
}

/// 署名者 `signer`（x-only 公開鍵の小文字 16 進）へ接続するためにクライアントへ
/// 貼り付ける `bunker://` URI。URI に入るのは公開鍵だけなので、秘密鍵を持つ
/// `Account` を受け取らない。NIP-46 は複数の `relay=` ヒントを許容し、クライアント
/// はそのすべてに接続するため、生きているリレーが 1 つあればバンカーに到達できる。
/// `secret` が `None` の URI はその場では接続できず、管理 UI での承認（auth_url
/// フロー）を経る。リレーが 0 件でも URI を返す（クエリー文字列自体を省く）。
pub fn bunker_uri(
  signer: String,
  relay_urls: List(String),
  secret: Option(String),
) -> String {
  let relay_params =
    list.map(relay_urls, fn(url) { "relay=" <> uri.percent_encode(url) })
  let secret_param = case secret {
    None -> []
    Some(secret) -> ["secret=" <> secret]
  }
  case list.append(relay_params, secret_param) {
    [] -> "bunker://" <> signer
    params -> "bunker://" <> signer <> "?" <> string.join(params, "&")
  }
}

/// `bunker_uri` が返した URI から、端末のカメラがテキストとして扱う形を作る。先頭の
/// `bunker://` を外し、`relay=` の値のドットを `%2E` に置き換える。クライアントの入力欄で
/// 先頭に `bunker://` を打ち直せば元の URI として解析でき、`%2E` は `.` に戻る。入力は
/// `bunker_uri` の出力に限る（`secret=` と公開鍵は触らない）。
pub fn camera_copy_text(uri: String) -> String {
  let body = case string.split_once(uri, "bunker://") {
    Ok(#("", rest)) -> rest
    _ -> uri
  }
  case string.split_once(body, "?") {
    Error(Nil) -> body
    Ok(#(signer, query)) ->
      signer
      <> "?"
      <> {
        string.split(query, "&")
        |> list.map(fn(param) {
          case string.starts_with(param, "relay=") {
            True -> string.replace(param, ".", "%2E")
            False -> param
          }
        })
        |> string.join("&")
      }
  }
}
