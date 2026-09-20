//// 管理 UI のページの記述を組み立てる純粋なモジュール。プロセスにもネットワークにも
//// 触れず、呼び出し元（`event_logger.gleam`）が観測した値を引数で受け取って
//// `Dynamic` を組み立てるだけである。
////
//// 記述の形式は `docs/plugin-api.md` 第 13 章のとおり、段ごとに種別を閉じた 3 段の
//// binary キーの map である。**プラグインが選べるのは文字列・種別・`tone` だけで**、
//// クラス名も `href` も持ち込めない。秘密（接続先 URL のパスワード）は本体に渡す前に
//// ここでマスクする（`masked_url/2`。同文書第 13.4 節の実例でもある）。
////
//// 値は `gleam/dynamic` の `properties` / `list` / `string` で組む。`properties` は
//// Erlang では binary キーの map になる。

import event_logger/store
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/result
import pog

/// このプラグインが供給する唯一のページのキー。URL の path 片にもなる。
const page_key = "settings"

/// ページの表示名。
const page_title = "Settings"

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

/// `plugin_pages/0` が返すページの一覧。キー `settings` の 1 件だけを供給する。
pub fn pages() -> Dynamic {
  dynamic.list([
    dynamic.properties([
      #(dynamic.string("key"), dynamic.string(page_key)),
      #(dynamic.string("title"), dynamic.string(page_title)),
    ]),
  ])
}

/// ページ 1 件の記述。`key` が `settings` なら設定と状態を 2 節で示し、それ以外
/// （キー未知、または binary として読めなかった呼び出し元が渡す仮の文字列）は
/// `alert` 1 つだけの節を返す。`plugin_page_content` に `{error, Reason}` を返す
/// 約束は無いため（`docs/plugin-api.md` 第 13.4 節）。
///
/// `database` は `masked_url/2` で組んだ表示用の文字列（未設定なら `Error(Nil)`）、
/// `pool_size` は接続プールの接続数、`processes` は保存アクターと接続プールの
/// 観測結果。
pub fn content(
  key: String,
  database: Result(String, Nil),
  pool_size: Int,
  processes: List(ProcessStatus),
) -> Dynamic {
  case key {
    k if k == page_key ->
      page_sections([
        configuration_section(database, pool_size),
        runtime_section(processes),
      ])
    _ -> page_sections([error_section()])
  }
}

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
/// `pairs` で示し、設定はこの環境変数だけで実行時には変えられない旨を注記する。
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
      <> "The setting comes only from this environment variable and cannot "
      <> "be changed from this page.",
    ),
  ])
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
/// （`text_inline` か `code_inline`）の対。
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
