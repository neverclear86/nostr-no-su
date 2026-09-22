//// 登録アカウントの現在のプロフィール（kind 0）を管理 UI に出す外部プラグイン
//// （API v1）。DB も状態も持たない。プロフィールは保持せず、ページを開いたときに
//// 毎回 `nostr_no_su@plugin_api:fetch_event(Pubkey, 0)`（`docs/plugin-api.md`
//// 第 14.7 節）でリレーから最新の 1 件を取る。取得はアカウントごとに並行で行い、
//// 総上限 4000ms で打ち切る（`plugins-src/profile/src/profile_ffi.erl` を参照）。
//// ページの期限（既定 5 秒、同文書第 13.1 節）にアカウントの件数やリレーの応答に
//// よらず収めるためである。
////
//// 本体（nostr_no_su）とは別のプロジェクトとしてビルドする。docker イメージでは
//// Dockerfile の `plugin-build-profile` ステージがビルドし、
//// `gleam export erlang-shipment` の出力が `/app/plugins/profile/` に入る。改造版を
//// 自分でビルドして `PLUGIN_DIR` の下へ置くこともできる。置き方とビルド手順は
//// 同ディレクトリーの README を参照すること。

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

/// 管理 UI のページの記述。`config` の予約キー `Accounts`（`docs/plugin-api.md`
/// 第 13.5 節）から登録アカウントの一覧を読み、`fetch_profiles` で公開鍵ごとに
/// 最新の kind 0 を取ってから `page.content` に渡す。
pub fn plugin_page_content(_key: Dynamic, config: Dynamic) -> Dynamic {
  let settings =
    decode.run(config, decode.dict(decode.string, decode.string))
    |> result.unwrap(dict.new())
  let accounts = accounts_from_config(settings)
  let fetched =
    fetch_profiles(list.map(accounts, fn(account) { account.pubkey }))
    |> list.map(page.fetched)
  page.content(accounts, fetched)
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

/// 公開鍵ごとに最新の kind 0 を並行で取得する。要素は `status`・`content`・
/// `created_at`・`reason` を持つ binary キーの map で、`page.fetched` が読む。
@external(erlang, "profile_ffi", "fetch_profiles")
fn fetch_profiles(pubkeys: List(String)) -> List(Dynamic)
