//// 実際の Postgres で、結果が曖昧な書き込みの後にバンカーアクターの一覧が DB と一致
//// することを確かめる統合テスト。`TEST_DATABASE_URL` があるときだけ実行する。
////
//// 専用のスキーマのテーブルに、書き込みの期限より長く眠る BEFORE トリガーを付ける。
//// 書き込みは期限で `TimedOut` を返した後もサーバー側で実行を続け、読み直しより後に
//// コミットされる。読み直しが実行中の書き込みを待たなければ、一覧は DB と食い違う。
//// セッションの削除でも同じ。

import gleam/erlang/process.{type Name, type Pid}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{type MasterKey}
import nostr_no_su/random
import nostr_no_su/time
import pog
import support/postgres
import support/random_account.{random_entry, random_master_key}

/// バンカーアクターに渡すストアの期限。書き込みはトリガーの眠りより短く、負荷の高い
/// 環境でもクエリーがサーバーに届くだけの長さにする。読み込みは書き込みの残りを待てる
/// よう長く取る。
const actor_timeouts = account_store.Timeouts(load_ms: 30_000, write_ms: 2000)

/// テストが直接 DB を読み書きするときの期限。
const generous = account_store.Timeouts(load_ms: 30_000, write_ms: 30_000)

/// 挿入と更新を、書き込みの期限を過ぎるまで遅らせるトリガー。`{schema}` は専用の
/// スキーマの名前に置き換える。
const slow_trigger = [
  "CREATE FUNCTION {schema}.slow_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_sleep(4);
  RETURN NEW;
END
$$",
  "CREATE TRIGGER slow_write BEFORE INSERT OR UPDATE ON {schema}.bunker_accounts
FOR EACH ROW EXECUTE FUNCTION {schema}.slow_write()",
]

/// セッションの削除を、書き込みの期限より長く遅らせるトリガー。BEFORE DELETE で
/// `NEW` を返すと削除が取り消されるので、`RETURN OLD` にする。`{schema}` は専用の
/// スキーマの名前に置き換える。
const slow_session_delete = [
  "CREATE FUNCTION {schema}.slow_session_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_sleep(4);
  RETURN OLD;
END
$$",
  "CREATE TRIGGER slow_session_delete BEFORE DELETE ON {schema}.bunker_sessions
FOR EACH ROW EXECUTE FUNCTION {schema}.slow_session_delete()",
]

/// 期限を過ぎてからコミットされる追加と secret の作り直しの後、バンカーの一覧が DB と
/// 一致する。合わせた後の登録済みとしての拒否と削除も DB と一致したまま動く。
/// 起動時の読み込みで、DB に保存したセッションと承認待ちが経過時間を保ったまま戻り、
/// 期限を過ぎてからコミットされる取り消しの後の読み直しでも DB の内容に置き換わる。
pub fn ambiguous_writes_are_reconciled_with_postgres_test() {
  use database_url <- postgres.with_test_database_url("account_reconcile")
  let lock_pool = postgres.start_lock_pool(database_url)
  reconcile_with_postgres(database_url, lock_pool)
  reconcile_sessions_with_postgres(database_url, lock_pool)
}

/// 期限を過ぎてからコミットされる追加と secret の作り直しの後、バンカーの一覧が DB と
/// 一致することを確かめる。合わせた後の登録済みとしての拒否と削除も DB と一致した
/// まま動くことを確かめる。
fn reconcile_with_postgres(
  database_url: String,
  lock_pool: Name(pog.Message),
) -> Nil {
  use schema, admin, pool <- with_schema(database_url)
  let key = random_master_key()
  let first = random_entry("")
  let first_pubkey = account.pubkey_hex(first.account)
  let db = pog.named_connection(pool)
  let assert Ok(_loaded) = account_store.load(pool, key, generous)
  let assert Ok(Nil) = account_store.insert(db, key, first, generous)
  list.each(slow_trigger, fn(statement) {
    postgres.run_statement(admin, string.replace(statement, "{schema}", schema))
  })

  let name = process.new_name("account_reconcile_bunker")
  let pid = start_store_bunker(name, pool, lock_pool, key)
  assert await(
    fn() { bunker.accounts(name) == Ok(database_listings(pool, key)) },
    10_000,
  )

  let other = random_entry("")
  let other_pubkey = account.pubkey_hex(other.account)
  assert bunker.add_account(name, other.account, "other")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let added = database_listings(pool, key)
  assert list.length(added) == 2
  assert bunker.accounts(name) == Ok(added)

  assert bunker.rotate_secret(name, first_pubkey)
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

/// DB の行を、バンカーの一覧と同じ形（署名者の昇順）で読む。読み込みは実行中の
/// 書き込みの終了を待つ。
fn database_listings(
  pool: Name(pog.Message),
  key: MasterKey,
) -> List(bunker.Listing) {
  let assert Ok(loaded) = account_store.load(pool, key, generous)
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
) -> Nil {
  use schema, admin, pool <- with_schema(database_url)
  let key = random_master_key()
  let entry = random_entry("")
  let signer = account.pubkey_hex(entry.account)
  let client =
    "0000000000000000000000000000000000000000000000000000000000000009"
  let db = pog.named_connection(pool)
  let assert Ok(_loaded) = account_store.load(pool, key, generous)
  let assert Ok(Nil) = account_store.insert(db, key, entry, generous)
  let now = time.now_seconds()
  let assert Ok(Nil) =
    account_store.insert_session(
      db,
      key,
      generous,
      session: account_store.StoredSession(
        signer: signer,
        client: client,
        perms: "",
        created_at: now - 60,
        last_used_at: now - 60,
      ),
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
  list.each(slow_session_delete, fn(statement) {
    postgres.run_statement(admin, string.replace(statement, "{schema}", schema))
  })

  let name = process.new_name("account_reconcile_sessions_bunker")
  let pid = start_store_bunker(name, pool, lock_pool, key)
  let session =
    engine.Session(
      signer: signer,
      client: client,
      perms: "",
      created_at: now - 60,
      last_used_at: now - 60,
    )
  assert await(fn() { bunker.sessions(name) == Ok([session]) }, 10_000)
  let assert Ok([pending]) = bunker.pending(name)
  assert pending.created_at == now - 120
  assert pending.request_id == "c2"

  let assert Ok(Nil) =
    account_store.delete_pending(db, generous, token: pending.token)
  assert bunker.revoke(name, signer, client)
    == Error(bunker.SessionMaybeApplied(bunker.StoreDidNotConfirm))

  assert await(fn() { bunker.sessions(name) == Ok([]) }, 10_000)
  assert bunker.pending(name) == Ok([])
  let assert Ok(after) = account_store.load(pool, key, generous)
  assert after.sessions == []
  assert after.pending == []

  process.unlink(pid)
  process.kill(pid)
}

/// 専用のスキーマを作って `run` を呼び、終わったらスキーマごと消す。専用の
/// スキーマ名は `run` にも渡し、そのスキーマ限定のトリガーを作るのに使えるようにする。
fn with_schema(
  database_url: String,
  run: fn(String, pog.Connection, Name(pog.Message)) -> Nil,
) -> Nil {
  let schema = "bunker_reconcile_" <> random.hex(8)
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin, "CREATE SCHEMA " <> schema)
  let pool = postgres.start_pool(database_url, Some(schema))
  run(schema, admin, pool)
  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
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
    )
  started.pid
}

/// `check` が真になるまで待つ。50ms ごとに `remaining` から引き、尽きたら諦める。
fn await(check: fn() -> Bool, remaining: Int) -> Bool {
  case check(), remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(50)
      await(check, remaining - 50)
    }
  }
}
