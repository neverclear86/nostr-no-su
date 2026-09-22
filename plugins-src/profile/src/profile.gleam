//// 登録アカウントの現在のプロフィール（kind 0）を管理 UI に出す外部プラグイン
//// （API v1）。DB は持たない。プロフィールも保持せず、ページを開いたときに毎回
//// `nostr_no_su@plugin_api:fetch_event(Pubkey, 0)`（`docs/plugin-api.md`
//// 第 14.7 節）でリレーから最新の 1 件を取る。持つ状態は直前の更新の送信の結果
//// だけで、`plugin_children/0` で申告する `profile_store` が 1 回の描画まで
//// 保持する。取得はアカウントごとに並行で行い、総上限 4000ms で打ち切る
//// （`plugins-src/profile/src/profile_ffi.erl` を参照）。ページの期限（既定 5
//// 秒、同文書第 13.1 節）にアカウントの件数やリレーの応答によらず収めるため
//// である。
////
//// 本体（nostr_no_su）とは別のプロジェクトとしてビルドする。docker イメージでは
//// Dockerfile の `plugin-build-profile` ステージがビルドし、
//// `gleam export erlang-shipment` の出力が `/app/plugins/profile/` に入る。改造版を
//// 自分でビルドして `PLUGIN_DIR` の下へ置くこともできる。置き方とビルド手順は
//// 同ディレクトリーの README を参照すること。
////
//// 更新はフォームの送信のたびに、送信の直前に対象アカウントの kind 0 をもう一度
//// 取得し直す。取得した内容に送信された 8 項目を差し替え、未知のキーは残した
//// まま新しい kind 0 として送る。送信の成否と文言は `profile_store` に保持し、
//// 次にこのページを開いたときの `alert` として 1 回だけ出る。取得の期限は送信
//// ぶんを差し引いた `action_fetch_timeout_ms`（2000ms）にし、残りを送信に充てる。

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import profile/page

/// このプラグインが実装するプラグイン API のバージョン。
pub fn plugin_api_version() -> Int {
  1
}

/// プラグイン名。ダッシュボードとログの識別子。
pub fn plugin_name() -> String {
  "profile"
}

/// 何もしない。`docs/plugin-api.md` 第 2 章の表が `handle_event/1` か `/2` の
/// どちらかを必須にしているために置くだけで、このプラグインは受信したイベントを
/// 処理しない（ページを開いたときにリレーから取り直す）。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}

/// 管理 UI に供給するページの一覧。本体は読み込み時に 1 度だけ検証する。
pub fn plugin_pages() -> Dynamic {
  page.pages()
}

/// 送信の結果を 1 回の描画まで保持する子（`profile_store`）を申告する。設定を
/// 要らないのでアリティ 0。この子は送信の結果を持つだけで、落ちてもプロフィール
/// そのものは失われない（次に開いたときにリレーから取り直すため）。
@external(erlang, "profile_store", "child_specs")
pub fn plugin_children() -> Dynamic

/// 管理 UI のページの記述。`config` の予約キー `Accounts`（`docs/plugin-api.md`
/// 第 13.5 節）から登録アカウントの一覧を読み、`fetch_profiles` で公開鍵ごとに
/// 最新の kind 0 を取り、直前の送信の結果（`profile_store:take/1`、取り出しと
/// 同時に削除）と合わせて `page.content` に渡す。
pub fn plugin_page_content(_key: Dynamic, config: Dynamic) -> Dynamic {
  let settings =
    decode.run(config, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  let accounts = accounts_from_config(settings)
  let pubkeys = list.map(accounts, fn(account) { account.pubkey })
  let fetched = fetch_profiles(pubkeys) |> list.map(page.fetched)
  let submissions =
    list.map(pubkeys, fn(pubkey) { page.submission(store_take(pubkey)) })
  page.content(accounts, fetched, submissions)
}

/// `config` の予約キー `Accounts` から登録アカウントの一覧を読む。キーが無い・
/// JSON として読めなければ `[]`。
fn accounts_from_config(
  settings: dict.Dict(String, String),
) -> List(page.Account) {
  dict.get(settings, "Accounts")
  |> result.map(page.accounts)
  |> result.unwrap([])
}

/// `profile` ページのフォームの送信を受け取る。`key` が `profile` でなければ
/// `error_tuple("unknown page")`。処理の詳細は `handle_submit/2` を参照。
pub fn plugin_page_action(
  key: Dynamic,
  values: Dynamic,
  config: Dynamic,
) -> Dynamic {
  case decode.run(key, decode.string) {
    Ok("profile") -> handle_submit(values, config)
    _ -> error_tuple("unknown page")
  }
}

/// 送信を `page.submitted/1` で検証し、送信元のアカウントが登録アカウントに
/// あることを確かめてから `submit_profile/1` へ渡す。ここで拒否する 3 つの誤り
/// （項目の無い送信、複数アカウントの混在、未登録の公開鍵）は管理 UI のフォーム
/// からは起こらない送信なので `{error, Reason}` を返してよい（親 #448 の
/// 「常に `ok` を返す」の例外）。
fn handle_submit(values: Dynamic, config: Dynamic) -> Dynamic {
  let values_dict =
    decode.run(values, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  case page.submitted(values_dict) {
    Error(reason) -> error_tuple(reason)
    Ok(submitted) -> {
      let settings =
        decode.run(config, decode.dict(decode.string, decode.string))
        |> result.unwrap(dict.new())
      let known =
        accounts_from_config(settings)
        |> list.any(fn(account) { account.pubkey == submitted.pubkey })
      case known {
        False -> error_tuple("unknown account")
        True -> submit_profile(submitted)
      }
    }
  }
}

/// 対象アカウントの kind 0 を取り直し、送信された 8 項目を差し替えて送る。結果
/// （成否・文言・送信された値）は `profile_store:put/2` に保持し、常に `ok` を
/// 返す（`{error, Reason}` は 503 になり、入力した 8 項目が失われるため）。
fn submit_profile(submitted: page.Submitted) -> Dynamic {
  let fields = page.submitted_fields(submitted)
  case
    fetch_profiles_before_submit([submitted.pubkey], action_fetch_timeout_ms)
    |> list.first
  {
    Error(Nil) ->
      fail_submission(
        submitted.pubkey,
        fields,
        "the plugin API returned an unexpected value",
      )
    Ok(raw) ->
      case page.fetched(raw) {
        page.Failed(reason:) ->
          fail_submission(submitted.pubkey, fields, reason)
        page.Found(content:, ..) ->
          publish_submission(submitted.pubkey, content, fields)
        page.NotFound -> publish_submission(submitted.pubkey, "{}", fields)
      }
  }
}

/// 取得した `content` に `fields` を差し替えた kind 0 を送り、結果を保持する。
fn publish_submission(
  pubkey: String,
  content: String,
  fields: List(#(String, String)),
) -> Dynamic {
  let merged = page.merged_content(content, fields)
  case decode.run(publish_profile(pubkey, merged), publish_result_decoder()) {
    Ok(#("ok", _reason)) -> {
      store_put(pubkey, ok_result("Profile updated."))
      ok_atom()
    }
    Ok(#(_status, reason)) -> fail_submission(pubkey, fields, reason)
    Error(_errors) ->
      fail_submission(
        pubkey,
        fields,
        "the plugin API returned an unexpected value",
      )
  }
}

/// `publish_profile` が返す map の `status` / `reason` のデコーダー。
fn publish_result_decoder() -> decode.Decoder(#(String, String)) {
  use status <- decode.field("status", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(#(status, reason))
}

/// 失敗を `profile_store` に保持し、`ok` を返す。`fields` はフォームへ戻す
/// 送信された値。
fn fail_submission(
  pubkey: String,
  fields: List(#(String, String)),
  reason: String,
) -> Dynamic {
  store_put(
    pubkey,
    error_result("Could not update the profile: " <> reason, fields),
  )
  ok_atom()
}

/// 成功を `profile_store` に保持する形の Dynamic。
fn ok_result(message: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("status"), dynamic.string("ok")),
    #(dynamic.string("message"), dynamic.string(message)),
  ])
}

/// 失敗を `profile_store` に保持する形の Dynamic。`values` は再送信のために
/// フォームへ戻す 8 項目。
fn error_result(message: String, values: List(#(String, String))) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("status"), dynamic.string("error")),
    #(dynamic.string("message"), dynamic.string(message)),
    #(
      dynamic.string("values"),
      dynamic.properties(
        list.map(values, fn(field) {
          #(dynamic.string(field.0), dynamic.string(field.1))
        }),
      ),
    ),
  ])
}

/// 更新の送信の直前に kind 0 を取り直すときの上限（ミリ秒）。
/// `plugin_page_action` 1 回の期限（既定 5 秒、`docs/plugin-api.md` 第 13.1 節）
/// のうち、この取得に 2000ms を使い、残りを `publish_event` に充てる。
const action_fetch_timeout_ms = 2000

/// 公開鍵ごとに最新の kind 0 を並行で取得する。要素は `status`・`content`・
/// `created_at`・`reason` を持つ binary キーの map で、`page.fetched` が読む。
/// 上限は `profile_ffi:?FETCH_ALL_TIMEOUT_MS`（4000ms）。
@external(erlang, "profile_ffi", "fetch_profiles")
fn fetch_profiles(pubkeys: List(String)) -> List(Dynamic)

/// `fetch_profiles/1` と同じだが上限を明示する。更新の送信の直前に取り直す
/// ときに使う（`submit_profile/1`）。
@external(erlang, "profile_ffi", "fetch_profiles")
fn fetch_profiles_before_submit(
  pubkeys: List(String),
  timeout_ms: Int,
) -> List(Dynamic)

/// 登録アカウントの名義で kind 0 を送る。返り値は `status` / `reason` を持つ
/// binary キーの map（`publish_result_decoder/0` が読む）。
@external(erlang, "profile_ffi", "publish_profile")
fn publish_profile(pubkey: String, content: String) -> Dynamic

/// `profile_store:put/2` の `@external`。
@external(erlang, "profile_store", "put")
fn store_put(pubkey: String, result: Dynamic) -> Dynamic

/// `profile_store:take/1` の `@external`。結果が無ければ `none` の atom を返す
/// （`page.submission/1` はそれを `None` に読む）。
@external(erlang, "profile_store", "take")
fn store_take(pubkey: String) -> Dynamic

/// 設定・送信を拒否する戻り値。本体はこれを見てこのプラグインだけを読み込まない、
/// またはフォームの送信を 503 にする。
@external(erlang, "profile_ffi", "error_tuple")
fn error_tuple(reason: String) -> Dynamic

/// Gleam の `Ok(Nil)` を `plugin_page_action` が要求する `ok` の atom に潰す。
@external(erlang, "profile_ffi", "ok_atom")
fn ok_atom() -> Dynamic
