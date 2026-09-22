//// 偽のストアを持つバンカーで、アカウントの読み込みと再試行、実行中の変更、結果が
//// 曖昧な書き込みの後の読み直しと管理 UI からの読み直しの要求、秘密鍵の問い合わせを
//// 確かめるテスト。

import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/app
import nostr_no_su/backoff.{Backoff}
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault.{Loaded}
import nostr_no_su/named
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/message
import nostr_no_su/time
import support/app_tree.{
  type DatabaseMsg, type SubscriptionReport, ApplyWrite, Deleted, FailReads,
  Inserted, LabelUpdated, Opened, Published, ReadRows, Retrying, Subscribed,
  WriteRows, Wrote, accounts_only, await_connection, await_signers, bunker_spec,
  call_counter, client_key, committed_but_timed_out_store, connect_request,
  connect_request_from, deliver_and_expect, discard_resume_points,
  drain_subscriptions, event_labels, fake_open, fixed_retry_delay,
  forwarding_spec, idle_monitor, load_signer, memory_store, named_relay,
  other_client_key, other_signer_key, receive_until, request, response_body,
  secret, signed_request, signer_key, start_database, start_loading_bunker_tree,
  start_tree, stop_tree, store_failure, store_with_load, stored_signer,
  test_relay, test_relay_url,
}
import support/nip46_client.{account_for}

/// 書き込みが遅いストアで、書き込みの途中に積まれる追加の対象になる署名者の鍵。
const slow_signer_key = "0000000000000000000000000000000000000000000000000000000000000055"

/// 読み込みの再試行の回数を数えるテストの待ち時間。`counted_retries_window_ms` の
/// 窓に、ジッターを入れても 10 回以上の再試行が収まる。
const counted_retry_delay = Backoff(initial_ms: 20, max_ms: 20)

/// 読み込みの再試行の回数を数える窓。
const counted_retries_window_ms = 300

/// ストアの遅い読み書きを、実時間を待たずに模す。呼び出し側（バンカーアクター）の
/// プロセスで作った門の subject を `gates` へ渡し、テストがそこへ `Nil` を送るまで
/// 呼び出し側を止める。subject は所有するプロセスでしか受信できないので、門は
/// テストのプロセスではなく呼び出し側で作る。テストが途中で落ちれば、止まっている
/// アクターはツリーごと終了する。
fn hold_until_released(gates: Subject(Subject(Nil))) -> Nil {
  let gate = process.new_subject()
  process.send(gates, gate)
  process.receive_forever(gate)
}

/// `duration_ms` の間に届いたメッセージの件数。
fn count_within(subject: Subject(Nil), duration_ms: Int) -> Int {
  count_until(subject, time.monotonic_ms() + duration_ms, 0)
}

/// 期限までに届いたメッセージを数える。
fn count_until(subject: Subject(Nil), deadline: Int, count: Int) -> Int {
  let remaining = deadline - time.monotonic_ms()
  case remaining > 0 && process.receive(subject, remaining) == Ok(Nil) {
    True -> count_until(subject, deadline, count + 1)
    False -> count
  }
}

/// すでに届いているメッセージを捨てる。
fn drain(subject: Subject(Nil)) -> Nil {
  case process.receive(subject, 0) {
    Ok(Nil) -> drain(subject)
    Error(Nil) -> Nil
  }
}

/// テスト用のクライアントから、指定した署名者宛に secret 付きで送る `connect`。
fn connect_request_to(signer_key_hex: String, id: String) -> Event {
  let signer = account_for(signer_key_hex)
  nip46_client.request_event(
    account_for(client_key),
    signer,
    nip46_client.connect_body(signer, secret, id),
    time.now_seconds(),
  )
}

/// 読み込みが遅くても、接続が最初に開く購読には読み込んだ署名者が入る。
/// `LoadAccounts` を initialiser が送るので、接続が送る `GetSigners` は必ず読み込みの
/// 後に処理される。送信を initialiser 以外へ移すと、最初の購読が空になって落ちる。
pub fn the_first_subscription_includes_the_loaded_signers_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      process.new_name("test_bunker"),
      store_with_load(fn() {
        process.sleep(300)
        load_signer(signer_key)
      }),
      fixed_retry_delay,
    )
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, filter)])) =
    process.receive(subscribed, 3000)
  assert filter.p_tags == Some([account.pubkey_hex(account_for(signer_key))])
  stop_tree(tree)
}

/// ストアに到達できない間はリクエストに応答せず、読み込みが成功した後に応答する。
/// 起動時に開いた購読は空で、読み込みの成功で再接続を待たずに張り直され、署名者が
/// 入る。
pub fn a_bunker_recovers_when_the_account_store_comes_back_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_call = call_counter()
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      store_with_load(fn() {
        case next_call() < 2 {
          True -> Error("database is unreachable or timed out")
          False -> load_signer(signer_key)
        }
      }),
      // 失敗の間にリクエストを確実に届けられるよう、再試行を遅めにする。
      Backoff(initial_ms: 300, max_ms: 300),
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(Subscribed(_relay_url, [])) = process.receive(subscribed, 2000)
  deliver(connect_request("c1", secret))
  assert process.receive(reports, 200) == Error(Nil)

  assert await_signers(name, [signer], 3000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, filter)])) =
    process.receive(subscribed, 2000)
  assert filter.p_tags == Some([signer])
  deliver(connect_request("c2", secret))
  // 次の報告が応答であることが、接続が開き直されていないことを示す。
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 読み込みに失敗し続けるバンカーを kill しても、再試行の系列は増えない。再試行を
/// 名前付き subject へ予約すると、古いタイマーが再起動後のアクターに届いて系列が
/// 再起動のたびに 1 本ずつ増え、再起動後の回数が約 2 倍になる。
pub fn retries_do_not_multiply_across_restarts_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store_with_load(fn() {
        process.send(calls, Nil)
        Error("database is unreachable or timed out")
      }),
      counted_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  let before = count_within(calls, counted_retries_window_ms)
  assert before >= 5

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  drain(calls)
  let after = count_within(calls, counted_retries_window_ms)
  assert after * 2 <= before * 3
  stop_tree(tree)
}

/// 読み込めていない間に読み直しを要求しても、読み込みの系列は増えない。既に進行中の
/// 読み込みに積み増さないので、失敗し続けるストアへの読み込みの回数はほぼ変わらない。
pub fn a_reload_during_loading_adds_no_series_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store_with_load(fn() {
        process.send(calls, Nil)
        Error("database is unreachable or timed out")
      }),
      counted_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  let before = count_within(calls, counted_retries_window_ms)
  assert before >= 5

  assert bunker.reload_accounts(name) == Ok(Nil)
  assert bunker.reload_accounts(name) == Ok(Nil)
  drain(calls)
  let after = count_within(calls, counted_retries_window_ms)
  assert after * 2 <= before * 3
  stop_tree(tree)
}

/// 管理 UI からの読み直しの要求は、読み込み済みの状態からストアの最新の内容に
/// メモリを合わせる。
pub fn a_requested_reload_picks_up_the_database_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_call = call_counter()
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store_with_load(fn() {
        case next_call() {
          0 -> load_signer(signer_key)
          _ -> load_signer(other_signer_key)
        }
      }),
      fixed_retry_delay,
    )
  assert await_signers(
    name,
    [account.pubkey_hex(account_for(signer_key))],
    2000,
  )

  assert bunker.reload_accounts(name) == Ok(Nil)
  assert await_signers(
    name,
    [account.pubkey_hex(account_for(other_signer_key))],
    2000,
  )
  stop_tree(tree)
}

/// 読み込みの再試行の待ち時間は失敗のたびに倍に延び、読み込みに成功した後の失敗では
/// 初期値から数え直す。タイマーは予約した時間より早く鳴らないので、延びたことは次の
/// 読み込みが待ち時間より前に来ないことで確かめる。
pub fn load_retries_back_off_and_start_over_after_a_success_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_call = call_counter()
  let store =
    bunker.Store(
      ..store_with_load(fn() {
        process.send(calls, Nil)
        case next_call() {
          4 -> load_signer(signer_key)
          _ -> Error("database is unreachable or timed out")
        }
      }),
      insert: fn(_entry) { Error(bunker.MaybeWritten(store_failure())) },
    )
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store,
      Backoff(initial_ms: 50, max_ms: 3200),
    )
  // 1 回目と 2 回目の失敗の間は 50ms。以後は 100、200、400ms と延びる。窓は延びた後の
  // 待ち時間より短く、延びる前の待ち時間の 1.5 倍にする。
  let assert Ok(Nil) = process.receive(calls, 2000)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert process.receive(calls, 75) == Error(Nil)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert process.receive(calls, 150) == Error(Nil)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert process.receive(calls, 300) == Error(Nil)
  let assert Ok(Nil) = process.receive(calls, 2000)
  assert await_signers(
    name,
    [account.pubkey_hex(account_for(signer_key))],
    2000,
  )

  // 結果が曖昧な書き込みの後の読み直しはすぐに行われて失敗する。待ち時間が初期値に
  // 戻っていれば次は 50ms 後で、延びたままなら 800ms 後になる。
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let assert Ok(Nil) = process.receive(calls, 2000)
  let assert Ok(Nil) = process.receive(calls, 700)
  stop_tree(tree)
}

/// 再起動したバンカーは、起動時の仕様ではなくストアの最新からアカウントを読み直す。
pub fn a_restarted_bunker_reloads_the_accounts_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let next_call = call_counter()
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      store_with_load(fn() {
        case next_call() {
          0 -> load_signer(signer_key)
          _ -> load_signer(other_signer_key)
        }
      }),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert bunker.signers(name)
    == Some([account.pubkey_hex(account_for(signer_key))])

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert bunker.signers(name)
    == Some([account.pubkey_hex(account_for(other_signer_key))])
  deliver(connect_request_to(other_signer_key, "c1"))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  let body =
    nip46_client.decrypt_response(
      account_for(client_key),
      account_for(other_signer_key),
      ack,
    )
  assert string.contains(body, "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 再起動しても、接続済みのクライアントは再 `connect` なしで署名でき、承認待ちは
/// DB に保存した経過時間のまま残って承認できる（#215 の受け入れ条件）。
pub fn a_restarted_bunker_restores_sessions_and_pending_requests_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(
    signed_request(nip46_client.connect_body_with_perms(
      account_for(signer_key),
      secret,
      "sign_event:1",
      "c1",
    )),
  )
  let assert Ok(Published(_socket, _ack)) = process.receive(reports, 2000)
  let assert Ok([session]) = bunker.sessions(name)

  deliver(connect_request_from(other_client_key, "c2", ""))
  let assert Ok(Published(_socket, _asked)) = process.receive(reports, 2000)
  let assert Ok([entry]) = bunker.pending(name)

  // DB の作成時刻だけをずらし、メモリではなく DB から読み込んだことを見分ける。
  let shifted = engine.Pending(..entry, created_at: entry.created_at - 300)
  process.call(database, 1000, ApplyWrite(
    engine.InsertPending(pending: shifted, replaced: [entry.token], evicted: []),
    _,
  ))

  let assert Ok(killed) = process.named(name)
  process.kill(killed)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert bunker.sessions(name) == Ok([session])
  assert bunker.pending(name) == Ok([shifted])

  let draft = "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}"
  deliver(request("s1", "sign_event", "[\"" <> draft <> "\"]"))
  let assert Ok(Published(_socket, signed)) = process.receive(reports, 2000)
  let signed_body = response_body(signed)
  assert string.contains(signed_body, "\"id\":\"s1\"")
  assert string.contains(signed_body, "\\\"sig\\\"")

  assert bunker.approve(name, entry.token) == Ok(Nil)
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  let ack_body =
    nip46_client.decrypt_response(
      account_for(other_client_key),
      account_for(signer_key),
      ack,
    )
  assert string.contains(ack_body, "\"id\":\"c2\"")
  assert string.contains(ack_body, "\"result\":\"ack\"")
  stop_tree(tree)
}

/// ストアの読み込みが戻らず、その後も失敗し続けても、監視のプラグインにはイベントが
/// 届き続け、バンカーもルートも再起動しない。読み込みでアクターのループが止まって
/// いる間の問い合わせは、読み込みが戻った後に `named.call` のタイムアウトより前に
/// 応答する。
pub fn a_failing_account_store_does_not_affect_the_monitor_test() {
  let reports = process.new_subject()
  let seen = process.new_subject()
  let gates = process.new_subject()
  let next_call = call_counter()
  let bunker_name = process.new_name("test_bunker")
  let monitor_relay = test_relay()
  let tree =
    start_tree(app.Spec(
      plugins: [
        forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
      ],
      not_loaded_plugins: [],
      monitor: app.Monitor(
        name: process.new_name("test_dedup"),
        dedup_capacity: 8,
        relays: [monitor_relay],
        subscriptions: fn(_relay_url) { fn() { Ok([]) } },
        save_resume: discard_resume_points,
        save_plugin_resume: discard_resume_points,
        excludes_kind: event.is_ephemeral,
        accepts_author: fn(_pubkey) { True },
      ),
      bunker: bunker_spec(
        bunker_name,
        store_with_load(fn() {
          // 最初の読み込みは、到達できない DB に対するチェックアウト待ちを模して、
          // テストが開けるまで戻らない。以後の再試行は待たずに失敗する。
          case next_call() {
            0 -> hold_until_released(gates)
            _ -> Nil
          }
          Error("database is unreachable or timed out")
        }),
        [named_relay("ws://bunker.test")],
        fixed_retry_delay,
      ),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    ))
  let assert Opened(first_url, _connection_1, _socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, _socket_2, deliver_2) =
    await_connection(reports)
  let deliver = case first_url == monitor_relay.url {
    True -> deliver_1
    False -> deliver_2
  }
  let assert Ok(bunker_before) = process.named(bunker_name)

  // 読み込みで止まっている間にイベントを届ける。
  let assert Ok(gate) = process.receive(gates, 2000)
  deliver_and_expect(deliver, seen, event_labels("while-failing", 3), 2000)
  process.send(gate, Nil)
  let asked_at = time.monotonic_ms()
  // 読み込めていない間 `bunker.sessions` は理由を返すので、応答したことは
  // `named.call` の `Some` で確かめる。
  let assert Some(_) = named.call(bunker_name, 5000, bunker.GetSessions)
  assert time.monotonic_ms() - asked_at < 5000
  assert process.named(bunker_name) == Ok(bunker_before)
  assert process.is_alive(tree)
  stop_tree(tree)
}

/// 報告が、署名者の購読を開き直すただ 1 件の REQ か。
fn subscribes(report: SubscriptionReport, signers: List(String)) -> Bool {
  case report {
    Subscribed(_relay_url, [message.Req(_id, filter)]) ->
      filter.p_tags == Some(signers)
    _ -> False
  }
}

/// 報告が、バンカーの購読を閉じる CLOSE を含むか。
fn closes(report: SubscriptionReport) -> Bool {
  case report {
    Subscribed(_relay_url, messages) ->
      list.contains(messages, message.Close("bunker"))
    Retrying(_relay_url) -> False
  }
}

/// アカウント 0 件で起動したバンカーに実行中に追加したアカウントは、接続を開き
/// 直さずに購読の #p に入り、ストアに書いた secret で接続できる。一覧の secret は
/// ストアに書いた secret と一致する。
pub fn an_account_added_at_runtime_answers_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      memory_store(calls, [], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  assert process.receive(subscribed, 2000) == Ok(Subscribed(test_relay_url, []))
  assert bunker.accounts(name) == Ok([])

  assert bunker.add_account(name, account_for(signer_key), "main") == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, filter)])) =
    process.receive(subscribed, 2000)
  assert filter.p_tags == Some([signer])
  let assert Ok(Inserted(inserted_signer, inserted_secret, "main")) =
    process.receive(calls, 1000)
  assert inserted_signer == signer
  assert bunker.accounts(name)
    == Ok([
      bunker.Listing(
        signer: signer,
        npub: account.npub(account_for(signer_key)),
        label: "main",
        secret: inserted_secret,
      ),
    ])

  deliver(connect_request("c1", inserted_secret))
  // 次の報告が応答であることが、接続が開き直されていないことを示す。
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 削除したアカウントは購読から外れ（CLOSE）、そのアカウント宛のリクエストには
/// 応答しない。セッションも消える。
pub fn a_removed_account_stops_answering_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      memory_store(calls, [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(Wrote(engine.InsertSession(..))) = process.receive(calls, 1000)

  assert bunker.remove_account(name, signer) == Ok(Nil)
  let #(_skipped, closed) = receive_until(subscribed, closes, 2000)
  assert closed == Ok(Subscribed(test_relay_url, [message.Close("bunker")]))
  assert process.receive(calls, 1000) == Ok(Deleted(signer))
  deliver(request("p1", "ping", "[]"))
  deliver(connect_request("c2", secret))
  assert process.receive(reports, 300) == Error(Nil)
  assert bunker.sessions(name) == Ok([])
  stop_tree(tree)
}

/// アカウントを追加・削除し、secret を作り直し、ラベルを差し替えても、バンカー
/// アクターは再起動せず、接続も開き直さず、既存のセッションは残る。作り直した後は
/// 古い secret での新規の `connect` を承認なしには通さない。
pub fn account_changes_keep_the_bunker_and_its_sessions_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let other = account.pubkey_hex(account_for(other_signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      memory_store(process.new_subject(), [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(before) = process.named(name)

  assert bunker.add_account(name, account_for(other_signer_key), "other")
    == Ok(Nil)
  assert bunker.remove_account(name, other) == Ok(Nil)
  assert bunker.rotate_secret(name, signer) == Ok(Nil)
  assert bunker.update_label(name, signer, "renamed") == Ok(Nil)
  assert process.named(name) == Ok(before)
  let assert Ok([
    bunker.Listing(signer: listed, label: "renamed", secret: rotated, ..),
  ]) = bunker.accounts(name)
  assert listed == signer
  assert rotated != secret

  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  deliver(connect_request_from(other_client_key, "c2", secret))
  let assert Ok(Published(_socket, asked)) = process.receive(reports, 2000)
  let body =
    nip46_client.decrypt_response(
      account_for(other_client_key),
      account_for(signer_key),
      asked,
    )
  assert string.contains(body, "\"result\":\"auth_url\"")
  assert process.receive(reports, 300) == Error(Nil)
  stop_tree(tree)
}

/// ストアへの書き込みが失敗したら、一覧も購読も変えず、削除に失敗した署名者は
/// 応答し続ける。
pub fn a_failed_write_changes_nothing_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      bunker.Store(
        ..memory_store(process.new_subject(), [stored_signer(signer_key)], True),
        write: fn(_write) { Ok(Nil) },
      ),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  let assert Ok(Subscribed(_relay_url, [message.Req(..)])) =
    process.receive(subscribed, 2000)
  drain_subscriptions(subscribed, 200)
  let listed =
    Ok([
      bunker.Listing(
        signer: signer,
        npub: account.npub(account_for(signer_key)),
        label: "",
        secret: secret,
      ),
    ])
  assert bunker.accounts(name) == listed

  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.NotApplied(store_failure()))
  assert bunker.accounts(name) == listed
  assert process.receive(subscribed, 300) == Error(Nil)

  assert bunker.remove_account(name, signer)
    == Error(bunker.NotApplied(store_failure()))
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 読み込みの前の変更はストアを呼ばずに拒否し、一覧は読み込めない理由を返す。
pub fn changes_before_loading_do_not_reach_the_store_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let store =
    bunker.Store(..memory_store(calls, [], False), load: fn() {
      Error(store_failure())
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  assert bunker.add_account(name, account_for(signer_key), "")
    == Error(bunker.NotReady("accounts are not loaded yet"))
  assert process.receive(calls, 100) == Error(Nil)
  assert bunker.accounts(name)
    == Error("account store unavailable: " <> store_failure())
  stop_tree(tree)
}

/// 書き込みの応答を待っている間に届いたリクエストは捨てられず、書き込みの応答の
/// 後に処理される。
pub fn requests_during_a_slow_write_are_not_dropped_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let results = process.new_subject()
  let gates = process.new_subject()
  let name = process.new_name("test_bunker")
  let store = memory_store(calls, [stored_signer(signer_key)], False)
  let slow =
    bunker.Store(..store, insert: fn(entry) {
      let written = store.insert(entry)
      // 書き込みの応答を、テストが開けるまで遅らせる。
      hold_until_released(gates)
      written
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, slow, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(Wrote(engine.InsertSession(..))) = process.receive(calls, 1000)

  // `add_account` は応答まで呼び出し側を止めるので、別のプロセスから呼ぶ。
  process.spawn(fn() {
    process.send(
      results,
      bunker.add_account(name, account_for(other_signer_key), ""),
    )
  })
  let assert Ok(Inserted(..)) = process.receive(calls, 1000)
  let assert Ok(gate) = process.receive(gates, 1000)
  deliver(request("p1", "ping", "[]"))
  assert process.receive(reports, 300) == Error(Nil)
  process.send(gate, Nil)
  assert process.receive(results, 2000) == Ok(Ok(Nil))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  stop_tree(tree)
}

/// ラベルの差し替えは一覧とストアに届く。メモリに無い署名者への変更と、登録済みの
/// 公開鍵の追加は、ストアを呼ばずに拒否する。
pub fn labels_and_registration_checks_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let stranger = account.pubkey_hex(account_for(other_signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      memory_store(calls, [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  assert bunker.update_label(name, signer, "renamed") == Ok(Nil)
  assert process.receive(calls, 1000) == Ok(LabelUpdated(signer, "renamed"))
  assert bunker.accounts(name)
    == Ok([
      bunker.Listing(
        signer: signer,
        npub: account.npub(account_for(signer_key)),
        label: "renamed",
        secret: secret,
      ),
    ])

  let not_registered = Error(bunker.AccountNotRegistered)
  assert bunker.update_label(name, stranger, "x") == not_registered
  assert bunker.rotate_secret(name, stranger) == not_registered
  assert bunker.remove_account(name, stranger) == not_registered
  assert bunker.add_account(name, account_for(signer_key), "again")
    == Error(bunker.AccountAlreadyRegistered)
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// 署名者の問い合わせがタイムアウトしても、開いている購読を閉じない。X の追加で
/// 張り直しが起きたとき、その問い合わせは Y の書き込みの後ろに積まれて 5000ms を超える。
/// 購読は変わらずに再試行が予約され、Y の失敗の後の再試行で A と X の REQ になる。
/// 問い合わせの失敗を署名者 0 件として扱う実装では、ここで CLOSE が届いて落ちる。
///
/// 順序は時間の余裕ではなく、偽の書き込みを止める門で作る。X の書き込みを止めている
/// 間に Y の追加がアクターのメールボックスに積まれたことを確かめてから X を通し、Y の
/// 書き込みは再試行の予約を確かめるまで止めておく。
pub fn a_timed_out_signer_query_does_not_close_live_subscriptions_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let results = process.new_subject()
  let gates = process.new_subject()
  let name = process.new_name("test_bunker")
  let signer = account.pubkey_hex(account_for(signer_key))
  let fast = account.pubkey_hex(account_for(other_signer_key))
  let slow = account.pubkey_hex(account_for(slow_signer_key))
  let store =
    memory_store(process.new_subject(), [stored_signer(signer_key)], False)
  let gated =
    bunker.Store(..store, insert: fn(entry: vault.StoredAccount) {
      let written = account.pubkey_hex(entry.account)
      // 門はアクターのプロセスで作るので、アクターの中で受信できる。
      let gate = process.new_subject()
      process.send(gates, #(written, gate))
      process.receive_forever(gate)
      case written == slow {
        True -> Error(bunker.NotWritten(store_failure()))
        False -> store.insert(entry)
      }
    })
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      gated,
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  let assert Ok(Subscribed(_relay_url, [message.Req(..)])) =
    process.receive(subscribed, 2000)
  drain_subscriptions(subscribed, 200)
  let assert Ok(actor) = process.named(name)

  process.spawn(fn() {
    process.send(
      results,
      bunker.add_account(name, account_for(other_signer_key), ""),
    )
  })
  let assert Ok(#(blocked_first, release_first)) = process.receive(gates, 2000)
  assert blocked_first == fast
  process.spawn(fn() {
    process.send(
      results,
      bunker.add_account(name, account_for(slow_signer_key), ""),
    )
  })
  assert await_queued(actor, 2000)
  process.send(release_first, Nil)
  let assert Ok(#(blocked_second, release_second)) =
    process.receive(gates, 2000)
  assert blocked_second == slow

  let #(before_retry, retrying) =
    receive_until(
      subscribed,
      fn(report) { report == Retrying(test_relay_url) },
      7000,
    )
  assert retrying == Ok(Retrying(test_relay_url))
  assert !list.any(before_retry, closes)
  process.send(release_second, Nil)
  let #(before_request, requested) =
    receive_until(
      subscribed,
      subscribes(_, list.sort([signer, fast], string.compare)),
      3000,
    )
  assert !list.any(before_request, closes)
  let assert Ok(_request) = requested
  // 呼び出し側のプロセスが結果を転送するのは偽ソケットの報告とは別の送信なので、
  // 届く順序は決まらない。十分に待つ。
  assert process.receive(results, 1000) == Ok(Ok(Nil))
  assert process.receive(results, 1000)
    == Ok(Error(bunker.NotApplied(store_failure())))
  assert process.receive(reports, 0) == Error(Nil)
  stop_tree(tree)
}

/// アクターのメールボックスにメッセージが積まれるまで待つ。
fn await_queued(actor: Pid, remaining: Int) -> Bool {
  let #(_item, queued) = process_info(actor, atom.create("message_queue_len"))
  case queued > 0, remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(10)
      await_queued(actor, remaining - 10)
    }
  }
}

/// プロセスの情報 1 項目。
@external(erlang, "erlang", "process_info")
fn process_info(pid: Pid, item: Atom) -> #(Atom, Int)

/// 偽のデータベースの行を、バンカーの一覧と同じ形（署名者の昇順）にする。
fn database_listings(database: Subject(DatabaseMsg)) -> List(bunker.Listing) {
  let assert Ok(snapshot) = process.call(database, 1000, ReadRows)
  snapshot.accounts.accounts
  |> list.map(fn(row) {
    bunker.Listing(
      signer: account.pubkey_hex(row.account),
      npub: account.npub(row.account),
      label: row.label,
      secret: row.secret,
    )
  })
  |> list.sort(fn(left, right) { string.compare(left.signer, right.signer) })
}

/// バンカーの一覧が期待どおりになるまで待つ。
fn await_accounts(
  name: Name(bunker.Msg),
  expected: List(bunker.Listing),
  remaining: Int,
) -> Bool {
  case bunker.accounts(name) == Ok(expected), remaining <= 0 {
    True, _ -> True
    _, True -> False
    _, False -> {
      process.sleep(20)
      await_accounts(name, expected, remaining - 20)
    }
  }
}

/// 結果が曖昧な追加がコミットされていたら、読み直してメモリを DB に合わせる。追加した
/// 署名者は購読に入り、既存の署名者のセッションは残る。合わせた後は、登録済みとしての
/// 拒否、削除、追加し直しがそれぞれ DB と一致したまま動く。
pub fn an_ambiguous_add_is_reconciled_with_the_store_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let signer = account.pubkey_hex(account_for(signer_key))
  let other = account.pubkey_hex(account_for(other_signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  let assert Ok(before) = process.named(name)

  assert bunker.add_account(name, account_for(other_signer_key), "other")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let stored = database_listings(database)
  assert list.map(stored, fn(listing) { listing.signer })
    == list.sort([signer, other], string.compare)
  assert bunker.accounts(name) == Ok(stored)
  let #(_skipped, resubscribed) =
    receive_until(
      subscribed,
      subscribes(_, list.sort([signer, other], string.compare)),
      2000,
    )
  let assert Ok(_request) = resubscribed
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")

  assert bunker.add_account(name, account_for(other_signer_key), "again")
    == Error(bunker.AccountAlreadyRegistered)
  assert bunker.remove_account(name, other)
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert list.map(database_listings(database), fn(listing) { listing.signer })
    == [signer]
  assert bunker.accounts(name) == Ok(database_listings(database))
  assert bunker.add_account(name, account_for(other_signer_key), "back")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert list.length(database_listings(database)) == 2
  assert bunker.accounts(name) == Ok(database_listings(database))
  assert process.named(name) == Ok(before)
  stop_tree(tree)
}

/// 結果が曖昧な secret の作り直しがコミットされていたら、読み直して新しい secret を
/// メモリに反映する。セッションは残り、新しい secret で接続できる。
pub fn an_ambiguous_secret_rotation_is_reconciled_with_the_store_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")

  assert bunker.rotate_secret(name, signer)
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  let assert [bunker.Listing(secret: rotated, ..)] = database_listings(database)
  assert rotated != secret
  assert bunker.accounts(name) == Ok(database_listings(database))

  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")
  deliver(connect_request_from(other_client_key, "c2", rotated))
  let assert Ok(Published(_socket, joined)) = process.receive(reports, 2000)
  let body =
    nip46_client.decrypt_response(
      account_for(other_client_key),
      account_for(signer_key),
      joined,
    )
  assert string.contains(body, "\"result\":\"ack\"")
  stop_tree(tree)
}

/// 読み直しに失敗したら、メモリのアカウントのまま NIP-46 に応答し続け、変更を拒否し、
/// 一覧は理由を返す。読み込めるようになったら、再試行で DB と一致する。
pub fn a_failed_reload_keeps_the_accounts_and_retries_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  deliver(connect_request("c1", secret))
  let assert Ok(Published(_socket, ack)) = process.receive(reports, 2000)
  assert string.contains(response_body(ack), "\"result\":\"ack\"")
  assert bunker.accounts(name) == Ok(database_listings(database))

  process.send(database, FailReads(True))
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert bunker.accounts(name)
    == Error("account store unavailable: " <> store_failure())
  assert bunker.add_account(name, account_for(slow_signer_key), "")
    == Error(bunker.NotReady("accounts are not loaded yet"))
  deliver(request("p1", "ping", "[]"))
  let assert Ok(Published(_socket, pong)) = process.receive(reports, 2000)
  assert string.contains(response_body(pong), "\"result\":\"pong\"")

  process.send(database, FailReads(False))
  assert await_accounts(name, database_listings(database), 2000)
  assert list.length(database_listings(database)) == 2
  stop_tree(tree)
}

/// ストアが登録済みを返す追加の失敗。
fn already_stored() -> Result(Nil, bunker.WriteFailure) {
  Error(
    bunker.AlreadyStored(account_store.describe(account_store.AlreadyRegistered)),
  )
}

/// DB にだけある行の公開鍵を追加すると、応答の前に読み直してメモリに入れ、登録済み
/// として応答する。
pub fn adding_a_row_that_only_the_store_has_reads_it_back_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let store =
    bunker.Store(..committed_but_timed_out_store(database), insert: fn(_entry) {
      already_stored()
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert bunker.accounts(name) == Ok(database_listings(database))

  // 読み直しに見えなかった書き込みで、DB だけが先行している状態を作る。
  process.call(database, 1000, WriteRows(
    list.append(_, [stored_signer(other_signer_key)]),
    _,
  ))
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.AccountAlreadyRegistered)
  let stored = database_listings(database)
  assert list.length(stored) == 2
  assert bunker.accounts(name) == Ok(stored)
  stop_tree(tree)
}

/// 読み込みで飛ばされる行の公開鍵を追加すると、読み直してもメモリに入らないので、
/// 何度追加しても「反映されたかもしれない」ではなく登録済みとして拒否する。
pub fn adding_a_skipped_row_is_rejected_as_registered_test() {
  let reports = process.new_subject()
  let loads = process.new_subject()
  let name = process.new_name("test_bunker")
  let skipped = account.pubkey_hex(account_for(other_signer_key))
  let store =
    bunker.Store(
      ..store_with_load(fn() {
        process.send(loads, Nil)
        Ok(
          bunker.Snapshot(
            ..accounts_only([]),
            accounts: Loaded(accounts: [], skipped: [
              vault.Skipped(
                pubkey: skipped,
                label: "",
                reason: vault.UndecryptablePrivateKey,
              ),
            ]),
          ),
        )
      }),
      insert: fn(_entry) { already_stored() },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert process.receive(loads, 1000) == Ok(Nil)

  list.each([1, 2], fn(_attempt) {
    assert bunker.add_account(name, account_for(other_signer_key), "")
      == Error(bunker.AccountAlreadyRegistered)
    // 追加のたびに読み直している。
    assert process.receive(loads, 0) == Ok(Nil)
    assert bunker.accounts(name) == Ok([])
  })
  stop_tree(tree)
}

/// 直近の読み込みで飛ばされた行は `app.skipped_rows` でも取れ、管理 UI の行
/// （npub とラベルを持つ）になる。
pub fn skipped_rows_are_kept_for_the_admin_ui_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let skipped_pubkey = account.pubkey_hex(account_for(other_signer_key))
  let store =
    store_with_load(fn() {
      Ok(
        bunker.Snapshot(
          ..accounts_only([]),
          accounts: Loaded(accounts: [], skipped: [
            vault.Skipped(
              pubkey: skipped_pubkey,
              label: "old wallet",
              reason: vault.UndecryptablePrivateKey,
            ),
          ]),
        ),
      )
    })
  let spec =
    app.Spec(
      plugins: [],
      not_loaded_plugins: [],
      monitor: idle_monitor(),
      bunker: bunker_spec(name, store, [test_relay()], fixed_retry_delay),
      admin: None,
      open: fake_open(reports, None),
      reconnect_delay: Backoff(initial_ms: 100, max_ms: 100),
      relay_list: process.new_name("test_relay_list"),
    )
  let tree = start_tree(spec)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  let assert Ok([row]) = app.skipped_rows(spec)
  assert row.pubkey == skipped_pubkey
  assert row.npub == account.npub(account_for(other_signer_key))
  assert row.label == "old wallet"
  assert row.reason == vault.UndecryptablePrivateKey
  stop_tree(tree)
}

/// 読み込みで飛ばされた行の公開鍵の削除は、ストアの `delete` に届き、
/// `bunker.skipped` からその行が消える。署名者の集合は変わらないので、購読は
/// 張り直されない。
pub fn removing_a_skipped_row_deletes_it_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let skipped_pubkey = account.pubkey_hex(account_for(other_signer_key))
  let store =
    bunker.Store(
      ..store_with_load(fn() {
        Ok(
          bunker.Snapshot(
            ..accounts_only([stored_signer(signer_key)]),
            accounts: Loaded(accounts: [stored_signer(signer_key)], skipped: [
              vault.Skipped(
                pubkey: skipped_pubkey,
                label: "old wallet",
                reason: vault.UndecryptablePrivateKey,
              ),
            ]),
          ),
        )
      }),
      delete: fn(deleted) {
        process.send(calls, Deleted(deleted))
        Ok(Nil)
      },
    )
  let tree =
    start_loading_bunker_tree(
      reports,
      Some(subscribed),
      name,
      store,
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  drain_subscriptions(subscribed, 200)
  let assert Ok([skipped_row]) = bunker.skipped(name)
  assert skipped_row.pubkey == skipped_pubkey

  assert bunker.remove_account(name, skipped_pubkey) == Ok(Nil)
  assert process.receive(calls, 1000) == Ok(Deleted(skipped_pubkey))
  assert bunker.skipped(name) == Ok([])
  assert process.receive(subscribed, 300) == Error(Nil)
  stop_tree(tree)
}

/// 登録済みでも、読み込みで飛ばされた行にも無い公開鍵の削除は、ストアを呼ばずに
/// 拒否する。
pub fn removing_an_unlisted_signer_does_not_reach_the_store_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let skipped_pubkey = account.pubkey_hex(account_for(other_signer_key))
  let stranger = account.pubkey_hex(account_for(other_client_key))
  let store =
    bunker.Store(
      ..store_with_load(fn() {
        Ok(
          bunker.Snapshot(
            ..accounts_only([stored_signer(signer_key)]),
            accounts: Loaded(accounts: [stored_signer(signer_key)], skipped: [
              vault.Skipped(
                pubkey: skipped_pubkey,
                label: "",
                reason: vault.UndecryptablePrivateKey,
              ),
            ]),
          ),
        )
      }),
      delete: fn(deleted) {
        process.send(calls, Deleted(deleted))
        Ok(Nil)
      },
    )
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  assert bunker.remove_account(name, stranger)
    == Error(bunker.AccountNotRegistered)
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

// --- 秘密鍵の再表示の問い合わせ ---

/// 読み込みの前は、秘密鍵の問い合わせを拒否し、ストアを呼ばない。
pub fn nsec_is_refused_before_the_accounts_are_loaded_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let store =
    bunker.Store(..memory_store(calls, [], False), load: fn() {
      Error(store_failure())
    })
  let tree =
    start_loading_bunker_tree(reports, None, name, store, fixed_retry_delay)
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  assert bunker.nsec(name, account.pubkey_hex(account_for(signer_key)))
    == Error("accounts are not loaded yet")
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// 読み込んだ後は、登録済みの署名者に nsec を返し、未登録の署名者は拒否する。どちらも
/// ストアを呼ばない。一覧の npub は `account.npub` と一致する。
pub fn nsec_answers_for_a_registered_signer_test() {
  let reports = process.new_subject()
  let calls = process.new_subject()
  let name = process.new_name("test_bunker")
  let registered = account_for(signer_key)
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      memory_store(calls, [stored_signer(signer_key)], False),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)

  let assert Ok([listing]) = bunker.accounts(name)
  assert listing.npub == account.npub(registered)
  assert bunker.nsec(name, account.pubkey_hex(account_for(other_signer_key)))
    == Error("account is not registered")
  assert bunker.nsec(name, account.pubkey_hex(registered))
    == Ok(account.nsec(registered))
  assert process.receive(calls, 100) == Error(Nil)
  stop_tree(tree)
}

/// 結果が曖昧な書き込みの後、読み直しが成功するまでは秘密鍵の問い合わせを拒否する。
pub fn nsec_is_refused_until_an_ambiguous_write_is_reloaded_test() {
  let reports = process.new_subject()
  let name = process.new_name("test_bunker")
  let database = start_database([stored_signer(signer_key)])
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_loading_bunker_tree(
      reports,
      None,
      name,
      committed_but_timed_out_store(database),
      fixed_retry_delay,
    )
  let assert Opened(_relay_url, _connection, _socket, _deliver) =
    await_connection(reports)
  assert bunker.nsec(name, signer) == Ok(account.nsec(account_for(signer_key)))

  process.send(database, FailReads(True))
  assert bunker.add_account(name, account_for(other_signer_key), "")
    == Error(bunker.MaybeApplied(bunker.StoreDidNotConfirm))
  assert bunker.nsec(name, signer) == Error("accounts are not loaded yet")

  process.send(database, FailReads(False))
  assert await_accounts(name, database_listings(database), 2000)
  assert bunker.nsec(name, signer) == Ok(account.nsec(account_for(signer_key)))
  stop_tree(tree)
}
