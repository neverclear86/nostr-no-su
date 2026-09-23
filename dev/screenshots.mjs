// 管理 UI の全ページを、固定状態のサーバー（dev/admin_preview.gleam）から撮る。
// 広い画面（1280px）と狭い画面（375px、2 倍の解像度）の、ライトとダーク
// （prefers-color-scheme のエミュレーション）で、ページ全体を撮る。
// ダイアログを開いた画面は、開いている間だけ画面の高さを 1200px 以上にして撮る（.modal-box の高さは画面の高さまで）。
// 使い方: PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots [locale]
//        PREVIEW_PORT=18461 node dev/screenshots.mjs --readme docs/images/usage [locale]
//        PREVIEW_PORT=18461 node dev/screenshots.mjs --usage docs/images/usage [locale]
// --readme のときは readme 印のある画面だけを 1280px・ライトで撮り、出力名を <readme>-<en|ja>.png にする。
// --usage のときは usage の要素だけを 1280px・ライトで切り出して撮り、出力名を <name>.png にする。
// そのとき、承認待ちと読み込めなかった行を除くダッシュボードの切り出し、ダイアログ、event_logger と profile のページは PREVIEW_PORT + 3 の状態から撮る。
// 撮影用のサーバー（PREVIEW_PORT=18461 gleam run -m admin_preview）は終了しないので、別の端末で先に起動しておく。
// 初回は npx playwright-core install chromium で、playwright-core の版が使う chromium を入れる。
// locale（ja-JP など）を渡すと、ブラウザーがその言語の Accept-Language を送り、管理 UI はその言語で出す。
// 渡さなければ Accept-Language を送らず、管理 UI は既定の英語で出す。
// 出力先をリポジトリの中にするときは、.gitignore と .dockerignore が除く build/ の下にする（--readme の docs/images/usage/ だけは例外で、撮り直した画像をコミットする）。
// CHROMIUM に chromium の実行ファイルを渡すと、playwright-core が既定で探すものの代わりに使う。
// 応答の状態コードが画面ごとの期待値と違うか、応答が HTML でない画面があれば、撮り終えた後にその一覧を出して
// 終了コード 1 で終える。
// テーマと言語の POST はコンテキストに cookie を残すので、以降の撮影に影響しないよう末尾に置き、
// 最後に system（cookie を消す）を送る。
// copy: "manual" は navigator.clipboard を消してから押す。
import { chromium } from "playwright-core";
import { mkdirSync } from "node:fs";

const readmeMode = process.argv[2] === "--readme";
const usageMode = process.argv[2] === "--usage";
const named = readmeMode || usageMode;
const out = named ? process.argv[3] : process.argv[2];
// --usage の出力名は言語の接尾辞を持たないので、locale を省略したときは日本語に倒す。
const locale = named
  ? (process.argv[4] ?? (usageMode ? "ja-JP" : undefined))
  : process.argv[3];
if (!out) {
  console.error(
    "usage: node dev/screenshots.mjs [--readme|--usage] <output directory> [locale]",
  );
  process.exit(2);
}
mkdirSync(out, { recursive: true });

const port = Number(process.env.PREVIEW_PORT ?? "18461");
const password = "preview-password";
const base = `http://127.0.0.1:${port}`;
const unavailable = `http://127.0.0.1:${port + 1}`;
const empty = `http://127.0.0.1:${port + 2}`;
const readmeBase = `http://127.0.0.1:${port + 3}`;
const partlySetUp = `http://127.0.0.1:${port + 4}`;
const signer = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";
const declaredClient = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222";
const undeclaredClient = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111";
const signerNsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re";
const specNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5";
// 確認のページの場面に送る URI。クライアントの公開鍵は NIP-19 の仕様の値で、secret はダミー。
const connectUri =
  "nostrconnect://7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e?relay=wss%3A%2F%2Frelay.example&secret=preview-secret";
const account = (action) => `${base}/accounts/${signer}/${action}`;
const unreadablePubkey = "dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444";
const unreadableAccount = (action) => `${base}/accounts/${unreadablePubkey}/${action}`;

// --readme と --usage のときは文書に載せる組だけを撮るので、広い画面とライトに絞る。
const viewports = named
  ? [{ name: "w1280", width: 1280, height: 800, deviceScaleFactor: 1 }]
  : [
      { name: "w1280", width: 1280, height: 800, deviceScaleFactor: 1 },
      { name: "w375", width: 375, height: 812, deviceScaleFactor: 2 },
    ];
const colorSchemes = named ? ["light"] : ["light", "dark"];

// 撮る画面。form を持つものは POST で開く。status は応答の状態コードの期待値で、無ければ 200。
// mask は乱数で変わる値を伏せる。copy を持つものは、開いた後に最初のコピーのボタンを押してから撮る。
// keys は、開いた後に順に押すキーの配列。
// open は、開いた後に open = true にして開く <details> のセレクター。
// dialog は、open の後に押して開くダイアログの id（トリガーは button[commandfor=id][command=show-modal]）。
// readme は --readme のときの出力名（<readme>-<en|ja>.png）で、印の無い画面は --readme では撮らない。
const shots = [
  { name: "01-dashboard", url: `${base}/` },
  { name: "02-dashboard-empty", url: `${empty}/` },
  { name: "03-dashboard-accounts-unavailable", url: `${unavailable}/` },
  { name: "04-approve-page", url: `${base}/approve/tok-1` },
  { name: "05-approved", url: `${base}/approve/tok-1`, form: {} },
  { name: "06-denied", url: `${base}/deny/tok-1`, form: {} },
  { name: "07-decision-not-found", url: `${base}/approve/unknown`, form: {}, status: 404 },
  { name: "09-import-invalid-nsec", url: `${base}/accounts/import`, form: { nsec: "nsec1invalid", label: "x" }, status: 400 },
  { name: "10-import-duplicate", url: `${base}/accounts/import`, form: { nsec: signerNsec, label: "dup" }, status: 409 },
  { name: "12-generated", url: `${base}/accounts/generate`, form: {}, mask: "input[readonly]" },
  { name: "13-generated-invalid-label", url: `${base}/accounts/register-generated`, form: { nsec: specNsec, label: "a\tb" }, status: 400 },
  { name: "14-edit-label", url: `${base}/`, open: "#accounts li:first-child > details", dialog: `dialog-account-${signer}-label` },
  { name: "15-edit-label-invalid", url: account("label"), form: { label: "a\nb" }, status: 400 },
  { name: "16-edit-label-not-applied", url: account("label"), form: { label: "not-applied" }, status: 409 },
  { name: "17-change-not-confirmed", url: account("label"), form: { label: "maybe" }, status: 202 },
  { name: "18-accounts-not-ready", url: account("label"), form: { label: "not-ready" }, status: 503 },
  { name: "18b-connection-qr", url: `${base}/`, dialog: `dialog-account-${signer}-qr` },
  { name: "19-rotate-confirm", url: `${base}/`, open: "#accounts li:first-child > details", dialog: `dialog-account-${signer}-rotate` },
  { name: "20-delete-confirm", url: `${base}/`, open: "#accounts li:first-child > details", dialog: `dialog-account-${signer}-delete` },
  { name: "21-private-key-form", url: `${base}/`, open: "#accounts li:first-child > details", dialog: `dialog-account-${signer}-private-key` },
  { name: "22-private-key-wrong-password", url: account("private-key"), form: { password: "wrong" }, status: 403 },
  { name: "23-private-key", url: account("private-key"), form: { password } },
  { name: "24-account-page-unavailable", url: `${unavailable}/accounts/${signer}/label`, form: { label: "x" }, status: 503 },
  { name: "25-delete-not-applied", url: account("delete"), form: {}, status: 409 },
  { name: "25b-unreadable-delete-not-applied", url: unreadableAccount("delete"), form: {}, status: 409 },
  { name: "26-dashboard-copied", url: `${base}/`, copy: true },
  { name: "27-revoke-not-found", url: `${base}/sessions/revoke`, form: { signer, client: "not-approved" }, status: 404 },
  { name: "27b-revoke-not-applied", url: `${base}/sessions/revoke`, form: { signer, client: "not-applied" }, status: 409 },
  { name: "28-revoke-not-answered", url: `${base}/sessions/revoke`, form: { signer, client: "no-answer" }, status: 503 },
  { name: "28b-approve-page-pending-unavailable", url: `${unavailable}/approve/tok-1`, status: 503 },
  { name: "29-reenable-not-found", url: `${base}/plugins/reenable`, form: { name: "missing" }, status: 404 },
  { name: "30-reenable-not-answered", url: `${base}/plugins/reenable`, form: { name: "no-answer" }, status: 503 },
  { name: "33-switch-pressed-focus", url: `${base}/`, keys: ["Tab", "Tab"] },
  { name: "34-switch-focus", url: `${base}/`, keys: ["Tab", "Tab", "Tab"] },
  { name: "36-theme-dark", url: `${base}/theme`, form: { theme: "dark", return: "/" } },
  { name: "37-theme-light", url: `${base}/theme`, form: { theme: "light", return: "/" } },
  { name: "38-theme-system", url: `${base}/theme`, form: { theme: "system", return: "/" } },
  { name: "39-dashboard-copy-selected", url: `${base}/`, copy: "manual" },
  { name: "40-language-ja", url: `${base}/language`, form: { language: "ja", return: "/" } },
  { name: "41-language-system", url: `${base}/language`, form: { language: "system", return: "/" } },
  { name: "42-import-empty-label", url: `${base}/accounts/import`, form: { nsec: specNsec, label: "" }, status: 400 },
  { name: "43-edit-label-empty", url: account("label"), form: { label: "" }, status: 400 },
  { name: "44-generated-not-applied", url: `${base}/accounts/register-generated`, form: { nsec: signerNsec, label: "work" }, status: 409 },
  { name: "45-generated-not-ready", url: `${base}/accounts/register-generated`, form: { nsec: specNsec, label: "not-ready" }, status: 503 },
  { name: "46-generated-not-confirmed", url: `${base}/accounts/register-generated`, form: { nsec: specNsec, label: "maybe" }, status: 202 },
  { name: "48-add-relay-invalid-url", url: `${base}/relays/new`, form: { url: "https://relay.example", monitor: "on" }, status: 400 },
  { name: "49-add-relay-role-required", url: `${base}/relays/new`, form: { url: "wss://relay.example" }, status: 400 },
  { name: "50-add-relay-duplicate", url: `${base}/relays/new`, form: { url: "wss://duplicate.example", monitor: "on" }, status: 409 },
  { name: "51-add-relay-not-saved", url: `${base}/relays/new`, form: { url: "wss://not-saved.example", monitor: "on" }, status: 409 },
  { name: "52-add-relay-maybe", url: `${base}/relays/new`, form: { url: "wss://maybe.example", monitor: "on" }, status: 202 },
  { name: "53-add-relay-unconfirmed", url: `${base}/relays/new`, form: { url: "wss://unconfirmed.example", monitor: "on" }, status: 202 },
  { name: "55-edit-relay-role-required", url: `${base}/relays/1/edit`, form: {}, status: 400 },
  { name: "56-edit-relay-not-saved", url: `${base}/relays/2/edit`, form: { monitor: "on" }, status: 409 },
  { name: "58-delete-relay-not-saved", url: `${base}/relays/2/delete`, form: {}, status: 409 },
  { name: "59-delete-relay-unconfirmed", url: `${base}/relays/3/delete`, form: {}, status: 202 },
  { name: "60-relay-not-found", url: `${base}/relays/99/delete`, form: {}, status: 404 },
  { name: "61-connect-client", url: `${base}/sessions/connect` },
  { name: "62-connect-client-empty", url: `${empty}/sessions/connect` },
  { name: "63-connect-client-accounts-unavailable", url: `${unavailable}/sessions/connect` },
  { name: "64-connect-client-invalid-uri", url: `${base}/sessions/connect`, form: { uri: "not-a-uri", signer }, status: 400 },
  {
    name: "64b-connect-review",
    url: `${base}/sessions/connect`,
    form: {
      uri: `${connectUri}&relay=ws%3A%2F%2Frelay.example.net&relay=wss%3A%2F%2Fnos.example&perms=sign_event%3A1%2Cnip44_encrypt&name=Example%20Client`,
      signer,
    },
  },
  { name: "64c-connect-review-unnamed", url: `${base}/sessions/connect`, form: { uri: connectUri, signer } },
  { name: "64d-connect-review-not-connected", url: `${base}/sessions/connect/confirm`, form: { uri: connectUri, signer }, status: 503 },
  { name: "65-plugin-page", url: `${base}/plugins/console_logger/status` },
  { name: "66-plugin-page-disabled", url: `${base}/plugins/broken/status` },
  { name: "67-plugin-page-not-found", url: `${base}/plugins/console_logger/nope`, status: 404 },
  { name: "68-plugin-page-unavailable", url: `${base}/plugins/slow/status`, status: 503 },
  { name: "69-session-permissions", url: `${base}/sessions/${signer}/${declaredClient}/permissions` },
  { name: "70-session-permissions-not-declared", url: `${base}/sessions/${signer}/${undeclaredClient}/permissions` },
  { name: "71-session-permissions-not-applied", url: `${base}/sessions/${signer}/${undeclaredClient}/permissions`, form: { sign_event: "on" }, status: 409 },
  { name: "72-session-permissions-unavailable", url: `${unavailable}/sessions/${signer}/${declaredClient}/permissions` },
  { name: "73-readme-dashboard", url: `${readmeBase}/`, open: "#accounts li:first-child > details" },
  { name: "74-event-logger-timeline", url: `${readmeBase}/plugins/event_logger/timeline` },
  { name: "75-event-logger-settings", url: `${readmeBase}/plugins/event_logger/settings` },
  { name: "76-readme-dashboard-plain", url: `${readmeBase}/`, readme: "dashboard" },
  { name: "77-dashboard-getting-started-partly-set-up", url: `${partlySetUp}/` },
  { name: "78-dialog-account-new", url: `${readmeBase}/`, dialog: "dialog-account-new" },
  { name: "79-dialog-unreadable-delete", url: `${base}/`, dialog: `dialog-unreadable-${unreadablePubkey}-delete` },
  { name: "80-dialog-relay-delete", url: `${readmeBase}/`, dialog: "dialog-relay-1-delete" },
  { name: "81-dialog-session-connect", url: `${readmeBase}/`, dialog: "dialog-session-connect" },
  { name: "82-profile", url: `${readmeBase}/plugins/profile/profile` },
];

// --usage で撮る要素。selector は開いたページの中で 1 つの要素にだけ一致させる
// （一致しないか複数に一致すると strict で失敗する）。url、form、status、open、dialog は
// shots と同じ意味で、dialog を持つものは selector を省き、#<dialog> > .modal-box を切り出す。
// 出力名は <name>.png で、言語の接尾辞は付けない。
const usage = [
  { name: "overview", url: `${readmeBase}/`, selector: "main > nav" },
  { name: "navbar", url: `${readmeBase}/`, selector: "header" },
  { name: "relays", url: `${readmeBase}/`, selector: "#relays" },
  { name: "new-relay", url: `${readmeBase}/`, dialog: "dialog-relay-new" },
  { name: "edit-relay", url: `${readmeBase}/`, dialog: "dialog-relay-1-edit" },
  {
    name: "accounts",
    url: `${readmeBase}/`,
    selector: "#accounts",
    open: "#accounts li:first-child > details",
  },
  { name: "new-account", url: `${readmeBase}/`, dialog: "dialog-account-new" },
  { name: "pending", url: `${base}/`, selector: "#pending" },
  { name: "approve", url: `${base}/approve/tok-1`, selector: "main > section" },
  { name: "sessions", url: `${readmeBase}/`, selector: "#sessions" },
  {
    name: "session-permissions",
    url: `${readmeBase}/`,
    dialog: `dialog-session-${signer}-${declaredClient}-permissions`,
  },
  {
    name: "private-key-form",
    url: `${readmeBase}/`,
    open: "#accounts li:first-child > details",
    dialog: `dialog-account-${signer}-private-key`,
  },
  {
    name: "rotate",
    url: `${readmeBase}/`,
    open: "#accounts li:first-child > details",
    dialog: `dialog-account-${signer}-rotate`,
  },
  { name: "plugins", url: `${readmeBase}/`, selector: "#plugins" },
  {
    name: "event-logger-timeline",
    url: `${readmeBase}/plugins/event_logger/timeline`,
    selector: "main",
  },
  {
    name: "event-logger-settings",
    url: `${readmeBase}/plugins/event_logger/settings`,
    selector: "main > section.card:has(form)",
  },
  {
    name: "profile",
    url: `${readmeBase}/plugins/profile/profile`,
    selector: "main",
  },
  {
    name: "unreadable",
    url: `${base}/`,
    selector: "#accounts .alert-error",
  },
  {
    name: "not-confirmed",
    url: account("label"),
    form: { label: "maybe" },
    status: 202,
    selector: "main > section",
  },
];

// 画面を開いて応答を返す。POST は送信先と同じオリジンのページにフォームを作って送り
// （CSRF の検査を通り、ブラウザーの実際の遷移で表示される）、POST の応答（303 で戻す POST は、
// 戻り先の文書の応答）と、送信で開いた文書の load を待つ。waitForURL は今の URL と同じ URL への
// 送信では遷移を待たずに解決するので使わない。
async function open(page, shot) {
  if (!shot.form) return page.goto(shot.url);
  const origin = new URL(shot.url).origin;
  if (!page.url().startsWith(origin)) await page.goto(`${origin}/`);
  const [response] = await Promise.all([
    page.waitForResponse((r) => {
      const request = r.request();
      const posted = request.method() === "POST" || request.redirectedFrom()?.method() === "POST";
      return posted && (r.status() < 300 || r.status() >= 400);
    }),
    page.waitForEvent("load"),
    page.evaluate(
      ({ url, fields }) => {
        const form = document.createElement("form");
        form.method = "post";
        form.action = url;
        for (const [name, value] of Object.entries(fields)) {
          const input = document.createElement("input");
          input.type = "hidden";
          input.name = name;
          input.value = value;
          form.append(input);
        }
        document.body.append(form);
        form.submit();
      },
      { url: shot.url, fields: shot.form },
    ),
  ]);
  return response;
}

// 撮る前の操作。押すキーを送り、open の <details> を開き、dialog のトリガーを押して開くまで待つ。
async function prepare(page, shot) {
  for (const key of shot.keys ?? []) {
    await page.keyboard.press(key);
  }
  if (shot.open) {
    await page.locator(shot.open).evaluate((el) => {
      el.open = true;
    });
  }
  if (shot.dialog) {
    const size = page.viewportSize();
    await page.setViewportSize({
      width: size.width,
      height: Math.max(size.height, 1200),
    });
    await page
      .locator(`button[commandfor="${shot.dialog}"][command="show-modal"]`)
      .click();
    await page.locator(`dialog#${shot.dialog}[open]`).waitFor();
  }
}

// 最初のコピーのボタンを押し、コピーの欄の囲みに data-copied（manual なら data-selected）が
// 付いたかを返す。manual なら押す前に navigator.clipboard を消し、書けない状態を再現する。
// 付いた表示は 2 秒で消える（data-selected は消えない）ので、付いたらすぐに撮る。
async function copy(page, manual) {
  if (manual) {
    await page.evaluate(() => {
      Object.defineProperty(navigator, "clipboard", { value: undefined });
    });
  }
  await page.locator('button[data-action="copy"]').first().click();
  const attribute = manual ? "data-selected" : "data-copied";
  return page
    .locator(`[${attribute}]`)
    .first()
    .waitFor({ timeout: 1000 })
    .then(() => true, () => false);
}

// --readme のときは readme の出力名を持つ画面だけ、--usage のときは usage の要素を撮る。
const wanted = usageMode
  ? usage
  : readmeMode
    ? shots.filter((shot) => shot.readme)
    : shots;
// README の画像の言語の接尾辞。locale を指定しなければ英語。
const lang = locale?.startsWith("ja") ? "ja" : "en";
// 画面の応答の content-type が始まるべき値。
const htmlType = "text/html";
// 期待と違った画面の、最後に stderr へ出す行。
const unexpected = [];
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM, headless: true });
try {
  for (const viewport of viewports) {
    for (const colorScheme of colorSchemes) {
      const context = await browser.newContext({
        httpCredentials: { username: "admin", password },
        viewport: { width: viewport.width, height: viewport.height },
        deviceScaleFactor: viewport.deviceScaleFactor,
        colorScheme,
        locale,
        // コピーのボタンが navigator.clipboard に書けるようにする。
        permissions: ["clipboard-read", "clipboard-write"],
      });
      const page = await context.newPage();
      for (const shot of wanted) {
        const response = await open(page, shot);
        await prepare(page, shot);
        const copyLabel = shot.copy === "manual" ? "selected" : "copied";
        const copied = shot.copy
          ? ` ${copyLabel}=${await copy(page, shot.copy === "manual")}`
          : "";
        const file = usageMode
          ? `${out}/${shot.name}.png`
          : readmeMode
            ? `${out}/${shot.readme}-${lang}.png`
            : `${out}/${shot.name}-${viewport.name}-${colorScheme}.png`;
        const mask = shot.mask ? [page.locator(shot.mask)] : [];
        // animations: "disabled" は、ボタンの色の遷移を終わった状態にしてから撮る。
        // selector を持つものは、その要素だけを切り出して撮る。
        const selector =
          shot.selector ??
          (usageMode && shot.dialog ? `#${shot.dialog} > .modal-box` : undefined);
        if (selector) {
          await page
            .locator(selector)
            .screenshot({ path: file, mask, animations: "disabled" });
        } else {
          await page.screenshot({
            path: file,
            fullPage: true,
            mask,
            animations: "disabled",
          });
        }
        if (shot.dialog) {
          // ダイアログの中身が .modal-box の高さを超えてスクロールしていれば、切り出しから欠ける。
          const clipped = await page
            .locator(`#${shot.dialog} > .modal-box`)
            .evaluate((el) => el.scrollHeight > el.clientHeight);
          if (clipped) unexpected.push(`clipped dialog ${file}`);
          await page.setViewportSize({
            width: viewport.width,
            height: viewport.height,
          });
        }
        const status = response.status();
        const type = response.headers()["content-type"] ?? "";
        const expected = shot.status ?? 200;
        console.log(`${status} ${file}${copied}`);
        // ルートに当たらないパスの 404 は wisp の text/plain なので、HTML であることも比べて
        // 画面の 404 と区別する。
        if (status !== expected || !type.startsWith(htmlType)) {
          unexpected.push(`${status} ${type} (expected ${expected} ${htmlType}) ${file}`);
        }
      }
      await context.close();
    }
  }
} finally {
  await browser.close();
}
// 期待と違う応答は、パスの変更などで意図と違う画面を撮った可能性がある。process.exit は
// パイプへの書き込みを終える前にプロセスを終えることがあるので、終了コードだけを決めて自然に終える。
if (unexpected.length > 0) {
  console.error(`unexpected response:\n${unexpected.join("\n")}`);
  process.exitCode = 1;
}
