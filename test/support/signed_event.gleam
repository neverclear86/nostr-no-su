//// テストで使う、署名済みのイベントと検証済みのイベント。`event.Verified` は
//// `event.verify` を通さないと作れないので、テストも本物の署名を作って検証する。

import nostr_no_su/crypto/secp256k1
import nostr_no_su/hex
import nostr_no_su/nostr/event.{type Event, type Verified, Event}

/// 署名に使うテスト用の秘密鍵。
const key = "0000000000000000000000000000000000000000000000000000000000000003"

/// テスト用の鍵で署名した、指定した kind と content のイベント。署名は補助乱数を
/// 引くので、同じ引数でも呼ぶたびに `sig` が変わる。比べるときは 1 度作った値を
/// 使い回す。
pub fn new(kind: Int, content: String) -> Event {
  let assert Ok(privkey) = hex.decode(key)
  let assert Ok(pubkey) = secp256k1.xonly_pubkey(privkey)
  let draft =
    Event(
      id: "",
      pubkey: hex.encode(pubkey),
      created_at: 1_700_000_000,
      kind: kind,
      tags: [],
      content: content,
      sig: "",
    )
  let assert Ok(signed) = event.finalize(draft, privkey)
  signed
}

/// 署名済みのイベントを検証済みにする。検証に通らないのはテスト自体の誤りとして
/// 扱う。
pub fn verified(signed: Event) -> Verified {
  let assert Ok(verified) = event.verify(signed)
  verified
}
