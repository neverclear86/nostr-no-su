//// 監視で受信したイベントを Postgres へ保存する外部プラグイン（API v1）。
////
//// 本体（nostr_no_su）とは別のプロジェクトとしてビルドする。docker イメージでは
//// Dockerfile の `plugin-build-event-logger` ステージがビルドし、
//// `gleam export erlang-shipment` の出力が `/app/plugins/event_logger/` に入る。
//// 改造版を自分でビルドして `PLUGIN_DIR` の下へ置くこともできる。置き方とビルド
//// 手順は同ディレクトリーの README を参照すること。
////
//// **接続先の設定は `PLUGIN_EVENT_LOGGER_DATABASE_URL` だけである。** 本体はこの
//// 接頭辞に一致する環境変数を集め、`database_url` をキーとする map として
//// `plugin_children/1` と `plugin_page_content/2` に渡す。未設定・不正なら
//// `{error, Reason}` を返し、このプラグインだけを読み込ませない。保存の対象と
//// するアカウントは環境変数ではなく設定ページから決め、プラグイン自身の DB に
//// 持つ。設定 map は `plugin_page_action/3` にも渡る。管理 UI のページと実行の
//// 呼び出しに渡る map には、本体がこれに加えて予約キー `Accounts`（登録アカウント
//// の一覧を JSON にした文字列）を入れる（`docs/plugin-api.md` 第 13.5 節）。
////
//// 押さえておくべき点が 4 つある。
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
//// - **名前で配線する。** プールの登録名は `pool_name/0`、保存アクターの登録名は
////   `store_name/0` の固定の atom である。プール名だけは子仕様の MFA 引数にも
////   焼き込む。どちらの子が再起動しても宛先は変わらず、管理 UI のページも同じ
////   名前で生存を引ける（`docs/plugin-api.md` 第 5.3 節）。
//// - **`plugin_page_content/2` は期限内に戻らなければならない。** `settings` は
////   DB へ問い合わせず、外から観測できる値（登録名の生存、未処理メッセージ数、
////   保存アクターが持つ監視対象の集合）だけを返す。`timeline` だけは直近 20 件を
////   DB から読み、問い合わせにページの期限より短い期限を付ける。

import event_logger/page
import event_logger/store
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid}
import gleam/otp/actor
import gleam/result
import gleam/string
import pog

/// 接続プールの接続数。書き込むのは保存アクター 1 つだけで逐次実行なので、
/// 既定の 10 本は DB 側の接続枠と idle ping を無駄に使う。表示側にもこの値を
/// 渡し、数を書き写さない。
const pool_size = 2

/// 保存アクターが再起動している間、登録名が戻るのを待つ上限。本体のランナーが
/// 1 件を打ち切る 30 秒より十分短くする。
const store_wait_ms = 1000

/// 保存アクターの登録名を問い合わせ直す間隔。
const store_poll_ms = 10

/// 設定ページが保存アクターの答えを待つ上限。ページの期限（既定 5 秒）に収める。
const monitored_reply_ms = 1000

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
/// **Config はここで 1 度だけ作り、子仕様の MFA 引数に焼き込む。** プール名は
/// `pool_name/0` の固定の atom なので、再起動でも管理 UI のページからも同じ
/// 名前を指す。
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
  case pog.url_config(pool_name(), database_url) {
    Error(Nil) ->
      error_tuple(
        "PLUGIN_EVENT_LOGGER_DATABASE_URL is not a valid postgres URL",
      )
    Ok(pool_config) ->
      child_specs(pog.pool_size(pool_config, pool_size), pool_config.pool_name)
  }
}

/// イベント 1 件を保存アクターへ転送する。設定は使わないのでアリティは 1。
///
/// 宛先が居なければ `store_poll_ms` ごとに最大 `store_wait_ms` 待ち、それでも
/// 居なければ **panic させる。** 待つのは、保存アクターの再起動の間に届いた
/// イベントを失敗として数えないためである（連続 5 件の失敗でプラグインごと
/// 無効になる）。待っても戻らない状態は子を諦めた状態（`docs/plugin-api.md`
/// 第 5.4 節）であり、ランナーの連続失敗を経てダッシュボードの `disabled` として
/// 可視化する。イベント map の変換もここで済ませ、アクターには DB の仕事だけを
/// 残す。変換に失敗したイベントも同じく失敗として数えられる。
pub fn handle_event(event: Dynamic) -> Nil {
  let name = store_name()
  let assert Ok(_pid) = await_registered(name, store_wait_ms)
    as "event_logger store is not running"
  case store.to_row(event) {
    Ok(row) -> process.send(process.named_subject(name), store.Store(row))
    // 理由を捨てると、どのキーで落ちたのかがランナーの 1 行に残らない。
    Error(reason) -> panic as { "event is not a valid event map: " <> reason }
  }
}

/// 名前が登録されるまで `store_poll_ms` ごとに問い合わせる。`remaining_ms` を
/// 使い切っても登録されていなければ `Error(Nil)` を返す。
fn await_registered(
  name: Name(message),
  remaining_ms: Int,
) -> Result(Pid, Nil) {
  case process.named(name), remaining_ms > 0 {
    Ok(pid), _ -> Ok(pid)
    Error(Nil), True -> {
      process.sleep(store_poll_ms)
      await_registered(name, remaining_ms - store_poll_ms)
    }
    Error(Nil), False -> Error(Nil)
  }
}

/// 接続プールを起動する起動シム。**`pgo` のアプリケーションもここで起動する**
/// （冒頭の doc を参照）。`pog.start/1` の `{ok, {started, Pid, Conn}}` を
/// 本体が受け取れる `{ok, Pid}` に潰す。
pub fn start_pool(config: pog.Config) -> Result(Pid, String) {
  ensure_pgo_started()
  started_pid(pog.start(config))
}

/// 保存アクターを起動する起動シム。登録名は固定で、`handle_event/1` の宛先に
/// なる。`pool` は `plugin_children/1` が作ったプールの名前である。
pub fn start_store(pool: Name(pog.Message)) -> Result(Pid, String) {
  started_pid(store.start(
    store_name(),
    store.postgres(pool),
    store.default_max_queue_len,
  ))
}

/// アクターの起動結果を、本体の `start_child` が受け取れる `{ok, Pid}` /
/// `{error, Reason}` に潰す。
fn started_pid(
  result: Result(actor.Started(data), actor.StartError),
) -> Result(Pid, String) {
  case result {
    Ok(started) -> Ok(started.pid)
    Error(reason) -> Error(string.inspect(reason))
  }
}

/// 保存アクターの登録名の atom 文字列。
const store_name_label = "event_logger_store"

/// 接続プールの登録名の atom 文字列。
const pool_name_label = "event_logger_pool"

/// 保存アクターの登録名。VM 全体で一意にするためプラグイン名を接頭辞にする
/// （`docs/plugin-api.md` 第 5.3 節）。`handle_event/1` の宛先であり、
/// `plugin_page_content/2` が生存を確かめる名前でもある。
pub fn store_name() -> Name(store.Msg) {
  fixed_name(store_name_label)
}

/// 接続プールの登録名。`plugin_children/1` が子仕様の MFA 引数に焼き込み、
/// `plugin_page_content/2` が同じ名前で生存を確かめる。
pub fn pool_name() -> Name(pog.Message) {
  fixed_name(pool_name_label)
}

/// 固定の atom から作る登録名。再起動をまたいで同じでなければならないので、
/// 呼ぶたびに新しい atom を作る `process.new_name` ではなくこちらを使う
/// （`docs/plugin-api.md` 第 5.3 節）。
fn fixed_name(label: String) -> Name(msg) {
  coerce_name(atom.create(label))
}

/// 指定したプロセスの未処理メッセージ数。プロセスが居なければ `Error(Nil)`。
pub fn pending_messages(pid: Pid) -> Result(Int, Nil) {
  decode.run(process_info(pid, atom.create("message_queue_len")), {
    use length <- decode.field(1, decode.int)
    decode.success(length)
  })
  |> result.replace_error(Nil)
}

/// 管理 UI に供給するページの一覧。本体は読み込み時に 1 度だけ検証する。中身は
/// `plugin_page_content/2` が返す。
pub fn plugin_pages() -> Dynamic {
  page.pages()
}

/// 管理 UI のページの記述。本体は `/1` より `/2` を優先し、ページの表示のたびに
/// これを呼んでページの `key` と、`database_url` と `Accounts` を含む設定 map
/// （`plugin_children/1` と同じ形に `Accounts` を足したもの）を渡す。期限
/// （既定 5 秒）を超えると 503 になるので、`settings` では DB へ問い合わせず、
/// 登録名の生存と未処理メッセージ数、保存アクターが持つ監視対象の集合だけを
/// 観測する。`timeline` だけは `store.recent_events/2` で直近 20 件を読み、
/// 問い合わせに 2 秒の期限を付ける。`{error, Reason}` を返す約束は無い
/// （`docs/plugin-api.md` 第 13.4 節）。
pub fn plugin_page_content(key: Dynamic, config: Dynamic) -> Dynamic {
  let page_key = decode.run(key, decode.string) |> result.unwrap("")
  let settings =
    decode.run(config, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  let database =
    dict.get(settings, "database_url")
    |> result.map(page.masked_url(pool_name(), _))
  let #(events, monitored) = case page_key {
    "timeline" -> #(recent_events(), Error(Nil))
    _ -> #(Ok([]), monitored_state())
  }
  page.content(
    page_key,
    database,
    pool_size,
    [
      process_status("connection pool", pool_name_label, pool_name()),
      process_status("store actor", store_name_label, store_name()),
    ],
    accounts_from_config(settings),
    monitored,
    events,
  )
}

/// タイムラインに出す直近のイベント。プールが居ない・問い合わせが失敗したとき
/// は、節の `alert` に出す英語の理由を返す。
fn recent_events() -> Result(List(store.Row), String) {
  case process.named(pool_name()) {
    Error(Nil) -> Error("connection pool is not running")
    Ok(_pid) ->
      store.recent_events(pog.named_connection(pool_name()), store.recent_limit)
      |> result.map_error(fn(error) {
        "could not read stored events: " <> string.inspect(error)
      })
  }
}

/// 設定 map の予約キー `Accounts`（`docs/plugin-api.md` 第 13.5 節）から登録
/// アカウントの一覧を読む。キーが無い・JSON として読めなければ `[]`。
fn accounts_from_config(
  settings: dict.Dict(String, String),
) -> List(page.Account) {
  dict.get(settings, "Accounts")
  |> result.map(page.accounts)
  |> result.unwrap([])
}

/// 保存アクターへ問い合わせた今の監視対象。宛先が居なければ問い合わせない
/// （`monitored_reply_ms` の期限で待っても戻らなければ `Error(Nil)`）。
fn monitored_state() -> Result(store.Monitored, Nil) {
  case process.named(store_name()) {
    Error(Nil) -> Error(Nil)
    Ok(_pid) -> {
      let reply = process.new_subject()
      process.send(
        process.named_subject(store_name()),
        store.GetMonitored(reply_to: reply),
      )
      process.receive(reply, monitored_reply_ms)
    }
  }
}

/// `settings` ページのフォームの送信を受け取る。`key` が `settings` でなければ
/// `error_tuple("unknown page")`。戻り値は `ok` か `{error, Reason}` である
/// （`docs/plugin-api.md` 第 13.6 節）。全アカウントを選んだ送信は行を 0 件に
/// して保存し（絞らない状態を表す）、0 件の送信は拒否する。
///
/// 保存の問い合わせはこの呼び出しのプロセスで行うので、DB が遅い・落ちている
/// ときは期限（既定 5 秒）の超過か問い合わせの失敗になり、どちらも 503 になる
/// （`docs/plugin-api.md` 第 13.1 節）。
pub fn plugin_page_action(
  key: Dynamic,
  values: Dynamic,
  config: Dynamic,
) -> Dynamic {
  let page_key = decode.run(key, decode.string) |> result.unwrap("")
  case page_key {
    "settings" -> save_monitored(values, config)
    _ -> error_tuple("unknown page")
  }
}

/// 送信を正規化し、保存アクターの DB へ書き込む。成功すれば保存アクターへ
/// `ReloadMonitored` を送って読み直させる。
fn save_monitored(values: Dynamic, config: Dynamic) -> Dynamic {
  let values =
    decode.run(values, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  let settings =
    decode.run(config, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  case page.selected_pubkeys(accounts_from_config(settings), values) {
    Error(reason) -> error_tuple(reason)
    Ok(pubkeys) ->
      case store.replace_monitored(pog.named_connection(pool_name()), pubkeys) {
        Error(error) ->
          error_tuple(
            "could not save monitored accounts: " <> string.inspect(error),
          )
        Ok(Nil) -> {
          reload_monitored()
          ok_atom()
        }
      }
  }
}

/// 保存アクターが生きていれば `ReloadMonitored` を送って読み直させる。
fn reload_monitored() -> Nil {
  case process.named(store_name()) {
    Ok(_pid) ->
      process.send(process.named_subject(store_name()), store.ReloadMonitored)
    Error(Nil) -> Nil
  }
}

/// 登録名 1 つの観測結果。生きていれば未処理メッセージ数も添える。
fn process_status(
  label: String,
  registered_name: String,
  name: Name(message),
) -> page.ProcessStatus {
  let mailbox = case process.named(name) {
    Ok(pid) -> pending_messages(pid)
    Error(Nil) -> Error(Nil)
  }
  page.ProcessStatus(
    label: label,
    registered_name: registered_name,
    mailbox: mailbox,
  )
}

/// 接続プールと保存アクターの子仕様（OTP の `supervisor:child_spec()` の map）。
@external(erlang, "event_logger_ffi", "child_specs")
fn child_specs(config: pog.Config, pool: Name(pog.Message)) -> Dynamic

/// 設定を拒否する `{error, Reason}`。
@external(erlang, "event_logger_ffi", "error_tuple")
fn error_tuple(reason: String) -> Dynamic

/// 実行の成功を表す `ok`。
@external(erlang, "event_logger_ffi", "ok_atom")
fn ok_atom() -> Dynamic

/// `pgo` とその依存アプリケーションを起動する。冪等。
@external(erlang, "event_logger_ffi", "ensure_pgo_started")
fn ensure_pgo_started() -> Nil

/// atom を登録名として扱う。gleam_erlang の `Name` は外部型で、実体は登録名の
/// atom である。
@external(erlang, "event_logger_ffi", "identity")
fn coerce_name(name: Atom) -> Name(msg)

/// プロセスの情報を 1 項目だけ問い合わせる。
@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, key: Atom) -> Dynamic
