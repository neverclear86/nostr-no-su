//// プラグイン固有の設定。環境変数 `PLUGIN_<NAME>_<KEY>` を集めて、プラグインごとの
//// binary キーの map にする。
////
//// **環境変数を読むのはこのモジュールではない**（`config.gleam` が 1 か所で読む）。
//// ここが持つのは、設定の切り出し、本体の接続先の予約キーへの写し、境界へ渡す map への
//// 変換、管理 UI のページの型（`PageAccount`、`PageAction`）だけである。map はキーも値も
//// binary で、値は変換しない。仕様は `docs/plugin-api.md` の第 6 章にある。

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/string

/// プラグインへ渡す環境変数の共通接頭辞。
pub const env_prefix = "PLUGIN_"

/// プラグイン名の正規化で残す文字。これ以外はすべて `_` にする。
const name_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

/// プラグイン 1 つぶんの設定。環境変数由来のキーは小文字、値は環境変数の文字列
/// そのまま。本体の接続先があれば予約キー `DatabaseUrl` も持つ。
pub type Config =
  Dict(String, String)

/// プラグイン名に対応する環境変数の接頭辞。`file_logger` なら
/// `PLUGIN_FILE_LOGGER_`。名前は大文字化し、`[A-Z0-9]` 以外は `_` にする
/// （環境変数名に使えない文字を含むプラグイン名があるため）。**末尾の `_` まで
/// 含めて接頭辞である。** これがあるおかげで `PLUGIN_DIR` はどのプラグインにも
/// 一致しない（`PLUGIN_DIR` は `PLUGIN_DIR_` で始まらない）。
pub fn prefix(plugin_name: String) -> String {
  env_prefix <> normalize(plugin_name) <> "_"
}

/// プラグイン名を環境変数名の一部として使える形にする。
fn normalize(plugin_name: String) -> String {
  string.uppercase(plugin_name)
  |> string.to_graphemes
  |> list.map(fn(character) {
    case string.contains(name_alphabet, character) {
      True -> character
      False -> "_"
    }
  })
  |> string.join("")
}

/// 集めた `PLUGIN_*` からプラグイン 1 つぶんの設定を切り出す。接頭辞に一致し、
/// かつ**残りが空でない**ものだけを採り、キーは小文字にする。`env` に本体の
/// 接続先（`with_database_url` が足した項）があれば、その値を予約キー
/// `DatabaseUrl` で足す（環境変数由来のキーと衝突しない理由は `database_url_key`）。
/// どちらも無ければ空。
///
/// 「残りが空でない」条件が弾くのは `PLUGIN_FILE_LOGGER_=x` のような**キーが空の
/// 変数**である。空のキーは環境変数名としては書けてしまうが、プラグインからは
/// `<<"">>` としてしか読めず意味を持たない。
///
/// キーを小文字にするため、**大文字小文字だけが違う変数は衝突する**
/// （`PLUGIN_X_PATH` と `PLUGIN_X_Path` はどちらも `path` になり、どちらが残るかは
/// `dict.fold` の走査順で決まる）。片方だけを設定するという運用に委ねる。
pub fn for_plugin(env: Dict(String, String), plugin_name: String) -> Config {
  let prefix = prefix(plugin_name)
  let prefix_length = string.length(prefix)
  dict.fold(env, dict.new(), fn(config, name, value) {
    case string.starts_with(name, prefix) {
      False -> config
      True ->
        case string.drop_start(name, prefix_length) {
          "" -> config
          key -> dict.insert(config, string.lowercase(key), value)
        }
    }
  })
  |> put_database_url_key(env)
}

/// 本体の接続先を、プラグインへ渡す環境変数の集合の中で表す名前。環境変数の集合は
/// `PLUGIN_` で始まる名前しか持たないので、この項は `with_database_url` だけが入れる。
const host_database_url = "DATABASE_URL"

/// 本体の接続先を渡す予約キー。大文字を含む予約キー（`page_map` の `Accounts` も同じ）は、
/// `for_plugin` が環境変数由来のキーを小文字にするので、それらのキーと衝突しない。
const database_url_key = "DatabaseUrl"

/// `env` に本体の接続先があれば、`config` に予約キー `DatabaseUrl` で足す。
fn put_database_url_key(config: Config, env: Dict(String, String)) -> Config {
  case dict.get(env, host_database_url) {
    Ok(url) -> dict.insert(config, database_url_key, url)
    Error(Nil) -> config
  }
}

/// プラグインへ渡す環境変数の集合に、本体のアカウントストアの接続先を足す。
/// `for_plugin` がこれを各プラグインの設定の予約キー `DatabaseUrl` に写す。
/// 値はパスワードを含むので、表示やログに入れないこと。
pub fn with_database_url(
  env: Dict(String, String),
  database_url: String,
) -> Dict(String, String) {
  dict.insert(env, host_database_url, database_url)
}

/// プラグイン境界へ渡す map。`event.to_map` と同じく `dynamic.properties/1` で
/// binary キー・binary 値の Erlang map を作る。
pub fn to_map(config: Config) -> Dynamic {
  config_entries(config) |> dynamic.properties
}

/// `config` の binary キー・binary 値の組。`to_map` と `page_map` が共有する。
fn config_entries(config: Config) -> List(#(Dynamic, Dynamic)) {
  dict.to_list(config)
  |> list.map(fn(entry) { #(dynamic.string(entry.0), dynamic.string(entry.1)) })
}

/// 管理 UI のページと実行の呼び出しに渡す、バンカーに登録したアカウント 1 件。
/// `pubkey` は 16 進、`npub` は表示と識別、`label` は利用者が付けた名前である。
pub type PageAccount {
  PageAccount(pubkey: String, npub: String, label: String)
}

/// 管理 UI のページのフォームの送信を受け取る実行の口。送られた欄の名前と値の組と、登録
/// アカウントの一覧を受け、拒否か呼び出しの失敗は表示する理由を返す。
pub type PageAction =
  fn(List(#(String, String)), List(PageAccount)) -> Result(Nil, String)

/// プラグイン境界へ渡す map。`to_map` と同じ形に、予約キー `Accounts`（値は
/// アカウントの一覧を JSON にした文字列）を足して返す。中身はアカウントごとの
/// オブジェクト（`pubkey`・`npub`・`label`、すべて文字列）の配列で、0 件なら
/// `[]` である。値は JSON の文字列なので、map は `to_map` と同じく binary
/// キー・binary 値である。このキーが環境変数由来のキーと衝突しない理由は
/// `database_url_key` を参照。
pub fn page_map(config: Config, accounts: List(PageAccount)) -> Dynamic {
  let accounts_json =
    json.array(accounts, fn(account) {
      json.object([
        #("pubkey", json.string(account.pubkey)),
        #("npub", json.string(account.npub)),
        #("label", json.string(account.label)),
      ])
    })
    |> json.to_string
  config_entries(config)
  |> list.append([
    #(dynamic.string("Accounts"), dynamic.string(accounts_json)),
  ])
  |> dynamic.properties
}
