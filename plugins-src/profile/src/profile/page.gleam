//// 管理 UI のページの記述を組み立てる純粋なモジュール。プロセスにもネットワーク
//// にも触れず、呼び出し元（`profile.gleam`）が読んだ登録アカウントと取得の結果を
//// 引数で受け取って、記述の `Dynamic` を組み立てるだけである。
////
//// 記述の形式は `docs/plugin-api.md` 第 13 章のとおり、段ごとに種別を閉じた 3 段の
//// binary キーの map である。値は `gleam/dynamic` の `properties` / `list` /
//// `string` で組む。`properties` は Erlang では binary キーの map になる。

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

/// プロフィールのページのキー。URL の path 片にもなる。
const profile_page_key = "profile"

/// プロフィールのページの表示名。
const profile_page_title = "Profile"

/// 本体から `Accounts`（`docs/plugin-api.md` 第 13.5 節）で届く登録アカウント 1 件。
pub type Account {
  Account(pubkey: String, npub: String, label: String)
}

/// `Accounts` の値（アカウントの一覧を JSON にした文字列）を読む。JSON として
/// 読めなければ `[]` を返す（`plugin_page_content` に `{error, Reason}` を返す
/// 約束が無いため。`docs/plugin-api.md` 第 13.4 節）。
pub fn accounts(accounts_json: String) -> List(Account) {
  json.parse(accounts_json, decode.list(account_decoder()))
  |> result.unwrap([])
}

/// 登録アカウント 1 件のデコーダー。
fn account_decoder() -> decode.Decoder(Account) {
  use pubkey <- decode.field("pubkey", decode.string)
  use npub <- decode.field("npub", decode.string)
  use label <- decode.field("label", decode.string)
  decode.success(Account(pubkey: pubkey, npub: npub, label: label))
}

/// 公開鍵 1 件の kind 0 の取得の結果。
pub type Fetched {
  /// 最新の kind 0 が見つかった。`content` は生の JSON 文字列。
  Found(content: String, created_at: Int)
  /// そのアカウントに kind 0 が 1 件も無かった。
  NotFound
  /// 取得に失敗した。`reason` は理由の英語の 1 文。
  Failed(reason: String)
}

/// `profile_ffi:fetch_profiles/1` が返す map（`status`・`content`・`created_at`・
/// `reason` を持つ binary キーの map）を読む。`status` が `found` / `not_found` /
/// `error` のいずれでもない、または map として読めなければ `Failed` にする。
pub fn fetched(raw: Dynamic) -> Fetched {
  case decode.run(raw, fetched_decoder()) {
    Ok(fetched) -> fetched
    Error(_errors) -> Failed("the plugin API returned an unexpected value")
  }
}

/// `fetched/1` のデコーダー。
fn fetched_decoder() -> decode.Decoder(Fetched) {
  use status <- decode.field("status", decode.string)
  case status {
    "found" -> {
      use content <- decode.field("content", decode.string)
      use created_at <- decode.field("created_at", decode.int)
      decode.success(Found(content: content, created_at: created_at))
    }
    "not_found" -> decode.success(NotFound)
    "error" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Failed(reason: reason))
    }
    _ -> decode.failure(Failed(""), "Fetched")
  }
}

/// kind 0 の `content` の 8 項目（NIP-01 の慣例のキー名。読めなかった・欠けた・
/// 文字列でない項目は空文字列）。
pub type Profile {
  Profile(
    name: String,
    display_name: String,
    about: String,
    picture: String,
    banner: String,
    nip05: String,
    website: String,
    lud16: String,
  )
}

/// kind 0 の `content`（JSON 文字列）を `Profile` として読む。JSON のオブジェクト
/// として読めなければ `Error(Nil)`。欠けたキー、および値が文字列でないキー
/// （`null` を入れるクライアントがある）は空文字列にする。
pub fn profile_of_json(content: String) -> Result(Profile, Nil) {
  json.parse(content, profile_decoder())
  |> result.replace_error(Nil)
}

/// `profile_of_json/1` のデコーダー。項目ごとに、値が文字列でなければ空文字列に
/// 倒す（`decode.optional_field` だけでは型が合わないときに decoder 全体が失敗し、
/// 他の項目まで空になってしまうため）。
fn profile_decoder() -> decode.Decoder(Profile) {
  use name <- decode.optional_field("name", "", string_or_empty())
  use display_name <- decode.optional_field(
    "display_name",
    "",
    string_or_empty(),
  )
  use about <- decode.optional_field("about", "", string_or_empty())
  use picture <- decode.optional_field("picture", "", string_or_empty())
  use banner <- decode.optional_field("banner", "", string_or_empty())
  use nip05 <- decode.optional_field("nip05", "", string_or_empty())
  use website <- decode.optional_field("website", "", string_or_empty())
  use lud16 <- decode.optional_field("lud16", "", string_or_empty())
  decode.success(Profile(
    name:,
    display_name:,
    about:,
    picture:,
    banner:,
    nip05:,
    website:,
    lud16:,
  ))
}

/// 文字列として読めれば通し、読めなければ空文字列にするデコーダー。
fn string_or_empty() -> decode.Decoder(String) {
  decode.one_of(decode.string, [decode.success("")])
}

/// `plugin_pages/0` が返すページの一覧。プロフィールのページ 1 件だけを持つ。
pub fn pages() -> Dynamic {
  dynamic.list([
    dynamic.properties([
      #(dynamic.string("key"), dynamic.string(profile_page_key)),
      #(dynamic.string("title"), dynamic.string(profile_page_title)),
    ]),
  ])
}

/// ページの記述。`accounts` が空なら `alert`（`info`）1 つだけの節を返す。
/// それ以外はアカウントと取得の結果を組にし、1 件につき `account_section/2` を
/// 返す（`accounts` と `fetched` は同じ順序・同じ件数である前提。呼び出し元
/// （`profile.gleam`）が同じ公開鍵の並びで作る）。
pub fn content(accounts: List(Account), fetched: List(Fetched)) -> Dynamic {
  case accounts {
    [] -> page_sections([no_accounts_section()])
    _ ->
      page_sections(
        list.map2(accounts, fetched, fn(account, fetched) {
          account_section(account, fetched)
        }),
      )
  }
}

/// 登録アカウントが 0 件のときの節。
fn no_accounts_section() -> Dynamic {
  section(profile_page_title, [
    alert_block(
      "No account is registered. Register an account first, then reload this page.",
      "info",
    ),
  ])
}

/// アカウント 1 件の節。`title` はアカウントの `label`。ブロックは取得の結果に
/// 応じて `account_blocks/2` が組む。
fn account_section(account: Account, fetched: Fetched) -> Dynamic {
  section(account.label, account_blocks(account, fetched))
}

/// アカウント 1 件のブロックの並び。上から `alert`（`failure`。content が JSON の
/// オブジェクトとして読めないときだけ）、`npub`・`updated` の `pairs`、画像
/// （`picture` / `banner` が空でなければ）、8 項目の `pairs` の順。`NotFound` は
/// `npub` と空の `updated` だけ、`Failed` は `npub` だけを出す。
fn account_blocks(account: Account, fetched: Fetched) -> List(Dynamic) {
  case fetched {
    Found(content:, created_at:) ->
      case profile_of_json(content) {
        Ok(profile) ->
          [pairs_block([npub_item(account), updated_item(created_at)])]
          |> list.append(image_blocks(account, profile))
          |> list.append([profile_fields_block(profile)])
        Error(Nil) -> [
          alert_block(
            "The latest kind 0 event has a content that is not a JSON object.",
            "failure",
          ),
          pairs_block([npub_item(account), updated_item(created_at)]),
        ]
      }
    NotFound -> [
      pairs_block([npub_item(account), #("updated", text_inline(""))]),
    ]
    Failed(reason:) -> [
      alert_block(
        "Could not fetch the profile from the relays: " <> reason,
        "failure",
      ),
      pairs_block([npub_item(account)]),
    ]
  }
}

/// `pairs` の `npub` の項。
fn npub_item(account: Account) -> #(String, Dynamic) {
  #("npub", id_inline(account.npub))
}

/// `pairs` の `updated` の項（RFC 3339 の UTC、`code` インライン）。
fn updated_item(created_at: Int) -> #(String, Dynamic) {
  #("updated", code_inline(format_timestamp(created_at)))
}

/// `picture` / `banner` が空でなければ `note` と `image` を続けて出す。両方空なら
/// 空リスト。
fn image_blocks(account: Account, profile: Profile) -> List(Dynamic) {
  list.flatten([
    image_with_note(profile.picture, "Picture", "Picture of " <> account.label),
    image_with_note(profile.banner, "Banner", "Banner of " <> account.label),
  ])
}

/// 1 枚の画像の `note` と `image`。`url` が空なら出さない。
fn image_with_note(url: String, label: String, alt: String) -> List(Dynamic) {
  case url {
    "" -> []
    _ -> [note_block(label), image_block(url, alt)]
  }
}

/// kind 0 の 8 項目の `pairs`。`picture`・`banner`・`website`・`lud16` は `code`
/// インライン、他は `text` インライン。
fn profile_fields_block(profile: Profile) -> Dynamic {
  pairs_block([
    #("name", text_inline(profile.name)),
    #("display_name", text_inline(profile.display_name)),
    #("about", text_inline(profile.about)),
    #("picture", code_inline(profile.picture)),
    #("banner", code_inline(profile.banner)),
    #("nip05", text_inline(profile.nip05)),
    #("website", code_inline(profile.website)),
    #("lud16", code_inline(profile.lud16)),
  ])
}

/// Unix 秒を UTC の RFC 3339（`2026-09-22T10:00:00Z`）にする。
@external(erlang, "profile_ffi", "format_timestamp")
fn format_timestamp(seconds: Int) -> String

/// 記述の最上位。`#{"sections" => [節, ...]}`。
fn page_sections(sections: List(Dynamic)) -> Dynamic {
  dynamic.properties([#(dynamic.string("sections"), dynamic.list(sections))])
}

/// 節（`type` = `"section"`）。
fn section(title: String, blocks: List(Dynamic)) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("section")),
    #(dynamic.string("title"), dynamic.string(title)),
    #(dynamic.string("blocks"), dynamic.list(blocks)),
  ])
}

/// `pairs` ブロック。`items` は `term` と、すでに組み立てた `value` のインライン
/// （`text_inline`・`code_inline`・`id_inline`）の対。
fn pairs_block(items: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("pairs")),
    #(
      dynamic.string("items"),
      dynamic.list(
        list.map(items, fn(item) {
          dynamic.properties([
            #(dynamic.string("term"), dynamic.string(item.0)),
            #(dynamic.string("value"), item.1),
          ])
        }),
      ),
    ),
  ])
}

/// `note` ブロック。
fn note_block(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("note")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `image` ブロック。
fn image_block(url: String, alt: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("image")),
    #(dynamic.string("url"), dynamic.string(url)),
    #(dynamic.string("alt"), dynamic.string(alt)),
  ])
}

/// `alert` ブロック。
fn alert_block(text: String, tone: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("alert")),
    #(dynamic.string("text"), dynamic.string(text)),
    #(dynamic.string("tone"), dynamic.string(tone)),
  ])
}

/// `text` インライン。
fn text_inline(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("text")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `code` インライン。
fn code_inline(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("code")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `id` インライン。`pairs` の値だけで使える。
fn id_inline(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("id")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}
