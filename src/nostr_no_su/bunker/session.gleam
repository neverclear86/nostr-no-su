//// バンカーの承認済みセッションと承認待ちの接続要求の型。フィールドの意味をここにだけ
//// 書く。どのモジュールも import しない葉に置き、使う側の依存の向きを変えない。

/// 承認済みのクライアントセッション 1 件。`connect` が成功した（署名者,
/// クライアント）の組で、管理 UI の取り消しかクライアントの `logout`、アカウントの
/// 削除、engine の `session_capacity` による押し出しまで署名を代理できる。
pub type Session {
  Session(
    /// 署名者の公開鍵（16 進、小文字）。
    signer: String,
    /// クライアントの公開鍵（16 進、小文字）。
    client: String,
    /// セッション内の `sign_event` と `nip44_encrypt` / `nip44_decrypt` を照合する
    /// 権限。組を最初に承認したときの値から、管理 UI の `set_perms` でだけ変わる。
    /// 空文字列は既定の集合（`bunker/permission` の既定）で照合する。
    perms: String,
    /// 作成した Unix 秒。
    created_at: Int,
    /// 最後に使った Unix 秒。作成時は `created_at` と同じ値で、セッション内の
    /// リクエストを処理したとき、前回から engine の `last_used_granularity_seconds`
    /// 以上経っていれば進める。
    last_used_at: Int,
    /// `nostrconnect://` で開いたときの URI のリレー（URI の順）。`bunker://` の
    /// `connect` と承認で開いたセッションでは空。承認済みの組を `nostrconnect://`
    /// で開き直すと、この一覧だけが新しい URI のものに変わる。
    relays: List(String),
  )
}

/// 承認待ちの接続要求 1 件。承認済みでない組に secret が無いか一致しない `connect`
/// が届き、承認フローが有効なときに作られる。承認（セッションになる）、拒否、同じ組の
/// 新しい要求による置き換え、アカウントの削除、engine の `pending_ttl_seconds` の
/// 失効、`pending_capacity` による押し出しで消える。
pub type Pending {
  Pending(
    /// 承認ページの URL に入るトークン。engine の承認待ちの辞書の鍵と同じ値で、
    /// 一覧に出すときに鍵を持ち回らずに済む。
    token: String,
    /// 署名者の公開鍵（16 進、小文字）。
    signer: String,
    /// クライアントの公開鍵（16 進、小文字）。
    client: String,
    /// 元の `connect` リクエストの id。承認後の応答を同じ id で返すために覚えておく。
    request_id: String,
    /// `connect` の `params[2]` を engine の `max_perms_bytes` で切った値。空文字列は
    /// 要求なし（`params[2]` が無いときも空文字列）。
    perms: String,
    /// `connect` が空でない secret を示し、それが一致しなかったか。
    secret_mismatch: Bool,
    /// 作成した Unix 秒。失効（engine の `pending_ttl_seconds`）の起点になる。
    created_at: Int,
  )
}
