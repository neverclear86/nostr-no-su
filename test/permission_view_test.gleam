//// 管理 UI の権限のチップ（`admin/permission_view`）の単体テスト。

import gleam/list
import gleam/string
import lustre/element
import nostr_no_su/admin/i18n
import nostr_no_su/admin/permission_view

/// 日本語の権限のチップの HTML。
fn japanese_chips(perms: String) -> String {
  element.to_string(permission_view.chips(i18n.Japanese, perms))
}

/// `nip04_encrypt,nip04_decrypt,nip44_encrypt` で、`nip04_decrypt` が点線のチップに「未対応」と
/// 等幅の生の値で出て、理由の `p` がちょうど 1 つ。`nip44_encrypt` だけなら `p` が無い。
pub fn unsupported_permissions_are_dashed_with_one_reason_test() {
  let html = japanese_chips("nip04_encrypt,nip04_decrypt,nip44_encrypt")
  assert string.contains(
    html,
    "<span class=\"badge badge-dash badge-sm gap-1 text-muted\">未対応<span class=\"font-mono text-muted\"><span lang=\"en\">nip04_decrypt</span></span></span>",
  )
  let note =
    "<p class=\"text-xs text-muted\">「未対応」の権限は、このバンカーが実装していない方法です。許可しても要求は拒否します。</p>"
  assert list.length(string.split(html, note)) == 2
  assert !string.contains(japanese_chips("nip44_encrypt"), "<p")
}

/// 日本語で `sign_event:1` のチップの全文（`投稿の署名` と等幅の生の値）、「すべての kind の
/// 署名」「kind 30023 の署名」「NIP-44 で暗号化」「NIP-44 で復号」が出て、`badge-dash` が無い。
pub fn named_permissions_keep_the_raw_value_test() {
  let html =
    japanese_chips(
      "sign_event:1,sign_event,sign_event:30023,nip44_encrypt,nip44_decrypt",
    )
  assert string.contains(
    html,
    "<span class=\"badge badge-outline badge-sm gap-1\">投稿の署名<span class=\"font-mono text-muted\"><span lang=\"en\">sign_event:1</span></span></span>",
  )
  assert string.contains(html, ">すべての kind の署名<")
  assert string.contains(html, ">kind 30023 の署名<")
  assert string.contains(html, ">NIP-44 で暗号化<")
  assert string.contains(html, ">NIP-44 で復号<")
  assert !string.contains(html, "badge-dash")
}

/// `get_public_key`、`sign_event:-1`、`sign_event:x` は生の値だけのチップで、`Sign ` が出ない。
pub fn unnamed_declarations_show_only_the_raw_value_test() {
  use token <- list.each(["get_public_key", "sign_event:-1", "sign_event:x"])
  let html = element.to_string(permission_view.chips(i18n.English, token))
  assert string.contains(
    html,
    "<span class=\"badge badge-outline badge-sm font-mono\"><span lang=\"en\">"
      <> token
      <> "</span></span>",
  )
  assert !string.contains(html, "Sign ")
}

/// `sign_event:10002` と `sign_event:0` は kind を返し、負の数、数でない値、kind の無い
/// `sign_event`、ほかの方法は `Error(Nil)` を返す。
pub fn signed_kind_reads_only_non_negative_kinds_test() {
  assert permission_view.signed_kind("sign_event:10002") == Ok(10_002)
  assert permission_view.signed_kind("sign_event:0") == Ok(0)
  assert permission_view.signed_kind("sign_event:-1") == Error(Nil)
  assert permission_view.signed_kind("sign_event:x") == Error(Nil)
  assert permission_view.signed_kind("sign_event") == Error(Nil)
  assert permission_view.signed_kind("nip44_encrypt") == Error(Nil)
}
