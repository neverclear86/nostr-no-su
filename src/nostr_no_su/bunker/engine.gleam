//// NIP-46 リクエスト処理の純粋なコア。プロセスも時計も乱数も IO も持たず、現在
//// 時刻と承認トークンは引数（`Inputs`）で受け取るため、すべての経路が決定的で
//// ループバックテストによる単体検証ができる。`bunker.gleam` がこれをアクターで
//// 包む。

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import nostr_no_su/bunker/account.{type Account}
import nostr_no_su/bunker/rpc
import nostr_no_su/crypto/nip44
import nostr_no_su/nostr/event.{type Event, Event}

/// クライアントの時刻ずれを許容するため、現在時刻から前後この秒数以内の
/// リクエストを受け付ける。
const window_seconds = 600

/// 承認待ちの有効期間。承認も拒否もされないまま放置された要求は、これを過ぎたら
/// 無かったものとして扱う。
const pending_ttl_seconds = 600

pub type Engine {
  Engine(
    // 署名者 pubkey hex -> #(account, secret)
    accounts: Dict(String, #(Account, String)),
    // #(署名者 pubkey hex, クライアント pubkey hex)
    sessions: Set(#(String, String)),
    // リプレイ防止用: リクエストイベント id -> created_at
    seen: Dict(String, Int),
    // 承認待ちの接続要求: token -> Pending
    pending: Dict(String, Pending),
    // token から承認ページの URL を組み立てる関数。None なら承認フローを使わない。
    auth_url: Option(fn(String) -> String),
  )
}

/// リクエストを 1 件処理する間だけ使う、外から注入する値。時刻も乱数もエンジンの
/// 外で決めることで、エンジンは純粋なまま保たれる。`token` は承認待ちを作るとき
/// だけ使う。
pub type Inputs {
  Inputs(now: Int, token: String)
}

/// 承認待ちの接続要求 1 件。`token` は承認ページの URL に入る値で、辞書の鍵と
/// 同じものを持つ（一覧に出すときに鍵を持ち回らずに済む）。`request_id` は承認後
/// の応答を元の `connect` と同じ id で返すために覚えておく。
pub type Pending {
  Pending(
    token: String,
    signer: String,
    client: String,
    request_id: String,
    created_at: Int,
  )
}

/// 承認済みのクライアントセッション 1 件。`connect` が成功した（署名者,
/// クライアント）の組で、取り消されるまで署名を代理できる。
pub type Session {
  Session(signer: String, client: String)
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
/// `auth_url` は承認待ちの token から承認ページの URL を組み立てる関数で、
/// `None`（管理 UI が無効）なら承認フローも無効になる。URL の形を知っているのは
/// 呼び出し側だけなので、エンジンは管理 UI のルート構造に依存しない。
pub fn new(
  accounts: List(#(Account, String)),
  auth_url: Option(fn(String) -> String),
) -> Engine {
  let account_dict =
    accounts
    |> list.map(fn(pair) { #({ pair.0 }.pubkey_hex, pair) })
    |> dict.from_list
  Engine(
    accounts: account_dict,
    sessions: set.new(),
    seen: dict.new(),
    pending: dict.new(),
    auth_url: auth_url,
  )
}

/// 承認済みセッションの一覧。集合の走査順は未定義なので、表示とテストが安定
/// するよう署名者・クライアントの順に並べる。
pub fn sessions(engine: Engine) -> List(Session) {
  engine.sessions
  |> set.to_list
  |> list.sort(fn(left, right) {
    string.compare(left.0, right.0)
    |> order.break_tie(string.compare(left.1, right.1))
  })
  |> list.map(fn(pair) { Session(signer: pair.0, client: pair.1) })
}

/// セッションの承認を取り消す。そのクライアントは再び `connect` を求められる。
/// 承認されていない組を渡しても何も起きない。
pub fn revoke(engine: Engine, signer: String, client: String) -> Engine {
  Engine(..engine, sessions: set.delete(engine.sessions, #(signer, client)))
}

/// 失効していない承認待ちの一覧。表示が安定するよう古い順に並べる。失効した要求
/// は状態からすぐに消えるわけではないが、この一覧にも `approve` / `deny` にも
/// 現れず、次の登録か成功した承認・拒否のときにまとめて捨てられる。
pub fn pending(engine: Engine, now: Int) -> List(Pending) {
  live_pending(engine, now)
  |> dict.values
  |> list.sort(fn(left, right) {
    int.compare(left.created_at, right.created_at)
    |> order.break_tie(string.compare(left.token, right.token))
  })
}

/// 承認待ちの接続要求を承認する。（署名者, クライアント）を承認済みにして、元の
/// `connect` と同じ id の `ack` 応答イベントを返す。token が不明、あるいは失効
/// していれば理由を返す。
pub fn approve(
  engine: Engine,
  token: String,
  now: Int,
) -> Result(#(Engine, Event), String) {
  use #(engine, entry) <- result.try(take_pending(engine, token, now))
  let engine = open_session(engine, #(entry.signer, entry.client))
  respond(engine, entry, rpc.ok(entry.request_id, "ack"), now)
}

/// 承認待ちの接続要求を拒否する。承認済みにはせず、元の `connect` と同じ id の
/// エラー応答イベントを返す。
pub fn deny(
  engine: Engine,
  token: String,
  now: Int,
) -> Result(#(Engine, Event), String) {
  use #(engine, entry) <- result.try(take_pending(engine, token, now))
  respond(engine, entry, rpc.error(entry.request_id, "connection denied"), now)
}

/// 承認待ちを 1 件取り出す。承認も拒否も 1 度きりなので取り出したものは状態から
/// 削除し、ついでに失効した要求もまとめて捨てる。
fn take_pending(
  engine: Engine,
  token: String,
  now: Int,
) -> Result(#(Engine, Pending), String) {
  let live = live_pending(engine, now)
  case dict.get(live, token) {
    Error(_) -> Error("unknown or expired approval request")
    Ok(entry) ->
      Ok(#(Engine(..engine, pending: dict.delete(live, token)), entry))
  }
}

/// 失効していない承認待ちだけを残した辞書。表示・承認・登録のどこから見ても、
/// 失効した要求は存在しないものとして扱う。
fn live_pending(engine: Engine, now: Int) -> Dict(String, Pending) {
  dict.filter(engine.pending, fn(_token, entry) { !expired(entry, now) })
}

/// 承認待ちが有効期間を過ぎているかどうか。リクエストの受付ウィンドウと違い、
/// 経過した時間だけを見る片側の判定。
fn expired(entry: Pending, now: Int) -> Bool {
  entry.created_at < now - pending_ttl_seconds
}

/// 承認・拒否の結果を、待たせているクライアント宛の応答イベントにする。会話鍵は
/// 署名者の秘密鍵とクライアント pubkey から導出し直す。
fn respond(
  engine: Engine,
  entry: Pending,
  response: rpc.Response,
  now: Int,
) -> Result(#(Engine, Event), String) {
  use #(account, _secret) <- result.try(
    dict.get(engine.accounts, entry.signer)
    |> result.replace_error("no matching account for " <> entry.signer),
  )
  use conversation_key <- result.try(client_conversation_key(
    account,
    entry.client,
  ))
  use reply <- result.map(build_reply(
    account,
    conversation_key,
    entry.client,
    response,
    now,
  ))
  #(engine, reply)
}

/// 受信イベント 1 件を処理する。検証・重複排除・ルーティングを行い、送信すべき
/// 応答があれば生成する。
pub fn handle_event(
  engine: Engine,
  incoming: Event,
  inputs: Inputs,
) -> #(Engine, Outcome) {
  case incoming.kind == 24_133 {
    False -> #(engine, Ignore("not a nip-46 request"))
    True ->
      case fresh(incoming.created_at, inputs.now) {
        False -> #(engine, Ignore("stale or future event"))
        True ->
          case route(engine, incoming.tags) {
            Error(reason) -> #(engine, Ignore(reason))
            Ok(#(account, secret)) ->
              case dict.has_key(engine.seen, incoming.id) {
                True -> #(engine, Duplicate)
                False -> {
                  let engine = record_seen(engine, incoming, inputs.now)
                  case event.verify_signature(incoming) {
                    False -> #(engine, Ignore("invalid signature"))
                    True ->
                      handle_request(engine, account, secret, incoming, inputs)
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
  inputs: Inputs,
) -> #(Engine, Outcome) {
  let client_pk_hex = incoming.pubkey
  case client_conversation_key(account, client_pk_hex) {
    Error(reason) -> #(engine, Ignore(reason))
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
                execute(engine, account, secret, client_pk_hex, request, inputs)
              let reply =
                build_reply(
                  account,
                  conversation_key,
                  client_pk_hex,
                  response,
                  inputs.now,
                )
              #(engine, outcome(reply))
            }
          }
      }
  }
}

/// クライアントとの会話鍵。署名者の秘密鍵とクライアント pubkey から導出する。
fn client_conversation_key(
  account: Account,
  client_pk_hex: String,
) -> Result(BitArray, String) {
  use client_pk <- result.try(
    decode_hex(client_pk_hex) |> result.replace_error("invalid client pubkey"),
  )
  nip44.conversation_key(account.privkey, client_pk)
  |> result.replace_error("cannot derive conversation key")
}

/// 組み立てた応答イベントを Outcome にする。失敗は送るものが無いので破棄する。
fn outcome(reply: Result(Event, String)) -> Outcome {
  case reply {
    Ok(response) -> Reply(response)
    Error(reason) -> Ignore(reason)
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
  inputs: Inputs,
) -> #(Engine, rpc.Response) {
  let signer = account.pubkey_hex
  case request.method {
    "connect" -> connect(engine, signer, secret, client_pk_hex, request, inputs)
    "logout" -> #(
      revoke(engine, signer, client_pk_hex),
      rpc.ok(request.id, "ack"),
    )
    _ ->
      case set.contains(engine.sessions, #(signer, client_pk_hex)) {
        False -> #(
          engine,
          rpc.error(request.id, "unauthorized: send connect first"),
        )
        True -> #(engine, execute_in_session(account, request, inputs.now))
      }
  }
}

/// `connect` を 1 件処理する。シークレットが一致すればその場で承認し、既に承認
/// 済みの組ならシークレット無しでも通す（クライアントの再読み込みのたびに承認を
/// 求めないため）。どちらでもないときは、管理 UI が有効なら承認待ちを作って
/// `auth_url` を返し、無効なら従来どおり拒否する。
fn connect(
  engine: Engine,
  signer: String,
  secret: String,
  client_pk_hex: String,
  request: rpc.Request,
  inputs: Inputs,
) -> #(Engine, rpc.Response) {
  let pair = #(signer, client_pk_hex)
  case
    connect_secret(request.params) == Some(secret),
    set.contains(engine.sessions, pair)
  {
    True, _ -> #(open_session(engine, pair), rpc.ok(request.id, "ack"))
    _, True -> #(engine, rpc.ok(request.id, "ack"))
    False, False ->
      case engine.auth_url {
        None -> #(engine, rpc.error(request.id, "invalid secret"))
        Some(auth_url) -> #(
          record_pending(
            engine,
            Pending(
              token: inputs.token,
              signer: signer,
              client: client_pk_hex,
              request_id: request.id,
              created_at: inputs.now,
            ),
          ),
          rpc.auth_url(request.id, auth_url(inputs.token)),
        )
      }
  }
}

/// （署名者, クライアント）の組を承認済みにする。
fn open_session(engine: Engine, pair: #(String, String)) -> Engine {
  Engine(..engine, sessions: set.insert(engine.sessions, pair))
}

/// 承認待ちを 1 件登録する。同じ（署名者, クライアント）の古い要求と、失効した
/// 要求は同時に捨てる。承認前にクライアントが再読み込みすると `connect` が届き
/// 直すため、最新の要求だけを残さないと、承認の応答が誰も待っていないリクエスト
/// id で送られてしまう。失効の基準になる現在時刻は、いま作った要求の作成時刻が
/// そのまま使える。
fn record_pending(engine: Engine, entry: Pending) -> Engine {
  let kept =
    live_pending(engine, entry.created_at)
    |> dict.filter(fn(_token, existing) {
      existing.signer != entry.signer || existing.client != entry.client
    })
  Engine(..engine, pending: dict.insert(kept, entry.token, entry))
}

/// 接続済みクライアントからのリクエストを 1 件実行する。
fn execute_in_session(
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
/// を送るが、古い実装には [secret] だけを送るものもある。シークレット無しで接続
/// するクライアントは空文字列を送ってくるため、それも「無し」として扱う。
fn connect_secret(params: List(String)) -> Option(String) {
  case params {
    [_signer, secret, ..] | [secret] ->
      case secret {
        "" -> None
        secret -> Some(secret)
      }
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
) -> Result(Event, String) {
  case nip44.encrypt(rpc.encode_response(response), conversation_key) {
    Error(_) -> Error("failed to encrypt response")
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
        Ok(signed) -> Ok(signed)
        Error(_) -> Error("failed to sign response")
      }
    }
  }
}

/// 16 進文字列をデコードする。大文字・小文字のどちらも受け付ける。
fn decode_hex(hex: String) -> Result(BitArray, Nil) {
  bit_array.base16_decode(string.uppercase(hex))
}
