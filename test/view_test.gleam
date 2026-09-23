//// 管理 UI のページ枠と共通の部品（`admin/view`）の単体テスト。

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element
import lustre/element/html
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view

/// 64 桁の 16 進のように長い値は、先頭 10 桁と末尾 6 桁を `…` でつなぐ。
pub fn shorten_keeps_the_head_and_tail_test() {
  let hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  assert view.shorten(hex) == "0123456789…abcdef"
}

/// 17 文字以下の値はそのまま返す。
pub fn shorten_returns_short_values_unchanged_test() {
  assert view.shorten("01234567890123456") == "01234567890123456"
  assert view.shorten("") == ""
}

/// 状態のチップは、変種ごとに決まったクラスとアイコンで描く。未使用だけ点線の枠で、
/// ほかは薄い塗りにトーンの色を付ける（中立は色の修飾なし）。
pub fn status_chip_follows_the_state_vocabulary_test() {
  let soft = "badge badge-soft badge-sm whitespace-nowrap gap-1"
  let cases = [
    #(view.ActiveChip, soft <> " badge-success", "m9 12 2 2 4-4"),
    #(view.DisconnectedChip, soft <> " badge-warning", "m19 5 3-3"),
    #(view.UnansweredChip, soft <> " badge-warning", "M12 6v6l4 2"),
    #(
      view.UnusedChip,
      "badge badge-dash badge-sm whitespace-nowrap gap-1",
      "M8 12h8",
    ),
    #(view.OverloadedChip, soft <> " badge-warning", "m12 14 4-4"),
    #(view.DisabledChip, soft <> " badge-error", "M4.929 4.929 19.07 19.071"),
    #(view.LoadFailedChip, soft <> " badge-error", "M15.312 2a2 2 0 0 1"),
    #(view.SecretNotOfferedChip, soft, "M20 13c0 5-3.5 7.5-7.66 8.95"),
    #(view.SecretMismatchChip, soft <> " badge-warning", "M12 8v4"),
    #(view.ToneChip(view.Neutral), soft, "M12 16v-4"),
    #(view.ToneChip(view.Success), soft <> " badge-success", "m9 12 2 2 4-4"),
    #(view.ToneChip(view.Warning), soft <> " badge-warning", "M12 9v4"),
    #(view.ToneChip(view.Failure), soft <> " badge-error", "m15 9-6 6"),
    #(view.ToneChip(view.Info), soft <> " badge-info", "M12 16v-4"),
  ]
  use #(chip, class, path) <- list.each(cases)
  let html = element.to_string(view.status_chip(chip, "t"))
  assert string.contains(html, "class=\"" <> class <> "\"")
  assert string.contains(html, path)
}

/// 状態の注記は、チップと同じアイコンを付け、語をチップのトーンの色の文字で出す（中立と
/// 未使用は色を付けない）。
pub fn status_note_colors_the_text_like_the_chip_test() {
  let base = "inline-flex items-center gap-1"
  let cases = [
    #(view.ActiveChip, base <> " text-success", "m9 12 2 2 4-4"),
    #(view.DisconnectedChip, base <> " text-warning", "m19 5 3-3"),
    #(view.UnusedChip, base, "M8 12h8"),
    #(view.LoadFailedChip, base <> " text-error", "M15.312 2a2 2 0 0 1"),
    #(view.SecretNotOfferedChip, base, "M20 13c0 5-3.5 7.5-7.66 8.95"),
    #(view.ToneChip(view.Info), base <> " text-info", "M12 16v-4"),
  ]
  use #(chip, class, path) <- list.each(cases)
  let html = element.to_string(view.status_note(chip, "t"))
  assert string.contains(html, "<span class=\"" <> class <> "\">")
  assert string.contains(html, path)
}

/// 通知のページの結果の印は、トーンごとに状態の語彙の色とアイコンで描く。
pub fn notice_mark_follows_the_state_vocabulary_test() {
  let cases = [
    #(view.Success, "bg-success/13 text-success", "m9 12 2 2 4-4"),
    #(view.Warning, "bg-warning/13 text-warning", "M12 6v6l4 2"),
    #(view.Failure, "bg-error/13 text-error", "M15.312 2a2 2 0 0 1"),
    #(view.Neutral, "bg-base-200 text-muted", "M8 12h8"),
    #(view.Info, "bg-info/13 text-info", "M12 16v-4"),
  ]
  use #(tone, class, path) <- list.each(cases)
  let html = element.to_string(view.notice_mark(tone))
  assert string.contains(
    html,
    "class=\"grid size-10 shrink-0 place-items-center rounded-full "
      <> class
      <> "\"",
  )
  assert string.contains(html, path)
}

/// ボタンの種類と置き場所の組ごとに、daisyUI のクラスが決まる。行は `button_link`、
/// フォームは `post_form` の送信ボタンで確かめる。
pub fn button_kinds_map_to_daisyui_classes_test() {
  let focus = " focus-visible:outline-base-content"
  let cases = [
    #(view.PrimaryButton, view.InRow, "btn btn-primary btn-sm"),
    #(view.OutlineButton, view.InRow, "btn btn-outline btn-sm"),
    #(view.GhostButton, view.InRow, "btn btn-ghost btn-sm"),
    #(view.DangerButton, view.InRow, "btn btn-error btn-sm"),
    #(view.DangerGhostButton, view.InRow, "btn btn-ghost btn-sm text-error"),
    #(
      view.WarningOutlineButton,
      view.InRow,
      "btn btn-outline btn-warning btn-sm",
    ),
    #(view.PrimaryButton, view.InForm, "btn btn-primary self-start"),
    #(view.OutlineButton, view.InForm, "btn btn-outline self-start"),
    #(view.GhostButton, view.InForm, "btn btn-ghost self-start"),
    #(view.DangerButton, view.InForm, "btn btn-error self-start"),
    #(
      view.DangerGhostButton,
      view.InForm,
      "btn btn-ghost self-start text-error",
    ),
    #(
      view.WarningOutlineButton,
      view.InForm,
      "btn btn-outline btn-warning self-start",
    ),
  ]
  use #(kind, placement, class) <- list.each(cases)
  let html = case placement {
    view.InRow -> element.to_string(view.button_link("/", "t", kind))
    view.InForm ->
      element.to_string(view.post_form("/", [], "t", kind, view.InForm))
  }
  assert string.contains(html, "class=\"" <> class <> focus <> "\"")
}

/// 節の見出しは、`primary` を薄く混ぜた面のアイコン、題の直後の件数のピル、補助の文字の色の
/// 説明、右端の操作の並びを出す。
pub fn section_heading_shows_the_count_description_and_actions_test() {
  let html =
    element.to_string(
      view.section_heading(
        view.plug_icon(),
        "Relays",
        Some(2),
        Some("Where the bunker listens."),
        [view.hint("action")],
      ),
    )
  assert string.contains(
    html,
    "<span class=\"grid size-7.5 shrink-0 place-items-center rounded-field bg-primary/13 text-primary\"><svg",
  )
  assert string.contains(
    html,
    "Relays</h2><span class=\"badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums\">2</span>",
  )
  assert string.contains(
    html,
    "<p class=\"text-sm text-muted sm:pl-10\">Where the bunker listens.</p>",
  )
  assert string.contains(
    html,
    "<div class=\"ml-auto flex flex-wrap justify-end gap-2\"><p class=\"text-sm text-muted\">action</p></div>",
  )
}

/// 件数、説明、操作を渡さなければ、ピル、説明の行、操作の並びを出さない。
pub fn section_heading_leaves_out_the_absent_parts_test() {
  let html =
    element.to_string(
      view.section_heading(view.plug_icon(), "Relays", None, None, []),
    )
  assert !string.contains(html, "badge")
  assert !string.contains(html, "<p class")
  assert !string.contains(html, "justify-end")
}

/// 行の一覧は面と枠線を持つ `list` で、行は並べ方ごとのクラスを `list-row` に重ねる。
pub fn row_list_frames_the_rows_test() {
  let html =
    element.to_string(
      view.row_list([
        view.list_row(view.InlineRow, [html.text("a")]),
        view.list_row(view.StackedRow, [html.text("b")]),
      ]),
    )
  assert html
    == "<ul class=\"list rounded-box border border-base-300 bg-base-100\">"
    <> "<li class=\"list-row flex flex-wrap items-center justify-between gap-x-6 gap-y-3\">a</li>"
    <> "<li class=\"list-row flex flex-col gap-3\">b</li></ul>"
}

/// 全幅の帯は、`id` を付けた `section` に、`primary` を混ぜた地と枠、縦に積むクラスを付ける。
pub fn band_stacks_its_content_test() {
  let html = element.to_string(view.band("pending", [html.text("content")]))
  assert html
    == "<section class=\"flex flex-col gap-4 rounded-box border border-primary/28 bg-primary/8 p-4 sm:p-6\" id=\"pending\">content</section>"
}

/// 空の状態は、点線の枠の中にアイコン、説明の文、操作を縦に積む。操作が無ければボタンを置かない。
pub fn empty_state_stacks_icon_sentence_and_actions_in_a_dashed_frame_test() {
  let frame =
    "<div class=\"flex flex-col items-start gap-3 rounded-box border border-dashed border-field bg-base-100/60 px-4 py-5 text-sm text-muted\">"
  assert element.to_string(
      view.empty_state(html.text("i"), "sentence", [html.text("button")]),
    )
    == frame <> "i<p>sentence</p>button</div>"
  assert element.to_string(view.empty_state(html.text("i"), "sentence", []))
    == frame <> "i<p>sentence</p></div>"
}

/// 残り時間は「分:秒」にし、秒を 2 桁に 0 埋めし、負の値を 0 とみなす。
pub fn countdown_pads_seconds_test() {
  assert view.countdown(492) == "8:12"
  assert view.countdown(45) == "0:45"
  assert view.countdown(600) == "10:00"
  assert view.countdown(-3) == "0:00"
}

/// コピーのボタンは、アイコンだけを見せ、語を `aria-label` と `title` に置き、`copy` の処理を指す。
pub fn copy_button_names_the_copy_action_test() {
  let html = element.to_string(view.copy_button("Copy client"))
  assert string.starts_with(
    html,
    "<button aria-label=\"Copy client\" class=\"btn btn-ghost btn-sm btn-square text-muted group-data-copied:text-success focus-visible:outline-base-content\" data-action=\"copy\" title=\"Copy client\" type=\"button\">",
  )
}

/// 時刻の部品は、`datetime` 属性に RFC 3339 の UTC の全文を置き、本文に 0 埋めした UTC の時分秒を
/// 表示の言語の「UTC」の表記つきで出す（JS が無いときに見える形）。
pub fn time_of_day_renders_utc_with_datetime_test() {
  let cases = [
    #(i18n.English, "05:02:04 UTC"),
    #(i18n.Japanese, "05:02:04（UTC）"),
  ]
  use #(language, text) <- list.each(cases)
  let html = element.to_string(view.time_of_day(language, 1_789_275_724))
  assert html == "<time datetime=\"2026-09-13T05:02:04Z\">" <> text <> "</time>"
}

/// 表の見出しは列を指す `scope="col"` を持ち、`scope` の無い `th` は出さない。
pub fn table_headers_scope_their_columns_test() {
  let body =
    element.to_string(
      view.table(["Name"], [[html.td([], [html.text("value")])]]),
    )
  assert string.contains(body, "<th scope=\"col\">Name</th>")
  assert !string.contains(body, "<th>")
}

/// 1 行の補足は、欄の下の段落に `id` を付けて欄の `aria-describedby` から指し、`popover` にしない。
pub fn line_hint_describes_the_field_test() {
  let html =
    element.to_string(
      view.hinted_input(
        i18n.English,
        "Label",
        "label-hint",
        view.LineHint("Up to 64 characters."),
        [attribute.name("label")],
      ),
    )
  assert string.contains(html, "aria-describedby=\"label-hint\"")
  assert string.contains(
    html,
    "<p class=\"text-muted\" id=\"label-hint\">Up to 64 characters.</p>",
  )
  assert !string.contains(html, "popover")
}

/// ⓘ で開く補足は、送信しないボタンの `popovertarget` で `popover="auto"` の段落を開き、ボタンの
/// 語を表示の言語で `aria-label` と `title` に置く。段落は閉じていても欄の説明として指され、JS の
/// 処理（`data-action`）を使わない。
pub fn folded_hint_opens_from_the_info_button_test() {
  let html =
    element.to_string(
      view.hinted_input(
        i18n.Japanese,
        "URL",
        "relay-url-hint",
        view.FoldedHint("ws:// か wss:// で始まる URL。"),
        [attribute.name("url")],
      ),
    )
  assert string.contains(
    html,
    "<button aria-label=\"補足を表示\" class=\"btn btn-ghost btn-xs btn-circle text-muted focus-visible:outline-base-content\" popovertarget=\"relay-url-hint\" title=\"補足を表示\" type=\"button\">",
  )
  assert string.contains(html, "id=\"relay-url-hint\" popover=\"auto\"")
  assert string.contains(html, "aria-describedby=\"relay-url-hint\"")
  assert !string.contains(html, "data-action")
}

/// 複数行の欄も、どちらの補足でも `aria-describedby` で補足の段落を指し、補足の出し方だけが変わる。
pub fn hinted_textarea_describes_the_field_with_either_hint_test() {
  let render = fn(hint) {
    element.to_string(
      view.hinted_textarea(i18n.English, "URI", "uri-hint", hint, "", [
        attribute.name("uri"),
      ]),
    )
  }
  let line = render(view.LineHint("Paste the URI."))
  let folded = render(view.FoldedHint("Paste the URI."))
  assert string.contains(line, "<textarea aria-describedby=\"uri-hint\"")
  assert string.contains(folded, "<textarea aria-describedby=\"uri-hint\"")
  assert string.contains(line, "<p class=\"text-muted\" id=\"uri-hint\">")
  assert string.contains(folded, "id=\"uri-hint\" popover=\"auto\"")
}

/// 警告の通知は畳まずに本文をそのまま出す（`details` にも `popover` にもしない）。
pub fn warning_alert_is_not_folded_test() {
  let html =
    element.to_string(view.alert(view.Warning, [html.text("Back up now.")]))
  assert string.contains(html, "<span>Back up now.</span>")
  assert !string.contains(html, "<details")
  assert !string.contains(html, "popover")
}

/// 上部のロゴの枠は内容の幅を基準に伸びる（`flex-1` のように基準の幅を 0 にしない）。
pub fn navbar_start_keeps_the_width_of_the_logo_test() {
  let html =
    view.page(
      i18n.English,
      view.System,
      i18n.BackToDashboard,
      view.Narrow,
      view.SwitchReturningTo("/"),
      view.NoRefresh,
      [],
    )
  assert string.contains(html, "<div class=\"navbar-start w-auto grow\">")
}

/// 狭い画面で語を隠すボタンのリンクは、語を `title` と `max-sm:sr-only` の `span` に置く。
pub fn compact_icon_button_link_hides_the_text_on_narrow_screens_test() {
  let link =
    element.to_string(view.compact_icon_button_link(
      "/href",
      view.qr_code_icon(),
      "Connection QR code",
      view.PrimaryButton,
    ))
  assert string.contains(link, "title=\"Connection QR code\"")
  assert string.contains(
    link,
    "<span class=\"max-sm:sr-only\">Connection QR code</span>",
  )
}

/// アイコンと語のダイアログのボタンは `commandfor` で `id` のダイアログを指して開き、ダイアログは
/// 題、中身、`autofocus` のキャンセル（`command="close"`）の順に並べる。
pub fn dialog_button_opens_the_dialog_it_names_test() {
  let html =
    view.dialog_button(
      i18n.English,
      "dialog-x",
      view.IconTextTrigger(view.plus_icon(), "Add"),
      view.PrimaryButton,
      "Title",
      [html.p([], [html.text("body")])],
    )
    |> list.map(element.to_string)
    |> string.concat
  assert html
    == "<button class=\"btn btn-primary btn-sm focus-visible:outline-base-content\" command=\"show-modal\" commandfor=\"dialog-x\" type=\"button\">"
    <> element.to_string(view.plus_icon())
    <> "Add</button>"
    <> "<dialog aria-labelledby=\"dialog-x-title\" class=\"modal\" id=\"dialog-x\"><div class=\"modal-box flex flex-col gap-4\"><h2 class=\"card-title\" id=\"dialog-x-title\">Title</h2><p>body</p><button autofocus class=\"btn btn-ghost self-start focus-visible:outline-base-content\" command=\"close\" commandfor=\"dialog-x\" type=\"button\">Cancel</button></div></dialog>"
}

/// アイコンだけのダイアログのボタンは、語を `aria-label` に置き、中身はアイコンだけにする。
pub fn icon_only_dialog_button_names_itself_by_label_test() {
  let assert [button, _] =
    view.dialog_button(
      i18n.English,
      "dialog-x",
      view.IconOnlyTrigger(view.trash_icon(), "Delete"),
      view.DangerGhostButton,
      "Title",
      [],
    )
  assert element.to_string(button)
    == "<button aria-label=\"Delete\" class=\"btn btn-ghost btn-sm text-error focus-visible:outline-base-content\" command=\"show-modal\" commandfor=\"dialog-x\" type=\"button\">"
    <> element.to_string(view.trash_icon())
    <> "</button>"
}

/// 語だけのダイアログのボタンは、`InRow` の送信ボタンと同じ見た目で語だけを出す。
pub fn text_dialog_button_shows_only_the_text_test() {
  let assert [button, _] =
    view.dialog_button(
      i18n.English,
      "dialog-x",
      view.TextTrigger("Revoke"),
      view.GhostButton,
      "Title",
      [],
    )
  assert element.to_string(button)
    == "<button class=\"btn btn-ghost btn-sm focus-visible:outline-base-content\" command=\"show-modal\" commandfor=\"dialog-x\" type=\"button\">Revoke</button>"
}

/// ダイアログの `id` は `dialog-` の後に部品を `-` で繋ぐ。
pub fn dialog_id_joins_the_parts_after_the_prefix_test() {
  assert view.dialog_id(["relay", "7", "edit"]) == "dialog-relay-7-edit"
}

/// 予備のリンクは今の操作のページを開き、表示の言語で「ページで開く」と書く。
pub fn fallback_link_opens_the_page_test() {
  assert element.to_string(view.fallback_link(i18n.Japanese, "/relays/1/edit"))
    == "<a class=\"link link-hover self-center text-xs text-muted\" href=\"/relays/1/edit\">ページで開く</a>"
}
