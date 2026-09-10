//// 監視で受信したイベントを Postgres へ保存する外部プラグイン（API v1）。
////
//// 本体（nostr_no_su）とは別のプロジェクトとしてビルドし、`gleam export
//// erlang-shipment` の出力を `PLUGIN_DIR/event_logger/` へ置いて使う。置き方と
//// ビルド手順は同ディレクトリーの README を参照すること。
////
//// **設定は `PLUGIN_EVENT_LOGGER_DATABASE_URL` だけである。** 本体はこの接頭辞に
//// 一致する環境変数を集め、`database_url` をキーとする map として
//// `plugin_children/1` に渡す。未設定・不正なら `{error, Reason}` を返し、この
//// プラグインだけを読み込ませない。
////
//// 押さえておくべき点が 3 つある。
////
//// - **同梱したアプリケーションはプラグインが自分で起動する。** 本体のローダーは
////   コードパスを足すだけでアプリケーションを起動しない（`docs/plugin-api.md`
////   第 8.1 節）。`pgo` を起動しないと `pg_types` のアプリが立たず、
////   `pgo_type_server` が `pg_types:update_map/3` の `application:get_key/2` で
////   `badmatch` して即死し、接続プールごと落ちる。起動は `start_pool/1` の中で
////   行う（子の再起動のたびに呼ばれるが冪等である）。
//// - **本体の `start_child` は `{ok, Pid}` を要求する。** `pog.start/1` は
////   `{ok, {started, Pid, Conn}}` を返すため、そのままでは弾かれる。プールと
////   保存アクターのどちらにも `{ok, Pid}` へ潰す薄い起動シムを用意する
////   （`docs/plugin-api.md` 第 5.2 節）。
//// - **名前で配線する。** プール名は `plugin_children/1` で 1 度だけ作って子仕様の
////   MFA 引数に焼き込み、保存アクターの登録名は固定の atom にする。どちらの子が
////   再起動しても宛先は変わらない（`docs/plugin-api.md` 第 5.3 節）。

import event_logger/store
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid}
import gleam/string
import pog

/// このプラグインが実装するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// プラグイン名。ダッシュボードとログの識別子であり、設定の接頭辞
/// `PLUGIN_EVENT_LOGGER_` もこの名前から決まる。
pub fn plugin_name() -> String {
  "event_logger"
}

/// 接続プールと保存アクターの子仕様。設定が無い・URL として解釈できないときは
/// `{error, Reason}` を返してこのプラグインだけを無効にする。
///
/// **プール名と Config はここで 1 度だけ作り、子仕様の MFA 引数に焼き込む。**
/// 再起動でも同じ引数で呼ばれるので、プールの登録名が変わらない。
///
/// 戻り値が `Dynamic` なのは、成功側を素のリストにするためである。Gleam の
/// `Ok(list)` は `{ok, List}` になり、素のリストを期待する本体には渡せない。
pub fn plugin_children(config: Dynamic) -> Dynamic {
  case decode.run(config, decode.dict(decode.string, decode.string)) {
    Error(_errors) -> error_tuple("configuration must be a map of strings")
    Ok(settings) ->
      case dict.get(settings, "database_url") {
        Error(Nil) ->
          error_tuple("PLUGIN_EVENT_LOGGER_DATABASE_URL is required")
        Ok(database_url) -> pool_children(database_url)
      }
  }
}

/// 接続プールと保存アクターの子仕様。URL が解釈できなければ設定を拒否する。
fn pool_children(database_url: String) -> Dynamic {
  case pog.url_config(process.new_name("event_logger_pool"), database_url) {
    Error(Nil) ->
      error_tuple(
        "PLUGIN_EVENT_LOGGER_DATABASE_URL is not a valid postgres URL",
      )
    Ok(pool_config) ->
      // 書き込むのは保存アクター 1 つだけで逐次実行なので、接続は少なく保つ。
      // 既定の 10 本は DB 側の接続枠と idle ping を無駄に使う。
      child_specs(pog.pool_size(pool_config, 2), pool_config.pool_name)
  }
}

/// イベント 1 件を保存アクターへ転送する。設定は使わないのでアリティは 1。
///
/// 宛先が居なければ **panic させる。** 子を諦めた状態（`docs/plugin-api.md`
/// 第 5.4 節）を、ランナーの連続失敗を経てダッシュボードの `disabled` として
/// 可視化するためである。イベント map の変換もここで済ませ、アクターには DB の
/// 仕事だけを残す。変換に失敗したイベントも同じく失敗として数えられる。
pub fn handle_event(event: Dynamic) -> Nil {
  let name = store_name()
  let assert Ok(_pid) = process.named(name)
    as "event_logger store is not running"
  let assert Ok(row) = store.to_row(event) as "event is not a valid event map"
  process.send(process.named_subject(name), store.Store(row))
}

/// 接続プールを起動する起動シム。**`pgo` のアプリケーションもここで起動する**
/// （冒頭の doc を参照）。`pog.start/1` の `{ok, {started, Pid, Conn}}` を
/// 本体が受け取れる `{ok, Pid}` に潰す。
pub fn start_pool(config: pog.Config) -> Result(Pid, String) {
  ensure_pgo_started()
  case pog.start(config) {
    Ok(started) -> Ok(started.pid)
    Error(reason) -> Error(string.inspect(reason))
  }
}

/// 保存アクターを起動する起動シム。登録名は固定で、`handle_event/1` の宛先に
/// なる。`pool` は `plugin_children/1` が作ったプールの名前である。
pub fn start_store(pool: Name(pog.Message)) -> Result(Pid, String) {
  case store.start(store_name(), pool) {
    Ok(started) -> Ok(started.pid)
    Error(reason) -> Error(string.inspect(reason))
  }
}

/// 保存アクターの登録名。VM 全体で一意にするためプラグイン名を接頭辞にする
/// （`docs/plugin-api.md` 第 5.3 節）。再起動をまたいで同じでなければならない
/// ので、`process.new_name` ではなく固定の atom から作る。
fn store_name() -> Name(store.Msg) {
  coerce_name(atom.create("event_logger_store"))
}

/// 接続プールと保存アクターの子仕様（OTP の `supervisor:child_spec()` の map）。
@external(erlang, "event_logger_ffi", "child_specs")
fn child_specs(config: pog.Config, pool: Name(pog.Message)) -> Dynamic

/// 設定を拒否する `{error, Reason}`。
@external(erlang, "event_logger_ffi", "error_tuple")
fn error_tuple(reason: String) -> Dynamic

/// `pgo` とその依存アプリケーションを起動する。冪等。
@external(erlang, "event_logger_ffi", "ensure_pgo_started")
fn ensure_pgo_started() -> Nil

/// atom を登録名として扱う。gleam_erlang の `Name` は外部型で、実体は登録名の
/// atom である。
@external(erlang, "event_logger_ffi", "identity")
fn coerce_name(name: Atom) -> Name(store.Msg)
