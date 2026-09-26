//// `delivery.track` / `delivery.acknowledge` のテストは、発行した応答への OK をどう
//// 追跡し、全リレーに拒否されたときの行をどう組み立てるかを確かめる。
//// `delivery.response_relays` / `delivery.session_relay_signers` のテストは、応答の
//// 発行先と、リレーの URL ごとのセッションの署名者を確かめる。
//// `delivery.authentication_events` のテストは、AUTH に返すイベントがアカウントごとに
//// その鍵で署名されることを確かめる。
//// `delivery.pause_on_rate_limit` / `delivery.recipients` のテストは、`rate-limited:` を
//// 返したリレーへのセッションの外の応答をいつ止めて再開し、出さなかった件数をどう
//// 報告するかを確かめる。

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/bunker/account
import nostr_no_su/bunker/delivery
import nostr_no_su/bunker/rate_limit
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
fn tracked(id: String, now: Int) -> delivery.Deliveries {
  delivery.track(
    delivery.new_deliveries(),
    response(id),
    [relay_a, relay_b],
    now,
  )
}

/// 全リレーが拒否すると、拒否を届いた順にまとめた 1 行が返り、項目は消える
/// （受け入れ条件）。
pub fn acknowledge_reports_a_response_rejected_by_every_relay_on_one_line_test() {
  let deliveries = tracked("e1", 0)
  let #(deliveries, first) =
    delivery.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert first == None
  let #(deliveries, second) =
    delivery.acknowledge(
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
    delivery.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert third == None
}

/// 1 つでも受理すれば、残りのリレーが拒否しても報告しない。
pub fn acknowledge_does_not_report_a_response_accepted_by_one_relay_test() {
  let deliveries = tracked("e1", 0)
  let #(deliveries, accepted) =
    delivery.acknowledge(deliveries, relay_a, Acknowledgement("e1", True, ""))
  assert accepted == None
  let #(_deliveries, rejected) =
    delivery.acknowledge(
      deliveries,
      relay_b,
      Acknowledgement("e1", False, "invalid: bad"),
    )
  assert rejected == None
}

/// 同じリレーからの 2 度目の拒否は数えず、報告に必要な残り 1 本のまま止まる。
pub fn acknowledge_does_not_count_a_repeated_rejection_from_the_same_relay_test() {
  let deliveries = tracked("e1", 0)
  let #(deliveries, first) =
    delivery.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert first == None
  let #(deliveries, repeated) =
    delivery.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert repeated == None
  let #(_deliveries, second) =
    delivery.acknowledge(
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
pub fn track_drops_deliveries_after_the_acknowledgement_timeout_test() {
  let deliveries = tracked("e1", 0)
  let deliveries =
    delivery.track(deliveries, response("e2"), [relay_a, relay_b], 60)
  let #(deliveries, first) =
    delivery.acknowledge(
      deliveries,
      relay_a,
      Acknowledgement("e1", False, "rate-limited: slow down"),
    )
  assert first == None
  let #(_deliveries, second) =
    delivery.acknowledge(
      deliveries,
      relay_b,
      Acknowledgement("e1", False, "invalid: bad"),
    )
  assert second == None
}

/// AUTH に返すイベントは、アカウントごとに 1 件、その鍵で署名した kind 22242 で、
/// リレー URL と challenge をタグに持つ。
pub fn authentication_events_sign_one_event_per_account_test() {
  let first =
    account_for(
      "0000000000000000000000000000000000000000000000000000000000000042",
    )
  let second =
    account_for(
      "0000000000000000000000000000000000000000000000000000000000000077",
    )
  let assert Ok(events) =
    delivery.authentication_events(
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

/// セッションのリレー（基本のリレーに無い URL）の 1 本目。
const relay_x = "wss://x.example"

/// セッションのリレーの 2 本目。
const relay_y = "wss://y.example"

/// 基本のリレーはどの応答にも選び、セッションのリレーは応答先のセッションが持つ
/// ときだけ選ぶ。
pub fn response_relays_pick_base_relays_and_the_session_relays_test() {
  let publishers = [
    #(relay_a, delivery.BaseRelay),
    #(relay_x, delivery.SessionRelay),
    #(relay_y, delivery.SessionRelay),
  ]
  assert delivery.response_relays(publishers, [relay_x]) == [relay_a, relay_x]
  assert delivery.response_relays(publishers, []) == [relay_a]
}

/// 共有の URL は署名者を昇順・重複なしで持ち、リレーの無いセッションは何も
/// 足さない。
pub fn session_relay_signers_list_the_signers_of_each_relay_test() {
  let map =
    delivery.session_relay_signers([
      #("s2", [relay_x, relay_y]),
      #("s1", [relay_x]),
      #("s2", [relay_x]),
      #("s3", []),
    ])
  assert map == dict.from_list([#(relay_x, ["s1", "s2"]), #(relay_y, ["s2"])])
}

/// `rate-limited:` の拒否を反映した時刻から `rate_limited_pause_seconds` 秒の間、
/// relay_a を止めた一覧。
fn pausing_relay_a(at: Int) -> delivery.Pauses {
  delivery.pause_on_rate_limit(
    delivery.new_pauses(),
    relay_a,
    Acknowledgement("e1", False, "rate-limited: slow down"),
    at,
  )
}

/// `rate-limited:` の拒否を返したリレーには、セッションの外の応答を出さない
/// （受け入れ条件）。飛ばした 1 件はすぐ報告する。
pub fn recipients_skip_a_rate_limited_relay_outside_a_session_test() {
  let #(_pauses, sent, lines) =
    delivery.recipients(pausing_relay_a(1000), [relay_a, relay_b], True, 1001)
  assert sent == [relay_b]
  assert lines == [delivery.pause_report(relay_a, 1)]
}

/// セッションのあるクライアントへの応答は、止めたリレーにも届く（受け入れ条件）。
pub fn recipients_keep_a_rate_limited_relay_inside_a_session_test() {
  let #(_pauses, sent, lines) =
    delivery.recipients(pausing_relay_a(1000), [relay_a, relay_b], False, 1001)
  assert sent == [relay_a, relay_b]
  assert lines == []
}

/// 止める期限が過ぎると、そのリレーへの発行が再開する（受け入れ条件）。
pub fn recipients_resume_a_relay_after_the_pause_test() {
  let pauses = pausing_relay_a(1000)
  let #(pauses, sent, _lines) =
    delivery.recipients(
      pauses,
      [relay_a, relay_b],
      True,
      1000 + delivery.rate_limited_pause_seconds - 1,
    )
  assert sent == [relay_b]
  let #(_pauses, sent, _lines) =
    delivery.recipients(
      pauses,
      [relay_a, relay_b],
      True,
      1000 + delivery.rate_limited_pause_seconds,
    )
  assert sent == [relay_a, relay_b]
}

/// `rate-limited:` 以外の理由の拒否と、受理の OK はリレーを止めない。
pub fn pause_on_rate_limit_ignores_other_acknowledgements_test() {
  let pauses =
    delivery.pause_on_rate_limit(
      delivery.new_pauses(),
      relay_a,
      Acknowledgement("e1", False, "invalid: bad"),
      1000,
    )
  let pauses =
    delivery.pause_on_rate_limit(
      pauses,
      relay_a,
      Acknowledgement("e2", True, "rate-limited: slow down"),
      1000,
    )
  let #(_pauses, sent, _lines) =
    delivery.recipients(pauses, [relay_a], True, 1001)
  assert sent == [relay_a]
}

/// 出さなかった件数はリレーごとに `report_interval_seconds` に 1 回まで報告する。
/// 新しく止めたリレーの最初の 1 件はすぐ出し、期限が過ぎた後に残った件数は、
/// 次にそのリレーを止めて出さなかったときに残りと合わせて出す。
pub fn recipients_report_dropped_responses_once_per_interval_test() {
  // 最初に出さなかった 1 件はすぐ報告する
  let #(pauses, sent, lines) =
    delivery.recipients(pausing_relay_a(1000), [relay_a, relay_b], True, 1001)
  assert sent == [relay_b]
  assert lines == [delivery.pause_report(relay_a, 1)]

  // 報告の間隔の内側では件数を数えるだけで報告しない
  let #(pauses, _sent, lines) =
    delivery.recipients(pauses, [relay_a, relay_b], True, 1002)
  assert lines == []
  let #(pauses, _sent, lines) =
    delivery.recipients(pauses, [relay_a, relay_b], True, 1003)
  assert lines == []

  // 止め直してから出さなかった最初の 1 件で、残った 2 件と合わせて 3 件を出す
  let pauses =
    delivery.pause_on_rate_limit(
      pauses,
      relay_a,
      Acknowledgement("e3", False, "rate-limited: slow down"),
      1001 + rate_limit.report_interval_seconds,
    )
  let #(_pauses, _sent, lines) =
    delivery.recipients(
      pauses,
      [relay_a, relay_b],
      True,
      1001 + rate_limit.report_interval_seconds,
    )
  assert lines == [delivery.pause_report(relay_a, 3)]
}
