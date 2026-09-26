//// 再開点を Postgres に保存する。監視の購読の再開点はリレーごとに
//// `monitor_resume`、プラグインごとの再開点はプラグイン名ごとに `plugin_resume`
//// に置く。
////
//// テーブルは本体の移行（`db.migrations`）で作るので、バンカーの
//// 読み込みが 1 回成功した後に使う（`docs/architecture.md` の「監視の購読」と
//// 「アカウントの読み込み」の節）。クエリーは `db.execute` を通し、
//// 例外も値で返す。

import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nostr_no_su/db.{type StoreError, type Timeouts}
import pog

/// 再開点を置くテーブル。
pub type Table {
  /// 監視の購読の再開点（`monitor_resume`）。キーはリレーの URL。
  Monitor
  /// プラグインごとの再開点（`plugin_resume`）。キーはプラグイン名
  /// （`plugin_name/0` の値）。
  Plugin
}

/// リレー 1 本の再開点の読み込み。
const monitor_select_sql = "SELECT since FROM monitor_resume WHERE relay_url = $1"

/// リレー 1 本の再開点の保存。値を小さくしない（`GREATEST`）。
const monitor_upsert_sql = "INSERT INTO monitor_resume (relay_url, since)
VALUES ($1, $2)
ON CONFLICT (relay_url) DO UPDATE
SET since = GREATEST(monitor_resume.since, EXCLUDED.since), updated_at = now()"

/// プラグイン 1 つの再開点の読み込み。
const plugin_select_sql = "SELECT since FROM plugin_resume WHERE plugin = $1"

/// プラグイン 1 つの再開点の保存。値を小さくしない（`GREATEST`）。
const plugin_upsert_sql = "INSERT INTO plugin_resume (plugin, since)
VALUES ($1, $2)
ON CONFLICT (plugin) DO UPDATE
SET since = GREATEST(plugin_resume.since, EXCLUDED.since), updated_at = now()"

/// `table` の再開点を 1 行読む SQL。
fn select_sql(table: Table) -> String {
  case table {
    Monitor -> monitor_select_sql
    Plugin -> plugin_select_sql
  }
}

/// `table` の再開点を 1 行保存する SQL。
fn upsert_sql(table: Table) -> String {
  case table {
    Monitor -> monitor_upsert_sql
    Plugin -> plugin_upsert_sql
  }
}

/// `table` の `key` の保存済みの再開点。行が無ければ `Ok(None)`。期限は
/// `timeouts.write_ms`（主キーの 1 行の読み込みなので書き込みと同じ期限）。
pub fn load(
  db: pog.Connection,
  table: Table,
  key: String,
  timeouts: Timeouts,
) -> Result(Option(Int), StoreError) {
  pog.query(select_sql(table))
  |> pog.parameter(pog.text(key))
  |> pog.timeout(timeouts.write_ms)
  |> pog.returning(decode.at([0], decode.int))
  |> db.execute(db)
  |> result.map(fn(returned) {
    case returned.rows {
      [since] -> Some(since)
      _ -> None
    }
  })
}

/// `points` の再開点を `table` に保存する。1 キー 1 文で、値を小さくせずに書く。
/// 行ごとに独立なので、途中で失敗しても書けた行は正しい。期限は 1 文ごとに
/// `timeouts.write_ms`。
pub fn save(
  db: pog.Connection,
  table: Table,
  points: List(#(String, Int)),
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  use #(key, since) <- list.try_each(points)
  pog.query(upsert_sql(table))
  |> pog.parameter(pog.text(key))
  |> pog.parameter(pog.int(since))
  |> pog.timeout(timeouts.write_ms)
  |> db.execute(db)
  |> result.replace(Nil)
}
