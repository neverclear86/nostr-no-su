//// `bunker.load_report` と `bunker.default_retry_delay` のテストと、バンカーアクターの
//// 状態に接続 secret が出ないことのテスト。読み込みの結果に対して、どのログ行を
//// 出すかと、再試行の待ち時間の延び方を確かめる。

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/vault.{Loaded, Skipped, StoredAccount}
import support/nip46_client.{account_for}

/// 読み込めたアカウント 1 件。
fn one_account() -> vault.StoredAccount {
  StoredAccount(
    account: account_for(
      "0000000000000000000000000000000000000000000000000000000000000042",
    ),
    secret: "s3cret",
    label: "",
  )
}

/// 飛ばした行 1 件。
fn one_skipped() -> vault.Skipped {
  Skipped(
    pubkey: account.pubkey_hex(account_for(
      "0000000000000000000000000000000000000000000000000000000000000009",
    )),
    reason: vault.UndecryptablePrivateKey,
  )
}

/// 初回の成功は件数だけを出す。
pub fn first_success_reports_the_count_test() {
  assert bunker.load_report(None, Ok(Loaded([one_account()], [])), 5000)
    == ["loaded 1 account(s)"]
}

/// 飛ばした行があれば全体の件数を添え、飛ばした行ごとに 1 行出す。
pub fn skipped_rows_are_reported_test() {
  let skipped = one_skipped()
  assert bunker.load_report(None, Ok(Loaded([one_account()], [skipped])), 5000)
    == ["loaded 1 of 2 account(s)", vault.describe_skipped(skipped)]
}

/// 失敗から復帰したときは、その旨を出す。購読はアクターが張り直すので、再接続を
/// 待つ旨の行は出さない。
pub fn recovery_is_reported_test() {
  let skipped = one_skipped()
  assert bunker.load_report(
      Some("database is unreachable or timed out"),
      Ok(Loaded([], [skipped])),
      5000,
    )
    == [
      "account store is back; loaded 0 of 1 account(s)",
      vault.describe_skipped(skipped),
    ]
}

/// 最初の失敗は理由と次の再試行までの待ち時間を出す。待ち時間は引数の値から作る。
pub fn first_failure_is_reported_test() {
  assert bunker.load_report(None, Error("database is unreachable"), 250)
    == [
      "account store unavailable: database is unreachable; retrying in 250ms",
    ]
}

/// 同じ理由の失敗が続く間は黙る。
pub fn repeated_failures_are_silent_test() {
  assert bunker.load_report(
      Some("database is unreachable"),
      Error("database is unreachable"),
      5000,
    )
    == []
}

/// 理由が変わった失敗は、改めて出す。
pub fn a_changed_failure_is_reported_test() {
  assert bunker.load_report(
      Some("database is unreachable"),
      Error("postgres error: insufficient_privilege"),
      5000,
    )
    == [
      "account store unavailable: postgres error: insufficient_privilege; retrying in 5000ms",
    ]
}

/// 既定の待ち時間は 5 秒から倍に延び、2 分で頭打ちになる（倍加の系列そのものは
/// `backoff_test.next_doubles_up_to_the_maximum_test` で検査する）。
pub fn default_retry_delay_is_five_seconds_up_to_two_minutes_test() {
  assert bunker.default_retry_delay
    == backoff.Backoff(initial_ms: 5000, max_ms: 120_000)
}

/// 読み込んだアカウントを持つバンカーアクターの状態を表示しても、接続 secret は
/// 現れない。
pub fn inspecting_the_bunker_state_does_not_reveal_the_secret_test() {
  let name = process.new_name("bunker_state_test")
  let stored = one_account()
  let assert Ok(_started) =
    bunker.start(
      name,
      bunker.Settings(
        store: bunker.Store(
          load: fn() { Ok(Loaded([stored], [])) },
          insert: fn(_account) { Ok(Nil) },
          delete: fn(_signer) { Ok(Nil) },
          update_secret: fn(_signer, _secret) { Ok(Nil) },
          update_label: fn(_signer, _label) { Ok(Nil) },
        ),
        auth_url: None,
        retry_delay: backoff.Backoff(initial_ms: 100, max_ms: 100),
      ),
      fn() { Nil },
    )
  // 読み込みの完了を待つ。`LoadAccounts` は起動時に名前なしの subject へ積まれて
  // おり、アクターは両方の subject を選択しているので、`GetAccounts` はその後に
  // 処理される。
  let assert Ok([_]) = bunker.accounts(name)
  let assert Ok(pid) = process.named(name)
  let shown = string.inspect(system.get_state(pid))
  assert string.contains(shown, account.pubkey_hex(stored.account))
  assert !string.contains(shown, stored.secret)
  process.unlink(pid)
  process.kill(pid)
}
