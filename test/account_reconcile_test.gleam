//// 実際の Postgres で、結果が曖昧な書き込みの後にバンカーアクターの一覧が DB と一致
//// することを確かめる統合テスト。`TEST_DATABASE_URL` があるときだけ実行する。
////
//// 専用のスキーマのテーブルに、テストの持つ advisory lock を共有で待つ BEFORE
//// トリガーを付ける。テストは書き込みの前に別の接続でその鍵を排他で取り、バンカーが
//// 期限で `MaybeApplied` を返し、読み直しの `LOCK TABLE` がその書き込みを待ち始めた
//// のを `pg_locks` で見てから離す。離すまで書き込みはコミットされないので、
//// 期限で `TimedOut` を返した後のコミットを読み直しが待つことを確かめられる。
//// 読み直しが実行中の書き込みを待たなければ、門を離す前の待ちが現れずテストが落ちる。
//// セッションの削除でも同じ。

import gleam/dynamic/decode
import gleam/erlang/process.{type Name, type Pid}
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import nostr_no_su
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/session
import nostr_no_su/bunker/vault.{type MasterKey}
import nostr_no_su/db
import nostr_no_su/random
import nostr_no_su/time
import pog
import support/poll
import support/postgres
import support/random_account.{random_entry, random_master_key}

/// バンカーアクターに渡すストアの期限。書き込みはトリガーが門を待つ間に切れるだけの
/// 短さで、負荷の高い環境でもクエリーがサーバーに届くだけの長さにする。読み込みは
/// 書き込みの残りを待てるよう長く取る。
const actor_timeouts = db.Timeouts(load_ms: 30_000, write_ms: 2000)

/// テストが直接 DB を読み書きするときの期限。
const generous = db.Timeouts(load_ms: 30_000, write_ms: 30_000)

/// 書き込みを止める門の advisory lock の鍵。ASCII の `gat`（gate）を 16 進にした値。
/// `db.instance_lock_key` と別の値にし、同じ DB のインスタンスのロックと
/// 取り合わないようにする。
const gate_lock_key = 6_775_156

/// 挿入と更新を、テストが門を開ける（排他の advisory lock を離す）まで止める
/// トリガー。`{schema}` は専用のスキーマの名前、`{gate}` は `gate_lock_key` の
/// 10 進に置き換える。
const gated_write = [
  "CREATE FUNCTION {schema}.gated_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock_shared({gate});
  RETURN NEW;
END
$$",
  "CREATE TRIGGER gated_write BEFORE INSERT OR UPDATE ON {schema}.bunker_accounts
FOR EACH ROW EXECUTE FUNCTION {schema}.gated_write()",
]

/// セッションの削除を、テストが門を開けるまで止めるトリガー。BEFORE DELETE で
/// `NEW` を返すと削除が取り消されるので、`RETURN OLD` にする。`{schema}` と
/// `{gate}` の置き換えは `gated_write` と同じ。
const gated_session_delete = [
  "CREATE FUNCTION {schema}.gated_session_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock_shared({gate});
  RETURN OLD;
END
$$",
  "CREATE TRIGGER gated_session_delete BEFORE DELETE ON {schema}.bunker_sessions
FOR EACH ROW EXECUTE FUNCTION {schema}.gated_session_delete()",
]

/// 期限を過ぎてからコミットされる追加と secret の作り直しの後、バンカーの一覧が DB と
/// 一致する。合わせた後の登録済みとしての拒否と削除も DB と一致したまま動く。
/// 起動時の読み込みで、DB に保存したセッションと承認待ちが経過時間を保ったまま戻り、
/// 期限を過ぎてからコミットされる取り消しの後の読み直しでも DB の内容に置き換わる。
pub fn ambiguous_writes_are_reconciled_with_postgres_test() {
  use database_url <- postgres.with_test_database_url("account_reconcile")
  let lock_pool = postgres.start_lock_pool(database_url)
  let gate = pog.named_connection(postgres.start_pool(database_url, None))
  reconcile_with_postgres(database_url, lock_pool, gate)
  reconcile_sessions_with_postgres(database_url, lock_pool, gate)
}

/// 期限を過ぎてからコミットされる追加と secret の作り直しの後、バンカーの一覧が DB と
/// 一致することを確かめる。合わせた後の登録済みとしての拒否と削除も DB と一致した
/// まま動くことを確かめる。
fn reconcile_with_postgres(
  database_url: String,
  lock_pool: Name(pog.Message),
  gate: pog.Connection,
) -> Nil {
  use schema, pool, db <- postgres.with_named_schema(database_url)
  let key = random_master_key()
  let first = random_entry("")
  let first_pubkey = account.pubkey_hex(first.account)
  let assert Ok(_loaded) = postgres.load_stored(pool, key, generous)
  let assert Ok(Nil) = account_store.insert(db, key, first, generous)
  create_triggers(db, schema, gated_write)

  let name = process.new_name("account_reconcile_bunker")
  let pid = start_store_bunker(name, pool, lock_pool, key)
  assert poll.until(
    fn() { bunker.accounts(name) == Ok(database_listings(pool, key)) },
    10_000,
    50,
  )

  let other = random_entry("")
  let other_pubkey = account.pubkey_hex(other.account)
  assert behind_gate(gate, schema, fn() {
      bunker.add_account(name, other.account, "other")
    })
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let added = database_listings(pool, key)
  assert list.length(added) == 2
  assert bunker.accounts(name) == Ok(added)

  assert behind_gate(gate, schema, fn() {
      bunker.rotate_secret(name, first_pubkey)
    })
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let rotated = database_listings(pool, key)
  let assert Ok(first_listing) =
    list.find(rotated, fn(listing) { listing.signer == first_pubkey })
  assert first_listing.secret != first.secret
  assert bunker.accounts(name) == Ok(rotated)

  assert bunker.add_account(name, other.account, "again")
    == Error(bunker.AccountAlreadyRegistered)
  // 削除にはトリガーが無いので、期限の内に終わる。
  assert bunker.remove_account(name, other_pubkey) == Ok(Nil)
  let removed = database_listings(pool, key)
  assert list.map(removed, fn(listing) { listing.signer }) == [first_pubkey]
  assert bunker.accounts(name) == Ok(removed)

  process.unlink(pid)
  process.kill(pid)
}

/// `write` を、`gate` の接続が門（`gate_lock_key` の排他の advisory lock）を持つ
/// トランザクションの中で呼び、結果を返す。トリガーは同じ鍵を共有で待つので、
/// `write` が返ってトランザクションがコミットされるまで書き込みはコミットされない。
/// `write` が返った後、`schema` の表へのロックを待つ読み直しが現れるまで門を
/// 離さず、2 秒で現れなければロールバックして落ちる。門のトランザクションは pgo の
/// 接続の貸し出しの期限（5 秒）の内に終える必要があり、`write` が `actor_timeouts`
/// の書き込みの期限（2 秒）を使うので、待ちは 2 秒で打ち切る。`write` が例外で
/// 抜けてもロールバックで門は必ず開く。コールバックの中では門のトランザクションの
/// 接続にだけ問い合わせ、別の接続へのクエリーは投げない。
/// `gate` はバンカーのプールと別のプールの接続にする（同じ 2 本のプールでは、門を
/// 持つ接続と門で止まった書き込みが両方を塞ぎ、読み直しが接続を得られない）。
fn behind_gate(gate: pog.Connection, schema: String, write: fn() -> a) -> a {
  let assert Ok(written) =
    pog.transaction(gate, fn(conn) {
      // pg_advisory_xact_lock は void を返し、pgo はその列を読めないので bool にする。
      postgres.run_statement(
        conn,
        "SELECT pg_advisory_xact_lock("
          <> int.to_string(gate_lock_key)
          <> ") IS NOT NULL",
      )
      let written = write()
      case poll.until(fn() { lock_waiter_in(conn, schema) }, 2000, 50) {
        True -> Ok(written)
        False -> Error("no reload waited for the gated write")
      }
    })
  written
}

/// `schema` の表に SHARE のロックを待っているバックエンドがあるかを返す。読み直しの
/// `LOCK TABLE` が、門で止まっている書き込みの ROW EXCLUSIVE を待ち始めたことを見る。
/// `pg_locks` は問い合わせのたびに今のロックを読むので、トランザクションの中で
/// 繰り返し呼べる。
fn lock_waiter_in(conn: pog.Connection, schema: String) -> Bool {
  let assert Ok(pog.Returned(rows: [waiting], ..)) =
    pog.query(
      "SELECT EXISTS (SELECT 1 FROM pg_locks l
JOIN pg_class c ON c.oid = l.relation
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT l.granted AND l.mode = 'ShareLock' AND n.nspname = $1)",
    )
    |> pog.parameter(pog.text(schema))
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.timeout(30_000)
    |> pog.execute(on: conn)
  waiting
}

/// DB の行を、バンカーの一覧と同じ形（署名者の昇順）で読む。読み込みは実行中の
/// 書き込みの終了を待つ。
fn database_listings(
  pool: Name(pog.Message),
  key: MasterKey,
) -> List(bunker.Listing) {
  let assert Ok(loaded) = postgres.load_stored(pool, key, generous)
  loaded.accounts.accounts
  |> list.map(fn(entry) {
    bunker.Listing(
      signer: account.pubkey_hex(entry.account),
      npub: account.npub(entry.account),
      label: entry.label,
      secret: entry.secret,
    )
  })
  |> list.sort(fn(left, right) { string.compare(left.signer, right.signer) })
}

/// DB に保存したセッション 1 件と承認待ち 1 件を経過時間を保ったまま起動時に
/// 読み戻すこと、承認待ちを DB から直接消してから起こした期限切れの取り消しの
/// 後、読み直しでセッションと承認待ちが DB の内容（空）に置き換わることを
/// 確かめる。
fn reconcile_sessions_with_postgres(
  database_url: String,
  lock_pool: Name(pog.Message),
  gate: pog.Connection,
) -> Nil {
  use schema, pool, db <- postgres.with_named_schema(database_url)
  let key = random_master_key()
  let entry = random_entry("")
  let signer = account.pubkey_hex(entry.account)
  let client =
    "0000000000000000000000000000000000000000000000000000000000000009"
  let assert Ok(_loaded) = postgres.load_stored(pool, key, generous)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)
  let now = time.now_seconds()
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      key,
      session: account_store.StoredSession(
        signer: signer,
        client: client,
        perms: "",
        created_at: now - 60,
        last_used_at: now - 60,
        relays: [],
      ),
      timeouts: generous,
    )
  let assert Ok(Nil) =
    account_store.insert_pending(
      db,
      key,
      account_store.StoredPending(
        token: random.hex(16),
        signer: signer,
        client: client,
        request_id: "c2",
        perms: "",
        secret_mismatch: False,
        created_at: now - 120,
      ),
      generous,
    )
  create_triggers(db, schema, gated_session_delete)

  let name = process.new_name("account_reconcile_sessions_bunker")
  let pid = start_store_bunker(name, pool, lock_pool, key)
  let session =
    session.Session(
      signer: signer,
      client: client,
      perms: "",
      created_at: now - 60,
      last_used_at: now - 60,
      relays: [],
    )
  assert poll.until(fn() { bunker.sessions(name) == Ok([session]) }, 10_000, 50)
  let assert Ok([pending]) = bunker.pending(name)
  assert pending.created_at == now - 120
  assert pending.request_id == "c2"

  let assert Ok(Nil) =
    account_store.delete_pending(db, token: pending.token, timeouts: generous)
  assert behind_gate(gate, schema, fn() { bunker.revoke(name, signer, client) })
    == Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))

  assert poll.until(fn() { bunker.sessions(name) == Ok([]) }, 10_000, 50)
  assert bunker.pending(name) == Ok([])
  let assert Ok(after) = postgres.load_stored(pool, key, generous)
  assert after.sessions == []
  assert after.pending == []

  process.unlink(pid)
  process.kill(pid)
}

/// `statements` の `{schema}` と `{gate}` を置き換えて、`db` の接続で順に実行する。
fn create_triggers(
  db: pog.Connection,
  schema: String,
  statements: List(String),
) -> Nil {
  list.each(statements, fn(statement) {
    postgres.run_statement(
      db,
      statement
        |> string.replace("{schema}", schema)
        |> string.replace("{gate}", int.to_string(gate_lock_key)),
    )
  })
}

/// 専用のスキーマに向けた `account_store_operations` でバンカーアクターを起動し、
/// その pid を返す。両方のシナリオが同じ起動の手順を使う。
fn start_store_bunker(
  name: Name(bunker.Msg),
  pool: Name(pog.Message),
  lock_pool: Name(pog.Message),
  key: MasterKey,
) -> Pid {
  let assert Ok(started) =
    bunker.start(
      name,
      bunker.Settings(
        store: nostr_no_su.account_store_operations(
          pool,
          lock_pool,
          key,
          actor_timeouts,
        ),
        auth_url: None,
        retry_delay: backoff.Backoff(initial_ms: 100, max_ms: 100),
      ),
      fn() { Nil },
      fn(_relays) { Nil },
      fn(_urls) { Nil },
    )
  started.pid
}
