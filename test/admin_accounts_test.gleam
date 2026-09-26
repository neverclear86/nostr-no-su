//// アカウント管理（登録、鍵の生成、秘密鍵の再表示、削除、secret の作り直し、
//// ラベル、接続 QR コードのダイアログ、ダッシュボードのアカウントの節）のテスト。

import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import lustre/element/html
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/qr
import nostr_no_su/admin/routes
import nostr_no_su/admin/view
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/bunker/vault
import nostr_no_su/nostr/nip19
import support/account_actions
import support/admin_context.{
  Added, NsecRequested, Relabeled, Removed, Rotated, account_row,
  action_dialog_id, action_path, auth_uri, auth_uri_camera_text, closed_dialog,
  context, failing_context, get, header, in_japanese, label, opened_dialog,
  password, post, post_form, reporting_context, signer, signer_npub, signer_nsec,
  skipped_npub, skipped_pubkey, skipped_row, spec_nsec, unavailable, uri,
  uri_camera_text, with_accounts, with_credentials, with_skipped,
}
import support/nip46_client.{account_for}
import wisp
import wisp/simulate

/// `spec_nsec` の秘密鍵の 16 進。
const spec_key = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

/// 生成した鍵のダイアログの隠しフィールドの nsec。
fn hidden_nsec(body: String) -> String {
  let assert Ok(#(_before, rest)) =
    string.split_once(body, "name=\"nsec\" type=\"hidden\" value=\"")
  let assert Ok(#(nsec, _after)) = string.split_once(rest, "\"")
  nsec
}

/// nsec から作ったアカウントの公開鍵の 16 進。
fn nsec_signer(nsec: String) -> String {
  let assert Ok(privkey) = nip19.decode(nsec, nip19.Nsec)
  let assert Ok(decoded) = account.from_privkey(privkey)
  account.pubkey_hex(decoded)
}

/// `body` の中で `attribute` を含む最初の `<input>` の開始タグの、`<input ` の後から `>` の前までの
/// 属性の並び。無ければ落ちる。
fn input_tag(body: String, attribute: String) -> String {
  let assert Ok(tag) =
    string.split(body, "<input ")
    |> list.drop(1)
    |> list.map(fn(piece) {
      let assert Ok(#(tag, _)) = string.split_once(piece, ">")
      tag
    })
    |> list.find(string.contains(_, attribute))
  tag
}

/// ダッシュボードのアカウントの節には、ラベルが出る。
pub fn dashboard_shows_account_labels_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(
    body,
    element.to_string(view.identity(
      i18n.English,
      view.LargeIdentity,
      label,
      signer_npub,
    )),
  )
}

/// アカウントの節の理由とラベルは、どちらもエスケープする。ラベルは利用者の入力で、
/// 理由には外から来た文字列が混ざりうる。
pub fn dashboard_escapes_account_labels_and_reasons_test() {
  let script = "<script>alert(1)</script>"
  let escaped = "&lt;script&gt;alert(1)&lt;/script&gt;"
  let labelled =
    simulate.read_body(get(with_accounts(Ok([account_row(script)])), "/"))
  assert string.contains(
    labelled,
    element.to_string(view.identity(
      i18n.English,
      view.LargeIdentity,
      script,
      signer_npub,
    )),
  )
  assert !string.contains(labelled, script)

  let failing = simulate.read_body(get(with_accounts(Error(script)), "/"))
  assert string.contains(
    failing,
    "<div class=\"alert alert-soft alert-error text-base-content\">"
      <> element.to_string(view.tone_icon(view.Failure))
      <> "<span class=\"wrap-anywhere\"><span lang=\"en\">"
      <> escaped
      <> "</span></span></div>",
  )
  assert !string.contains(failing, script)
}

// --- アカウントの登録 ---

/// nsec とラベルの POST で登録し、nsec を描画せずにダッシュボードへ 303 で戻る。
/// ラベルは前後の空白を除いて渡す。
pub fn import_registers_an_account_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", " work "),
    ])
  assert response.status == 303
  assert header(response, "location") == "/"
  assert !string.contains(simulate.read_body(response), spec_nsec)
  assert process.receive(reports, 1000)
    == Ok(Added(account.pubkey_hex(account_for(spec_key)), "work"))
}

/// 前後に空白を付けて大文字にした nsec でも、正規の表記の nsec と同じ鍵を登録する。
pub fn import_normalizes_the_nsec_test() {
  let reports = process.new_subject()
  let sent = " " <> string.uppercase(spec_nsec) <> "\n"
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", sent),
      #("label", "work"),
    ])
  assert response.status == 303
  assert process.receive(reports, 1000)
    == Ok(Added(account.pubkey_hex(account_for(spec_key)), "work"))
}

/// 不正な nsec の登録は 400 で、アカウントの追加のダイアログを開いたダッシュボードを返す。
pub fn import_error_opens_the_add_account_dialog_test() {
  let response =
    post_form(context(), "/accounts/import", [#("nsec", "nsec1invalid")])
  assert response.status == 400
  assert string.contains(
    simulate.read_body(response),
    "class=\"modal\" id=\"dialog-account-new\" open>",
  )
}

/// チェックサムの壊れた nsec は 400 で、送った文字列を応答に含めず、登録しない。
pub fn import_rejects_an_invalid_nsec_test() {
  let reports = process.new_subject()
  let broken = string.drop_end(spec_nsec, 1) <> "4"
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", broken),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "invalid bech32 checksum")
  assert !string.contains(body, broken)
  assert process.receive(reports, 100) == Error(Nil)
}

/// npub は nsec として受け付けない。
pub fn import_rejects_an_npub_test() {
  let response =
    post_form(context(), "/accounts/import", [#("nsec", signer_npub)])
  assert response.status == 400
  assert string.contains(simulate.read_body(response), "expected nsec prefix")
}

/// 範囲外の秘密鍵（0）の nsec は 400。
pub fn import_rejects_an_out_of_range_key_test() {
  let zero = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqwkhnav"
  let response = post_form(context(), "/accounts/import", [#("nsec", zero)])
  assert response.status == 400
  assert string.contains(
    simulate.read_body(response),
    "private key not in valid range",
  )
}

/// 登録済みの鍵は 409 で、アカウントの追加のダイアログを開き直して理由と、ダッシュボードへ戻る
/// 「キャンセル」を出す。nsec は出さない。
pub fn import_rejects_a_registered_account_test() {
  let response =
    post_form(context(), "/accounts/import", [
      #("nsec", signer_nsec),
      #("label", "work"),
    ])
  assert response.status == 409
  let body = simulate.read_body(response)
  let dialog = opened_dialog(body, "dialog-account-new")
  assert string.contains(dialog, "account is already registered")
  assert string.contains(
    dialog,
    "<a autofocus class=\"btn btn-ghost focus-visible:outline-base-content\" href=\"/\">Cancel</a>",
  )
  assert !string.contains(body, signer_nsec)
}

/// 反映されたか分からない登録は 202 の通知ページで、nsec を出さない。
pub fn import_that_may_have_been_applied_is_accepted_test() {
  let response =
    post_form(
      failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
      "/accounts/import",
      [#("nsec", spec_nsec), #("label", "work")],
    )
  assert response.status == 202
  let body = simulate.read_body(response)
  assert string.contains(body, i18n.text(i18n.English, i18n.StoreDidNotConfirm))
  assert string.contains(body, "Back to dashboard")
  assert !string.contains(body, spec_nsec)
}

/// 変更を受け付けられないときの登録は 503 で、nsec を出さない。
pub fn import_while_accounts_are_not_ready_is_unavailable_test() {
  let response =
    post_form(
      failing_context(bunker.NotReady("accounts are not loaded yet")),
      "/accounts/import",
      [#("nsec", spec_nsec), #("label", "work")],
    )
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "accounts are not loaded yet")
  assert !string.contains(body, spec_nsec)
}

/// 符号位置が 100 を超えるラベルと、制御文字を含むラベルは 400 で、登録しない。
/// 結合文字を続けたラベルは書記素クラスターでは 1 だが、符号位置で数えて拒否する。
pub fn import_rejects_a_label_over_the_code_point_limit_test() {
  let reports = process.new_subject()
  let labels = [
    #(
      "101 code points",
      string.repeat("a", 101),
      "label must be at most 100 characters",
    ),
    #(
      "combining marks",
      "e" <> string.repeat("\u{0301}", 100),
      "label must be at most 100 characters",
    ),
    #("line feed", "a\nb", "label must not contain control characters"),
    #("C1 control", "a\u{009B}b", "label must not contain control characters"),
  ]
  list.each(labels, fn(entry) {
    let #(name, sent, reason) = entry
    let response =
      post_form(reporting_context(reports), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", sent),
      ])
    assert #(name, response.status) == #(name, 400)
    assert #(name, string.contains(simulate.read_body(response), reason))
      == #(name, True)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 空のラベル（欄が無い、空文字列、空白だけ）と、trim の前にだけある制御文字
/// （末尾の "\n"、U+0085 だけ）と、双方向テキストの上書き（U+202E）を含むラベルは、
/// 登録、生成した鍵の登録、ラベルの編集のどの経路でも 400 になり、登録も更新もしない。
pub fn invalid_label_is_rejected_on_every_path_test() {
  let reports = process.new_subject()
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let cases = [
    #("no field", [], "label must not be empty"),
    #("empty", [#("label", "")], "label must not be empty"),
    #("spaces", [#("label", "   ")], "label must not be empty"),
    #(
      "trailing line feed",
      [#("label", "abc\n")],
      "label must not contain control characters",
    ),
    #(
      "next line only",
      [#("label", "\u{0085}")],
      "label must not contain control characters",
    ),
    #(
      "right-to-left override",
      [#("label", "a\u{202E}b")],
      "label must not contain control characters",
    ),
  ]
  let paths = [
    #("/accounts/import", [#("nsec", spec_nsec)]),
    #("/accounts/register-generated", [#("nsec", generated)]),
    #(action_path(routes.EditLabel), []),
  ]
  list.each(cases, fn(entry) {
    let #(name, label_field, reason) = entry
    list.each(paths, fn(path_entry) {
      let #(path, head_fields) = path_entry
      let response =
        post_form(
          reporting_context(reports),
          path,
          list.append(head_fields, label_field),
        )
      assert #(name, path, response.status) == #(name, path, 400)
      assert #(
          name,
          path,
          string.contains(simulate.read_body(response), reason),
        )
        == #(name, path, True)
    })
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// ラベルの欄を持つフォームを再描画する 5 つの経路は、応答で開いたダイアログの中で、送られた値から
/// 制御文字を除き trim しない値を欄に入れる。理由はこれまでどおり欄より前の `role="alert"` の囲みに
/// 出し、欄に `input-error` と `aria-invalid` を付けない。送った nsec は反射しない。
pub fn invalid_input_keeps_the_label_on_every_path_test() {
  let edit_id = action_dialog_id(routes.EditLabel)
  let broken = string.drop_end(spec_nsec, 1) <> "4"
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let cases = [
    #(
      "import with a broken nsec",
      post_form(context(), "/accounts/import", [
        #("nsec", broken),
        #("label", "a\tb"),
      ]),
      400,
      "invalid bech32 checksum",
      "ab",
      Some(broken),
      "dialog-account-new",
    ),
    #(
      "generated with a broken nsec",
      post_form(context(), "/accounts/register-generated", [
        #("nsec", broken),
        #("label", " a\tb "),
      ]),
      400,
      "invalid bech32 checksum",
      " ab ",
      Some(broken),
      "dialog-account-new",
    ),
    #(
      "import with a tab",
      post_form(context(), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", " a\tb"),
      ]),
      400,
      "label must not contain control characters",
      " ab",
      Some(spec_nsec),
      "dialog-account-new",
    ),
    #(
      "import with only spaces",
      post_form(context(), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", "   "),
      ]),
      400,
      "label must not be empty",
      "   ",
      Some(spec_nsec),
      "dialog-account-new",
    ),
    #(
      "generated with a next line",
      post_form(context(), "/accounts/register-generated", [
        #("nsec", generated),
        #("label", "a\u{0085}b "),
      ]),
      400,
      "label must not contain control characters",
      "ab ",
      None,
      "dialog-result",
    ),
    #(
      "import of a registered key",
      post_form(context(), "/accounts/import", [
        #("nsec", signer_nsec),
        #("label", " work "),
      ]),
      409,
      "account is already registered",
      " work ",
      Some(signer_nsec),
      "dialog-account-new",
    ),
    #(
      "edit with a line feed",
      post_form(context(), action_path(routes.EditLabel), [
        #("label", " a\nb "),
      ]),
      400,
      "label must not contain control characters",
      " ab ",
      None,
      edit_id,
    ),
    #(
      "edit with a right-to-left override",
      post_form(context(), action_path(routes.EditLabel), [
        #("label", " a\u{202E}b "),
      ]),
      400,
      "label must not contain control characters",
      " ab ",
      None,
      edit_id,
    ),
    #(
      "edit that was not applied",
      post_form(
        failing_context(bunker.NotApplied("account is not registered")),
        action_path(routes.EditLabel),
        [#("label", " new ")],
      ),
      409,
      "account is not registered",
      " new ",
      None,
      edit_id,
    ),
  ]
  use #(name, response, status, reason, field_value, sent_nsec, dialog_id) <- list.each(
    cases,
  )
  assert #(name, response.status) == #(name, status)
  let body = simulate.read_body(response)
  let dialog = opened_dialog(body, dialog_id)
  assert #(name, string.contains(dialog, reason)) == #(name, True)
  assert string.contains(
    dialog,
    "name=\"label\" required type=\"text\" value=\"" <> field_value <> "\"",
  )
  let assert Ok(#(_before, after_alert)) =
    string.split_once(
      dialog,
      "<div class=\"alert alert-soft alert-error text-base-content\" role=\"alert\">"
        <> element.to_string(view.tone_icon(view.Failure))
        <> "<span class=\"wrap-anywhere\">",
    )
  let assert Ok(#(reason_text, after_reason)) =
    string.split_once(after_alert, "</div>")
  assert string.contains(reason_text, reason)
  assert string.contains(after_reason, "name=\"label\"")
  assert !string.contains(body, "input-error")
  assert !string.contains(body, "aria-invalid")
  let echoes_the_sent_nsec = case sent_nsec {
    Some(nsec) -> string.contains(body, nsec)
    None -> False
  }
  assert !echoes_the_sent_nsec
  assert !string.contains(body, spec_nsec)
  assert !string.contains(body, signer_nsec)
}

/// 前後に空白を付けた 100 符号位置のラベルは通り、空白を除いた値で登録する。
pub fn import_accepts_a_label_at_the_code_point_limit_test() {
  let reports = process.new_subject()
  let limit = string.repeat("a", 100)
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", "  " <> limit <> " "),
    ])
  assert response.status == 303
  assert process.receive(reports, 1000)
    == Ok(Added(nsec_signer(spec_nsec), limit))
}

/// 欄の無いフォームは 400、フォームの本文が無い POST は 415 で、どちらも登録しない。
pub fn import_without_fields_is_rejected_test() {
  let reports = process.new_subject()
  let empty = post_form(reporting_context(reports), "/accounts/import", [])
  assert empty.status == 400
  assert string.contains(simulate.read_body(empty), "missing bech32 separator")
  assert post(reporting_context(reports), "/accounts/import").status == 415
  assert process.receive(reports, 100) == Error(Nil)
}

/// 鍵の生成は登録せず、生成した鍵のダイアログの隠しフィールドに有効な nsec を入れて、生成した鍵の
/// 登録へ送るフォームを返す。生成のたびに違う鍵になる。本文の無い POST も受け付ける。
pub fn generate_does_not_register_test() {
  let reports = process.new_subject()
  let response = post(reporting_context(reports), "/accounts/generate")
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(body, "action=\"/accounts/register-generated\"")
  let generated = hidden_nsec(body)
  let assert Ok(privkey) = nip19.decode(generated, nip19.Nsec)
  let assert Ok(_account) = account.from_privkey(privkey)
  let again =
    simulate.read_body(post(reporting_context(reports), "/accounts/generate"))
  assert hidden_nsec(again) != generated
  assert process.receive(reports, 100) == Error(Nil)
}

/// 生成した鍵のダイアログの nsec とラベルで生成した鍵を登録すると、nsec を描画せずに
/// ダッシュボードへ 303 で戻る。
pub fn generated_key_can_be_registered_test() {
  let reports = process.new_subject()
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let response =
    post_form(reporting_context(reports), "/accounts/register-generated", [
      #("nsec", generated),
      #("label", "fresh"),
    ])
  assert response.status == 303
  assert header(response, "location") == "/"
  assert !string.contains(simulate.read_body(response), generated)
  assert process.receive(reports, 1000)
    == Ok(Added(nsec_signer(generated), "fresh"))
}

/// 生成した鍵の登録でバンカーが失敗すると、生成した鍵を失わないよう、送られた nsec の
/// ダイアログを理由付きで開いて返す。状態コードは nsec 入力による登録と同じで、ラベルの欄には
/// 送られた値を入れる。
pub fn register_generated_bunker_failure_keeps_the_key_test() {
  let path = "/accounts/register-generated"
  let label = " work "
  let cases = [
    #(
      "already registered",
      context(),
      signer_nsec,
      409,
      view.reason_alert(view.Failure, [
        html.text(i18n.text(i18n.English, i18n.AccountAlreadyRegistered)),
      ]),
    ),
    #(
      "not ready",
      failing_context(bunker.NotReady("accounts are not loaded yet")),
      spec_nsec,
      503,
      view.reason_alert(view.Warning, [
        html.text(i18n.text(i18n.English, i18n.RegistrationNotAccepted) <> " "),
        view.untranslated("accounts are not loaded yet"),
      ]),
    ),
    #(
      "maybe applied",
      failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
      spec_nsec,
      202,
      view.reason_alert(view.Warning, [
        html.text(
          i18n.text(i18n.English, i18n.RegistrationNotConfirmed)
          <> " "
          <> i18n.text(i18n.English, i18n.StoreDidNotConfirm),
        ),
      ]),
    ),
  ]
  use #(name, ctx, nsec, status, alert) <- list.each(cases)
  let response = post_form(ctx, path, [#("nsec", nsec), #("label", label)])
  assert #(name, response.status) == #(name, status)
  let body = simulate.read_body(response)
  assert hidden_nsec(body) == nsec
  assert string.contains(body, "action=\"/accounts/register-generated\"")
  assert #(name, string.contains(body, element.to_string(alert)))
    == #(name, True)
  assert string.contains(
    body,
    "name=\"label\" required type=\"text\" value=\" work \"",
  )
  assert header(response, "cache-control") == "no-store"
}

/// 生成した鍵の登録でバンカーが反映しなかった失敗は、未登録も含めて 409 で、送られた nsec の
/// ダイアログを理由付きで開いて返す。
pub fn register_generated_unapplied_failures_keep_the_key_test() {
  let cases = [
    #(bunker.NotApplied("not written"), "not written"),
    #(
      bunker.AccountNotRegistered,
      i18n.text(i18n.English, i18n.AccountNotFound),
    ),
  ]
  use #(failure, reason) <- list.each(cases)
  let response =
    post_form(failing_context(failure), "/accounts/register-generated", [
      #("nsec", spec_nsec),
      #("label", "work"),
    ])
  assert #(reason, response.status) == #(reason, 409)
  let body = simulate.read_body(response)
  assert hidden_nsec(body) == spec_nsec
  assert string.contains(body, reason)
}

/// 生成した鍵の登録でラベルだけが規則に反すると、生成した鍵を失わないよう、送られた
/// nsec のダイアログを理由付きで開いて 400 で返す。登録はせず、ラベルの欄には制御文字を除いた
/// 値を入れる。
pub fn register_generated_with_an_invalid_label_keeps_the_key_test() {
  let reports = process.new_subject()
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let response =
    post_form(reporting_context(reports), "/accounts/register-generated", [
      #("nsec", generated),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert hidden_nsec(body) == generated
  assert string.contains(body, "action=\"/accounts/register-generated\"")
  assert string.contains(
    body,
    "<div class=\"alert alert-soft alert-error text-base-content\" role=\"alert\">"
      <> element.to_string(view.tone_icon(view.Failure))
      <> "<span class=\"wrap-anywhere\">label must not contain control characters</span></div>",
  )
  assert string.contains(body, "value=\"ab\"")
  assert !string.contains(body, "a\tb")
  assert header(response, "cache-control") == "no-store"
  assert process.receive(reports, 100) == Error(Nil)
}

/// 生成した鍵の登録で nsec が不正なら、ラベルの不正を問わずアカウントの追加のダイアログを 400 で開いて返す。
pub fn register_generated_with_an_invalid_nsec_returns_to_the_registration_page_test() {
  let response =
    post_form(context(), "/accounts/register-generated", [
      #("nsec", "nsec1invalid"),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(
    opened_dialog(body, "dialog-account-new"),
    "action=\"/accounts/import\"",
  )
  assert !string.contains(body, "action=\"/accounts/register-generated\"")
}

/// nsec 入力による登録でラベルが規則に反すると、アカウントの追加のダイアログを開いて返し、nsec を出さない。
pub fn import_with_an_invalid_label_does_not_echo_the_nsec_test() {
  let response =
    post_form(context(), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(
    opened_dialog(body, "dialog-account-new"),
    "action=\"/accounts/import\"",
  )
  assert !string.contains(body, spec_nsec)
}

/// 登録の POST のルートは GET を受け付けない。
pub fn registration_routes_reject_other_methods_test() {
  let paths = [
    "/accounts/import", "/accounts/generate", "/accounts/register-generated",
  ]
  list.each(paths, fn(path) {
    assert get(context(), path).status == 405
  })
}

/// `/accounts/new` の GET は 404 になる（アカウントの追加はダッシュボードのダイアログで行う）。
pub fn new_account_page_is_not_found_test() {
  assert get(context(), "/accounts/new").status == 404
}

/// 鍵の生成は、Esc で閉じない生成した鍵のダイアログ（`dialog-result`）を開いたダッシュボードを返す。
/// 自動の読み込み直しはせず、テーマと言語の切り替えはダッシュボード（`/`）へ戻る。
pub fn generate_opens_the_generated_key_dialog_test() {
  let body = simulate.read_body(post(context(), "/accounts/generate"))
  assert string.contains(
    body,
    "class=\"modal\" closedby=\"none\" id=\"dialog-result\" open>",
  )
  assert string.contains(
    opened_dialog(body, "dialog-result"),
    "action=\"/accounts/register-generated\"",
  )
  assert !string.contains(body, "http-equiv=\"refresh\"")
  assert string.contains(
    body,
    "<input name=\"return\" type=\"hidden\" value=\"/\">",
  )
}

/// アカウントの追加のダイアログの nsec のフォームと欄は伏せ字で、パスワードとして保存させない。
pub fn new_account_form_does_not_save_the_nsec_as_a_password_test() {
  let body =
    closed_dialog(simulate.read_body(get(context(), "/")), "dialog-account-new")
  let nsec_input = input_tag(body, "name=\"nsec\"")
  assert string.contains(nsec_input, "type=\"password\"")
  assert string.contains(nsec_input, "autocomplete=\"new-password\"")
  assert string.contains(
    body,
    "<form action=\""
      <> view.segments_path(routes.import_account_segments)
      <> "\" autocomplete=\"off\"",
  )
}

// --- 秘密鍵の再表示 ---

/// パスワードが違えば 403 で、秘密鍵の表示のダイアログを開き直して理由を出す。nsec もパスワードも出さず、
/// nsec を問い合わせない。Basic 認証の入力を促すヘッダーも付けない。
pub fn reveal_with_a_wrong_password_is_forbidden_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), action_path(routes.RevealPrivateKey), [
      #("password", "wrong-guess"),
    ])
  assert response.status == 403
  let body = simulate.read_body(response)
  assert string.contains(
    opened_dialog(body, action_dialog_id(routes.RevealPrivateKey)),
    "incorrect password",
  )
  assert !string.contains(body, signer_nsec)
  assert !string.contains(body, "wrong-guess")
  assert list.key_find(response.headers, "www-authenticate") == Error(Nil)
  assert process.receive(reports, 100) == Error(Nil)
}

/// 再入力が一致しない応答は、Context の `authentication_delay` を呼んでから返る。
/// 一致するときは呼ばない。
pub fn reveal_with_a_wrong_password_waits_test() {
  let waited = process.new_subject()
  let context =
    admin.Context(..context(), authentication_delay: fn() {
      process.send(waited, Nil)
    })
  let wrong =
    post_form(context, action_path(routes.RevealPrivateKey), [
      #("password", "wrong-guess"),
    ])
  assert wrong.status == 403
  assert process.receive(waited, 0) == Ok(Nil)

  let correct =
    post_form(context, action_path(routes.RevealPrivateKey), [
      #("password", password),
    ])
  assert correct.status == 200
  assert process.receive(waited, 0) == Error(Nil)
}

/// 正しいパスワードなら、一覧の署名者の nsec を問い合わせ、Esc で閉じない秘密鍵のダイアログ
/// （`dialog-result`）で表示する。
pub fn reveal_with_the_password_shows_the_nsec_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), action_path(routes.RevealPrivateKey), [
      #("password", password),
    ])
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(body, "closedby=\"none\" id=\"dialog-result\" open>")
  assert string.contains(opened_dialog(body, "dialog-result"), signer_nsec)
  assert process.receive(reports, 1000) == Ok(NsecRequested(signer))
}

/// nsec の問い合わせが失敗したら 503 の通知ページにする。
pub fn reveal_failure_is_unavailable_test() {
  let failing =
    admin.Context(..context(), nsec: fn(_signer) {
      Error("accounts are not loaded yet")
    })
  let response =
    post_form(failing, action_path(routes.RevealPrivateKey), [
      #("password", password),
    ])
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "accounts are not loaded yet")
  assert string.contains(body, "Back to dashboard")
}

/// 一覧に無い署名者への POST は 404 で、パスの値を応答に含めず、何も呼ばない。
pub fn reveal_for_an_unknown_signer_is_not_found_test() {
  let reports = process.new_subject()
  let path = "/accounts/%3Cscript%3Eunknown/private-key"
  let response =
    post_form(reporting_context(reports), path, [#("password", password)])
  assert response.status == 404
  assert !string.contains(simulate.read_body(response), "%3Cscript%3Eunknown")
  assert process.receive(reports, 100) == Error(Nil)
}

// --- 削除、secret の作り直し、ラベル ---

/// 削除のダイアログは、鍵を失うことを伝え、エスケープしたラベルと npub を出す。
pub fn delete_page_warns_about_losing_the_key_test() {
  let labelled = with_accounts(Ok([account_row("<b>x</b>")]))
  let body =
    closed_dialog(
      simulate.read_body(get(labelled, "/")),
      action_dialog_id(routes.DeleteAccount),
    )
  assert string.contains(body, signer_npub)
  assert string.contains(body, "&lt;b&gt;x&lt;/b&gt;")
  assert string.contains(body, "the account is lost")
  assert string.contains(body, "action=\"/accounts/" <> signer <> "/delete\"")
}

/// 削除の POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn delete_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post(reporting_context(reports), action_path(routes.DeleteAccount))
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reports, 1000) == Ok(Removed(signer))
}

/// secret の作り直しのダイアログは、古い URI での新規の接続が拒否され、承認済みの
/// セッションが残ることを伝える。
pub fn rotate_page_explains_the_effect_test() {
  let body =
    closed_dialog(
      simulate.read_body(get(context(), "/")),
      action_dialog_id(routes.RotateSecret),
    )
  assert string.contains(
    body,
    "old connection URI are no longer accepted without approval",
  )
  assert string.contains(body, "sessions that are already approved remain")
}

/// secret の作り直しの POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn rotate_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post(reporting_context(reports), action_path(routes.RotateSecret))
  assert response.status == 303
  assert process.receive(reports, 1000) == Ok(Rotated(signer))
}

/// ラベルの POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn label_update_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), action_path(routes.EditLabel), [
      #("label", "new"),
    ])
  assert response.status == 303
  assert process.receive(reports, 1000) == Ok(Relabeled(signer, "new"))
}

/// ラベルの編集のダイアログを開き直しても、要約は保存済みのラベルのまま。
pub fn edit_page_keeps_the_saved_label_in_the_summary_test() {
  let saved =
    element.to_string(view.identity(
      i18n.English,
      view.PlainIdentity,
      label,
      signer_npub,
    ))
  let id = action_dialog_id(routes.EditLabel)
  let invalid_input =
    simulate.read_body(
      post_form(context(), action_path(routes.EditLabel), [
        #("label", "a\nb"),
      ]),
    )
  assert string.contains(opened_dialog(invalid_input, id), saved)
  let conflict =
    simulate.read_body(
      post_form(
        failing_context(bunker.NotApplied("account is not registered")),
        action_path(routes.EditLabel),
        [#("label", "new")],
      ),
    )
  assert string.contains(opened_dialog(conflict, id), saved)
}

/// 欄に戻したラベルは属性値としてエスケープする。
pub fn reflected_label_is_escaped_test() {
  let body =
    simulate.read_body(
      post_form(context(), "/accounts/import", [
        #("nsec", "nsec1invalid"),
        #("label", "a\tb\"><b>"),
      ]),
    )
  assert string.contains(body, "value=\"ab&quot;&gt;&lt;b&gt;\"")
  assert !string.contains(body, "\"><b>")
}

/// 3 つのラベルの欄には `maxlength` が無く、欄の下に表示の言語の上限の案内がある。案内の `id` は
/// ダイアログごとに違う。
pub fn label_inputs_describe_the_limit_without_maxlength_test() {
  let hint = fn(language, hint_id) {
    "<p class=\"text-muted\" id=\""
    <> hint_id
    <> "\">"
    <> i18n.text(language, i18n.LabelHint(max: dashboard.max_label_code_points))
    <> "</p>"
  }
  let edit_id = action_dialog_id(routes.EditLabel)
  let fields = label_dialogs()
  let hint_ids = [
    "label-hint",
    "dialog-result-label-hint",
    edit_id <> "-label-hint",
  ]
  list.each(list.zip(fields, hint_ids), fn(entry) {
    let #(dialog, hint_id) = entry
    assert !string.contains(dialog, "maxlength")
    assert string.contains(
      dialog,
      "aria-describedby=\""
        <> hint_id
        <> "\" aria-label=\"Label\" autocomplete=\"off\"",
    )
    assert string.contains(dialog, hint(i18n.English, hint_id))
  })

  let japanese_request =
    simulate.request(http.Get, "/")
    |> in_japanese
    |> with_credentials("admin", password)
  let japanese_body =
    closed_dialog(
      simulate.read_body(admin.handle_request(context(), japanese_request)),
      "dialog-account-new",
    )
  assert string.contains(
    japanese_body,
    "aria-describedby=\"label-hint\" aria-label=\"ラベル\" autocomplete=\"off\"",
  )
  assert string.contains(japanese_body, hint(i18n.Japanese, "label-hint"))
}

/// アカウントの追加、生成した鍵、ラベルの編集のダイアログの 3 つの欄はどれも必須。
pub fn label_inputs_are_required_test() {
  list.each(label_dialogs(), fn(dialog) {
    assert string.contains(dialog, "name=\"label\" required type=\"text\"")
  })
}

/// ラベルの欄を持つ 3 つのダイアログ（アカウントの追加、生成した鍵、ラベルの編集）の中身。
fn label_dialogs() -> List(String) {
  let dashboard_body = simulate.read_body(get(context(), "/"))
  [
    closed_dialog(dashboard_body, "dialog-account-new"),
    opened_dialog(
      simulate.read_body(post(context(), "/accounts/generate")),
      "dialog-result",
    ),
    closed_dialog(dashboard_body, action_dialog_id(routes.EditLabel)),
  ]
}

/// 削除、secret の作り直し、ラベルの POST の失敗は、反映されていなければ同じダイアログを開き直して 409、
/// 対象が登録されていなければ 404、受け付けられなければ 503、反映されたか分からなければ 202 になる。
/// 409 は開いたダイアログに、ほかは通知ページに理由とダッシュボードへのリンクを出す。
pub fn account_change_failures_map_to_status_codes_test() {
  let changes = [
    #(routes.DeleteAccount, []),
    #(routes.RotateSecret, []),
    #(routes.EditLabel, [#("label", "new")]),
  ]
  use #(failure, status, reason) <- list.each(change_failures())
  use #(action, fields) <- list.each(changes)
  let response =
    post_form(failing_context(failure), action_path(action), fields)
  assert #(action, response.status) == #(action, status)
  assert_failure_body(
    simulate.read_body(response),
    status,
    reason,
    action_dialog_id(action),
  )
}

/// 変更の失敗と、その応答の状態コードと理由の組。
fn change_failures() -> List(#(bunker.ChangeFailure, Int, String)) {
  let not_applied_reason = "account is not registered"
  let not_ready_reason = "accounts are not loaded yet"
  [
    #(bunker.NotApplied(not_applied_reason), 409, not_applied_reason),
    #(
      bunker.AccountNotRegistered,
      404,
      i18n.text(i18n.English, i18n.AccountNotFound),
    ),
    #(bunker.NotReady(not_ready_reason), 503, not_ready_reason),
    #(
      bunker.MaybeApplied(bunker.StoreDidNotConfirm),
      202,
      i18n.text(i18n.English, i18n.StoreDidNotConfirm),
    ),
  ]
}

/// 変更の失敗の応答の本文。409 はダイアログ `dialog_id` を開き直して理由を出し、ほかは通知ページに
/// 理由とダッシュボードへのリンクを出す。
fn assert_failure_body(
  body: String,
  status: Int,
  reason: String,
  dialog_id: String,
) -> Nil {
  case status {
    409 -> {
      assert string.contains(opened_dialog(body, dialog_id), reason)
      Nil
    }
    _ -> {
      assert string.contains(body, reason)
      assert string.contains(
        body,
        element.to_string(view.back_link(i18n.English)),
      )
      Nil
    }
  }
}

/// 失敗を開き直す行が、スナップショットを取り直す間に一覧から消えていたら、ダイアログを描けないので
/// 警告の色の 503 の通知ページにする。
pub fn account_dialog_for_a_vanished_row_is_a_notice_test() {
  let owner = process.self()
  let vanishing =
    admin.Context(
      ..context(),
      accounts: fn() {
        case process.self() == owner {
          True -> Ok([account_row(label)])
          False -> Ok([])
        }
      },
      rotate_secret: fn(_signer) { Error(bunker.NotApplied("not applied")) },
    )
  let response = post(vanishing, action_path(routes.RotateSecret))
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    element.to_string(view.notice_mark(view.Warning)),
  )
  assert string.contains(
    body,
    ">" <> i18n.text(i18n.English, i18n.AccountsNotAvailable) <> "</h1>",
  )
}

/// 一覧に無い署名者（削除済みなど）への削除、secret の作り直し、ラベルの POST は 404 の HTML で、
/// 理由を出し、署名者を含めず、Context の変更を呼ばない。反映済みの削除を再送した場合もこの経路になる。
pub fn changes_to_an_unlisted_signer_are_not_found_test() {
  let reports = process.new_subject()
  let emptied =
    admin.Context(..reporting_context(reports), accounts: fn() { Ok([]) })
  let changes = [
    #(routes.DeleteAccount, []),
    #(routes.RotateSecret, []),
    #(routes.EditLabel, [#("label", "new")]),
  ]
  list.each(changes, fn(entry) {
    let #(action, fields) = entry
    let response = post_form(emptied, action_path(action), fields)
    assert #(action, response.status) == #(action, 404)
    assert #(action, header(response, "content-type"))
      == #(action, "text/html; charset=utf-8")
    let body = simulate.read_body(response)
    assert #(
        action,
        string.contains(body, i18n.text(i18n.English, i18n.AccountNotFound)),
      )
      == #(action, True)
    assert #(action, string.contains(body, signer)) == #(action, False)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 登録済みの行の操作と読み込めなかった行の削除は POST だけを受け、GET は `Allow: POST` の 405 にする。
pub fn account_actions_accept_only_post_test() {
  let paths =
    list.append(list.map(account_actions.all, action_path), [
      skipped_delete_path(),
    ])
  use path <- list.each(paths)
  let response = get(with_skipped(Ok([skipped_row()])), path)
  assert #(path, response.status) == #(path, 405)
  assert header(response, "allow") == "POST"
}

/// 知らない操作のセグメントは 404。
pub fn unknown_account_action_is_not_found_test() {
  assert get(context(), "/accounts/" <> signer <> "/nope").status == 404
  assert post(context(), "/accounts/" <> signer <> "/nope").status == 404
}

/// アカウントの一覧を得られなければ、操作の POST は 503 で理由を出す。
pub fn account_pages_need_the_account_list_test() {
  let failing = with_accounts(Error(unavailable))
  use action <- list.each(account_actions.all)
  let response = post(failing, action_path(action))
  assert #(action, response.status) == #(action, 503)
  let body = simulate.read_body(response)
  assert #(action, string.contains(body, unavailable)) == #(action, True)
  assert string.contains(body, "Back to dashboard")
}

// --- 読み込みで飛ばされた行の削除 ---

/// 飛ばされた行の削除のパス。
fn skipped_delete_path() -> String {
  routes.account_action_path(skipped_pubkey, routes.DeleteAccount)
}

/// 飛ばされた行の削除のダイアログの `id`。
fn skipped_dialog_id() -> String {
  "dialog-unreadable-" <> skipped_pubkey <> "-delete"
}

/// ダッシュボードの飛ばされた行には理由を出し、その行の削除のダイアログにはラベル・npub・説明・
/// フォームの宛先が出る。
pub fn unreadable_delete_page_shows_the_row_test() {
  let body = simulate.read_body(get(with_skipped(Ok([skipped_row()])), "/"))
  assert string.contains(
    body,
    i18n.text(
      i18n.English,
      i18n.UnreadableReason(vault.UndecryptablePrivateKey),
    ),
  )
  let dialog = closed_dialog(body, skipped_dialog_id())
  assert string.contains(dialog, "Delete account")
  assert string.contains(dialog, "old wallet")
  assert string.contains(dialog, skipped_npub)
  assert string.contains(
    dialog,
    "This removes the row from the bunker and the database.",
  )
  assert string.contains(dialog, "action=\"" <> skipped_delete_path() <> "\"")
}

/// 飛ばされた行の削除の POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn unreadable_delete_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post(
      admin.Context(..reporting_context(reports), skipped: fn() {
        Ok([skipped_row()])
      }),
      skipped_delete_path(),
    )
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reports, 1000) == Ok(Removed(skipped_pubkey))
}

/// どちらの一覧にも無い pubkey と、`MalformedPubkey` の行の生の値への削除の
/// POST は 404 で、Context の変更を呼ばない。
pub fn unreadable_delete_for_an_unlisted_or_malformed_pubkey_is_not_found_test() {
  let reports = process.new_subject()
  let malformed_pubkey = "not-a-valid-pubkey"
  let with_malformed =
    admin.Context(..reporting_context(reports), skipped: fn() {
      Ok([
        dashboard.SkippedRow(
          pubkey: malformed_pubkey,
          npub: None,
          label: "",
          reason: vault.MalformedPubkey,
        ),
      ])
    })
  let unlisted_path =
    routes.account_action_path("unknown-pubkey", routes.DeleteAccount)
  let malformed_path =
    routes.account_action_path(malformed_pubkey, routes.DeleteAccount)
  list.each([unlisted_path, malformed_path], fn(path) {
    assert post(with_malformed, path).status == 404
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 飛ばされた行の一覧を得られなければ、削除の POST は 503 で理由を出す。
pub fn unreadable_delete_needs_the_skipped_list_test() {
  let response = post(with_skipped(Error(unavailable)), skipped_delete_path())
  assert response.status == 503
  assert string.contains(simulate.read_body(response), unavailable)
}

/// 飛ばされた行の削除の POST の失敗は、登録済みの削除と同じ対応で状態コードが
/// 決まる。409 はその行の削除のダイアログを開き直す。
pub fn unreadable_delete_failures_map_to_status_codes_test() {
  use #(failure, status, reason) <- list.each(change_failures())
  let failing =
    admin.Context(
      ..with_skipped(Ok([skipped_row()])),
      remove_account: fn(_signer) { Error(failure) },
    )
  let response = post(failing, skipped_delete_path())
  assert response.status == status
  assert_failure_body(
    simulate.read_body(response),
    status,
    reason,
    skipped_dialog_id(),
  )
}

// --- ダッシュボードのアカウントの節 ---

/// アカウントの節には、npub、読み取り専用の欄の URI、接続 QR コードのボタン、4 つの操作のダイアログの
/// フォーム、アカウントの追加のボタンが出る。
pub fn dashboard_lists_account_actions_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(body, signer_npub)
  let uri_input =
    input_tag(body, "aria-describedby=\"account-" <> signer <> "-uri-hint\"")
  assert string.contains(uri_input, " readonly ")
  assert string.contains(uri_input, "value=\"" <> wisp.escape_html(uri) <> "\"")
  assert string.contains(body, "commandfor=\"dialog-account-new\"")
  assert string.contains(body, "commandfor=\"" <> qr_dialog_id <> "\"")
  list.each(account_actions.all, fn(action) {
    assert string.contains(body, "action=\"" <> action_path(action) <> "\"")
  })
}

/// URI に `"` が含まれても、`value` の属性値の外に出ない。
pub fn dashboard_escapes_a_uri_attribute_test() {
  let row =
    dashboard.AccountRow(..account_row(label), uri: "bunker://x?\"><b>xss</b>")
  let body = simulate.read_body(get(with_accounts(Ok([row])), "/"))
  assert string.contains(
    body,
    "value=\"bunker://x?&quot;&gt;&lt;b&gt;xss&lt;/b&gt;\"",
  )
  assert !string.contains(body, "<b>xss</b>")
}

// --- 接続 QR コード ---

/// 接続 QR コードのダイアログの `id`。
const qr_dialog_id = "dialog-account-" <> signer <> "-qr"

/// `context` のダッシュボードの、接続 QR コードのダイアログの中身。
fn qr_dialog(context: admin.Context) -> String {
  closed_dialog(simulate.read_body(get(context, "/")), qr_dialog_id)
}

/// 接続 QR コードの操作のパスは無く、GET は 404 になる。
pub fn connection_qr_path_is_not_found_test() {
  assert get(context(), "/accounts/" <> signer <> "/qr").status == 404
}

/// 接続 QR コードのダイアログは、secret 入りの URI と要承認の URI を、それぞれカメラ用と
/// クライアントの読み取り機能用の 2 枚の QR コードとコピー欄で出す。
pub fn connection_qr_dialog_shows_both_uris_test() {
  let body = qr_dialog(context())
  assert list.length(string.split(body, "role=\"img\"")) == 5
  assert string.contains(body, "value=\"" <> wisp.escape_html(uri) <> "\"")
  assert string.contains(body, "value=\"" <> wisp.escape_html(auth_uri) <> "\"")
}

/// 各タブの QR は、カメラ用に行の `uri_camera_text` と `auth_uri_camera_text` のコピー用の文字列を、
/// 畳みの中に完全な URI を載せる。クライアントの読み取り機能で読む語も本文に出る。
pub fn connection_qr_dialog_shows_a_camera_code_and_a_scanner_code_test() {
  let body = qr_dialog(context())
  let scanner = i18n.text(i18n.English, i18n.ScanWithClientScanner)
  list.each(
    [
      #("Connection URI", uri, uri_camera_text),
      #("Connection URI (approval)", auth_uri, auth_uri_camera_text),
    ],
    fn(pair) {
      let #(title, full, camera_text) = pair
      let assert Ok(camera_svg) = qr.svg(title, camera_text)
      let assert Ok(scanner_svg) = qr.svg(title <> " / " <> scanner, full)
      assert string.contains(body, element.to_string(camera_svg))
      assert string.contains(body, element.to_string(scanner_svg))
    },
  )
  assert string.contains(body, wisp.escape_html(scanner))
}

/// 2 つの接続 URI は、同じ名前（ダイアログの `id` に `-tab` を付けた値）のラジオボタンを入れた
/// `tab` のラベルと、その直後の `tab-content` の組で切り替える。CSS の `:checked` で切り替わるので
/// JS は要らない。既定で選ぶのは secret 入りの URI である。
pub fn connection_qr_dialog_switches_the_uris_with_radio_tabs_test() {
  let body = qr_dialog(context())
  let name = qr_dialog_id <> "-tab"
  assert string.contains(
    body,
    "<label class=\"tab\"><input checked name=\""
      <> name
      <> "\" type=\"radio\">Connection URI</label><div class=\"tab-content",
  )
  assert string.contains(
    body,
    "<label class=\"tab\"><input name=\""
      <> name
      <> "\" type=\"radio\">Connection URI (approval)</label><div class=\"tab-content",
  )
  assert list.length(string.split(body, "type=\"radio\"")) == 3
}

/// secret 入りの URI のタブの警告は、既定で選ぶタブの中にあり、畳み（`details`）に入れない。
pub fn connection_qr_dialog_keeps_the_secret_warning_open_test() {
  let body = qr_dialog(context())
  let warning =
    wisp.escape_html(i18n.text(i18n.English, i18n.ConnectionQrSecretWarning))
  let assert Ok(#(before, _)) = string.split_once(body, warning)
  assert list.length(string.split(before, "<details"))
    == list.length(string.split(before, "</details>"))
  assert string.contains(before, "<input checked name=\"" <> qr_dialog_id)
  assert !string.contains(before, "Connection URI (approval)</label>")
}

/// カメラ用のコードの貼り方の案内は、タブの外に 1 回だけ出す。
pub fn connection_qr_dialog_shows_the_camera_steps_once_test() {
  let steps = wisp.escape_html(i18n.text(i18n.English, i18n.CameraCopySteps))
  assert list.length(string.split(qr_dialog(context()), steps)) == 2
}

/// 要承認の URI のタブは、承認するまで署名できない旨の説明を中身に持つ。
pub fn connection_qr_dialog_explains_the_approval_uri_test() {
  let body = qr_dialog(context())
  let assert Ok(#(_before, approval_tab)) =
    string.split_once(body, "Connection URI (approval)</label>")
  assert string.contains(
    approval_tab,
    wisp.escape_html(i18n.text(i18n.English, i18n.ApprovalUriNeedsApproval)),
  )
}

/// バンカー用途のリレーがある Context では、その URL と一覧の見出しがダイアログに出る。
pub fn connection_qr_dialog_lists_the_bunker_relays_test() {
  let body = qr_dialog(context())
  assert string.contains(body, "wss://bunker.example")
  assert string.contains(body, i18n.text(i18n.English, i18n.BunkerRelaysForUri))
}

/// リレーの一覧を得られないときは、一覧の代わりに理由を出す。QR コードの枚数は変わらない。
pub fn connection_qr_dialog_notes_relays_that_cannot_be_listed_test() {
  let body =
    qr_dialog(
      admin.Context(..context(), relays: fn(_deadline) {
        Error("relay list did not answer")
      }),
    )
  assert string.contains(body, "relay list did not answer")
  assert list.length(string.split(body, "role=\"img\"")) == 5
}

/// バンカーに使うリレーが 1 件も無ければエラーの色の囲みを出す。バンカー用途のリレーがある
/// Context と、一覧を得られない Context では出ない。
pub fn connection_qr_dialog_warns_without_a_bunker_relay_test() {
  let warning =
    i18n.text(i18n.English, i18n.NoBunkerRelay)
    |> string.slice(0, 30)
  let without_relay =
    admin.Context(..context(), relays: fn(_deadline) { Ok([]) })
  assert string.contains(qr_dialog(without_relay), warning)
  assert string.contains(qr_dialog(context()), warning) == False
  let unavailable_relays =
    admin.Context(..context(), relays: fn(_deadline) {
      Error("relay list did not answer")
    })
  assert string.contains(qr_dialog(unavailable_relays), warning) == False
}

/// 符号化できない長さの URI は、その位置に理由を出し、コピー欄は残す。
pub fn connection_qr_dialog_notes_an_unencodable_uri_test() {
  let unencodable_uri = string.repeat("0", 3000)
  let row = dashboard.AccountRow(..account_row(label), uri: unencodable_uri)
  let body = qr_dialog(with_accounts(Ok([row])))
  assert string.contains(
    body,
    string.slice(i18n.text(i18n.English, i18n.CouldNotEncodeQr), 0, 20),
  )
  assert string.contains(body, "value=\"" <> unencodable_uri <> "\"")
}
