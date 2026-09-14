//// 管理 UI のパスの定義と、状態の見せ方（`admin/dashboard`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
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
    pending: Ok([
      dashboard.PendingRow(
        token: "tok",
        signer: "abcd",
        client: "ef01",
        age_seconds: 12,
        secret_mismatch: False,
      ),
    ]),
    sessions: Ok([]),
    relays: Ok([
      dashboard.RelayRow(
        1,
        "wss://a",
        Some(relay_connection.Connected),
        Some(relay_connection.Disconnected),
      ),
      dashboard.RelayRow(
        2,
        "wss://b",
        Some(relay_connection.Disconnected),
        None,
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

/// 提示なしと不一致の承認待ちを、経過時間の短い順に持つスナップショット。
fn secret_states() -> dashboard.Snapshot {
  dashboard.Snapshot(
    ..states(),
    pending: Ok([
      dashboard.PendingRow(
        token: "tok-1",
        signer: "abcd",
        client: "ef01",
        age_seconds: 12,
        secret_mismatch: False,
      ),
      dashboard.PendingRow(
        token: "tok-2",
        signer: "abcd",
        client: "ef01",
        age_seconds: 48,
        secret_mismatch: True,
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
    "<dd class=\"break-words\">12s</dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 日本語のダッシュボードでは、状態の語、件数、経過時間を日本語の形で出す。バッジの
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
    "<dd class=\"break-words\">12 秒</dd>",
  ]
  list.each(badges, fn(badge) {
    assert string.contains(body, badge)
  })
}

/// 提示なしの承認待ちは secret の行が「Not offered」、不一致は塗りの警告バッジの
/// 「Mismatch」になる。承認待ちは経過時間の短い順に並ぶ。
pub fn pending_secret_is_shown_test() {
  let body = dashboard.render(i18n.English, view.System, secret_states())
  let assert Ok(#(before, after)) =
    string.split_once(body, "<dd class=\"break-words\">48s</dd>")
  assert string.contains(
    before,
    "<dd class=\"break-words\">12s</dd><dt class=\"text-base-content/70\">Secret</dt><dd class=\"break-words\">Not offered</dd>",
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
    string.split_once(body, "<dd class=\"break-words\">48 秒</dd>")
  assert string.contains(
    before,
    "<dd class=\"break-words\">12 秒</dd><dt class=\"text-base-content/70\">secret</dt><dd class=\"break-words\">提示なし</dd>",
  )
  assert string.contains(
    after,
    "<dt class=\"text-base-content/70\">secret</dt><dd><span class=\"badge badge-sm badge-warning whitespace-nowrap\">不一致</span></dd>",
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
      pending: Error("pending reason"),
      sessions: Error("sessions reason"),
    )
  let english = dashboard.render(i18n.English, view.System, snapshot)
  assert string.contains(english, "<span lang=\"en\">pending reason</span>")
  assert string.contains(english, "<span lang=\"en\">sessions reason</span>")
  assert !string.contains(
    english,
    i18n.text(i18n.English, i18n.NoPendingConnections),
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

/// リレーは 1 行につき `<li>` 1 件で、使っている用途を監視、バンカーの順に並べる。
/// 使っていない用途は出さず、URL は `break-all`、用途の語とバッジは `whitespace-nowrap`。
pub fn relays_are_listed_one_item_per_row_test() {
  let body = dashboard.render(i18n.English, view.System, states())
  assert string.contains(
    body,
    "<ul class=\"divide-y divide-base-300\"><li class=\"flex flex-wrap items-center justify-between gap-x-6 gap-y-3 py-4 first:pt-0 last:pb-0\"><div class=\"flex min-w-0 flex-col gap-1\"><p class=\"font-mono text-xs break-all\">wss://a</p><div class=\"flex flex-wrap gap-x-4 gap-y-1 text-sm\"><span class=\"flex items-center gap-2\"><span class=\"whitespace-nowrap\">monitor</span><span class=\"badge badge-sm badge-success whitespace-nowrap\">connected</span></span><span class=\"flex items-center gap-2\"><span class=\"whitespace-nowrap\">bunker</span><span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span></span></div></div></li><li class=\"flex flex-wrap items-center justify-between gap-x-6 gap-y-3 py-4 first:pt-0 last:pb-0\"><div class=\"flex min-w-0 flex-col gap-1\"><p class=\"font-mono text-xs break-all\">wss://b</p><div class=\"flex flex-wrap gap-x-4 gap-y-1 text-sm\"><span class=\"flex items-center gap-2\"><span class=\"whitespace-nowrap\">monitor</span><span class=\"badge badge-sm badge-error whitespace-nowrap\">disconnected</span></span></div></div></li></ul>",
  )
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
    "Relays</h2><div class=\"alert alert-warning\"><span>No relay is used for the bunker. Clients cannot connect to any account until you add one.</span></div></div></section>",
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
            Some(relay_connection.Connected),
            None,
          ),
        ]),
      ),
    )
  assert string.contains(
    monitor_only,
    "Relays</h2><div class=\"alert alert-warning\"><span>No relay is used for the bunker. Clients cannot connect to any account until you add one.</span></div><ul",
  )
  assert !string.contains(
    dashboard.render(i18n.English, view.System, states()),
    "No relay is used for the bunker.",
  )
}

/// リレーの一覧を得られないときは、一覧の代わりに理由を出し、警告は出さない。日本語では
/// 前置きも出る。
pub fn unlisted_relays_show_the_reason_test() {
  let snapshot = dashboard.Snapshot(..states(), relays: Error("boom"))
  assert string.contains(
    dashboard.render(i18n.English, view.System, snapshot),
    "Relays</h2><div class=\"alert\"><span><span lang=\"en\">boom</span></span></div></div></section>",
  )
  assert string.contains(
    dashboard.render(i18n.Japanese, view.System, snapshot),
    "リレー</h2><div class=\"alert\"><span>リレーの一覧を表示できません。<span lang=\"en\">boom</span></span></div></div></section>",
  )
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
