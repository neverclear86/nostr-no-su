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
/// フォームは `post_form` の送信ボタンで確かめる。ダイアログの行のボタンは左に寄せない。
pub fn button_kinds_map_to_daisyui_classes_test() {
  let focus = " focus-visible:outline-base-content"
  let in_dialog =
    view.InDialog(
      id: "dialog-x",
      dismiss: "Cancel",
      opening: view.OpensOnTrigger,
    )
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
    #(view.PrimaryButton, in_dialog, "btn btn-primary"),
    #(view.OutlineButton, in_dialog, "btn btn-outline"),
    #(view.GhostButton, in_dialog, "btn btn-ghost"),
    #(view.DangerButton, in_dialog, "btn btn-error"),
    #(view.DangerGhostButton, in_dialog, "btn btn-ghost text-error"),
    #(view.WarningOutlineButton, in_dialog, "btn btn-outline btn-warning"),
  ]
  use #(kind, placement, class) <- list.each(cases)
  let html = case placement {
    view.InRow -> element.to_string(view.button_link("/", "t", kind))
    view.InForm | view.InDialog(..) ->
      element.to_string(view.post_form("/", [], "t", kind, placement))
  }
  assert string.contains(html, "class=\"" <> class <> focus <> "\"")
}

/// 節の見出しは、`primary` を薄く混ぜた面のアイコン、題、題の直後の ⓘ と補足、件数のピル、右端の操作の
/// 並びを 1 行に出し、説明の段落を持たない。
pub fn section_heading_puts_the_hint_between_the_title_and_the_count_test() {
  let hint = view.info_hint(i18n.English, "relays-hint", [html.text("Where.")])
  let html =
    element.to_string(
      view.section_heading(view.plug_icon(), "Relays", Some(2), hint, [
        view.hint("action"),
      ]),
    )
  assert string.contains(
    html,
    "<span class=\"grid size-7.5 shrink-0 place-items-center rounded-field bg-primary/13 text-primary\"><svg",
  )
  assert string.contains(
    html,
    "Relays</h2>"
      <> string.concat(list.map(hint, element.to_string))
      <> "<span class=\"badge badge-sm border-base-300 bg-base-100 font-mono font-bold text-muted tabular-nums\">2</span>",
  )
  assert string.contains(
    html,
    "<div class=\"flex min-w-0 items-center gap-2.5\">",
  )
  assert !string.contains(html, "sm:pl-10")
  assert string.contains(
    html,
    "<div class=\"ml-auto flex flex-wrap justify-end gap-2\"><p class=\"text-sm text-muted\">action</p></div>",
  )
}

/// 件数、補足、操作を渡さなければ、ピル、ⓘ、操作の並びを出さない。
pub fn section_heading_leaves_out_the_absent_parts_test() {
  let html =
    element.to_string(
      view.section_heading(view.plug_icon(), "Relays", None, [], []),
    )
  assert !string.contains(html, "badge")
  assert !string.contains(html, "interestfor")
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

/// ⓘ で開く補足は `info_hint` を見出しに置き、ボタンの `interestfor` と `popovertarget` で
/// `popover="hint"` の補足を開く。ボタンの語は表示の言語で、補足は閉じていても欄の説明として指され、
/// JS の処理（`data-action`）を使わない。
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
    "<div class=\"fieldset-legend w-fit justify-start\">URL"
      <> string.concat(list.map(
      view.info_hint(i18n.Japanese, "relay-url-hint", [
        html.text("ws:// か wss:// で始まる URL。"),
      ]),
      element.to_string,
    ))
      <> "</div>",
  )
  assert string.contains(html, "interestfor=\"relay-url-hint\"")
  assert string.contains(html, "id=\"relay-url-hint\" popover=\"hint\"")
  assert string.contains(html, "<input aria-describedby=\"relay-url-hint\"")
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
  assert string.contains(folded, "id=\"uri-hint\" popover=\"hint\"")
}

/// ⓘ のボタンは送信せず、ホバーとフォーカス（`interestfor`）とクリック（`popovertarget` の `show`）で
/// 補足を開き、`aria-describedby` で補足を指す。補足は `popover="hint"` の `div` で、見出しの太字を
/// 継がない（`font-normal`）。
pub fn info_hint_opens_on_hover_focus_and_click_test() {
  let assert [button, hint] =
    view.info_hint(i18n.English, "accounts-hint", [html.text("Keys.")])
    |> list.map(element.to_string)
  assert button
    == "<button aria-describedby=\"accounts-hint\" aria-label=\"Show help\" class=\"btn btn-ghost btn-xs btn-circle text-muted focus-visible:outline-base-content\" interestfor=\"accounts-hint\" popovertarget=\"accounts-hint\" popovertargetaction=\"show\" title=\"Show help\" type=\"button\">"
    <> element.to_string(view.info_icon())
    <> "</button>"
  assert hint
    == "<div class=\"inset-auto m-0 me-4 mb-1 max-w-80 rounded-box border border-base-300 bg-base-100 p-3 text-sm font-normal text-base-content shadow-lift [position-area:top_span-right] [position-try-fallbacks:flip-block,flip-inline]\" id=\"accounts-hint\" popover=\"hint\">Keys.</div>"
}

/// ダイアログのフォームは、欄の後に送信とキャンセルを折り返せる 1 行に並べる。キャンセルは送信せず、
/// 開いたときにフォーカスを受け、同じダイアログを閉じる。
pub fn in_dialog_form_puts_submit_and_cancel_on_one_row_test() {
  let html =
    element.to_string(view.post_form(
      "/relays",
      [html.p([], [html.text("field")])],
      "Save",
      view.PrimaryButton,
      view.InDialog(
        id: "dialog-x",
        dismiss: "Cancel",
        opening: view.OpensOnTrigger,
      ),
    ))
  assert html
    == "<form action=\"/relays\" class=\"flex flex-col gap-4\" method=\"post\"><p>field</p><div class=\"flex flex-wrap items-center gap-2\"><button class=\"btn btn-primary focus-visible:outline-base-content\" type=\"submit\">Save</button><button autofocus class=\"btn btn-ghost focus-visible:outline-base-content\" command=\"close\" commandfor=\"dialog-x\" type=\"button\">Cancel</button></div></form>"
}

/// 操作の行は、ダイアログのときだけボタンの後にキャンセルを足して 1 行にし、ほかの置き場所では
/// ボタンをそのまま返す。
pub fn dialog_actions_add_cancel_only_in_a_dialog_test() {
  let buttons = [html.a([], [html.text("Add")])]
  assert view.dialog_actions(view.InForm, buttons) == buttons
  assert view.dialog_actions(view.InRow, buttons) == buttons
  let assert [row] =
    view.dialog_actions(
      view.InDialog(
        id: "dialog-x",
        dismiss: "Cancel",
        opening: view.OpensOnTrigger,
      ),
      buttons,
    )
  assert element.to_string(row)
    == "<div class=\"flex flex-wrap items-center gap-2\"><a>Add</a><button autofocus class=\"btn btn-ghost focus-visible:outline-base-content\" command=\"close\" commandfor=\"dialog-x\" type=\"button\">Cancel</button></div>"
}

/// ⓘ つきのコピー欄は、見出しの横に ⓘ と補足を置き、欄の `aria-describedby` で補足を指す。
pub fn hinted_copyable_field_opens_the_hint_from_the_legend_test() {
  let html =
    element.to_string(view.hinted_copyable_field(
      i18n.English,
      "Connection URI",
      "uri-hint",
      "Paste it.",
      "bunker://x",
    ))
  assert string.contains(
    html,
    "<div class=\"fieldset-legend w-fit justify-start\">Connection URI"
      <> string.concat(list.map(
      view.info_hint(i18n.English, "uri-hint", [html.text("Paste it.")]),
      element.to_string,
    ))
      <> "</div>",
  )
  assert string.contains(
    html,
    "<input aria-describedby=\"uri-hint\" aria-label=\"Connection URI\"",
  )
}

/// 識別のラベルは、アカウントの一覧の行では大きい太字、ほかでは今の太さで出す。
pub fn identity_sizes_the_label_test() {
  let render = fn(size) {
    element.to_string(view.identity(i18n.English, size, "Main", "npub1x"))
  }
  assert string.contains(
    render(view.LargeIdentity),
    "<p class=\"text-lg font-bold leading-snug break-words\">Main</p>",
  )
  assert string.contains(
    render(view.PlainIdentity),
    "<p class=\"font-semibold break-words\">Main</p>",
  )
}

/// 警告の通知は畳まずに本文をそのまま出す（`details` にも `popover` にもしない）。
pub fn warning_alert_is_not_folded_test() {
  let html =
    element.to_string(view.alert(view.Warning, [html.text("Back up now.")]))
  assert string.contains(
    html,
    "<span class=\"wrap-anywhere\">Back up now.</span>",
  )
  assert !string.contains(html, "<details")
  assert !string.contains(html, "popover")
}

/// 上部のロゴの枠は内容の幅を基準に伸びる（`flex-1` のように基準の幅を 0 にしない）。
pub fn navbar_start_keeps_the_width_of_the_logo_test() {
  let html =
    view.page(
      i18n.English,
      view.System,
      view.TranslatedTitle(i18n.BackToDashboard),
      view.Narrow,
      view.SwitchReturningTo("/"),
      view.NoRefresh,
      [],
    )
  assert string.contains(html, "<div class=\"navbar-start w-auto grow\">")
}

/// 訳文の題は、表示の言語で引いて `<title>` の `Nostr-no-Su — ` の後と見出し（h1）に出す。
pub fn translated_title_goes_to_the_title_and_the_heading_test() {
  let html =
    view.page(
      i18n.English,
      view.System,
      view.TranslatedTitle(i18n.BackToDashboard),
      view.Narrow,
      view.SwitchReturningTo("/"),
      view.NoRefresh,
      [],
    )
  assert string.contains(html, "<title>Nostr-no-Su — Back to dashboard</title>")
  assert string.contains(
    html,
    "<h1 class=\"text-2xl font-bold\">Back to dashboard</h1>",
  )
}

/// 狭い画面で語を隠すダイアログのボタンは、`commandfor` で `id` を指し、語を `title` と `max-sm:sr-only` の `span` に置く。
pub fn compact_dialog_trigger_hides_the_text_on_narrow_screens_test() {
  let button =
    element.to_string(view.dialog_trigger(
      "dialog-x",
      view.CompactTrigger(view.qr_code_icon(), "Connection QR code"),
      view.PrimaryButton,
    ))
  assert button
    == "<button class=\"btn btn-primary btn-sm focus-visible:outline-base-content\" command=\"show-modal\" commandfor=\"dialog-x\" title=\"Connection QR code\" type=\"button\">"
    <> element.to_string(view.qr_code_icon())
    <> "<span class=\"max-sm:sr-only\">Connection QR code</span></button>"
}

/// 応答で開き Esc で閉じないダイアログは、`open` と `closedby="none"` を付けて描き、閉じるボタン（語は
/// `dismiss`）をダッシュボード（`/`）へのリンクにする。
pub fn pinned_dialog_ignores_close_requests_test() {
  let html =
    element.to_string(view.dialog(
      i18n.English,
      "dialog-x",
      "Title",
      fn(placement) { view.dialog_actions(placement, []) },
      i18n.Close,
      view.OpenedByResponsePinned,
    ))
  assert html
    == "<dialog aria-labelledby=\"dialog-x-title\" class=\"modal\" closedby=\"none\" id=\"dialog-x\" open><div class=\"modal-box flex flex-col gap-4\"><h2 class=\"card-title\" id=\"dialog-x-title\">Title</h2><div class=\"flex flex-wrap items-center gap-2\"><a autofocus class=\"btn btn-ghost focus-visible:outline-base-content\" href=\"/\">Close</a></div></div></dialog>"
}

/// アイコンと語のダイアログのボタンは `commandfor` で `id` のダイアログを指して開き、ダイアログは
/// 題と、`InDialog` を受けた中身だけを並べる（キャンセルは中身の操作の行が持つ）。
pub fn dialog_button_opens_the_dialog_it_names_test() {
  let html =
    view.dialog_button(
      i18n.English,
      "dialog-x",
      view.IconTextTrigger(view.plus_icon(), "Add"),
      view.PrimaryButton,
      "Title",
      fn(placement) {
        assert placement
          == view.InDialog(
            id: "dialog-x",
            dismiss: "Cancel",
            opening: view.OpensOnTrigger,
          )
        [html.p([], [html.text("body")])]
      },
      view.OpensOnTrigger,
    )
    |> list.map(element.to_string)
    |> string.concat
  assert html
    == "<button class=\"btn btn-primary btn-sm focus-visible:outline-base-content\" command=\"show-modal\" commandfor=\"dialog-x\" type=\"button\">"
    <> element.to_string(view.plus_icon())
    <> "Add</button>"
    <> "<dialog aria-labelledby=\"dialog-x-title\" class=\"modal\" id=\"dialog-x\"><div class=\"modal-box flex flex-col gap-4\"><h2 class=\"card-title\" id=\"dialog-x-title\">Title</h2><p>body</p></div></dialog>"
}

/// ダイアログのボタンの組は、ダイアログを `opening` の開き方で描く（応答で開くなら `open` を付け、
/// 閉じるボタンをダッシュボード（`/`）へのリンクにする）。
pub fn dialog_button_draws_the_dialog_with_the_given_opening_test() {
  let assert [_, dialog] =
    view.dialog_button(
      i18n.English,
      "dialog-x",
      view.TextTrigger("Revoke"),
      view.GhostButton,
      "Title",
      fn(placement) { view.dialog_actions(placement, []) },
      view.OpenedByResponse,
    )
  assert element.to_string(dialog)
    == "<dialog aria-labelledby=\"dialog-x-title\" class=\"modal\" id=\"dialog-x\" open><div class=\"modal-box flex flex-col gap-4\"><h2 class=\"card-title\" id=\"dialog-x-title\">Title</h2><div class=\"flex flex-wrap items-center gap-2\"><a autofocus class=\"btn btn-ghost focus-visible:outline-base-content\" href=\"/\">Cancel</a></div></div></dialog>"
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
      fn(_) { [] },
      view.OpensOnTrigger,
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
      fn(_) { [] },
      view.OpensOnTrigger,
    )
  assert element.to_string(button)
    == "<button class=\"btn btn-ghost btn-sm focus-visible:outline-base-content\" command=\"show-modal\" commandfor=\"dialog-x\" type=\"button\">Revoke</button>"
}

/// ダイアログの `id` は `dialog-` の後に部品を `-` で繋ぐ。
pub fn dialog_id_joins_the_parts_after_the_prefix_test() {
  assert view.dialog_id(["relay", "7", "edit"]) == "dialog-relay-7-edit"
}

/// プラグインのページの画像は、見た目の種類ごとに決まった完全なクラスの文字列で描く。
pub fn plugin_image_shapes_test() {
  let cases = [
    #(
      view.ContainedImage,
      "block h-auto w-auto max-h-48 max-w-full rounded-lg border border-base-300 bg-base-200 object-contain",
    ),
    #(
      view.IconImage,
      "block size-16 rounded-full border border-base-300 bg-base-200 object-cover",
    ),
    #(
      view.BannerImage,
      "block aspect-3/1 w-full max-h-48 rounded-lg border border-base-300 bg-base-200 object-cover",
    ),
  ]
  use #(shape, class) <- list.each(cases)
  let html =
    element.to_string(view.plugin_image("https://example.com/a.png", "a", shape))
  assert string.contains(html, "class=\"" <> class <> "\"")
}

/// タブはラベルの中のラジオと中身の枠を交互に並べ、最初のタブだけを選んだ状態で描く。
pub fn radio_tabs_check_the_first_tab_test() {
  assert element.to_string(
      view.radio_tabs("g", [#("One", [html.p([], [])]), #("Two", [])]),
    )
    == "<div class=\"tabs tabs-border\"><label class=\"tab\"><input checked name=\"g\" type=\"radio\">One</label><div class=\"tab-content pt-4\"><div class=\"flex flex-col gap-4\"><p></p></div></div><label class=\"tab\"><input name=\"g\" type=\"radio\">Two</label><div class=\"tab-content pt-4\"><div class=\"flex flex-col gap-4\"></div></div></div>"
}

/// `view.relative_time` は、境界の秒数ごとに正しい文言を返す。未来の時刻は
/// 「たった今」（`JustNow`）にする。
pub fn relative_time_buckets_test() {
  assert view.relative_time(1000, 1000) == i18n.JustNow
  assert view.relative_time(1059, 1000) == i18n.JustNow
  assert view.relative_time(1060, 1000) == i18n.MinutesAgo(1)
  assert view.relative_time(1000 + 3599, 1000) == i18n.MinutesAgo(59)
  assert view.relative_time(1000 + 3600, 1000) == i18n.HoursAgo(1)
  assert view.relative_time(1000 + 86_399, 1000) == i18n.HoursAgo(23)
  assert view.relative_time(1000 + 86_400, 1000) == i18n.DaysAgo(1)
  assert view.relative_time(1000, 2000) == i18n.JustNow
}
