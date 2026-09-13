//// 実際の Postgres で、結果が曖昧な書き込みの後にバンカーアクターの一覧が DB と一致
//// することを確かめる統合テスト。`TEST_DATABASE_URL` があるときだけ実行する
//// （CI では未設定なら失敗する）。
////
//// 専用のスキーマのテーブルに、書き込みの期限より長く眠る BEFORE トリガーを付ける。
//// 書き込みは期限で `TimedOut` を返した後もサーバー側で実行を続け、読み直しより後に
//// コミットされる。読み直しが実行中の書き込みを待たなければ、一覧は DB と食い違う。

import gleam/crypto
import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/vault.{
  type MasterKey, type StoredAccount, StoredAccount,
}
import nostr_no_su/hex
import nostr_no_su/random
import pog
import support/postgres

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

/// 期限を過ぎてからコミットされる追加と secret の作り直しの後、バンカーの一覧が DB と
/// 一致する。合わせた後の登録済みとしての拒否と削除も DB と一致したまま動く。
pub fn ambiguous_writes_are_reconciled_with_postgres_test() {
  use database_url <- postgres.with_test_database_url("account_reconcile")
  reconcile_with_postgres(database_url)
}

/// 専用のスキーマでテストを行い、最後にスキーマごと消す。
fn reconcile_with_postgres(database_url: String) -> Nil {
  let schema = "bunker_reconcile_" <> random.hex(8)
  let admin = pog.named_connection(postgres.start_pool(database_url, None))
  postgres.run_statement(admin, "CREATE SCHEMA " <> schema)
  let pool = postgres.start_pool(database_url, Some(schema))
  let key = random_master_key()
  let first = random_entry()
  let first_pubkey = account.pubkey_hex(first.account)
  let db = pog.named_connection(pool)
  let assert Ok(_loaded) = account_store.load(pool, key, generous)
  let assert Ok(Nil) = account_store.insert(db, key, first, generous)
  list.each(slow_trigger, fn(statement) {
    postgres.run_statement(admin, string.replace(statement, "{schema}", schema))
  })

  let name = process.new_name("account_reconcile_bunker")
  let assert Ok(started) =
    bunker.start(
      name,
      bunker.Settings(
        store: nostr_no_su.account_store_operations(pool, key, actor_timeouts),
        auth_url: None,
        retry_delay: bunker.RetryDelay(initial_ms: 100, max_ms: 100),
      ),
      fn() { Nil },
    )
  assert await_listings(name, database_listings(pool, key), 10_000)

  let other = random_entry()
  let other_pubkey = account.pubkey_hex(other.account)
  assert bunker.add_account(name, other.account, "other")
    == Error(bunker.MaybeApplied(bunker.change_may_have_been_applied))
  let added = database_listings(pool, key)
  assert list.length(added) == 2
  assert bunker.accounts(name) == Ok(added)

  assert bunker.rotate_secret(name, first_pubkey)
    == Error(bunker.MaybeApplied(bunker.change_may_have_been_applied))
  let rotated = database_listings(pool, key)
  let assert Ok(first_listing) =
    list.find(rotated, fn(listing) { listing.signer == first_pubkey })
  assert first_listing.secret != first.secret
  assert bunker.accounts(name) == Ok(rotated)

  assert bunker.add_account(name, other.account, "again")
    == Error(bunker.NotApplied("account is already registered"))
  // 削除にはトリガーが無いので、期限の内に終わる。
  assert bunker.remove_account(name, other_pubkey) == Ok(Nil)
  let removed = database_listings(pool, key)
  assert list.map(removed, fn(listing) { listing.signer }) == [first_pubkey]
  assert bunker.accounts(name) == Ok(removed)

  process.unlink(started.pid)
  process.kill(started.pid)
  postgres.run_statement(admin, "DROP SCHEMA " <> schema <> " CASCADE")
}

/// DB の行を、バンカーの一覧と同じ形（署名者の昇順）で読む。読み込みは実行中の
/// 書き込みの終了を待つ。
fn database_listings(
  pool: Name(pog.Message),
  key: MasterKey,
) -> List(bunker.Listing) {
  let assert Ok(loaded) = account_store.load(pool, key, generous)
  loaded.accounts
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

/// バンカーの一覧が期待どおりになるまで待つ。
fn await_listings(
  name: Name(bunker.Msg),
  expected: List(bunker.Listing),
  remaining: Int,
) -> Bool {
  case bunker.accounts(name) == Ok(expected), remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(50)
      await_listings(name, expected, remaining - 50)
    }
  }
}

/// 実行のたびに違うマスターキー。
fn random_master_key() -> MasterKey {
  let assert Ok(key) =
    vault.master_key_from_hex(hex.encode(crypto.strong_random_bytes(32)))
  key
}

/// 実行のたびに違う鍵と secret を持つアカウント。
fn random_entry() -> StoredAccount {
  let assert Ok(signer) = account.from_privkey(crypto.strong_random_bytes(32))
  StoredAccount(account: signer, secret: random.hex(16), label: "")
}
