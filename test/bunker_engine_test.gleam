import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine.{Duplicate, Ignore, Reply}
import nostr_no_su/crypto/nip44
import nostr_no_su/nostr/event.{type Event, Event}

const secret = "s3cr3t-token"

const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

const other_client_key = "0000000000000000000000000000000000000000000000000000000000000005"

/// 承認ページを載せる管理 UI の公開 URL。
const auth_base = "http://admin.test"

/// 承認待ちのトークン。アクターが引く乱数の代わりにテストから注入する。
const token = "tok-1"

/// テスト用 16 進鍵に対応するアカウント。
fn account_for(key_hex: String) -> Account {
  let assert Ok(account) = account.from_hex(key_hex)
  account
}

/// テスト用の署名者 1 件とテスト用シークレットを扱うエンジン。管理 UI が無効な
/// 構成なので、シークレットの一致しない `connect` は拒否される。
fn new_engine() -> engine.Engine {
  engine.new([#(account_for(signer_key), secret)], None)
}

/// 承認フロー（auth_url）を有効にしたエンジン。
fn auth_engine() -> engine.Engine {
  engine.new([#(account_for(signer_key), secret)], Some(auth_base))
}

/// 受信イベントを 1 件処理する。トークンは固定なので、承認ページの URL も
/// テストから予測できる。
fn handle(
  state: engine.Engine,
  incoming: Event,
  now: Int,
) -> #(engine.Engine, engine.Outcome) {
  engine.handle_event(state, incoming, engine.Context(now: now, token: token))
}

/// 実際のクライアントと同じ手順でリクエストイベントを組み立てる。JSON-RPC 本文
/// を署名者宛に NIP-44 で暗号化し、kind 24133 イベントとして署名する。
fn request_event(
  client: Account,
  signer: Account,
  rpc_json: String,
  created_at: Int,
) -> Event {
  let assert Ok(conversation_key) =
    nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(content) = nip44.encrypt(rpc_json, conversation_key)
  let unsigned =
    Event(
      id: "",
      pubkey: client.pubkey_hex,
      created_at: created_at,
      kind: 24_133,
      tags: [["p", signer.pubkey_hex]],
      content: content,
      sig: "",
    )
  let assert Ok(signed) = event.finalize(unsigned, client.privkey)
  signed
}

/// 応答イベントを復号して JSON-RPC 本文に戻す。
fn decrypt_response(
  client: Account,
  signer: Account,
  response: Event,
) -> String {
  let assert Ok(conversation_key) =
    nip44.conversation_key(client.privkey, signer.pubkey)
  let assert Ok(text) = nip44.decrypt(response.content, conversation_key)
  text
}

/// 指定した署名者とシークレットで `connect` リクエストを送る。
fn connect(
  engine: engine.Engine,
  client: Account,
  signer: Account,
  secret_arg: String,
  now: Int,
) -> #(engine.Engine, engine.Outcome) {
  let body =
    "{\"id\":\"c1\",\"method\":\"connect\",\"params\":[\""
    <> signer.pubkey_hex
    <> "\",\""
    <> secret_arg
    <> "\"]}"
  handle(engine, request_event(client, signer, body, now), now)
}

/// 正しいシークレットには、クライアント宛の署名済み応答で ack を返す。
pub fn connect_ack_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(_engine, outcome) = connect(new_engine(), client, signer, secret, 1000)
  let assert Reply(response) = outcome
  // 応答はクライアント宛であり、それ自体が正当なイベントである
  assert response.kind == 24_133
  assert response.tags == [["p", client.pubkey_hex]]
  assert response.pubkey == signer.pubkey_hex
  assert event.verify_signature(response)
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
}

/// 誤ったシークレットは拒否され、クライアントは未認可のままになる。
pub fn connect_wrong_secret_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, outcome) = connect(new_engine(), client, signer, "wrong", 1000)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "invalid secret",
  )
  // その後も未認可のまま
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_engine, outcome2) =
    handle(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(r2) = outcome2
  assert string.contains(decrypt_response(client, signer, r2), "unauthorized")
}

/// `connect` より前に送られたリクエストは未認可として拒否される。
pub fn get_public_key_requires_connect_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_engine, outcome) =
    handle(new_engine(), request_event(client, signer, body, 1000), 1000)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unauthorized",
  )
}

/// 接続後は `get_public_key` が署名者の pubkey を返す。
pub fn get_public_key_after_connect_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"g1\",\"result\":\"" <> signer.pubkey_hex <> "\"}"
}

/// `ping` には "pong" を返す。
pub fn ping_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"p1\",\"method\":\"ping\"}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"p1\",\"result\":\"pong\"}"
}

/// `sign_event` は正しい id と署名を持つイベントを返す。
pub fn sign_event_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft =
    "{\\\"kind\\\":1,\\\"content\\\":\\\"hello\\\",\\\"tags\\\":[],\\\"created_at\\\":1700000123}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  let result = decrypt_response(client, signer, response)
  // result フィールドは JSON 文字列として符号化された署名済みイベントなので、
  // 取り出してパースする。
  let assert Ok(signed) = parse_result_event(result)
  assert signed.pubkey == signer.pubkey_hex
  assert signed.kind == 1
  assert signed.content == "hello"
  assert signed.created_at == 1_700_000_123
  assert signed.id == event.compute_id(signed)
  assert event.verify_signature(signed)
}

/// `created_at` を持たないドラフトには現在時刻が入る。
pub fn sign_event_fills_created_at_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft = "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}"
  let body =
    "{\"id\":\"s2\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 2000), 2000)
  let assert Reply(response) = outcome
  let assert Ok(signed) =
    parse_result_event(decrypt_response(client, signer, response))
  assert signed.created_at == 2000
}

/// 受付ウィンドウの外にあるリクエストは無視される。
pub fn stale_event_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body = "{\"id\":\"x\",\"method\":\"ping\"}"
  // "now" の 1 時間前に作られたイベント
  let #(_engine, outcome) =
    handle(new_engine(), request_event(client, signer, body, 1000), 4600)
  let assert Ignore(_) = outcome
}

/// 同じリクエストが 2 度届いても処理は 1 度きりで、2 度目は重複として報告される。
/// 2 つ目のバンカーリレーがあると実際にこの状況が起きる。
pub fn replay_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let request =
    request_event(
      client,
      signer,
      "{\"id\":\"c1\",\"method\":\"connect\",\"params\":[\""
        <> signer.pubkey_hex
        <> "\",\""
        <> secret
        <> "\"]}",
      1000,
    )
  let #(engine, first) = handle(new_engine(), request, 1000)
  let assert Reply(_) = first
  let #(_engine, second) = handle(engine, request, 1000)
  let assert Duplicate = second
}

/// 署名の検証に失敗したリクエストは無視される。
pub fn tampered_signature_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let request =
    request_event(client, signer, "{\"id\":\"x\",\"method\":\"ping\"}", 1000)
  let tampered = Event(..request, sig: flip_last_hex(request.sig))
  let #(_engine, outcome) = handle(new_engine(), tampered, 1000)
  let assert Ignore(reason) = outcome
  assert string.contains(reason, "signature")
}

/// 別の署名者宛に暗号化された content は読めないため無視される。
pub fn undecryptable_content_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  // ルーティング先とは異なる署名者宛に暗号化した content
  let wrong_signer = account_for(other_client_key)
  let assert Ok(conversation_key) =
    nip44.conversation_key(client.privkey, wrong_signer.pubkey)
  let assert Ok(content) = nip44.encrypt("{\"id\":\"x\"}", conversation_key)
  let unsigned =
    Event(
      id: "",
      pubkey: client.pubkey_hex,
      created_at: 1000,
      kind: 24_133,
      tags: [["p", signer.pubkey_hex]],
      content: content,
      sig: "",
    )
  let assert Ok(request) = event.finalize(unsigned, client.privkey)
  let #(_engine, outcome) = handle(new_engine(), request, 1000)
  let assert Ignore(_) = outcome
}

/// 未知のメソッドはクラッシュではなくエラー応答で返す。
pub fn unknown_method_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"u1\",\"method\":\"do_the_thing\"}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unsupported method",
  )
}

/// NIP-04 のメソッドには「未対応」という明示的なエラーを返す。
pub fn nip04_stubbed_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body =
    "{\"id\":\"n1\",\"method\":\"nip04_encrypt\",\"params\":[\"pk\",\"text\"]}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "nip04 is not supported",
  )
}

/// `nip44_encrypt` と `nip44_decrypt` が往復し、第三者は自身の鍵でペイロードを
/// 復号できる。
pub fn nip44_roundtrip_via_engine_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let third_party = account_for(other_client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  // 署名者を介して "secret msg" を third_party 宛に暗号化する
  let enc_body =
    "{\"id\":\"e1\",\"method\":\"nip44_encrypt\",\"params\":[\""
    <> third_party.pubkey_hex
    <> "\",\"secret msg\"]}"
  let #(engine, enc_outcome) =
    handle(engine, request_event(client, signer, enc_body, 1001), 1001)
  let assert Reply(enc_response) = enc_outcome
  let payload = extract_result(decrypt_response(client, signer, enc_response))
  // 相互運用性を確認するため third_party が直接復号する
  let assert Ok(tp_key) =
    nip44.conversation_key(third_party.privkey, signer.pubkey)
  let assert Ok(plain) = nip44.decrypt(payload, tp_key)
  assert plain == "secret msg"
  // エンジン側でも復号して元に戻せる
  let dec_body =
    "{\"id\":\"d1\",\"method\":\"nip44_decrypt\",\"params\":[\""
    <> third_party.pubkey_hex
    <> "\",\""
    <> payload
    <> "\"]}"
  let #(_engine, dec_outcome) =
    handle(engine, request_event(client, signer, dec_body, 1002), 1002)
  let assert Reply(dec_response) = dec_outcome
  assert extract_result(decrypt_response(client, signer, dec_response))
    == "secret msg"
}

/// 認可とシークレットは署名者ごとに独立し、署名者間で共有されない。
pub fn multi_account_isolation_test() {
  let signer_a = account_for(signer_key)
  let signer_b = account_for(other_client_key)
  let client = account_for(client_key)
  let engine =
    engine.new([#(signer_a, "secret-a"), #(signer_b, "secret-b")], None)
  // A で認可を得る
  let #(engine, _) = connect(engine, client, signer_a, "secret-a", 1000)
  // B へのリクエストは未認可（認可は署名者ごと）
  let body = "{\"id\":\"g\",\"method\":\"get_public_key\"}"
  let #(engine, outcome_b) =
    handle(engine, request_event(client, signer_b, body, 1001), 1001)
  let assert Reply(rb) = outcome_b
  assert string.contains(decrypt_response(client, signer_b, rb), "unauthorized")
  // B への接続には A ではなく B のシークレットが必要
  let #(_engine, outcome_bc) =
    connect(engine, client, signer_b, "secret-a", 1002)
  let assert Reply(rbc) = outcome_bc
  assert string.contains(
    decrypt_response(client, signer_b, rbc),
    "invalid secret",
  )
}

/// `logout` は認可を破棄するため、以降のリクエストは拒否される。
pub fn logout_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let #(engine, _) =
    handle(
      engine,
      request_event(
        client,
        signer,
        "{\"id\":\"l1\",\"method\":\"logout\"}",
        1001,
      ),
      1001,
    )
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 1002), 1002)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unauthorized",
  )
}

/// `connect` に成功したクライアントはセッション一覧に現れる。まだ誰も接続して
/// いなければ一覧は空。
pub fn sessions_lists_connected_clients_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  assert engine.sessions(new_engine()) == []

  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  assert engine.sessions(engine)
    == [engine.Session(signer: signer.pubkey_hex, client: client.pubkey_hex)]
}

/// 一覧は署名者・クライアントの順に並ぶため、集合の走査順に左右されない。
pub fn sessions_are_sorted_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let other = account_for(other_client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let #(engine, _) = connect(engine, other, signer, secret, 1001)
  let sorted =
    [client.pubkey_hex, other.pubkey_hex]
    |> list.sort(string.compare)
    |> list.map(fn(client) {
      engine.Session(signer: signer.pubkey_hex, client: client)
    })
  assert engine.sessions(engine) == sorted
}

/// 取り消されたクライアントは一覧から消え、以降のリクエストは拒否される。
pub fn revoke_removes_the_session_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let engine = engine.revoke(engine, signer.pubkey_hex, client.pubkey_hex)
  assert engine.sessions(engine) == []

  let body = "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"{}\"]}"
  let #(_engine, outcome) =
    handle(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unauthorized",
  )
}

/// 承認されていない組の取り消しは、他のセッションに影響しない。
pub fn revoke_of_an_unknown_session_is_harmless_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let other = account_for(other_client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let engine = engine.revoke(engine, signer.pubkey_hex, other.pubkey_hex)
  assert engine.sessions(engine)
    == [engine.Session(signer: signer.pubkey_hex, client: client.pubkey_hex)]
}

/// シークレット無しの `connect`（nostr-tools は空文字列を送る）には、承認ページ
/// の URL を載せた auth_url 応答を返し、承認待ちを 1 件作る。
pub fn connect_without_secret_asks_for_approval_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, outcome) = connect(auth_engine(), client, signer, "", 1000)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"auth_url\",\"error\":\""
    <> auth_base
    <> "/approve/"
    <> token
    <> "\"}"
  assert engine.pending(state, 1000)
    == [
      engine.Pending(
        token: token,
        signer: signer.pubkey_hex,
        client: client.pubkey_hex,
        request_id: "c1",
        created_at: 1000,
      ),
    ]
  // 承認するまでは認可されない
  assert engine.sessions(state) == []
}

/// シークレットが違う `connect` も、管理 UI が有効なら承認フローに載る。
pub fn connect_with_a_wrong_secret_asks_for_approval_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(_state, outcome) = connect(auth_engine(), client, signer, "wrong", 1000)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "\"result\":\"auth_url\"",
  )
}

/// 管理 UI が無効なら、シークレット無しの `connect` は従来どおり拒否する。
pub fn connect_without_secret_is_rejected_without_the_admin_ui_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, outcome) = connect(new_engine(), client, signer, "", 1000)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "invalid secret",
  )
  assert engine.pending(state, 1000) == []
}

/// シークレットが一致する `connect` は、承認を挟まずその場で ack になる。
pub fn connect_with_the_secret_skips_approval_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, outcome) = connect(auth_engine(), client, signer, secret, 1000)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
  assert engine.pending(state, 1000) == []
}

/// 承認すると、元の `connect` と同じ id で ack を返し、以降は署名を代理できる。
pub fn approve_answers_the_original_request_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(auth_engine(), client, signer, "", 1000)
  let assert Ok(#(state, ack)) = engine.approve(state, token, 1001)
  // 応答は通常の応答と同じくクライアント宛の署名済みイベント
  assert ack.kind == 24_133
  assert ack.tags == [["p", client.pubkey_hex]]
  assert ack.pubkey == signer.pubkey_hex
  assert event.verify_signature(ack)
  assert decrypt_response(client, signer, ack)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
  assert engine.sessions(state)
    == [engine.Session(signer: signer.pubkey_hex, client: client.pubkey_hex)]
  assert engine.pending(state, 1001) == []

  let draft = "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1002), 1002)
  let assert Reply(response) = outcome
  let assert Ok(signed) =
    parse_result_event(decrypt_response(client, signer, response))
  assert signed.pubkey == signer.pubkey_hex
}

/// 拒否すると、元の `connect` と同じ id でエラーを返し、認可はされない。
pub fn deny_answers_the_original_request_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(auth_engine(), client, signer, "", 1000)
  let assert Ok(#(state, denied)) = engine.deny(state, token, 1001)
  assert decrypt_response(client, signer, denied)
    == "{\"id\":\"c1\",\"result\":\"\",\"error\":\"connection denied\"}"
  assert engine.sessions(state) == []
  assert engine.pending(state, 1001) == []

  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1002), 1002)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unauthorized",
  )
}

/// 一度承認した組は、シークレット無しで `connect` し直しても即 ack になる。
/// クライアントの再読み込みのたびに承認を求めない。
pub fn approved_client_can_reconnect_without_a_secret_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(auth_engine(), client, signer, "", 1000)
  let assert Ok(#(state, _ack)) = engine.approve(state, token, 1001)
  let #(state, outcome) = connect(state, client, signer, "", 1002)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
  assert engine.pending(state, 1002) == []
}

/// 失効した承認待ちは承認も拒否もできず、一覧にも出ない。
pub fn expired_approval_request_is_gone_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(auth_engine(), client, signer, "", 1000)
  let expired = 1000 + 601
  assert engine.pending(state, expired) == []
  let assert Error(_) = engine.approve(state, token, expired)
  let assert Error(_) = engine.deny(state, token, expired)
}

/// 知らない token の承認・拒否はエラーになる。
pub fn unknown_token_cannot_be_decided_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(auth_engine(), client, signer, "", 1000)
  let assert Error(_) = engine.approve(state, "other-token", 1001)
  let assert Error(_) = engine.deny(state, "other-token", 1001)
  // 同じ token を二度は使えない
  let assert Ok(#(state, _ack)) = engine.approve(state, token, 1001)
  let assert Error(_) = engine.approve(state, token, 1001)
}

// --- ヘルパー ---

/// 末尾 1 文字だけを変えた同じ 16 進文字列。
fn flip_last_hex(hex: String) -> String {
  let head = string.drop_end(hex, 1)
  let last = string.slice(hex, string.length(hex) - 1, 1)
  let replacement = case last {
    "0" -> "1"
    _ -> "0"
  }
  head <> replacement
}

/// JSON-RPC 応答の "result" フィールド用のデコーダー。
fn result_decoder() -> decode.Decoder(String) {
  use result <- decode.field("result", decode.string)
  decode.success(result)
}

/// 応答 JSON から "result" フィールドの文字列値を取り出す。
fn extract_result(response_json: String) -> String {
  let assert Ok(value) = json.parse(response_json, result_decoder())
  value
}

/// `sign_event` が JSON 文字列として返すイベントをパースする。
fn parse_result_event(response_json: String) -> Result(Event, Nil) {
  case json.parse(response_json, result_decoder()) {
    Ok(event_json) ->
      case json.parse(event_json, event.decoder()) {
        Ok(signed) -> Ok(signed)
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}
