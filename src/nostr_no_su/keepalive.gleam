//// WebSocket 接続の生存確認を、刻みごとの判定で行う。刻みの間隔を I とすると、
//// 無受信が I を超えて 2I 以内の刻みで ping を送り、それでも無受信のまま
//// 2I を超えて 3I 以内の刻みで接続を切る判定になる。
////
//// | heard | awaiting_pong | 判定 | 次の状態 |
//// | --- | --- | --- | --- |
//// | True | どちらでも | `Healthy` | 両方 False |
//// | False | False | `SendPing` | awaiting_pong だけ True |
//// | False | True | `Unresponsive` | 変えない |

/// 接続の生存確認の状態。前の刻みから受信したかと、ping の応答を待っているか。
pub opaque type Keepalive {
  Keepalive(heard: Bool, awaiting_pong: Bool)
}

/// 刻み 1 回の判定。
pub type Verdict {
  /// 前の刻みから何かを受信した。
  Healthy
  /// 無受信が続いたので ping を送る。
  SendPing
  /// ping を送った後も無受信だった。接続を切る。
  Unresponsive
}

/// 接続直後の状態。まだ何も受信しておらず、ping も送っていない。
pub fn new() -> Keepalive {
  Keepalive(heard: False, awaiting_pong: False)
}

/// リレーから何かを受信した。次の刻みは `Healthy` になり、`awaiting_pong` も
/// 解消する。
pub fn received(_state: Keepalive) -> Keepalive {
  Keepalive(heard: True, awaiting_pong: False)
}

/// 刻み 1 回分の判定を行い、次の状態と判定を返す。
pub fn tick(state: Keepalive) -> #(Keepalive, Verdict) {
  case state.heard, state.awaiting_pong {
    True, _ -> #(Keepalive(heard: False, awaiting_pong: False), Healthy)
    False, False -> #(Keepalive(heard: False, awaiting_pong: True), SendPing)
    False, True -> #(state, Unresponsive)
  }
}
