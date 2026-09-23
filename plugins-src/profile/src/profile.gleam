//// 登録アカウントの現在のプロフィール（kind 0）を管理 UI に出す外部プラグイン
//// （API v1）。DB は持たない。ページを開くと、キャッシュに無いアカウントの
//// kind 0 を `nostr_no_su@plugin_api:fetch_events(Pubkeys, 0)`
//// （`docs/plugin-api.md` 第 14.10 節）の 1 回の呼び出しでまとめてリレーから
//// 取る。本体はリレー 1 本につき接続 1 本と REQ 1 件で問い合わせるので、1 回の
//// 描画で開く接続はアカウントの件数によらずリレーの本数までである。取れた
//// kind 0（無かったことを含む）は `cache_ttl_ms`（60 秒）の間キャッシュし、
//// その間の描画はリレーに問い合わせない。持つ状態はこのキャッシュと直前の更新の
//// 送信の結果で、どちらも `plugin_children/0` で申告する `profile_store` が
//// 揮発で保持する。
////
//// 本体（nostr_no_su）とは別のプロジェクトとしてビルドする。docker イメージでは
//// Dockerfile の `plugin-build-profile` ステージがビルドし、
//// `gleam export erlang-shipment` の出力が `/app/plugins/profile/` に入る。改造版を
//// 自分でビルドして `PLUGIN_DIR` の下へ置くこともできる。置き方とビルド手順は
//// 同ディレクトリーの README を参照すること。
////
//// 更新はフォームの送信のたびに、送信の直前に対象アカウントの kind 0 を
//// キャッシュを使わずに取得し直す。取得した内容に送信された 8 項目を差し替え、
//// 未知のキーは残したまま新しい kind 0 として送る。送信に成功したら送った
//// kind 0 をキャッシュに入れ、送信後のリダイレクトで開き直したページはリレーに
//// 問い合わせずにそれを出す。送信の成否と文言は `profile_store` に保持し、
//// 次にこのページを開いたときの `alert` として 1 回だけ出る。

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
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
/// 処理しない（プロフィールはページを開いたときにキャッシュかリレーから得る）。
pub fn handle_event(_event: Dynamic) -> Nil {
  Nil
}

/// 管理 UI に供給するページの一覧。本体は読み込み時に 1 度だけ検証する。
pub fn plugin_pages() -> Dynamic {
  page.pages()
}

/// 送信の結果と取得のキャッシュを保持する子（`profile_store`）を申告する。
/// 設定を要らないのでアリティ 0。この子が落ちると保持していた送信の結果と
/// キャッシュは失われるが、プロフィールそのものは失われない（次に開いたときに
/// リレーから取り直すため）。
@external(erlang, "profile_store", "child_specs")
pub fn plugin_children() -> Dynamic

/// 管理 UI のページの記述。`config` の予約キー `Accounts`（`docs/plugin-api.md`
/// 第 13.5 節）から登録アカウントの一覧を読み、`current_profiles` で公開鍵ごとの
/// kind 0 を得て、直前の送信の結果（`profile_store:take/1`、取り出しと同時に
/// 削除）と合わせて `page.content` に渡す。
pub fn plugin_page_content(_key: Dynamic, config: Dynamic) -> Dynamic {
  let settings =
    decode.run(config, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  let accounts = accounts_from_config(settings)
  let pubkeys = list.map(accounts, fn(account) { account.pubkey })
  let fetched = current_profiles(pubkeys)
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

/// 対象アカウントの kind 0 をキャッシュを使わずに取り直し、送信された 8 項目を
/// 差し替えて送る。結果（成否・文言・送信された値）は `profile_store:put/2` に
/// 保持し、常に `ok` を返す（`{error, Reason}` は 503 になり、入力した 8 項目が
/// 失われるため）。
fn submit_profile(submitted: page.Submitted) -> Dynamic {
  let fields = page.submitted_fields(submitted)
  case
    fetch_profiles([submitted.pubkey])
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
  finish_submission(pubkey, merged, fields, publish_profile(pubkey, merged))
}

/// `publish_profile` の戻り値 `published` から送信の結果を `profile_store` に
/// 保持し、`ok` を返す。成功なら送った `merged` と本体が付けた `created_at` を
/// `Found` としてキャッシュに入れる（送信後のリダイレクトで開き直したページが
/// リレーに問い合わせずに送った内容を出すため）。失敗ならキャッシュは変えず、
/// `fields` をフォームへ戻す値として保持する。`profile_test` の
/// `finish_submission_caches_the_published_profile_test` が参照するため公開する。
pub fn finish_submission(
  pubkey: String,
  merged: String,
  fields: List(#(String, String)),
  published: Dynamic,
) -> Dynamic {
  case decode.run(published, publish_result_decoder()) {
    Ok(#("ok", _reason, created_at)) -> {
      let _ =
        cache_put(
          pubkey,
          page.Found(content: merged, created_at:),
          cache_ttl_ms,
        )
      store_put(pubkey, ok_result("Profile updated."))
      ok_atom()
    }
    Ok(#(_status, reason, _created_at)) ->
      fail_submission(pubkey, fields, reason)
    Error(_errors) ->
      fail_submission(
        pubkey,
        fields,
        "the plugin API returned an unexpected value",
      )
  }
}

/// `publish_profile` が返す map の `status` / `reason` / `created_at` の
/// デコーダー。
fn publish_result_decoder() -> decode.Decoder(#(String, String, Int)) {
  use status <- decode.field("status", decode.string)
  use reason <- decode.field("reason", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  decode.success(#(status, reason, created_at))
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

/// 取得した kind 0 と送信した kind 0 をキャッシュに置く期間（ミリ秒）。
/// この間にページを開き直してもリレーに問い合わせない。
const cache_ttl_ms = 60_000

/// `pubkeys` の各アカウントの kind 0 を `pubkeys` の順に返す。`profile_store`
/// に期限内のキャッシュがある公開鍵はそれを使い、無い公開鍵だけを
/// `fetch_profiles` の 1 回の呼び出しで取る（全員がキャッシュにあれば呼ばない）。
/// 取れた `Found` と `NotFound` は `cache_ttl_ms` の間キャッシュし、`Failed` は
/// キャッシュしない（次の描画で取り直すため）。
fn current_profiles(pubkeys: List(String)) -> List(page.Fetched) {
  let cached = cache_get(pubkeys)
  let misses =
    list.filter_map(list.zip(pubkeys, cached), fn(pair) {
      case pair.1 {
        Some(_) -> Error(Nil)
        None -> Ok(pair.0)
      }
    })
  let fresh = fetch_profiles(misses) |> list.map(page.fetched)
  list.each(list.zip(misses, fresh), fn(pair) {
    case pair.1 {
      page.Failed(_) -> Nil
      fetched -> {
        let _ = cache_put(pair.0, fetched, cache_ttl_ms)
        Nil
      }
    }
  })
  fill_misses(cached, fresh)
}

/// `cached` の `None` の位置に、`fresh` を先頭から順に当てはめる。`fresh` は
/// `cached` の `None` の公開鍵を同じ順に取った結果である。`fresh` が足りない
/// 位置は `Failed` にする。
fn fill_misses(
  cached: List(Option(page.Fetched)),
  fresh: List(page.Fetched),
) -> List(page.Fetched) {
  let #(_remaining, filled) =
    list.map_fold(cached, fresh, fn(remaining, entry) {
      case entry, remaining {
        Some(fetched), _ -> #(remaining, fetched)
        None, [first, ..rest] -> #(rest, first)
        None, [] -> #(
          [],
          page.Failed("the plugin API returned an unexpected value"),
        )
      }
    })
  filled
}

/// 公開鍵ごとに最新の kind 0 を、本体の `fetch_events` の 1 回の呼び出しで
/// まとめて取る。要素は `pubkeys` と同じ順の、`status`・`content`・`created_at`・
/// `reason` を持つ binary キーの map で、`page.fetched` が読む。`pubkeys` が空なら
/// 本体を呼ばない。
@external(erlang, "profile_ffi", "fetch_profiles")
fn fetch_profiles(pubkeys: List(String)) -> List(Dynamic)

/// `profile_store:cache_get/1` の `@external`。Erlang の `{some, Profile}` /
/// `none` は Gleam の `Option` と同じ表現である。
@external(erlang, "profile_store", "cache_get")
fn cache_get(pubkeys: List(String)) -> List(Option(page.Fetched))

/// `profile_store:cache_put/3` の `@external`。
@external(erlang, "profile_store", "cache_put")
fn cache_put(pubkey: String, profile: page.Fetched, ttl_ms: Int) -> Dynamic

/// 登録アカウントの名義で kind 0 を送る。返り値は `status` / `reason` /
/// `created_at` を持つ binary キーの map（`publish_result_decoder/0` が読む）。
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
