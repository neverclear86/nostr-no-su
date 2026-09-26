//// `bunker.load_report` のテストと、バンカーアクターの状態に接続 secret が出ないことの
//// テスト。読み込みの結果に対して、どのログ行を出すかを確かめる。
//// `rate-limited:` を返したリレーのアクターのテストは、`Acknowledged` と `Incoming`
//// から発行までの配線を確かめる。
//// セッションのリレーのアクターのテストは、応答の発行先、購読と AUTH の署名者、
//// 取り消しで閉じる一覧を確かめる。`bunker.sign_event`
//// （`SignEvent`）のテストは、プラグインからの送信の口（`plugin_api`）が使う
//// 署名の要求を、読み込み前と登録済みの署名者のそれぞれで確かめる。
//// `bunker.check_accounts`（`CheckAccounts`）のテストは、プラグインからの取得の口
//// （`plugin_api`）が使う登録の確認を、読み込み前と、登録済みと未登録を混ぜた順の
//// それぞれで確かめる。
//// `bunker.reserve_session_relays` / `bunker.release_session_relays` のテストは、
//// 取り置いた署名者で開く接続の購読と AUTH と、セッションを開いた後の取り外しで
//// 接続が残ることを確かめる。

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/system
import gleam/string
import nostr_no_su/backoff
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/delivery
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{Loaded, Skipped, StoredAccount}
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
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
    bunker.SetPublisher(relay_a, delivery.BaseRelay, process.send(inbox_a, _)),
  )
  named.send(
    name,
    bunker.SetPublisher(relay_b, delivery.BaseRelay, process.send(inbox_b, _)),
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
  scope: delivery.RelayScope,
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
  set_publisher(name, relay_a, delivery.BaseRelay, inbox_a)
  set_publisher(name, relay_x, delivery.SessionRelay, inbox_x)
  set_publisher(name, relay_y, delivery.SessionRelay, inbox_y)

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
  set_publisher(bare, relay_x, delivery.SessionRelay, bare_x)
  set_publisher(bare, relay_y, delivery.SessionRelay, bare_y)
  send_get_public_key(bare, stranger, signer, "g3")
  assert process.receive(bare_x, 200) == Error(Nil)
  assert process.receive(bare_y, 100) == Error(Nil)
  stop_bunker(bare)
}

/// `logout` の応答は、閉じたセッションのリレーにも届く。応答の宛先を探す時点では
/// 書き込み後のエンジンにセッションは無いので、書き込み前のエンジンからも引く。
pub fn a_logout_response_reaches_the_relays_of_the_closed_session_test() {
  let stored = one_account()
  let signer = stored.account
  let client = account_for(client_key)
  let name = process.new_name("bunker_logout_response_relays_test")
  start_bunker_with_load(name, fn() {
    Ok(
      bunker.Snapshot(
        Loaded([stored], []),
        [session_with(signer, client, [relay_x])],
        [],
        [],
      ),
    )
  })
  let assert Ok([_]) = bunker.accounts(name)
  let inbox_a = process.new_subject()
  let inbox_x = process.new_subject()
  set_publisher(name, relay_a, delivery.BaseRelay, inbox_a)
  set_publisher(name, relay_x, delivery.SessionRelay, inbox_x)

  named.send(
    name,
    bunker.Incoming(
      signed_event.verified(request_event(
        client,
        signer,
        request_body("l1", "logout", "[]"),
        time.now_seconds(),
      )),
    ),
  )
  let assert Ok(_response) = process.receive(inbox_a, 1000)
  let assert Ok(_response) = process.receive(inbox_x, 1000)
  assert bunker.sessions(name) == Ok([])
  stop_bunker(name)
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
    bunker.authenticate(name, relay_x, delivery.SessionRelay, "challenge-1")
  assert only.pubkey == first_hex
  let assert Ok([_, _]) =
    bunker.authenticate(name, relay_x, delivery.BaseRelay, "challenge-1")
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
    bunker.authenticate(name, relay_x, delivery.SessionRelay, "c")
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
  set_publisher(name, relay_x, delivery.BaseRelay, process.new_subject())
  named.send(name, bunker.RemovePublisher(relay_x, delivery.SessionRelay))
  assert bunker.publisher_urls(name) == Some([relay_x])
  named.send(name, bunker.RemovePublisher(relay_x, delivery.BaseRelay))
  assert bunker.publisher_urls(name) == Some([])
  stop_bunker(name)
}
