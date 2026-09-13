import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string
import nostr_no_su/crypto/bip340
import nostr_no_su/hex

/// NIP-46 のリクエストと応答を運ぶイベントの kind。`is_ephemeral` が真になる
/// kind なので、リレーは保存せず接続中のクライアントにだけ転送する。
pub const nip46_kind = 24_133

/// NIP-01 の ephemeral イベントの kind（20000 以上 30000 未満）か。リレーは
/// 保存せず、接続中のクライアントにだけ転送する。
pub fn is_ephemeral(kind: Int) -> Bool {
  kind >= 20_000 && kind < 30_000
}

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

/// リレーから届く JSON オブジェクト、または binary キーの map のデコーダー。
/// `decode.field` はキーを完全一致で引くため、同じデコーダーがプラグイン境界の
/// map（`to_map` が作る形）にもそのまま使える。
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

/// リレーへ送る JSON オブジェクト。
pub fn to_json(event: Event) -> Json {
  json.object([
    #("id", json.string(event.id)),
    #("pubkey", json.string(event.pubkey)),
    #("created_at", json.int(event.created_at)),
    #("kind", json.int(event.kind)),
    #("tags", tags_json(event)),
    #("content", json.string(event.content)),
    #("sig", json.string(event.sig)),
  ])
}

/// プラグインへ渡すイベントの表現。**Erlang の map（キーは binary）** を
/// `Dynamic` として返す。`Dict` ではなく、キーは atom でもないことに注意。
///
/// この map の形はプラグイン API v1 の一部であり、キーの変更は破壊的変更に
/// あたる（`nostr_no_su/plugin` を参照）。`to_json` とフィールド一覧が重複する
/// が、`from_map` が `decoder()` を再利用するため、片方だけ直すとラウンド
/// トリップテストが落ちる。
pub fn to_map(event: Event) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("id"), dynamic.string(event.id)),
    #(dynamic.string("pubkey"), dynamic.string(event.pubkey)),
    #(dynamic.string("created_at"), dynamic.int(event.created_at)),
    #(dynamic.string("kind"), dynamic.int(event.kind)),
    #(dynamic.string("tags"), tags_dynamic(event)),
    #(dynamic.string("content"), dynamic.string(event.content)),
    #(dynamic.string("sig"), dynamic.string(event.sig)),
  ])
}

/// タグの map 表現。`tags_json` と対になる、文字列リストのリスト。
fn tags_dynamic(event: Event) -> Dynamic {
  dynamic.list(
    list.map(event.tags, fn(tag) { dynamic.list(list.map(tag, dynamic.string)) }),
  )
}

/// プラグイン境界の map（`to_map` の形）を `Event` に戻す。
///
/// 失敗側を `String` にしているのは、プラグインローダーがこの文字列をそのまま
/// ログの 1 行に出せるようにするため。JSON のデコードを扱う他の 3 か所は
/// `json.DecodeError` を型のまま伝播しているが、ここだけ方針が違う。
pub fn from_map(value: Dynamic) -> Result(Event, String) {
  decode.run(value, decoder())
  |> result.map_error(fn(errors) {
    // map でない値は 7 フィールドすべてで同じエラーになるので重複を落とす。
    list.map(errors, describe_error) |> list.unique |> string.join("; ")
  })
}

/// デコードエラー 1 件を人が読める 1 行にする。欠損キーは
/// `DecodeError("Field", "Nothing", ["kind"])` になるため、`expected` と `found`
/// をそのまま差し込むと意味の通らない行になる。専用の分岐で振り分ける。
///
/// `path` が空になるのは値そのものが map でないときで、この場合はキー名を書か
/// ない（同じ行がフィールドの数だけ繰り返されるのを避けるため、`from_map` 側で
/// 重複を落とす）。
fn describe_error(error: decode.DecodeError) -> String {
  let decode.DecodeError(expected:, found:, path:) = error
  let mismatch = "expected " <> expected <> ", found " <> found
  case expected, found, path {
    _, _, [] -> mismatch
    "Field", "Nothing", _ -> "missing field " <> quoted_path(path)
    _, _, _ -> "field " <> quoted_path(path) <> ": " <> mismatch
  }
}

/// エラーの位置を示すキー。`tags` の内側のように複数要素になるときは `.` で
/// 連結する。
fn quoted_path(path: List(String)) -> String {
  "\"" <> string.join(path, ".") <> "\""
}

/// タグの JSON 表現。NIP-01 では文字列配列の配列で、正規シリアライズでも
/// イベント本体でも同じ形を使う。
pub fn tags_json(event: Event) -> Json {
  json.array(event.tags, of: json.array(_, of: json.string))
}

/// イベント id の計算に使う NIP-01 の正規シリアライズ。
/// `[0, pubkey, created_at, kind, tags, content]` を空白なしで出力する。
pub fn serialize_for_id(event: Event) -> String {
  json.preprocessed_array([
    json.int(0),
    json.string(event.pubkey),
    json.int(event.created_at),
    json.int(event.kind),
    tags_json(event),
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
  |> hex.encode
}

/// 他のフィールドが設定済みのドラフトに `id` と `sig` を埋める。`privkey` は
/// `event.pubkey` に対応している必要がある。
pub fn finalize(event: Event, privkey: BitArray) -> Result(Event, Nil) {
  let hash = hash_for_signing(event)
  use signature <- result.try(
    bip340.sign(privkey, hash) |> result.replace_error(Nil),
  )
  Ok(Event(..event, id: hex.encode(hash), sig: hex.encode(signature)))
}

/// イベントの BIP-340 署名を、その pubkey と内容に対して検証する。
pub fn verify_signature(event: Event) -> Bool {
  case hex.decode(event.pubkey), hex.decode(event.sig) {
    Ok(pubkey), Ok(signature) ->
      bip340.verify(signature, hash_for_signing(event), pubkey)
    _, _ -> False
  }
}

/// 受信したイベントを `verify` が落とした理由。
pub type VerifyError {
  /// `id` が内容から計算した値と一致しない。
  InvalidId
  /// 署名が `pubkey` と内容に対して検証できない。
  InvalidSignature
}

/// `verify` を通ったイベント。`id` が内容と一致し、署名が `pubkey` で検証できる
/// ことを表す。値を作れるのは `verify` だけである。
pub opaque type Verified {
  Verified(event: Event)
}

/// 受信したイベントの `id` と署名を確かめる。`id` の照合（sha256 1 回）を署名の
/// 検証（1 件あたりミリ秒単位）より先に置き、`id` の合わないイベントには署名の
/// 検証を払わない。
pub fn verify(event: Event) -> Result(Verified, VerifyError) {
  use <- bool.guard(compute_id(event) != event.id, Error(InvalidId))
  use <- bool.guard(!verify_signature(event), Error(InvalidSignature))
  Ok(Verified(event))
}

/// 検証済みのイベントの中身。
pub fn verified_event(verified: Verified) -> Event {
  verified.event
}
