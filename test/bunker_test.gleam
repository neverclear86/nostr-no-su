//// `bunker.load_report` と `bunker.default_retry_delay` のテストと、バンカーアクターの
//// 状態に接続 secret が出ないことのテスト。読み込みの結果に対して、どのログ行を
//// 出すかと、再試行の待ち時間の延び方を確かめる。`bunker.track` / `bunker.acknowledge`
//// のテストは、発行した応答への OK をどう追跡し、全リレーに拒否されたときの行を
//// どう組み立てるかを確かめる。`bunker.sign_event`（`SignEvent`）のテストは、
//// プラグインからの送信の口（`plugin_api`）が使う署名の要求を、読み込み前と
//// 登録済みの署名者のそれぞれで確かめる。`bunker.check_account`（`CheckAccount`）の
//// テストは、プラグインからの取得の口が使う登録の確認を、読み込み前・未登録・
//// 登録済みのそれぞれで確かめる。

import gleam/erlang/process
import gleam/list
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

/// テストで使うバンカーリレーの 1 本目。
const relay_a = "wss://a.example"

/// テストで使うバンカーリレーの 2 本目。
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
    label: "",
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
          load: fn() { Ok(bunker.Snapshot(Loaded([stored], []), [], [], [])) },
          insert: fn(_account) { Ok(Nil) },
          delete: fn(_signer) { Ok(Nil) },
          update_secret: fn(_signer, _secret) { Ok(Nil) },
          update_label: fn(_signer, _label) { Ok(Nil) },
          write: fn(_write) { Ok(Nil) },
        ),
        auth_url: None,
        retry_delay: backoff.Backoff(initial_ms: 100, max_ms: 100),
      ),
      fn() { Nil },
      fn(_relays) { Nil },
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

/// AUTH に返すイベントは、アカウントごとに 1 件、その鍵で署名した kind 22242 で、
/// リレー URL と challenge をタグに持つ。
pub fn authentication_events_are_signed_by_each_account_test() {
  let first =
    account_for(
      "0000000000000000000000000000000000000000000000000000000000000042",
    )
  let second =
    account_for(
      "0000000000000000000000000000000000000000000000000000000000000077",
    )
  let assert Ok(events) =
    bunker.authentication_events(
      [first, second],
      "wss://relay.test",
      "challenge-1",
      1_700_000_000,
    )
  let assert [a, b] = events
  assert a.pubkey == account.pubkey_hex(first)
  assert b.pubkey == account.pubkey_hex(second)
  list.each(events, fn(e) {
    assert e.kind == event.auth_kind
    assert e.created_at == 1_700_000_000
    assert e.content == ""
    assert e.tags
      == [["relay", "wss://relay.test"], ["challenge", "challenge-1"]]
    let assert Ok(_verified) = event.verify(e)
    Nil
  })
}

/// 偽のストアと再試行の待ち時間で、`Store` を組み立てるだけのバンカーを起動する。
fn start_bunker_with_load(
  name: process.Name(bunker.Msg),
  load: fn() -> Result(bunker.Snapshot, String),
) -> Nil {
  let assert Ok(_started) =
    bunker.start(
      name,
      bunker.Settings(
        store: bunker.Store(
          load: load,
          insert: fn(_account) { Ok(Nil) },
          delete: fn(_signer) { Ok(Nil) },
          update_secret: fn(_signer, _secret) { Ok(Nil) },
          update_label: fn(_signer, _label) { Ok(Nil) },
          write: fn(_write) { Ok(Nil) },
        ),
        auth_url: None,
        retry_delay: backoff.Backoff(initial_ms: 100, max_ms: 100),
      ),
      fn() { Nil },
      fn(_relays) { Nil },
    )
  Nil
}

/// 読み込みが常に失敗する（＝いつまでも `Loading` のままの）バンカーは、
/// `SignEvent` を理由で拒む。
pub fn sign_event_returns_the_reason_before_accounts_are_loaded_test() {
  let name = process.new_name("bunker_sign_event_not_loaded_test")
  start_bunker_with_load(name, fn() { Error("boom") })

  assert bunker.sign_event(name, "s1", 1, [], "hello")
    == Error("accounts are not loaded yet")

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}

/// 登録済みの署名者の鍵で署名し、検証を通るイベントを返す。
pub fn sign_event_signs_with_the_registered_account_test() {
  let name = process.new_name("bunker_sign_event_signs_test")
  let stored = one_account()
  start_bunker_with_load(name, fn() {
    Ok(bunker.Snapshot(Loaded([stored], []), [], [], []))
  })
  let assert Ok([_]) = bunker.accounts(name)
  let signer = account.pubkey_hex(stored.account)

  let assert Ok(signed) = bunker.sign_event(name, signer, 1, [["a", "b"]], "hi")
  assert signed.pubkey == signer
  assert signed.kind == 1
  assert signed.tags == [["a", "b"]]
  assert signed.content == "hi"
  let assert Ok(_verified) = event.verify(signed)

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}

/// 読み込みが常に失敗する（＝いつまでも `Loading` のままの）バンカーは、
/// `CheckAccount` を理由で拒む。
pub fn check_account_returns_the_reason_before_accounts_are_loaded_test() {
  let name = process.new_name("bunker_check_account_not_loaded_test")
  start_bunker_with_load(name, fn() { Error("boom") })

  assert bunker.check_account(name, "s1")
    == Error("accounts are not loaded yet")

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}

/// 登録済みの署名者は `Ok(Nil)`。
pub fn check_account_accepts_a_registered_signer_test() {
  let name = process.new_name("bunker_check_account_accepts_test")
  let stored = one_account()
  start_bunker_with_load(name, fn() {
    Ok(bunker.Snapshot(Loaded([stored], []), [], [], []))
  })
  let assert Ok([_]) = bunker.accounts(name)
  let signer = account.pubkey_hex(stored.account)

  assert bunker.check_account(name, signer) == Ok(Nil)

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}

/// 未登録の署名者は理由を返す。
pub fn check_account_rejects_an_unregistered_signer_test() {
  let name = process.new_name("bunker_check_account_rejects_test")
  let stored = one_account()
  start_bunker_with_load(name, fn() {
    Ok(bunker.Snapshot(Loaded([stored], []), [], [], []))
  })
  let assert Ok([_]) = bunker.accounts(name)

  assert bunker.check_account(name, "not-registered")
    == Error("account is not registered")

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}
