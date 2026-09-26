//// バンカーアカウントを Postgres の `bunker_accounts` テーブルに保存する。
////
//// SQL と pog の呼び出しだけを持ち、暗号化と行の検証は `vault` に任せる。nonce の
//// 乱数はこの層で引く。DB へ送るのは暗号文だけで、平文もマスターキーも DB へは
//// 出ない。承認済みのセッション（`bunker_sessions`）と承認待ちの接続要求
//// （`bunker_pending`）も同じ DB に保存し、`load_within` が同じトランザクションで読む。
//// この 2 表の行には書き込みのたびに `vault.row_mac` の MAC を付け、読み込みでは
//// MAC の合わない行を使わずに `Stored.rejected` に分ける。
////
//// テーブルの作成、期限、トランザクション、クエリーの実行と失敗の値（`StoreError`）は
//// `db` のものを使う。読み込みは一覧を読む前に `db.ensure_schema` でスキーマを
//// 最新の版にする。

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/result
import nostr_no_su/bunker/session.{
  type Pending, type Session, type SessionKey, Pending, Session,
}
import nostr_no_su/bunker/vault.{type MasterKey}
import nostr_no_su/crypto/aes_gcm
import nostr_no_su/db.{type StoreError, type Timeouts}
import nostr_no_su/hex
import pog

/// 読み込みのトランザクションの中で、ロックの待ちの上限を設定する（ミリ秒）。
/// クライアントが期限で諦めた後に、サーバーのバックエンドがロックを待ち続けないため。
const lock_timeout_sql = "SELECT set_config('lock_timeout', $1, true)"

/// 実行中の書き込み（ROW EXCLUSIVE）の終了を待つためのロック。PostgreSQL は列挙の
/// 順に 1 つずつロックを取るので、書き手の順に合わせる（docs/architecture.md）。
const lock_sql = "LOCK TABLE bunker_accounts, bunker_pending, bunker_sessions IN SHARE MODE"

/// 全行の読み込み。表示とテストが安定するよう登録順に並べる。
const select_sql = "SELECT pubkey, label, encrypted_privkey, encrypted_secret
FROM bunker_accounts
ORDER BY created_at, pubkey"

/// 1 行の挿入。
const insert_sql = "INSERT INTO bunker_accounts (pubkey, label, encrypted_privkey, encrypted_secret)
VALUES ($1, $2, $3, $4)"

/// 主キーの制約名。これに違反した挿入は、同じ公開鍵の登録済みを意味する。
const primary_key_constraint = "bunker_accounts_pkey"

/// 1 行の削除。
const delete_sql = "DELETE FROM bunker_accounts WHERE pubkey = $1"

/// 接続 secret の差し替え。
const update_secret_sql = "UPDATE bunker_accounts SET encrypted_secret = $2 WHERE pubkey = $1"

/// ラベルの差し替え。
const update_label_sql = "UPDATE bunker_accounts SET label = $2 WHERE pubkey = $1"

/// セッションの一覧。テストの安定のための順。
const select_sessions_sql = "SELECT signer, client, perms, created_at, last_used_at, mac, relays
FROM bunker_sessions
ORDER BY created_at, signer, client"

/// 承認待ちの一覧。テストの安定のための順。
const select_pending_sql = "SELECT token, signer, client, request_id, perms, secret_mismatch, created_at, mac
FROM bunker_pending
ORDER BY created_at, token"

/// セッションの挿入。同じ（signer, client）があれば全列と MAC をこの値で
/// 上書きする。
const insert_session_sql = "INSERT INTO bunker_sessions (signer, client, perms, created_at, last_used_at, mac, relays)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (signer, client) DO UPDATE
SET perms = EXCLUDED.perms, created_at = EXCLUDED.created_at, last_used_at = EXCLUDED.last_used_at, mac = EXCLUDED.mac, relays = EXCLUDED.relays"

/// 最終利用の更新。時刻が進むときだけ、全列と MAC を書き換える。
const touch_session_sql = "UPDATE bunker_sessions SET perms = $3, created_at = $4, last_used_at = $5, mac = $6, relays = $7 WHERE signer = $1 AND client = $2 AND last_used_at < $5"

/// 権限の更新。全列と MAC を書き換える。
const update_session_perms_sql = "UPDATE bunker_sessions SET perms = $3, created_at = $4, last_used_at = $5, mac = $6, relays = $7 WHERE signer = $1 AND client = $2"

/// セッションの削除。
const delete_session_sql = "DELETE FROM bunker_sessions WHERE signer = $1 AND client = $2"

/// 承認待ちの挿入。同じ token があれば何もしない。
const insert_pending_sql = "INSERT INTO bunker_pending (token, signer, client, request_id, perms, secret_mismatch, created_at, mac)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (token) DO NOTHING"

/// 承認待ちの削除。
const delete_pending_sql = "DELETE FROM bunker_pending WHERE token = $1"

/// `load_within` が 1 つのトランザクションで読み込んだ全体。
pub type Stored {
  Stored(
    /// 復号できたアカウントと、復号できずに飛ばした行。
    accounts: vault.Loaded,
    /// 承認済みのセッション（`created_at`、`signer`、`client` の順）。
    sessions: List(Session),
    /// 承認待ちの接続要求（`created_at`、`token` の順）。
    pending: List(Pending),
    /// MAC の合わない行（セッション、承認待ちの順）。どちらも元の行の順序を保つ。
    rejected: List(vault.MacRow),
  )
}

/// スキーマを最新の版に移行してから、アカウント、承認済みのセッション、承認待ちの
/// 接続要求を読み込む。アカウントは復号できた行と飛ばした行に分ける
/// （`vault.open_rows`）。セッションと承認待ちは行の MAC を `key` で検証し、
/// 合わない行（列を書き換えた行、別の行の MAC を移した行、空の MAC の行）は
/// `sessions` と `pending` に入れずに `rejected` に分ける。3 つのうちどれかの
/// 読み込みが `Error` なら全体を `Error` にする。`db.transaction` の中で呼ぶ。
///
/// 一覧を読む前に `LOCK TABLE bunker_accounts, bunker_pending, bunker_sessions
/// IN SHARE MODE` を取る（`lock_sql`）。SHARE は実行中の書き込みの ROW EXCLUSIVE と
/// 衝突するので、期限を過ぎてもサーバー側で実行を続ける書き込みがあれば、その終了を
/// 待ってから読む。残る窓と測定の値は docs/architecture.md の「アカウントの変更」。
/// `relays` の書き手はバンカーではないので、このロックには含めない。
pub fn load_within(
  db: pog.Connection,
  key: MasterKey,
  timeouts: Timeouts,
) -> Result(Stored, StoreError) {
  use _set <- result.try(
    pog.query(lock_timeout_sql)
    |> pog.parameter(pog.text(int.to_string(timeouts.load_ms)))
    |> db.execute(db),
  )
  use Nil <- result.try(db.ensure_schema(db))
  use _locked <- result.try(pog.query(lock_sql) |> db.execute(db))
  use accounts <- result.try(
    pog.query(select_sql)
    |> pog.returning(row_decoder())
    |> db.execute(db),
  )
  use sessions <- result.try(
    pog.query(select_sessions_sql)
    |> pog.returning(session_decoder())
    |> db.execute(db),
  )
  use pending <- result.try(
    pog.query(select_pending_sql)
    |> pog.returning(pending_decoder())
    |> db.execute(db),
  )
  let #(sessions_list, rejected_sessions) =
    split_by_mac(key, sessions.rows, vault.SessionMacRow)
  let #(pending_list, rejected_pending) =
    split_by_mac(key, pending.rows, vault.PendingMacRow)
  Ok(Stored(
    accounts: vault.open_rows(key, accounts.rows),
    sessions: sessions_list,
    pending: pending_list,
    rejected: list.append(rejected_sessions, rejected_pending),
  ))
}

/// アカウントを 1 件追加する。同じ公開鍵がすでにあれば `db.Duplicate`（主キーの
/// 制約違反）。
pub fn insert(
  db: pog.Connection,
  key: MasterKey,
  entry: vault.StoredAccount,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  // ストアは 12 バイトの nonce しか作らず、マスターキーは 32 バイトであることが
  // 構築時に保証されているので、暗号化は失敗しない。失敗しても表示されるのは
  // Error(Nil) と下の文言だけで、鍵も平文も含まない。
  let assert Ok(row) =
    vault.seal_row(key, entry, random_nonce(), random_nonce())
    as "a 12-byte random nonce is always accepted"
  pog.query(insert_sql)
  |> pog.parameter(pog.text(row.pubkey))
  |> pog.parameter(pog.text(row.label))
  |> pog.parameter(pog.bytea(row.encrypted_privkey))
  |> pog.parameter(pog.bytea(row.encrypted_secret))
  |> db.execute_write(db, timeouts)
  |> result.map_error(db.duplicate_on(_, primary_key_constraint))
}

/// アカウントを 1 件削除する。
pub fn delete(
  db: pog.Connection,
  pubkey: String,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(delete_sql)
  |> pog.parameter(pog.text(pubkey))
  |> db.execute_on_one_row(db, timeouts)
}

/// 接続 secret を差し替える。`pubkey` が 16 進として読めないときは、列の制約上
/// その行は存在しえないので `db.NotFound` にする。
pub fn update_secret(
  db: pog.Connection,
  key: MasterKey,
  pubkey: String,
  secret: String,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  use pubkey_bytes <- result.try(
    hex.decode(pubkey) |> result.replace_error(db.NotFound),
  )
  // `insert` と同じ理由で、暗号化は失敗しない。
  let assert Ok(encrypted_secret) =
    vault.seal(
      key,
      vault.ConnectionSecret,
      pubkey_bytes,
      bit_array.from_string(secret),
      random_nonce(),
    )
    as "a 12-byte random nonce is always accepted"
  pog.query(update_secret_sql)
  |> pog.parameter(pog.text(pubkey))
  |> pog.parameter(pog.bytea(encrypted_secret))
  |> db.execute_on_one_row(db, timeouts)
}

/// ラベルを差し替える。
pub fn update_label(
  db: pog.Connection,
  pubkey: String,
  label: String,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(update_label_sql)
  |> pog.parameter(pog.text(pubkey))
  |> pog.parameter(pog.text(label))
  |> db.execute_on_one_row(db, timeouts)
}

/// セッション `session` を 1 件追加する。同じ（signer, client）の組がすでに
/// あれば、全列と MAC をこの値で上書きする。MAC の合わない行が主キーを塞いで
/// 正しい承認が保存されなくなるのを防ぐためで、2 インスタンスが並ぶ窓で両方が
/// 同じ値を挿す場合も吸収する。
pub fn insert_session(
  db: pog.Connection,
  key: MasterKey,
  session session: Session,
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  write_session_row(db, key, insert_session_sql, session, timeouts)
}

/// セッションの最終利用を `session.last_used_at` に進め、行の全列と MAC を
/// `session` の値にする。行が無いか、すでに `session.last_used_at` 以上なら
/// 何もせず `Ok`（2 インスタンスが並ぶ窓で後退させない）。
pub fn touch_session(
  db: pog.Connection,
  key: MasterKey,
  session session: Session,
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  write_session_row(db, key, touch_session_sql, session, timeouts)
}

/// セッションの権限を `session.perms` に差し替え、行の全列と MAC を `session` の
/// 値にする。行が無ければ何もせず `Ok`。
pub fn update_session_perms(
  db: pog.Connection,
  key: MasterKey,
  session session: Session,
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  write_session_row(db, key, update_session_perms_sql, session, timeouts)
}

/// `sql`（`insert_session_sql`、`touch_session_sql`、`update_session_perms_sql`
/// のどれか）で、（signer, client）の行の全列と MAC を `session` の値にする。
fn write_session_row(
  db: pog.Connection,
  key: MasterKey,
  sql: String,
  session: Session,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(sql)
  |> pog.parameter(pog.text(session.signer))
  |> pog.parameter(pog.text(session.client))
  |> pog.parameter(pog.text(session.perms))
  |> pog.parameter(pog.int(session.created_at))
  |> pog.parameter(pog.int(session.last_used_at))
  |> pog.parameter(pog.bytea(vault.row_mac(key, vault.SessionMacRow(session))))
  |> pog.parameter(pog.array(pog.text, session.relays))
  |> db.execute_write(db, timeouts)
}

/// セッションを 1 件取り消す。行が無くても `Ok`。
pub fn delete_session(
  db: pog.Connection,
  signer signer: String,
  client client: String,
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(delete_session_sql)
  |> pog.parameter(pog.text(signer))
  |> pog.parameter(pog.text(client))
  |> db.execute_write(db, timeouts)
}

/// `keys` の組をすべて `delete_session` で消す。行が無くても `Ok`。
fn delete_sessions(
  db: pog.Connection,
  keys: List(SessionKey),
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  list.try_each(keys, fn(key) {
    delete_session(db, signer: key.signer, client: key.client, timeouts:)
  })
}

/// セッション `session` を 1 件追加し（同じ組があれば上書きする。
/// `insert_session`）、`evicted` の組を消す。1 トランザクションで行うので、
/// 挿入だけが残ることは無い。
pub fn insert_session_evicting(
  pool: Name(pog.Message),
  key: MasterKey,
  session session: Session,
  evicted evicted: List(SessionKey),
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  db.transaction(pool, timeouts.write_ms, fn(db) {
    use Nil <- result.try(insert_session(db, key, session: session, timeouts:))
    delete_sessions(db, evicted, timeouts)
  })
}

/// 承認待ちの接続要求を 1 件追加する。同じ `token` がすでにあれば何もしない
/// （2 インスタンスが並ぶ窓を吸収する）。
pub fn insert_pending(
  db: pog.Connection,
  key: MasterKey,
  pending: Pending,
  timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(insert_pending_sql)
  |> pog.parameter(pog.text(pending.token))
  |> pog.parameter(pog.text(pending.signer))
  |> pog.parameter(pog.text(pending.client))
  |> pog.parameter(pog.text(pending.request_id))
  |> pog.parameter(pog.text(pending.perms))
  |> pog.parameter(pog.bool(pending.secret_mismatch))
  |> pog.parameter(pog.int(pending.created_at))
  |> pog.parameter(pog.bytea(vault.row_mac(key, vault.PendingMacRow(pending))))
  |> db.execute_write(db, timeouts)
}

/// 承認待ちの接続要求を 1 件取り除く。行が無くても `Ok`。
pub fn delete_pending(
  db: pog.Connection,
  token token: String,
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  pog.query(delete_pending_sql)
  |> pog.parameter(pog.text(token))
  |> db.execute_write(db, timeouts)
}

/// 承認待ちの接続要求 `token` を承認する。1 トランザクションでその行を消し、
/// セッション `session` を追加し（同じ組があれば上書きする。`insert_session`）、
/// `evicted` の組を消す。承認の値の出どころはエンジンのメモリなので、消した行から
/// 読み返さない。`DELETE … RETURNING` で拾うと、2 インスタンスが並ぶ窓で別の
/// インスタンスが先に消していた場合にセッションを作れなくなるためである。承認待ちの
/// 行が無くても追加する。
pub fn approve(
  pool: Name(pog.Message),
  key: MasterKey,
  token token: String,
  session session: Session,
  evicted evicted: List(SessionKey),
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  db.transaction(pool, timeouts.write_ms, fn(db) {
    use Nil <- result.try(delete_pending(db, token: token, timeouts:))
    use Nil <- result.try(insert_session(db, key, session: session, timeouts:))
    delete_sessions(db, evicted, timeouts)
  })
}

/// 同じ組の古い承認待ち `replaced` と、上限で押し出す承認待ち `evicted` を消し、
/// `pending` を登録する。1 トランザクションで行うので、削除だけが残ることは無い。
pub fn insert_pending_replacing(
  pool: Name(pog.Message),
  key: MasterKey,
  pending pending: Pending,
  replaced replaced: List(String),
  evicted evicted: List(String),
  timeouts timeouts: Timeouts,
) -> Result(Nil, StoreError) {
  db.transaction(pool, timeouts.write_ms, fn(db) {
    use Nil <- result.try(
      list.try_each(list.append(replaced, evicted), delete_pending(
        db,
        token: _,
        timeouts:,
      )),
    )
    insert_pending(db, key, pending, timeouts)
  })
}

/// 削除の結果で、行が無かったこと（`db.NotFound`）を成功に写す。削除は行が無い
/// 状態にすることが目的なので、タイムアウトした削除がサーバー側でコミットされて
/// いた場合や、DB の外で行を消した場合にも、呼び出し側が削除を完了できるようにする。
pub fn deleted_or_absent(
  result: Result(Nil, StoreError),
) -> Result(Nil, StoreError) {
  case result {
    Error(db.NotFound) -> Ok(Nil)
    other -> other
  }
}

/// アカウントの操作の失敗の説明。行の重複と行が無いことをアカウントの語で言い、
/// それ以外は `db.describe` に任せる。
pub fn describe(error: StoreError) -> String {
  case error {
    db.Duplicate -> "account is already registered"
    db.NotFound -> "account is not registered"
    _ -> db.describe(error)
  }
}

/// 暗号化 1 回ぶんの nonce。
fn random_nonce() -> BitArray {
  crypto.strong_random_bytes(aes_gcm.nonce_bytes)
}

/// `bunker_accounts` の 1 行を読むデコーダー。列の順序は `select_sql` と同じ。
fn row_decoder() -> decode.Decoder(vault.Row) {
  use pubkey <- decode.field(0, decode.string)
  use label <- decode.field(1, decode.string)
  use encrypted_privkey <- decode.field(2, decode.bit_array)
  use encrypted_secret <- decode.field(3, decode.bit_array)
  decode.success(vault.Row(
    pubkey: pubkey,
    label: label,
    encrypted_privkey: encrypted_privkey,
    encrypted_secret: encrypted_secret,
  ))
}

/// `bunker_sessions` の 1 行を、値と MAC の組にして読むデコーダー。列の順序は
/// `select_sessions_sql` と同じ。
fn session_decoder() -> decode.Decoder(#(Session, BitArray)) {
  use signer <- decode.field(0, decode.string)
  use client <- decode.field(1, decode.string)
  use perms <- decode.field(2, decode.string)
  use created_at <- decode.field(3, decode.int)
  use last_used_at <- decode.field(4, decode.int)
  use mac <- decode.field(5, decode.bit_array)
  use relays <- decode.field(6, decode.list(decode.string))
  decode.success(#(
    Session(signer:, client:, perms:, created_at:, last_used_at:, relays:),
    mac,
  ))
}

/// `bunker_pending` の 1 行を、値と MAC の組にして読むデコーダー。列の順序は
/// `select_pending_sql` と同じ。
fn pending_decoder() -> decode.Decoder(#(Pending, BitArray)) {
  use token <- decode.field(0, decode.string)
  use signer <- decode.field(1, decode.string)
  use client <- decode.field(2, decode.string)
  use request_id <- decode.field(3, decode.string)
  use perms <- decode.field(4, decode.string)
  use secret_mismatch <- decode.field(5, decode.bool)
  use created_at <- decode.field(6, decode.int)
  use mac <- decode.field(7, decode.bit_array)
  decode.success(#(
    Pending(
      token:,
      signer:,
      client:,
      request_id:,
      perms:,
      secret_mismatch:,
      created_at:,
    ),
    mac,
  ))
}

/// 読んだ行（値と MAC の組）を、MAC の合う値と、合わない行の MAC の対象に
/// 分ける。どちらも元の順序を保つ。
fn split_by_mac(
  key: MasterKey,
  rows: List(#(row, BitArray)),
  mac_row: fn(row) -> vault.MacRow,
) -> #(List(row), List(vault.MacRow)) {
  let #(matching, rejected) =
    list.partition(rows, fn(pair) {
      vault.verify_row_mac(key, mac_row(pair.0), pair.1)
    })
  #(
    list.map(matching, fn(pair) { pair.0 }),
    list.map(rejected, fn(pair) { mac_row(pair.0) }),
  )
}
