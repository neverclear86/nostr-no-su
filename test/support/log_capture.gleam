//// テストが OTP logger を通る行を捕まえるためのハンドラーの宣言。
//// 行は本番と同じ 1 行形式に整形され、積んだ順に読める。

/// ハンドラーの id と、捕まえた行を積む表。中身は Erlang 側だけが触る。
pub type Capture

/// 一意なハンドラーを登録して捕まえ始める。
@external(erlang, "log_capture", "install")
pub fn install() -> Capture

/// 捕まえた行を積んだ順に返す。
@external(erlang, "log_capture", "lines")
pub fn lines(capture: Capture) -> List(String)

/// ハンドラーと表を消す。
@external(erlang, "log_capture", "remove")
pub fn remove(capture: Capture) -> Nil
