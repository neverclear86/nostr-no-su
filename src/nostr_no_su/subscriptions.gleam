//// 監視とバンカーの購読の定義。購読 id とフィルターの組み立て（純粋）と、監視リレーごとに
//// バンカーの署名者と再開点から定義を評価する閉包の組み立てを持つ。

import gleam/erlang/process.{type Name}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import nostr_no_su/bunker
import nostr_no_su/dedup
import nostr_no_su/nostr/event
import nostr_no_su/nostr/filter.{type Filter, Filter}
import nostr_no_su/plugin_runner
import nostr_no_su/relay_client

/// 監視の購読 id。
pub const monitor_subscription_id = "nostr-no-su"

/// プラグインの取り直しの購読 id の接頭辞。プラグイン名を繋げて使う。
const catchup_subscription_prefix = "nostr-no-su-catchup-"

/// 購読 id が取り直しのものなら、そのプラグイン名。`catchup_subscriptions` が
/// 組み立てる id の逆である。
pub fn catchup_plugin(subscription_id: String) -> Option(String) {
  case string.starts_with(subscription_id, catchup_subscription_prefix) {
    True ->
      Some(string.drop_start(
        subscription_id,
        string.length(catchup_subscription_prefix),
      ))
    False -> None
  }
}

/// 登録アカウントが書いたイベントの購読。署名者がいなければ購読を定義せず、継続
/// を評価しない（開いている購読は照合で CLOSE になる、`relay_client.sync`）。継続
/// は署名者がいるときだけ呼び、`since` と足す購読（プラグインの取り直し、
/// `catchup_subscriptions`）を返す。`since` が `Ok(None)` なら保存済みのイベントを
/// すべて求め、`Error(Nil)` なら定義を得られなかったことにする。
pub fn monitor_subscriptions(
  signer_pubkeys: List(String),
  continuation: fn() -> Result(#(Option(Int), List(#(String, Filter))), Nil),
) -> Result(List(#(String, Filter)), Nil) {
  case signer_pubkeys {
    [] -> Ok([])
    signer_pubkeys -> {
      use #(since, extra) <- result.map(continuation())
      [
        #(
          monitor_subscription_id,
          Filter(..filter.new(), authors: Some(signer_pubkeys), since: since),
        ),
        ..extra
      ]
    }
  }
}

/// 復帰したプラグインの取り直しの購読。署名者がいなければ購読を定義しない。購読 id は
/// プラグイン名で分け、それぞれ `until` で範囲を閉じる（それより後のイベントは通常の監視の
/// 購読が運ぶ）。`monitor_since` はこの接続の監視の購読の `since` で、`Some` なら `until` を
/// それ以下に切り詰め、範囲が残らない取り直しは定義しない（切り詰めた範囲は監視の購読が
/// 運ぶ。境界の秒は両方が運ぶ）。`None` なら範囲を変えない（`since` の無い監視の購読は
/// リレーの件数の上限で切られうる）。
pub fn catchup_subscriptions(
  signer_pubkeys: List(String),
  monitor_since: Option(Int),
  catchups: List(#(String, Int, Int)),
) -> List(#(String, Filter)) {
  case signer_pubkeys {
    [] -> []
    signer_pubkeys ->
      list.filter_map(catchups, fn(catchup) {
        let #(plugin, since, until) = catchup
        let until = case monitor_since {
          None -> until
          Some(monitor) -> int.min(until, monitor)
        }
        case since <= until {
          False -> Error(Nil)
          True ->
            Ok(#(
              catchup_subscription_prefix <> plugin,
              Filter(
                ..filter.new(),
                authors: Some(signer_pubkeys),
                since: Some(since),
                until: Some(until),
              ),
            ))
        }
      })
  }
}

/// 署名者宛の NIP-46 リクエストの購読。署名者がいなければ購読を定義しない。空の
/// `#p` の扱いはリレーによって異なるため REQ を送らず、開いている購読は照合で
/// CLOSE になる（`relay_client.sync`）。
pub fn bunker_subscriptions(
  signer_pubkeys: List(String),
  since: Int,
) -> List(#(String, Filter)) {
  case signer_pubkeys {
    [] -> []
    signer_pubkeys -> [#("bunker", bunker_filter(signer_pubkeys, since))]
  }
}

/// 指定した署名者 pubkey 宛の NIP-46 リクエストを購読する。
pub fn bunker_filter(signer_pubkeys: List(String), since: Int) -> Filter {
  Filter(
    ..filter.new(),
    kinds: Some([event.nip46_kind]),
    p_tags: Some(signer_pubkeys),
    since: Some(since),
  )
}

/// 監視リレー `relay_url` の購読の定義。評価のたびにバンカーの現在の署名者から
/// 組み立て、署名者がいれば `since` をディスパッチャーのメモリの再開点から、無ければ
/// 保存済みの再開点（`load`）から決める。署名者がいれば、各ランナーの取り直しの
/// 要求（`catchups`）からプラグインごとの取り直しの購読を足す。その `since` は
/// ランナーのメモリの再開点か保存済みの値（`load_plugin`）から決め、再開点の無い
/// 要求は落とす。`until` は監視の購読の `since` までに切り詰め、範囲が残らない
/// 要求はこのリレーでは定義しない（`catchup_subscriptions`）。取り直しの
/// 解決に失敗したら定義全体を得られなかったことにする。どれかに応答が無ければ
/// 定義を得られなかったことにし、開いている購読を閉じない。
pub fn monitor_relay_subscriptions(
  bunker_name: Name(bunker.Msg),
  dedup_name: Name(dedup.Msg),
  load: fn(String) -> Result(Option(Int), String),
  load_plugin: fn(String) -> Result(Option(Int), String),
  catchups: fn() -> Result(List(#(String, plugin_runner.Catchup)), Nil),
  relay_url: String,
) -> relay_client.Subscriptions {
  fn() {
    use signers <- result.try(
      bunker.signers(bunker_name) |> option.to_result(Nil),
    )
    use <- monitor_subscriptions(signers)
    use in_memory <- result.try(dedup.since(dedup_name, relay_url))
    use since <- result.try(resume_since(in_memory, fn() { load(relay_url) }))
    use requests <- result.try(catchups())
    use resolved <- result.map(catchup_since(requests, load_plugin))
    #(since, catchup_subscriptions(signers, since, resolved))
  }
}

/// メモリの再開点があればそれを、無ければ保存済みの値を使う。読めなければ
/// 定義を得られなかったことにする。監視の購読と取り直しの購読で共用する。
fn resume_since(
  in_memory: Option(Int),
  load: fn() -> Result(Option(Int), String),
) -> Result(Option(Int), Nil) {
  case in_memory {
    Some(_) -> Ok(in_memory)
    None -> load() |> result.replace_error(Nil)
  }
}

/// 取り直しの要求ごとに `since` を解決し、購読を定義する `#(プラグイン名,
/// since, until)` の一覧にする。`since` はランナーのメモリの再開点があれば
/// それを、無ければ `load_plugin` で読む保存済みの値を使う。再開点が未保存の
/// 要求は落とす（取り直す範囲が決まらない）。1 つでも読めなければ全体を
/// `Error(Nil)` にする。テストが直接呼べるよう公開する。
pub fn catchup_since(
  catchups: List(#(String, plugin_runner.Catchup)),
  load_plugin: fn(String) -> Result(Option(Int), String),
) -> Result(List(#(String, Int, Int)), Nil) {
  list.try_fold(catchups, [], fn(acc, request) {
    let #(plugin, catchup) = request
    use since <- result.map(
      resume_since(catchup.since, fn() { load_plugin(plugin) }),
    )
    case since {
      Some(at) -> [#(plugin, at, catchup.until), ..acc]
      None -> acc
    }
  })
  |> result.map(list.reverse)
}
