//// 描画した管理 UI のページを使う検査が共有する、ページと静的ファイルの読み出し。配信する
//// 静的ファイル（`priv/static/`）と突き合わせる `stylesheet_test` と `script_test`、日本語の
//// ページの英文を見る `japanese_pages_test`、板つきのロゴのファイルと README を読む
//// `logo_test` が使う。
////
//// `view.gleam` か `admin/fingerprint` に部品を足したら `components` にもその部品を足す。

import gleam/bit_array
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/fingerprint
import nostr_no_su/admin/i18n
import nostr_no_su/admin/plugin_pages
import nostr_no_su/admin/view
import nostr_no_su/bunker/vault
import nostr_no_su/plugin
import nostr_no_su/plugin_loader
import nostr_no_su/plugin_runner
import nostr_no_su/relay_connection
import nostr_no_su/relay_list
import plugin_page_builder
import support/account_actions

/// ファイルの中身を読む。
@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, Dynamic)

/// URL のパスセグメントが指す静的ファイルの中身。ルーティングが `priv` の下の同じパスから
/// 配信するので、セグメントの定義（`view.stylesheet_segments` など）から読む。
pub fn static_file(segments: List(String)) -> String {
  text_file("priv" <> view.segments_path(segments))
}

/// リポジトリの根からの相対パスのテキストファイルの中身。
pub fn text_file(path: String) -> String {
  let assert Ok(bytes) = read_file(path)
  let assert Ok(content) = bit_array.to_string(bytes)
  content
}

/// `pages()` のアカウントの 64 桁の 16 進の公開鍵。鍵の指紋を描かせるため 32 バイトにし、
/// `japanese_pages_have_no_english_words_test` が短縮した値の英字を拾わないよう数字だけにする。
const account_hex = "0123012301230123012301230123012301230123012301230123012301230123"

/// `pages()` の読み込めなかった行の 64 桁の 16 進の公開鍵。`account_hex` と同じ理由で数字だけにする。
const skipped_hex = "8901890189018901890189018901890189018901890189018901890189018901"

/// 状態ごとに違うクラスと属性がすべて現れるよう、描画のどの分岐も通したページ。渡された言語で
/// 描画し、言語の切り替えのボタン（押した状態の表示している言語とそれ以外）と、切り替えを出さないページを通す。テーマの切り替えのボタン（`view.themes` ごとに押した状態のボタンが違う 3 通り）は、ダッシュボードをテーマごとに描画して通す。ほかのページは `view.System` で描画する。描画に
/// 状態の分岐を足したら、ここにもその状態のページを足す。
pub fn pages(language: i18n.Language) -> List(String) {
  let row =
    dashboard.AccountRow(
      signer: account_hex,
      npub: "npub1example",
      label: "label-a",
      uri: "bunker://0123?relay=x&secret=s",
      auth_uri: "bunker://0123?relay=x",
      uri_camera_text: "0123?relay=x&secret=s",
      auth_uri_camera_text: "0123?relay=x",
      picture: Some("https://example.invalid/avatar.png"),
    )
  let pending =
    dashboard.PendingRow(
      token: "tok",
      signer: account_hex,
      client: "4567456745674567456745674567456745674567456745674567456745674567",
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
      signer: account_hex,
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
          pubkey: skipped_hex,
          npub: Some("npub1example"),
          label: "label-b",
          reason: vault.UndecryptablePrivateKey,
        ),
        dashboard.SkippedRow(
          pubkey: "not-a-pubkey",
          npub: None,
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
          signer: account_hex,
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
  let opened = fn(dialog) {
    let assert Ok(html) =
      dashboard.render_open(language, view.System, full, dialog)
    html
  }
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
          accounts: Error(i18n.Translated(i18n.NotAvailable)),
          pending: Error(i18n.Translated(i18n.NotAvailable)),
          sessions: Error(i18n.Translated(i18n.NotAvailable)),
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
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(
          ..empty,
          relays: Ok([
            dashboard.RelayRow(
              1,
              "wss://a",
              dashboard.Unused,
              dashboard.Reported(relay_connection.Connected),
            ),
          ]),
        ),
      ),
      dashboard.approval_page(language, view.System, Ok([row]), 2000, pending),
      dashboard.approval_page(
        language,
        view.System,
        Ok([row]),
        2000,
        pending_mismatch,
      ),
      opened(dashboard.AddAccountOpen("", reason)),
      opened(dashboard.PrivateKeyOpen(row, "nsec1example")),
      opened(dashboard.UnreadableDeleteOpen(skipped_hex, reason)),
      opened(dashboard.NewRelayOpen(
        "wss://relay-with-a-very-long-host-name-for-layout-checks.example/path/segment/that/keeps/going/without/breaking",
        Some(relay_list.BunkerOnly),
        reason,
      )),
      opened(dashboard.RelayActionOpen(
        1,
        dashboard.EditRelayRoles,
        None,
        i18n.Translated(i18n.RelayRoleRequired),
      )),
      opened(dashboard.ConnectOpen(
        uri: "nostrconnect://0123",
        signer: row.signer,
        error: Some(i18n.Translated(i18n.NotNostrconnectUri)),
      )),
      opened(dashboard.ConnectReviewOpen(
        review: dashboard.ConnectReview(
          uri: "nostrconnect://4567?relay=wss://a.example&relay=ws://b.example&secret=s",
          signer: account_hex,
          client: "4567456745674567456745674567456745674567456745674567456745674567",
          client_name: Some("example"),
          perms: "sign_event:1",
          relays: ["wss://a.example", "ws://b.example"],
        ),
        error: None,
      )),
      opened(dashboard.ConnectReviewOpen(
        review: dashboard.ConnectReview(
          uri: "nostrconnect://4567?relay=wss://a.example&secret=s",
          signer: account_hex,
          client: "4567456745674567456745674567456745674567456745674567456745674567",
          client_name: None,
          perms: "",
          relays: ["wss://a.example"],
        ),
        error: Some(reason),
      )),
      // 保存の失敗（409 の描き直し）
      opened(dashboard.PermissionsOpen(
        signer: account_hex,
        client: "4567",
        form: dashboard.PermissionsForm(
          sign_event: True,
          nip44_encrypt: False,
          nip44_decrypt: False,
          kinds: "",
          other: "",
        ),
        error: reason,
      )),
    ],
    list.map(
      [
        None,
        Some(dashboard.InvalidLabel(i18n.LabelHasControlCharacters)),
        Some(dashboard.NotApplied(i18n.Untranslated("reason"))),
        Some(
          dashboard.NotApplied(i18n.Translated(i18n.AccountAlreadyRegistered)),
        ),
        Some(dashboard.NotAccepted("reason")),
        Some(dashboard.NotConfirmed(i18n.StoreDidNotConfirm)),
      ],
      fn(problem) {
        opened(dashboard.GeneratedKeyOpen(
          "npub1example",
          "nsec1example",
          "label-a",
          problem,
        ))
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
    list.map(account_actions.all, fn(action) {
      opened(dashboard.AccountActionOpen(account_hex, action, None, reason))
    }),
    // 接続 QR コードのダイアログのリレーの一覧が空、得られない、URI を符号化できない
    [
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(..full, relays: Ok([])),
      ),
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(
          ..full,
          relays: Error(i18n.Untranslated("relay list did not answer")),
        ),
      ),
      dashboard.render(
        language,
        view.System,
        dashboard.Snapshot(
          ..full,
          accounts: Ok([
            dashboard.AccountRow(..row, uri: string.repeat("0", 3000)),
          ]),
        ),
      ),
    ],
    // 節の題とブロックの文字列は `allowed_words` の語か英字を含まない語で組む
    [
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        0,
        [
          plugin_page_builder.section("a", [], [
            plugin_page_builder.typed_text("text", "example"),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_two_pages,
        plugin_status_page,
        0,
        [
          plugin_page_builder.section("b", [], [
            plugin_page_builder.typed_text("text", "label"),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        0,
        [],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        0,
        [
          plugin_page_builder.section("c", [], [
            plugin_page_builder.typed_text("text", "plugin"),
          ]),
          plugin_missing_title_section(),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_disabled,
        plugin_status_page,
        0,
        [
          plugin_page_builder.section("d", [], [
            plugin_page_builder.typed_text("text", "a"),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        0,
        [
          plugin_page_builder.section("a", [], [
            // `textarea` の欄の初期値は要素の内容（テキストノード）なので
            // `allowed_words` の語だけを使う。`text` の欄の初期値は属性なので制約を受けない
            plugin_page_builder.form_block(
              [
                plugin_page_builder.checkbox_field(
                  name: "example",
                  label: "label",
                  hint: Some("plugin"),
                  checked: False,
                ),
                plugin_page_builder.input_field(
                  kind: "text",
                  name: "a",
                  label: "b",
                  hint: "c",
                  value: "d",
                ),
                plugin_page_builder.input_field(
                  kind: "textarea",
                  name: "b",
                  label: "c",
                  hint: "d",
                  value: "a",
                ),
              ],
              "b",
            ),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        0,
        [
          plugin_page_builder.section("a", [], [
            plugin_page_builder.details_block("example", "label"),
            plugin_page_builder.pairs_block([
              // `id` の値は数字だけにする（`allowed_words` は識別子の英字を許さない）
              #(
                "plugin",
                plugin_page_builder.typed_text("id", "01234567890123456789"),
              ),
            ]),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        0,
        [
          plugin_page_builder.section("a", [], [
            // `image` の `alt` は節の言語を引き継ぐテキストにも出るので
            // `allowed_words` の語で組む
            plugin_page_builder.image_block(
              "http://example.com/a.png",
              "example",
              None,
            ),
            plugin_page_builder.image_block(
              "data:image/png;base64,AAA",
              "label",
              None,
            ),
            plugin_page_builder.image_block(
              "http://example.com/a.png",
              "example",
              Some("icon"),
            ),
            plugin_page_builder.image_block(
              "http://example.com/b.png",
              "example",
              Some("banner"),
            ),
          ]),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_one_page,
        plugin_status_page,
        0,
        [
          // 見出しの補足のクラスと、訳した kind の名前と相対時刻をページに載せる節
          plugin_page_builder.section(
            "a",
            [
              plugin_page_builder.kind_inline(1),
              plugin_page_builder.time_inline(0),
            ],
            [
              plugin_page_builder.pairs_block([
                #("plugin", plugin_page_builder.time_inline(0)),
              ]),
            ],
          ),
        ],
      ),
      plugin_pages.plugin_page(
        language,
        view.System,
        plugin_row_localized(),
        plugin_localized_status_page(),
        0,
        [
          plugin_page_builder.section("キュー", [], [
            plugin_page_builder.typed_text("text", "処理済み"),
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

/// 表示の言語を受け取るプラグインの行（タブを表示の言語で撮るため）。日本語の
/// 表示名は `japanese_pages_test` が包み無しで検査する。
fn plugin_row_localized() -> dashboard.PluginRow {
  dashboard.PluginRow("plugin-e", Some(plugin_runner.Running), pages: [
    plugin_localized_status_page(),
    plugin.LocalizedPage(
      key: "settings",
      titles: dict.from_list([#("en", "Settings"), #("ja", "設定")]),
    ),
  ])
}

/// `plugin_row_localized` の最初のページ。
fn plugin_localized_status_page() -> plugin.PluginPage {
  plugin.LocalizedPage(
    key: "status",
    titles: dict.from_list([#("en", "Status"), #("ja", "状態")]),
  )
}

/// `title` を持たない、変換に失敗する節の記述。
fn plugin_missing_title_section() -> Dynamic {
  dynamic.properties([
    #(dynamic.string("type"), dynamic.string("section")),
    #(dynamic.string("blocks"), dynamic.list([])),
  ])
}

/// すべての言語のページ。言語に依らない検査（CSS、スクリプト）が使う。
pub fn all_pages() -> List(String) {
  list.flat_map(i18n.languages, pages)
}

/// ボタンの種類のすべて。`components` がどの置き場所でも全種類を描くのに使う。
const button_kinds = [
  view.PrimaryButton,
  view.OutlineButton,
  view.GhostButton,
  view.DangerButton,
  view.DangerGhostButton,
  view.WarningOutlineButton,
]

/// ページに埋め込まれずに使う `view.gleam` と `admin/fingerprint` の部品を、状態の分岐をすべて通して描いた文字列。
/// `view.gleam` か `admin/fingerprint` に部品を足したらここにも足す。
pub fn components(language: i18n.Language) -> List(String) {
  list.flatten([
    list.map(
      [
        view.ActiveChip,
        view.DisconnectedChip,
        view.UnansweredChip,
        view.UnusedChip,
        view.OverloadedChip,
        view.DisabledChip,
        view.LoadFailedChip,
        view.SecretNotOfferedChip,
        view.SecretMismatchChip,
        ..list.map(
          [view.Neutral, view.Success, view.Warning, view.Failure, view.Info],
          view.ToneChip,
        )
      ],
      fn(chip) { element.to_string(view.status_chip(chip, "text")) },
    ),
    [
      element.to_string(
        view.section_heading(
          view.plug_icon(),
          "title",
          Some(3),
          view.info_hint(language, "hint-id", [view.hint("hint")]),
          [view.hint("action")],
        ),
      ),
      element.to_string(
        view.section_heading(view.plug_icon(), "title", None, [], []),
      ),
    ],
    [
      element.to_string(
        view.checkbox_row(
          "name",
          view.key_icon(),
          "caption",
          view.hint("description"),
          True,
          [view.status_chip(view.ActiveChip, "badge")],
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
    list.flat_map([view.LineHint("hint"), view.FoldedHint("hint")], fn(hint) {
      [
        element.to_string(
          view.hinted_input(language, "caption", "hint-id", hint, []),
        ),
        element.to_string(
          view.hinted_textarea(language, "caption", "hint-id", hint, "", []),
        ),
      ]
    }),
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
    // 大きさのクラスは、Tailwind が走査する admin/ の .gleam に現れる size-4 を使う（test/ は走査の外）。
    list.map([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11], fn(hue) {
      element.to_string(fingerprint.svg(
        fingerprint.Fingerprint(hue:, cells: [#(0, 0), #(4, 0)]),
        fingerprint.Colored,
        "size-4",
      ))
    }),
    [
      element.to_string(fingerprint.svg(
        fingerprint.Fingerprint(hue: 0, cells: [#(2, 2)]),
        fingerprint.Gray,
        "size-4",
      )),
    ],
    [
      element.to_string(view.section_block("anchor", [view.hint("content")])),
      element.to_string(
        view.row_list([
          view.list_row(view.InlineRow, [view.hint("content")]),
          view.list_row(view.StackedRow, [view.hint("content")]),
        ]),
      ),
      element.to_string(view.surface([view.hint("content")])),
      element.to_string(view.copy_button("copy")),
      element.to_string(
        view.detail_list([#("term", html.dd([], [view.hint("value")]))]),
      ),
      element.to_string(view.alert(view.Info, [view.hint("content")])),
      element.to_string(
        view.failure_frame(
          view.warning_triangle_icon(),
          "title",
          1,
          "description",
          [view.list_row(view.InlineRow, [html.text("row")])],
        ),
      ),
    ],
    list.map(button_kinds, fn(kind) {
      element.to_string(view.button_link(
        "/",
        view.IconTextFace(view.plus_icon(), "text"),
        kind,
      ))
    }),
    list.map(button_kinds, fn(kind) {
      element.to_string(view.post_form("/", [], "text", kind, view.InForm))
    }),
    list.map(button_kinds, fn(kind) {
      element.to_string(view.post_form(
        "/",
        [],
        "text",
        kind,
        view.InDialog(
          id: "dialog-x",
          dismiss: "text",
          opening: view.OpensOnTrigger,
        ),
      ))
    }),
    list.flat_map(
      [view.OpensOnTrigger, view.OpenedByResponse, view.OpenedByResponsePinned],
      fn(opening) {
        list.map(
          view.dialog_actions(
            view.InDialog(id: "dialog-x", dismiss: "text", opening:),
            [view.hint("content")],
          ),
          element.to_string,
        )
      },
    ),
    [
      element.to_string(view.hinted_copyable_field(
        language,
        "caption",
        "hint-id",
        "hint",
        "value",
      )),
    ],
    list.map([view.LargeIdentity, view.PlainIdentity], fn(size) {
      element.to_string(view.identity(language, size, "label", "npub1value"))
    }),
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure, view.Info],
      fn(tone) { element.to_string(view.tone_icon(tone)) },
    ),
    list.map(
      [view.Neutral, view.Success, view.Warning, view.Failure, view.Info],
      fn(tone) { element.to_string(view.notice_mark(tone)) },
    ),
    [element.to_string(view.band("anchor", [view.hint("content")]))],
    list.map(
      view.dialog_button(
        language,
        "dialog-x",
        view.IconTextFace(view.plus_icon(), "text"),
        view.PrimaryButton,
        "title",
        fn(_) { [] },
        view.OpensOnTrigger,
      ),
      element.to_string,
    ),
    list.map(
      view.dialog_button(
        language,
        "dialog-y",
        view.TextFace("text"),
        view.GhostButton,
        "title",
        fn(_) { [] },
        view.OpensOnTrigger,
      ),
      element.to_string,
    ),
    [element.to_string(view.radio_tabs("tabs", [#("one", []), #("two", [])]))],
    [
      element.to_string(view.dialog_trigger(
        "dialog-x",
        view.CompactFace(view.qr_code_icon(), "text"),
        view.PrimaryButton,
      )),
      element.to_string(
        view.failure_frame(
          view.warning_triangle_icon(),
          "title",
          1,
          "description",
          [
            view.list_row(view.InlineRow, [html.text("row")]),
          ],
        ),
      ),
      element.to_string(fingerprint.pubkey_svg(
        string.repeat("ab", 32),
        fingerprint.Gray,
        "size-8",
      )),
    ],
    list.map(
      [
        view.logo_icon(),
        view.qr_code_icon(),
        view.info_icon(),
        view.warning_triangle_icon(),
        view.plus_icon(),
        view.trash_icon(),
        view.pencil_icon(),
        view.plug_icon(),
        view.eye_icon(),
        view.key_icon(),
        view.rotate_icon(),
        view.users_icon(),
        view.clock_icon(),
        view.door_open_icon(),
        view.sparkle_icon(),
        view.check_icon(),
        view.puzzle_icon(),
        view.file_text_icon(),
      ],
      element.to_string,
    ),
  ])
}
