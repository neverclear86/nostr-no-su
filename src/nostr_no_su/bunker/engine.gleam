//// NIP-46 リクエスト処理の純粋なコア。プロセスも時計も IO も持たず、現在時刻は
//// 引数で受け取るため、すべての経路が決定的でループバックテストによる単体検証が
//// できる。`bunker.gleam` がこれをアクターで包む。

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

/// クライアントの時刻ずれを許容するため、現在時刻から前後この秒数以内の
/// リクエストを受け付ける。
const window_seconds = 600

pub type Engine {
  Engine(
    // 署名者 pubkey hex -> #(account, secret)
    accounts: Dict(String, #(Account, String)),
    // #(署名者 pubkey hex, クライアント pubkey hex)
    authorized: Set(#(String, String)),
    // リプレイ防止用: リクエストイベント id -> created_at
    seen: Dict(String, Int),
  )
}

pub type Outcome {
  /// クライアントへ送り返す応答イベント。
  Reply(response: Event)
  /// 処理済みのリクエスト。2 つ目のバンカーリレーから同じものが届いた場合など。
  /// 複数リレー構成では想定内なので、呼び出し側はログを出さない。
  Duplicate
  /// リクエストを破棄した。ログに出す理由を伴う。
  Ignore(reason: String)
}

/// 指定したアカウント群（それぞれの接続シークレット付き）を扱うエンジン。
pub fn new(accounts: List(#(Account, String))) -> Engine {
  let account_dict =
    accounts
    |> list.map(fn(pair) { #({ pair.0 }.pubkey_hex, pair) })
    |> dict.from_list
  Engine(accounts: account_dict, authorized: set.new(), seen: dict.new())
}

/// 受信イベント 1 件を処理する。検証・重複排除・ルーティングを行い、送信すべき
/// 応答があれば生成する。
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

/// タイムスタンプが現在時刻を中心とした受付ウィンドウ内かどうか。
fn fresh(created_at: Int, now: Int) -> Bool {
  created_at >= now - window_seconds && created_at <= now + window_seconds
}

/// 最初の ["p", pubkey] タグを見て、既知のアカウントへルーティングする。
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

/// 最初の ["p", pubkey] タグの pubkey。存在しなければ None。
fn first_p_tag(tags: List(List(String))) -> Option(String) {
  case tags {
    [] -> None
    [["p", pubkey, ..], ..] -> Some(pubkey)
    [_, ..rest] -> first_p_tag(rest)
  }
}

/// リプレイ防止のためリクエスト id を記録し、もはやリプレイされ得ない id は
/// 忘れる。
fn record_seen(engine: Engine, incoming: Event, now: Int) -> Engine {
  let seen =
    engine.seen
    |> dict.insert(incoming.id, incoming.created_at)
    // 受付ウィンドウより古いエントリを削除する。どのみちリプレイされないため、
    // これで集合のサイズが有界に保たれる。
    |> dict.filter(fn(_id, created_at) { created_at >= now - window_seconds })
  Engine(..engine, seen: seen)
}

/// リクエストを復号・デコードし、暗号化した応答を組み立てる。
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

/// リクエストを 1 件実行する。`connect` と `logout` 以外は、クライアントが先に
/// 接続済みであることを条件とする。
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

/// 接続済みクライアントからのリクエストを 1 件実行する。
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

/// connect リクエストのシークレット。クライアントは [signer_pk, secret, perms]
/// を送るが、古い実装には [secret] だけを送るものもある。
fn connect_secret(params: List(String)) -> Option(String) {
  case params {
    [_signer, secret, ..] -> Some(secret)
    [secret] -> Some(secret)
    [] -> None
  }
}

/// リクエストに含まれるイベントドラフトをアカウントの鍵で署名する。
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

/// 第三者宛のテキストをアカウントの鍵で暗号化または復号する。
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

/// 応答をクライアント宛に暗号化し、kind 24133 イベントとして署名する。
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

/// 16 進文字列をデコードする。大文字・小文字のどちらも受け付ける。
fn decode_hex(hex: String) -> Result(BitArray, Nil) {
  bit_array.base16_decode(string.uppercase(hex))
}
