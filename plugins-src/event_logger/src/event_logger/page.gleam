//// 管理 UI のページの記述を組み立て、フォームの送信を正規化する純粋なモジュール。
//// プロセスにもネットワークにも触れず、呼び出し元（`event_logger.gleam`）が観測した値と
//// 受け取った送信を引数で受け取って、記述の `Dynamic` と選択の結果を組み立てるだけである。
////
//// 記述の形式は `docs/plugin-api.md` 第 13 章のとおり、段ごとに種別を閉じた 3 段の
//// binary キーの map である。**プラグインが選べるのは文字列・種別・`tone`・真偽値だけで**、
//// クラス名も `href` も持ち込めない。秘密（接続先 URL のパスワード）は本体に渡す前に
//// ここでマスクする（`masked_url/2`。同文書第 13.4 節の実例でもある）。
////
//// 値は `gleam/dynamic` の `properties` / `list` / `string` で組む。`properties` は
//// Erlang では binary キーの map になる。

import event_logger/store
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import pog

/// 設定ページのキー。URL の path 片にもなる。
const settings_page_key = "settings"

/// 設定ページの表示名。
const settings_page_title = "Settings"

/// タイムラインのページのキー。URL の path 片にもなる。
const timeline_page_key = "timeline"

/// タイムラインのページの表示名。
const timeline_page_title = "Timeline"

/// プロセス 1 つの観測結果。`label` は表に出す名前（例: `connection pool`）、
/// `registered_name` は登録名の文字列、`mailbox` は未処理メッセージ数で、
/// プロセスが居なければ `Error(Nil)`。
pub type ProcessStatus {
  ProcessStatus(
    label: String,
    registered_name: String,
    mailbox: Result(Int, Nil),
  )
}

/// 本体から `Accounts`（`docs/plugin-api.md` 第 13.5 節）で届く登録アカウント 1 件。
pub type Account {
  Account(pubkey: String, npub: String, label: String)
}

/// `Accounts` の値（アカウントの一覧を JSON にした文字列）を読む。JSON として
/// 読めなければ `[]` を返す。`plugin_page_content` に `{error, Reason}` を返す
/// 約束が無いため（`docs/plugin-api.md` 第 13.4 節）。
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

/// フォームの送信を正規化する。`values` はチェックされたチェックボックスの
/// `name`（= `pubkey`）だけを持つ。1 件も選ばれていなければ拒否し、登録の
/// 全件が選ばれていれば絞らないことを表す空リストにする。`values` に含まれる
/// 未知の名前（登録に無い `pubkey`）は無視する。
pub fn selected_pubkeys(
  accounts: List(Account),
  values: Dict(String, String),
) -> Result(List(String), String) {
  let chosen =
    list.filter(accounts, fn(account) { dict.has_key(values, account.pubkey) })
  case list.length(chosen), list.length(accounts) {
    0, _ -> Error("select at least one account")
    selected, total if selected == total -> Ok([])
    _, _ -> Ok(list.map(chosen, fn(account) { account.pubkey }))
  }
}

/// `plugin_pages/0` が返すページの一覧。`timeline` を先頭に置く（ダッシュボード
/// のリンクは先頭のページを指す）。
pub fn pages() -> Dynamic {
  dynamic.list([
    dynamic.properties([
      #(dynamic.string("key"), dynamic.string(timeline_page_key)),
      #(dynamic.string("title"), dynamic.string(timeline_page_title)),
    ]),
    dynamic.properties([
      #(dynamic.string("key"), dynamic.string(settings_page_key)),
      #(dynamic.string("title"), dynamic.string(settings_page_title)),
    ]),
  ])
}

/// ページ 1 件の記述。`key` が `timeline` なら保存済みイベントの直近の一覧を、
/// `settings` なら監視対象・設定・状態を 3 節で示し、それ以外（キー未知、または
/// binary として読めなかった呼び出し元が渡す仮の文字列）は `alert` 1 つだけの
/// 節を返す。`plugin_page_content` に `{error, Reason}` を返す約束は無いため
/// （`docs/plugin-api.md` 第 13.4 節）。
///
/// `database` は `masked_url/2` で組んだ表示用の文字列（未設定なら `Error(Nil)`）、
/// `pool_size` は接続プールの接続数、`processes` は保存アクターと接続プールの
/// 観測結果、`accounts` は登録アカウントの一覧、`monitored` は保存アクターへ
/// 問い合わせた今の監視対象（問い合わせが届かなければ `Error(Nil)`）。`events`
/// はタイムラインに出す直近のイベント（読めなければ `alert` に出す理由の
/// 文字列）。
pub fn content(
  key: String,
  database: Result(String, Nil),
  pool_size: Int,
  processes: List(ProcessStatus),
  accounts: List(Account),
  monitored: Result(store.Monitored, Nil),
  events: Result(List(store.Row), String),
) -> Dynamic {
  case key {
    k if k == timeline_page_key -> page_sections(timeline_sections(events))
    k if k == settings_page_key ->
      page_sections([
        monitored_section(accounts, monitored),
        configuration_section(database, pool_size),
        runtime_section(processes),
      ])
    _ -> page_sections([error_section()])
  }
}

/// `Timeline` の節。`Error(reason)` なら `alert`（`failure`）1 つだけ、
/// `Ok([])` なら空の状態の文に任せて `blocks` を空にする、`Ok(rows)` なら
/// 行ごとに 1 つの節（`event_section/1`）にする。
fn timeline_sections(events: Result(List(store.Row), String)) -> List(Dynamic) {
  case events {
    Error(reason) -> [section("Timeline", [alert_block(reason, "failure")])]
    Ok([]) -> [section("Timeline", [])]
    Ok(rows) -> list.map(rows, event_section)
  }
}

/// イベント 1 件の節。見出しは `kind` と保存された `created_at` の時刻、
/// `pairs` に `id`・`pubkey`、`details` に `tags`・`content`・`signature` を
/// 畳んで持つ。
fn event_section(row: store.Row) -> Dynamic {
  section(
    "kind "
      <> int.to_string(row.kind)
      <> " · "
      <> format_timestamp(row.created_at),
    [
      pairs_block([
        #("id", id_inline(row.id)),
        #("pubkey", id_inline(row.pubkey)),
      ]),
      details_block(
        "tags (" <> int.to_string(tag_count(row.tags)) <> ")",
        row.tags,
      ),
      details_block(
        "content (" <> int.to_string(string.byte_size(row.content)) <> " bytes)",
        row.content,
      ),
      details_block("signature", row.sig),
    ],
  )
}

/// `tags` の JSON 文字列に含まれるタグの件数。読めなければ 0。
fn tag_count(tags: String) -> Int {
  json.parse(tags, decode.list(decode.dynamic))
  |> result.map(list.length)
  |> result.unwrap(0)
}

/// Unix 秒を UTC の RFC 3339（`2026-09-22T10:00:00Z`）にする。
@external(erlang, "event_logger_ffi", "format_timestamp")
fn format_timestamp(seconds: Int) -> String

/// 接続先だけを残した表示用の文字列。パスワードは含めない。`database_url` が
/// postgres の URL として解釈できなければ、その旨の 1 文を返す。`pool` は
/// `pog.url_config/2` の第 1 引数として要るだけで、戻り値には使わない。
pub fn masked_url(pool: Name(pog.Message), database_url: String) -> String {
  case pog.url_config(pool, database_url) {
    Ok(config) ->
      "postgres://"
      <> config.user
      <> "@"
      <> config.host
      <> ":"
      <> int.to_string(config.port)
      <> "/"
      <> config.database
    Error(Nil) -> "PLUGIN_EVENT_LOGGER_DATABASE_URL is not a valid postgres URL"
  }
}

/// `Configuration` の節。マスク済みの URL、プール接続数、保存待ちの上限を
/// `pairs` で示し、接続先はこの環境変数だけで実行時には変えられない旨を注記する。
fn configuration_section(
  database: Result(String, Nil),
  pool_size: Int,
) -> Dynamic {
  let masked = case database {
    Ok(value) -> value
    Error(Nil) -> "not configured"
  }
  section("Configuration", [
    pairs_block([
      #("PLUGIN_EVENT_LOGGER_DATABASE_URL", code_inline(masked)),
      #("pool size", text_inline(int.to_string(pool_size))),
      #(
        "max queue length",
        text_inline(int.to_string(store.default_max_queue_len)),
      ),
    ]),
    note_block(
      "This plugin strips the password before showing the URL above. "
      <> "The connection URL comes only from this environment variable and "
      <> "cannot be changed from this page. Only the accounts to store "
      <> "events for are chosen above.",
    ),
  ])
}

/// `Monitored accounts` の節。保存アクターへ問い合わせた今の監視対象が
/// `Error(Nil)`（問い合わせが届かなかった）なら `alert`（`failure`）1 つだけに
/// する。登録アカウントが 0 件なら、本体が出す空の状態の文に任せて `blocks` を
/// 空にする（`docs/plugin-api.md` 第 13.3 節）。それ以外はチェックボックスの
/// `form` を、登録アカウントごとに 1 行で出す。
fn monitored_section(
  accounts: List(Account),
  monitored: Result(store.Monitored, Nil),
) -> Dynamic {
  case monitored, accounts {
    Error(Nil), _ ->
      section("Monitored accounts", [
        alert_block(
          "monitored accounts are unavailable: the store actor did not answer",
          "failure",
        ),
      ])
    Ok(_), [] -> section("Monitored accounts", [])
    Ok(current), _ ->
      section("Monitored accounts", [
        text_block("Events are stored only for the accounts checked here."),
        note_block(
          "All accounts checked means every account, including ones you "
          <> "register later.",
        ),
        form_block(
          list.map(accounts, fn(account) {
            checkbox_field(
              name: account.pubkey,
              label: account.label,
              hint: account.npub,
              checked: store.is_monitored(current, account.pubkey),
            )
          }),
          "Save",
        ),
      ])
  }
}

/// `Runtime` の節。プロセスごとに 1 行の表を出し、居ないプロセスが 1 つでも
/// あれば、子が再起動中か諦められた状態であることを示す注意を末尾に足す。
fn runtime_section(processes: List(ProcessStatus)) -> Dynamic {
  let table =
    table_block(
      ["Process", "Registered name", "Status", "Pending messages"],
      list.map(processes, process_row),
    )
  case list.any(processes, fn(process) { result.is_error(process.mailbox) }) {
    True ->
      section("Runtime", [
        table,
        alert_block(
          "A process shown as not running may be restarting or have "
            <> "been given up on; see plugin-api.md section 5.4.",
          "warning",
        ),
      ])
    False -> section("Runtime", [table])
  }
}

/// `Runtime` の表の 1 行。`Status` は生存を `badge` で、`Pending messages` は
/// 未処理メッセージ数か、居なければ `-` で示す。
fn process_row(process: ProcessStatus) -> List(Dynamic) {
  let #(status_text, status_tone, pending_text) = case process.mailbox {
    Ok(count) -> #("running", "success", int.to_string(count))
    Error(Nil) -> #("not running", "failure", "-")
  }
  [
    text_inline(process.label),
    code_inline(process.registered_name),
    badge_inline(status_text, status_tone),
    text_inline(pending_text),
  ]
}

/// 未知のページキーに対する節。`alert`（`failure`）1 つだけを持つ。
fn error_section() -> Dynamic {
  section("Error", [alert_block("unknown page", "failure")])
}

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

/// `table` ブロック。`rows` の各セルはすでに組み立てたインライン。
fn table_block(headers: List(String), rows: List(List(Dynamic))) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("table")),
    #(
      dynamic.string("headers"),
      dynamic.list(list.map(headers, dynamic.string)),
    ),
    #(dynamic.string("rows"), dynamic.list(list.map(rows, dynamic.list))),
  ])
}

/// `note` ブロック。
fn note_block(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("note")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `details` ブロック。`text` は開いたときに出す整形済みのテキスト。
fn details_block(summary: String, text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("details")),
    #(dynamic.string("summary"), dynamic.string(summary)),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `text` ブロック。
fn text_block(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("text")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `form` ブロック。`fields` は `checkbox_field/4` などで組んだ欄の記述、
/// `submit` は送信ボタンの文字列。
fn form_block(fields: List(Dynamic), submit: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("form")),
    #(dynamic.string("fields"), dynamic.list(fields)),
    #(dynamic.string("submit"), dynamic.string(submit)),
  ])
}

/// `checkbox` の欄。`name` が送信名（`docs/plugin-api.md` 13.3 節の
/// `[A-Za-z0-9_-]+`）で、この節では登録アカウントの `pubkey`（16 進）を使う。
fn checkbox_field(
  name name: String,
  label label: String,
  hint hint: String,
  checked checked: Bool,
) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("checkbox")),
    #(dynamic.string("name"), dynamic.string(name)),
    #(dynamic.string("label"), dynamic.string(label)),
    #(dynamic.string("hint"), dynamic.string(hint)),
    #(dynamic.string("checked"), dynamic.bool(checked)),
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

/// `badge` インライン。`table` のセルだけで使える。
fn badge_inline(text: String, tone: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("badge")),
    #(dynamic.string("text"), dynamic.string(text)),
    #(dynamic.string("tone"), dynamic.string(tone)),
  ])
}

/// `id` インライン。`pairs` の値だけで使える。
fn id_inline(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("id")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}
