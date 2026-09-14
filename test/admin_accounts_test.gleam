//// アカウント管理（登録、鍵の生成、秘密鍵の再表示、削除、secret の作り直し、
//// ラベル、ダッシュボードのアカウントの節）のテスト。

import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import nostr_no_su/admin
import nostr_no_su/admin/dashboard
import nostr_no_su/admin/i18n
import nostr_no_su/admin/view
import nostr_no_su/bunker
import nostr_no_su/bunker/account
import nostr_no_su/nostr/nip19
import support/account_actions
import support/admin_context.{
  Added, NsecRequested, Relabeled, Removed, Rotated, account_row, action_path,
  context, failing_context, get, header, in_japanese, label, password, post,
  post_form, reporting_context, signer, signer_npub, signer_nsec, spec_nsec,
  unavailable, uri, with_accounts, with_credentials,
}
import support/nip46_client.{account_for}
import wisp
import wisp/simulate

/// `spec_nsec` の秘密鍵の 16 進。
const spec_key = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

/// 生成の確認ページの隠しフィールドの nsec。
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

/// ダッシュボードのアカウントの節には、ラベルが出る。
pub fn dashboard_shows_account_labels_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(
    body,
    "<p class=\"font-semibold break-words\">" <> label <> "</p>",
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
    "<p class=\"font-semibold break-words\">" <> escaped <> "</p>",
  )
  assert !string.contains(labelled, script)

  let failing = simulate.read_body(get(with_accounts(Error(script)), "/"))
  assert string.contains(
    failing,
    "<div class=\"alert\"><span><span lang=\"en\">"
      <> escaped
      <> "</span></span></div>",
  )
  assert !string.contains(failing, script)
}

/// アカウントが 1 件も無ければ、その旨を出す。
pub fn dashboard_shows_that_no_accounts_are_registered_test() {
  let body = simulate.read_body(get(with_accounts(Ok([])), "/"))
  assert string.contains(body, "No accounts registered.")
}

// --- アカウントの登録 ---

/// nsec とラベルの POST で登録し、完了ページに正規の nsec と npub を 1 回出す。
/// ラベルは前後の空白を除いて渡す。
pub fn import_registers_an_account_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", " work "),
    ])
  assert response.status == 200
  let body = simulate.read_body(response)
  let registered = account_for(spec_key)
  assert string.contains(body, spec_nsec)
  assert string.contains(body, account.npub(registered))
  assert process.receive(reports, 1000)
    == Ok(Added(account.pubkey_hex(registered), "work"))
}

/// 前後に空白を付けて大文字にした nsec でも、完了ページの nsec は小文字の正規の表記。
pub fn import_normalizes_the_nsec_test() {
  let sent = " " <> string.uppercase(spec_nsec) <> "\n"
  let body =
    simulate.read_body(
      post_form(context(), "/accounts/import", [
        #("nsec", sent),
        #("label", "work"),
      ]),
    )
  assert string.contains(body, spec_nsec)
  assert !string.contains(body, string.uppercase(spec_nsec))
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

/// 登録済みの鍵は 409 で、理由と、別のマスターキーの行についての案内と、
/// ダッシュボードへのリンクを出す。nsec は出さない。
pub fn import_rejects_a_registered_account_test() {
  let response =
    post_form(context(), "/accounts/import", [
      #("nsec", signer_nsec),
      #("label", "work"),
    ])
  assert response.status == 409
  let body = simulate.read_body(response)
  assert string.contains(body, "account is already registered")
  assert string.contains(body, "different master key")
  assert string.contains(
    body,
    "<a class=\"link\" href=\"/\">Back to dashboard</a>",
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
    #(string.repeat("a", 101), "label must be at most 100 characters"),
    #(
      "e" <> string.repeat("\u{0301}", 100),
      "label must be at most 100 characters",
    ),
    #("a\nb", "label must not contain control characters"),
    #("a\u{009B}b", "label must not contain control characters"),
  ]
  list.each(labels, fn(entry) {
    let #(sent, reason) = entry
    let response =
      post_form(reporting_context(reports), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", sent),
      ])
    assert response.status == 400
    assert string.contains(simulate.read_body(response), reason)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 空のラベル（欄が無い、空文字列、空白だけ）と、trim の前にだけある制御文字
/// （末尾の "\n"、U+0085 だけ）は、登録、生成した鍵の登録、ラベルの編集のどの経路
/// でも 400 になり、登録も更新もしない。
pub fn invalid_label_is_rejected_on_every_path_test() {
  let reports = process.new_subject()
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let cases = [
    #([], "label must not be empty"),
    #([#("label", "")], "label must not be empty"),
    #([#("label", "   ")], "label must not be empty"),
    #([#("label", "abc\n")], "label must not contain control characters"),
    #([#("label", "\u{0085}")], "label must not contain control characters"),
  ]
  list.each(cases, fn(entry) {
    let #(label_field, reason) = entry
    let import_response =
      post_form(reporting_context(reports), "/accounts/import", [
        #("nsec", spec_nsec),
        ..label_field
      ])
    assert import_response.status == 400
    assert string.contains(simulate.read_body(import_response), reason)

    let generated_response =
      post_form(reporting_context(reports), "/accounts/register-generated", [
        #("nsec", generated),
        ..label_field
      ])
    assert generated_response.status == 400
    assert string.contains(simulate.read_body(generated_response), reason)

    let edit_response =
      post_form(
        reporting_context(reports),
        action_path(dashboard.EditLabel),
        label_field,
      )
    assert edit_response.status == 400
    assert string.contains(simulate.read_body(edit_response), reason)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// ラベルの欄を持つフォームを再描画する 5 つの経路は、送られた値から制御文字を除き、
/// trim しない値を欄に入れる。理由はこれまでどおり欄より前の `role="alert"` の囲みに
/// 出し、欄に `input-error` と `aria-invalid` を付けない。送った nsec は反射しない。
pub fn invalid_input_keeps_the_label_on_every_path_test() {
  let broken = string.drop_end(spec_nsec, 1) <> "4"
  let generated =
    hidden_nsec(simulate.read_body(post(context(), "/accounts/generate")))
  let cases = [
    #(
      post_form(context(), "/accounts/import", [
        #("nsec", broken),
        #("label", "a\tb"),
      ]),
      400,
      "invalid bech32 checksum",
      "ab",
      Some(broken),
    ),
    #(
      post_form(context(), "/accounts/register-generated", [
        #("nsec", broken),
        #("label", " a\tb "),
      ]),
      400,
      "invalid bech32 checksum",
      " ab ",
      Some(broken),
    ),
    #(
      post_form(context(), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", " a\tb"),
      ]),
      400,
      "label must not contain control characters",
      " ab",
      Some(spec_nsec),
    ),
    #(
      post_form(context(), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", "   "),
      ]),
      400,
      "label must not be empty",
      "   ",
      Some(spec_nsec),
    ),
    #(
      post_form(context(), "/accounts/register-generated", [
        #("nsec", generated),
        #("label", "a\u{0085}b "),
      ]),
      400,
      "label must not contain control characters",
      "ab ",
      None,
    ),
    #(
      post_form(context(), "/accounts/import", [
        #("nsec", signer_nsec),
        #("label", " work "),
      ]),
      409,
      "account is already registered",
      " work ",
      Some(signer_nsec),
    ),
    #(
      post_form(context(), action_path(dashboard.EditLabel), [
        #("label", " a\nb "),
      ]),
      400,
      "label must not contain control characters",
      " ab ",
      None,
    ),
    #(
      post_form(
        failing_context(bunker.NotApplied("account is not registered")),
        action_path(dashboard.EditLabel),
        [#("label", " new ")],
      ),
      409,
      "account is not registered",
      " new ",
      None,
    ),
  ]
  use #(response, status, reason, field_value, sent_nsec) <- list.each(cases)
  assert response.status == status
  let body = simulate.read_body(response)
  assert string.contains(body, reason)
  assert string.contains(
    body,
    "name=\"label\" required type=\"text\" value=\"" <> field_value <> "\"",
  )
  let assert Ok(#(_before, after_alert)) =
    string.split_once(
      body,
      "<div class=\"alert alert-error\" role=\"alert\"><span>",
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
  assert response.status == 200
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

/// 完了ページのラベルはエスケープして出す。
pub fn registered_page_escapes_the_label_test() {
  let body =
    simulate.read_body(
      post_form(context(), "/accounts/import", [
        #("nsec", spec_nsec),
        #("label", "<script>x</script>"),
      ]),
    )
  assert string.contains(body, "&lt;script&gt;x&lt;/script&gt;")
  assert !string.contains(body, "<script>x</script>")
}

/// 鍵の生成は登録せず、確認ページの隠しフィールドに有効な nsec を入れて、生成した鍵の
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

/// 確認ページの nsec とラベルで生成した鍵を登録すると、nsec を描画せずに
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
/// 確認ページを理由付きで返す。状態コードは nsec 入力による登録と同じで、ラベルの欄には
/// 送られた値を入れる。
pub fn register_generated_bunker_failure_keeps_the_key_test() {
  let path = "/accounts/register-generated"
  let label = " work "
  let cases = [
    #(
      context(),
      signer_nsec,
      409,
      "<div class=\"alert alert-error\" role=\"alert\"><span><span lang=\"en\">account is already registered</span></span></div>",
    ),
    #(
      failing_context(bunker.NotReady("accounts are not loaded yet")),
      spec_nsec,
      503,
      "<div class=\"alert alert-warning\" role=\"alert\"><span>The key was not registered because accounts are not available right now. Wait a moment, then press &quot;Register this key&quot; again. <span lang=\"en\">accounts are not loaded yet</span></span></div>",
    ),
    #(
      failing_context(bunker.MaybeApplied(bunker.StoreDidNotConfirm)),
      spec_nsec,
      202,
      "<div class=\"alert alert-warning\" role=\"alert\"><span>The registration was not confirmed. Back up this key, then press &quot;Register this key&quot; again: it is registered if it was not, or &quot;account is already registered&quot; is shown if it was. the store did not confirm the change; it may have been applied</span></div>",
    ),
  ]
  use #(ctx, nsec, status, alert) <- list.each(cases)
  let response = post_form(ctx, path, [#("nsec", nsec), #("label", label)])
  assert response.status == status
  let body = simulate.read_body(response)
  assert hidden_nsec(body) == nsec
  assert string.contains(body, "action=\"/accounts/register-generated\"")
  assert string.contains(body, alert)
  assert string.contains(
    body,
    "name=\"label\" required type=\"text\" value=\" work \"",
  )
  assert header(response, "cache-control") == "no-store"
}

/// 生成した鍵の登録でラベルだけが規則に反すると、生成した鍵を失わないよう、送られた
/// nsec の確認ページを理由付きで 400 で返す。登録はせず、ラベルの欄には制御文字を除いた
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
    "<div class=\"alert alert-error\" role=\"alert\"><span>label must not contain control characters</span></div>",
  )
  assert string.contains(body, "value=\"ab\"")
  assert !string.contains(body, "a\tb")
  assert header(response, "cache-control") == "no-store"
  assert process.receive(reports, 100) == Error(Nil)
}

/// 生成した鍵の登録で nsec が不正なら、ラベルの不正を問わず登録画面を 400 で返す。
pub fn register_generated_with_an_invalid_nsec_returns_to_the_registration_page_test() {
  let response =
    post_form(context(), "/accounts/register-generated", [
      #("nsec", "nsec1invalid"),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "action=\"/accounts/import\"")
  assert !string.contains(body, "action=\"/accounts/register-generated\"")
}

/// nsec 入力による登録でラベルが規則に反すると、登録画面を返し、nsec を出さない。
pub fn import_with_an_invalid_label_does_not_echo_the_nsec_test() {
  let response =
    post_form(context(), "/accounts/import", [
      #("nsec", spec_nsec),
      #("label", "a\tb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "action=\"/accounts/import\"")
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

/// 登録画面の nsec のフォームと欄は伏せ字で、パスワードとして保存させない。
pub fn new_account_form_does_not_save_the_nsec_as_a_password_test() {
  let response = get(context(), "/accounts/new")
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "<input autocomplete=\"new-password\" class=\"input w-full font-mono border-base-content/60\" name=\"nsec\" required type=\"password\">",
  )
  assert string.contains(
    body,
    "<form action=\""
      <> view.segments_path(dashboard.import_account_segments)
      <> "\" autocomplete=\"off\"",
  )
}

// --- 秘密鍵の再表示 ---

/// 再表示のページはパスワードを求めるだけで、nsec を問い合わせない。
pub fn reveal_page_asks_for_the_password_test() {
  let reports = process.new_subject()
  let response =
    get(reporting_context(reports), action_path(dashboard.RevealPrivateKey))
  assert response.status == 200
  let body = simulate.read_body(response)
  assert string.contains(
    body,
    "<input autocomplete=\"off\" class=\"input w-full font-mono border-base-content/60\" name=\"password\" required type=\"password\">",
  )
  assert !string.contains(body, signer_nsec)
  assert process.receive(reports, 100) == Error(Nil)
}

/// パスワードが違えば 403 で、nsec もパスワードも出さず、nsec を問い合わせない。
/// Basic 認証の入力を促すヘッダーも付けない。
pub fn reveal_with_a_wrong_password_is_forbidden_test() {
  let reports = process.new_subject()
  let response =
    post_form(
      reporting_context(reports),
      action_path(dashboard.RevealPrivateKey),
      [#("password", "wrong-guess")],
    )
  assert response.status == 403
  let body = simulate.read_body(response)
  assert string.contains(body, "incorrect password")
  assert !string.contains(body, signer_nsec)
  assert !string.contains(body, "wrong-guess")
  assert list.key_find(response.headers, "www-authenticate") == Error(Nil)
  assert process.receive(reports, 100) == Error(Nil)
}

/// 正しいパスワードなら、一覧の署名者の nsec を問い合わせて表示する。
pub fn reveal_with_the_password_shows_the_nsec_test() {
  let reports = process.new_subject()
  let response =
    post_form(
      reporting_context(reports),
      action_path(dashboard.RevealPrivateKey),
      [#("password", password)],
    )
  assert response.status == 200
  assert string.contains(simulate.read_body(response), signer_nsec)
  assert process.receive(reports, 1000) == Ok(NsecRequested(signer))
}

/// nsec の問い合わせが失敗したら 503 の通知ページにする。
pub fn reveal_failure_is_unavailable_test() {
  let failing =
    admin.Context(..context(), nsec: fn(_signer) {
      Error("accounts are not loaded yet")
    })
  let response =
    post_form(failing, action_path(dashboard.RevealPrivateKey), [
      #("password", password),
    ])
  assert response.status == 503
  let body = simulate.read_body(response)
  assert string.contains(body, "accounts are not loaded yet")
  assert string.contains(body, "Back to dashboard")
}

/// 一覧に無い署名者は GET も POST も 404 で、パスの値を応答に含めず、何も呼ばない。
pub fn reveal_for_an_unknown_signer_is_not_found_test() {
  let reports = process.new_subject()
  let path = "/accounts/%3Cscript%3Eunknown/private-key"
  let responses = [
    get(reporting_context(reports), path),
    post_form(reporting_context(reports), path, [#("password", password)]),
  ]
  list.each(responses, fn(response) {
    assert response.status == 404
    assert !string.contains(simulate.read_body(response), "%3Cscript%3Eunknown")
  })
  assert process.receive(reports, 100) == Error(Nil)
}

// --- 削除、secret の作り直し、ラベル ---

/// 削除のページは、鍵を失うことを伝え、エスケープしたラベルと npub を出す。
pub fn delete_page_warns_about_losing_the_key_test() {
  let labelled = with_accounts(Ok([account_row("<b>x</b>")]))
  let body =
    simulate.read_body(get(labelled, action_path(dashboard.DeleteAccount)))
  assert string.contains(body, signer_npub)
  assert string.contains(body, "&lt;b&gt;x&lt;/b&gt;")
  assert string.contains(body, "the account is lost")
  assert string.contains(body, "action=\"/accounts/" <> signer <> "/delete\"")
}

/// 削除の POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn delete_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post(reporting_context(reports), action_path(dashboard.DeleteAccount))
  assert response.status == 303
  assert header(response, "location") == "/"
  assert process.receive(reports, 1000) == Ok(Removed(signer))
}

/// secret の作り直しのページは、古い URI での新規の接続が拒否され、承認済みの
/// セッションが残ることを伝える。
pub fn rotate_page_explains_the_effect_test() {
  let body =
    simulate.read_body(get(context(), action_path(dashboard.RotateSecret)))
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
    post(reporting_context(reports), action_path(dashboard.RotateSecret))
  assert response.status == 303
  assert process.receive(reports, 1000) == Ok(Rotated(signer))
}

/// ラベルの POST は Context を呼び、ダッシュボードへ 303 で戻す。
pub fn label_update_calls_the_context_and_redirects_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), action_path(dashboard.EditLabel), [
      #("label", "new"),
    ])
  assert response.status == 303
  assert process.receive(reports, 1000) == Ok(Relabeled(signer, "new"))
}

/// 規則に反するラベルは 400 で、編集の欄には送られた値から制御文字を除いた値を入れ、
/// Context を呼ばない。
pub fn label_update_rejects_an_invalid_label_test() {
  let reports = process.new_subject()
  let response =
    post_form(reporting_context(reports), action_path(dashboard.EditLabel), [
      #("label", "a\nb"),
    ])
  assert response.status == 400
  let body = simulate.read_body(response)
  assert string.contains(body, "label must not contain control characters")
  assert string.contains(body, "value=\"ab\"")
  assert process.receive(reports, 100) == Error(Nil)
}

/// 編集のページを再描画しても、カードの上の要約は保存済みのラベルのまま。
pub fn edit_page_keeps_the_saved_label_in_the_summary_test() {
  let saved = "<dd class=\"break-words\">" <> label <> "</dd>"
  let invalid_input =
    simulate.read_body(
      post_form(context(), action_path(dashboard.EditLabel), [
        #("label", "a\nb"),
      ]),
    )
  assert string.contains(invalid_input, saved)
  let conflict =
    simulate.read_body(
      post_form(
        failing_context(bunker.NotApplied("account is not registered")),
        action_path(dashboard.EditLabel),
        [#("label", "new")],
      ),
    )
  assert string.contains(conflict, saved)
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

/// 3 つのラベルの欄には `maxlength` が無く、欄の下に表示の言語の上限の案内がある。
pub fn label_inputs_describe_the_limit_without_maxlength_test() {
  let hint = fn(language) {
    "<p class=\"text-base-content/70\" id=\"label-hint\">"
    <> i18n.text(language, i18n.LabelHint(max: dashboard.max_label_code_points))
    <> "</p>"
  }
  let bodies = [
    simulate.read_body(get(context(), "/accounts/new")),
    simulate.read_body(post(context(), "/accounts/generate")),
    simulate.read_body(get(context(), action_path(dashboard.EditLabel))),
  ]
  list.each(bodies, fn(body) {
    assert !string.contains(body, "maxlength")
    assert string.contains(
      body,
      "aria-describedby=\"label-hint\" aria-label=\"Label\" autocomplete=\"off\"",
    )
    assert string.contains(body, hint(i18n.English))
  })

  let japanese_request =
    simulate.request(http.Get, "/accounts/new")
    |> in_japanese
    |> with_credentials("admin", password)
  let japanese_body =
    simulate.read_body(admin.handle_request(context(), japanese_request))
  assert string.contains(
    japanese_body,
    "aria-describedby=\"label-hint\" aria-label=\"ラベル\" autocomplete=\"off\"",
  )
  assert string.contains(japanese_body, hint(i18n.Japanese))
}

/// 登録画面、生成した鍵の確認、ラベルの編集の 3 つの欄はどれも必須。
pub fn label_inputs_are_required_test() {
  let new = simulate.read_body(get(context(), "/accounts/new"))
  assert string.contains(new, "name=\"label\" required type=\"text\"")
  let generated = simulate.read_body(post(context(), "/accounts/generate"))
  assert string.contains(generated, "name=\"label\" required type=\"text\"")
  let edit =
    simulate.read_body(get(context(), action_path(dashboard.EditLabel)))
  assert string.contains(edit, "name=\"label\" required type=\"text\"")
}

/// 削除、secret の作り直し、ラベルの POST の失敗は、反映されていなければ 409、
/// 受け付けられなければ 503、反映されたか分からなければ 202 になり、理由と
/// ダッシュボードへのリンクを出す。
pub fn account_change_failures_map_to_status_codes_test() {
  let not_applied_reason = "account is not registered"
  let not_ready_reason = "accounts are not loaded yet"
  let failures = [
    #(bunker.NotApplied(not_applied_reason), 409, not_applied_reason),
    #(bunker.NotReady(not_ready_reason), 503, not_ready_reason),
    #(
      bunker.MaybeApplied(bunker.StoreDidNotConfirm),
      202,
      i18n.text(i18n.English, i18n.StoreDidNotConfirm),
    ),
  ]
  let changes = [
    #(dashboard.DeleteAccount, []),
    #(dashboard.RotateSecret, []),
    #(dashboard.EditLabel, [#("label", "new")]),
  ]
  use #(failure, status, reason) <- list.each(failures)
  use #(action, fields) <- list.each(changes)
  let response =
    post_form(failing_context(failure), action_path(action), fields)
  assert #(action, response.status) == #(action, status)
  let body = simulate.read_body(response)
  assert string.contains(body, reason)
  assert string.contains(
    body,
    "<a class=\"link\" href=\"/\">Back to dashboard</a>",
  )
}

/// 一覧に無い署名者（削除済みなど）への削除、secret の作り直し、ラベルの POST は 404 で、
/// Context の変更を呼ばない。反映済みの削除を再送した場合もこの経路になる。
pub fn changes_to_an_unlisted_signer_are_not_found_test() {
  let reports = process.new_subject()
  let emptied =
    admin.Context(..reporting_context(reports), accounts: fn() { Ok([]) })
  let changes = [
    #(dashboard.DeleteAccount, []),
    #(dashboard.RotateSecret, []),
    #(dashboard.EditLabel, [#("label", "new")]),
  ]
  list.each(changes, fn(entry) {
    let #(action, fields) = entry
    let response = post_form(emptied, action_path(action), fields)
    assert #(action, response.status) == #(action, 404)
  })
  assert process.receive(reports, 100) == Error(Nil)
}

/// 知らない操作のセグメントは 404。
pub fn unknown_account_action_is_not_found_test() {
  assert get(context(), "/accounts/" <> signer <> "/nope").status == 404
  assert post(context(), "/accounts/" <> signer <> "/nope").status == 404
}

/// 一覧に無い署名者への操作の GET は 404 の HTML で、理由を出し、署名者を含めない。
pub fn unlisted_signer_is_not_found_page_test() {
  let response = get(with_accounts(Ok([])), action_path(dashboard.EditLabel))
  assert response.status == 404
  let body = simulate.read_body(response)
  assert header(response, "content-type") == "text/html; charset=utf-8"
  assert string.contains(body, i18n.text(i18n.English, i18n.AccountNotFound))
  assert !string.contains(body, signer)
}

/// アカウントの一覧を得られなければ、操作の GET と POST は 503 で理由を出す。
pub fn account_pages_need_the_account_list_test() {
  let failing = with_accounts(Error(unavailable))
  let responses =
    list.append(
      list.map(account_actions.all, fn(action) {
        get(failing, action_path(action))
      }),
      [post(failing, action_path(dashboard.DeleteAccount))],
    )
  list.each(responses, fn(response) {
    assert response.status == 503
    let body = simulate.read_body(response)
    assert string.contains(body, unavailable)
    assert string.contains(body, "Back to dashboard")
  })
}

// --- ダッシュボードのアカウントの節 ---

/// アカウントの節には、npub、読み取り専用の欄の URI、4 つの操作のリンク、登録の
/// リンクが出る。
pub fn dashboard_lists_account_actions_test() {
  let body = simulate.read_body(get(context(), "/"))
  assert string.contains(body, signer_npub)
  assert string.contains(
    body,
    "<input aria-label=\"Connection URI\" class=\"input join-item w-full min-w-0 font-mono text-xs border-base-content/60\" readonly type=\"text\" value=\""
      <> wisp.escape_html(uri)
      <> "\">",
  )
  assert string.contains(body, "href=\"/accounts/new\"")
  list.each(account_actions.all, fn(action) {
    assert string.contains(body, "href=\"" <> action_path(action) <> "\"")
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

/// 一覧を得られないときは登録のリンクを出さない。
pub fn dashboard_hides_add_account_without_accounts_test() {
  let failing = simulate.read_body(get(with_accounts(Error(unavailable)), "/"))
  assert !string.contains(failing, "Add account")
  let empty = simulate.read_body(get(with_accounts(Ok([])), "/"))
  assert string.contains(empty, "Add account")
}
