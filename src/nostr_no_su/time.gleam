//// 現在時刻を取る口。壁時計（`now_seconds`）と単調時計（`monotonic_ms`）の 2 つを持つ。
////
//// 壁時計の実体は `erlang:system_time(second)` で、システムの時計の変更を受ける。
//// 承認待ちの失効やセッションの間引きのように、この値どうしの差で経過時間も
//// 測っているため、時計が飛べばその判定も同じだけずれる。

/// 現在時刻を Unix タイムスタンプ（秒）で返す。
@external(erlang, "nostr_no_su_ffi", "now_seconds")
pub fn now_seconds() -> Int

/// 単調に増える時刻をミリ秒で返す。値そのものに意味は無く、差だけを使う。
/// システムの時計の変更を受けない。
@external(erlang, "nostr_no_su_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int
