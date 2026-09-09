import gleam/dynamic/decode
import gleam/json
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/engine.{Duplicate, Ignore, Reply}
import nostr_no_su/crypto/nip44
import nostr_no_su/nostr/event.{type Event, Event}

const secret = "s3cr3t-token"

const signer_key = "0000000000000000000000000000000000000000000000000000000000000042"

const client_key = "0000000000000000000000000000000000000000000000000000000000000009"

const other_client_key = "0000000000000000000000000000000000000000000000000000000000000005"

fn account_for(key_hex: String) -> Account {
  let assert Ok(account) = account.from_hex(key_hex)
  account
}

fn new_engine() -> engine.Engine {
  engine.new([#(account_for(signer_key), secret)])
}

/// Build a request event exactly as a real client would: NIP-44 encrypt the
/// JSON-RPC body to the signer, then sign the kind-24133 event.
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
  engine.handle_event(engine, request_event(client, signer, body, now), now)
}

pub fn connect_ack_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(_engine, outcome) = connect(new_engine(), client, signer, secret, 1000)
  let assert Reply(response) = outcome
  // response is addressed back to the client and is itself a valid event
  assert response.kind == 24_133
  assert response.tags == [["p", client.pubkey_hex]]
  assert response.pubkey == signer.pubkey_hex
  assert event.verify_signature(response)
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"c1\",\"result\":\"ack\"}"
}

pub fn connect_wrong_secret_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, outcome) = connect(new_engine(), client, signer, "wrong", 1000)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "invalid secret",
  )
  // still unauthorized afterwards
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_engine, outcome2) =
    engine.handle_event(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(r2) = outcome2
  assert string.contains(decrypt_response(client, signer, r2), "unauthorized")
}

pub fn get_public_key_requires_connect_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_engine, outcome) =
    engine.handle_event(
      new_engine(),
      request_event(client, signer, body, 1000),
      1000,
    )
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unauthorized",
  )
}

pub fn get_public_key_after_connect_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"g1\",\"method\":\"get_public_key\"}"
  let #(_engine, outcome) =
    engine.handle_event(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"g1\",\"result\":\"" <> signer.pubkey_hex <> "\"}"
}

pub fn ping_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"p1\",\"method\":\"ping\"}"
  let #(_engine, outcome) =
    engine.handle_event(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert decrypt_response(client, signer, response)
    == "{\"id\":\"p1\",\"result\":\"pong\"}"
}

pub fn sign_event_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft =
    "{\\\"kind\\\":1,\\\"content\\\":\\\"hello\\\",\\\"tags\\\":[],\\\"created_at\\\":1700000123}"
  let body =
    "{\"id\":\"s1\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_engine, outcome) =
    engine.handle_event(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  let result = decrypt_response(client, signer, response)
  // The result field is a JSON-string-encoded signed event. Extract and parse.
  let assert Ok(signed) = parse_result_event(result)
  assert signed.pubkey == signer.pubkey_hex
  assert signed.kind == 1
  assert signed.content == "hello"
  assert signed.created_at == 1_700_000_123
  assert signed.id == event.compute_id(signed)
  assert event.verify_signature(signed)
}

pub fn sign_event_fills_created_at_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let draft = "{\\\"kind\\\":1,\\\"content\\\":\\\"hi\\\"}"
  let body =
    "{\"id\":\"s2\",\"method\":\"sign_event\",\"params\":[\"" <> draft <> "\"]}"
  let #(_engine, outcome) =
    engine.handle_event(engine, request_event(client, signer, body, 2000), 2000)
  let assert Reply(response) = outcome
  let assert Ok(signed) =
    parse_result_event(decrypt_response(client, signer, response))
  assert signed.created_at == 2000
}

pub fn stale_event_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let body = "{\"id\":\"x\",\"method\":\"ping\"}"
  // event created an hour before "now"
  let #(_engine, outcome) =
    engine.handle_event(
      new_engine(),
      request_event(client, signer, body, 1000),
      4600,
    )
  let assert Ignore(_) = outcome
}

/// The same request delivered twice is handled once and reported as a
/// duplicate, which is what a second bunker relay produces.
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
  let #(engine, first) = engine.handle_event(new_engine(), request, 1000)
  let assert Reply(_) = first
  let #(_engine, second) = engine.handle_event(engine, request, 1000)
  let assert Duplicate = second
}

pub fn tampered_signature_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let request =
    request_event(client, signer, "{\"id\":\"x\",\"method\":\"ping\"}", 1000)
  let tampered = Event(..request, sig: flip_last_hex(request.sig))
  let #(_engine, outcome) = engine.handle_event(new_engine(), tampered, 1000)
  let assert Ignore(reason) = outcome
  assert string.contains(reason, "signature")
}

pub fn undecryptable_content_ignored_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  // content encrypted to a DIFFERENT signer than the one we route to
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
  let #(_engine, outcome) = engine.handle_event(new_engine(), request, 1000)
  let assert Ignore(_) = outcome
}

pub fn unknown_method_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body = "{\"id\":\"u1\",\"method\":\"do_the_thing\"}"
  let #(_engine, outcome) =
    engine.handle_event(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unsupported method",
  )
}

pub fn nip04_stubbed_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let body =
    "{\"id\":\"n1\",\"method\":\"nip04_encrypt\",\"params\":[\"pk\",\"text\"]}"
  let #(_engine, outcome) =
    engine.handle_event(engine, request_event(client, signer, body, 1001), 1001)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "nip04 is not supported",
  )
}

pub fn nip44_roundtrip_via_engine_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let third_party = account_for(other_client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  // encrypt "secret msg" to third_party via the signer
  let enc_body =
    "{\"id\":\"e1\",\"method\":\"nip44_encrypt\",\"params\":[\""
    <> third_party.pubkey_hex
    <> "\",\"secret msg\"]}"
  let #(engine, enc_outcome) =
    engine.handle_event(
      engine,
      request_event(client, signer, enc_body, 1001),
      1001,
    )
  let assert Reply(enc_response) = enc_outcome
  let payload = extract_result(decrypt_response(client, signer, enc_response))
  // third_party decrypts it directly to confirm interop
  let assert Ok(tp_key) =
    nip44.conversation_key(third_party.privkey, signer.pubkey)
  let assert Ok(plain) = nip44.decrypt(payload, tp_key)
  assert plain == "secret msg"
  // and the engine can decrypt it back
  let dec_body =
    "{\"id\":\"d1\",\"method\":\"nip44_decrypt\",\"params\":[\""
    <> third_party.pubkey_hex
    <> "\",\""
    <> payload
    <> "\"]}"
  let #(_engine, dec_outcome) =
    engine.handle_event(
      engine,
      request_event(client, signer, dec_body, 1002),
      1002,
    )
  let assert Reply(dec_response) = dec_outcome
  assert extract_result(decrypt_response(client, signer, dec_response))
    == "secret msg"
}

pub fn multi_account_isolation_test() {
  let signer_a = account_for(signer_key)
  let signer_b = account_for(other_client_key)
  let client = account_for(client_key)
  let engine = engine.new([#(signer_a, "secret-a"), #(signer_b, "secret-b")])
  // authorize on A
  let #(engine, _) = connect(engine, client, signer_a, "secret-a", 1000)
  // request to B is unauthorized (auth is per-signer)
  let body = "{\"id\":\"g\",\"method\":\"get_public_key\"}"
  let #(engine, outcome_b) =
    engine.handle_event(
      engine,
      request_event(client, signer_b, body, 1001),
      1001,
    )
  let assert Reply(rb) = outcome_b
  assert string.contains(decrypt_response(client, signer_b, rb), "unauthorized")
  // connecting to B needs B's secret, not A's
  let #(_engine, outcome_bc) =
    connect(engine, client, signer_b, "secret-a", 1002)
  let assert Reply(rbc) = outcome_bc
  assert string.contains(
    decrypt_response(client, signer_b, rbc),
    "invalid secret",
  )
}

pub fn logout_test() {
  let signer = account_for(signer_key)
  let client = account_for(client_key)
  let #(engine, _) = connect(new_engine(), client, signer, secret, 1000)
  let #(engine, _) =
    engine.handle_event(
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
    engine.handle_event(engine, request_event(client, signer, body, 1002), 1002)
  let assert Reply(response) = outcome
  assert string.contains(
    decrypt_response(client, signer, response),
    "unauthorized",
  )
}

// --- helpers ---

fn flip_last_hex(hex: String) -> String {
  let head = string.drop_end(hex, 1)
  let last = string.slice(hex, string.length(hex) - 1, 1)
  let replacement = case last {
    "0" -> "1"
    _ -> "0"
  }
  head <> replacement
}

fn result_decoder() -> decode.Decoder(String) {
  use result <- decode.field("result", decode.string)
  decode.success(result)
}

/// Pull the string value of the "result" field out of a response JSON.
fn extract_result(response_json: String) -> String {
  let assert Ok(value) = json.parse(response_json, result_decoder())
  value
}

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
