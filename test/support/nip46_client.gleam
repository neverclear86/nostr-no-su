//// テストから見た NIP-46 クライアント。
////
//// 実際のクライアントと同じ手順で、JSON-RPC の本文を署名者宛に NIP-44 で暗号化し
//// kind 24133 イベントとして署名する。応答も同じ会話鍵で復号して読む。エンジンを
//// 直接叩くテスト（`bunker_engine_test`）と、スーパービジョンツリー越しに叩く
//// テスト（`app_test`）が同じ手順を共有するために置く。

import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/crypto/nip44
import nostr_no_su/nostr/event.{type Event, Event}

/// テスト用 16 進鍵に対応するアカウント。テストの鍵は正しい前提なので、読めない
/// のはテスト自体の誤りとして扱う。
pub fn account_for(key_hex: String) -> Account {
  let assert Ok(account) = account.from_hex(key_hex)
  account
}

/// 指定した params を持つ JSON-RPC リクエストの本文。
pub fn request_body(id: String, method: String, params_json: String) -> String {
  "{\"id\":\""
  <> id
  <> "\",\"method\":\""
  <> method
  <> "\",\"params\":"
  <> params_json
  <> "}"
}

/// `connect` リクエストの本文。`secret_arg` が空文字列なら、シークレット無しで
/// 接続するクライアントと同じ形になる（nostr-tools はそのように送る）。
pub fn connect_body(signer: Account, secret_arg: String, id: String) -> String {
  request_body(
    id,
    "connect",
    "[\"" <> signer.pubkey_hex <> "\",\"" <> secret_arg <> "\"]",
  )
}

/// 指定した本文を持つリクエストイベント。署名者宛に暗号化し、署名者への p タグ
/// を付けて、クライアントの鍵で署名する。
pub fn request_event(
  client: Account,
  signer: Account,
  body: String,
  created_at: Int,
) -> Event {
  request_event_with_tags(
    client,
    signer,
    body,
    [["p", signer.pubkey_hex]],
    created_at,
  )
}

/// タグを指定してリクエストイベントを組み立てる。p タグの並びやルーティング先と
/// 暗号化の宛先のずれが本題になるテストが使う。`encrypt_to` は content の暗号化に
/// 使う相手で、タグが示すルーティング先とは独立に指定できる。
pub fn request_event_with_tags(
  client: Account,
  encrypt_to: Account,
  body: String,
  tags: List(List(String)),
  created_at: Int,
) -> Event {
  let assert Ok(conversation_key) =
    nip44.conversation_key(client.privkey, encrypt_to.pubkey)
  let assert Ok(content) = nip44.encrypt(body, conversation_key)
  let unsigned =
    Event(
      id: "",
      pubkey: client.pubkey_hex,
      created_at: created_at,
      kind: event.nip46_kind,
      tags: tags,
      content: content,
      sig: "",
    )
  let assert Ok(signed) = event.finalize(unsigned, client.privkey)
  signed
}

/// 応答イベントを復号して JSON-RPC の本文に戻す。クライアントが読むのと同じ形で
/// 取り出す。
pub fn decrypt_response(
  client: Account,
  signer: Account,
  response: Event,
) -> String {
  let assert Ok(conversation_key) =
    nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(text) = nip44.decrypt(response.content, conversation_key)
  text
}
