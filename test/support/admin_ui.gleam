//// 描画した管理 UI のページを使う検査が共有する、ページと静的ファイルの読み出し。配信する
//// 静的ファイル（`priv/static/`）と突き合わせる `stylesheet_test` と `script_test`、日本語の
//// ページの英文を見る `japanese_pages_test` が使う。
////
//// `view.gleam` に部品を足したら `components` にもその部品を足す。

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import nostr_no_su/admin/account_pages
import nostr_no_su/admin/connect_pages
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/plugin_pages
import nostr_no_su/admin/relay_pages
import nostr_no_su/admin/session_pages
import nostr_no_su/admin/view
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import nostr_no_su/relay_list.{Roles}
import nostr_no_su/relay_store
import support/account_actions

/// ファイルの中身を読む。
@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// URL のパスセグメントが指す静的ファイルの中身。ルーティングが `priv` の下の同じパスから
/// 配信するので、セグメントの定義（`view.stylesheet_segments` など）から読む。
pub fn static_file(segments: List(String)) -> String {
  let assert Ok(bytes) = read_file("priv" <> view.segments_path(segments))
  let assert Ok(content) = bit_array.to_string(bytes)
  content
}

/// 状態ごとに違うクラスと属性がすべて現れるよう、描画のどの分岐も通したページ。渡された言語で
/// 描画し、言語の切り替えの項目（表示している言語とそれ以外）と、切り替えを出さない秘密鍵の
/// ページを通す。テーマの一覧の項目（`view.themes` ごとの表示中の項目の 3 通り）は、
/// ダッシュボードをテーマごとに描画して通す。ほかのページは `view.System` で描画する。描画に
/// 状態の分岐を足したら、ここにもその状態のページを足す。
pub fn pages(language: i18n.Language) -> List(String) {
  let row =
    dashboard.AccountRow(
      signer: "0123",
      npub: "npub1example",
      label: "label-a",
      uri: "bunker://0123?relay=x&secret=s",
      auth_uri: "bunker://0123?relay=x",
    )
  let pending =
    dashboard.PendingRow(
      token: "tok",
      signer: "0123",
      client: "4567",
      expires_in_seconds: 540,
      secret_mismatch: False,
      perms: "sign_event:1",
    )
  let empty =
    dashboard.Snapshot(
      accounts: Ok([]),
      skipped: Ok([]),
      pending: Ok([]),
      relays: Ok([]),
      sessions: Ok([]),
      plugins: [],
      not_loaded_plugins: [],
      now: 2000,
    )
  let pending_mismatch =
    dashboard.PendingRow(
      token: "tok2",
      signer: "0123",
      client: "4567",
      expires_in_seconds: 45,
      secret_mismatch: True,
      perms: "",
    )
  // アカウント一覧に無い署名者。`japanese_pages_have_no_english_words_test` が
  // 短縮した 16 進の英字を未知語として拾うので、数字だけの値にする。
  let pending_unknown_signer =
    dashboard.PendingRow(
      token: "tok3",
      signer: "9999888877776666555544443333222211110000999988887777666655554444",
      client: "4567",
      expires_in_seconds: 540,
      secret_mismatch: False,
      perms: "",
    )
  let full =
    dashboard.Snapshot(
      accounts: Ok([row]),
      skipped: Ok([
        dashboard.SkippedRow(
          pubkey: "8901",
          npub: "npub1example",
          label: "label-b",
          reason: vault.UndecryptablePrivateKey,
        ),
        dashboard.SkippedRow(
          pubkey: "not-a-pubkey",
          npub: "",
          label: "",
          reason: vault.MalformedPubkey,
        ),
      ]),
      pending: Ok([pending, pending_mismatch, pending_unknown_signer]),
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
          dashboard.Reported(relay_connection.Connected),
          dashboard.Unused,
        ),
      ]),
      sessions: Ok([
        dashboard.SessionRow(
          signer: "0123",
          client: "4567",
          perms: "",
          created_at: 1000,
          last_used_at: 1000,
        ),
      ]),
      plugins: [
        dashboard.PluginRow("plugin-a", Some(plugin_runner.Running), pages: []),
        dashboard.PluginRow(
          "plugin-b",
          Some(plugin_runner.Overloaded(dropped: 1)),
          pages: [],
        ),
        dashboard.PluginRow(
          "plugin-c",
          Some(plugin_runner.Disabled(reason: "boom", dropped: 1)),
          pages: [],
        ),
        dashboard.PluginRow("plugin-d", None, pages: []),
      ],
      not_loaded_plugins: [
        plugin_loader.NotLoaded(
          id: "demo_plugin",
          reason: "unsupported api version 2 (expected 1)",
        ),
        plugin_loader.NotLoaded(
          id: "broken-bundle",
          reason: "no ebin directory found (expected broken-bundle/ebin or broken-bundle/*/ebin)",
        ),
      ],
      now: 2000,
    )
  let reason = i18n.Untranslated("reason")
  list.flatten([
    list.map(view.themes, dashboard.render(language, _, full)),
    [
      dashboard.render(language, view.System, empty),
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(
          ..empty,
          accounts: Error(i18n.Untranslated("reason")),
          pending: Error(i18n.Untranslated("reason")),
          relays: Error(i18n.Untranslated("reason")),
          sessions: Error(i18n.Untranslated("reason")),
        ),
      ),
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(
          ..empty,
          relays: Ok([
            dashboard.RelayRow(
              1,
              "wss://a",
              dashboard.Reported(relay_connection.Connected),
              dashboard.Unused,
            ),
          ]),
        ),
      ),
      dashboard.approval_page(language, view.System, Ok([row]), pending),
      account_pages.new_account_page(language, view.System, "", Some(reason)),
      account_pages.generated_key_page(
        language,
        view.System,
        "npub1example",
        "nsec1example",
        "",
        Some(account_pages.InvalidLabel(i18n.LabelHasControlCharacters)),
      ),
      account_pages.registered_page(
        language,
        view.System,
        "npub1example",
        "label-a",
        "nsec1example",
      ),
      account_pages.private_key_page(language, view.System, row, "nsec1example"),
      account_pages.unreadable_delete_page(
        language,
        view.System,
        dashboard.SkippedRow(
          pubkey: "8901",
          npub: "npub1example",
          label: "label-b",
          reason: vault.UndecryptablePrivateKey,
        ),
        Some(reason),
      ),
      relay_pages.new_relay_page(
        language,
        view.System,
        "",
        Roles(True, True),
        None,
      ),
      relay_pages.new_relay_page(
        language,
        view.System,
        "https://relay.example",
        Roles(False, True),
        Some(reason),
      ),
      relay_pages.relay_action_page(
        language,
        view.System,
        relay_store.Relay(1, "wss://a", Roles(True, True)),
        dashboard.EditRelayRoles,
        Some(Roles(False, False)),
        Some(dashboard.RelayRow(
          1,
          "wss://a",
          dashboard.Reported(relay_connection.Connected),
          dashboard.Unused,
        )),
        Some(i18n.Translated(i18n.RelayRoleRequired)),
      ),
      relay_pages.relay_action_page(
        language,
        view.System,
        relay_store.Relay(1, "wss://a", Roles(True, True)),
        dashboard.DeleteRelay,
        None,
        None,
        Some(reason),
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Ok([row]),
        "",
        "",
        None,
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Ok([row]),
        "nostrconnect://0123",
        row.signer,
        Some(i18n.Translated(i18n.NotNostrconnectUri)),
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Ok([]),
        "",
        "",
        None,
      ),
      connect_pages.connect_client_page(
        language,
        view.System,
        Error(reason),
        "",
        "",
        None,
      ),
      // 無宣言（既定）
      session_pages.session_permissions_page(
        language,
        view.System,
        Ok(dashboard.SessionRow(
          signer: "0123",
          client: "4567",
          perms: "",
          created_at: 1000,
          last_used_at: 1000,
        )),
        None,
        None,
      ),
      // 宣言あり、そのほかの宣言も含む
      session_pages.session_permissions_page(
        language,
        view.System,
        Ok(dashboard.SessionRow(
          signer: "0123",
          client: "4567",
          perms: "sign_event:1,nip04_encrypt",
          created_at: 1000,
          last_used_at: 1000,
        )),
        None,
        None,
      ),
      // 保存の失敗（409 の描き直し）
      session_pages.session_permissions_page(
        language,
        view.System,
        Ok(dashboard.SessionRow(
          signer: "0123",
          client: "4567",
          perms: "sign_event",
          created_at: 1000,
          last_used_at: 1000,
        )),
        Some(session_pages.PermissionsForm(
          sign_event: True,
          nip44_encrypt: False,
          nip44_decrypt: False,
          kinds: "",
          other: "",
        )),
        Some(reason),
      ),
      // 一覧を得られない
      session_pages.session_permissions_page(
        language,
        view.System,
        Error(reason),
        None,
        None,
      ),
    ],
    list.map(
      [
        account_pages.NotApplied("reason"),
        account_pages.NotAccepted("reason"),
        account_pages.NotConfirmed(i18n.StoreDidNotConfirm),
      ],
      fn(problem) {
        account_pages.generated_key_page(
          language,
          view.System,
          "npub1example",
          "nsec1example",
          "label-a",
          Some(problem),
        )
      },
    ),
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure],
      dashboard.notice_page(
        language,
        view.System,
        view.SwitchReturningTo("/"),
        i18n.NotFound,
        reason,
        _,
        [],
      ),
    ),
    [
      dashboard.notice_page(
        language,
        view.System,
        view.SwitchReturningTo("/"),
        i18n.ChangeNotConfirmed,
        reason,
        view.Warning,
        [view.hint("ヒント")],
      ),
      dashboard.notice_page(
        language,
        view.System,
        view.NoSwitch,
        i18n.BadRequest,
        i18n.Translated(i18n.OriginMismatch),
        view.Failure,
        [],
      ),
    ],
    list.map(account_actions.with_form, account_pages.account_action_page(
      language,
      view.System,
      row,
      _,
      None,
      Some(reason),
    )),
    [
      account_pages.connection_qr_page(
        language,
        view.System,
        row,
        Ok([
          dashboard.RelayRow(
            1,
            "wss://a",
            dashboard.Unused,
            dashboard.Reported(relay_connection.Connected),
          ),
        ]),
      ),
      account_pages.connection_qr_page(language, view.System, row, Ok([])),
      account_pages.connection_qr_page(
        language,
        view.System,
        row,
        Error(i18n.Untranslated("relay list did not answer")),
      ),
      account_pages.connection_qr_page(
        language,
        view.System,
        dashboard.AccountRow(..row, uri: string.repeat("0", 3000)),
        Ok([]),
      ),
    ],
    [
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        [plugin_section("a", [plugin_text_block("example")])],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_two_pages,
        plugin_status_page,
        [plugin_section("b", [plugin_text_block("label")])],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        [],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        [
          plugin_section("c", [plugin_text_block("plugin")]),
          plugin_missing_title_section(),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_disabled,
        plugin_status_page,
        [plugin_section("d", [plugin_text_block("a")])],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        [
          plugin_section("a", [
            plugin_form_block("example", "label", "plugin", "b"),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        [
          plugin_section("a", [
            plugin_details_block("example", "label"),
            plugin_pairs_block([
              #("plugin", plugin_id_inline("01234567890123456789")),
            ]),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        [
          plugin_section("a", [
            plugin_image_block("http://example.com/a.png", "example"),
            plugin_image_block("data:image/png;base64,AAA", "picture"),
          ]),
        ],
      ),
    ],
  ])
}

/// ページを 1 件だけ供給するプラグインの行（タブ無しを撮るため）。表示名は
/// `allowed_words`（`test/japanese_pages_test.gleam`）に無い語にし、`view.untranslated`
/// の包み忘れを検査できるようにする。
const plugin_row_one_page = dashboard.PluginRow(
  "plugin-a",
  Some(plugin_runner.Running),
  pages: [plugin.PluginPage(key: "status", title: "Status")],
)

/// ページを 2 件供給するプラグインの行（タブを撮るため）。
const plugin_row_two_pages = dashboard.PluginRow(
  "plugin-b",
  Some(plugin_runner.Running),
  pages: [
    plugin.PluginPage(key: "status", title: "Status"),
    plugin.PluginPage(key: "settings", title: "Settings"),
  ],
)

/// 無効になったプラグインの行（ページの注意の囲みを撮るため）。
const plugin_row_disabled = dashboard.PluginRow(
  "plugin-c",
  Some(plugin_runner.Disabled(reason: "boom", dropped: 1)),
  pages: [plugin.PluginPage(key: "status", title: "Status")],
)

/// 上の 3 行がいずれも持つ最初のページ。
const plugin_status_page = plugin.PluginPage(key: "status", title: "Status")

/// 節の記述。タイトルとブロックの文字列は `allowed_words` にある語だけで組む
/// （`japanese_pages_test` を通すため）。
fn plugin_section(title: String, blocks: List(Dynamic)) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("section")),
    #(dynamic.string("title"), dynamic.string(title)),
    #(dynamic.string("blocks"), dynamic.list(blocks)),
  ])
}

/// ブロック（`text`）。
fn plugin_text_block(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("text")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// `title` を持たない、変換に失敗する節の記述。
fn plugin_missing_title_section() -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("section")),
    #(dynamic.string("blocks"), dynamic.list([])),
  ])
}

/// ブロック（`details`）。`summary`・`text` は `allowed_words` にある語だけを
/// 使う。
fn plugin_details_block(summary: String, text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("details")),
    #(dynamic.string("summary"), dynamic.string(summary)),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// ブロック（`image`）。`alt` は `<img>` の属性値か `view.untranslated` の中に出るので、
/// `allowed_words` の制約を受けない。
fn plugin_image_block(url: String, alt: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("image")),
    #(dynamic.string("url"), dynamic.string(url)),
    #(dynamic.string("alt"), dynamic.string(alt)),
  ])
}

/// ブロック（`pairs`）。`items` は `#(term, value)` の並び。
fn plugin_pairs_block(items: List(#(String, Dynamic))) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("pairs")),
    #(
      dynamic.string("items"),
      dynamic.list(
        list.map(items, fn(item) {
          dynamic.properties([
            #(dynamic.string("term"), dynamic.string(item.0)),
            #(dynamic.string("value"), item.1),
          ])
        }),
      ),
    ),
  ])
}

/// インライン（`id`）。値は数字だけにする（`japanese_pages_test` の
/// `allowed_words` は識別子の英字を許さないため）。
fn plugin_id_inline(text: String) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("id")),
    #(dynamic.string("text"), dynamic.string(text)),
  ])
}

/// ブロック（`form`）。チェック 1 件、`text` の欄 1 件、`textarea` の欄 1 件と送信の
/// ボタンを持つ。`textarea` の初期値は要素の内容＝テキストノードなので `allowed_words`
/// の語だけを使う。`text` の初期値は属性なので制約を受けない。
fn plugin_form_block(
  name: String,
  label: String,
  hint: String,
  submit: String,
) -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("form")),
    #(
      dynamic.string("fields"),
      dynamic.list([
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("checkbox")),
          #(dynamic.string("name"), dynamic.string(name)),
          #(dynamic.string("label"), dynamic.string(label)),
          #(dynamic.string("hint"), dynamic.string(hint)),
        ]),
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("text")),
          #(dynamic.string("name"), dynamic.string("a")),
          #(dynamic.string("label"), dynamic.string("b")),
          #(dynamic.string("hint"), dynamic.string("c")),
          #(dynamic.string("value"), dynamic.string("d")),
        ]),
        dynamic.properties([
          #(dynamic.string("type"), dynamic.string("textarea")),
          #(dynamic.string("name"), dynamic.string("b")),
          #(dynamic.string("label"), dynamic.string("c")),
          #(dynamic.string("hint"), dynamic.string("d")),
          #(dynamic.string("value"), dynamic.string("a")),
        ]),
      ]),
    ),
    #(dynamic.string("submit"), dynamic.string(submit)),
  ])
}

/// すべての言語のページ。言語に依らない検査（CSS、スクリプト）が使う。
pub fn all_pages() -> List(String) {
  list.flat_map(i18n.languages, pages)
}

/// ページに埋め込まれずに使う `view.gleam` の部品を、状態の分岐をすべて通して描いた文字列。
/// `view.gleam` に部品を足したらここにも足す。
pub fn components(language: i18n.Language) -> List(String) {
  list.flatten([
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure, view.Info],
      fn(tone) { element.to_string(view.status_badge(tone, "text")) },
    ),
    [element.to_string(view.count_pill(3))],
    [
      element.to_string(
        view.checkbox_row(
          "name",
          view.key_icon(),
          "caption",
          view.hint("description"),
          True,
          [view.status_badge(view.Success, "badge")],
        ),
      ),
      element.to_string(
        view.checkbox_row(
          "name",
          view.key_icon(),
          "caption",
          view.hint("description"),
          False,
          [],
        ),
      ),
    ],
    [
      element.to_string(
        view.details_panel("summary", [
          view.hint("content"),
        ]),
      ),
    ],
    [
      element.to_string(view.truncated_id(language, "0123456789abcdef", "copy")),
    ],
    [element.to_string(view.preformatted("[[0,1]]"))],
    [
      element.to_string(view.section_card("anchor", [view.hint("content")])),
      element.to_string(view.warning_card("anchor", [view.hint("content")])),
      element.to_string(
        view.detail_list([#("term", html.dd([], [view.hint("value")]))]),
      ),
      element.to_string(view.alert(view.Info, [view.hint("content")])),
    ],
    list.map(
      [view.Normal, view.Primary, view.Caution, view.Destructive],
      fn(weight) {
        element.to_string(view.icon_button_link(
          "/",
          view.plus_icon(),
          "text",
          weight,
        ))
      },
    ),
    list.map(
      [view.Normal, view.Primary, view.Caution, view.Destructive],
      fn(weight) {
        element.to_string(view.icon_only_link(
          "/",
          view.trash_icon(),
          "label",
          weight,
        ))
      },
    ),
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure, view.Info],
      fn(tone) { element.to_string(view.tone_icon(tone)) },
    ),
    list.map(
      [
        view.logo_icon(),
        view.theme_icon(),
        view.language_icon(),
        view.qr_code_icon(),
        view.info_icon(),
        view.check_circle_icon(),
        view.warning_triangle_icon(),
        view.x_circle_icon(),
        view.copy_icon(),
        view.plus_icon(),
        view.trash_icon(),
        view.pencil_icon(),
        view.plug_icon(),
        view.eye_icon(),
        view.key_icon(),
        view.rotate_icon(),
        view.users_icon(),
        view.clock_icon(),
        view.puzzle_icon(),
        view.file_text_icon(),
      ],
      element.to_string,
    ),
  ])
}

/// `form` を含むページを `pages()` に足し、`stylesheet_test` と
/// `japanese_pages_test` の走査に載せる。
pub fn plugin_page_with_a_form_test() {
  let body =
    plugin_pages.plugin_page(
      i18n.English,
      view.System,
      plugin_row_one_page,
      plugin_status_page,
      [
        plugin_section("a", [
          plugin_form_block("example", "label", "plugin", "b"),
        ]),
      ],
    )
  assert string.contains(body, "action=\"/plugins/plugin-a/status\"")
  assert string.contains(body, "type=\"checkbox\"")
  assert string.contains(body, "type=\"text\"")
  assert string.contains(body, "</textarea>")
  assert string.contains(body, ">b<")
}
