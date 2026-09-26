//// `bunker.load_report` のテストと、バンカーアクターの状態に接続 secret が出ないことの
//// テスト。読み込みの結果に対して、どのログ行を出すかを確かめる。
//// `bunker.track` / `bunker.acknowledge`
//// のテストは、発行した応答への OK をどう追跡し、全リレーに拒否されたときの行を
//// どう組み立てるかを確かめる。`bunker.pause_on_rate_limit` / `bunker.recipients`
//// のテストは、`rate-limited:` を返したリレーへのセッションの外の応答をいつ
//// 止めて再開し、出さなかった件数をどう報告するかを確かめ、アクターのテストは
//// `Acknowledged` と `Incoming` から発行までの配線を確かめる。
//// `bunker.response_relays` / `bunker.session_relay_signers` のテストと、セッションの
//// リレーのアクターのテストは、応答の発行先、購読と AUTH の署名者、取り消しで閉じる
//// 一覧を確かめる。`bunker.sign_event`
//// （`SignEvent`）のテストは、プラグインからの送信の口（`plugin_api`）が使う
//// 署名の要求を、読み込み前と登録済みの署名者のそれぞれで確かめる。
//// `bunker.check_accounts`（`CheckAccounts`）のテストは、プラグインからの取得の口
//// （`plugin_api`）が使う登録の確認を、読み込み前と、登録済みと未登録を混ぜた順の
//// それぞれで確かめる。
//// `bunker.reserve_session_relays` / `bunker.release_session_relays` のテストは、
//// 取り置いた署名者で開く接続の購読と AUTH と、セッションを開いた後の取り外しで
//// 接続が残ることを確かめる。

import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/engine
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
      fn(_urls) { Nil },
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
  start_bunker_with_session_relays(name, load, fn(_urls) { Nil })
}

/// `start_bunker_with_load` に、セッションのリレーの一覧を受ける関数を渡す版。
fn start_bunker_with_session_relays(
  name: process.Name(bunker.Msg),
  load: fn() -> Result(bunker.Snapshot, String),
  session_relays: fn(List(String)) -> Nil,
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
      session_relays,
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
  named.send(
    name,
    bunker.SetPublisher(relay_a, bunker.BaseRelay, process.send(inbox_a, _)),
  )
  named.send(
    name,
    bunker.SetPublisher(relay_b, bunker.BaseRelay, process.send(inbox_b, _)),
  )
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

/// テストで使う、セッションのリレーの 1 本目。
const relay_x = "wss://x.example"

/// テストで使う、セッションのリレーの 2 本目。
const relay_y = "wss://y.example"

/// テストで使う、セッションのリレーの 3 本目。
const relay_z = "wss://z.example"

/// 3 人目のクライアントの秘密鍵（16 進）。
const third_client_key = "0000000000000000000000000000000000000000000000000000000000000007"

/// 署名者 `signer` とクライアント `client` の、リレー `relays` を持つ承認済み
/// セッション。
fn session_with(
  signer: account.Account,
  client: account.Account,
  relays: List(String),
) -> engine.Session {
  let now = time.now_seconds()
  engine.Session(
    signer: account.pubkey_hex(signer),
    client: account.pubkey_hex(client),
    perms: "",
    created_at: now,
    last_used_at: now,
    relays: relays,
  )
}

/// `relay_url` の送信手段として、`inbox` へ送る関数を範囲 `scope` で登録する。
fn set_publisher(
  name: process.Name(bunker.Msg),
  relay_url: String,
  scope: bunker.RelayScope,
  inbox: process.Subject(Event),
) -> Nil {
  named.send(
    name,
    bunker.SetPublisher(relay_url, scope, process.send(inbox, _)),
  )
}

/// `client` から `signer` への `get_public_key` を受信させる。
fn send_get_public_key(
  name: process.Name(bunker.Msg),
  client: account.Account,
  signer: account.Account,
  id: String,
) -> Nil {
  named.send(
    name,
    bunker.Incoming(
      signed_event.verified(request_event(
        client,
        signer,
        request_body(id, "get_public_key", "[]"),
        time.now_seconds(),
      )),
    ),
  )
}

/// テストで起動したバンカーを止める。
fn stop_bunker(name: process.Name(bunker.Msg)) -> Nil {
  let assert Ok(pid) = process.named(name)
  process.unlink(pid)
  process.kill(pid)
}

/// 基本のリレーはどの応答にも選び、セッションのリレーは応答先のセッションが持つ
/// ときだけ選ぶ。
pub fn response_relays_keep_base_relays_and_the_session_relays_test() {
  let publishers = [
    #(relay_a, bunker.BaseRelay),
    #(relay_x, bunker.SessionRelay),
    #(relay_y, bunker.SessionRelay),
  ]
  assert bunker.response_relays(publishers, [relay_x]) == [relay_a, relay_x]
  assert bunker.response_relays(publishers, []) == [relay_a]
}

/// 共有の URL は署名者を昇順・重複なしで持ち、リレーの無いセッションは何も
/// 足さない。
pub fn session_relay_signers_map_each_relay_to_its_session_signers_test() {
  let map =
    bunker.session_relay_signers([
      #("s2", [relay_x, relay_y]),
      #("s1", [relay_x]),
      #("s2", [relay_x]),
      #("s3", []),
    ])
  assert map == dict.from_list([#(relay_x, ["s1", "s2"]), #(relay_y, ["s2"])])
}

/// 応答は基本のリレーと応答先のセッションのリレーにだけ届き、別のセッションの
/// リレーには届かない。セッションの無いクライアントへの応答は基本のリレーだけに
/// 届く（受け入れ条件 1）。
pub fn responses_reach_only_the_relays_of_their_session_test() {
  let stored = one_account()
  let signer = stored.account
  let client_a = account_for(client_key)
  let client_b = account_for(other_client_key)
  let stranger = account_for(third_client_key)
  let sessions = [
    session_with(signer, client_a, [relay_x]),
    session_with(signer, client_b, [relay_y]),
  ]
  let load = fn() {
    Ok(bunker.Snapshot(Loaded([stored], []), sessions, [], []))
  }

  let name = process.new_name("bunker_session_relay_responses_test")
  start_bunker_with_load(name, load)
  let assert Ok([_]) = bunker.accounts(name)
  let inbox_a = process.new_subject()
  let inbox_x = process.new_subject()
  let inbox_y = process.new_subject()
  set_publisher(name, relay_a, bunker.BaseRelay, inbox_a)
  set_publisher(name, relay_x, bunker.SessionRelay, inbox_x)
  set_publisher(name, relay_y, bunker.SessionRelay, inbox_y)

  // A への応答は基本の a と A のリレーの x に届き、B のリレーの y には届かない
  send_get_public_key(name, client_a, signer, "g1")
  let assert Ok(_response) = process.receive(inbox_a, 1000)
  let assert Ok(_response) = process.receive(inbox_x, 1000)
  assert process.receive(inbox_y, 100) == Error(Nil)

  // セッションの無いクライアントへの応答は基本の a だけに届く
  send_get_public_key(name, stranger, signer, "g2")
  let assert Ok(_response) = process.receive(inbox_a, 1000)
  assert process.receive(inbox_x, 100) == Error(Nil)
  assert process.receive(inbox_y, 100) == Error(Nil)
  stop_bunker(name)

  // 基本の送信手段が無ければ、セッションの無いクライアントへの応答はセッションの
  // リレーのどちらにも届かない
  let bare = process.new_name("bunker_session_relay_without_base_test")
  start_bunker_with_load(bare, load)
  let assert Ok([_]) = bunker.accounts(bare)
  let bare_x = process.new_subject()
  let bare_y = process.new_subject()
  set_publisher(bare, relay_x, bunker.SessionRelay, bare_x)
  set_publisher(bare, relay_y, bunker.SessionRelay, bare_y)
  send_get_public_key(bare, stranger, signer, "g3")
  assert process.receive(bare_x, 200) == Error(Nil)
  assert process.receive(bare_y, 100) == Error(Nil)
  stop_bunker(bare)
}

/// セッションのリレーの一覧は、読み込み、取り消し、`logout`、アカウントの削除の
/// たびに、使われている URL だけに変わる（受け入れ条件 3）。
pub fn session_relays_follow_revocation_and_account_removal_test() {
  let stored = one_account()
  let signer = stored.account
  let client_a = account_for(client_key)
  let client_b = account_for(other_client_key)
  let client_c = account_for(third_client_key)
  let sessions = [
    session_with(signer, client_a, [relay_x]),
    session_with(signer, client_b, [relay_y]),
    session_with(signer, client_c, [relay_z]),
  ]
  let name = process.new_name("bunker_session_relays_follow_test")
  let urls = process.new_subject()
  start_bunker_with_session_relays(
    name,
    fn() { Ok(bunker.Snapshot(Loaded([stored], []), sessions, [], [])) },
    process.send(urls, _),
  )
  let assert Ok(loaded) = process.receive(urls, 1000)
  assert loaded == [relay_x, relay_y, relay_z]

  let signer_hex = account.pubkey_hex(signer)
  let assert Ok(Nil) =
    bunker.revoke(name, signer_hex, account.pubkey_hex(client_a))
  let assert Ok(revoked) = process.receive(urls, 1000)
  assert revoked == [relay_y, relay_z]

  named.send(
    name,
    bunker.Incoming(
      signed_event.verified(request_event(
        client_b,
        signer,
        request_body("l1", "logout", "[]"),
        time.now_seconds(),
      )),
    ),
  )
  let assert Ok(logged_out) = process.receive(urls, 1000)
  assert logged_out == [relay_z]

  let assert Ok(Nil) = bunker.remove_account(name, signer_hex)
  let assert Ok(removed) = process.receive(urls, 1000)
  assert removed == []
  stop_bunker(name)
}

/// セッションのリレーの接続の AUTH と署名者の問い合わせは、その URL を持つ
/// セッションの署名者だけで行い、基本の接続は全アカウントで AUTH する。
pub fn a_session_relay_is_authenticated_by_its_session_signers_only_test() {
  let first = one_account()
  let second =
    StoredAccount(
      account: account_for(
        "0000000000000000000000000000000000000000000000000000000000000077",
      ),
      secret: "other",
      label: "",
    )
  let client = account_for(client_key)
  let name = process.new_name("bunker_session_relay_auth_test")
  start_bunker_with_load(name, fn() {
    Ok(
      bunker.Snapshot(
        Loaded([first, second], []),
        [session_with(first.account, client, [relay_x])],
        [],
        [],
      ),
    )
  })
  let assert Ok([_, _]) = bunker.accounts(name)
  let first_hex = account.pubkey_hex(first.account)

  let assert Ok([only]) =
    bunker.authenticate(name, relay_x, bunker.SessionRelay, "challenge-1")
  assert only.pubkey == first_hex
  let assert Ok([_, _]) =
    bunker.authenticate(name, relay_x, bunker.BaseRelay, "challenge-1")
  assert bunker.session_signers(name, relay_x) == Some([first_hex])
  stop_bunker(name)
}

/// 取り置いたリレーは、取り置いた署名者で購読と AUTH を行うセッションのリレーに
/// なり、取り外すと一覧から消える。
pub fn reserved_session_relays_open_with_the_reserving_signer_test() {
  let stored = one_account()
  let signer_hex = account.pubkey_hex(stored.account)
  let client_hex = account.pubkey_hex(account_for(client_key))
  let name = process.new_name("bunker_reserved_session_relays_test")
  let urls = process.new_subject()
  start_bunker_with_session_relays(
    name,
    fn() { Ok(bunker.Snapshot(Loaded([stored], []), [], [], [])) },
    process.send(urls, _),
  )
  let assert Ok([_]) = bunker.accounts(name)

  bunker.reserve_session_relays(name, signer_hex, client_hex, [relay_x])
  let assert Ok(reserved) = process.receive(urls, 1000)
  assert reserved == [relay_x]
  assert bunker.session_signers(name, relay_x) == Some([signer_hex])
  let assert Ok([only]) =
    bunker.authenticate(name, relay_x, bunker.SessionRelay, "c")
  assert only.pubkey == signer_hex

  bunker.release_session_relays(name, signer_hex, client_hex)
  let assert Ok(released) = process.receive(urls, 1000)
  assert released == []
  assert bunker.session_signers(name, relay_x) == Some([])
  stop_bunker(name)
}

/// 同じ組のセッションを開いた後の取り外しでは、セッションが同じリレーを持つので
/// 一覧が変わらず、接続は張り直されない。
pub fn releasing_a_reservation_keeps_the_relays_of_an_opened_session_test() {
  let stored = one_account()
  let signer_hex = account.pubkey_hex(stored.account)
  let client_hex = account.pubkey_hex(account_for(client_key))
  let name = process.new_name("bunker_release_after_open_test")
  let urls = process.new_subject()
  start_bunker_with_session_relays(
    name,
    fn() { Ok(bunker.Snapshot(Loaded([stored], []), [], [], [])) },
    process.send(urls, _),
  )
  let assert Ok([_]) = bunker.accounts(name)

  bunker.reserve_session_relays(name, signer_hex, client_hex, [relay_x])
  let assert Ok([_]) = process.receive(urls, 1000)
  let assert Ok(Nil) =
    bunker.open_client_session(
      name,
      signer_hex,
      client_hex,
      "sign_event:1",
      [relay_x],
      "reserved-secret",
    )
  bunker.release_session_relays(name, signer_hex, client_hex)
  assert process.receive(urls, 100) == Error(Nil)
  assert bunker.session_signers(name, relay_x) == Some([signer_hex])
  stop_bunker(name)
}

/// 範囲の違う取り下げは、登録済みの送信手段を消さない（止めたセッションのリレーの
/// 接続の `on_disconnect` が、同じ URL の基本の接続を外さない）。
pub fn a_stale_disconnect_does_not_remove_the_publisher_of_another_scope_test() {
  let name = process.new_name("bunker_stale_disconnect_test")
  start_bunker_with_load(name, fn() {
    Ok(bunker.Snapshot(Loaded([one_account()], []), [], [], []))
  })
  set_publisher(name, relay_x, bunker.BaseRelay, process.new_subject())
  named.send(name, bunker.RemovePublisher(relay_x, bunker.SessionRelay))
  assert bunker.publisher_urls(name) == Some([relay_x])
  named.send(name, bunker.RemovePublisher(relay_x, bunker.BaseRelay))
  assert bunker.publisher_urls(name) == Some([])
  stop_bunker(name)
}
