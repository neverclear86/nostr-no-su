//// プラグインごとの再開点を Postgres の `plugin_resume` に保存する。テーブルは
//// 本体の移行（`account_store.migrations` の版 5）で作るので、バンカーの
//// 読み込みが 1 回成功した後に使う。

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nostr_no_su/bunker/account_store
import pog

/// クエリー 1 回の期限。主キーの 1 行の読み書きなので、`account_store` の
/// 書き込みの期限と同じ値にする。
const timeout_ms = 1000

/// プラグイン 1 つの再開点の読み込み。
const select_sql = "SELECT since FROM plugin_resume WHERE plugin = $1"

/// プラグイン 1 つの再開点の保存。値を小さくしない（`GREATEST`）。
const upsert_sql = "INSERT INTO plugin_resume (plugin, since)
VALUES ($1, $2)
ON CONFLICT (plugin) DO UPDATE
SET since = GREATEST(plugin_resume.since, EXCLUDED.since), updated_at = now()"

/// `plugin` の保存済みの再開点。行が無ければ `Ok(None)`。
pub fn load(
  db: pog.Connection,
  plugin: String,
) -> Result(Option(Int), account_store.StoreError) {
  pog.query(select_sql)
  |> pog.parameter(pog.text(plugin))
  |> pog.timeout(timeout_ms)
  |> pog.returning(decode.at([0], decode.int))
  |> account_store.execute(db)
  |> result.map(fn(returned) {
    case returned.rows {
      [since] -> Some(since)
      _ -> None
    }
  })
}

/// `points` の再開点を保存する。1 プラグイン 1 文で、値を小さくせずに書く。
/// 行ごとに独立なので、途中で失敗しても書けた行は正しい。
pub fn save(
  db: pog.Connection,
  points: List(#(String, Int)),
) -> Result(Nil, account_store.StoreError) {
  use #(plugin, since) <- list.try_each(points)
  pog.query(upsert_sql)
  |> pog.parameter(pog.text(plugin))
  |> pog.parameter(pog.int(since))
  |> pog.timeout(timeout_ms)
  |> account_store.execute(db)
  |> result.replace(Nil)
}
