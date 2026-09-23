import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit
import profile
import profile/i18n
import profile/page

/// テストランナー。`gleam test` はこのモジュールの `main` から始まる。
pub fn main() -> Nil {
  gleeunit.main()
}

/// `plugin_pages/2` は `key` = `profile` の 1 件を供給し、`title` は `en` と
/// 知らない言語のコード（`fr`）で `Profile`、`ja` で `プロフィール`。
pub fn plugin_pages_titles_the_page_in_each_language_test() {
  let entries = fn(code) {
    let decoder = {
      use key <- decode.field("key", decode.string)
      use title <- decode.field("title", decode.string)
      decode.success(#(key, title))
    }
    let assert Ok(entries) =
      decode.run(
        profile.plugin_pages(dynamic.properties([]), code),
        decode.list(decoder),
      )
    entries
  }
  assert entries("en") == [#("profile", "Profile")]
  assert entries("fr") == [#("profile", "Profile")]
  assert entries("ja") == [#("profile", "プロフィール")]
}

/// `plugin_page_content/3` は最後の引数の言語のコードで記述を組む。`ja` は
/// 日本語、知らない言語のコード（`fr`）は英語。
pub fn plugin_page_content_follows_the_display_language_test() {
  let config = config_with_accounts([])
  assert profile.plugin_page_content(dynamic.string("profile"), config, "ja")
    == page.content(i18n.Japanese, [], [], [])
  assert profile.plugin_page_content(dynamic.string("profile"), config, "fr")
    == page.content(i18n.English, [], [], [])
}

/// 全状態の文言を英語で描くと、今までどおりの英語の全文が出る順に並ぶ。
pub fn content_texts_in_english_test() {
  assert all_states_texts(i18n.English)
    == [
      "Profile",
      "No account is registered. Register an account first, then reload this page.",
      "Alice",
      "Profile updated.",
      "npub",
      "updated",
      "Picture",
      "Picture of Alice",
      "Banner",
      "Banner of Alice",
      "Save",
      "Bob",
      "Could not update the profile: timeout",
      "No kind 0 event was found on the relays. Sending this form publishes a new profile with only the fields below.",
      "npub",
      "Save",
      "Carol",
      "Could not fetch the profile from the relays (reason: timeout). The edit form is not shown because the current profile is unknown.",
      "npub",
      "Dave",
      "The latest kind 0 event has a content that is not a JSON object.",
      "npub",
      "updated",
      "Save",
    ]
}

/// 全状態の文言を日本語で描くと、日本語の全文が出る順に並ぶ（`npub` と理由の
/// `timeout` はそのまま）。
pub fn content_texts_in_japanese_test() {
  assert all_states_texts(i18n.Japanese)
    == [
      "プロフィール",
      "アカウントが登録されていません。先にアカウントを登録してから、このページを開き直してください。",
      "Alice",
      "プロフィールを更新しました。",
      "npub",
      "更新日時",
      "アイコン画像",
      "Alice のアイコン画像",
      "バナー画像",
      "Alice のバナー画像",
      "保存する",
      "Bob",
      "プロフィールを更新できませんでした（理由: timeout）。",
      "リレーに kind 0 のイベントがありませんでした。このフォームを送ると、下の項目だけを持つ新しいプロフィールを送信します。",
      "npub",
      "保存する",
      "Carol",
      "リレーからプロフィールを取得できませんでした（理由: timeout）。現在のプロフィールが分からないため、編集のフォームは出しません。",
      "npub",
      "Dave",
      "最新の kind 0 のイベントの content が JSON のオブジェクトではありません。",
      "npub",
      "更新日時",
      "保存する",
    ]
}

/// 登録アカウントが 0 件のときは、節 1 つに `alert`（`info`）1 つだけを出す。
pub fn content_without_accounts_shows_one_info_alert_test() {
  let description = page.content(i18n.English, [], [], [])
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

/// `Found` の節はブロックが `pairs` / `note` / `image` / `note` / `image` /
/// `form` の順で、`form` の 8 欄の `type` と `name` と `value` が取得した
/// プロフィールと一致する。
pub fn content_shows_the_edit_form_test() {
  let description =
    page.content(
      i18n.English,
      [sample_account()],
      [page.Found(sample_content, 1_700_000_000)],
      [None],
    )
  let assert [section] = page_sections(description)
  let #(title, blocks) = section_shape(section)
  assert title == "Alice"
  assert list.map(blocks, block_type)
    == ["pairs", "note", "image", "note", "image", "form"]
  let assert [
    pairs,
    _picture_note,
    _picture_image,
    _banner_note,
    _banner_image,
    form,
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
  assert form_fields(form)
    == [
      #("text", "aa-name", "alice"),
      #("text", "aa-display_name", "Alice"),
      #("textarea", "aa-about", "hello"),
      #("text", "aa-picture", "https://example.com/p.png"),
      #("text", "aa-banner", "https://example.com/b.png"),
      #("text", "aa-nip05", "alice@example.com"),
      #("text", "aa-website", "https://alice.example"),
      #("text", "aa-lud16", "alice@wallet.example"),
    ]
}

/// `about` の欄だけ `type` が `textarea` で、他の 7 欄は `text`。
pub fn content_uses_textarea_for_about_test() {
  let description =
    page.content(
      i18n.English,
      [sample_account()],
      [page.Found(sample_content, 1_700_000_000)],
      [None],
    )
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [_, _, _, _, _, form] = blocks
  assert form_fields(form) |> list.map(fn(field) { field.0 })
    == ["text", "text", "textarea", "text", "text", "text", "text", "text"]
}

/// 欄のラベルは表示の言語の人の読める名前で、補足（`hint`）は kind 0 のキー名。
pub fn content_labels_form_fields_in_each_language_test() {
  let labels = fn(language) {
    let description =
      page.content(language, [sample_account()], [page.NotFound], [None])
    let assert [section] = page_sections(description)
    let #(_title, blocks) = section_shape(section)
    let assert [_alert, _pairs, form] = blocks
    let assert Ok(fields) =
      decode.run(
        form,
        decode.field(
          "fields",
          decode.list({
            use label <- decode.field("label", decode.string)
            use hint <- decode.field("hint", decode.string)
            decode.success(#(label, hint))
          }),
          decode.success,
        ),
      )
    fields
  }
  assert labels(i18n.English)
    == [
      #("Name", "name"),
      #("Display name", "display_name"),
      #("About", "about"),
      #("Icon image URL", "picture"),
      #("Banner image URL", "banner"),
      #("Verified identifier (NIP-05)", "nip05"),
      #("Website", "website"),
      #("Lightning address", "lud16"),
    ]
  assert labels(i18n.Japanese)
    == [
      #("名前", "name"),
      #("表示名", "display_name"),
      #("自己紹介", "about"),
      #("アイコンの画像の URL", "picture"),
      #("バナーの画像の URL", "banner"),
      #("認証の識別子（NIP-05）", "nip05"),
      #("ウェブサイト", "website"),
      #("Lightning アドレス", "lud16"),
    ]
}

/// `NotFound` の節には `warning` の `alert`、`npub` だけの `pairs`（`updated` の
/// 項は出ない）と、値がすべて空の `form` が出る。
pub fn content_shows_empty_form_when_not_found_test() {
  let description =
    page.content(i18n.English, [sample_account()], [page.NotFound], [None])
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [alert, pairs, form] = blocks
  let #(kind, text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert text
    == "No kind 0 event was found on the relays. Sending this form publishes a new profile with only the fields below."
  assert tone == "warning"
  let assert Ok(top_items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert top_items == [#("npub", "id", "npub1aa")]
  assert form_fields(form) |> list.map(fn(field) { field.2 })
    == ["", "", "", "", "", "", "", ""]
}

/// `Failed` の節に `form` が無く、`alert` の文は理由を括弧で区切った全文と一致
/// する（理由の後で次の文がつながらない）。
pub fn content_omits_the_form_when_fetch_failed_test() {
  let description =
    page.content(
      i18n.English,
      [sample_account()],
      [page.Failed("no monitor relay is connected")],
      [None],
    )
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [alert, pairs] = blocks
  let #(kind, text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert text
    == "Could not fetch the profile from the relays (reason: no monitor relay is connected). The edit form is not shown because the current profile is unknown."
  assert tone == "failure"
  let assert Ok(items) =
    decode.run(
      pairs,
      decode.field("items", decode.list(pair_item_decoder()), decode.success),
    )
  assert items == [#("npub", "id", "npub1aa")]
}

/// 2 件中 1 件が `Failed` でも、他方の form は出る。
pub fn content_keeps_other_accounts_when_one_failed_test() {
  let accounts = [
    sample_account(),
    page.Account(pubkey: "bb", npub: "npub1bb", label: "Bob"),
  ]
  let fetched = [
    page.Failed("no monitor relay is connected"),
    page.Found(sample_content, 1_700_000_000),
  ]
  let description = page.content(i18n.English, accounts, fetched, [None, None])
  let assert [alice_section, bob_section] = page_sections(description)
  let #(alice_title, alice_blocks) = section_shape(alice_section)
  assert alice_title == "Alice"
  let assert [_alert, _pairs] = alice_blocks
  let #(bob_title, bob_blocks) = section_shape(bob_section)
  assert bob_title == "Bob"
  assert list.length(bob_blocks) == 6
}

/// `content` が JSON のオブジェクトとして読めないと、その旨の `alert`（`failure`）
/// を出し、`form` は空の値で出す。
pub fn content_shows_alert_when_content_is_not_json_test() {
  let description =
    page.content(
      i18n.English,
      [sample_account()],
      [page.Found("[1,2,3]", 1_700_000_000)],
      [None],
    )
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [alert, _pairs, form] = blocks
  let #(kind, text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert text
    == "The latest kind 0 event has a content that is not a JSON object."
  assert tone == "failure"
  assert form_fields(form) |> list.map(fn(field) { field.2 })
    == ["", "", "", "", "", "", "", ""]
}

/// `Some(Succeeded)` を渡すと節の先頭に `tone` = `success` の `alert` が
/// 1 つ出る。
pub fn content_shows_success_alert_after_submit_test() {
  let description =
    page.content(
      i18n.English,
      [sample_account()],
      [page.Found(sample_content, 1_700_000_000)],
      [Some(page.Succeeded)],
    )
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [alert, ..] = blocks
  let #(kind, text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert text == "Profile updated."
  assert tone == "success"
}

/// `Some(SubmitFailed(...))` を渡すと `failure` の `alert` が出て、`form` の
/// 初期値が取得した値ではなく送信された値になる。
pub fn content_refills_the_form_after_a_failed_submit_test() {
  let submitted_values =
    page.Profile(
      name: "bob",
      display_name: "",
      about: "",
      picture: "",
      banner: "",
      nip05: "",
      website: "",
      lud16: "",
    )
  let description =
    page.content(
      i18n.English,
      [sample_account()],
      [page.Found(sample_content, 1_700_000_000)],
      [
        Some(page.SubmitFailed("timeout", submitted_values)),
      ],
    )
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [
    alert,
    _pairs,
    _picture_note,
    _picture_image,
    _banner_note,
    _banner_image,
    form,
  ] = blocks
  let #(kind, _text, tone) = alert_shape(alert)
  assert kind == "alert"
  assert tone == "failure"
  assert form_fields(form) |> list.map(fn(field) { field.2 })
    == ["bob", "", "", "", "", "", "", ""]
}

/// `picture` だけが空のとき、`banner` の `note` と `image` だけが 1 件ずつ出る。
pub fn content_omits_image_when_url_is_empty_test() {
  let content =
    "{\"name\":\"a\",\"display_name\":\"\",\"about\":\"\",\"picture\":\"\",\"banner\":\"https://example.com/b.png\",\"nip05\":\"\",\"website\":\"\",\"lud16\":\"\"}"
  let description =
    page.content(
      i18n.English,
      [sample_account()],
      [page.Found(content, 1_700_000_000)],
      [None],
    )
  let assert [section] = page_sections(description)
  let #(_title, blocks) = section_shape(section)
  let assert [_pairs, note, image, _form] = blocks
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

/// `<公開鍵>-<項目名>` の 8 件から `Submitted` を組み立てる。届かない項目は
/// 空文字列。
pub fn submitted_reads_the_pubkey_and_fields_test() {
  let values =
    dict.from_list([
      #("aa-name", "alice"),
      #("aa-display_name", "Alice"),
      #("aa-picture", "https://example.com/p.png"),
      #("aa-banner", "https://example.com/b.png"),
      #("aa-nip05", "alice@example.com"),
      #("aa-website", "https://alice.example"),
      #("aa-lud16", "alice@wallet.example"),
    ])
  let assert Ok(submitted) = page.submitted(values)
  assert submitted.pubkey == "aa"
  assert submitted.profile
    == page.Profile(
      name: "alice",
      display_name: "Alice",
      about: "",
      picture: "https://example.com/p.png",
      banner: "https://example.com/b.png",
      nip05: "alice@example.com",
      website: "https://alice.example",
      lud16: "alice@wallet.example",
    )
}

/// 8 項目の欄が 1 つも無い送信は `Error`。
pub fn submitted_rejects_a_form_without_profile_fields_test() {
  assert page.submitted(dict.new())
    == Error("the submitted form has no profile field")
}

/// 公開鍵が 2 つ混ざった送信は `Error`。
pub fn submitted_rejects_values_from_several_accounts_test() {
  let values = dict.from_list([#("aa-name", "Alice"), #("bb-name", "Bob")])
  assert page.submitted(values)
    == Error("the submitted form mixes several accounts")
}

/// `profile_store` が返す形の map から `Succeeded` / `SubmitFailed` を読み、
/// 未知の `status` と `none` は `None`。
pub fn submission_reads_the_stored_result_test() {
  let success =
    dynamic.properties([#(dynamic.string("status"), dynamic.string("ok"))])
  assert page.submission(success) == Some(page.Succeeded)

  let failure =
    dynamic.properties([
      #(dynamic.string("status"), dynamic.string("error")),
      #(dynamic.string("reason"), dynamic.string("timeout")),
      #(
        dynamic.string("values"),
        dynamic.properties([
          #(dynamic.string("name"), dynamic.string("bob")),
          #(dynamic.string("display_name"), dynamic.string("")),
          #(dynamic.string("about"), dynamic.string("")),
          #(dynamic.string("picture"), dynamic.string("")),
          #(dynamic.string("banner"), dynamic.string("")),
          #(dynamic.string("nip05"), dynamic.string("")),
          #(dynamic.string("website"), dynamic.string("")),
          #(dynamic.string("lud16"), dynamic.string("")),
        ]),
      ),
    ])
  assert page.submission(failure)
    == Some(page.SubmitFailed(
      reason: "timeout",
      values: page.Profile(
        name: "bob",
        display_name: "",
        about: "",
        picture: "",
        banner: "",
        nip05: "",
        website: "",
        lud16: "",
      ),
    ))

  let unknown_status =
    dynamic.properties([#(dynamic.string("status"), dynamic.string("weird"))])
  assert page.submission(unknown_status) == None

  // `none`（本来は profile_store:take/1 が返す atom）に相当する、map として
  // 読めない Dynamic。
  assert page.submission(dynamic.string("none")) == None
}

/// 未知のキーが残り、指定した項目だけが差し替わる。
pub fn merged_content_keeps_unknown_keys_test() {
  let result =
    page.merged_content("{\"name\":\"old\",\"custom\":\"kept\"}", [
      #("name", "new"),
    ])
  let assert Ok(name) =
    json.parse(result, decode.field("name", decode.string, decode.success))
  assert name == "new"
  let assert Ok(custom) =
    json.parse(result, decode.field("custom", decode.string, decode.success))
  assert custom == "kept"
}

/// 空の値の項目はキーごと消え、`content` が JSON のオブジェクトでないときは
/// 指定した項目だけの JSON になる。
pub fn merged_content_removes_empty_fields_test() {
  let result =
    page.merged_content("{\"name\":\"old\",\"about\":\"bio\"}", [
      #("name", "new"),
      #("about", ""),
    ])
  let assert Ok(name) =
    json.parse(result, decode.field("name", decode.string, decode.success))
  assert name == "new"
  assert !has_key(result, "about")

  let broken_result = page.merged_content("not json", [#("name", "new")])
  let assert Ok(broken_name) =
    json.parse(
      broken_result,
      decode.field("name", decode.string, decode.success),
    )
  assert broken_name == "new"
  let assert Ok(broken_keys) =
    json.parse(broken_result, decode.dict(decode.string, decode.dynamic))
  assert dict.size(broken_keys) == 1
}

/// `json_text` がオブジェクトとして `key` を持つか。
fn has_key(json_text: String, key: String) -> Bool {
  case
    json.parse(json_text, decode.field(key, decode.dynamic, decode.success))
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// `profile_store:start_link/0` を起こし、`put` した結果が `take` で 1 度だけ
/// 返り、2 度目と未登録の公開鍵は `none` になる。
pub fn store_takes_the_result_once_test() {
  let _started = store_start_link()
  let stored =
    dynamic.properties([#(dynamic.string("status"), dynamic.string("ok"))])
  let _put_result = store_put("aa", stored)
  assert page.submission(store_take("aa")) == Some(page.Succeeded)
  assert page.submission(store_take("aa")) == None
  assert page.submission(store_take("bb")) == None
}

/// 本体が無い（`fetch_events` が `undef` になる）環境では、全員が
/// `the plugin API is not installed` の `Failed` になり、空のリストは `[]` を
/// 返す。
pub fn fetch_profiles_without_the_host_reports_the_reason_test() {
  assert list.map(ffi_fetch_profiles(["aa", "bb"]), page.fetched)
    == [
      page.Failed("the plugin API is not installed"),
      page.Failed("the plugin API is not installed"),
    ]
  assert ffi_fetch_profiles([]) == []
}

/// `fetch_events` の `{ok, Results}` の要素 1 件ずつを `NotFound` / `Found` /
/// `Failed` に変換する。
pub fn profiles_from_reply_reads_each_result_test() {
  let reply =
    dynamic.array([
      atom("ok"),
      dynamic.list([
        dynamic.array([atom("ok"), atom("none")]),
        dynamic.array([
          atom("ok"),
          dynamic.properties([
            #(dynamic.string("content"), dynamic.string("{}")),
            #(dynamic.string("created_at"), dynamic.int(7)),
          ]),
        ]),
        dynamic.array([
          atom("error"),
          dynamic.string("account is not registered"),
        ]),
      ]),
    ])
  assert list.map(
      ffi_profiles_from_reply(["aa", "bb", "cc"], reply),
      page.fetched,
    )
    == [
      page.NotFound,
      page.Found("{}", 7),
      page.Failed("account is not registered"),
    ]
}

/// `{error, Reason}` は全員に同じ理由の `Failed` を返す。`{ok, Results}` の
/// 件数が `Pubkeys` と違うときは全員に `the plugin API returned an unexpected
/// value` の `Failed` を返す。
pub fn profiles_from_reply_spreads_a_failure_to_every_pubkey_test() {
  let failure =
    dynamic.array([
      atom("error"),
      dynamic.string("no monitor relay is connected"),
    ])
  assert list.map(ffi_profiles_from_reply(["aa", "bb"], failure), page.fetched)
    == [
      page.Failed("no monitor relay is connected"),
      page.Failed("no monitor relay is connected"),
    ]
  let short =
    dynamic.array([
      atom("ok"),
      dynamic.list([dynamic.array([atom("ok"), atom("none")])]),
    ])
  assert list.map(ffi_profiles_from_reply(["aa", "bb"], short), page.fetched)
    == [
      page.Failed("the plugin API returned an unexpected value"),
      page.Failed("the plugin API returned an unexpected value"),
    ]
}

/// 期限内のキャッシュがあるアカウントはリレーに問い合わせず（本体が無くても
/// `Found` が出る）、キャッシュに無いアカウントは取り直す。取り直しに失敗した
/// アカウントはキャッシュされないので、直後の `cache_get` は `none` を返す。
pub fn page_content_uses_the_cache_within_its_lifetime_test() {
  let _started = store_start_link()
  let _put = store_cache_put("c1", page.Found("{}", 1), 60_000)
  assert profile.plugin_page_content(
      dynamic.string("profile"),
      config_with_accounts([
        #("c1", "npub1c1", "C1"),
        #("c2", "npub1c2", "C2"),
      ]),
      "en",
    )
    == page.content(
      i18n.English,
      [
        page.Account(pubkey: "c1", npub: "npub1c1", label: "C1"),
        page.Account(pubkey: "c2", npub: "npub1c2", label: "C2"),
      ],
      [page.Found("{}", 1), page.Failed("the plugin API is not installed")],
      [None, None],
    )
  assert store_cache_get(["c2"]) == [None]
}

/// 期限の過ぎたキャッシュ（TTL 0）は使われず、ページは取り直しに行く（本体が
/// 無いので `Failed` になる）。
pub fn page_content_fetches_again_after_the_lifetime_test() {
  let _started = store_start_link()
  let _put = store_cache_put("c3", page.Found("{}", 1), 0)
  assert profile.plugin_page_content(
      dynamic.string("profile"),
      config_with_accounts([#("c3", "npub1c3", "C3")]),
      "en",
    )
    == page.content(
      i18n.English,
      [page.Account(pubkey: "c3", npub: "npub1c3", label: "C3")],
      [page.Failed("the plugin API is not installed")],
      [None],
    )
}

/// 送信に成功すると、送った kind 0 と本体が付けた `created_at` が `Found` と
/// してキャッシュに入り、結果は `profile_store` に保持される。
pub fn finish_submission_caches_the_published_profile_test() {
  let _started = store_start_link()
  let published =
    dynamic.properties([
      #(dynamic.string("status"), dynamic.string("ok")),
      #(dynamic.string("reason"), dynamic.string("")),
      #(dynamic.string("created_at"), dynamic.int(123)),
    ])
  let _finished =
    profile.finish_submission("c4", "{\"name\":\"x\"}", [], published)
  assert store_cache_get(["c4"]) == [Some(page.Found("{\"name\":\"x\"}", 123))]
  assert page.submission(store_take("c4")) == Some(page.Succeeded)
}

/// 本体の送信が `status` = `error`、`reason` = `timeout` を返すと、保持した
/// 結果は理由と送信した値を持つ `SubmitFailed` になる（文言は保持しない）。
pub fn finish_submission_keeps_the_failure_reason_test() {
  let _started = store_start_link()
  let published =
    dynamic.properties([
      #(dynamic.string("status"), dynamic.string("error")),
      #(dynamic.string("reason"), dynamic.string("timeout")),
      #(dynamic.string("created_at"), dynamic.int(0)),
    ])
  let submitted =
    page.Profile(
      name: "x",
      display_name: "",
      about: "",
      picture: "",
      banner: "",
      nip05: "",
      website: "",
      lud16: "",
    )
  let fields =
    page.submitted_fields(page.Submitted(pubkey: "c5", profile: submitted))
  let _finished =
    profile.finish_submission("c5", "{\"name\":\"x\"}", fields, published)
  assert page.submission(store_take("c5"))
    == Some(page.SubmitFailed(reason: "timeout", values: submitted))
}

/// `profile_store:start_link/0` の `@external`。テストのモジュールに置く
/// （実装時の条件 2）。
@external(erlang, "profile_store", "start_link")
fn store_start_link() -> Dynamic

/// `profile_store:put/2` の `@external`。テストのモジュールに置く。
@external(erlang, "profile_store", "put")
fn store_put(pubkey: String, result: Dynamic) -> Dynamic

/// `profile_store:take/1` の `@external`。テストのモジュールに置く。
@external(erlang, "profile_store", "take")
fn store_take(pubkey: String) -> Dynamic

/// `profile_store:cache_put/3` の `@external`。テストのモジュールに置く。
@external(erlang, "profile_store", "cache_put")
fn store_cache_put(
  pubkey: String,
  profile: page.Fetched,
  ttl_ms: Int,
) -> Dynamic

/// `profile_store:cache_get/1` の `@external`。テストのモジュールに置く。
@external(erlang, "profile_store", "cache_get")
fn store_cache_get(pubkeys: List(String)) -> List(Option(page.Fetched))

/// `profile_ffi:fetch_profiles/1` の `@external`。テストのモジュールに置く。
@external(erlang, "profile_ffi", "fetch_profiles")
fn ffi_fetch_profiles(pubkeys: List(String)) -> List(Dynamic)

/// `profile_ffi:profiles_from_reply/2` の `@external`。テストのモジュールに
/// 置く。
@external(erlang, "profile_ffi", "profiles_from_reply")
fn ffi_profiles_from_reply(
  pubkeys: List(String),
  reply: Dynamic,
) -> List(Dynamic)

/// `erlang:binary_to_atom/1`。`fetch_events` の戻り値の `{ok, none}` などを
/// 組むのに使う。
@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Dynamic

/// `plugin_page_content` の `config`（`Accounts` にアカウントの配列の JSON
/// 文字列を持つ `dynamic.properties`）。アカウントは `#(pubkey, npub, label)`
/// の組で渡す。
fn config_with_accounts(accounts: List(#(String, String, String))) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("Accounts"), dynamic.string(accounts_json(accounts))),
  ])
}

/// `#(pubkey, npub, label)` の組のリストを `Accounts` の値（JSON 文字列）に
/// する。
fn accounts_json(accounts: List(#(String, String, String))) -> String {
  json.array(accounts, fn(account) {
    json.object([
      #("pubkey", json.string(account.0)),
      #("npub", json.string(account.1)),
      #("label", json.string(account.2)),
    ])
  })
  |> json.to_string
}

/// `content_texts_in_english_test` と `content_texts_in_japanese_test` が描く
/// 状態の文言。アカウント無しの記述と、4 件のアカウント（Alice は成功の送信の後の
/// `Found`（`content` は `picture` と `banner` を持つ `sample_content`）、Bob は
/// 失敗の送信の後の `NotFound`、Carol は `Failed`、Dave は JSON でない
/// `content`）の記述を `language` で描き、`page_texts` を続けて返す。
fn all_states_texts(language: i18n.Language) -> List(String) {
  let empty_values =
    page.Profile(
      name: "",
      display_name: "",
      about: "",
      picture: "",
      banner: "",
      nip05: "",
      website: "",
      lud16: "",
    )
  let accounts = [
    sample_account(),
    page.Account(pubkey: "bb", npub: "npub1bb", label: "Bob"),
    page.Account(pubkey: "cc", npub: "npub1cc", label: "Carol"),
    page.Account(pubkey: "dd", npub: "npub1dd", label: "Dave"),
  ]
  let fetched = [
    page.Found(sample_content, 1_700_000_000),
    page.NotFound,
    page.Failed("timeout"),
    page.Found("[1,2,3]", 1_700_000_000),
  ]
  let submissions = [
    Some(page.Succeeded),
    Some(page.SubmitFailed("timeout", empty_values)),
    None,
    None,
  ]
  list.append(
    page_texts(page.content(language, [], [], [])),
    page_texts(page.content(language, accounts, fetched, submissions)),
  )
}

/// 記述の中の、表示の言語で出る文言を出る順に並べる。節ごとに見出し、続けて
/// ブロックごとに `alert` と `note` の `text`、`image` の `alt`、`pairs` の各項の
/// `term`、`form` の `submit` を並べる（欄のラベルは
/// `content_labels_form_fields_in_each_language_test` で見る）。
fn page_texts(description: Dynamic) -> List(String) {
  list.flat_map(page_sections(description), fn(raw) {
    let #(title, blocks) = section_shape(raw)
    [title, ..list.flat_map(blocks, block_texts)]
  })
}

/// ブロック 1 つの文言（`page_texts` を参照）。
fn block_texts(raw: Dynamic) -> List(String) {
  let field = fn(name) {
    let assert Ok(value) =
      decode.run(raw, decode.field(name, decode.string, decode.success))
    [value]
  }
  case block_type(raw) {
    "alert" | "note" -> field("text")
    "image" -> field("alt")
    "form" -> field("submit")
    "pairs" -> {
      let assert Ok(items) =
        decode.run(
          raw,
          decode.field(
            "items",
            decode.list(pair_item_decoder()),
            decode.success,
          ),
        )
      list.map(items, fn(item) { item.0 })
    }
    _ -> []
  }
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

/// ブロックの `type`。
fn block_type(raw: Dynamic) -> String {
  let assert Ok(kind) =
    decode.run(raw, decode.field("type", decode.string, decode.success))
  kind
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

/// `form` ブロックの `fields`。欄ごとに `type` / `name` / `value`。
fn form_fields(raw: Dynamic) -> List(#(String, String, String)) {
  let assert Ok(fields) =
    decode.run(
      raw,
      decode.field("fields", decode.list(form_field_decoder()), decode.success),
    )
  fields
}

/// `form` の欄 1 件の `type` / `name` / `value`。
fn form_field_decoder() -> decode.Decoder(#(String, String, String)) {
  use kind <- decode.field("type", decode.string)
  use name <- decode.field("name", decode.string)
  use value <- decode.field("value", decode.string)
  decode.success(#(kind, name, value))
}
