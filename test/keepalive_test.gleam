import nostr_no_su/keepalive

/// 接続直後、まだ何も受信していないので刻みは ping を求める。
pub fn a_silent_tick_asks_for_a_ping_test() {
  let #(_state, verdict) = keepalive.new() |> keepalive.tick
  assert verdict == keepalive.SendPing
}

/// 受信した直後の刻みは healthy になり、受信の印はその刻みで消える。
pub fn a_tick_after_receiving_is_healthy_test() {
  let #(state, verdict) =
    keepalive.new() |> keepalive.received |> keepalive.tick
  assert verdict == keepalive.Healthy

  let #(_state, verdict) = keepalive.tick(state)
  assert verdict == keepalive.SendPing
}

/// ping を送った刻みの次でも無受信なら unresponsive になる。
pub fn a_second_silent_tick_is_unresponsive_test() {
  let #(state, _verdict) = keepalive.new() |> keepalive.tick
  let #(_state, verdict) = keepalive.tick(state)
  assert verdict == keepalive.Unresponsive
}

/// ping を送った後に何か受信すれば、次の刻みは healthy になる。
pub fn a_pong_after_a_ping_is_healthy_test() {
  let #(state, _verdict) = keepalive.new() |> keepalive.tick
  let #(_state, verdict) = state |> keepalive.received |> keepalive.tick
  assert verdict == keepalive.Healthy
}
