//// 現在時刻を取る唯一の口。
////
//// 実体は `erlang:system_time(second)` で、システムの時計の変更を受ける。
//// 承認待ちの失効やセッションの間引きのように、この値どうしの差で経過時間も
//// 測っているため、時計が飛べばその判定も同じだけずれる。

/// 現在時刻を Unix タイムスタンプ（秒）で返す。
@external(erlang, "nostr_no_su_ffi", "now_seconds")
pub fn now_seconds() -> Int
