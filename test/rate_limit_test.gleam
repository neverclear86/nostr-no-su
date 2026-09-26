import gleam/int
import gleam/list
import gleam/option.{None, Some}
import nostr_no_su/bunker/rate_limit.{type Limiter, Admitted, Refused}

/// 1 から `count` までの整数の一覧。別々のクライアントを並べるために使う。
fn up_to(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index + 1 })
}

/// 時刻 `now` に `client` のリクエストを 1 件数え、通した状態を返す。捨てられた
/// のはテスト自体の誤りとして扱う。
fn admitted(limiter: Limiter, client: String, now: Int) -> Limiter {
  let assert Admitted(limiter:) = rate_limit.admit(limiter, client, now)
  limiter
}

/// `now` に `n` 番目のクライアントのリクエストを通した状態を返す。
fn admitted_nth(limiter: Limiter, n: Int, now: Int) -> Limiter {
  admitted(limiter, "client-" <> int.to_string(n), now)
}

/// `now` に `capacity` 件を別々のクライアントが通して、全体のバケットを
/// 使い切った状態。
fn global_exhausted(capacity: Int, now: Int) -> Limiter {
  list.fold(up_to(capacity), rate_limit.new(), fn(limiter, n) {
    admitted_nth(limiter, n, now)
  })
}

/// 同じ時刻に `client_limit` 件を通したクライアントの次の 1 件は捨てる。別の
/// クライアントは自分のバケットを持つので影響を受けない。
pub fn a_client_over_its_limit_is_refused_test() {
  let limiter =
    list.fold(
      up_to(rate_limit.client_limit.capacity),
      rate_limit.new(),
      fn(limiter, _) { admitted(limiter, "client-a", 1000) },
    )
  let assert Refused(..) = rate_limit.admit(limiter, "client-a", 1000)
  let assert Admitted(..) = rate_limit.admit(limiter, "client-b", 1000)
}

/// `global_limit` 件を別々のクライアントが使い切ると、まだ 1 件も送っていない
/// 新しいクライアントも捨てる。
pub fn the_global_limit_refuses_new_clients_test() {
  let limiter = global_exhausted(rate_limit.global_limit.capacity, 1000)
  let assert Refused(..) = rate_limit.admit(limiter, "client-new", 1000)
}

/// 使い切ったバケットは `refill_seconds` 秒ごとに 1 件だけ補充され、その間は
/// 捨てる。
pub fn a_bucket_refills_over_time_test() {
  let limiter =
    list.fold(
      up_to(rate_limit.client_limit.capacity),
      rate_limit.new(),
      fn(limiter, _) { admitted(limiter, "client-a", 1000) },
    )
  let soon = 1000 + rate_limit.client_limit.refill_seconds - 1
  let assert Refused(limiter:, ..) = rate_limit.admit(limiter, "client-a", soon)
  let after = 1000 + rate_limit.client_limit.refill_seconds
  let limiter = admitted(limiter, "client-a", after)
  let assert Refused(..) = rate_limit.admit(limiter, "client-a", after)
}

/// 捨てたリクエストはどちらのトークンも使わない。自分の上限を超えて送り続ける
/// クライアントだけでは、全体のバケットを使い切れない。
pub fn refused_requests_spend_no_tokens_test() {
  // client-a が自分の上限（4 件）を使い切った状態にする
  let limiter =
    list.fold(
      up_to(rate_limit.client_limit.capacity),
      rate_limit.new(),
      fn(limiter, _) { admitted(limiter, "client-a", 1000) },
    )
  // 全体の容量ぶん捨てられても、使った全体のトークンは 4 件のまま
  let limiter =
    list.fold(up_to(rate_limit.global_limit.capacity), limiter, fn(limiter, _) {
      let assert Refused(limiter:, ..) =
        rate_limit.admit(limiter, "client-a", 1000)
      limiter
    })
  // 残りの全体トークン（20 - 4 = 16 件）は他のクライアントがそのまま使える
  let remaining =
    rate_limit.global_limit.capacity - rate_limit.client_limit.capacity
  let limiter =
    list.fold(up_to(remaining), limiter, fn(limiter, n) {
      admitted_nth(limiter, n, 1000)
    })
  let assert Refused(..) = rate_limit.admit(limiter, "client-new", 1000)
}

/// 捨てた件数は `report_interval_seconds` に 1 回まで報告する。間に捨てたものは
/// 次の報告にまとめる。
pub fn refusals_are_reported_once_per_interval_test() {
  let limiter = global_exhausted(rate_limit.global_limit.capacity, 1000)
  let assert Refused(limiter:, report:) =
    rate_limit.admit(limiter, "client-x", 1000)
  assert report == Some(rate_limit.report(1))
  let assert Refused(limiter:, report:) =
    rate_limit.admit(limiter, "client-x", 1000)
  assert report == None
  let assert Refused(limiter:, report:) =
    rate_limit.admit(limiter, "client-x", 1000)
  assert report == None
  // 報告の間隔が過ぎてから再び使い切ると、間に捨てた 2 件と合わせて 3 件を報告する
  let later = 1000 + rate_limit.report_interval_seconds
  let limiter =
    list.fold(up_to(rate_limit.global_limit.capacity), limiter, fn(limiter, n) {
      admitted_nth(limiter, 100 + n, later)
    })
  let assert Refused(report:, ..) = rate_limit.admit(limiter, "client-y", later)
  assert report == Some(rate_limit.report(3))
}

/// 記憶するクライアントは通したものだけで有界になる。満ちたバケットは消すので、
/// `client_limit` が満ちるまでの時間に全体が通せる件数を超えない。
pub fn remembered_clients_stay_bounded_test() {
  let bound =
    rate_limit.client_limit.refill_seconds
    / rate_limit.global_limit.refill_seconds
    + 1
  list.fold(up_to(200), rate_limit.new(), fn(limiter, n) {
    let now = 1000 + n * rate_limit.global_limit.refill_seconds
    let limiter = admitted_nth(limiter, n, now)
    assert rate_limit.remembered_clients(limiter) <= bound
    limiter
  })
}
