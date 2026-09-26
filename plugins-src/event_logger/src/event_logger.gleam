//// 監視で受信したイベントを Postgres へ保存する外部プラグイン（API v1）。
////
//// 本体（nostr_no_su）とは別のプロジェクトとしてビルドし、接続プールと版つきの
//// 移行も本体と共有せず自分で持つ。接続先は本体が予約キー `DatabaseUrl` で渡す
//// 本体のデータベースで、`PLUGIN_EVENT_LOGGER_DATABASE_URL` があればそちらを
//// 優先する（`database_url/1`）。保存の対象とするアカウントは設定ページから決め、
//// このプラグインのテーブルに持つ。
////
//// ビルド、置き方、設定、`pgo` を自分で起動する理由は同ディレクトリーの README に、
//// エクスポートの契約は `docs/plugin-api.md` にある。

import event_logger/i18n
import event_logger/page
import event_logger/store
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
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

/// 設定 map から接続先の URL を選ぶ。`PLUGIN_EVENT_LOGGER_DATABASE_URL`（キーは
/// `database_url`）があればそれを、無ければ本体が予約キー `DatabaseUrl` で渡す本体の
/// `DATABASE_URL` を返す。どちらも無ければ `Error(Nil)`。
pub fn database_url(
  settings: dict.Dict(String, String),
) -> Result(String, Nil) {
  dict.get(settings, "database_url")
  |> result.lazy_or(fn() { dict.get(settings, "DatabaseUrl") })
}

/// 接続プールと保存アクターの子仕様。接続先（`database_url/1`）が無い・URL として
/// 解釈できないときは `{error, Reason}` を返してこのプラグインだけを無効にする。
/// 接続先が無いのは本体が `DatabaseUrl` を渡さないときだけで、nostr-no-su の本体は
/// 常に渡す。
///
/// **Config はここで 1 度だけ作り、子仕様の MFA 引数に焼き込む。**
///
/// 戻り値が `Dynamic` なのは、成功側を素のリストにするためである。Gleam の
/// `Ok(list)` は `{ok, List}` になり、素のリストを期待する本体には渡せない。
pub fn plugin_children(config: Dynamic) -> Dynamic {
  case decode.run(config, decode.dict(decode.string, decode.string)) {
    Error(_errors) -> error_tuple("configuration must be a map of strings")
    Ok(settings) ->
      case database_url(settings) {
        Error(Nil) ->
          error_tuple(
            "database_url is required when the host passes no DatabaseUrl",
          )
        Ok(url) -> pool_children(url)
      }
  }
}

/// 接続プールと保存アクターの子仕様。URL が解釈できなければ設定を拒否する。
fn pool_children(database_url: String) -> Dynamic {
  case pog.url_config(pool_name(), database_url) {
    Error(Nil) -> error_tuple("database URL is not a valid postgres URL")
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

/// 接続プールを起動する起動シム。本体は同梱アプリケーションを起動しないので、先に
/// `pgo` を起動する（冪等）。`pog.start/1` の `{ok, {started, Pid, Conn}}` は本体の
/// `start_child` に弾かれるので、`{ok, Pid}` に潰す（`docs/plugin-api.md` 第 5.2 節）。
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

/// アクターの起動結果を `{ok, Pid}` / `{error, Reason}` に潰す。
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

/// 保存アクターの登録名。`handle_event/1` の宛先である。
pub fn store_name() -> Name(store.Msg) {
  fixed_name(store_name_label)
}

/// 接続プールの登録名。
fn pool_name() -> Name(pog.Message) {
  fixed_name(pool_name_label)
}

/// 固定の atom から作る登録名。子が再起動しても管理 UI のページからも同じ宛先を
/// 指すよう、呼ぶたびに新しい atom を作る `process.new_name` は使わない。`label` は
/// プラグイン名を接頭辞にして VM 全体で一意にする（`docs/plugin-api.md` 第 5.3 節）。
@external(erlang, "erlang", "binary_to_atom")
fn fixed_name(label: String) -> Name(msg)

/// 管理 UI に供給するページの一覧。本体は読み込み時に表示の言語ごとに 1 度ずつ
/// 呼び、どの言語でもキーの並びが同じことを検証する。`language` は言語のコードの
/// binary で、表示名をその言語で返す。設定 map は使わない。中身は
/// `plugin_page_content/3` が返す。
pub fn plugin_pages(_config: Dynamic, language: Dynamic) -> Dynamic {
  page.pages(language_of(language))
}

/// 本体が渡す言語のコードを `i18n.from_code` で言語にする。binary として
/// 読めなければ英語にする。
fn language_of(value: Dynamic) -> i18n.Language {
  decode.run(value, decode.string)
  |> result.unwrap("")
  |> i18n.from_code
}

/// 管理 UI のページの記述。本体はページの表示のたびにこれを呼び、ページの `key`
/// と、`DatabaseUrl` と `Accounts` を含む設定 map（`plugin_children/1` と同じ形に
/// `Accounts` を足したもの）と、表示の言語のコードを渡す。接続先は
/// `database_url/1` で選ぶ。文言はその言語で組む。
/// 期限（既定 5 秒）を超えると 503 になるので、DB を読むのは `timeline` の直近 20 件
/// だけにし、問い合わせに 2 秒の期限を付ける。`{error, Reason}` を返す約束は無い
/// （`docs/plugin-api.md` 第 13.4 節）。
pub fn plugin_page_content(
  key: Dynamic,
  config: Dynamic,
  language: Dynamic,
) -> Dynamic {
  let page_key = decode.run(key, decode.string) |> result.unwrap("")
  let language = language_of(language)
  let settings =
    decode.run(config, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  let database =
    database_url(settings)
    |> result.map(page.masked_url(pool_name(), _, language))
  let #(events, monitored) = case page_key {
    "timeline" -> #(recent_events(), Error(Nil))
    _ -> #(Ok([]), monitored_state())
  }
  page.content(
    page_key,
    language,
    database,
    pool_size,
    [
      process_status(i18n.ConnectionPool, pool_name_label, pool_name()),
      process_status(i18n.StoreActor, store_name_label, store_name()),
    ],
    accounts_from_config(settings),
    monitored,
    events,
  )
}

/// タイムラインに出す直近のイベント。プールが居ない・問い合わせが失敗したときは、
/// 節の `alert` に出す文言（`i18n.PoolNotRunning`、`i18n.EventsUnreadable`）を返す。
/// 問い合わせの失敗の詳細（`string.inspect` の文字列）は訳さずに文言へ埋め込む。
fn recent_events() -> Result(List(store.Row), i18n.Message) {
  case process.named(pool_name()) {
    Error(Nil) -> Error(i18n.PoolNotRunning)
    Ok(_pid) ->
      store.recent_events(pog.named_connection(pool_name()), store.recent_limit)
      |> result.map_error(fn(error) {
        i18n.EventsUnreadable(string.inspect(error))
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
  label: i18n.Message,
  registered_name: String,
  name: Name(message),
) -> page.ProcessStatus {
  let mailbox = case process.named(name) {
    Ok(pid) -> store.pending_messages(pid)
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
