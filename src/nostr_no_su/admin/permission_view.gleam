//// 管理 UI の権限のチップ。NIP-46 の `perms`（カンマ区切りのトークン）を、トークンごとに
//// 人の語と生の値のチップにする。承認待ちのカード、承認済みのセッションの行、権限の編集の
//// ダイアログ、接続の確認のダイアログが使う。
////
//// 未対応かどうかはバンカーのエンジンの定義（`bunker/engine.is_unsupported_permission`）で
//// 決め、ここに一覧を持たない。`admin/view` は `admin/i18n` と `admin/wordmark` 以外の本体の
//// モジュールに依存しないので、エンジンを見るこの部品は別のモジュールに置く。
////
//// トークンはクライアント由来なので、テキストとして lustre に渡し、エスケープを文字列化に
//// 任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から表示の言語で引く。

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view
import nostr_no_su/bunker/engine

/// 権限のトークン 1 つのチップの見せ方。
type Presentation {
  /// バンカーが対応していない方法。点線のチップに「未対応」と生の値を出す。
  Unsupported
  /// 人の語のある権限。語のあとに生の値を出す。
  Named(message: i18n.Message)
  /// 人の語の無い宣言。生の値だけを出す。
  Unnamed
}

/// 権限のチップ。カンマ区切りの値を 1 つずつチップにし、未対応が 1 件以上あれば並びの下に
/// 理由を 1 行出す。空なら「権限の要求なし」のチップ 1 つを出す。承認待ちのカードとクライアントの
/// 接続の確認のダイアログでは要求された権限を、承認済みのセッションでは今の権限を出す。
pub fn chips(language: Language, perms: String) -> Element(msg) {
  case perms {
    "" ->
      view.status_chip(
        view.ToneChip(view.Neutral),
        i18n.text(language, i18n.NoPermissionsRequestedBadge),
      )
    _ -> {
      let tokens = string.split(perms, ",")
      let note = case list.any(tokens, engine.is_unsupported_permission) {
        True -> [
          html.p([attribute.class("text-xs text-muted")], [
            html.text(i18n.text(language, i18n.UnsupportedPermissionsNote)),
          ]),
        ]
        False -> []
      }
      html.div([attribute.class("flex flex-col items-start gap-1")], [
        html.div(
          [attribute.class("flex flex-wrap gap-1")],
          list.map(tokens, chip(language, _)),
        ),
        ..note
      ])
    }
  }
}

/// 権限のトークン 1 つのチップ。
fn chip(language: Language, token: String) -> Element(msg) {
  case presentation(token) {
    Unsupported ->
      html.span(
        [attribute.class("badge badge-dash badge-sm gap-1 text-muted")],
        [
          html.text(i18n.text(language, i18n.PermissionUnsupported)),
          raw_value(token),
        ],
      )
    Named(message:) ->
      html.span([attribute.class("badge badge-outline badge-sm gap-1")], [
        html.text(i18n.text(language, message)),
        raw_value(token),
      ])
    Unnamed ->
      html.span([attribute.class("badge badge-outline badge-sm font-mono")], [
        view.untranslated(token),
      ])
  }
}

/// チップの中の生の値。クライアントが送ったままの英字なので、等幅で `lang="en"` を付けて出す。
fn raw_value(token: String) -> Element(msg) {
  html.span([attribute.class("font-mono text-muted")], [
    view.untranslated(token),
  ])
}

/// トークンの見せ方。未対応の判定を先に行い、`sign_event`、`nip44_encrypt`、`nip44_decrypt`、
/// `sign_event:<n>` に人の語を当てる。
fn presentation(token: String) -> Presentation {
  case engine.is_unsupported_permission(token), token {
    True, _ -> Unsupported
    False, "sign_event" -> Named(i18n.PermissionSignAnyKind)
    False, "nip44_encrypt" -> Named(i18n.PermissionNip44Encrypt)
    False, "nip44_decrypt" -> Named(i18n.PermissionNip44Decrypt)
    False, _ ->
      case signed_kind(token) {
        Ok(kind) -> Named(i18n.PermissionSignKind(kind))
        Error(Nil) -> Unnamed
      }
  }
}

/// `sign_event:<n>`（`n` は 0 以上の整数）なら `n` を返す。権限の編集のフォームも同じ規則で
/// kind の欄に写す。
pub fn signed_kind(token: String) -> Result(Int, Nil) {
  case token {
    "sign_event:" <> kind ->
      case int.parse(kind) {
        Ok(kind) if kind >= 0 -> Ok(kind)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}
