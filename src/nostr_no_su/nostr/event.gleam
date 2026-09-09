import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/result
import gleam/string
import nostr_no_su/crypto/bip340

/// NIP-01 で定義される Nostr イベント。
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

/// イベント id の計算に使う NIP-01 の正規シリアライズ。
/// `[0, pubkey, created_at, kind, tags, content]` を空白なしで出力する。
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

/// 正規シリアライズの 32 バイト sha256。BIP-340 で署名する対象。
pub fn hash_for_signing(event: Event) -> BitArray {
  serialize_for_id(event)
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
}

/// イベント id を計算する。正規シリアライズの sha256 を小文字 16 進で表したもの。
pub fn compute_id(event: Event) -> String {
  hash_for_signing(event)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// 他のフィールドが設定済みのドラフトに `id` と `sig` を埋める。`privkey` は
/// `event.pubkey` に対応している必要がある。
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

/// イベントの BIP-340 署名を、その pubkey と内容に対して検証する。
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
