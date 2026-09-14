import gleam/erlang/process.{type Name}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/app
import nostr_no_su/bunker
import nostr_no_su/bunker/account_store
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault
import nostr_no_su/config.{type Config}
import nostr_no_su/dedup
import nostr_no_su/dedup/resume_store
import nostr_no_su/log
import nostr_no_su/nostr/event
import nostr_no_su/plugin.{type Plugin}
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/plugins/console_logger
import nostr_no_su/relay_client
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import nostr_no_su/relay_store
import nostr_no_su/time
import pog

/// 起動処理そのものが出すログ行の接頭辞。
const log_prefix = "main"

/// 監視ディスパッチャーがリレー間の重複排除のために記憶する直近イベント id の
/// 件数（正確な上限は `dedup` を参照）。
const dedup_capacity = 4096

/// バンカーの購読が現在時刻からどれだけ遡るか。切断していた間に届いたリクエストを
/// 取りこぼさないための猶予。クライアントは数十秒で応答を諦めるため、これより古い
/// リクエストには待っている相手がいない。
const bunker_since_lookback_seconds = 60

/// `wss://` 接続が依存する `ssl` アプリケーションを起動する。
@external(erlang, "nostr_no_su_ffi", "ensure_ssl_started")
fn ensure_ssl_started() -> Nil

/// 終了コード `status` で VM を直ちに止める。既定のログハンドラーは少ない件数を
/// 非同期に書くため、直前のログ行が書き出される保証は無い。失敗として終了する
/// ときは `exit_with_failure` を使うこと。`main` が返ると、生成されたエントリー
/// ポイントが終了コード 0 で止める。
@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

/// 溜まったログ行を書き終えてから終了コード 1 で VM を止める。
fn exit_with_failure() -> Nil {
  log.flush()
  halt(1)
}

/// 起動時に組み立てたツリーの仕様と、その報告行。組み立てから出力を分けることで、
/// 何をどう報告するかが `main` の 1 か所に集まる。
pub type Startup {
  Startup(spec: app.Spec, notes: List(String))
}

/// 設定されたアカウントのスーパービジョンツリーを起動し、以降は待機する。ここから
/// 先はプロセスの監視・再起動・再配線をすべてツリーが担う。バンカーか管理 UI を
/// 起動できない設定なら、理由を 1 行出して終了コード 1 で終了する。
pub fn main() -> Nil {
  log.configure()
  ensure_ssl_started()
  case startup(config.load()) {
    Error(reason) -> {
      log.write(log.Error, log_prefix, "cannot start: " <> reason)
      exit_with_failure()
    }
    Ok(started) -> {
      list.each(started.notes, log.write_line(log.Notice, _))
      // ツリーが起動しないのはバグか設定の不備なので、中途半端な状態で待機せず
      // クラッシュさせる。コンテナーの再起動はプロセスの終了で起き、終了コードは
      // 失敗を示す。
      let assert Ok(_started) = app.start(started.spec)
        as "supervision tree failed to start"
      process.sleep_forever()
    }
  }
}

/// 読み込んだ設定に対して動かすツリーと、その報告行。プロセス名はここで一度だけ
/// 生成して下へ渡すため、再起動したアクターは接続の送信先となる名前を再登録する。
/// 出力は行わず、報告する内容は文字列として返す。
/// バンカーか管理 UI を起動できない設定なら、プラグインの読み込みより前にその理由を
/// 返す。
///
/// 外部プラグインの読み込みは監視のリレーの有無に関わらず行う。読み込んだ
/// プラグインは監視のリレーが 0 本でも動く。ルート直下の `plugins` サブツリーで
/// 動き、ダッシュボードにも状態が出る。監視のツリーは常に起動し、リレーが無い間は
/// 配信されるイベントが無いだけである。
///
/// テストが本番と同じ仕様でツリーを動かせるよう公開する。
pub fn startup(loaded: Config) -> Result(Startup, String) {
  use console_logger_enabled <- result.try(loaded.console_logger_enabled)
  use bunker <- result.try(bunker_spec(loaded))
  use #(admin, admin_notes) <- result.map(admin_spec(loaded))
  let builtin = builtin_plugins(console_logger_enabled)
  let #(external, plugin_notes) =
    plugin_loader.load_all(
      loaded.plugin_dir,
      [console_logger.name],
      loaded.plugin_env,
      plugin.default_call_timeout_ms,
    )
  let specs = plugin_specs(list.append(builtin, external))
  Startup(
    spec: app.Spec(
      plugins: specs,
      monitor: monitor_spec(bunker),
      bunker: bunker,
      admin: admin,
      open: app.open_websocket,
      reconnect_delay: relay_connection.default_reconnect_delay,
      relay_list: process.new_name("nostr_no_su_relay_list"),
    ),
    notes: list.flatten([plugin_notes, admin_notes]),
  )
}

/// プラグインごとにランナープロセスの名前を作る。名前はここで 1 度だけ作り、
/// ディスパッチャーの宛先と管理 UI の問い合わせ先に共用する。再起動したランナー
/// は同じ名前を登録し直すので、どちらの配線もやり直す必要がない。
fn plugin_specs(plugins: List(Plugin)) -> List(app.PluginSpec) {
  use item <- list.map(plugins)
  app.PluginSpec(
    name: process.new_name("nostr_no_su_plugin"),
    plugin: item,
    limits: plugin_runner.default_limits,
  )
}

/// 監視サブツリー。起動時のリレーは常に空で、行はバンカーの読み込みから
/// `OpenRegistered` で届く（`app.gleam` の doc）。購読はバンカーの署名者と
/// 再開点から組み立て（`monitor_subscriptions`）、再開点はアカウントストアと
/// 同じ DB に保存する。除外する kind の既定は ephemeral 全般
/// （`event.is_ephemeral`）。バンカーの NIP-46 の応答を含む。
fn monitor_spec(bunker: app.Bunker) -> app.Monitor {
  let name = process.new_name("nostr_no_su_dedup")
  app.Monitor(
    name: name,
    dedup_capacity: dedup_capacity,
    relays: [],
    subscriptions: monitor_subscriptions(
      bunker.name,
      name,
      resume_point_loader(bunker.pool.pool_name),
      _,
    ),
    save_resume: resume_point_saver(bunker.pool.pool_name),
    excludes_kind: event.is_ephemeral,
  )
}

/// 監視リレー `relay_url` の購読の定義。評価のたびにバンカーの現在の署名者から
/// 組み立て、署名者がいれば `since` をディスパッチャーのメモリの再開点から、無ければ
/// 保存済みの再開点（`load`）から決める。どれかに応答が無ければ定義を得られなかった
/// ことにし、開いている購読を閉じない。テストが本番と同じ定義でツリーを動かせるよう
/// 公開する。
pub fn monitor_subscriptions(
  bunker_name: Name(bunker.Msg),
  dedup_name: Name(dedup.Msg),
  load: fn(String) -> Result(Option(Int), String),
  relay_url: String,
) -> relay_client.Subscriptions {
  fn() {
    use signers <- result.try(
      bunker.signers(bunker_name) |> option.to_result(Nil),
    )
    use <- config.monitor_subscriptions(signers)
    use in_memory <- result.try(dedup.since(dedup_name, relay_url))
    case in_memory {
      Some(_) -> Ok(in_memory)
      None -> load(relay_url) |> result.replace_error(Nil)
    }
  }
}

/// リレーの保存済みの再開点を読む操作（`resume_store.load`）。購読の評価の再試行の
/// 行は理由を含まないので、失敗の理由はここで 1 行出してから返す。
fn resume_point_loader(
  pool: Name(pog.Message),
) -> fn(String) -> Result(Option(Int), String) {
  fn(relay_url: String) {
    let db = pog.named_connection(pool)
    resume_store.load(db, relay_url)
    |> result.map_error(fn(error) {
      let reason = account_store.describe(error)
      log.write(
        log.Warning,
        log.relay_prefix(relay_client.label(relay_url)),
        "could not load resume point: " <> reason,
      )
      reason
    })
  }
}

/// 再開点を値を小さくせずに保存する操作（`resume_store.save`）。ログは
/// `resume_saver` が出す。
fn resume_point_saver(
  pool: Name(pog.Message),
) -> fn(List(#(String, Int))) -> Result(Nil, String) {
  fn(points: List(#(String, Int))) {
    let db = pog.named_connection(pool)
    resume_store.save(db, points)
    |> result.map_error(account_store.describe)
  }
}

/// 本体に内蔵されたプラグイン。外部プラグインはローダーが返し、このリストの
/// 後ろに繋がれる。並び順が決めるのは読み込みと表示の順序だけで、実行は
/// プラグインごとの独立したランナーが行う。内蔵プラグインは子仕様を持たない
/// （`children: []`）。イベント保存は外部プラグイン `event_logger` の仕事に
/// なったので、ここには含まれない。
/// **内蔵プラグインは `plugin.load` を通らないので設定 map を受け取らない。**
/// 内蔵プラグインの設定は `config.gleam` が読む。`PLUGIN_CONSOLE_LOGGER_ENABLED`
/// だけがある。
///
/// `enabled` が `False` なら空リストを返す。予約名（`console_logger.name`）は
/// 無効時も外部プラグインに使わせないため、呼び出し側で別に渡す。
fn builtin_plugins(enabled: Bool) -> List(Plugin) {
  case enabled {
    True -> [console_logger.new()]
    False -> []
  }
}

/// 承認待ちの token から、クライアントへ渡す承認ページの URL を組み立てる関数。
/// 管理 UI の公開 URL に承認ページのパスを繋ぐだけで、パスの形を知っているのは
/// 管理 UI 側（`dashboard`）だけになる。管理 UI が無効なら承認フローも無効。
fn auth_url(loaded: Config) -> Option(fn(String) -> String) {
  use base <- option.map(config.auth_url_base(loaded))
  fn(token) { base <> dashboard.approve_path(token) }
}

/// バンカーサブツリー。アカウントストアの設定が揃わないか不正なら、その理由を
/// 返す。アカウントはアクターが起動後にストアから読むので、ここではアカウントの
/// 件数を知らず、0 件でも起動する。起動時のリレーは常に空で、行はバンカーの
/// 読み込みから `OpenRegistered` で届く（`app.gleam` の doc）。
///
/// マスターキーはストアの操作のクロージャーにだけ捕捉され、ツリーの仕様の他の部分と
/// 管理 UI には渡らない。ロックのプールの名前もこのクロージャーに捕捉される。購読は
/// 接続と張り直しのたびに現在の署名者から組み立て直すため、`since` もその時点の
/// 現在時刻から決まる。署名者を問い合わせられなければ定義を得られなかったことにし、
/// 開いている購読を閉じない。
fn bunker_spec(loaded: Config) -> Result(app.Bunker, String) {
  use #(pool, lock_pool, master_key) <- result.map(bunker_store(loaded))
  let name = process.new_name("nostr_no_su_bunker")
  app.Bunker(
    name: name,
    pool: pool,
    lock_pool: lock_pool,
    settings: bunker.Settings(
      store: account_store_operations(
        pool.pool_name,
        lock_pool.pool_name,
        master_key,
        account_store.default_timeouts,
      ),
      auth_url: auth_url(loaded),
      retry_delay: bunker.default_retry_delay,
    ),
    relays: [],
    subscriptions: fn() {
      bunker.signers(name)
      |> option.to_result(Nil)
      |> result.map(config.bunker_subscriptions(
        _,
        time.now_seconds() - bunker_since_lookback_seconds,
      ))
    },
  )
}

/// アカウントストアの操作。プールの名前とマスターキーはこのクロージャーにだけ
/// 捕捉される。失敗は値を含まない説明に写し、書き込みの失敗は書き込まれていることが
/// あるかどうかを区別する。削除は行が無いことを成功として扱う。
///
/// 追加の `AlreadyRegistered` は `bunker.AlreadyStored` に写す。バンカーはメモリに無い
/// 公開鍵にだけ追加を書き込むので、DB に行があるのは、DB がメモリより先行しているか、
/// 読み込みで飛ばされた行があることを意味し、バンカーはそれを読み直して確かめる。
///
/// 期限を受け取るのは、実際の DB を使う統合テストが負荷の高い環境でも収まる期限を
/// 渡せるようにするためである。本番は `account_store.default_timeouts` を渡す。
///
/// 読み込みの前に `lock_pool` のセッションで advisory lock を取り直す。読み込みが
/// `SchemaTooNew` か `HeldByAnotherInstance` を返したら、どちらも再試行しても変わら
/// ないので、理由を 1 行出して VM を止める（`halt_if_cannot_continue`）。バンカー
/// アクターには戻らない。
///
/// `write` はエンジンのセッションと承認待ちの書き込み 1 件を `account_store` の
/// 関数に写す（`write_session_state`）。`load` はアカウントと一緒にセッション、
/// 承認待ち、登録されたリレーを返す（`load_snapshot`）。
pub fn account_store_operations(
  pool: Name(pog.Message),
  lock_pool: Name(pog.Message),
  master_key: vault.MasterKey,
  timeouts: account_store.Timeouts,
) -> bunker.Store {
  let db = pog.named_connection(pool)
  let lock_db = pog.named_connection(lock_pool)
  bunker.Store(
    load: fn() {
      account_store.acquire_lock(
        lock_db,
        account_store.instance_lock_key,
        timeouts,
      )
      |> result.try(fn(_locked) { load_snapshot(pool, master_key, timeouts) })
      |> halt_if_cannot_continue
      |> result.map_error(account_store.describe)
    },
    insert: fn(entry) {
      account_store.insert(db, master_key, entry, timeouts)
      |> result.map_error(fn(error) {
        case error {
          account_store.AlreadyRegistered ->
            bunker.AlreadyStored(account_store.describe(error))
          _ -> write_failure(error)
        }
      })
    },
    delete: fn(signer) {
      account_store.delete(db, signer, timeouts)
      |> account_store.deleted_or_absent
      |> result.map_error(write_failure)
    },
    update_secret: fn(signer, secret) {
      account_store.update_secret(db, master_key, signer, secret, timeouts)
      |> result.map_error(write_failure)
    },
    update_label: fn(signer, label) {
      account_store.update_label(db, signer, label, timeouts)
      |> result.map_error(write_failure)
    },
    write: fn(change) {
      write_session_state(pool, db, timeouts, change)
      |> result.map_error(write_failure)
    },
  )
}

/// エンジンの書き込み 1 件を `account_store` の関数に写す。`delete_session` と
/// `delete_pending` は行が無くても `Ok`（`account_store.gleam:574-586`、
/// `:609-620`）なので `deleted_or_absent` は通さない。
fn write_session_state(
  pool: Name(pog.Message),
  db: pog.Connection,
  timeouts: account_store.Timeouts,
  change: engine.Write,
) -> Result(Nil, account_store.StoreError) {
  case change {
    engine.InsertSession(session:) ->
      account_store.insert_session(
        db,
        timeouts,
        signer: session.signer,
        client: session.client,
        perms: session.perms,
        now: session.created_at,
      )
    engine.DeleteSession(signer:, client:) ->
      account_store.delete_session(db, timeouts, signer:, client:)
    engine.InsertPending(pending:, replaced:) ->
      account_store.insert_pending_replacing(
        pool,
        timeouts,
        pending: stored_pending(pending),
        replaced: replaced,
      )
    engine.DeletePending(token:) ->
      account_store.delete_pending(db, timeouts, token:)
    engine.ApprovePending(token:, session:) ->
      account_store.approve(
        pool,
        timeouts,
        token: token,
        signer: session.signer,
        client: session.client,
        perms: session.perms,
        now: session.created_at,
      )
  }
}

/// 1 つのトランザクション（`account_store.transaction`、期限 `load_ms`）で、
/// 移行を含む `load_within` の後に `relay_store.list` を読み（`relays` は移行で
/// 作られるので順を変えない）、バンカーの読み込みの結果にする。統合テストが
/// ロックを通さずに呼べるよう公開する。
pub fn load_snapshot(
  pool: Name(pog.Message),
  key: vault.MasterKey,
  timeouts: account_store.Timeouts,
) -> Result(bunker.Snapshot, account_store.StoreError) {
  use db <- account_store.transaction(pool, timeouts.load_ms)
  use stored <- result.try(account_store.load_within(db, key, timeouts))
  use relays <- result.try(relay_store.list(db, timeouts))
  Ok(bunker_snapshot(stored, relays))
}

/// DB から読んだ行を、バンカーの読み込みの結果（エンジンの型）にする。
fn bunker_snapshot(
  stored: account_store.Stored,
  relays: List(relay_store.Relay),
) -> bunker.Snapshot {
  bunker.Snapshot(
    accounts: stored.accounts,
    sessions: list.map(stored.sessions, fn(session) {
      engine.Session(
        signer: session.signer,
        client: session.client,
        perms: session.perms,
        created_at: session.created_at,
        last_used_at: session.last_used_at,
      )
    }),
    pending: list.map(stored.pending, fn(pending) {
      engine.Pending(
        token: pending.token,
        signer: pending.signer,
        client: pending.client,
        request_id: pending.request_id,
        perms: pending.perms,
        secret_mismatch: pending.secret_mismatch,
        created_at: pending.created_at,
      )
    }),
    relays: list.map(relays, fn(relay) {
      relay_list.Registered(url: relay.url, roles: relay.roles)
    }),
  )
}

/// エンジンの承認待ちを DB の行の型にする。
fn stored_pending(pending: engine.Pending) -> account_store.StoredPending {
  account_store.StoredPending(
    token: pending.token,
    signer: pending.signer,
    client: pending.client,
    request_id: pending.request_id,
    perms: pending.perms,
    secret_mismatch: pending.secret_mismatch,
    created_at: pending.created_at,
  )
}

/// 読み込みの結果が、再試行しても変わらない失敗（DB のスキーマがビルドより新しい、
/// 別のインスタンスが同じ DB を使っている）を示していたら、`cannot continue: <理由>`
/// を 1 行出して終了コード 1 で VM を止める（`exit_with_failure`）。それ以外の
/// 結果はそのまま返る。
fn halt_if_cannot_continue(
  loaded: Result(a, account_store.StoreError),
) -> Result(a, account_store.StoreError) {
  case loaded {
    Error(account_store.SchemaTooNew(..) as error)
    | Error(account_store.HeldByAnotherInstance(..) as error) -> {
      log.write(
        log.Error,
        log_prefix,
        "cannot continue: " <> account_store.describe(error),
      )
      exit_with_failure()
      loaded
    }
    _ -> loaded
  }
}

/// 書き込みの失敗を、書き込まれていることがあるかどうかの区別つきでバンカーへ渡す形に
/// 写す。
fn write_failure(error: account_store.StoreError) -> bunker.WriteFailure {
  let reason = account_store.describe(error)
  case account_store.may_have_been_written(error) {
    True -> bunker.MaybeWritten(reason)
    False -> bunker.NotWritten(reason)
  }
}

/// アカウントストアの接続プールの設定、ロック専用のプールの設定、マスターキー。
/// 設定が揃わない、あるいは `DATABASE_URL` を解釈できなければ理由を返す。理由は
/// 値を含まない。
fn bunker_store(
  loaded: Config,
) -> Result(#(pog.Config, pog.Config, vault.MasterKey), String) {
  case loaded.account_store {
    config.AccountStoreUnavailable(reason) -> Error(reason)
    config.AccountStore(database_url:, master_key:) ->
      account_store.pool_config(
        process.new_name("nostr_no_su_account_pool"),
        database_url,
      )
      |> result.map(fn(pool) {
        let lock_pool =
          account_store.lock_pool_config(
            process.new_name("nostr_no_su_account_lock_pool"),
            pool,
          )
        #(pool, lock_pool, master_key)
      })
  }
}

/// 管理 UI の仕様と、その報告行。`ADMIN_PORT` が空なら黙って無効にし、値が不正な
/// ときは理由を報告してから無効にする。待ち受けるのに `ADMIN_PASSWORD` が無ければ、
/// その理由を返す。
fn admin_spec(
  loaded: Config,
) -> Result(#(Option(app.Admin), List(String)), String) {
  case loaded.admin_ui {
    config.MissingPassword(reason) -> Error(reason)
    config.Disabled ->
      Ok(
        #(None, [
          log.line(admin.log_prefix, "ADMIN_PORT is empty; admin UI disabled"),
        ]),
      )
    config.Invalid(reason) ->
      Ok(#(None, [log.line(admin.log_prefix, reason <> "; admin UI disabled")]))
    config.Listen(port:, password:) ->
      Ok(#(Some(app.Admin(bind: loaded.admin_bind, port:, password:)), []))
  }
}
