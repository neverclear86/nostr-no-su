import gleam/option.{None, Some}
import nostr_no_su/nostr/filter.{Filter}
import nostr_no_su/plugin_runner
import nostr_no_su/subscriptions

/// 署名者が 0 件なら購読を定義せず、継続を評価しない。署名者がいれば継続を呼び、
/// 監視のフィルターに `authors` と `since` を入れて、足す購読をそのまま後ろに並べる。
/// 継続が `Error(Nil)` なら定義を得られなかったことにする。
pub fn monitor_subscriptions_test() {
  assert subscriptions.monitor_subscriptions([], fn() {
      panic as "must not be called"
    })
    == Ok([])
  assert subscriptions.monitor_subscriptions(["pk1", "pk2"], fn() {
      Ok(#(None, []))
    })
    == Ok([
      #("nostr-no-su", Filter(..filter.new(), authors: Some(["pk1", "pk2"]))),
    ])
  let assert Ok([#(_id, with_since)]) =
    subscriptions.monitor_subscriptions(["pk1"], fn() { Ok(#(Some(1000), [])) })
  assert with_since.since == Some(1000)
  assert subscriptions.monitor_subscriptions(["pk1"], fn() {
      Ok(#(Some(1000), [#("nostr-no-su-catchup-a", filter.new())]))
    })
    == Ok([
      #(
        "nostr-no-su",
        Filter(..filter.new(), authors: Some(["pk1"]), since: Some(1000)),
      ),
      #("nostr-no-su-catchup-a", filter.new()),
    ])
  assert subscriptions.monitor_subscriptions(["pk1"], fn() { Error(Nil) })
    == Error(Nil)
}

/// 要求ごとに、プラグイン名を繋げた id で、`authors` と閉じた範囲 `since`〜`until` を持つ
/// フィルターを作る。
pub fn catchup_subscriptions_test() {
  assert subscriptions.catchup_subscriptions(["pk1"], None, [
      #("logger", 100, 200),
      #("echo", 300, 400),
    ])
    == [
      #(
        "nostr-no-su-catchup-logger",
        Filter(
          ..filter.new(),
          authors: Some(["pk1"]),
          since: Some(100),
          until: Some(200),
        ),
      ),
      #(
        "nostr-no-su-catchup-echo",
        Filter(
          ..filter.new(),
          authors: Some(["pk1"]),
          since: Some(300),
          until: Some(400),
        ),
      ),
    ]
}

/// 監視の購読の `since` が `until` より前なら、`until` をそれに切り詰める。
/// 切り詰めた範囲は監視の購読が運ぶ。
pub fn catchup_subscriptions_trims_until_to_the_monitor_since_test() {
  let assert [#(_id, query)] =
    subscriptions.catchup_subscriptions(["pk1"], Some(150), [
      #("logger", 100, 200),
    ])
  assert query.since == Some(100)
  assert query.until == Some(150)
}

/// 監視の購読の `since` が `until` 以降なら、取り直しの範囲は変えない。
pub fn catchup_subscriptions_keeps_until_before_the_monitor_since_test() {
  let assert [#(_id, query)] =
    subscriptions.catchup_subscriptions(["pk1"], Some(250), [
      #("logger", 100, 200),
    ])
  assert query.since == Some(100)
  assert query.until == Some(200)
}

/// 取り直しの範囲がすべて監視の購読に含まれるときは、その接続では取り直しを
/// 定義しない。境界は両端を含むので、`since` と監視の `since` が同じなら残る。
pub fn catchup_subscriptions_drops_a_range_the_monitor_covers_test() {
  assert subscriptions.catchup_subscriptions(["pk1"], Some(90), [
      #("logger", 100, 200),
    ])
    == []
  let assert [#(_id, query)] =
    subscriptions.catchup_subscriptions(["pk1"], Some(100), [
      #("logger", 100, 200),
    ])
  assert query.until == Some(100)
}

/// 取り直しの購読 id からはプラグイン名が戻る。監視の購読 id とそれ以外は
/// `None` になる。
pub fn catchup_plugin_test() {
  assert subscriptions.catchup_plugin("nostr-no-su-catchup-a") == Some("a")
  assert subscriptions.catchup_plugin("nostr-no-su") == None
  assert subscriptions.catchup_plugin("other") == None
}

/// 署名者がいれば `#p` に入れて購読し、いなければ購読そのものを開かない。
pub fn bunker_subscriptions_test() {
  assert subscriptions.bunker_subscriptions([], 1000) == []
  assert subscriptions.bunker_subscriptions(["pk1"], 1000)
    == [#("bunker", subscriptions.bunker_filter(["pk1"], 1000))]
}

/// バンカーのフィルターは、署名者宛の直近の kind 24133 イベントを選択する。
pub fn bunker_filter_test() {
  assert subscriptions.bunker_filter(["pk1", "pk2"], 1000)
    == Filter(
      ..filter.new(),
      kinds: Some([24_133]),
      p_tags: Some(["pk1", "pk2"]),
      since: Some(1000),
    )
}

/// 取り直しの要求の `since` は、ランナーのメモリの再開点を優先し、無ければ
/// 保存済みの値を使う。保存済みも無い要求は落とし、要求の順は保つ。
pub fn catchup_since_resolves_each_request_test() {
  let stored = fn(plugin: String) {
    case plugin {
      "logger" -> Ok(Some(100))
      _ -> Ok(None)
    }
  }
  assert subscriptions.catchup_since(
      [
        #("logger", plugin_runner.Catchup(since: None, until: 200)),
        #("echo", plugin_runner.Catchup(since: Some(50), until: 300)),
        #("unsaved", plugin_runner.Catchup(since: None, until: 400)),
      ],
      stored,
    )
    == Ok([#("logger", 100, 200), #("echo", 50, 300)])
}

/// 保存済みの再開点を 1 つでも読めなければ、解決は全体を失敗にする（その評価では
/// 購読を 1 本も定義しない）。
pub fn catchup_since_fails_as_a_whole_on_a_read_error_test() {
  assert subscriptions.catchup_since(
      [#("logger", plugin_runner.Catchup(since: None, until: 200))],
      fn(_plugin) { Error("unavailable") },
    )
    == Error(Nil)
}
