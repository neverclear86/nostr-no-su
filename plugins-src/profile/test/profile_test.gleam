import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleeunit
import profile/page

/// テストランナー。`gleam test` はこのモジュールの `main` から始まる。
pub fn main() -> Nil {
  gleeunit.main()
}

/// `plugin_pages/0` は `key` = `profile`、`title` = `Profile` の 1 件を供給する。
pub fn pages_lists_the_profile_page_test() {
  let decoder = {
    use key <- decode.field("key", decode.string)
    use title <- decode.field("title", decode.string)
    decode.success(#(key, title))
  }
  let assert Ok(entries) = decode.run(page.pages(), decode.list(decoder))
  assert entries == [#("profile", "Profile")]
}

/// 登録アカウントが 0 件のときは、節 1 つに `alert`（`info`）1 つだけを出す。
pub fn content_without_accounts_shows_one_info_alert_test() {
  let description = page.content([], [])
  let assert [only] = page_sections(description)
  let #(title, blocks) = section_shape(only)
  assert title == "Profile"
  let assert [alert] = blocks
  let #(kind, text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert text
    == "No account is registered. Register an account first, then reload this page."
  assert tone == "info"
}

/// サンプルの JSON（8 項目すべてを持つ）。
const sample_content = "{\"name\":\"alice\",\"display_name\":\"Alice\",\"about\":\"hello\",\"picture\":\"https://example.com/p.png\",\"banner\":\"https://example.com/b.png\",\"nip05\":\"alice@example.com\",\"website\":\"https://alice.example\",\"lud16\":\"alice@wallet.example\"}"

/// アカウント 1 件を返す。
fn sample_account() -> page.Account {
  page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice")
}

/// `Found` なら `npub`・`updated`（RFC 3339）と 8 項目がそのまま出る。
pub fn content_shows_all_profile_fields_test() {
  let description =
    page.content([sample_account()], [page.Found(sample_content, 1_700_000_000)])
  let assert [section] = page_sections(description)
  let #(title, blocks) = section_shape(section)
  assert title == "Alice"
  let assert [
    pairs,
    _picture_note,
    _picture_image,
    _banner_note,
    _banner_image,
    fields,
  ] = blocks
  let assert Ok(top_items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert top_items
    == [
      #("npub", "id", "npub1aa"),
      #("updated", "code", "2023-11-14T22:13:20Z"),
    ]
  let assert Ok(field_items) =
    decode.run(
      fields,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert field_items
    == [
      #("name", "text", "alice"),
      #("display_name", "text", "Alice"),
      #("about", "text", "hello"),
      #("picture", "code", "https://example.com/p.png"),
      #("banner", "code", "https://example.com/b.png"),
      #("nip05", "text", "alice@example.com"),
      #("website", "code", "https://alice.example"),
      #("lud16", "code", "alice@wallet.example"),
    ]
}

/// `NotFound` は `npub` と空の `updated` だけを出し、`alert` は出さない。
pub fn content_leaves_fields_empty_when_not_found_test() {
  let description = page.content([sample_account()], [page.NotFound])
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [pairs] = blocks
  let assert Ok(items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert items == [#("npub", "id", "npub1aa"), #("updated", "text", "")]
}

/// `Failed` は `npub` だけの `pairs` と、理由を含む `alert`（`failure`）を出し、
/// 8 項目は出さない。
pub fn content_shows_alert_when_fetch_failed_test() {
  let description =
    page.content([sample_account()], [
      page.Failed("no monitor relay is connected"),
    ])
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [alert, pairs] = blocks
  let #(kind, text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert text
    == "Could not fetch the profile from the relays: no monitor relay is connected"
  assert tone == "failure"
  let assert Ok(items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert items == [#("npub", "id", "npub1aa")]
}

/// 2 件中 1 件が `Failed` でも、他方の 8 項目はそのまま出る。
pub fn content_keeps_other_accounts_when_one_failed_test() {
  let accounts = [
    sample_account(),
    page.Account(pubkey: "bb", npub: "npub1bb", label: "Bob"),
  ]
  let fetched = [
    page.Failed("no monitor relay is connected"),
    page.Found(sample_content, 1_700_000_000),
  ]
  let description = page.content(accounts, fetched)
  let assert [alice_section, bob_section] = page_sections(description)
  let #(alice_title, alice_blocks) = section_shape(alice_section)
  assert alice_title == "Alice"
  let assert [_alert, _pairs] = alice_blocks
  let #(bob_title, bob_blocks) = section_shape(bob_section)
  assert bob_title == "Bob"
  assert list.length(bob_blocks) == 6
}

/// `content` が JSON のオブジェクトとして読めないと、その旨の `alert`（`failure`）
/// を出し、8 項目は出さない。
pub fn content_shows_alert_when_content_is_not_json_test() {
  let description =
    page.content([sample_account()], [page.Found("[1,2,3]", 1_700_000_000)])
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [alert, _pairs] = blocks
  let #(kind, text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert text
    == "The latest kind 0 event has a content that is not a JSON object."
  assert tone == "failure"
}

/// `picture` だけが空のとき、`banner` の `note` と `image` だけが 1 件ずつ出る。
pub fn content_omits_image_when_url_is_empty_test() {
  let content =
    "{\"name\":\"a\",\"display_name\":\"\",\"about\":\"\",\"picture\":\"\",\"banner\":\"https://example.com/b.png\",\"nip05\":\"\",\"website\":\"\",\"lud16\":\"\"}"
  let description =
    page.content([sample_account()], [page.Found(content, 1_700_000_000)])
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [_pairs, note, image, _fields] = blocks
  let assert Ok(#(note_type, note_text)) =
    decode.run(note, {
      use kind <- decode.field("type", decode.string)
      use text <- decode.field("text", decode.string)
      decode.success(#(kind, text))
    })
  assert note_type == "note"
  assert note_text == "Banner"
  let assert Ok(#(image_type, url, alt)) =
    decode.run(image, {
      use kind <- decode.field("type", decode.string)
      use url <- decode.field("url", decode.string)
      use alt <- decode.field("alt", decode.string)
      decode.success(#(kind, url, alt))
    })
  assert image_type == "image"
  assert url == "https://example.com/b.png"
  assert alt == "Banner of Alice"
}

/// 8 項目をすべて持つ JSON から、そのまま読める。
pub fn profile_of_json_reads_all_eight_fields_test() {
  assert page.profile_of_json(sample_content)
    == Ok(page.Profile(
      name: "alice",
      display_name: "Alice",
      about: "hello",
      picture: "https://example.com/p.png",
      banner: "https://example.com/b.png",
      nip05: "alice@example.com",
      website: "https://alice.example",
      lud16: "alice@wallet.example",
    ))
}

/// 欠けたキーと `null` は空文字列になり、他のキーは読める。
pub fn profile_of_json_treats_missing_and_non_string_as_empty_test() {
  let content = "{\"name\":\"alice\",\"about\":null}"
  assert page.profile_of_json(content)
    == Ok(page.Profile(
      name: "alice",
      display_name: "",
      about: "",
      picture: "",
      banner: "",
      nip05: "",
      website: "",
      lud16: "",
    ))
}

/// 壊れた JSON は `Error(Nil)`。
pub fn profile_of_json_rejects_broken_json_test() {
  assert page.profile_of_json("not json") == Error(Nil)
}

/// `Accounts` の値（JSON 文字列）から `pubkey`・`npub`・`label` を読む。壊れた
/// JSON なら `[]`。
pub fn accounts_returns_empty_list_for_broken_json_test() {
  let json_text =
    "[{\"pubkey\":\"aa\",\"npub\":\"npub1aa\",\"label\":\"Alice\"}]"
  assert page.accounts(json_text)
    == [page.Account(pubkey: "aa", npub: "npub1aa", label: "Alice")]
  assert page.accounts("not json") == []
}

/// `fetch_profiles/1` が返す map の 3 つの status を読む。未知の map は `Failed`。
pub fn fetched_reads_the_three_statuses_test() {
  assert page.fetched(
      dynamic.properties([
        #(dynamic.string("status"), dynamic.string("found")),
        #(dynamic.string("content"), dynamic.string("{}")),
        #(dynamic.string("created_at"), dynamic.int(1_700_000_000)),
      ]),
    )
    == page.Found("{}", 1_700_000_000)
  assert page.fetched(
      dynamic.properties([
        #(dynamic.string("status"), dynamic.string("not_found")),
      ]),
    )
    == page.NotFound
  assert page.fetched(
      dynamic.properties([
        #(dynamic.string("status"), dynamic.string("error")),
        #(dynamic.string("reason"), dynamic.string("timeout")),
      ]),
    )
    == page.Failed("timeout")
  // status が 3 つのいずれでもない map も、map として読めない値も、同じ理由の Failed。
  assert page.fetched(
      dynamic.properties([#(dynamic.string("status"), dynamic.string("weird"))]),
    )
    == page.Failed("the plugin API returned an unexpected value")
  assert page.fetched(dynamic.string("nope"))
    == page.Failed("the plugin API returned an unexpected value")
}

/// 記述の `sections` を取り出す。
fn page_sections(description: Dynamic) -> List(Dynamic) {
  let assert Ok(sections) =
    decode.run(
      description,
      decode.field("sections", decode.list(decode.dynamic), decode.success),
    )
  sections
}

/// 節の `title` と `blocks`。
fn section_shape(raw: Dynamic) -> #(String, List(Dynamic)) {
  let assert Ok(shape) =
    decode.run(raw, {
      use title <- decode.field("title", decode.string)
      use blocks <- decode.field("blocks", decode.list(decode.dynamic))
      decode.success(#(title, blocks))
    })
  shape
}

/// `alert` ブロックの `type` / `text` / `tone`。
fn alert_shape(raw: Dynamic) -> #(String, String, String) {
  let assert Ok(shape) =
    decode.run(raw, {
      use kind <- decode.field("type", decode.string)
      use text <- decode.field("text", decode.string)
      use tone <- decode.field("tone", decode.string)
      decode.success(#(kind, text, tone))
    })
  shape
}

/// `pairs` ブロックの 1 項目。`term` と、値の `type` / `text`。
fn pair_item_decoder() -> decode.Decoder(#(String, String, String)) {
  use term <- decode.field("term", decode.string)
  use kind <- decode.subfield(["value", "type"], decode.string)
  use text <- decode.subfield(["value", "text"], decode.string)
  decode.success(#(term, kind, text))
}
