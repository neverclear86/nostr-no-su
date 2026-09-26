//// `persistent_term:put/2` と `get/2` に Gleam の型を付けた束縛。キーごとに置く値の型を
//// 揃えるのは呼び出し側で、`get` は置かれた値を検査せずに `default` の型として返す。

import gleam/erlang/atom.{type Atom}

/// `key` に `value` を置く。VM の全プロセスから読め、置いたプロセスが終わっても残る。
@external(erlang, "persistent_term", "put")
pub fn put(key: key, value: value) -> Atom

/// `key` に置かれた値。キーが無ければ `default` を返すので、`badarg` で落ちない。
@external(erlang, "persistent_term", "get")
pub fn get(key: key, default: value) -> value
