//// The pure NIP-46 request-handling core. No processes, no clock, no IO: the
//// current time is passed in, so every path is deterministic and unit-tested
//// through the loopback test. `bunker.gleam` wraps this in an actor.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/rpc
import nostr_no_su/crypto/nip44
import nostr_no_su/nostr/event.{type Event, Event}

/// Accept requests within this many seconds of now, in either direction, to
/// tolerate client clock skew.
const window_seconds = 600

pub type Engine {
  Engine(
    // signer pubkey hex -> #(account, secret)
    accounts: Dict(String, #(Account, String)),
    // #(signer pubkey hex, client pubkey hex)
    authorized: Set(#(String, String)),
    // request event id -> created_at, for replay protection
    seen: Dict(String, Int),
  )
}

pub type Outcome {
  /// The response event to publish back to the client.
  Reply(response: Event)
  /// A request already handled, e.g. the same one delivered by a second
  /// bunker relay. Expected in a multi-relay setup, so callers stay quiet.
  Duplicate
  /// The request was dropped, with the reason for the log.
  Ignore(reason: String)
}

/// An engine serving the given accounts, each with its connect secret.
pub fn new(accounts: List(#(Account, String))) -> Engine {
  let account_dict =
    accounts
    |> list.map(fn(pair) { #({ pair.0 }.pubkey_hex, pair) })
    |> dict.from_list
  Engine(accounts: account_dict, authorized: set.new(), seen: dict.new())
}

/// Handle one received event: validate, deduplicate and route it, then
/// produce the response to publish, if any.
pub fn handle_event(
  engine: Engine,
  incoming: Event,
  now: Int,
) -> #(Engine, Outcome) {
  case incoming.kind == 24_133 {
    False -> #(engine, Ignore("not a nip-46 request"))
    True ->
      case fresh(incoming.created_at, now) {
        False -> #(engine, Ignore("stale or future event"))
        True ->
          case route(engine, incoming.tags) {
            Error(reason) -> #(engine, Ignore(reason))
            Ok(#(account, secret)) ->
              case dict.has_key(engine.seen, incoming.id) {
                True -> #(engine, Duplicate)
                False -> {
                  let engine = record_seen(engine, incoming, now)
                  case event.verify_signature(incoming) {
                    False -> #(engine, Ignore("invalid signature"))
                    True ->
                      handle_request(engine, account, secret, incoming, now)
                  }
                }
              }
          }
      }
  }
}

/// Whether the timestamp is inside the acceptance window around now.
fn fresh(created_at: Int, now: Int) -> Bool {
  created_at >= now - window_seconds && created_at <= now + window_seconds
}

/// Route on the first ["p", pubkey] tag that names a known account.
fn route(
  engine: Engine,
  tags: List(List(String)),
) -> Result(#(Account, String), String) {
  case first_p_tag(tags) {
    None -> Error("no p tag")
    Some(pubkey) ->
      case dict.get(engine.accounts, pubkey) {
        Ok(pair) -> Ok(pair)
        Error(_) -> Error("no matching account for " <> pubkey)
      }
  }
}

/// The pubkey of the first ["p", pubkey] tag, if there is one.
fn first_p_tag(tags: List(List(String))) -> Option(String) {
  case tags {
    [] -> None
    [["p", pubkey, ..], ..] -> Some(pubkey)
    [_, ..rest] -> first_p_tag(rest)
  }
}

/// Remember the request id for replay protection, forgetting the ids
/// that can no longer be replayed.
fn record_seen(engine: Engine, incoming: Event, now: Int) -> Engine {
  let seen =
    engine.seen
    |> dict.insert(incoming.id, incoming.created_at)
    // Drop entries older than the acceptance window: they can never be
    // replayed anyway, which keeps the set bounded.
    |> dict.filter(fn(_id, created_at) { created_at >= now - window_seconds })
  Engine(..engine, seen: seen)
}

/// Decrypt and decode the request, then build the encrypted reply.
fn handle_request(
  engine: Engine,
  account: Account,
  secret: String,
  incoming: Event,
  now: Int,
) -> #(Engine, Outcome) {
  let client_pk_hex = incoming.pubkey
  case decode_hex(client_pk_hex) {
    Error(_) -> #(engine, Ignore("invalid client pubkey"))
    Ok(client_pk_bytes) ->
      case nip44.conversation_key(account.privkey, client_pk_bytes) {
        Error(_) -> #(engine, Ignore("cannot derive conversation key"))
        Ok(conversation_key) ->
          case nip44.decrypt(incoming.content, conversation_key) {
            Error(_) ->
              case string.contains(incoming.content, "?iv=") {
                True -> #(engine, Ignore("nip-04 request (unsupported)"))
                False -> #(engine, Ignore("undecryptable content"))
              }
            Ok(plaintext) ->
              case rpc.decode_request(plaintext) {
                Error(_) -> #(engine, Ignore("malformed request payload"))
                Ok(request) -> {
                  let #(engine, response) =
                    execute(
                      engine,
                      account,
                      secret,
                      client_pk_hex,
                      request,
                      now,
                    )
                  #(
                    engine,
                    build_reply(
                      account,
                      conversation_key,
                      client_pk_hex,
                      response,
                      now,
                    ),
                  )
                }
              }
          }
      }
  }
}

/// Run one request, gating everything but `connect` and `logout` on the
/// client having connected first.
fn execute(
  engine: Engine,
  account: Account,
  secret: String,
  client_pk_hex: String,
  request: rpc.Request,
  now: Int,
) -> #(Engine, rpc.Response) {
  let signer = account.pubkey_hex
  let authorized = set.contains(engine.authorized, #(signer, client_pk_hex))
  case request.method {
    "connect" ->
      case connect_secret(request.params) == Some(secret) {
        True -> #(
          Engine(
            ..engine,
            authorized: set.insert(engine.authorized, #(signer, client_pk_hex)),
          ),
          rpc.ok(request.id, "ack"),
        )
        False -> #(engine, rpc.error(request.id, "invalid secret"))
      }
    "logout" -> #(
      Engine(
        ..engine,
        authorized: set.delete(engine.authorized, #(signer, client_pk_hex)),
      ),
      rpc.ok(request.id, "ack"),
    )
    _ ->
      case authorized {
        False -> #(
          engine,
          rpc.error(request.id, "unauthorized: send connect first"),
        )
        True -> #(engine, execute_authorized(account, request, now))
      }
  }
}

/// Run one request from a client that has already connected.
fn execute_authorized(
  account: Account,
  request: rpc.Request,
  now: Int,
) -> rpc.Response {
  case request.method {
    "get_public_key" -> rpc.ok(request.id, account.pubkey_hex)
    "ping" -> rpc.ok(request.id, "pong")
    "sign_event" -> sign_event(account, request, now)
    "nip44_encrypt" -> nip44_op(account, request, True)
    "nip44_decrypt" -> nip44_op(account, request, False)
    "nip04_encrypt" | "nip04_decrypt" ->
      rpc.error(request.id, "nip04 is not supported")
    method -> rpc.error(request.id, "unsupported method: " <> method)
  }
}

/// The secret from a connect request. Clients send [signer_pk, secret, perms]
/// but some older ones send just [secret].
fn connect_secret(params: List(String)) -> Option(String) {
  case params {
    [_signer, secret, ..] -> Some(secret)
    [secret] -> Some(secret)
    [] -> None
  }
}

/// Sign the event draft in the request with the account key.
fn sign_event(
  account: Account,
  request: rpc.Request,
  now: Int,
) -> rpc.Response {
  case request.params {
    [draft_json, ..] ->
      case rpc.decode_draft(draft_json) {
        Error(_) -> rpc.error(request.id, "invalid event draft")
        Ok(draft) -> {
          let unsigned =
            Event(
              id: "",
              pubkey: account.pubkey_hex,
              created_at: option.unwrap(draft.created_at, now),
              kind: draft.kind,
              tags: draft.tags,
              content: draft.content,
              sig: "",
            )
          case event.finalize(unsigned, account.privkey) {
            Ok(signed) ->
              rpc.ok(request.id, json.to_string(event.to_json(signed)))
            Error(_) -> rpc.error(request.id, "failed to sign event")
          }
        }
      }
    [] -> rpc.error(request.id, "sign_event requires an event draft")
  }
}

/// Encrypt or decrypt text for a third party with the account key.
fn nip44_op(
  account: Account,
  request: rpc.Request,
  encrypting: Bool,
) -> rpc.Response {
  case request.params {
    [third_party_hex, text, ..] ->
      case decode_hex(third_party_hex) {
        Error(_) -> rpc.error(request.id, "invalid third-party pubkey")
        Ok(third_party) ->
          case nip44.conversation_key(account.privkey, third_party) {
            Error(_) -> rpc.error(request.id, "invalid third-party pubkey")
            Ok(key) -> {
              let outcome = case encrypting {
                True -> nip44.encrypt(text, key)
                False -> nip44.decrypt(text, key)
              }
              case outcome {
                Ok(result) -> rpc.ok(request.id, result)
                Error(_) -> rpc.error(request.id, "nip44 operation failed")
              }
            }
          }
      }
    _ -> rpc.error(request.id, "nip44 requires [pubkey, text]")
  }
}

/// Encrypt the response to the client and sign it as a kind 24133 event.
fn build_reply(
  account: Account,
  conversation_key: BitArray,
  client_pk_hex: String,
  response: rpc.Response,
  now: Int,
) -> Outcome {
  case nip44.encrypt(rpc.encode_response(response), conversation_key) {
    Error(_) -> Ignore("failed to encrypt response")
    Ok(content) -> {
      let unsigned =
        Event(
          id: "",
          pubkey: account.pubkey_hex,
          created_at: now,
          kind: 24_133,
          tags: [["p", client_pk_hex]],
          content: content,
          sig: "",
        )
      case event.finalize(unsigned, account.privkey) {
        Ok(signed) -> Reply(signed)
        Error(_) -> Ignore("failed to sign response")
      }
    }
  }
}

/// Decode a hex string, accepting either case.
fn decode_hex(hex: String) -> Result(BitArray, Nil) {
  bit_array.base16_decode(string.uppercase(hex))
}
