// 管理 UI の全ページを、固定状態のサーバー（dev/admin_preview.gleam）から撮る。
// 広い画面（1280px）と狭い画面（375px、2 倍の解像度）の、ライトとダーク
// （prefers-color-scheme のエミュレーション）で、ページ全体を撮る。
// 使い方: PREVIEW_PORT=18461 node dev/screenshots.mjs build/screenshots
// 出力先をリポジトリの中にするときは、.gitignore と .dockerignore が除く build/ の下にする。
// CHROMIUM に chromium の実行ファイルを渡すと、playwright-core が既定で探すものの代わりに使う。
import { chromium } from "playwright-core";
import { mkdirSync } from "node:fs";

const out = process.argv[2];
if (!out) {
  console.error("usage: node dev/screenshots.mjs <output directory>");
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

const viewports = [
  { name: "w1280", width: 1280, height: 800, deviceScaleFactor: 1 },
  { name: "w375", width: 375, height: 812, deviceScaleFactor: 2 },
];
const colorSchemes = ["light", "dark"];

// 撮る画面。form を持つものは POST で開く。mask は乱数で変わる値を伏せる。copy を持つものは、
// 開いた後に最初のコピーのボタンを押してから撮る。
const shots = [
  { name: "01-dashboard", url: `${base}/` },
  { name: "02-dashboard-empty", url: `${empty}/` },
  { name: "03-dashboard-accounts-unavailable", url: `${unavailable}/` },
  { name: "04-approve-page", url: `${base}/approve/tok-1` },
  { name: "05-approved", url: `${base}/approve/tok-1`, form: {} },
  { name: "06-denied", url: `${base}/deny/tok-1`, form: {} },
  { name: "07-decision-not-found", url: `${base}/approve/unknown`, form: {} },
  { name: "08-new-account", url: `${base}/accounts/new` },
  { name: "09-import-invalid-nsec", url: `${base}/accounts/import`, form: { nsec: "nsec1invalid", label: "x" } },
  { name: "10-import-duplicate", url: `${base}/accounts/import`, form: { nsec: signerNsec, label: "dup" } },
  { name: "11-registered", url: `${base}/accounts/import`, form: { nsec: specNsec, label: "<i>imported</i>" } },
  { name: "12-generated", url: `${base}/accounts/generate`, form: {}, mask: "input[readonly]" },
  { name: "13-generated-invalid-label", url: `${base}/accounts/register-generated`, form: { nsec: specNsec, label: "a\tb" } },
  { name: "14-edit-label", url: account("label") },
  { name: "15-edit-label-invalid", url: account("label"), form: { label: "a\nb" } },
  { name: "16-edit-label-not-applied", url: account("label"), form: { label: "not-applied" } },
  { name: "17-change-not-confirmed", url: account("label"), form: { label: "maybe" } },
  { name: "18-accounts-not-ready", url: account("label"), form: { label: "not-ready" } },
  { name: "19-rotate-confirm", url: account("rotate") },
  { name: "20-delete-confirm", url: account("delete") },
  { name: "21-private-key-form", url: account("private-key") },
  { name: "22-private-key-wrong-password", url: account("private-key"), form: { password: "wrong" } },
  { name: "23-private-key", url: account("private-key"), form: { password } },
  { name: "24-account-page-unavailable", url: `${unavailable}/accounts/${signer}/label` },
  { name: "25-delete-not-applied", url: account("delete"), form: {} },
  { name: "26-dashboard-copied", url: `${base}/`, copy: true },
];

// 画面を開いて応答を返す。POST は送信先と同じオリジンのページにフォームを作って送る
// （CSRF の検査を通り、ブラウザーの実際の遷移で表示される）。
async function open(page, shot) {
  if (!shot.form) return page.goto(shot.url);
  const origin = new URL(shot.url).origin;
  if (!page.url().startsWith(origin)) await page.goto(`${origin}/`);
  const [response] = await Promise.all([
    page.waitForNavigation(),
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

// 最初のコピーのボタンを押し、コピーの欄の囲みに data-copied が付いたかを返す。付いた表示は
// 2 秒で消えるので、付いたらすぐに撮る。完了を表示しない版（#49 より前の main）では false になる。
async function copy(page) {
  await page.locator("button[onclick]").first().click();
  return page
    .locator("[data-copied]")
    .first()
    .waitFor({ timeout: 1000 })
    .then(() => true, () => false);
}

const browser = await chromium.launch({ executablePath: process.env.CHROMIUM, headless: true });
try {
  for (const viewport of viewports) {
    for (const colorScheme of colorSchemes) {
      const context = await browser.newContext({
        httpCredentials: { username: "admin", password },
        viewport: { width: viewport.width, height: viewport.height },
        deviceScaleFactor: viewport.deviceScaleFactor,
        colorScheme,
        // コピーのボタンが navigator.clipboard に書けるようにする。
        permissions: ["clipboard-read", "clipboard-write"],
      });
      const page = await context.newPage();
      for (const shot of shots) {
        const response = await open(page, shot);
        const copied = shot.copy ? ` copied=${await copy(page)}` : "";
        const file = `${out}/${shot.name}-${viewport.name}-${colorScheme}.png`;
        const mask = shot.mask ? [page.locator(shot.mask)] : [];
        // animations: "disabled" は、ボタンの色の遷移を終わった状態にしてから撮る。
        await page.screenshot({ path: file, fullPage: true, mask, animations: "disabled" });
        console.log(`${response.status()} ${file}${copied}`);
      }
      await context.close();
    }
  }
} finally {
  await browser.close();
}
