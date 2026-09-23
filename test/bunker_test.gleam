//// `bunker.load_report` と `bunker.default_retry_delay` のテストと、バンカーアクターの
//// 状態に接続 secret が出ないことのテスト。読み込みの結果に対して、どのログ行を
//// 出すかと、再試行の待ち時間の延び方を確かめる。`bunker.track` / `bunker.acknowledge`
//// のテストは、発行した応答への OK をどう追跡し、全リレーに拒否されたときの行を
//// どう組み立てるかを確かめる。`bunker.pause_on_rate_limit` / `bunker.recipients`
//// のテストは、`rate-limited:` を返したリレーへのセッションの外の応答をいつ
//// 止めて再開し、出さなかった件数をどう報告するかを確かめ、アクターのテストは
//// `Acknowledged` と `Incoming` から発行までの配線を確かめる。`bunker.sign_event`
//// （`SignEvent`）のテストは、プラグインからの送信の口（`plugin_api`）が使う
//// 署名の要求を、読み込み前と登録済みの署名者のそれぞれで確かめる。
//// `bunker.check_account`（`CheckAccount`）のテストは、プラグインからの取得の口が
//// 使う登録の確認を、読み込み前・未登録・登録済みのそれぞれで確かめる。
//// `bunker.check_accounts`（`CheckAccounts`）のテストは、複数の公開鍵の取得が使う
//// 登録の確認を、読み込み前と、登録済みと未登録を混ぜた順のそれぞれで確かめる。

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/rate_limit
import nostr_no_su/bunker/vault.{Loaded, Skipped, StoredAccount}
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event, Event}
import nostr_no_su/relay_client.{Acknowledgement}
import nostr_no_su/time
import support/nip46_client.{
  account_for, connect_body, request_body, request_event,
}
import support/signed_event

/// テストで使うバンカーリレーの 1 本目。
const relay_a = "wss://a.example"

/// テストで使うバンカーリレーの 2 本目。
const relay_b = "wss://b.example"

/// テスト用のクライアントの秘密鍵（16 進）。
const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

/// 2 人目のクライアントの秘密鍵（16 進）。
const other_client_key = "0000000000000000000000000000000000000000000000000000000000000005"

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

/// `rate-limited:` の拒否を反映した時刻から `rate_limited_pause_seconds` 秒の間、
/// relay_a を止めた一覧。
fn pausing_relay_a(at: Int) -> bunker.Pauses {
  bunker.pause_on_rate_limit(
    bunker.new_pauses(),
    relay_a,
    Acknowledgement("e1", False, "rate-limited: slow down"),
    at,
  )
}

/// `rate-limited:` の拒否を返したリレーには、セッションの外の応答を出さない
/// （受け入れ条件）。飛ばした 1 件はすぐ報告する。
pub fn a_rate_limited_relay_gets_no_responses_without_a_session_test() {
  let #(_pauses, sent, lines) =
    bunker.recipients(pausing_relay_a(1000), [relay_a, relay_b], True, 1001)
  assert sent == [relay_b]
  assert lines == [bunker.pause_report(relay_a, 1)]
}

/// セッションのあるクライアントへの応答は、止めたリレーにも届く（受け入れ条件）。
pub fn responses_in_a_session_reach_a_rate_limited_relay_test() {
  let #(_pauses, sent, lines) =
    bunker.recipients(pausing_relay_a(1000), [relay_a, relay_b], False, 1001)
  assert sent == [relay_a, relay_b]
  assert lines == []
}

/// 止める期限が過ぎると、そのリレーへの発行が再開する（受け入れ条件）。
pub fn a_rate_limited_relay_resumes_after_the_pause_test() {
  let pauses = pausing_relay_a(1000)
  let #(pauses, sent, _lines) =
    bunker.recipients(
      pauses,
      [relay_a, relay_b],
      True,
      1000 + bunker.rate_limited_pause_seconds - 1,
    )
  assert sent == [relay_b]
  let #(_pauses, sent, _lines) =
    bunker.recipients(
      pauses,
      [relay_a, relay_b],
      True,
      1000 + bunker.rate_limited_pause_seconds,
    )
  assert sent == [relay_a, relay_b]
}

/// `rate-limited:` 以外の理由の拒否と、受理の OK はリレーを止めない。
pub fn other_rejections_do_not_pause_a_relay_test() {
  let pauses =
    bunker.pause_on_rate_limit(
      bunker.new_pauses(),
      relay_a,
      Acknowledgement("e1", False, "invalid: bad"),
      1000,
    )
  let pauses =
    bunker.pause_on_rate_limit(
      pauses,
      relay_a,
      Acknowledgement("e2", True, "rate-limited: slow down"),
      1000,
    )
  let #(_pauses, sent, _lines) =
    bunker.recipients(pauses, [relay_a], True, 1001)
  assert sent == [relay_a]
}

/// 出さなかった件数はリレーごとに `report_interval_seconds` に 1 回まで報告する。
/// 新しく止めたリレーの最初の 1 件はすぐ出し、期限が過ぎた後に残った件数は、
/// 次にそのリレーを止めて出さなかったときに残りと合わせて出す。
pub fn dropped_responses_are_reported_once_per_interval_test() {
  // 最初に出さなかった 1 件はすぐ報告する
  let #(pauses, sent, lines) =
    bunker.recipients(pausing_relay_a(1000), [relay_a, relay_b], True, 1001)
  assert sent == [relay_b]
  assert lines == [bunker.pause_report(relay_a, 1)]

  // 報告の間隔の内側では件数を数えるだけで報告しない
  let #(pauses, _sent, lines) =
    bunker.recipients(pauses, [relay_a, relay_b], True, 1002)
  assert lines == []
  let #(pauses, _sent, lines) =
    bunker.recipients(pauses, [relay_a, relay_b], True, 1003)
  assert lines == []

  // 止め直してから出さなかった最初の 1 件で、残った 2 件と合わせて 3 件を出す
  let pauses =
    bunker.pause_on_rate_limit(
      pauses,
      relay_a,
      Acknowledgement("e3", False, "rate-limited: slow down"),
      1001 + rate_limit.report_interval_seconds,
    )
  let #(_pauses, _sent, lines) =
    bunker.recipients(
      pauses,
      [relay_a, relay_b],
      True,
      1001 + rate_limit.report_interval_seconds,
    )
  assert lines == [bunker.pause_report(relay_a, 3)]
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

/// 読み込みが常に失敗する（＝いつまでも `Loading` のままの）バンカーは、
/// `CheckAccounts` を全体の理由で拒む。
pub fn check_accounts_returns_the_reason_before_accounts_are_loaded_test() {
  let name = process.new_name("bunker_check_accounts_not_loaded_test")
  start_bunker_with_load(name, fn() { Error("boom") })

  assert bunker.check_accounts(name, ["s1"])
    == Error("accounts are not loaded yet")

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}

/// 登録済みと未登録を混ぜた問い合わせは、署名者ごとの結果を問い合わせた順に返す。
pub fn check_accounts_reports_each_signer_in_order_test() {
  let name = process.new_name("bunker_check_accounts_in_order_test")
  let stored = one_account()
  start_bunker_with_load(name, fn() {
    Ok(bunker.Snapshot(Loaded([stored], []), [], [], []))
  })
  let assert Ok([_]) = bunker.accounts(name)

  assert bunker.check_accounts(name, [
      "not-registered",
      account.pubkey_hex(stored.account),
    ])
    == Ok([Error("account is not registered"), Ok(Nil)])

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}

/// `rate-limited:` を返したリレーには、セッションの外の応答が届かなくなる
/// （受け入れ条件）。接続 secret の一致する `connect` の応答は止めたリレーにも
/// 届く。
pub fn the_bunker_skips_a_rate_limited_relay_for_responses_without_a_session_test() {
  let name = process.new_name("bunker_rate_limited_relay_test")
  let stored = one_account()
  start_bunker_with_load(name, fn() {
    Ok(bunker.Snapshot(Loaded([stored], []), [], [], []))
  })
  let assert Ok([_]) = bunker.accounts(name)

  // relay_a と relay_b の送信手段として、テストの subject へ送る関数を登録する
  let inbox_a = process.new_subject()
  let inbox_b = process.new_subject()
  named.send(name, bunker.SetPublisher(relay_a, process.send(inbox_a, _)))
  named.send(name, bunker.SetPublisher(relay_b, process.send(inbox_b, _)))
  named.send(
    name,
    bunker.Acknowledged(
      relay_a,
      Acknowledgement("e0", False, "rate-limited: slow down"),
    ),
  )

  let signer = stored.account
  let client = account_for(client_key)
  let now = time.now_seconds()
  named.send(
    name,
    bunker.Incoming(
      signed_event.verified(request_event(
        client,
        signer,
        request_body("g1", "get_public_key", "[]"),
        now,
      )),
    ),
  )
  // セッションの無いクライアントへの応答は、止めた relay_a を飛ばして relay_b
  // だけに届く
  let assert Ok(_response) = process.receive(inbox_b, 1000)
  assert process.receive(inbox_a, 100) == Error(Nil)

  // 接続 secret の一致する `connect` の応答は、止めた relay_a にも届く
  let other = account_for(other_client_key)
  named.send(
    name,
    bunker.Incoming(
      signed_event.verified(request_event(
        other,
        signer,
        connect_body(signer, "s3cret", "c1"),
        now,
      )),
    ),
  )
  let assert Ok(_response) = process.receive(inbox_a, 1000)
  let assert Ok(_response) = process.receive(inbox_b, 1000)

  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}
