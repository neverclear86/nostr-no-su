//// 管理 UI のパスの定義と、状態の見せ方（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
import nostr_no_su/bunker/engine
import nostr_no_su/bunker/vault
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import support/account_actions

/// 操作のパスは、どの操作でもパスセグメントから同じ署名者と操作に戻る。
pub fn account_action_paths_round_trip_test() {
  use action <- list.each(account_actions.all)
  let assert "/" <> path = dashboard.account_action_path("abcd", action)
  assert dashboard.parse_account_action_path(string.split(path, "/"))
    == Ok(#("abcd", action))
}

/// 知らない操作のセグメントと、アカウントのページ以外のパスは操作にならない。
pub fn unknown_account_action_paths_are_rejected_test() {
  assert dashboard.parse_account_action_path(["accounts", "abcd", "nope"])
    == Error(Nil)
  assert dashboard.parse_account_action_path(["sessions", "abcd", "delete"])
    == Error(Nil)
  assert dashboard.parse_account_action_path(dashboard.new_account_segments)
    == Error(Nil)
}

/// リレーとプラグインのすべての状態と、承認待ち 1 件を持つスナップショット。
fn states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    accounts: Ok([]),
    skipped: Ok([]),
    pending: Ok([
      dashboard.PendingRow(
        token: "tok",
        signer: "abcd",
        client: "ef01",
        expires_in_seconds: 540,
        secret_mismatch: False,
        perms: "",
      ),
    ]),
    sessions: Ok([]),
    relays: Ok([
      dashboard.RelayRow(
        1,
        "wss://a",
        dashboard.Reported(relay_connection.Connected),
        dashboard.Reported(relay_connection.Disconnected),
      ),
      dashboard.RelayRow(
        2,
        "wss://b",
        dashboard.Reported(relay_connection.Disconnected),
        dashboard.Unused,
      ),
    ]),
    plugins: [
      dashboard.PluginRow("a", Some(plugin_runner.Running)),
      dashboard.PluginRow("b", Some(plugin_runner.Overloaded(dropped: 4))),
      dashboard.PluginRow(
        "c",
        Some(plugin_runner.Disabled(reason: "boom", dropped: 2)),
      ),
      dashboard.PluginRow("d", None),
    ],
  )
}

/// 提示なしと不一致の承認待ちを、失効までが長い順（作成の新しい順）に持つスナップショット。
/// 提示なしの方(`tok-1`) は権限を要求し、不一致の方（`tok-2`）は権限を要求しない。`tok-2`
/// は残り 60 秒未満で、警告のバッジを見るためのものである。
fn secret_states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    ..states(),
    pending: Ok([
      dashboard.PendingRow(
        token: "tok-1",
        signer: "abcd",
        client: "ef01",
        expires_in_seconds: 540,
        secret_mismatch: False,
        perms: "sign_event:1,nip44_encrypt",
      ),
      dashboard.PendingRow(
        token: "tok-2",
        signer: "abcd",
        client: "ef01",
        expires_in_seconds: 45,
        secret_mismatch: True,
        perms: "",
      ),
    ]),
  )
}

/// リレーとプラグインの状態は、状態ごとの色のバッジで出し、状態の語と詳細を文字で残す。
/// プラグイン由来の理由は英語のまま `lang="en"` を付けて出す。
pub fn states_are_shown_as_badges_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  let badges = [
    "<span class=\"whitespace-nowrap\">monitor</span>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">connected</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">running</span>",
    "<span class=\"badge badge-sm badge-warning whitespace-nowrap\">overloaded</span><span class=\"text-xs break-words\">(dropped 4)</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">disabled</span><span class=\"text-xs break-words\"><span lang=\"en\">boom</span> (dropped 2)</span>",
    "<span class=\"badge badge-sm badge-ghost whitespace-nowrap\">unavailable</span>",
    "<dd class=\"break-words\">540s</dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 日本語のダッシュボードでは、状態の語、件数、残り秒を日本語の形で出す。バッジの
/// クラスは英語と同じである。
pub fn japanese_states_are_translated_test() {
  let body = dashboard.render(i18n.Japanese, view.System, states())
  let badges = [
    "<span class=\"whitespace-nowrap\">監視</span>",
    "<span class=\"whitespace-nowrap\">バンカー</span>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">接続中</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">未接続</span>",
    "<span class=\"badge badge-sm badge-success whitespace-nowrap\">動作中</span>",
    "<span class=\"badge badge-sm badge-warning whitespace-nowrap\">過負荷</span><span class=\"text-xs break-words\">（破棄 4 件）</span>",
    "<span class=\"badge badge-sm badge-error whitespace-nowrap\">無効</span><span class=\"text-xs break-words\"><span lang=\"en\">boom</span>（破棄 2 件）</span>",
    "<span class=\"badge badge-sm badge-ghost whitespace-nowrap\">応答なし</span>",
    "<dd class=\"break-words\">540 秒</dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 提示なしの承認待ちは secret の行が「Not offered」、不一致は塗りの警告バッジの
/// 「Mismatch」になる。承認待ちは失効までが長い順に並ぶ。残り 60 秒未満の `tok-2` は
/// 失効までの値も警告のバッジになる。
pub fn pending_secret_is_shown_test() {
  let body = dashboard.render(i18n.English, view.System, secret_states())
  let assert Ok(#(before, after)) =
    string.split_once(
      body,
      "<dd><span class=\"badge badge-sm badge-warning whitespace-nowrap\">45s</span></dd>",
    )
  assert string.contains(
    before,
    "<dd class=\"break-words\">540s</dd><dt class=\"text-base-content/70\">Secret</dt><dd class=\"break-words\">Not offered</dd>",
  )
  assert string.contains(
    after,
    "<dt class=\"text-base-content/70\">Secret</dt><dd><span class=\"badge badge-sm badge-warning whitespace-nowrap\">Mismatch</span></dd>",
  )
}

/// 日本語では secret の見出しと値が訳される。
pub fn japanese_pending_secret_is_translated_test() {
  let body = dashboard.render(i18n.Japanese, view.System, secret_states())
  let assert Ok(#(before, after)) =
    string.split_once(
      body,
      "<dd><span class=\"badge badge-sm badge-warning whitespace-nowrap\">45 秒</span></dd>",
    )
  assert string.contains(
    before,
    "<dd class=\"break-words\">540 秒</dd><dt class=\"text-base-content/70\">secret</dt><dd class=\"break-words\">提示なし</dd>",
  )
  assert string.contains(
    after,
    "<dt class=\"text-base-content/70\">secret</dt><dd><span class=\"badge badge-sm badge-warning whitespace-nowrap\">不一致</span></dd>",
  )
}

/// secret が一致しない承認待ちの承認ページにだけ警告が出て、提示が無い承認待ちの承認
/// ページとダッシュボードの行には出ない。
pub fn wrong_secret_warning_is_shown_only_on_mismatched_approval_page_test() {
  let assert Ok([not_offered, mismatched]) = secret_states().pending

  assert string.contains(
    dashboard.approval_page(i18n.English, view.System, mismatched),
    "<div class=\"alert alert-warning\"><p><strong>The connection secret does not match.</strong> This happens when",
  )
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, mismatched),
    "<div class=\"alert alert-warning\"><p><strong>接続 secret が一致しません。</strong>secret を再生成する前の",
  )

  assert !string.contains(
    dashboard.approval_page(i18n.English, view.System, not_offered),
    "alert-warning",
  )
  assert !string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, not_offered),
    "alert-warning",
  )

  assert !string.contains(
    dashboard.render(i18n.English, view.System, secret_states()),
    "The connection secret does not match.",
  )
  assert !string.contains(
    dashboard.render(i18n.Japanese, view.System, secret_states()),
    "接続 secret が一致しません。",
  )
}

/// 要求された権限は、承認待ちの行と承認ページの両方で secret の行の直後に等幅で出る。
pub fn pending_perms_are_shown_on_rows_and_approval_page_test() {
  let assert Ok([offered, ..]) = secret_states().pending
  let expected =
    "<dd class=\"break-words\">Not offered</dd><dt class=\"text-base-content/70\">Permissions</dt><dd class=\"font-mono text-xs break-all\">sign_event:1,nip44_encrypt</dd>"

  assert string.contains(
    dashboard.render(i18n.English, view.System, secret_states()),
    expected,
  )
  assert string.contains(
    dashboard.approval_page(i18n.English, view.System, offered),
    expected,
  )
}

/// セッションの行は、クライアントの直後に権限を出し、続けて作成の時刻が並ぶ。
pub fn sessions_show_perms_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "abcd",
          client: "ef01",
          perms: "sign_event:7",
          created_at: 1_788_253_200,
          last_used_at: 1_789_276_354,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(
    body,
    "<dt class=\"text-base-content/70\">Client</dt><dd class=\"font-mono text-xs break-all\">ef01</dd><dt class=\"text-base-content/70\">Permissions</dt><dd class=\"font-mono text-xs break-all\">sign_event:7</dd><dt class=\"text-base-content/70\">Created</dt>",
  )
}

/// 権限が空のときは、承認待ちの行と承認ページ、セッションの行のいずれも「署名と暗号化は
/// 拒否します」の旨の文が出る（値は等幅にしない）。
pub fn empty_perms_say_signing_and_encryption_are_refused_test() {
  let assert Ok([_, not_requested]) = secret_states().pending
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "abcd",
          client: "ef01",
          perms: "",
          created_at: 1_788_253_200,
          last_used_at: 1_789_276_354,
        ),
      ]),
    )

  let assert Ok(#(_, sessions)) =
    string.split_once(
      dashboard.render(i18n.English, view.System, snapshot),
      "Approved sessions",
    )
  assert string.contains(
    sessions,
    "<dt class=\"text-base-content/70\">Permissions</dt><dd class=\"break-words\">None requested. Signing and encryption are refused.</dd>",
  )
  assert string.contains(
    dashboard.approval_page(i18n.English, view.System, not_requested),
    "<dd class=\"break-words\">None requested. Signing and encryption are refused.</dd>",
  )
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, not_requested),
    "<dt class=\"text-base-content/70\">権限</dt><dd class=\"break-words\">要求なし。署名と暗号化は拒否します。</dd>",
  )
}

/// 無効になったプラグインの行にだけ再有効化のフォームが付き、プラグイン名を
/// hidden 欄で送る。
pub fn only_disabled_plugins_have_a_reenable_button_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  let forms =
    string.split(body, "action=\"/plugins/reenable\"")
    |> list.length
  assert forms == 2
  assert string.contains(
    body,
    "action=\"/plugins/reenable\" method=\"post\"><input name=\"name\" type=\"hidden\" value=\"c\">",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, states()),
    "再有効化",
  )
}

/// テーマと言語のドロップダウンは、それぞれ表示中の項目に `aria-current` と `menu-active` と
/// 見えるチェックを付け、それ以外の項目はその値を POST で送るボタンにする。言語名はその言語
/// 自身の文字で出す。
pub fn navbar_dropdowns_mark_the_current_choice_test() {
  let snapshot = dashboard.Snapshot(..states(), plugins: [], relays: Ok([]))
  assert string.contains(
    dashboard.render(i18n.English, view.Dark, snapshot),
    "<div class=\"navbar-end w-auto gap-2\"><details class=\"dropdown dropdown-end\" name=\"navbar-menu\"><summary class=\"btn btn-sm focus-visible:outline-base-content\">Theme<svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-3\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M4 6l4 4 4-4\"></path></svg></summary><form action=\"/theme\" class=\"dropdown-content z-10 mt-1\" method=\"post\"><input name=\"return\" type=\"hidden\" value=\"/\"><ul class=\"menu w-48 rounded-box border border-base-300 bg-base-100 shadow-sm\"><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" name=\"theme\" type=\"submit\" value=\"system\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>Browser setting</span></button></li><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" name=\"theme\" type=\"submit\" value=\"light\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>Light</span></button></li><li><button aria-current=\"true\" class=\"menu-active focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-neutral-content\" name=\"theme\" type=\"submit\" value=\"dark\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>Dark</span></button></li></ul></form></details><details class=\"dropdown dropdown-end\" name=\"navbar-menu\"><summary class=\"btn btn-sm focus-visible:outline-base-content\">Language<svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-3\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M4 6l4 4 4-4\"></path></svg></summary><form action=\"/language\" class=\"dropdown-content z-10 mt-1\" method=\"post\"><input name=\"return\" type=\"hidden\" value=\"/\"><ul class=\"menu w-48 rounded-box border border-base-300 bg-base-100 shadow-sm\"><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" name=\"language\" type=\"submit\" value=\"system\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>Browser setting</span></button></li><li><button aria-current=\"true\" class=\"menu-active focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-neutral-content\" lang=\"en\" name=\"language\" type=\"submit\" value=\"en\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>English</span></button></li><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" lang=\"ja\" name=\"language\" type=\"submit\" value=\"ja\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>日本語</span></button></li></ul></form></details></div>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.Dark, snapshot),
    "<div class=\"navbar-end w-auto gap-2\"><details class=\"dropdown dropdown-end\" name=\"navbar-menu\"><summary class=\"btn btn-sm focus-visible:outline-base-content\">テーマ<svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-3\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M4 6l4 4 4-4\"></path></svg></summary><form action=\"/theme\" class=\"dropdown-content z-10 mt-1\" method=\"post\"><input name=\"return\" type=\"hidden\" value=\"/\"><ul class=\"menu w-48 rounded-box border border-base-300 bg-base-100 shadow-sm\"><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" name=\"theme\" type=\"submit\" value=\"system\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>ブラウザーの設定</span></button></li><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" name=\"theme\" type=\"submit\" value=\"light\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>ライト</span></button></li><li><button aria-current=\"true\" class=\"menu-active focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-neutral-content\" name=\"theme\" type=\"submit\" value=\"dark\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>ダーク</span></button></li></ul></form></details><details class=\"dropdown dropdown-end\" name=\"navbar-menu\"><summary class=\"btn btn-sm focus-visible:outline-base-content\">言語<svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-3\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M4 6l4 4 4-4\"></path></svg></summary><form action=\"/language\" class=\"dropdown-content z-10 mt-1\" method=\"post\"><input name=\"return\" type=\"hidden\" value=\"/\"><ul class=\"menu w-48 rounded-box border border-base-300 bg-base-100 shadow-sm\"><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" name=\"language\" type=\"submit\" value=\"system\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>ブラウザーの設定</span></button></li><li><button class=\"focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-base-content\" lang=\"en\" name=\"language\" type=\"submit\" value=\"en\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"invisible size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>English</span></button></li><li><button aria-current=\"true\" class=\"menu-active focus-visible:outline-2 focus-visible:outline-solid focus-visible:-outline-offset-2 focus-visible:outline-neutral-content\" lang=\"ja\" name=\"language\" type=\"submit\" value=\"ja\"><svg xmlns=\"http://www.w3.org/2000/svg\" aria-hidden=\"true\" class=\"size-4\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" viewBox=\"0 0 16 16\"><path d=\"M3 8.5l3 3 7-7\"></path></svg><span>日本語</span></button></li></ul></form></details></div>",
  )
}

/// 表の見出しは列を指す `scope="col"` を持ち、`scope` の無い `th` は出さない。
pub fn table_headers_scope_their_columns_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(body, "<th scope=\"col\">")
  assert !string.contains(body, "<th>")
}

/// 承認待ちとセッションを得られないときは、「0 件」の代わりに理由を出し、
/// 承認・拒否や取り消しのフォームも出さない。日本語では前置きも出る。
pub fn unlisted_pending_and_sessions_show_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      pending: Error(i18n.Untranslated("pending reason")),
      sessions: Error(i18n.Untranslated("sessions reason")),
    )
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(english, "<span lang=\"en\">pending reason</span>")
  assert string.contains(english, "<span lang=\"en\">sessions reason</span>")
  assert !string.contains(
    english,
    i18n.text(
      i18n.English,
      i18n.NoPendingConnections(engine.pending_ttl_minutes()),
    ),
  )
  assert !string.contains(
    english,
    i18n.text(i18n.English, i18n.NoApprovedSessions),
  )
  assert !string.contains(english, "action=\"/approve/")
  assert !string.contains(english, "action=\"/sessions/revoke\"")

  let japanese = dashboard.render(i18n.Japanese, view.System, snapshot)
  assert string.contains(
    japanese,
    "<span>承認待ちの一覧を表示できません。<span lang=\"en\">pending reason</span></span>",
  )
  assert string.contains(
    japanese,
    "<span>セッションの一覧を表示できません。<span lang=\"en\">sessions reason</span></span>",
  )
}

/// 承認済みセッションの行は、作成と最終利用を Unix 秒から RFC 3339 の UTC で出し、`time`
/// の `datetime` 属性にも同じ値を入れる。
pub fn sessions_show_created_and_last_used_times_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "abcd",
          client: "ef01",
          perms: "",
          created_at: 1_788_253_200,
          last_used_at: 1_789_276_354,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(
    body,
    "<dt class=\"text-base-content/70\">Created</dt><dd><time class=\"whitespace-nowrap tabular-nums\" datetime=\"2026-09-01T09:00:00Z\">2026-09-01T09:00:00Z</time></dd>",
  )
  assert string.contains(
    body,
    "<dt class=\"text-base-content/70\">Last used</dt><dd><time class=\"whitespace-nowrap tabular-nums\" datetime=\"2026-09-13T05:12:34Z\">2026-09-13T05:12:34Z</time></dd>",
  )
}

/// 飛ばされた行が 1 件以上あれば、見出し・警告の 1 文・識別（ラベル・npub・16 進の
/// pubkey）・理由・削除のリンクが出る。日本語でも見出しが訳される。
pub fn skipped_rows_are_listed_with_their_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey: "abcd1234",
          npub: "npub1unreadable",
          label: "old wallet",
          reason: vault.UndecryptablePrivateKey,
        ),
      ]),
    )
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(english, "Unreadable accounts")
  assert string.contains(
    english,
    "The current ACCOUNT_MASTER_KEY cannot decrypt these rows.",
  )
  assert string.contains(english, "old wallet")
  assert string.contains(english, "npub1unreadable")
  assert string.contains(english, "abcd1234")
  assert string.contains(
    english,
    "The private key cannot be decrypted (wrong ACCOUNT_MASTER_KEY or a tampered row).",
  )
  assert string.contains(english, "href=\"/accounts/abcd1234/delete\"")
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "読み込めなかったアカウント",
  )
}

/// `pubkey` 列を読めない行は、識別も削除のリンクも出さず、理由の 1 文に削除でき
/// ない旨を続けて出す。
pub fn malformed_pubkey_rows_show_only_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey: "not-a-valid-pubkey-value",
          npub: "",
          label: "",
          reason: vault.MalformedPubkey,
        ),
      ]),
    )
  let body = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(body, "The pubkey column cannot be read.")
  assert string.contains(
    body,
    "This row cannot be deleted here because its pubkey cannot be read.",
  )
  assert !string.contains(body, "not-a-valid-pubkey-value")
}

/// 飛ばされた行が 0 件、あるいは一覧を得られないときはカードを描かない。
pub fn no_skipped_rows_draws_no_card_test() {
  let empty = dashboard.Snapshot(..states(), skipped: Ok([]))
  let unavailable =
    dashboard.Snapshot(..states(), skipped: Error(i18n.Untranslated("boom")))
  use language <- list.each([i18n.English, i18n.Japanese])
  assert !string.contains(
    dashboard.render(language, view.System, empty),
    "Unreadable accounts",
  )
  assert !string.contains(
    dashboard.render(language, view.System, empty),
    "読み込めなかったアカウント",
  )
  assert !string.contains(
    dashboard.render(language, view.System, unavailable),
    "Unreadable accounts",
  )
  assert !string.contains(
    dashboard.render(language, view.System, unavailable),
    "読み込めなかったアカウント",
  )
}

/// リレーは 1 行につき `<li>` 1 件で、使っている用途を監視、バンカーの順に並べ、操作の
/// リンク（用途の編集、削除）を続ける。使っていない用途は出さず、URL は `break-all`、
/// 用途の語とバッジは `whitespace-nowrap`。
pub fn relays_are_listed_one_item_per_row_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "<ul class=\"divide-y divide-base-300\"><li class=\"flex flex-wrap items-center justify-between gap-x-6 gap-y-3 py-4 first:pt-0 last:pb-0\"><div class=\"flex min-w-0 flex-col gap-1\"><p class=\"font-mono text-xs break-all\">wss://a</p><div class=\"flex flex-wrap gap-x-4 gap-y-1 text-sm\"><span class=\"flex items-center gap-2\"><span class=\"whitespace-nowrap\">monitor</span><span class=\"badge badge-sm badge-success whitespace-nowrap\">connected</span></span><span class=\"flex items-center gap-2\"><span class=\"whitespace-nowrap\">bunker</span><span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span></span></div></div><div class=\"flex shrink-0 flex-wrap gap-2\"><a class=\"btn btn-sm focus-visible:outline-base-content\" href=\"/relays/1/edit\">Edit roles</a><a class=\"btn btn-sm btn-warning focus-visible:outline-base-content\" href=\"/relays/1/delete\">Delete relay</a></div></li><li class=\"flex flex-wrap items-center justify-between gap-x-6 gap-y-3 py-4 first:pt-0 last:pb-0\"><div class=\"flex min-w-0 flex-col gap-1\"><p class=\"font-mono text-xs break-all\">wss://b</p><div class=\"flex flex-wrap gap-x-4 gap-y-1 text-sm\"><span class=\"flex items-center gap-2\"><span class=\"whitespace-nowrap\">monitor</span><span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span></span></div></div><div class=\"flex shrink-0 flex-wrap gap-2\"><a class=\"btn btn-sm focus-visible:outline-base-content\" href=\"/relays/2/edit\">Edit roles</a><a class=\"btn btn-sm btn-warning focus-visible:outline-base-content\" href=\"/relays/2/delete\">Delete relay</a></div></li></ul>",
  )
}

/// リレーの行のリンクは、用途の編集が通常の重さ、削除が注意の重さ。
pub fn relay_rows_link_to_edit_and_delete_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "<a class=\"btn btn-sm focus-visible:outline-base-content\" href=\"/relays/1/edit\">Edit roles</a>",
  )
  assert string.contains(
    body,
    "<a class=\"btn btn-sm btn-warning focus-visible:outline-base-content\" href=\"/relays/1/delete\">Delete relay</a>",
  )
}

/// 締め切りまでに答えなかった用途（`Unanswered`）は「応答なし」のバッジになり、
/// URL と操作のリンク（用途の編集、削除）は残る。
pub fn a_relay_role_without_a_status_shows_unavailable_test() {
  let body =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(
        ..states(),
        relays: Ok([
          dashboard.RelayRow(
            1,
            "wss://a",
            dashboard.Unanswered,
            dashboard.Unused,
          ),
        ]),
      ),
    )
  assert string.contains(
    body,
    "<span class=\"whitespace-nowrap\">monitor</span><span class=\"badge badge-sm badge-ghost whitespace-nowrap\">unavailable</span>",
  )
  assert string.contains(body, "wss://a")
  assert string.contains(body, "href=\"/relays/1/edit\">Edit roles</a>")
  assert string.contains(body, "href=\"/relays/1/delete\">Delete relay</a>")
}

/// バンカーに使う行が 1 件も無ければ、見出しの直後に警告が出て一覧は出さない。監視だけの
/// 行があれば警告の後に一覧を出し、バンカーの行が 1 件でもあれば警告を出さない
/// （`states()` はバンカーの行を持つので、上のテストの描画に警告が無いことで確かめる）。
pub fn no_bunker_relay_is_warned_test() {
  let no_rows =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), relays: Ok([])),
    )
  assert string.contains(
    no_rows,
    "Relays</h2><div class=\"flex shrink-0 flex-wrap gap-2\"><a class=\"btn btn-sm btn-primary focus-visible:outline-base-content\" href=\"/relays/new\">Add relay</a></div></div><div class=\"alert alert-warning\"><span>No relay is used for the bunker. Clients cannot connect to any account until you add one.</span></div></div></section>",
  )
  let monitor_only =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(
        ..states(),
        relays: Ok([
          dashboard.RelayRow(
            1,
            "wss://a",
            dashboard.Reported(relay_connection.Connected),
            dashboard.Unused,
          ),
        ]),
      ),
    )
  assert string.contains(
    monitor_only,
    "Relays</h2><div class=\"flex shrink-0 flex-wrap gap-2\"><a class=\"btn btn-sm btn-primary focus-visible:outline-base-content\" href=\"/relays/new\">Add relay</a></div></div><div class=\"alert alert-warning\"><span>No relay is used for the bunker. Clients cannot connect to any account until you add one.</span></div><ul",
  )
  assert !string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "No relay is used for the bunker.",
  )
}

/// リレーの一覧を得られないときは、一覧の代わりに理由を出し、警告は出さない。日本語では
/// 前置きも出る。
pub fn unlisted_relays_show_the_reason_test() {
  let snapshot =
    dashboard.Snapshot(..states(), relays: Error(i18n.Untranslated("boom")))
  assert string.contains(
    dashboard.render(i18n.English, view.System, snapshot),
    "Relays</h2></div><div class=\"alert\"><span><span lang=\"en\">boom</span></span></div></div></section>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "リレー</h2></div><div class=\"alert\"><span>リレーの一覧を表示できません。<span lang=\"en\">boom</span></span></div></div></section>",
  )
}

/// 締め切りを超えた節は、上流の理由の代わりに訳した「今は取得できません。」
/// （`Not available right now.`）を出す。
pub fn a_section_past_the_deadline_says_not_available_test() {
  let snapshot =
    dashboard.Snapshot(
      ..states(),
      relays: Error(i18n.Translated(i18n.NotAvailable)),
    )
  assert string.contains(
    dashboard.render(i18n.English, view.System, snapshot),
    "Not available right now.",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "今は取得できません。",
  )
}

/// リレーの節の見出しの行は、一覧を得たときだけ追加のリンクを出す。
pub fn relays_heading_links_to_add_a_relay_test() {
  let ok = dashboard.render(i18n.English, view.System, states())
  assert string.contains(ok, "href=\"/relays/new\">Add relay</a>")

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), relays: Error(i18n.Untranslated("boom"))),
    )
  assert !string.contains(unavailable, "/relays/new")
}

/// セッションの節の見出しの行は、一覧を得たときだけクライアントの接続へのリンクを出す。
pub fn sessions_heading_links_to_connect_a_client_test() {
  let ok = dashboard.render(i18n.English, view.System, states())
  assert string.contains(ok, "href=\"/sessions/connect\">Connect a client</a>")

  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), sessions: Error(i18n.Untranslated("boom"))),
    )
  assert !string.contains(unavailable, "/sessions/connect")
}

/// アカウントの節の見出しの行には、追加のリンクと並んで読み直しのフォームが出る。
pub fn accounts_heading_has_a_reload_form_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "<form action=\"/accounts/reload\" method=\"post\">",
  )
}

/// 一覧を得られないときはアカウントの節の見出しに読み直しのフォームも出さない。
pub fn no_reload_form_without_the_account_list_test() {
  let unavailable =
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), accounts: Error(i18n.Untranslated("boom"))),
    )
  assert !string.contains(unavailable, "/accounts/reload")
}

/// 承認ページは言語を切り替えた後に同じ承認ページを、通知ページはダッシュボードを開く。
pub fn language_switch_return_paths_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, pending),
    "<input name=\"return\" type=\"hidden\" value=\"/approve/tok\">",
  )
  assert string.contains(
    dashboard.notice_page(
      i18n.Japanese,
      view.System,
      view.SwitchReturningTo("/"),
      i18n.NotFound,
      i18n.Untranslated("unknown or expired approval request"),
      view.Failure,
      [],
    ),
    "<input name=\"return\" type=\"hidden\" value=\"/\">",
  )
}

/// ダッシュボードは承認待ちを 1 件以上得たときだけ 30 秒ごとに自動で読み込み直す。
/// 空のときと一覧を得られないときは自動更新しない。
pub fn dashboard_refreshes_only_when_pending_exists_test() {
  let with_pending = dashboard.render(i18n.English, view.System, states())
  assert string.contains(with_pending, "http-equiv=\"refresh\"")
  assert string.contains(with_pending, "content=\"30\"")
  assert !string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    ),
    "http-equiv=\"refresh\"",
  )
  assert !string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Error(i18n.Untranslated("boom"))),
    ),
    "http-equiv=\"refresh\"",
  )
}

/// 承認待ちの節の見出しは、自動更新中のときだけ更新の間隔を伝える注記を出す。
pub fn pending_heading_shows_auto_refresh_note_only_when_refreshing_test() {
  assert string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "Refreshing every 30s",
  )
  assert !string.contains(
    dashboard.render(
      i18n.English,
      view.System,
      dashboard.Snapshot(..states(), pending: Ok([])),
    ),
    "Refreshing every",
  )
}

/// 承認ページは常に 30 秒ごとに自動で読み込み直すが、その移り先の通知ページは
/// 読み込みを繰り返さない。
pub fn approval_page_refreshes_automatically_test() {
  let assert Ok([pending]) = states().pending
  let approval = dashboard.approval_page(i18n.English, view.System, pending)
  assert string.contains(approval, "http-equiv=\"refresh\"")
  assert string.contains(approval, "content=\"30\"")
  assert !string.contains(
    dashboard.notice_page(
      i18n.English,
      view.System,
      view.SwitchReturningTo("/"),
      i18n.NotFound,
      i18n.Untranslated("gone"),
      view.Failure,
      [],
    ),
    "http-equiv=\"refresh\"",
  )
}

/// 承認待ちの行と承認ページには「失効まで」の欄が出る。
pub fn pending_shows_time_until_expiry_test() {
  let assert Ok([pending]) = states().pending
  assert string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "<dt class=\"text-base-content/70\">Expires in</dt><dd class=\"break-words\">540s</dd>",
  )
  assert string.contains(
    dashboard.approval_page(i18n.Japanese, view.System, pending),
    "<dt class=\"text-base-content/70\">失効まで</dt><dd class=\"break-words\">540 秒</dd>",
  )
}
