//// 現在時刻を取る唯一の口。
////
//// 実体は `erlang:system_time(second)` で、システムの時計の変更を受ける。
//// 単調ではないので、経過時間の測定には使わない。

/// 現在時刻を Unix タイムスタンプ（秒）で返す。
@external(erlang, "nostr_no_su_ffi", "now_seconds")
pub fn now_seconds() -> Int
