//// 管理 UI のクライアントの接続のページの描画（`admin/connect_pages`）の単体テスト。

import gleam/option.{None}
import gleam/string
import nostr_no_su/admin/connect_pages
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view

/// 実寸の npub（63 文字）。`view.shorten` が省略することを検査できるよう、`"npub1example"`
/// のような短い値は使わない。
const example_npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

/// 署名者の選択欄には、ラベルと省略した npub を並べて出す。
pub fn connect_page_lists_accounts_with_the_shortened_npub_test() {
  let row =
    dashboard.AccountRow(
      signer: "abcd",
      npub: example_npub,
      label: "main",
      uri: "bunker://abcd?relay=x&secret=s",
      auth_uri: "bunker://abcd?relay=x",
    )
  let page =
    connect_pages.connect_client_page(
      i18n.English,
      view.System,
      Ok([row]),
      "",
      "",
      None,
    )
  assert string.contains(
    page,
    "main " <> view.shorten(example_npub) <> "</option>",
  )
}
