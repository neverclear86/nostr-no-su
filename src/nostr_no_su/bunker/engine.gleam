//// NIP-46 リクエスト処理の純粋なコア。プロセスも時計も乱数も IO も持たず、現在
//// 時刻と承認トークンは引数（`Inputs`）で受け取るため、すべての経路が決定的で
//// ループバックテストによる単体検証ができる。`bunker.gleam` がこれをアクターで
//// 包む。

import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import nostr_no_su/bunker/account.{type Account, privkey, pubkey_hex}
import nostr_no_su/bunker/rpc
import nostr_no_su/crypto/nip44
import nostr_no_su/dedup/window
import nostr_no_su/hex
import nostr_no_su/nostr/event.{type Event, Event}

/// クライアントの時刻ずれを許容するため、現在時刻から前後この秒数以内の
/// リクエストを受け付ける。
const window_seconds = 600

/// 承認待ちの有効期間。承認も拒否もされないまま放置された要求は、これを過ぎたら
/// 無かったものとして扱う。
const pending_ttl_seconds = 600

/// リプレイ防止のために記憶するリクエスト id の件数。
///
/// `accept` は復号も認可も済ませる前に id を記録するため、自分宛の p タグを付けて
/// 署名しただけの kind 24133 であれば、未認可のクライアントからでも 1 件を占める。
/// つまり流入量は運用者の負荷ではなく送信者が決められるもので、署名検証 1 件が
/// ミリ秒単位である以上、受付ウィンドウ（`window_seconds`）の間に容量を超える
/// 件数を送り込むことは攻撃者にとって現実的である。
///
/// 押し出された id のリプレイが通ったときに起こりうることは限られる。応答は元の
/// クライアント宛に NIP-44 で暗号化されるため攻撃者は読めず、`logout` の再送で
/// セッションが切れる、secret 無しの `connect` の再送で承認待ちが再登録される
/// （承認しても認可されるのは元のクライアント）といった範囲にとどまり、鍵や署名が
/// 漏れる経路は無い。この範囲を受容したうえで、記憶領域を確実に有界にすることを
/// 優先して件数のみで区切っている。
const seen_capacity = 16_384

/// バンカーが持つ状態のすべて。プロセスも時計も持たない純粋な値で、`bunker` の
/// アクターがこれを保持して受信のたびに更新する。
pub type Engine {
  Engine(
    // 署名者 pubkey hex -> #(account, secret)
    accounts: Dict(String, #(Account, String)),
    // #(署名者 pubkey hex, クライアント pubkey hex)
    sessions: Set(#(String, String)),
    // リプレイ防止用: 処理済みのリクエストイベント id
    seen: window.Window,
    // 承認待ちの接続要求: token -> Pending
    pending: Dict(String, Pending),
    // token から承認ページの URL を組み立てる関数。None なら承認フローを使わない。
    auth_url: Option(fn(String) -> String),
  )
}

/// 受信イベント 1 件を処理する間に、外から注入する値。時刻も乱数もエンジンの外で
/// 決めることで、エンジンは純粋なまま保たれる。`token` は承認待ちを作るときだけ
/// 使う。
///
/// `not_before` はこのバンカーを動かしているアクターが起動した時刻で、これより
/// 古いリクエストは受け付けない。リプレイ防止の `seen` はアクターの寿命に閉じて
/// いるため、アクターが再起動すると、それ以前に処理したリクエストを新規として
/// 実行してしまう（kind 24133 を保存するリレーは再購読で再配送する）。起点を
/// 設けることで、記憶していないリクエストは実行せずに捨てる。
///
/// `created_at` は秒までしか持たないため、判定は起動した秒より前かどうかで行い、
/// 起動と同じ秒のリクエストは通す。起動直後に届いた正当なリクエストを落とすと、
/// クライアントは応答を待ったまま失敗する。再起動が同じ秒に収まった場合は、その秒
/// のリクエストが再実行されうる。これは判定の粒度による残りである。
///
/// 判定に使うのはクライアントが自己申告する `created_at` なので、時計が進んでいる
/// クライアントには保護が効かない。ずれが D 秒あると、リレーがそのリクエストを
/// 再配送しうるのは送信から「D + 購読の猶予」の間で、そのうち最初の D 秒に入った
/// 再起動では、アクターの起点がリクエストの `created_at` に届かず落とせない（D の
/// 上限は受付ウィンドウの `window_seconds`）。逆に時計が遅れているクライアントの
/// リクエストは、アクターの起動直後、そのずれの秒数ぶんだけ弾かれうる。
pub type Inputs {
  Inputs(now: Int, token: String, not_before: Int)
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

/// 受信イベント 1 件を処理した結果。
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
  let empty =
    Engine(
      accounts: dict.new(),
      sessions: set.new(),
      seen: window.new(seen_capacity),
      pending: dict.new(),
      auth_url: auth_url,
    )
  use engine, pair <- list.fold(accounts, empty)
  add_account(engine, pair.0, pair.1)
}

/// アカウントを 1 件足す。同じ署名者がすでにあれば、鍵と secret を置き換え、
/// セッションと承認待ちは残す。
///
/// この関数と下の `remove_account` / `replace_secret` は全域にしてある。アクターは
/// DB への書き込みが成功したときだけこれらを呼ぶので、不在や重複を失敗として返しても
/// 到達しない分岐になる（`revoke` と同じ作法）。
pub fn add_account(engine: Engine, account: Account, secret: String) -> Engine {
  Engine(
    ..engine,
    accounts: dict.insert(engine.accounts, pubkey_hex(account), #(
      account,
      secret,
    )),
  )
}

/// アカウントを 1 件取り除き、その署名者の承認済みセッションと承認待ちも（失効の
/// 有無に関わらず）捨てる。登録されていない署名者なら何もしない。
///
/// 処理済みのリクエスト id（`seen`）は残す。リレーは購読の張り直しで直近の
/// リクエストを再配送するので、削除してすぐ戻したときに `seen` が空だと、実行済みの
/// リクエストを再実行してしまう。削除されていた間に届いたリクエストはルーティングで
/// 破棄されて `seen` に記録されないので、戻した後に届けば初めて実行される。
pub fn remove_account(engine: Engine, signer: String) -> Engine {
  Engine(
    ..engine,
    accounts: dict.delete(engine.accounts, signer),
    sessions: set.filter(engine.sessions, fn(pair) { pair.0 != signer }),
    pending: dict.filter(engine.pending, fn(_token, entry) {
      entry.signer != signer
    }),
  )
}

/// 接続 secret を差し替える。承認済みセッションは残る（取り消しは `revoke` で
/// 行う）。承認待ちは secret を持たない `connect` から作られ secret と無関係なので、
/// これも残す。登録されていない署名者なら何もしない。
pub fn replace_secret(
  engine: Engine,
  signer: String,
  secret: String,
) -> Engine {
  case dict.get(engine.accounts, signer) {
    Ok(#(account, _previous)) -> add_account(engine, account, secret)
    Error(Nil) -> engine
  }
}

/// 署名者として登録されているか。変更の前の所属の検査に使う。
pub fn has_account(engine: Engine, signer: String) -> Bool {
  dict.has_key(engine.accounts, signer)
}

/// 署名者の公開鍵の一覧（昇順）。購読の #p と、署名者の集合の比較に使う。
pub fn signers(engine: Engine) -> List(String) {
  dict.keys(engine.accounts)
  |> list.sort(string.compare)
}

/// 登録済みのアカウントと接続 secret（署名者の昇順）。管理 UI への一覧に使う。
pub fn registered_accounts(engine: Engine) -> List(#(Account, String)) {
  dict.to_list(engine.accounts)
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(entry) { entry.1 })
}

/// 署名者のアカウント。登録されていなければ `Error(Nil)`。秘密鍵の再表示に使う。
pub fn find_account(engine: Engine, signer: String) -> Result(Account, Nil) {
  dict.get(engine.accounts, signer)
  |> result.map(fn(entry) { entry.0 })
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
  case accept(engine, incoming, inputs) {
    Error(outcome) -> #(engine, outcome)
    Ok(#(engine, account, secret)) ->
      handle_request(engine, account, secret, incoming, inputs)
  }
}

/// 受信イベントを受理するかどうかを、kind・受付ウィンドウ・アクターの起点・
/// ルーティング・署名・重複の順に判定する。署名の検証を重複排除より先に置くのは、
/// `seen` に残るのを正当なリクエストだけに限るため。誰でも作れる署名なしの
/// イベントで記憶領域を埋められてはならない。受理したイベントの id は記録して
/// 返す。
fn accept(
  engine: Engine,
  incoming: Event,
  inputs: Inputs,
) -> Result(#(Engine, Account, String), Outcome) {
  use <- bool.guard(
    incoming.kind != event.nip46_kind,
    Error(Ignore("not a nip-46 request")),
  )
  use <- bool.guard(
    !fresh(incoming.created_at, inputs.now),
    Error(Ignore("stale or future event")),
  )
  use <- bool.guard(
    incoming.created_at < inputs.not_before,
    Error(Ignore("request predates this bunker instance")),
  )
  use #(account, secret) <- result.try(
    route(engine, incoming.tags) |> result.map_error(Ignore),
  )
  use <- bool.guard(
    !event.verify_signature(incoming),
    Error(Ignore("invalid signature")),
  )
  use seen <- result.map(
    window.insert(engine.seen, incoming.id) |> result.replace_error(Duplicate),
  )
  #(Engine(..engine, seen: seen), account, secret)
}

/// タイムスタンプが現在時刻を中心とした受付ウィンドウ内かどうか。
fn fresh(created_at: Int, now: Int) -> Bool {
  created_at >= now - window_seconds && created_at <= now + window_seconds
}

/// 既知のアカウントに一致する ["p", pubkey] タグへルーティングする。NIP-46 の
/// リクエストが持つ p タグは通常 1 つだが、複数あっても自分宛のものを選ぶ。
fn route(
  engine: Engine,
  tags: List(List(String)),
) -> Result(#(Account, String), String) {
  case p_tag_pubkeys(tags) {
    [] -> Error("no p tag")
    pubkeys ->
      list.find_map(pubkeys, dict.get(engine.accounts, _))
      |> result.replace_error(
        "no matching account for " <> string.join(pubkeys, ", "),
      )
  }
}

/// ["p", pubkey] タグの pubkey を、現れた順に取り出す。
fn p_tag_pubkeys(tags: List(List(String))) -> List(String) {
  use tag <- list.filter_map(tags)
  case tag {
    ["p", pubkey, ..] -> Ok(pubkey)
    _ -> Error(Nil)
  }
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
  case decode_request(account, incoming) {
    Error(reason) -> #(engine, Ignore(reason))
    Ok(#(conversation_key, request)) -> {
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

/// リクエストの content を復号し、JSON-RPC としてデコードする。同じ会話鍵で応答を
/// 暗号化するため、鍵も一緒に返す。
fn decode_request(
  account: Account,
  incoming: Event,
) -> Result(#(BitArray, rpc.Request), String) {
  use conversation_key <- result.try(client_conversation_key(
    account,
    incoming.pubkey,
  ))
  use plaintext <- result.try(
    nip44.decrypt(incoming.content, conversation_key)
    |> result.replace_error(undecryptable(incoming.content)),
  )
  use request <- result.map(
    rpc.decode_request(plaintext)
    |> result.replace_error("malformed request payload"),
  )
  #(conversation_key, request)
}

/// 復号できなかった content を破棄する理由。NIP-04 のペイロードは形式で見分けが
/// つくため、未対応であることが分かる理由にする。
fn undecryptable(content: String) -> String {
  case string.contains(content, "?iv=") {
    True -> "nip-04 request (unsupported)"
    False -> "undecryptable content"
  }
}

/// クライアントとの会話鍵。署名者の秘密鍵とクライアント pubkey から導出する。
fn client_conversation_key(
  account: Account,
  client_pk_hex: String,
) -> Result(BitArray, String) {
  use client_pk <- result.try(
    hex.decode(client_pk_hex) |> result.replace_error("invalid client pubkey"),
  )
  nip44.conversation_key(privkey(account), client_pk)
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
  let signer = pubkey_hex(account)
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
    "get_public_key" -> rpc.ok(request.id, pubkey_hex(account))
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
              pubkey: pubkey_hex(account),
              created_at: option.unwrap(draft.created_at, now),
              kind: draft.kind,
              tags: draft.tags,
              content: draft.content,
              sig: "",
            )
          case event.finalize(unsigned, privkey(account)) {
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
      case hex.decode(third_party_hex) {
        Error(_) -> rpc.error(request.id, "invalid third-party pubkey")
        Ok(third_party) ->
          case nip44.conversation_key(privkey(account), third_party) {
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
          pubkey: pubkey_hex(account),
          created_at: now,
          kind: event.nip46_kind,
          tags: [["p", client_pk_hex]],
          content: content,
          sig: "",
        )
      case event.finalize(unsigned, privkey(account)) {
        Ok(signed) -> Ok(signed)
        Error(_) -> Error("failed to sign response")
      }
    }
  }
}
