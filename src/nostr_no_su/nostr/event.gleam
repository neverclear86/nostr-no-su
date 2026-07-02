import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/result
import gleam/string
import nostr_no_su/crypto/bip340

/// A Nostr event as defined by NIP-01.
pub type Event {
  Event(
    id: String,
    pubkey: String,
    created_at: Int,
    kind: Int,
    tags: List(List(String)),
    content: String,
    sig: String,
  )
}

pub fn decoder() -> decode.Decoder(Event) {
  use id <- decode.field("id", decode.string)
  use pubkey <- decode.field("pubkey", decode.string)
  use created_at <- decode.field("created_at", decode.int)
  use kind <- decode.field("kind", decode.int)
  use tags <- decode.field("tags", decode.list(decode.list(decode.string)))
  use content <- decode.field("content", decode.string)
  use sig <- decode.field("sig", decode.string)
  decode.success(Event(id:, pubkey:, created_at:, kind:, tags:, content:, sig:))
}

pub fn to_json(event: Event) -> Json {
  json.object([
    #("id", json.string(event.id)),
    #("pubkey", json.string(event.pubkey)),
    #("created_at", json.int(event.created_at)),
    #("kind", json.int(event.kind)),
    #("tags", json.array(event.tags, of: json.array(_, of: json.string))),
    #("content", json.string(event.content)),
    #("sig", json.string(event.sig)),
  ])
}

/// The canonical NIP-01 serialization used to compute the event id:
/// `[0, pubkey, created_at, kind, tags, content]` with no whitespace.
pub fn serialize_for_id(event: Event) -> String {
  json.preprocessed_array([
    json.int(0),
    json.string(event.pubkey),
    json.int(event.created_at),
    json.int(event.kind),
    json.array(event.tags, of: json.array(_, of: json.string)),
    json.string(event.content),
  ])
  |> json.to_string
}

/// The 32-byte sha256 of the canonical serialization, signed by BIP-340.
pub fn hash_for_signing(event: Event) -> BitArray {
  serialize_for_id(event)
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
}

/// Compute the event id: lowercase hex sha256 of the canonical serialization.
pub fn compute_id(event: Event) -> String {
  hash_for_signing(event)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Fill `id` and `sig` on a draft whose other fields are set. `privkey` must
/// correspond to `event.pubkey`.
pub fn finalize(event: Event, privkey: BitArray) -> Result(Event, Nil) {
  let hash = hash_for_signing(event)
  use signature <- result.try(
    bip340.sign(privkey, hash) |> result.replace_error(Nil),
  )
  Ok(
    Event(
      ..event,
      id: string.lowercase(bit_array.base16_encode(hash)),
      sig: string.lowercase(bit_array.base16_encode(signature)),
    ),
  )
}

/// Verify the event's BIP-340 signature against its pubkey and content.
pub fn verify_signature(event: Event) -> Bool {
  case
    bit_array.base16_decode(string.uppercase(event.pubkey)),
    bit_array.base16_decode(string.uppercase(event.sig))
  {
    Ok(pubkey), Ok(signature) ->
      bip340.verify(signature, hash_for_signing(event), pubkey)
    _, _ -> False
  }
}
