//// `relays` の読み書き。テーブルは本体の移行の版 4（`account_store.gleam` の
//// `create_relays_table`）で作る。クエリーはすべて `account_store.execute` を
//// 通す。列 `observe` は `relay_list.Roles.monitor` に写す（#62 の分割の設計 2）。

import gleam/dynamic/decode
import gleam/result
import nostr_no_su/bunker/account_store.{type StoreError, type Timeouts}
import nostr_no_su/relay_list.{type Roles}
import pog

/// `relays` の 1 行。
pub type Relay {
  Relay(id: Int, url: String, roles: Roles)
}

/// 全行の読み込み。
const select_sql = "SELECT id, url, observe, bunker FROM relays ORDER BY id"

/// 1 行の挿入。
const insert_sql = "INSERT INTO relays (url, observe, bunker) VALUES ($1, $2, $3)
RETURNING id, url, observe, bunker"

/// 用途の差し替え。
const update_roles_sql = "UPDATE relays SET observe = $2, bunker = $3 WHERE id = $1"

/// 1 行の削除。
const delete_sql = "DELETE FROM relays WHERE id = $1"

/// 全行を `id` の順に読む。`timeouts.load_ms` を期限にする（`load_snapshot` の
/// トランザクションの中では、同じ値が外側の期限としてすでに効いている）。
pub fn list(
  db: pog.Connection,
  timeouts: Timeouts,
) -> Result(List(Relay), StoreError) {
  pog.query(select_sql)
  |> pog.returning(relay_decoder())
  |> pog.timeout(timeouts.load_ms)
  |> account_store.execute(db)
  |> result.map(fn(returned) { returned.rows })
}

/// 1 行を追加する。URL と用途の検査は呼び出し側が行う（`relay_list.open` と
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
    |> pog.parameter(pog.bool(roles.monitor))
    |> pog.parameter(pog.bool(roles.bunker))
    |> pog.returning(relay_decoder())
    |> pog.timeout(timeouts.write_ms)
    |> account_store.execute(db),
  )
  case returned.rows {
    [row] -> Ok(row)
    _ -> Error(account_store.QueryFailed("unexpected insert result"))
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
  |> pog.parameter(pog.bool(roles.monitor))
  |> pog.parameter(pog.bool(roles.bunker))
  |> account_store.execute_on_one_row(
    db,
    timeouts,
    account_store.RelayNotRegistered,
  )
}

/// `id` の行を消す。行が無ければ `RelayNotRegistered`。
pub fn delete(
  db: pog.Connection,
  id: Int,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(delete_sql)
  |> pog.parameter(pog.int(id))
  |> account_store.execute_on_one_row(
    db,
    timeouts,
    account_store.RelayNotRegistered,
  )
}

/// `relays` の 1 行を読むデコーダー。列の順序は `select_sql` / `insert_sql` の
/// `RETURNING` と同じ。
fn relay_decoder() -> decode.Decoder(Relay) {
  use id <- decode.field(0, decode.int)
  use url <- decode.field(1, decode.string)
  use observe <- decode.field(2, decode.bool)
  use bunker <- decode.field(3, decode.bool)
  decode.success(Relay(
    id:,
    url:,
    roles: relay_list.Roles(monitor: observe, bunker: bunker),
  ))
}
