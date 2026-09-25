//// 複数のテストが使う外部関数の宣言。Erlang の BIF と、`test/support/child_fixture.erl`
//// の登録名の問い合わせと、本体の FFI（`nostr_no_su_ffi`）の自プロセスの未処理メッセージ数
//// を置く。

import gleam/erlang/atom.{type Atom}

/// 呼び出しごとに VM の中で一意な整数。`[positive]` で常に正の値になる。
@external(erlang, "erlang", "unique_integer")
pub fn unique_integer(options: List(Atom)) -> Int

/// 登録名が使われているか。
@external(erlang, "child_fixture", "is_registered")
pub fn is_registered(name: Atom) -> Bool

/// 自プロセスの未処理メッセージ数。
@external(erlang, "nostr_no_su_ffi", "message_queue_len")
pub fn message_queue_len() -> Int
