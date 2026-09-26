//// セッションの外の NIP-46 リクエストに応答する回数の上限（純粋）。クライアントの
//// pubkey ごとと全体の 2 つのトークンバケットで数え、両方に残りがあるときだけ
//// 1 件ずつ取って通す。捨てたリクエストはどちらのトークンも使わない。時刻は
//// 呼び出し側が Unix 秒で渡す。
////
//// 上限の値の理由と、記憶する pubkey の件数が有界である理由は docs/design-decisions.md の
//// 「NIP-46 の入力にはサイズと件数の上限がある」にある。

import gleam/dict.{type Dict}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result

/// トークンバケットの大きさ。容量 `capacity` 件で、`refill_seconds` 秒ごとに
/// 1 件補充する。
pub type Limit {
  Limit(capacity: Int, refill_seconds: Int)
}

/// クライアントの pubkey ごとの上限。
pub const client_limit = Limit(capacity: 4, refill_seconds: 15)

/// 全体の上限。
pub const global_limit = Limit(capacity: 20, refill_seconds: 3)

/// 捨てた件数を報告する最小の間隔（秒）。
pub const report_interval_seconds = 60

/// トークンバケット 1 つ。`updated_at` は補充を数え始めた時刻で、満ちている間は
/// 最後に補充した時刻にする。
type Bucket {
  Bucket(tokens: Int, updated_at: Int)
}

/// 上限の状態。`clients` はクライアントの pubkey hex → バケットで、無い pubkey
/// は満ちたバケットと同じに扱う。`dropped` は最後の報告の後に捨てた件数、
/// `reported_at` は最後に報告した時刻。
pub opaque type Limiter {
  Limiter(
    global: Bucket,
    clients: Dict(String, Bucket),
    dropped: Int,
    reported_at: Int,
  )
}

/// `admit` の結果。
pub type Admission {
  /// 通した。両方のバケットから 1 件ずつ取った状態を持つ。
  Admitted(limiter: Limiter)
  /// 捨てた。`report` は報告の間隔が過ぎていればログの 1 行（`report`）で、
  /// そうでなければ `None`。
  Refused(limiter: Limiter, report: Option(String))
}

/// 全体のバケットが満ち、pubkey を 1 件も記憶していない状態。最初に捨てた
/// リクエストはすぐ報告する。
pub fn new() -> Limiter {
  Limiter(
    global: Bucket(global_limit.capacity, 0),
    clients: dict.new(),
    dropped: 0,
    reported_at: 0,
  )
}

/// クライアント `client` のリクエストを 1 件数える。全体と `client` のバケット
/// を `now` まで補充し、両方に残りがあれば 1 件ずつ取り、満ちたバケットを消して
/// 通す。どちらかが空なら状態のトークンを変えずに捨て、
/// `report_interval_seconds` 以上前に報告していれば、それまでに捨てた件数を
/// 報告して数え直す。
pub fn admit(limiter: Limiter, client: String, now: Int) -> Admission {
  let global = refill(limiter.global, global_limit, now)
  let own =
    dict.get(limiter.clients, client)
    |> result.unwrap(Bucket(client_limit.capacity, now))
    |> refill(client_limit, now)
  case global.tokens > 0 && own.tokens > 0 {
    False -> refuse(limiter, now)
    True -> {
      let clients =
        dict.filter(limiter.clients, fn(_client, bucket) {
          !is_full(bucket, client_limit, now)
        })
      Admitted(
        Limiter(
          ..limiter,
          global: take(global),
          clients: dict.insert(clients, client, take(own)),
        ),
      )
    }
  }
}

/// 記憶しているクライアントの pubkey の件数。
pub fn remembered_clients(limiter: Limiter) -> Int {
  dict.size(limiter.clients)
}

/// 捨てた件数を報告するログの 1 行。
pub fn report(dropped: Int) -> String {
  "dropped "
  <> int.to_string(dropped)
  <> " requests without a session over the rate limit"
}

/// `now` までに補充したバケット。補充した間隔の整数倍だけ `updated_at` を進め、
/// 端数の秒は次に持ち越す。時計が戻ったときは補充しない。
fn refill(bucket: Bucket, limit: Limit, now: Int) -> Bucket {
  let gained = int.max(0, now - bucket.updated_at) / limit.refill_seconds
  case bucket.tokens + gained >= limit.capacity {
    True -> Bucket(tokens: limit.capacity, updated_at: now)
    False ->
      Bucket(
        tokens: bucket.tokens + gained,
        updated_at: bucket.updated_at + gained * limit.refill_seconds,
      )
  }
}

/// トークンを 1 件取ったバケット。残りの有無は呼び出し側が確かめる。
fn take(bucket: Bucket) -> Bucket {
  Bucket(..bucket, tokens: bucket.tokens - 1)
}

/// `now` まで補充すると容量に戻るか。
fn is_full(bucket: Bucket, limit: Limit, now: Int) -> Bool {
  refill(bucket, limit, now).tokens == limit.capacity
}

/// 1 件捨てる。報告の間隔が過ぎていれば件数を報告して数え直す。
fn refuse(limiter: Limiter, now: Int) -> Admission {
  let dropped = limiter.dropped + 1
  case now - limiter.reported_at >= report_interval_seconds {
    True ->
      Refused(
        Limiter(..limiter, dropped: 0, reported_at: now),
        Some(report(dropped)),
      )
    False -> Refused(Limiter(..limiter, dropped: dropped), None)
  }
}
