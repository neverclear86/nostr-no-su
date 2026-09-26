//// `relay_list` の一覧を変える純粋関数と用途の組の関数（`roles_from`、`has_role`）、
//// セッションのリレーの接続を選ぶ `session_connections` のテスト。アクターを介さないので
//// `process.new_name` で作った名前をそのまま比べられる。

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/relay_list

/// `roles_from` は使う用途の組を `Roles` にし、どちらも使わない組は `Error(Nil)` を返す。
pub fn roles_from_refuses_no_role_test() {
  assert relay_list.roles_from(monitor: False, bunker: False) == Error(Nil)
  assert relay_list.roles_from(monitor: True, bunker: False)
    == Ok(relay_list.MonitorOnly)
  assert relay_list.roles_from(monitor: False, bunker: True)
    == Ok(relay_list.BunkerOnly)
  assert relay_list.roles_from(monitor: True, bunker: True)
    == Ok(relay_list.Both)
}

/// `has_role` は `Roles` の各変種が含む用途にだけ `True` を返す。`SessionOnly` は
/// `Roles` の用途ではないので、どの変種にも含まれない。
pub fn has_role_follows_each_variant_test() {
  let cases = [
    #(relay_list.MonitorOnly, True, False, False),
    #(relay_list.BunkerOnly, False, True, False),
    #(relay_list.Both, True, True, False),
  ]
  use #(roles, monitor, bunker, session) <- list.each(cases)
  assert [
      relay_list.has_role(roles, relay_list.Monitor),
      relay_list.has_role(roles, relay_list.Bunker),
      relay_list.has_role(roles, relay_list.SessionOnly),
    ]
    == [monitor, bunker, session]
}

/// 起動時の一覧は監視の一覧を先に並べ、その後にバンカーの一覧のうち未出の
/// URL を並べる。両方にある URL は 1 項目にまとまり、バンカーの名前が足される。
pub fn initial_lists_monitor_relays_first_and_merges_roles_test() {
  let monitor_a =
    relay_list.Connection(name: process.new_name("m_a"), url: "wss://a")
  let monitor_b =
    relay_list.Connection(name: process.new_name("m_b"), url: "wss://b")
  let bunker_b =
    relay_list.Connection(name: process.new_name("b_b"), url: "wss://b")
  let bunker_c =
    relay_list.Connection(name: process.new_name("b_c"), url: "wss://c")
  let entries = relay_list.initial([monitor_a, monitor_b], [bunker_b, bunker_c])
  assert entries
    == [
      relay_list.Entry(
        url: "wss://a",
        monitor: Some(monitor_a.name),
        bunker: None,
      ),
      relay_list.Entry(
        url: "wss://b",
        monitor: Some(monitor_b.name),
        bunker: Some(bunker_b.name),
      ),
      relay_list.Entry(
        url: "wss://c",
        monitor: None,
        bunker: Some(bunker_c.name),
      ),
    ]
}

/// `open` は URL の形と重複の 2 つを検査し、通れば末尾に足して用途ごとに
/// 新しい名前を作る。
pub fn open_refuses_invalid_and_duplicate_relays_test() {
  let existing =
    relay_list.initial(
      [
        relay_list.Connection(
          name: process.new_name("m"),
          url: "wss://existing",
        ),
      ],
      [],
    )
  assert relay_list.open(existing, "relay.damus.io", relay_list.MonitorOnly)
    == Error(relay_list.InvalidUrl)
  assert relay_list.open(existing, "wss://existing", relay_list.MonitorOnly)
    == Error(relay_list.AlreadyListed)

  let assert Ok(opened) =
    relay_list.open(existing, "wss://new", relay_list.Both)
  let assert Ok(added) = list.last(opened)
  assert added.url == "wss://new"
  assert option.is_some(added.monitor)
  assert option.is_some(added.bunker)
  assert added.monitor != added.bunker
}

/// `open` は `ws://`・`wss://` で始まらない URL を `InvalidUrl` で拒む。
pub fn open_rejects_a_non_websocket_scheme_test() {
  assert relay_list.open([], "https://relay.example", relay_list.MonitorOnly)
    == Error(relay_list.InvalidUrl)
}

/// `close` は一覧に無い URL を `NotListed` で拒む。
pub fn close_refuses_an_unlisted_relay_test() {
  assert relay_list.close([], "wss://missing") == Error(relay_list.NotListed)
}

/// `change_roles` は項目の位置を保ち、残る用途の名前を保ち、外した用途は
/// `None` にする。URL が無ければ `NotListed`。
pub fn change_roles_keeps_the_position_and_kept_names_test() {
  let a = relay_list.Connection(name: process.new_name("a"), url: "wss://a")
  let b = relay_list.Connection(name: process.new_name("b"), url: "wss://b")
  let entries = relay_list.initial([a, b], [])

  assert relay_list.change_roles(
      entries,
      "wss://missing",
      relay_list.MonitorOnly,
    )
    == Error(relay_list.NotListed)

  let assert Ok(changed) =
    relay_list.change_roles(entries, "wss://a", relay_list.BunkerOnly)
  let assert [first, second] = changed
  assert first.url == "wss://a"
  assert first.monitor == None
  assert option.is_some(first.bunker)
  // 動かさなかった項目は名前も位置もそのまま。
  assert second
    == relay_list.Entry(url: "wss://b", monitor: Some(b.name), bunker: None)

  let assert Ok(kept) =
    relay_list.change_roles(entries, "wss://b", relay_list.Both)
  let assert [_, kept_b] = kept
  // 残した用途（監視）は名前を保つ。
  assert kept_b.monitor == Some(b.name)
  assert option.is_some(kept_b.bunker)
}

/// `open_all` は空の一覧に登録された順で足す。用途ごとに新しい名前を作る。
pub fn open_all_keeps_the_registered_order_test() {
  let registered = [
    relay_list.Registered(url: "wss://a", roles: relay_list.MonitorOnly),
    relay_list.Registered(url: "wss://b", roles: relay_list.BunkerOnly),
    relay_list.Registered(url: "wss://c", roles: relay_list.Both),
  ]
  let #(entries, rejections) = relay_list.open_all([], registered)
  assert rejections == []
  assert list.map(entries, fn(entry) { entry.url })
    == ["wss://a", "wss://b", "wss://c"]
  assert relay_list.urls(entries, relay_list.Monitor) == ["wss://a", "wss://c"]
  assert relay_list.urls(entries, relay_list.Bunker) == ["wss://b", "wss://c"]
}

/// `open_all` は一覧にある URL を黙って飛ばし、位置も一覧も変えない。不正な URL は、
/// URL つきの拒否として返り一覧に入らない。
pub fn open_all_skips_listed_and_invalid_relays_test() {
  let existing =
    relay_list.initial(
      [relay_list.Connection(name: process.new_name("m"), url: "wss://a")],
      [],
    )
  let registered = [
    relay_list.Registered(url: "wss://a", roles: relay_list.MonitorOnly),
    relay_list.Registered(url: "relay.damus.io", roles: relay_list.MonitorOnly),
    relay_list.Registered(url: "wss://", roles: relay_list.MonitorOnly),
  ]
  let #(entries, rejections) = relay_list.open_all(existing, registered)
  assert entries == existing
  assert rejections
    == [
      #("relay.damus.io", relay_list.InvalidUrl),
      #("wss://", relay_list.InvalidUrl),
    ]
}

/// `connections` と `urls` は、その用途で使う項目だけを一覧の順に並べる。
pub fn connections_follow_the_entry_order_test() {
  let a = relay_list.Connection(name: process.new_name("m_a"), url: "wss://a")
  let b_monitor =
    relay_list.Connection(name: process.new_name("m_b"), url: "wss://b")
  let b_bunker =
    relay_list.Connection(name: process.new_name("bk_b"), url: "wss://b")
  let entries = relay_list.initial([a, b_monitor], [b_bunker])

  assert relay_list.connections(entries, relay_list.Monitor)
    == [
      a,
      b_monitor,
    ]
  assert relay_list.connections(entries, relay_list.Bunker) == [b_bunker]
  assert relay_list.urls(entries, relay_list.Monitor) == ["wss://a", "wss://b"]
}

/// セッションのリレーの接続は、バンカーの用途の URL を除き、監視だけの URL は
/// 含め、重複した URL は 1 本にする。
pub fn session_connections_skip_urls_of_the_base_set_test() {
  let entries = [
    relay_list.Entry(
      url: "wss://monitor",
      monitor: Some(process.new_name("m")),
      bunker: None,
    ),
    relay_list.Entry(
      url: "wss://bunker",
      monitor: None,
      bunker: Some(process.new_name("b")),
    ),
  ]
  let connections =
    relay_list.session_connections(
      entries,
      ["wss://bunker", "wss://monitor", "wss://x", "wss://monitor"],
      [],
    )
  assert list.map(connections, fn(connection) { connection.url })
    == ["wss://monitor", "wss://x"]
}

/// 残る URL の接続は名前を保ち、新しい URL の接続は別の名前を持つ。
pub fn session_connections_keep_the_names_of_kept_urls_test() {
  let kept =
    relay_list.Connection(name: process.new_name("s_x"), url: "wss://x")
  let assert [first, second] =
    relay_list.session_connections([], ["wss://x", "wss://y"], [kept])
  assert first == kept
  assert second.url == "wss://y"
  assert second.name != kept.name
}
