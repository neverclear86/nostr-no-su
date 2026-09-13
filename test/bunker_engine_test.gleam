import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine.{Duplicate, Ignore, Reply}
import nostr_no_su/crypto/nip44
import nostr_no_su/nostr/event.{type Event, Event}
import support/nip46_client.{
  account_for, connect_body, decrypt_response, request_event,
}
import support/signed_event

const secret = "s3cr3t-token"

const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

const other_client_key = "0000000000000000000000000000000000000000000000000000000000000005"

/// 2 人目の署名者の鍵。
const other_signer_key = "0000000000000000000000000000000000000000000000000000000000000077"

/// 承認ページを載せる管理 UI の公開 URL。
const auth_base = "http://admin.test"

/// 承認待ちのトークン。アクターが引く乱数の代わりにテストから注入する。
const token = "tok-1"

/// テスト用の署名者 1 件とテスト用シークレットを扱うエンジン。管理 UI が無効な
/// 構成なので、シークレットの一致しない `connect` は拒否される。
fn new_engine() -> engine.Engine {
  engine.new([#(account_for(signer_key), secret)], None)
}

/// 承認フロー（auth_url）を有効にしたエンジン。承認ページの URL の組み立ては
/// 本番と同じく外から注入する。
fn auth_engine() -> engine.Engine {
  engine.new([#(account_for(signer_key), secret)], Some(approval_url))
}

/// 承認待ちの token に対応する承認ページの URL。
fn approval_url(token: String) -> String {
  auth_base <> "/approve/" <> token
}

/// 受信イベントを 1 件処理する。トークンは固定なので、承認ページの URL も
/// テストから予測できる。アクターの起点は、起点そのものを見るテスト以外では
/// 判定に効かないよう 0 にする。
fn handle(
  state: engine.Engine,
  incoming: Event,
  now: Int,
) -> #(engine.Engine, engine.Outcome) {
  handle_after(state, incoming, now, 0)
}

/// 指定した起点のアクターが受信イベントを 1 件処理する。
fn handle_after(
  state: engine.Engine,
  incoming: Event,
  now: Int,
  not_before: Int,
) -> #(engine.Engine, engine.Outcome) {
  engine.handle_event(
    state,
    signed_event.verified(incoming),
    engine.Inputs(now: now, token: token, not_before: not_before),
  )
}

/// 指定したクライアントから署名者宛の `connect` リクエストイベント。
fn connect_event(
  client: Account,
  signer: Account,
  secret_arg: String,
  created_at: Int,
) -> Event {
  request_event(
    client,
    signer,
    connect_body(signer, secret_arg, "c1"),
    created_at,
  )
}

/// 指定した署名者とシークレットで `connect` リクエストを送る。
fn connect(
  state: engine.Engine,
  client: Account,
  signer: Account,
  secret_arg: String,
  now: Int,
) -> #(engine.Engine, engine.Outcome) {
  handle(state, connect_event(client, signer, secret_arg, now), now)
}

/// 正しいシークレットには、クライアント宛の署名済み応答で ack を返す。
pub fn connect_ack_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(_state, outcome) = connect(new_engine(), client, signer, secret, 1000)
  let assert Reply(response) = outcome
  // 応答はクライアント宛であり、それ自体が正当なイベントである
  assert response.kind == event.nip46_kind
  assert response.tags == [["p", account.pubkey_hex(client)]]
  assert response.pubkey == account.pubkey_hex(signer)
  assert event.verify_signature(response)
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
}

/// 誤ったシークレットは拒否され、クライアントは未認可のままになる。
pub fn connect_wrong_secret_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, outcome) = connect(new_engine(), client, signer, "wrong", 1000)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "invalid secret",
  )
  // その後も未認可のまま
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_state, outcome2) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(r2) = outcome2
  assert string.contains(decrypt_response(client, signer, r2), "unauthorized")
}

/// `connect` より前に送られたリクエストは未認可として拒否される。
pub fn get_public_key_requires_connect_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_state, outcome) =
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
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"g1\",\"result\":\"" <> account.pubkey_hex(signer) <> "\"}"
}

/// `ping` には "pong" を返す。
pub fn ping_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"p1\",\"method\":\"ping\"}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"p1\",\"result\":\"pong\"}"
}

/// `sign_event` は正しい id と署名を持つイベントを返す。ドラフトが署名者自身の
/// pubkey を指していても、一致するので通る。
pub fn sign_event_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft =
    "{\\\"kind\\\":1,\\\"content\\\":\\\"hello\\\",\\\"tags\\\":[],\\\"created_at\\\":1700000123,\\\"pubkey\\\":\\\""
    <> account.pubkey_hex(signer)
    <> "\\\"}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  let result = decrypt_response(client, signer, response)
  // result フィールドは JSON 文字列として符号化された署名済みイベントなので、
  // 取り出してパースする。
  let assert Ok(signed) = parse_result_event(result)
  assert signed.pubkey == account.pubkey_hex(signer)
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
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft = "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}"
  let body =
    "{\"id\":\"s2\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 2000), 2000)
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
  let #(_state, outcome) =
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
        <> account.pubkey_hex(signer)
        <> "\",\""
        <> secret
        <> "\"]}",
      1000,
    )
  let #(state, first) = handle(new_engine(), request, 1000)
  let assert Reply(_) = first
  let #(_state, second) = handle(state, request, 1000)
  let assert Duplicate = second
}

/// p タグが複数あっても、既知のアカウントに一致するものへルーティングする。
/// 先頭が別人宛でも、自分宛のタグがあれば処理する。
pub fn routes_to_the_matching_p_tag_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let stranger = account_for(other_client_key)
  let request =
    nip46_client.request_event_with_tags(
      client,
      signer,
      connect_body(signer, secret, "c1"),
      [["p", account.pubkey_hex(stranger)], ["p", account.pubkey_hex(signer)]],
      1000,
    )
  let #(_state, outcome) = handle(new_engine(), request, 1000)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
}

/// どの p タグも既知のアカウントに一致しなければ、理由を添えて無視する。
pub fn unknown_p_tags_are_ignored_test() {
  let client = account_for(client_key)
  let stranger = account_for(other_client_key)
  let request =
    nip46_client.request_event_with_tags(
      client,
      stranger,
      connect_body(stranger, secret, "c1"),
      [["p", account.pubkey_hex(stranger)]],
      1000,
    )
  let #(_state, outcome) = handle(new_engine(), request, 1000)
  let assert Ignore(reason) = outcome
  assert string.contains(reason, "no matching account")
  assert string.contains(reason, account.pubkey_hex(stranger))
}

/// 別の署名者宛に暗号化された content は読めないため無視される。
pub fn undecryptable_content_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  // ルーティング先とは異なる署名者宛に暗号化した content
  let wrong_signer = account_for(other_client_key)
  let request =
    nip46_client.request_event_with_tags(
      client,
      wrong_signer,
      "{\"id\":\"x\"}",
      [["p", account.pubkey_hex(signer)]],
      1000,
    )
  let #(_state, outcome) = handle(new_engine(), request, 1000)
  let assert Ignore(_) = outcome
}

/// 未知のメソッドはクラッシュではなくエラー応答で返す。
pub fn unknown_method_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"u1\",\"method\":\"do_the_thing\"}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
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
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let body =
    "{\"id\":\"n1\",\"method\":\"nip04_encrypt\",\"params\":[\"pk\",\"text\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
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
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  // 署名者を介して "secret msg" を third_party 宛に暗号化する
  let enc_body =
    "{\"id\":\"e1\",\"method\":\"nip44_encrypt\",\"params\":[\""
    <> account.pubkey_hex(third_party)
    <> "\",\"secret msg\"]}"
  let #(state, enc_outcome) =
    handle(state, request_event(client, signer, enc_body, 1001), 1001)
  let assert Reply(enc_response) = enc_outcome
  let payload = extract_result(decrypt_response(client, signer, enc_response))
  // 相互運用性を確認するため third_party が直接復号する
  let assert Ok(tp_key) =
    nip44.conversation_key(account.privkey(third_party), account.pubkey(signer))
  let assert Ok(plain) = nip44.decrypt(payload, tp_key)
  assert plain == "secret msg"
  // エンジン側でも復号して元に戻せる
  let dec_body =
    "{\"id\":\"d1\",\"method\":\"nip44_decrypt\",\"params\":[\""
    <> account.pubkey_hex(third_party)
    <> "\",\""
    <> payload
    <> "\"]}"
  let #(_state, dec_outcome) =
    handle(state, request_event(client, signer, dec_body, 1002), 1002)
  let assert Reply(dec_response) = dec_outcome
  assert extract_result(decrypt_response(client, signer, dec_response))
    == "secret msg"
}

/// 認可とシークレットは署名者ごとに独立し、署名者間で共有されない。
pub fn multi_account_isolation_test() {
  let signer_a = account_for(signer_key)
  let signer_b = account_for(other_client_key)
  let client = account_for(client_key)
  let state =
    engine.new([#(signer_a, "secret-a"), #(signer_b, "secret-b")], None)
  // A で認可を得る
  let #(state, _) = connect(state, client, signer_a, "secret-a", 1000)
  // B へのリクエストは未認可（認可は署名者ごと）
  let body = "{\"id\":\"g\",\"method\":\"get_public_key\"}"
  let #(state, outcome_b) =
    handle(state, request_event(client, signer_b, body, 1001), 1001)
  let assert Reply(rb) = outcome_b
  assert string.contains(decrypt_response(client, signer_b, rb), "unauthorized")
  // B への接続には A ではなく B のシークレットが必要
  let #(_state, outcome_bc) = connect(state, client, signer_b, "secret-a", 1002)
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
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let #(state, _) =
    handle(
      state,
      request_event(
        client,
        signer,
        "{\"id\":\"l1\",\"method\":\"logout\"}",
        1001,
      ),
      1001,
    )
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1002), 1002)
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

  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  assert engine.sessions(state)
    == [
      engine.Session(
        signer: account.pubkey_hex(signer),
        client: account.pubkey_hex(client),
      ),
    ]
}

/// 一覧は署名者・クライアントの順に並ぶため、集合の走査順に左右されない。
pub fn sessions_are_sorted_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let other = account_for(other_client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let #(state, _) = connect(state, other, signer, secret, 1001)
  let sorted =
    [account.pubkey_hex(client), account.pubkey_hex(other)]
    |> list.sort(string.compare)
    |> list.map(fn(client) {
      engine.Session(signer: account.pubkey_hex(signer), client: client)
    })
  assert engine.sessions(state) == sorted
}

/// 取り消されたクライアントは一覧から消え、以降のリクエストは拒否される。
pub fn revoke_removes_the_session_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let assert Ok(state) =
    engine.revoke(state, account.pubkey_hex(signer), account.pubkey_hex(client))
  assert engine.sessions(state) == []

  let body = "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"{}\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unauthorized",
  )
}

/// 承認されていない組の取り消しは `Error(Nil)` になる。取り消し済みの組も同じ。
pub fn revoke_of_an_unknown_session_is_an_error_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let other = account_for(other_client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  assert engine.revoke(
      state,
      account.pubkey_hex(signer),
      account.pubkey_hex(other),
    )
    == Error(Nil)

  let assert Ok(state) =
    engine.revoke(state, account.pubkey_hex(signer), account.pubkey_hex(client))
  assert engine.revoke(
      state,
      account.pubkey_hex(signer),
      account.pubkey_hex(client),
    )
    == Error(Nil)
}

/// 承認されていないクライアントの `logout` も ack を返し、他のセッションを残す。
/// NIP-46 との相互運用のための挙動を固定する（`execute` の Doc コメントを参照）。
pub fn logout_without_a_session_is_acknowledged_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let other = account_for(other_client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let #(state, outcome) =
    handle(
      state,
      request_event(
        other,
        signer,
        "{\"id\":\"l1\",\"method\":\"logout\"}",
        1001,
      ),
      1001,
    )
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(other, signer, response),
    "\"result\":\"ack\"",
  )
  assert engine.sessions(state)
    == [
      engine.Session(
        signer: account.pubkey_hex(signer),
        client: account.pubkey_hex(client),
      ),
    ]
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
    <> approval_url(token)
    <> "\"}"
  assert engine.pending(state, 1000)
    == [
      engine.Pending(
        token: token,
        signer: account.pubkey_hex(signer),
        client: account.pubkey_hex(client),
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
  assert ack.kind == event.nip46_kind
  assert ack.tags == [["p", account.pubkey_hex(client)]]
  assert ack.pubkey == account.pubkey_hex(signer)
  assert event.verify_signature(ack)
  assert decrypt_response(client, signer, ack)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
  assert engine.sessions(state)
    == [
      engine.Session(
        signer: account.pubkey_hex(signer),
        client: account.pubkey_hex(client),
      ),
    ]
  assert engine.pending(state, 1001) == []

  let draft = "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1002), 1002)
  let assert Reply(response) = outcome
  let assert Ok(signed) =
    parse_result_event(decrypt_response(client, signer, response))
  assert signed.pubkey == account.pubkey_hex(signer)
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

/// 承認前にクライアントが `connect` を送り直しても、承認待ちは 1 件のままで、
/// 承認は最新のリクエスト id に応答する。古い id に応答すると、再読み込み後の
/// クライアントは応答を受け取れない。
pub fn reconnecting_before_approval_replaces_the_request_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(auth_engine(), client, signer, "", 1000)
  let #(state, outcome) =
    engine.handle_event(
      state,
      signed_event.verified(request_event(
        client,
        signer,
        connect_body(signer, "", "c2"),
        1001,
      )),
      engine.Inputs(now: 1001, token: "tok-2", not_before: 0),
    )
  let assert Reply(_) = outcome
  let assert [entry] = engine.pending(state, 1001)
  assert entry.token == "tok-2"

  let assert Error(_) = engine.approve(state, token, 1001)
  let assert Ok(#(state, ack)) = engine.approve(state, "tok-2", 1002)
  assert decrypt_response(client, signer, ack)
    == "{\"id\":\"c2\",\"result\":\"ack\"}"
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

/// 古いクライアントが送る `[secret]` だけの params でも接続できる。
pub fn connect_with_a_bare_secret_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body =
    "{\"id\":\"c1\",\"method\":\"connect\",\"params\":[\"" <> secret <> "\"]}"
  let #(_state, outcome) =
    handle(new_engine(), request_event(client, signer, body, 1000), 1000)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
}

/// NIP-04 のペイロード（`?iv=` を含む）は形式で見分けがつくため、未対応である
/// ことが分かる理由を添えて無視する。
pub fn nip04_payload_is_reported_as_unsupported_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let unsigned =
    Event(
      id: "",
      pubkey: account.pubkey_hex(client),
      created_at: 1000,
      kind: event.nip46_kind,
      tags: [["p", account.pubkey_hex(signer)]],
      content: "3v0dEBmi5FI=?iv=Xk7z3RQ0ZQ4vJn1p2sTgHQ==",
      sig: "",
    )
  let assert Ok(request) = event.finalize(unsigned, account.privkey(client))
  let #(_state, outcome) = handle(new_engine(), request, 1000)
  let assert Ignore(reason) = outcome
  assert string.contains(reason, "nip-04")
}

/// JSON として読めないドラフトは、クラッシュではなくエラー応答で返す。
pub fn sign_event_rejects_an_invalid_draft_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"not json\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "invalid event draft",
  )
}

/// ドラフトの pubkey が別人を指していれば、署名せずにエラー応答を返す。
pub fn sign_event_rejects_a_draft_for_another_pubkey_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let other = account_for(other_signer_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft =
    "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\",\\\"pubkey\\\":\\\""
    <> account.pubkey_hex(other)
    <> "\\\"}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "event draft pubkey does not match the signer",
  )
}

/// 空文字列の pubkey を持つドラフトは、指定無しとして署名される。
pub fn sign_event_accepts_a_draft_with_an_empty_pubkey_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft =
    "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\",\\\"pubkey\\\":\\\"\\\"}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  let assert Ok(signed) =
    parse_result_event(decrypt_response(client, signer, response))
  assert signed.pubkey == account.pubkey_hex(signer)
}

/// kind 24133（バンカー自身の応答）のドラフトは、署名せずにエラー応答を返す。
pub fn sign_event_rejects_a_nip46_kind_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft = "{\\\"kind\\\":24133,\\\"content\\\":\\\"hi\\\"}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "refusing to sign a kind 24133 event",
  )
}

/// 正しい secret でも、別の署名者を指した `connect` は状態を変えずに拒否する。
pub fn connect_to_another_signer_is_rejected_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let other = account_for(other_signer_key)
  let request =
    request_event(client, signer, connect_body(other, secret, "c1"), 1000)
  let #(state, outcome) = handle(auth_engine(), request, 1000)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "connect is addressed to another signer",
  )
  assert engine.sessions(state) == []
  assert engine.pending(state, 1000) == []
}

/// params[0] が空文字列の `connect` は「指定無し」として扱われ、通る。
pub fn connect_with_an_empty_signer_param_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body =
    "{\"id\":\"c1\",\"method\":\"connect\",\"params\":[\"\",\""
    <> secret
    <> "\"]}"
  let #(state, outcome) =
    handle(new_engine(), request_event(client, signer, body, 1000), 1000)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
  assert engine.sessions(state)
    == [
      engine.Session(
        signer: account.pubkey_hex(signer),
        client: account.pubkey_hex(client),
      ),
    ]
}

/// 16 進として読めない相手 pubkey には、エラー応答を返す。
pub fn nip44_rejects_an_invalid_third_party_pubkey_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let body =
    "{\"id\":\"e1\",\"method\":\"nip44_encrypt\",\"params\":[\"zz\",\"hi\"]}"
  let #(_state, outcome) =
    handle(state, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "invalid third-party pubkey",
  )
}

// --- ヘルパー ---

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

/// アクターの起点より古いリクエストは実行しない。アクターが再起動すると `seen`
/// が空になるため、記憶していない処理済みのリクエストを新規として実行しないよう
/// に落とす。
pub fn requests_before_the_actor_started_are_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let request = connect_event(client, signer, secret, 999)
  let #(state, outcome) = handle_after(new_engine(), request, 1000, 1000)
  assert outcome == Ignore("request predates this bunker instance")
  assert engine.sessions(state) == []
}

/// 起点と同じ秒のリクエストは実行する。判定は秒単位なので、起動直後に届いた正当な
/// リクエストまで落とすと、クライアントは応答を待ったまま失敗する。
pub fn requests_at_the_actor_start_are_handled_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let request = connect_event(client, signer, secret, 1000)
  let #(state, outcome) = handle_after(new_engine(), request, 1000, 1000)
  let assert Reply(_) = outcome
  assert engine.sessions(state) != []
}

/// 起点より後のリクエストは、現在時刻から離れていても実行する。切断していた間に
/// 届いたリクエストは、再接続後にこの経路で処理される。
pub fn requests_after_the_actor_started_are_handled_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let request = connect_event(client, signer, secret, 1001)
  let #(state, outcome) = handle_after(new_engine(), request, 1030, 1000)
  let assert Reply(_) = outcome
  assert engine.sessions(state) != []
}

/// 未来側の受付幅は 60 秒で、それを 1 秒でも超えたリクエストは捨てる。
pub fn the_future_side_of_the_window_ends_after_a_minute_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(_state, accepted) =
    handle(new_engine(), connect_event(client, signer, secret, 1060), 1000)
  let assert Reply(_) = accepted
  let #(_state, rejected) =
    handle(new_engine(), connect_event(client, signer, secret, 1061), 1000)
  assert rejected == Ignore("stale or future event")
}

/// 過去側の受付幅は 600 秒のまま。
pub fn the_past_side_of_the_window_ends_after_ten_minutes_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(_state, accepted) =
    handle(new_engine(), connect_event(client, signer, secret, 400), 1000)
  let assert Reply(_) = accepted
  let #(_state, rejected) =
    handle(new_engine(), connect_event(client, signer, secret, 399), 1000)
  assert rejected == Ignore("stale or future event")
}

// --- アカウントの追加・削除・secret の差し替え ---

/// 指定したトークンで承認待ちを作る、secret 無しの `connect` を処理する。
fn connect_for_approval(
  state: engine.Engine,
  client: Account,
  signer: Account,
  approval_token: String,
  now: Int,
) -> engine.Engine {
  let #(state, outcome) =
    engine.handle_event(
      state,
      signed_event.verified(connect_event(client, signer, "", now)),
      engine.Inputs(now: now, token: approval_token, not_before: 0),
    )
  let assert Reply(_) = outcome
  state
}

/// 署名者宛の `ping` リクエスト。
fn ping_event(client: Account, signer: Account, now: Int) -> Event {
  request_event(client, signer, "{\"id\":\"p1\",\"method\":\"ping\"}", now)
}

/// 追加した署名者宛の `connect` には応答し、追加の前は破棄する。
pub fn add_account_makes_the_signer_answer_test() {
  let signer = account_for(other_signer_key)
  let client = account_for(client_key)
  let #(_state, before) =
    connect(new_engine(), client, signer, "secret-b", 1000)
  let assert Ignore(_) = before

  let state = engine.add_account(new_engine(), signer, "secret-b")
  let #(_state, after) = connect(state, client, signer, "secret-b", 1000)
  let assert Reply(response) = after
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
}

/// 削除すると、その署名者のセッションと承認待ちだけが消え、もう片方の署名者の
/// ものは残る。削除した署名者宛のリクエストは破棄する。
pub fn remove_account_drops_only_its_sessions_and_pending_test() {
  let signer_a = account_for(signer_key)
  let signer_b = account_for(other_signer_key)
  let client = account_for(client_key)
  let waiting = account_for(other_client_key)
  let state =
    engine.new([#(signer_a, secret), #(signer_b, secret)], Some(approval_url))
  let #(state, _) = connect(state, client, signer_a, secret, 1000)
  let #(state, _) = connect(state, client, signer_b, secret, 1000)
  let state = connect_for_approval(state, waiting, signer_a, "tok-a", 1000)
  let state = connect_for_approval(state, waiting, signer_b, "tok-b", 1000)

  let state = engine.remove_account(state, account.pubkey_hex(signer_a))
  assert engine.sessions(state)
    == [
      engine.Session(
        signer: account.pubkey_hex(signer_b),
        client: account.pubkey_hex(client),
      ),
    ]
  let assert [remaining] = engine.pending(state, 1000)
  assert remaining.token == "tok-b"
  let #(_state, outcome) =
    handle(state, ping_event(client, signer_a, 1001), 1001)
  let assert Ignore(_) = outcome
}

/// 削除して戻しても、削除の前に処理したリクエストの再配送は重複として扱う。
pub fn remove_and_add_keeps_the_seen_requests_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let request = connect_event(client, signer, secret, 1000)
  let #(state, first) = handle(new_engine(), request, 1000)
  let assert Reply(_) = first

  let state =
    engine.remove_account(state, account.pubkey_hex(signer))
    |> engine.add_account(signer, "new-secret")
  let #(_state, replayed) = handle(state, request, 1000)
  assert replayed == Duplicate
}

/// secret を差し替えると、古い secret の `connect` は拒否され、新しい secret の
/// `connect` が通る。差し替えの前に成立したセッションは残る。
pub fn replace_secret_rejects_the_old_secret_and_keeps_sessions_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let newcomer = account_for(other_client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let state =
    engine.replace_secret(state, account.pubkey_hex(signer), "rotated")

  let #(state, old) = connect(state, newcomer, signer, secret, 1001)
  let assert Reply(old_response) = old
  assert string.contains(
    decrypt_response(newcomer, signer, old_response),
    "invalid secret",
  )
  let #(state, new) = connect(state, newcomer, signer, "rotated", 1002)
  let assert Reply(new_response) = new
  assert decrypt_response(newcomer, signer, new_response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
  let #(_state, ping) = handle(state, ping_event(client, signer, 1003), 1003)
  let assert Reply(pong) = ping
  assert decrypt_response(client, signer, pong)
    == "{\"id\":\"p1\",\"result\":\"pong\"}"
}

/// secret を差し替えても承認待ちは残る。承認待ちは secret と無関係に作られる。
pub fn replace_secret_keeps_pending_connections_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let state = connect_for_approval(auth_engine(), client, signer, token, 1000)
  let before = engine.pending(state, 1000)
  let state =
    engine.replace_secret(state, account.pubkey_hex(signer), "rotated")
  assert before != []
  assert engine.pending(state, 1000) == before
}

/// 登録されていない署名者の削除と差し替えは、何も変えない。
pub fn changes_to_an_unregistered_signer_are_harmless_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let stranger = account.pubkey_hex(account_for(other_signer_key))
  let #(state, _) = connect(auth_engine(), client, signer, secret, 1000)
  let state =
    connect_for_approval(
      state,
      account_for(other_client_key),
      signer,
      token,
      1000,
    )
  let unchanged = fn(changed: engine.Engine) {
    engine.sessions(changed) == engine.sessions(state)
    && engine.pending(changed, 1000) == engine.pending(state, 1000)
    && secrets_by_signer(changed) == secrets_by_signer(state)
  }
  assert unchanged(engine.remove_account(state, stranger))
  assert unchanged(engine.replace_secret(state, stranger, "rotated"))
}

/// 登録済みの署名者を足し直すと secret が置き換わり、セッションは残る。
pub fn adding_a_registered_signer_replaces_its_secret_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(state, _) = connect(new_engine(), client, signer, secret, 1000)
  let state = engine.add_account(state, signer, "replaced")
  assert secrets_by_signer(state) == [#(account.pubkey_hex(signer), "replaced")]
  assert engine.sessions(state)
    == [
      engine.Session(
        signer: account.pubkey_hex(signer),
        client: account.pubkey_hex(client),
      ),
    ]
}

/// 登録済みのアカウントを、比べられる形（署名者の公開鍵と secret の組）にする。
/// `Account` は同じ鍵から作った値同士でも `==` が成り立たないため。
fn secrets_by_signer(state: engine.Engine) -> List(#(String, String)) {
  engine.registered_accounts(state)
  |> list.map(fn(entry) { #(account.pubkey_hex(entry.0), entry.1) })
}

/// 署名者の一覧と登録済みのアカウントの一覧は、登録の順ではなく署名者の昇順に並ぶ。
pub fn signers_and_registered_accounts_are_sorted_test() {
  let keys = [other_signer_key, signer_key, other_client_key]
  let state =
    engine.new(
      list.map(keys, fn(key) { #(account_for(key), "secret-" <> key) }),
      None,
    )
  let expected =
    keys
    |> list.map(fn(key) {
      #(account.pubkey_hex(account_for(key)), "secret-" <> key)
    })
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  assert secrets_by_signer(state) == expected
  assert engine.signers(state) == list.map(expected, fn(entry) { entry.0 })
}

/// 署名者のアカウントは、登録済みなら見つかり、未登録と削除の後は見つからない。
pub fn find_account_reflects_the_registered_signers_test() {
  let signer = account.pubkey_hex(account_for(signer_key))
  let stranger = account.pubkey_hex(account_for(other_signer_key))
  let assert Ok(found) = engine.find_account(new_engine(), signer)
  assert account.pubkey_hex(found) == signer
  assert engine.find_account(new_engine(), stranger) == Error(Nil)
  assert engine.find_account(
      engine.remove_account(new_engine(), signer),
      signer,
    )
    == Error(Nil)
}

/// 所属の検査は、登録済みの署名者だけを真にする。
pub fn has_account_reflects_the_registered_signers_test() {
  let signer = account.pubkey_hex(account_for(signer_key))
  let stranger = account.pubkey_hex(account_for(other_signer_key))
  assert engine.has_account(new_engine(), signer)
  assert !engine.has_account(new_engine(), stranger)
  assert !engine.has_account(
    engine.remove_account(new_engine(), signer),
    signer,
  )
}
