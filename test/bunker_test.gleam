//// `bunker.load_report` と `bunker.default_retry_delay` のテストと、バンカーアクターの
//// 状態に接続 secret が出ないことのテスト。読み込みの結果に対して、どのログ行を
//// 出すかと、再試行の待ち時間の延び方を確かめる。`bunker.track` / `bunker.acknowledge`
//// のテストは、発行した応答への OK をどう追跡し、全リレーに拒否されたときの行を
//// どう組み立てるかを確かめる。

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/vault.{Loaded, Skipped, StoredAccount}
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/relay_client.{Acknowledgement}
import support/nip46_client.{account_for}

/// テストで使うバンカーリレー 2 本。
const relay_a = "wss://a.example"

const relay_b = "wss://b.example"

/// バンカーが発行する応答イベント 1 件。kind と宛先タグは NIP-46 の応答の形。
fn response(id: String) -> Event {
  Event(
    id: id,
    pubkey: "s1",
    created_at: 0,
    kind: 24_133,
    tags: [["p", "c1"]],
    content: "",
    sig: "",
  )
}

/// 2 リレーへ発行した直後の追跡。
fn tracked(id: String, now: Int) -> bunker.Deliveries {
  bunker.track(bunker.new_deliveries(), response(id), [relay_a, relay_b], now)
}

/// 全リレーが拒否すると、拒否を届いた順にまとめた 1 行が返り、項目は消える
/// （受け入れ条件）。
pub fn every_relay_rejecting_a_response_is_reported_on_one_line_test() {
  let deliveries = tracked("e1", 0)
  let #(deliveries, first) =
    bunker.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert first == None
  let #(deliveries, second) =
    bunker.acknowledge(
      deliveries,
      relay_b,
      Acknowledgement("e1", False, "invalid: bad"),
    )
  assert second
    == Some(
      "response e1 to c1 was rejected by every relay: a.example: rate-limited: slow down; b.example: invalid: bad",
    )
  // 項目が消えているので、同じ id の拒否がもう届いても None。
  let #(_deliveries, third) =
    bunker.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert third == None
}

/// 1 つでも受理すれば、残りのリレーが拒否しても報告しない。
pub fn a_response_accepted_by_one_relay_is_not_reported_test() {
  let deliveries = tracked("e1", 0)
  let #(deliveries, accepted) =
    bunker.acknowledge(deliveries, relay_a, Acknowledgement("e1", True, ""))
  assert accepted == None
  let #(_deliveries, rejected) =
    bunker.acknowledge(
      deliveries,
      relay_b,
      Acknowledgement("e1", False, "invalid: bad"),
    )
  assert rejected == None
}

/// 同じリレーからの 2 度目の拒否は数えず、報告に必要な残り 1 本のまま止まる。
pub fn a_repeated_rejection_from_the_same_relay_is_not_counted_test() {
  let deliveries = tracked("e1", 0)
  let #(deliveries, first) =
    bunker.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert first == None
  let #(deliveries, repeated) =
    bunker.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert repeated == None
  let #(_deliveries, second) =
    bunker.acknowledge(
      deliveries,
      relay_b,
      Acknowledgement("e1", False, "invalid: bad"),
    )
  assert second
    == Some(
      "response e1 to c1 was rejected by every relay: a.example: rate-limited: slow down; b.example: invalid: bad",
    )
}

/// 発行から `acknowledgement_timeout_seconds`（60 秒）以上経った項目は、次の
/// 発行の記録のときに黙って捨てる。捨てた後に届く OK は一覧に無いので無視する。
pub fn acknowledgements_after_the_timeout_are_ignored_test() {
  let deliveries = tracked("e1", 0)
  let deliveries =
    bunker.track(deliveries, response("e2"), [relay_a, relay_b], 60)
  let #(deliveries, first) =
    bunker.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert first == None
  let #(_deliveries, second) =
    bunker.acknowledge(
      deliveries,
      relay_b,
      Acknowledgement("e1", False, "invalid: bad"),
    )
  assert second == None
}

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
