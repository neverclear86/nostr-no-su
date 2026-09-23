//// 管理 UI のページの記述を組み立てる純粋なモジュール。プロセスにもネットワーク
//// にも触れず、呼び出し元（`profile.gleam`）が読んだ登録アカウント・取得の結果・
//// 直前の送信の結果を引数で受け取って記述の `Dynamic` を組み立て、送信された欄の
//// 値の解釈（`submitted/1`）と保持した結果の読み取り（`submission/1`）も担う。
//// 文言は引数の表示の言語（`profile/i18n` の `Language`）で `i18n.text` から引く。
////
//// 記述の形式は `docs/plugin-api.md` 第 13 章のとおり、段ごとに種別を閉じた 3 段の
//// binary キーの map である。値は `gleam/dynamic` の `properties` / `list` /
//// `string` で組む。`properties` は Erlang では binary キーの map になる。

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import profile/i18n.{type Language}

/// プロフィールのページのキー。URL の path 片にもなる。
const profile_page_key = "profile"

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

/// kind 0 の 8 項目の項目名（`form` の欄の `name` の後半、`submitted/1` が読む
/// キー）。この並びが `submitted_fields/1` と `profile_form_block/3` の欄の順に
/// なる。
const profile_field_names = [
  "name", "display_name", "about", "picture", "banner", "nip05", "website",
  "lud16",
]

/// `plugin_page_action` に届いたフォームの送信から取り出した 1 件。`pubkey` は
/// 欄の `name` の前半（決めたこと 5 で検証済み）。
pub type Submitted {
  Submitted(pubkey: String, profile: Profile)
}

/// 送信された欄の `name`（`<公開鍵>-<項目名>`）を割り、公開鍵が 1 つに定まる
/// ことと、8 項目のうち 1 つ以上が届いていることを確かめる。届かなかった項目は
/// 空文字列。`values` に無い名前（8 項目のいずれでもない、または `-` を含まない）
/// の欄は無視する。
pub fn submitted(
  values: dict.Dict(String, String),
) -> Result(Submitted, String) {
  let fields = dict.to_list(values) |> list.filter_map(parse_submitted_field)
  let pubkeys = fields |> list.map(fn(field) { field.0 }) |> list.unique
  case pubkeys {
    [] -> Error("the submitted form has no profile field")
    [pubkey] ->
      Ok(Submitted(pubkey: pubkey, profile: profile_of_fields(fields)))
    _ -> Error("the submitted form mixes several accounts")
  }
}

/// `values` の 1 項目を `#(公開鍵, 項目名, 値)` にする。`name` に `-` が無い、
/// または項目名が 8 項目のいずれでもなければ `Error(Nil)`（`submitted/1` が
/// `filter_map` で捨てる）。
fn parse_submitted_field(
  entry: #(String, String),
) -> Result(#(String, String, String), Nil) {
  let #(name, value) = entry
  case string.split_once(name, "-") {
    Ok(#(pubkey, field)) ->
      case list.contains(profile_field_names, field) {
        True -> Ok(#(pubkey, field, value))
        False -> Error(Nil)
      }
    Error(Nil) -> Error(Nil)
  }
}

/// `parse_submitted_field/1` が返した組から `Profile` を組み立てる。届かなかった
/// 項目は空文字列。
fn profile_of_fields(fields: List(#(String, String, String))) -> Profile {
  let value_of = fn(field) {
    fields
    |> list.find(fn(entry) { entry.1 == field })
    |> result.map(fn(entry) { entry.2 })
    |> result.unwrap("")
  }
  Profile(
    name: value_of("name"),
    display_name: value_of("display_name"),
    about: value_of("about"),
    picture: value_of("picture"),
    banner: value_of("banner"),
    nip05: value_of("nip05"),
    website: value_of("website"),
    lud16: value_of("lud16"),
  )
}

/// `submitted/1` が返した `Submitted` の 8 項目を、項目名と値の対で返す
/// （`merged_content/2` の `fields` と `profile_store` へ保持する `values` に使う）。
pub fn submitted_fields(submitted: Submitted) -> List(#(String, String)) {
  let Submitted(profile:, ..) = submitted
  [
    #("name", profile.name),
    #("display_name", profile.display_name),
    #("about", profile.about),
    #("picture", profile.picture),
    #("banner", profile.banner),
    #("nip05", profile.nip05),
    #("website", profile.website),
    #("lud16", profile.lud16),
  ]
}

/// kind 0 の `content`（JSON 文字列）に `fields` の項目を差し替えた JSON 文字列を
/// 返す。未知のキーはそのまま残す。空の値の項目はキーごと消す。
/// `profile_ffi:merge_content/2` の `@external`。純粋なのでこのモジュールに置き、
/// テストから直接呼べるようにする。
@external(erlang, "profile_ffi", "merge_content")
pub fn merged_content(
  content: String,
  fields: List(#(String, String)),
) -> String

/// 直前の更新の送信の結果。`profile_store` が 1 回の描画まで保持する
/// （`profile.gleam` の `plugin_children/0` を参照）。
pub type Submission {
  /// 送信に成功した。
  Succeeded
  /// 送信に失敗した。`reason` は失敗の理由の英語の 1 文、`values` はフォームへ
  /// 戻す送信された値（`Fetched.Failed` と名前が衝突するため `SubmitFailed` に
  /// する）。
  SubmitFailed(reason: String, values: Profile)
}

/// `profile_store:take/1` が返す map（`status`・`reason`・`values` を持つ
/// binary キーの map、または結果が無いときの `none`）を読む。`reason` と
/// `values` は `status` が `error` のときだけ読む。`none`、型の誤り、未知の
/// `status` は `None`。
pub fn submission(raw: Dynamic) -> Option(Submission) {
  case decode.run(raw, submission_decoder()) {
    Ok(submission) -> Some(submission)
    Error(_errors) -> None
  }
}

/// `submission/1` のデコーダー。
fn submission_decoder() -> decode.Decoder(Submission) {
  use status <- decode.field("status", decode.string)
  case status {
    "ok" -> decode.success(Succeeded)
    "error" -> {
      use reason <- decode.field("reason", decode.string)
      use values <- decode.field("values", submitted_values_decoder())
      decode.success(SubmitFailed(reason: reason, values: values))
    }
    _ -> decode.failure(Succeeded, "Submission")
  }
}

/// `profile_store` に保持した `values`（8 項目の binary キーの map）のデコーダー。
fn submitted_values_decoder() -> decode.Decoder(Profile) {
  use name <- decode.field("name", decode.string)
  use display_name <- decode.field("display_name", decode.string)
  use about <- decode.field("about", decode.string)
  use picture <- decode.field("picture", decode.string)
  use banner <- decode.field("banner", decode.string)
  use nip05 <- decode.field("nip05", decode.string)
  use website <- decode.field("website", decode.string)
  use lud16 <- decode.field("lud16", decode.string)
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

/// `plugin_pages/2` が返すページの一覧。プロフィールのページ 1 件だけを持ち、
/// 表示名は `language` の文言。
pub fn pages(language: Language) -> Dynamic {
  dynamic.list([
    dynamic.properties([
      #(dynamic.string("key"), dynamic.string(profile_page_key)),
      #(
        dynamic.string("title"),
        dynamic.string(i18n.text(language, i18n.PageTitle)),
      ),
    ]),
  ])
}

/// ページの記述を `language` の文言で組む。`accounts` が空なら `alert`
/// （`info`）1 つだけの節を返す。それ以外はアカウント・取得の結果・直前の送信の
/// 結果を組にし、1 件につき `account_section/4` を返す（`accounts`・`fetched`・
/// `submissions` は同じ順序・同じ件数である前提。呼び出し元（`profile.gleam`）が
/// 同じ公開鍵の並びで作る）。
pub fn content(
  language: Language,
  accounts: List(Account),
  fetched: List(Fetched),
  submissions: List(Option(Submission)),
) -> Dynamic {
  case accounts {
    [] -> page_sections([no_accounts_section(language)])
    _ ->
      page_sections(
        list.map(zip3(accounts, fetched, submissions), fn(row) {
          account_section(language, row.0, row.1, row.2)
        }),
      )
  }
}

/// 3 つのリストを同じ添字で組にする。`accounts`・`fetched`・`submissions` を
/// まとめて `content/4` から渡すためだけに使う。
fn zip3(a: List(a), b: List(b), c: List(c)) -> List(#(a, b, c)) {
  list.zip(a, b)
  |> list.zip(c)
  |> list.map(fn(pair) { #(pair.0.0, pair.0.1, pair.1) })
}

/// 登録アカウントが 0 件のときの節。
fn no_accounts_section(language: Language) -> Dynamic {
  section(i18n.text(language, i18n.PageTitle), [
    alert_block(i18n.text(language, i18n.NoAccounts), "info"),
  ])
}

/// アカウント 1 件の節。`title` はアカウントの `label`。ブロックは取得の結果と
/// 直前の送信の結果に応じて `account_blocks/4` が組む。
fn account_section(
  language: Language,
  account: Account,
  fetched: Fetched,
  submission: Option(Submission),
) -> Dynamic {
  section(account.label, account_blocks(language, account, fetched, submission))
}

/// アカウント 1 件のブロックの並び。
///
/// 1. `submission` が `Some` なら、`Succeeded` は `i18n.ProfileUpdated`、
///    `SubmitFailed` は `i18n.UpdateFailed` の文言を `alert`（成功は `success`、
///    失敗は `failure`）で先頭に出す。
/// 2. `Failed` は理由の `alert`（`failure`）と `npub` の `pairs` だけで終わり、
///    `form` は出さない（現在のプロフィールが分からないまま編集させないため）。
/// 3. `NotFound` は `warning` の `alert` に続けて `npub` と空の `updated` の
///    `pairs`、そして `form` を出す。
/// 4. `content` が JSON のオブジェクトとして読めないときは、既存の `alert`
///    （`failure`）に続けて `npub`・`updated` の `pairs` と `form` を出す。
/// 5. それ以外（`Found` で読めた）は `npub`・`updated` の `pairs`、画像
///    （`picture` / `banner` が空でなければ）、`form` の順。
///
/// `form` の初期値は、直前の送信が `SubmitFailed` ならその `values`、それ以外は
/// 取得した `Profile`（`NotFound` と読めない `content` は `empty_profile`）。
fn account_blocks(
  language: Language,
  account: Account,
  fetched: Fetched,
  submission: Option(Submission),
) -> List(Dynamic) {
  list.append(
    submission_alert(language, submission),
    fetched_blocks(language, account, fetched, submission),
  )
}

/// `submission` を先頭に出す `alert` 0〜1 件。文言は `language` で組む。
fn submission_alert(
  language: Language,
  submission: Option(Submission),
) -> List(Dynamic) {
  case submission {
    Some(Succeeded) -> [
      alert_block(i18n.text(language, i18n.ProfileUpdated), "success"),
    ]
    Some(SubmitFailed(reason:, ..)) -> [
      alert_block(i18n.text(language, i18n.UpdateFailed(reason)), "failure"),
    ]
    None -> []
  }
}

/// `submission_alert/2` に続くブロック（取得の結果ごとの並び。`account_blocks/4`
/// の Doc を参照）。
fn fetched_blocks(
  language: Language,
  account: Account,
  fetched: Fetched,
  submission: Option(Submission),
) -> List(Dynamic) {
  case fetched {
    Failed(reason:) -> [
      alert_block(i18n.text(language, i18n.FetchFailed(reason)), "failure"),
      pairs_block([npub_item(account)]),
    ]
    NotFound ->
      [
        alert_block(i18n.text(language, i18n.NoProfileEvent), "warning"),
        pairs_block([
          npub_item(account),
          #(i18n.text(language, i18n.UpdatedTerm), code_inline("")),
        ]),
      ]
      |> list.append([
        profile_form_block(
          language,
          account.pubkey,
          initial_profile(submission, empty_profile),
        ),
      ])
    Found(content:, created_at:) ->
      case profile_of_json(content) {
        Ok(profile) ->
          [
            pairs_block([
              npub_item(account),
              updated_item(language, created_at),
            ]),
          ]
          |> list.append(image_blocks(language, account, profile))
          |> list.append([
            profile_form_block(
              language,
              account.pubkey,
              initial_profile(submission, profile),
            ),
          ])
        Error(Nil) -> [
          alert_block(i18n.text(language, i18n.ContentNotObject), "failure"),
          pairs_block([npub_item(account), updated_item(language, created_at)]),
          profile_form_block(
            language,
            account.pubkey,
            initial_profile(submission, empty_profile),
          ),
        ]
      }
  }
}

/// `form` の初期値。`submission` が `SubmitFailed` ならその `values`（送信された
/// 値をそのまま返す）、それ以外は `fallback`（取得した現在のプロフィール）。
fn initial_profile(
  submission: Option(Submission),
  fallback: Profile,
) -> Profile {
  case submission {
    Some(SubmitFailed(values:, ..)) -> values
    _ -> fallback
  }
}

/// 8 項目すべてが空文字列の `Profile`。`NotFound` と `content` が読めないときの
/// `form` の初期値に使う。
const empty_profile = Profile(
  name: "",
  display_name: "",
  about: "",
  picture: "",
  banner: "",
  nip05: "",
  website: "",
  lud16: "",
)

/// `pairs` の `npub` の項。
fn npub_item(account: Account) -> #(String, Dynamic) {
  #("npub", id_inline(account.npub))
}

/// `pairs` の更新の時刻の項。見出しは `language` の `i18n.UpdatedTerm`、値は
/// RFC 3339 の UTC の `code` インライン。
fn updated_item(language: Language, created_at: Int) -> #(String, Dynamic) {
  #(
    i18n.text(language, i18n.UpdatedTerm),
    code_inline(format_timestamp(created_at)),
  )
}

/// `picture` / `banner` が空でなければ、`language` の文言の `note` と、代替
/// テキストを持つ `image` を続けて出す。両方空なら空リスト。
fn image_blocks(
  language: Language,
  account: Account,
  profile: Profile,
) -> List(Dynamic) {
  list.flatten([
    image_with_note(
      profile.picture,
      i18n.text(language, i18n.PictureNote),
      i18n.text(language, i18n.PictureAlt(account.label)),
    ),
    image_with_note(
      profile.banner,
      i18n.text(language, i18n.BannerNote),
      i18n.text(language, i18n.BannerAlt(account.label)),
    ),
  ])
}

/// 1 枚の画像の `note` と `image`。`url` が空なら出さない。
fn image_with_note(url: String, label: String, alt: String) -> List(Dynamic) {
  case url {
    "" -> []
    _ -> [note_block(label), image_block(url, alt)]
  }
}

/// プロフィールを編集する `form` ブロック。欄は `name` / `display_name` / `about`
/// （`textarea`）/ `picture` / `banner` / `nip05` / `website` / `lud16` の順で、
/// ラベルは項目名のまま（kind 0 のキー名なので訳さない）。送信ボタンは
/// `language` の `i18n.SaveButton` の文言。欄の `name` は `field_name/2` で
/// 組み立てる。
fn profile_form_block(
  language: Language,
  pubkey: String,
  profile: Profile,
) -> Dynamic {
  form_block(
    [
      text_field(field_name(pubkey, "name"), "name", profile.name),
      text_field(
        field_name(pubkey, "display_name"),
        "display_name",
        profile.display_name,
      ),
      textarea_field(field_name(pubkey, "about"), "about", profile.about),
      text_field(field_name(pubkey, "picture"), "picture", profile.picture),
      text_field(field_name(pubkey, "banner"), "banner", profile.banner),
      text_field(field_name(pubkey, "nip05"), "nip05", profile.nip05),
      text_field(field_name(pubkey, "website"), "website", profile.website),
      text_field(field_name(pubkey, "lud16"), "lud16", profile.lud16),
    ],
    i18n.text(language, i18n.SaveButton),
  )
}

/// 欄の送信名。`<公開鍵>-<項目名>` の形（`parse_submitted_field/1` の分解と対）。
fn field_name(pubkey: String, field: String) -> String {
  pubkey <> "-" <> field
}

/// `text` 欄の記述。
fn text_field(name: String, label: String, value: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("text")),
    #(dynamic.string("name"), dynamic.string(name)),
    #(dynamic.string("label"), dynamic.string(label)),
    #(dynamic.string("value"), dynamic.string(value)),
  ])
}

/// `textarea` 欄の記述。
fn textarea_field(name: String, label: String, value: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("textarea")),
    #(dynamic.string("name"), dynamic.string(name)),
    #(dynamic.string("label"), dynamic.string(label)),
    #(dynamic.string("value"), dynamic.string(value)),
  ])
}

/// `form` ブロック。
fn form_block(fields: List(Dynamic), submit: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("form")),
    #(dynamic.string("fields"), dynamic.list(fields)),
    #(dynamic.string("submit"), dynamic.string(submit)),
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
/// （`code_inline`・`id_inline`）の対。
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
