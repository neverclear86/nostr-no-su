//// NIP-46 の `perms`（カンマ区切りの権限のトークン）の型と解釈。`perms` の文字列との変換、
//// 無宣言のセッションに許す既定の集合、許可の判定、バンカーが対応していない方法の判定を
//// 持つ。保存と通信（DB の `perms` 列、`connect` の `params[2]`）は文字列のままで、型は
//// メモリの中だけで使う。バンカーのエンジンと、管理 UI の権限のチップ・権限の編集のフォームと
//// 保存が使う。純粋である。

import gleam/int
import gleam/list
import gleam/string

/// `perms` のトークン 1 つ。前後の空白は除かず、下の 4 つの形（`sign_event:<kind>` は
/// 正規形に限る）に当たらないトークンは `Other` に綴りのまま入れる。
pub type Permission {
  /// `sign_event`。すべての kind の署名を許す。
  SignAnyKind
  /// `sign_event:<kind>`。その kind の署名だけを許す。`kind` の綴りは `int.to_string` の形に限る。
  SignKind(kind: Int)
  /// `nip44_encrypt`。
  Nip44Encrypt
  /// `nip44_decrypt`。
  Nip44Decrypt
  /// そのほかのトークン（`get_public_key`、`nip04_encrypt`、`sign_event:01` など）。
  Other(token: String)
}

/// 無宣言（`perms` が空）のセッションに既定で許す権限。kind 24133 の署名はエンジンの
/// `sign_event` の検査が別に拒否する。
const defaults = [SignAnyKind, Nip44Encrypt, Nip44Decrypt]

/// カンマ区切りの `perms` を権限の並びにする。順も重複もそのまま残す。空文字列は無宣言として
/// 空の一覧にし、`","` のような空のトークンは `Other("")` にする。`to_string` で元の文字列に
/// 戻る。
pub fn parse(perms: String) -> List(Permission) {
  case perms {
    "" -> []
    _ -> string.split(perms, ",") |> list.map(from_token)
  }
}

/// トークン 1 つを権限にする。`sign_event:` に続く部分は、整数として読めて `int.to_string` で
/// 同じ綴りに戻るとき（`1`、`-1`）だけ `SignKind` にし、`01`、`+1`、`x`、空は `Other` に
/// 残す。エンジンは NIP-46 の方法名もこれで読む。
pub fn from_token(token: String) -> Permission {
  case token {
    "sign_event" -> SignAnyKind
    "nip44_encrypt" -> Nip44Encrypt
    "nip44_decrypt" -> Nip44Decrypt
    "sign_event:" <> digits ->
      case int.parse(digits) {
        Ok(kind) ->
          case int.to_string(kind) == digits {
            True -> SignKind(kind)
            False -> Other(token)
          }
        Error(Nil) -> Other(token)
      }
    _ -> Other(token)
  }
}

/// 権限 1 つのトークンの綴り。`from_token` の逆である。
pub fn token(permission: Permission) -> String {
  case permission {
    SignAnyKind -> "sign_event"
    SignKind(kind) -> "sign_event:" <> int.to_string(kind)
    Nip44Encrypt -> "nip44_encrypt"
    Nip44Decrypt -> "nip44_decrypt"
    Other(token:) -> token
  }
}

/// 権限の並びをカンマ区切りの `perms` にする。`parse` の逆である。
pub fn to_string(permissions: List(Permission)) -> String {
  permissions |> list.map(token) |> string.join(",")
}

/// `granted`（`parse` の結果）が `wanted` を許すか。`granted` が空（無宣言）なら既定の集合と
/// 照合し、宣言があれば既定の集合は使わない。`SignKind` は同じ kind の `SignKind` か
/// `SignAnyKind` があれば許し、ほかは同じ権限があるときだけ許す。
pub fn allows(granted: List(Permission), wanted: Permission) -> Bool {
  let declared = case granted {
    [] -> defaults
    _ -> granted
  }
  let covered = case wanted {
    SignKind(_) -> list.contains(declared, SignAnyKind)
    _ -> False
  }
  covered || list.contains(declared, wanted)
}

/// バンカーが対応していない方法（NIP-04 の `nip04_encrypt` と `nip04_decrypt`）か。エンジンは
/// 未対応の理由を返し、管理 UI の権限のチップは未対応の印を付ける。
pub fn is_unsupported(permission: Permission) -> Bool {
  case permission {
    Other("nip04_encrypt") | Other("nip04_decrypt") -> True
    _ -> False
  }
}
