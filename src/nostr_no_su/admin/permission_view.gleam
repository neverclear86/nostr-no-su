//// 管理 UI の権限のチップ。NIP-46 の `perms` をバンカーの権限のモジュールで読み、権限ごとに
//// 人の語と生の値のチップにする。承認待ちのカード、承認済みのセッションの行、権限の編集の
//// ダイアログ、接続の確認のダイアログが使う。
////
//// トークンの解釈と未対応かどうかはバンカーの権限の定義（`bunker/permission` の `parse` と
//// `is_unsupported`）で決め、ここに綴りの一覧を持たない。`admin/view` は `admin/i18n` と
//// `admin/wordmark` 以外の本体のモジュールに依存しないので、バンカーの定義を見るこの部品は
//// 別のモジュールに置く。
////
//// トークンはクライアント由来なので、テキストとして lustre に渡し、エスケープを文字列化に
//// 任せる（`admin/view` の規則に従う）。文言は `admin/i18n` から表示の言語で引く。

import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import nostr_no_su/admin/i18n.{type Language}
import nostr_no_su/admin/view
import nostr_no_su/bunker/permission.{type Permission}

/// 権限 1 つのチップの見せ方。
type Presentation {
  /// バンカーが対応していない方法。点線のチップに「未対応」と生の値を出す。
  Unsupported
  /// 人の語のある権限。語のあとに生の値を出す。
  Named(message: i18n.Message)
  /// 人の語の無い宣言。生の値だけを出す。
  Unnamed
}

/// 権限のチップ。`perms` を `permission.parse` で読んで 1 つずつチップにし、未対応が 1 件以上
/// あれば並びの下に理由を 1 行出す。空なら「権限の要求なし」のチップ 1 つを出す。承認待ちの
/// カードとクライアントの接続の確認のダイアログでは要求された権限を、承認済みのセッションでは
/// 今の権限を出す。
pub fn chips(language: Language, perms: String) -> Element(msg) {
  case permission.parse(perms) {
    [] ->
      view.status_chip(
        view.ToneChip(view.Neutral),
        i18n.text(language, i18n.NoPermissionsRequestedBadge),
      )
    declared -> {
      let note = case list.any(declared, permission.is_unsupported) {
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
          list.map(declared, chip(language, _)),
        ),
        ..note
      ])
    }
  }
}

/// 権限 1 つのチップ。生の値は `permission.token` の綴り（クライアントが送ったトークンと同じ）で
/// 出す。
fn chip(language: Language, declared: Permission) -> Element(msg) {
  let token = permission.token(declared)
  case presentation(declared) {
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

/// 権限の見せ方。すべての kind の署名、0 以上の kind の署名、NIP-44 の暗号化と復号に人の語を
/// 当て、未対応の方法（`permission.is_unsupported`）は未対応の印にし、ほか（負の kind と
/// 0 埋めの kind を含む）は生の値だけにする。
fn presentation(declared: Permission) -> Presentation {
  case declared {
    permission.SignAnyKind -> Named(i18n.PermissionSignAnyKind)
    permission.SignKind(kind) if kind >= 0 ->
      Named(i18n.PermissionSignKind(kind))
    permission.Nip44Encrypt -> Named(i18n.PermissionNip44Encrypt)
    permission.Nip44Decrypt -> Named(i18n.PermissionNip44Decrypt)
    _ ->
      case permission.is_unsupported(declared) {
        True -> Unsupported
        False -> Unnamed
      }
  }
}
