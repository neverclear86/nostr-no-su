// 管理 UI の全ページを、固定状態のサーバー（dev/admin_preview.gleam）から撮る。
// 広い画面（1280px）と狭い画面（375px、2 倍の解像度）の、ライトとダーク
// （prefers-color-scheme のエミュレーション）で、ページ全体を撮る。
// 使い方: PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots [locale]
// 撮影用のサーバー（PREVIEW_PORT=18461 gleam run -m admin_preview）は終了しないので、別の端末で先に起動しておく。
// 初回は npx playwright-core install chromium で、playwright-core の版が使う chromium を入れる。
// locale（ja-JP など）を渡すと、ブラウザーがその言語の Accept-Language を送り、管理 UI はその言語で出す。
// 渡さなければ Accept-Language を送らず、管理 UI は既定の英語で出す。
// 出力先をリポジトリの中にするときは、.gitignore と .dockerignore が除く build/ の下にする。
// CHROMIUM に chromium の実行ファイルを渡すと、playwright-core が既定で探すものの代わりに使う。
// 応答の状態コードが画面ごとの期待値と違うか、応答が HTML でない画面があれば、撮り終えた後にその一覧を出して
// 終了コード 1 で終える。
// テーマと言語の POST はコンテキストに cookie を残すので、以降の撮影に影響しないよう末尾に置き、
// 最後に system（cookie を消す）を送る。
// copy: "manual" は navigator.clipboard を消してから押す。
import { chromium } from "playwright-core";
import { mkdirSync } from "node:fs";

const out = process.argv[2];
const locale = process.argv[3];
if (!out) {
  console.error("usage: node dev/screenshots.mjs <output directory> [locale]");
  process.exit(2);
}
mkdirSync(out, { recursive: true });

const port = Number(process.env.PREVIEW_PORT ?? "18461");
const password = "preview-password";
const base = `http://127.0.0.1:${port}`;
const unavailable = `http://127.0.0.1:${port + 1}`;
const empty = `http://127.0.0.1:${port + 2}`;
const signer = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9";
const signerNsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re";
const specNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5";
const account = (action) => `${base}/accounts/${signer}/${action}`;
const unreadablePubkey = "dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444";
const unreadableAccount = (action) => `${base}/accounts/${unreadablePubkey}/${action}`;

const viewports = [
  { name: "w1280", width: 1280, height: 800, deviceScaleFactor: 1 },
  { name: "w375", width: 375, height: 812, deviceScaleFactor: 2 },
];
const colorSchemes = ["light", "dark"];

// 撮る画面。form を持つものは POST で開く。status は応答の状態コードの期待値で、無ければ 200。
// mask は乱数で変わる値を伏せる。copy を持つものは、開いた後に最初のコピーのボタンを押してから撮る。
// click と keys は、開いた後に順にクリックするセレクターと、順に押すキーの配列。
const shots = [
  { name: "01-dashboard", url: `${base}/` },
  { name: "02-dashboard-empty", url: `${empty}/` },
  { name: "03-dashboard-accounts-unavailable", url: `${unavailable}/` },
  { name: "04-approve-page", url: `${base}/approve/tok-1` },
  { name: "05-approved", url: `${base}/approve/tok-1`, form: {} },
  { name: "06-denied", url: `${base}/deny/tok-1`, form: {} },
  { name: "07-decision-not-found", url: `${base}/approve/unknown`, form: {}, status: 404 },
  { name: "08-new-account", url: `${base}/accounts/new` },
  { name: "09-import-invalid-nsec", url: `${base}/accounts/import`, form: { nsec: "nsec1invalid", label: "x" }, status: 400 },
  { name: "10-import-duplicate", url: `${base}/accounts/import`, form: { nsec: signerNsec, label: "dup" }, status: 409 },
  { name: "11-registered", url: `${base}/accounts/import`, form: { nsec: specNsec, label: "<i>imported</i>" } },
  { name: "12-generated", url: `${base}/accounts/generate`, form: {}, mask: "input[readonly]" },
  { name: "13-generated-invalid-label", url: `${base}/accounts/register-generated`, form: { nsec: specNsec, label: "a\tb" }, status: 400 },
  { name: "14-edit-label", url: account("label") },
  { name: "15-edit-label-invalid", url: account("label"), form: { label: "a\nb" }, status: 400 },
  { name: "16-edit-label-not-applied", url: account("label"), form: { label: "not-applied" }, status: 409 },
  { name: "17-change-not-confirmed", url: account("label"), form: { label: "maybe" }, status: 202 },
  { name: "18-accounts-not-ready", url: account("label"), form: { label: "not-ready" }, status: 503 },
  { name: "19-rotate-confirm", url: account("rotate") },
  { name: "20-delete-confirm", url: account("delete") },
  { name: "20b-unreadable-delete-confirm", url: unreadableAccount("delete") },
  { name: "21-private-key-form", url: account("private-key") },
  { name: "22-private-key-wrong-password", url: account("private-key"), form: { password: "wrong" }, status: 403 },
  { name: "23-private-key", url: account("private-key"), form: { password } },
  { name: "24-account-page-unavailable", url: `${unavailable}/accounts/${signer}/label`, status: 503 },
  { name: "25-delete-not-applied", url: account("delete"), form: {}, status: 409 },
  { name: "25b-unreadable-delete-not-applied", url: unreadableAccount("delete"), form: {}, status: 409 },
  { name: "26-dashboard-copied", url: `${base}/`, copy: true },
  { name: "27-revoke-not-found", url: `${base}/sessions/revoke`, form: { signer, client: "not-approved" }, status: 404 },
  { name: "27b-revoke-not-applied", url: `${base}/sessions/revoke`, form: { signer, client: "not-applied" }, status: 409 },
  { name: "28-revoke-not-answered", url: `${base}/sessions/revoke`, form: { signer, client: "no-answer" }, status: 503 },
  { name: "28b-approve-page-pending-unavailable", url: `${unavailable}/approve/tok-1` },
  { name: "29-reenable-not-found", url: `${base}/plugins/reenable`, form: { name: "missing" }, status: 404 },
  { name: "30-reenable-not-answered", url: `${base}/plugins/reenable`, form: { name: "no-answer" }, status: 503 },
  { name: "31-theme-menu", url: `${base}/`, click: ["summary >> nth=0"] },
  { name: "32-language-menu", url: `${base}/`, click: ["summary >> nth=0", "summary >> nth=1"] },
  { name: "33-summary-focus", url: `${base}/`, keys: ["Tab", "Tab"] },
  { name: "34-current-item-focus", url: `${base}/`, keys: ["Tab", "Tab", "Enter", "Tab"] },
  { name: "35-item-focus", url: `${base}/`, keys: ["Tab", "Tab", "Enter", "Tab", "Tab"] },
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
  { name: "47-new-relay", url: `${base}/relays/new` },
  { name: "48-add-relay-invalid-url", url: `${base}/relays/new`, form: { url: "https://relay.example", monitor: "on" }, status: 400 },
  { name: "49-add-relay-role-required", url: `${base}/relays/new`, form: { url: "wss://relay.example" }, status: 400 },
  { name: "50-add-relay-duplicate", url: `${base}/relays/new`, form: { url: "wss://duplicate.example", monitor: "on" }, status: 409 },
  { name: "51-add-relay-not-saved", url: `${base}/relays/new`, form: { url: "wss://not-saved.example", monitor: "on" }, status: 409 },
  { name: "52-add-relay-maybe", url: `${base}/relays/new`, form: { url: "wss://maybe.example", monitor: "on" }, status: 202 },
  { name: "53-add-relay-unconfirmed", url: `${base}/relays/new`, form: { url: "wss://unconfirmed.example", monitor: "on" }, status: 202 },
  { name: "54-edit-relay", url: `${base}/relays/1/edit` },
  { name: "55-edit-relay-role-required", url: `${base}/relays/1/edit`, form: {}, status: 400 },
  { name: "56-edit-relay-not-saved", url: `${base}/relays/2/edit`, form: { monitor: "on" }, status: 409 },
  { name: "57-delete-relay", url: `${base}/relays/1/delete` },
  { name: "58-delete-relay-not-saved", url: `${base}/relays/2/delete`, form: {}, status: 409 },
  { name: "59-delete-relay-unconfirmed", url: `${base}/relays/3/delete`, form: {}, status: 202 },
  { name: "60-relay-not-found", url: `${base}/relays/99/edit`, status: 404 },
  { name: "61-connect-client", url: `${base}/sessions/connect` },
  { name: "62-connect-client-empty", url: `${empty}/sessions/connect` },
  { name: "63-connect-client-accounts-unavailable", url: `${unavailable}/sessions/connect` },
  { name: "64-connect-client-invalid-uri", url: `${base}/sessions/connect`, form: { uri: "not-a-uri", signer }, status: 400 },
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

// 撮る前の操作。クリックの後に押すキーを送る。
async function prepare(page, shot) {
  for (const selector of shot.click ?? []) {
    await page.locator(selector).click();
  }
  for (const key of shot.keys ?? []) {
    await page.keyboard.press(key);
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
      for (const shot of shots) {
        const response = await open(page, shot);
        await prepare(page, shot);
        const copyLabel = shot.copy === "manual" ? "selected" : "copied";
        const copied = shot.copy
          ? ` ${copyLabel}=${await copy(page, shot.copy === "manual")}`
          : "";
        const file = `${out}/${shot.name}-${viewport.name}-${colorScheme}.png`;
        const mask = shot.mask ? [page.locator(shot.mask)] : [];
        // animations: "disabled" は、ボタンの色の遷移を終わった状態にしてから撮る。
        await page.screenshot({ path: file, fullPage: true, mask, animations: "disabled" });
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
