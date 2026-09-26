//// WebSocket 接続の生存確認を、刻みごとの判定で行う。刻みの間隔を I とすると、
//// 無受信が I を超えて 2I 以内の刻みで ping を送り、それでも無受信のまま
//// 2I を超えて 3I 以内の刻みで接続を切る判定になる。
////
//// | 状態 | 判定 | 次の状態 |
//// | --- | --- | --- |
//// | `Heard` | `Healthy` | `Quiet` |
//// | `Quiet` | `SendPing` | `AwaitingPong` |
//// | `AwaitingPong` | `Unresponsive` | `AwaitingPong` |
////
//// どの状態でも、受信すれば `Heard` になる。

/// 接続の生存確認の状態。
pub opaque type Keepalive {
  /// 前の刻みから何も受信しておらず、ping の応答も待っていない。
  Quiet
  /// 前の刻みから何かを受信した。
  Heard
  /// ping を送った後、まだ何も受信していない。
  AwaitingPong
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
  Quiet
}

/// リレーから何かを受信した後の状態。次の刻みは `Healthy` になる。
pub fn received() -> Keepalive {
  Heard
}

/// 刻み 1 回分の判定を行い、次の状態と判定を返す。
pub fn tick(state: Keepalive) -> #(Keepalive, Verdict) {
  case state {
    Heard -> #(Quiet, Healthy)
    Quiet -> #(AwaitingPong, SendPing)
    AwaitingPong -> #(AwaitingPong, Unresponsive)
  }
}
