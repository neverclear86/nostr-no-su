//// `relays` テーブルの読み書き。列 `observe`（監視）と `bunker`（バンカー）の組を
//// `relay_list.Roles` に写す（`roles_from`）。

import gleam/dynamic/decode
import gleam/result
import nostr_no_su/db.{type StoreError, type Timeouts}
import nostr_no_su/relay_list.{type Roles}
import pog

/// `relays` の 1 行。
pub type Relay {
  Relay(id: Int, url: String, roles: Roles)
}

/// 用途のある行の読み込み。
const select_sql = "SELECT id, url, observe, bunker FROM relays WHERE observe OR bunker ORDER BY id"

/// 1 行の挿入。
const insert_sql = "INSERT INTO relays (url, observe, bunker) VALUES ($1, $2, $3)
RETURNING id, url, observe, bunker"

/// 用途の差し替え。
const update_roles_sql = "UPDATE relays SET observe = $2, bunker = $3 WHERE id = $1"

/// 1 行の削除。
const delete_sql = "DELETE FROM relays WHERE id = $1"

/// 用途のある行を `id` の順に読む。`timeouts.load_ms` を期限にする（`load_snapshot` の
/// トランザクションの中では、同じ値が外側の期限としてすでに効いている）。
pub fn list(
  db: pog.Connection,
  timeouts: Timeouts,
) -> Result(List(Relay), StoreError) {
  pog.query(select_sql)
  |> pog.returning(relay_decoder())
  |> pog.timeout(timeouts.load_ms)
  |> db.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

/// 1 行を追加する。URL の検査は呼び出し側が行う（`relay_list.open` と
/// 同じ判定を使う）。同じ URL がすでにあれば `RelayAlreadyRegistered`。
pub fn insert(
  db: pog.Connection,
  url: String,
  roles: Roles,
  timeouts: Timeouts,
) -> Result(Relay, StoreError) {
  use returned <- result.try(
    pog.query(insert_sql)
    |> pog.parameter(pog.text(url))
    |> pog.parameter(pog.bool(relay_list.has_role(roles, relay_list.Monitor)))
    |> pog.parameter(pog.bool(relay_list.has_role(roles, relay_list.Bunker)))
    |> pog.returning(relay_decoder())
    |> pog.timeout(timeouts.write_ms)
    |> db.execute(db),
  )
  case returned.rows {
    [row] -> Ok(row)
    _ -> Error(db.QueryFailed("unexpected insert result"))
  }
}

/// `id` の行の用途を差し替える。行が無ければ `RelayNotRegistered`。
pub fn update_roles(
  db: pog.Connection,
  id: Int,
  roles: Roles,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(update_roles_sql)
  |> pog.parameter(pog.int(id))
  |> pog.parameter(pog.bool(relay_list.has_role(roles, relay_list.Monitor)))
  |> pog.parameter(pog.bool(relay_list.has_role(roles, relay_list.Bunker)))
  |> db.execute_on_one_row(db, timeouts, db.RelayNotRegistered)
}

/// `id` の行を消す。行が無ければ `RelayNotRegistered`。
pub fn delete(
  db: pog.Connection,
  id: Int,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(delete_sql)
  |> pog.parameter(pog.int(id))
  |> db.execute_on_one_row(db, timeouts, db.RelayNotRegistered)
}

/// `relays` の 1 行を読むデコーダー。列の順序は `select_sql` / `insert_sql` の
/// `RETURNING` と同じ。`observe` と `bunker` がどちらも false の行は失敗にする
/// （`select_sql` がその行を除くので、通常は通らない）。
fn relay_decoder() -> decode.Decoder(Relay) {
  use id <- decode.field(0, decode.int)
  use url <- decode.field(1, decode.string)
  use observe <- decode.field(2, decode.bool)
  use bunker <- decode.field(3, decode.bool)
  case relay_list.roles_from(monitor: observe, bunker: bunker) {
    Ok(roles) -> decode.success(Relay(id:, url:, roles:))
    Error(Nil) ->
      decode.failure(Relay(id:, url:, roles: relay_list.Both), "relay roles")
  }
}
