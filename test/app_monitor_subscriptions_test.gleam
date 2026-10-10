//// 偽リレーの上のツリーで、本番と同じ組み立ての監視の購読と取り直しを確かめるテスト。
//// 登録アカウントの増減への追随、再開点、プラグインごとの取り直しの要求、届いた
//// イベントの作者の照合を扱う。

import gleam/dict
import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/dedup
import nostr_no_su/nostr/event.{type Event}
import nostr_no_su/nostr/filter
import nostr_no_su/nostr/message
import nostr_no_su/plugin
import nostr_no_su/plugin_runner
import nostr_no_su/relay_client
import nostr_no_su/relay_list
import nostr_no_su/subscriptions
import nostr_no_su/time
import support/app_tree.{
  type Report, type SubscriptionReport, Opened, Retrying, Subscribed,
  await_connection, await_restart, base_spec, bunker_spec, drain_until_quiet,
  fake_open, fixed_retry_delay, forwarding_spec, idle_monitor, idle_plugin,
  load_signer, memory_store, note, other_signer_key, receive_until, signer_key,
  signer_store, start_tree, start_tree_with_relays, stop_tree, store_with_load,
  test_relay_url,
}

import support/nip46_client.{account_for}
import support/signed_event

/// 実行時のリレーの増減のテストで、3 人目として追加する署名者の鍵。
const third_signer_key =
  "0000000000000000000000000000000000000000000000000000000000000099"

/// どのリレーにも `stored` を返す、再開点の読み込みの操作。
fn fixed_resume_point(
  stored: Result(Option(Int), String),
) -> fn(String) -> Result(Option(Int), String) {
  fn(_relay_url) { stored }
}

// --- 監視の購読 ---

/// `monitored_accounts_spec` の入力。`load_resume` は監視の再開点、
/// `load_plugin_resume` はプラグインの保存済みの再開点を読む操作。`catchups` は
/// プラグインの一覧から取り直しの要求を問い合わせる操作を作る。
type Monitored {
  Monitored(
    store: bunker.Store,
    load_resume: fn(String) -> Result(Option(Int), String),
    plugins: List(app.PluginSpec),
    load_plugin_resume: fn(String) -> Result(Option(Int), String),
    catchups: fn(List(app.PluginSpec)) ->
      fn() -> Result(List(#(String, plugin_runner.Catchup)), Nil),
  )
}

/// `signer_key` を登録済みとし、再開点が無く、プラグインを載せず、取り直しの要求は
/// 本番と同じ `app.plugin_catchups` で問い合わせる入力。各テストは
/// `Monitored(..monitored_defaults(), …)` で違うフィールドだけを書く。
fn monitored_defaults() -> Monitored {
  Monitored(
    store: signer_store(),
    load_resume: fixed_resume_point(Ok(None)),
    plugins: [],
    load_plugin_resume: fixed_resume_point(Ok(None)),
    catchups: app.plugin_catchups,
  )
}

/// 監視のリレーを起動後に開くツリーの仕様。購読は本番と同じ
/// `subscriptions.monitor_relay_subscriptions` から組み立てる。リレーは呼び出し側が
/// `start_tree_with_relays` で開き、バンカーの用途で開いたリレーの購読も
/// `subscribed` へ報告される。プラグインを載せると、その取り直しの要求も
/// `monitored.catchups` から購読へ現れる。作者の照合も本番と同じ
/// `bunker.is_signer` で行う。
fn monitored_accounts_spec(
  reports: Subject(Report),
  subscribed: Subject(SubscriptionReport),
  monitored: Monitored,
) -> app.Spec {
  let bunker_name = process.new_name("test_bunker")
  let dedup_name = process.new_name("test_dedup")
  app.Spec(
    ..base_spec(reports),
    plugins: monitored.plugins,
    monitor: app.Monitor(
      ..idle_monitor(),
      name: dedup_name,
      dedup_capacity: 64,
      subscriptions: subscriptions.monitor_relay_subscriptions(
        bunker_name,
        dedup_name,
        monitored.load_resume,
        monitored.load_plugin_resume,
        monitored.catchups(monitored.plugins),
        _,
      ),
      accepts_author: bunker.is_signer(bunker_name, _),
    ),
    bunker: bunker_spec(bunker_name, monitored.store, fixed_retry_delay),
    open: fake_open(reports, Some(subscribed)),
  )
}

/// 報告が、指定したリレーの接続の REQ 1 件か。
fn requests_on(report: SubscriptionReport, relay_url: String) -> Bool {
  case report {
    Subscribed(url, [message.Req(..)]) -> url == relay_url
    _ -> False
  }
}

/// 起動直後の監視の購読は、読み込みに時間がかかっても読み込み済みの署名者を含み、
/// 読み込みの成功による張り直しでは定義が同じなので REQ を送り直さない。
pub fn the_first_monitor_subscription_includes_the_loaded_signers_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let signer = account.pubkey_hex(account_for(signer_key))
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(
        reports,
        subscribed,
        Monitored(
          ..monitored_defaults(),
          store: store_with_load(fn() {
            // 読み込みが接続の最初の評価より遅れて終わることを模す。
            process.sleep(300)
            load_signer(signer_key)
          }),
          load_resume: fixed_resume_point(Ok(Some(1234))),
        ),
      ),
      [test_relay_url],
      [],
    )
  let assert Ok(Subscribed(_relay_url, [message.Req("nostr-no-su", filter)])) =
    process.receive(subscribed, 2000)
  assert filter.authors == Some([signer])
  assert filter.since == Some(1234)

  assert process.receive(subscribed, 2000) == Ok(Subscribed(test_relay_url, []))
  stop_tree(tree)
}

/// 監視の購読は、登録アカウントの追加・削除に合わせて張り直される。追加の時刻は
/// 追加の呼び出しの前後の現在時刻の範囲に収まり、以後の張り直しでも遡らない。
pub fn the_monitor_subscription_follows_account_changes_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let signer = account.pubkey_hex(account_for(signer_key))
  let other_signer = account.pubkey_hex(account_for(other_signer_key))
  let spec =
    monitored_accounts_spec(
      reports,
      subscribed,
      Monitored(..monitored_defaults(), store: memory_store(calls, [], False)),
    )
  let tree = start_tree_with_relays(spec, [test_relay_url], [])
  assert process.receive(subscribed, 2000) == Ok(Subscribed(test_relay_url, []))

  let before_first_add = time.now_seconds()
  assert app.add_account(spec, account_for(signer_key), "main") == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, first_filter)])) =
    process.receive(subscribed, 2000)
  assert first_filter.authors == Some([signer])
  let assert Some(since_after_first_add) = first_filter.since
  assert since_after_first_add >= before_first_add
  assert since_after_first_add <= time.now_seconds()

  assert app.add_account(spec, account_for(other_signer_key), "second")
    == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, second_filter)])) =
    process.receive(subscribed, 2000)
  assert second_filter.authors
    == Some(list.sort([signer, other_signer], string.compare))
  let assert Some(since_after_second_add) = second_filter.since
  assert since_after_second_add >= since_after_first_add

  assert bunker.remove_account(spec.bunker.name, other_signer) == Ok(Nil)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, third_filter)])) =
    process.receive(subscribed, 2000)
  assert third_filter.authors == Some([signer])
  assert third_filter.since == Some(since_after_second_add)

  assert bunker.remove_account(spec.bunker.name, signer) == Ok(Nil)
  assert process.receive(subscribed, 2000)
    == Ok(Subscribed(test_relay_url, [message.Close("nostr-no-su")]))
  stop_tree(tree)
}

/// 本番の配線（`monitored_accounts_spec`）の監視は、登録アカウントのイベントだけを
/// プラグインへ渡し、他人のイベントは渡さない。
pub fn the_monitor_delivers_only_events_of_registered_accounts_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let seen = process.new_subject()
  let plugins = [
    forwarding_spec(process.new_name("test_plugin_forwarding"), seen),
  ]
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(
        reports,
        subscribed,
        Monitored(..monitored_defaults(), plugins: plugins),
      ),
      [test_relay_url],
      [],
    )
  let assert Opened(_relay_url, _connection, _socket, deliver) =
    await_connection(reports)
  // REQ が来るまで待つ。署名者の読み込みと、その写しの配置が済んでから流す。
  let #(_skipped, requested) =
    receive_until(subscribed, requests_on(_, test_relay_url), 2000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, _filter)])) = requested

  deliver(note("other"))
  let own = signed_event.by(signer_key, 1, "own")
  deliver(own)
  assert process.receive(seen, 2000) == Ok(own)
  assert process.receive(seen, 200) == Error(Nil)
  stop_tree(tree)
}

/// `bunker.is_signer` は登録アカウントの増減に従い、追加前は偽、`app.add_account` の後は
/// 真、`bunker.remove_account` の後は偽を返す。
pub fn the_registered_authors_follow_account_changes_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let calls = process.new_subject()
  let signer = account.pubkey_hex(account_for(signer_key))
  let spec =
    monitored_accounts_spec(
      reports,
      subscribed,
      Monitored(..monitored_defaults(), store: memory_store(calls, [], False)),
    )
  let bunker_name = spec.bunker.name
  let tree = start_tree_with_relays(spec, [test_relay_url], [])
  assert bunker.is_signer(bunker_name, signer) == False

  assert app.add_account(spec, account_for(signer_key), "main") == Ok(Nil)
  assert bunker.is_signer(bunker_name, signer) == True

  assert bunker.remove_account(bunker_name, signer) == Ok(Nil)
  assert bunker.is_signer(bunker_name, signer) == False
  stop_tree(tree)
}

/// 再接続したリレーは、切断前にそのリレーで受け取った最新イベントの `created_at`
/// から購読し直す。イベントを受け取っていないリレーは保存済みの再開点（無ければ
/// `None`）から購読する。
pub fn a_reconnected_monitor_relay_resumes_from_its_latest_event_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let first = "ws://first.test"
  let second = "ws://second.test"
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(reports, subscribed, monitored_defaults()),
      [first, second],
      [],
    )
  let assert Opened(first_url, _connection_1, socket_1, deliver_1) =
    await_connection(reports)
  let assert Opened(_second_url, _connection_2, socket_2, deliver_2) =
    await_connection(reports)
  let #(first_socket, second_socket, deliver_first) = case first_url == first {
    True -> #(socket_1, socket_2, deliver_1)
    False -> #(socket_2, socket_1, deliver_2)
  }
  // 接続直後の評価と起動時の読み込みによる張り直しの報告を
  // 読み捨ててから、切断後の張り直しだけを見る。
  drain_until_quiet(subscribed, 300)

  let received = signed_event.by(signer_key, 1, "received")
  deliver_first(received)

  process.kill(first_socket)
  let #(_skipped, first_requested) =
    receive_until(subscribed, requests_on(_, first), 2000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, first_after_kill)])) =
    first_requested
  assert first_after_kill.since == Some(received.created_at)

  process.kill(second_socket)
  let #(_skipped, second_requested) =
    receive_until(subscribed, requests_on(_, second), 2000)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, second_after_kill)])) =
    second_requested
  assert second_after_kill.since == None
  stop_tree(tree)
}

/// 再開点を読めない間は、監視の購読を張らずに再試行を続ける（開いている購読を
/// 閉じない）。
pub fn an_unreadable_resume_point_keeps_the_monitor_relay_unsubscribed_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(
        reports,
        subscribed,
        Monitored(
          ..monitored_defaults(),
          load_resume: fixed_resume_point(Error("unavailable")),
        ),
      ),
      [test_relay_url],
      [],
    )
  let assert Ok(first) = process.receive(subscribed, 2000)
  assert first == Retrying(test_relay_url)
  assert_never_requests(subscribed, time.monotonic_ms() + 500)
  stop_tree(tree)
}

/// 取り直しの要求の問い合わせに失敗すると、購読の定義全体を得られなかった
/// ことになり、監視の購読も張らずに再試行を続ける（開いている購読を閉じない）。
pub fn catchups_that_fail_keep_the_definition_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(
        reports,
        subscribed,
        Monitored(..monitored_defaults(), catchups: fn(_plugins) {
          fn() { Error(Nil) }
        }),
      ),
      [test_relay_url],
      [],
    )
  let assert Ok(first) = process.receive(subscribed, 2000)
  assert first == Retrying(test_relay_url)
  assert_never_requests(subscribed, time.monotonic_ms() + 500)
  stop_tree(tree)
}

/// `deadline`（`time.monotonic_ms` の単位）まで、`subscribed` に届く報告が
/// `Retrying` か空の `Subscribed` だけであることを検査する。
fn assert_never_requests(
  subscribed: Subject(SubscriptionReport),
  deadline: Int,
) -> Nil {
  case process.receive(subscribed, int.max(deadline - time.monotonic_ms(), 0)) {
    Error(Nil) -> Nil
    Ok(report) -> {
      assert report == Retrying(test_relay_url)
        || report == Subscribed(test_relay_url, [])
      assert_never_requests(subscribed, deadline)
    }
  }
}

/// 報告が、指定したリレーの接続へのプラグインの取り直しの REQ を含むか。
fn requests_a_catchup(report: SubscriptionReport, relay_url: String) -> Bool {
  case report {
    Subscribed(url, messages) ->
      url == relay_url && catchup_filters(messages) != []
    _ -> False
  }
}

/// 照合のメッセージから、プラグインの取り直しの REQ のフィルターだけを取り出す。
fn catchup_filters(
  messages: List(message.ClientMessage),
) -> List(filter.Filter) {
  list.filter_map(messages, fn(msg) {
    case msg {
      message.Req("nostr-no-su-catchup-" <> _plugin, query) -> Ok(query)
      _ -> Error(Nil)
    }
  })
}

/// 起動したランナーは取り直しを要求し、保存済みの再開点があれば監視の接続から
/// `nostr-no-su-catchup-<プラグイン名>` の REQ が届く。フィルターは現在の署名者を
/// `authors` に持ち、保存済みの再開点から要求を立てた時刻までの閉じた範囲を持つ。
/// ランナーを落として復帰させると、新しい `until` で取り直しの REQ が再び届く。
pub fn a_catchup_subscription_follows_the_runner_resume_point_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let runner = process.new_name("test_plugin_forwarding")
  let signer = account.pubkey_hex(account_for(signer_key))
  let before_start = time.now_seconds()
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(
        reports,
        subscribed,
        Monitored(
          ..monitored_defaults(),
          plugins: [forwarding_spec(runner, process.new_subject())],
          load_plugin_resume: fixed_resume_point(Ok(Some(1234))),
        ),
      ),
      [test_relay_url],
      [],
    )
  let #(_skipped, first) =
    receive_until(subscribed, requests_a_catchup(_, test_relay_url), 2000)
  let after_start = time.now_seconds()
  let assert Ok(Subscribed(_relay_url, first_messages)) = first
  let assert [first_catchup] = catchup_filters(first_messages)
  assert first_catchup.authors == Some([signer])
  assert first_catchup.since == Some(1234)
  let assert Some(first_until) = first_catchup.until
  assert first_until >= before_start && first_until <= after_start

  // 起動時の読み込みによる張り直しの報告を読み捨て、`until`（秒）が最初の
  // 要求より進むまで待ってから落とす。同じ秒に落とすと復帰後の要求が
  // 開いている取り直しと同じ範囲になり、REQ が出ない。
  drain_until_quiet(subscribed, 300)
  process.sleep(1000)
  let assert Ok(runner_before) = process.named(runner)
  let before_restart = time.now_seconds()
  process.kill(runner_before)
  assert await_restart(runner, runner_before, 2000)
  let #(_skipped, second) =
    receive_until(subscribed, requests_a_catchup(_, test_relay_url), 2000)
  let after_restart = time.now_seconds()
  let assert Ok(Subscribed(_relay_url, second_messages)) = second
  let assert [second_catchup] = catchup_filters(second_messages)
  assert second_catchup.since == Some(1234)
  let assert Some(second_until) = second_catchup.until
  assert second_until >= before_restart && second_until <= after_restart
  stop_tree(tree)
}

/// 取り直しの購読の `until` は、その接続の監視の購読の `since` に切り詰められる。
/// 監視の再開点が 1500、プラグインの保存済みの再開点が 1234 なら、取り直しの
/// REQ は `since` が 1234、`until` が 1500 の範囲を持つ。
pub fn a_catchup_subscription_ends_at_the_monitor_resume_point_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(
        reports,
        subscribed,
        Monitored(
          ..monitored_defaults(),
          load_resume: fixed_resume_point(Ok(Some(1500))),
          plugins: [
            forwarding_spec(
              process.new_name("test_plugin_forwarding"),
              process.new_subject(),
            ),
          ],
          load_plugin_resume: fixed_resume_point(Ok(Some(1234))),
        ),
      ),
      [test_relay_url],
      [],
    )
  let #(_skipped, first) =
    receive_until(subscribed, requests_a_catchup(_, test_relay_url), 2000)
  let assert Ok(Subscribed(_relay_url, messages)) = first
  let assert [catchup] = catchup_filters(messages)
  assert catchup.since == Some(1234)
  assert catchup.until == Some(1500)
  stop_tree(tree)
}

/// 保存済みの再開点が無いプラグインは、起動しても取り直しの購読を定義しない。
/// 監視の購読は通常どおり張られる。
pub fn a_runner_without_a_saved_resume_point_requests_no_catchup_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let tree =
    start_tree_with_relays(
      monitored_accounts_spec(
        reports,
        subscribed,
        Monitored(..monitored_defaults(), plugins: [
          forwarding_spec(
            process.new_name("test_plugin_forwarding"),
            process.new_subject(),
          ),
        ]),
      ),
      [test_relay_url],
      [],
    )
  let #(_skipped, first) =
    receive_until(subscribed, requests_on(_, test_relay_url), 2000)
  let assert Ok(Subscribed(_relay_url, messages)) = first
  assert catchup_filters(messages) == []
  stop_tree(tree)
}

/// 報告が、指定したリレーの接続の照合か（送る REQ と CLOSE の有無を問わない）。
fn reports_on(report: SubscriptionReport, relay_url: String) -> Bool {
  case report {
    Subscribed(url, _) -> url == relay_url
    Retrying(url) -> url == relay_url
  }
}

/// ランナーの復帰による張り直しは監視の接続だけに届き、バンカーの接続は購読を
/// 照合し直さない。
pub fn a_restarted_runner_resubscribes_only_the_monitor_relays_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let runner = process.new_name("test_plugin_forwarding")
  let bunker_relay_url = "ws://bunker.test"
  let spec =
    monitored_accounts_spec(
      reports,
      subscribed,
      Monitored(..monitored_defaults(), plugins: [
        forwarding_spec(runner, process.new_subject()),
      ]),
    )
  let tree = start_tree_with_relays(spec, [test_relay_url], [bunker_relay_url])
  let #(_started_skipped, bunker_started) =
    receive_until(subscribed, reports_on(_, bunker_relay_url), 2000)
  let assert Ok(_) = bunker_started
  drain_until_quiet(subscribed, 300)

  let assert Ok(runner_before) = process.named(runner)
  process.kill(runner_before)
  assert await_restart(runner, runner_before, 2000)
  let #(skipped, monitor_synced) =
    receive_until(subscribed, reports_on(_, test_relay_url), 2000)
  let assert Ok(_) = monitor_synced
  assert !list.any(skipped, reports_on(_, bunker_relay_url))
  let #(_later, bunker_synced) =
    receive_until(subscribed, reports_on(_, bunker_relay_url), 500)
  assert bunker_synced == Error(Nil)
  stop_tree(tree)
}

/// 取り直しの振り分けを確かめるために、ツリーは張らずランナーだけを起こす。
/// `resubscribe` の呼び出しは `resubscribed` へ報告する（起動時に 1 度呼ばれる）。
fn start_bare_runner(
  runner_name: Name(plugin_runner.Msg),
  plugin_name: String,
  seen: Subject(Event),
  resubscribed: Subject(Nil),
) -> Nil {
  let assert Ok(_started) =
    plugin_runner.start(
      runner_name,
      plugin.Plugin(..idle_plugin(plugin_name), handle: process.send(seen, _)),
      fn() { process.send(resubscribed, Nil) },
      plugin_runner.default_limits,
    )
  Nil
}

/// 送られたイベントを `seen` へ転送するディスパッチャーを起動し、その名前を返す。
/// 監視のハンドラーを直接試すテストが使う。
fn forwarding_dedup(seen: Subject(Event)) -> Name(dedup.Msg) {
  let name = process.new_name("test_dedup")
  let assert Ok(_) =
    dedup.start(
      name,
      Nil,
      fn(_targets, incoming) {
        process.send(seen, incoming)
        Nil
      },
      8,
    )
  name
}

/// 取り直しの購読 id のイベントは、そのプラグインのランナーにだけ届く。他の
/// プラグインにもディスパッチャーにも渡らず、監視の購読 id のイベントだけが
/// ディスパッチャーへ渡る。
pub fn a_catchup_event_reaches_only_the_target_plugin_test() {
  let seen_a = process.new_subject()
  let seen_b = process.new_subject()
  let dedup_seen = process.new_subject()
  let runner_a = process.new_name("test_plugin_a")
  let runner_b = process.new_name("test_plugin_b")
  start_bare_runner(runner_a, "plugin_a", seen_a, process.new_subject())
  start_bare_runner(runner_b, "plugin_b", seen_b, process.new_subject())
  let dedup_name = forwarding_dedup(dedup_seen)
  let handle =
    app.monitor_handler(
      dedup_name,
      event.is_ephemeral,
      fn(_pubkey) { True },
      dict.from_list([#("plugin_a", runner_a), #("plugin_b", runner_b)]),
    )

  let catchup = note("catch-up")
  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      "nostr-no-su-catchup-plugin_a",
      signed_event.verified(catchup),
    ),
  )
  assert process.receive(seen_a, 2000) == Ok(catchup)
  assert process.receive(seen_b, 200) == Error(Nil)
  assert process.receive(dedup_seen, 200) == Error(Nil)

  let normal = note("normal")
  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      subscriptions.monitor_subscription_id,
      signed_event.verified(normal),
    ),
  )
  assert process.receive(dedup_seen, 2000) == Ok(normal)
}

/// 同じ取り直しの購読 id で同じイベントが 2 度届いても、ランナーの `seen`
/// ウィンドウが弾くのでプラグインは 1 回しか呼ばれない。複数のリレーが同じ
/// 範囲を返すときの重複排除である。
pub fn a_catchup_event_is_delivered_once_per_id_test() {
  let seen = process.new_subject()
  let runner = process.new_name("test_plugin_a")
  start_bare_runner(runner, "plugin_a", seen, process.new_subject())
  let handle =
    app.monitor_handler(
      process.new_name("test_dedup"),
      event.is_ephemeral,
      fn(_pubkey) { True },
      dict.from_list([#("plugin_a", runner)]),
    )
  let sent = note("catch-up")
  let received =
    relay_client.ReceivedEvent(
      "nostr-no-su-catchup-plugin_a",
      signed_event.verified(sent),
    )

  handle(test_relay_url, received)
  handle(test_relay_url, received)
  assert process.receive(seen, 2000) == Ok(sent)
  assert process.receive(seen, 200) == Error(Nil)
}

/// 取り直しの購読の EOSE はそのランナーへ取り直しの完了として伝わり、要求を
/// 落として購読の張り直しを呼ぶ。
pub fn a_catchup_eose_drops_the_request_and_resubscribes_test() {
  let resubscribed = process.new_subject()
  let runner = process.new_name("test_plugin_a")
  start_bare_runner(runner, "plugin_a", process.new_subject(), resubscribed)
  // 起動時の張り直しの呼び出しを読み捨てる。
  assert process.receive(resubscribed, 1000) == Ok(Nil)
  let assert Some(Some(_catchup)) = plugin_runner.catchup(runner)
  let handle =
    app.monitor_handler(
      process.new_name("test_dedup"),
      event.is_ephemeral,
      fn(_pubkey) { True },
      dict.from_list([#("plugin_a", runner)]),
    )

  handle(
    test_relay_url,
    relay_client.ReceivedEose("nostr-no-su-catchup-plugin_a"),
  )
  assert process.receive(resubscribed, 1000) == Ok(Nil)
  assert plugin_runner.catchup(runner) == Some(None)
}

/// 監視ハンドラーは、監視の購読 id で届いた他人のイベントをディスパッチャーの配送に回さず、
/// その再開点も動かさない。登録アカウントのイベントは配送に回す。
pub fn a_monitor_event_from_an_unregistered_author_is_dropped_test() {
  let dedup_seen = process.new_subject()
  let dedup_name = forwarding_dedup(dedup_seen)
  let signer = account.pubkey_hex(account_for(signer_key))
  let handle =
    app.monitor_handler(
      dedup_name,
      event.is_ephemeral,
      fn(pubkey) { pubkey == signer },
      dict.from_list([]),
    )

  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      subscriptions.monitor_subscription_id,
      signed_event.verified(note("other")),
    ),
  )
  // 照合で落としたイベントは、ディスパッチャーの再開点を動かさない。
  assert dedup.since(dedup_name, test_relay_url) == Ok(None)

  let own = signed_event.by(signer_key, 1, "own")
  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      subscriptions.monitor_subscription_id,
      signed_event.verified(own),
    ),
  )
  assert process.receive(dedup_seen, 2000) == Ok(own)
  assert process.receive(dedup_seen, 200) == Error(Nil)
  assert dedup.since(dedup_name, test_relay_url) == Ok(Some(own.created_at))
}

/// 監視ハンドラーの作者の照合は kind 1 以外のイベントにも掛かる。他人の kind 0 と、
/// ephemeral の kind 24133 は登録アカウントのものでもディスパッチャーの配送に回らず、
/// 登録アカウントの kind 0 だけが回る。
pub fn the_monitor_checks_the_author_whatever_the_kind_test() {
  let dedup_seen = process.new_subject()
  let signer = account.pubkey_hex(account_for(signer_key))
  let handle =
    app.monitor_handler(
      forwarding_dedup(dedup_seen),
      event.is_ephemeral,
      fn(pubkey) { pubkey == signer },
      dict.from_list([]),
    )

  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      subscriptions.monitor_subscription_id,
      signed_event.verified(signed_event.new(0, "other")),
    ),
  )
  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      subscriptions.monitor_subscription_id,
      signed_event.verified(signed_event.by(
        signer_key,
        event.nip46_kind,
        "nip46",
      )),
    ),
  )
  let own = signed_event.by(signer_key, 0, "own")
  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      subscriptions.monitor_subscription_id,
      signed_event.verified(own),
    ),
  )
  assert process.receive(dedup_seen, 2000) == Ok(own)
  assert process.receive(dedup_seen, 200) == Error(Nil)
}

/// 監視ハンドラーは、取り直しの購読 id で届いた他人のイベントをそのプラグインのランナーへ
/// 渡さず、登録アカウントのイベントだけを渡す。どちらもディスパッチャーの配送には回さない。
pub fn a_catchup_event_from_an_unregistered_author_is_dropped_test() {
  let seen = process.new_subject()
  let dedup_seen = process.new_subject()
  let runner = process.new_name("test_plugin_a")
  start_bare_runner(runner, "plugin_a", seen, process.new_subject())
  let signer = account.pubkey_hex(account_for(signer_key))
  let handle =
    app.monitor_handler(
      forwarding_dedup(dedup_seen),
      event.is_ephemeral,
      fn(pubkey) { pubkey == signer },
      dict.from_list([#("plugin_a", runner)]),
    )

  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      "nostr-no-su-catchup-plugin_a",
      signed_event.verified(note("other")),
    ),
  )
  let own = signed_event.by(signer_key, 1, "own")
  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      "nostr-no-su-catchup-plugin_a",
      signed_event.verified(own),
    ),
  )
  assert process.receive(seen, 2000) == Ok(own)
  assert process.receive(seen, 200) == Error(Nil)
  assert process.receive(dedup_seen, 200) == Error(Nil)
}

/// 監視ハンドラーは、監視でも取り直しでもない購読 id（`bunker`）で届いたイベントを
/// ディスパッチャーの配送に回さず、監視の購読 id で届いたイベントは回す。
pub fn an_event_on_an_unknown_subscription_is_dropped_test() {
  let dedup_seen = process.new_subject()
  let signer = account.pubkey_hex(account_for(signer_key))
  let handle =
    app.monitor_handler(
      forwarding_dedup(dedup_seen),
      event.is_ephemeral,
      fn(pubkey) { pubkey == signer },
      dict.from_list([]),
    )

  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      "bunker",
      signed_event.verified(signed_event.by(signer_key, 1, "unknown")),
    ),
  )
  let normal = signed_event.by(signer_key, 1, "normal")
  handle(
    test_relay_url,
    relay_client.ReceivedEvent(
      subscriptions.monitor_subscription_id,
      signed_event.verified(normal),
    ),
  )
  assert process.receive(dedup_seen, 2000) == Ok(normal)
  assert process.receive(dedup_seen, 200) == Error(Nil)
}

/// 実行時に足した監視のリレーは、アカウントの変更に合わせて購読が張り直され、
/// アカウントの追加の再開点の対象になる。閉じたリレーは対象から外れる。
pub fn a_runtime_monitor_relay_follows_account_changes_and_resume_test() {
  let reports = process.new_subject()
  let subscribed = process.new_subject()
  let signer = account.pubkey_hex(account_for(signer_key))
  let other_signer = account.pubkey_hex(account_for(other_signer_key))
  let spec = monitored_accounts_spec(reports, subscribed, monitored_defaults())
  let tree = start_tree(spec)
  let r = "ws://runtime-monitor.test"
  let assert Ok(Nil) = app.open_relay(spec, r, relay_list.MonitorOnly)
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, opened_filter)])) =
    receive_until(subscribed, requests_on(_, r), 2000).1
  assert opened_filter.authors == Some([signer])

  assert app.add_account(spec, account_for(other_signer_key), "second")
    == Ok(Nil)
  // 張り直しの評価が変更前の一覧で先に行われると、開いている購読と同じ定義なので
  // 空の報告が届きうる。両方揃った内容が届くまで読み飛ばす。
  let both_signers = Some(list.sort([signer, other_signer], string.compare))
  let assert Ok(Subscribed(_relay_url, [message.Req(_id, added_filter)])) =
    receive_until(
      subscribed,
      fn(report) {
        case report {
          Subscribed(url, [message.Req(_, filter)]) ->
            url == r && filter.authors == both_signers
          _ -> False
        }
      },
      2000,
    ).1
  assert added_filter.authors == both_signers
  let assert Ok(Some(_)) = dedup.since(spec.monitor.name, r)

  let assert Ok(Nil) = app.close_relay(spec, r)
  assert bunker.remove_account(spec.bunker.name, other_signer) == Ok(Nil)
  // r は閉じられているので、以降のアカウントの変更で REQ は届かない。
  assert process.receive(subscribed, 300) == Error(Nil)

  let r2 = "ws://runtime-monitor-2.test"
  let assert Ok(Nil) = app.open_relay(spec, r2, relay_list.MonitorOnly)
  let assert Ok(Nil) = app.close_relay(spec, r2)
  assert app.add_account(spec, account_for(third_signer_key), "third")
    == Ok(Nil)
  // r2 は、監視の一覧に居た間に一度もアカウントの追加を知らされていない。
  assert dedup.since(spec.monitor.name, r2) == Ok(None)
  stop_tree(tree)
}
