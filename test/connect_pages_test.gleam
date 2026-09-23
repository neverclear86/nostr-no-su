//// 管理 UI のクライアントの接続のページと確認のページの描画（`admin/connect_pages`）の単体テスト。

import gleam/option.{type Option, None, Some}
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

/// 確認のページに渡す内容。名前と権限があり、リレーは 2 件。
fn review() -> connect_pages.ConnectReview {
  connect_pages.ConnectReview(
    uri: "nostrconnect://abcd?relay=wss%3A%2F%2Ffirst.example&relay=wss%3A%2F%2Fsecond.example&secret=s",
    signer: "abcd",
    client: "1111111111111111111111111111111111111111111111111111111111111111",
    client_name: Some("example"),
    perms: "sign_event:1",
    relays: ["wss://first.example", "wss://second.example"],
  )
}

/// 確認のページの署名者に当たるアカウント。
fn review_account() -> dashboard.AccountRow {
  dashboard.AccountRow(
    signer: "abcd",
    npub: example_npub,
    label: "main",
    uri: "bunker://abcd?relay=x&secret=s",
    auth_uri: "bunker://abcd?relay=x",
  )
}

/// 英語の確認のページを描く。
fn review_page(
  review: connect_pages.ConnectReview,
  error: Option(i18n.Reason),
) -> String {
  connect_pages.connect_review_page(
    i18n.English,
    view.System,
    [review_account()],
    review,
    error,
  )
}

/// URI のリレーは URI に現れた順に 1 行ずつ並び、URI と署名者は隠し欄で送り直す。
pub fn connect_review_page_lists_the_relays_in_order_test() {
  let page = review_page(review(), None)
  assert string.contains(
    page,
    "<li class=\"font-mono text-xs break-all\">wss://first.example</li><li class=\"font-mono text-xs break-all\">wss://second.example</li>",
  )
  assert string.contains(
    page,
    "<input name=\"uri\" type=\"hidden\" value=\""
      <> string.replace(review().uri, "&", "&amp;")
      <> "\">",
  )
  assert string.contains(
    page,
    "<input name=\"signer\" type=\"hidden\" value=\"abcd\">",
  )
}

/// 名乗る名前の行は、名前があるときだけ出す。
pub fn connect_review_page_shows_the_name_only_when_given_test() {
  let label = i18n.text(i18n.English, i18n.ClientName)
  let named = review_page(review(), None)
  assert string.contains(named, label)
  assert string.contains(named, "<dd class=\"break-words\">example</dd>")
  let unnamed =
    review_page(
      connect_pages.ConnectReview(..review(), client_name: None),
      None,
    )
  assert !string.contains(unnamed, label)
}

/// 権限が空のときだけ、許す操作の一文を説明に続ける。
pub fn connect_review_page_explains_empty_permissions_test() {
  let sentence = i18n.text(i18n.English, i18n.NoPermissionsRequested)
  assert !string.contains(review_page(review(), None), sentence)
  assert string.contains(
    review_page(connect_pages.ConnectReview(..review(), perms: ""), None),
    sentence,
  )
}

/// 接続の段で失敗したときは、カードの中に理由を出す。
pub fn connect_review_page_shows_the_failure_in_the_card_test() {
  let reason = i18n.text(i18n.English, i18n.NostrconnectRelayNotConnected)
  let failed =
    review_page(
      review(),
      Some(i18n.Translated(i18n.NostrconnectRelayNotConnected)),
    )
  assert string.contains(failed, reason)
  assert string.contains(failed, "role=\"alert\"")
  assert !string.contains(review_page(review(), None), reason)
}

/// 確認のページはテーマと言語の切り替えを出さない。
pub fn connect_review_page_has_no_switch_test() {
  assert !string.contains(review_page(review(), None), "action=\"/theme\"")
}
