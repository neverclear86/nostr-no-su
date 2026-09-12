# 動作確認レポートのコマンド例

[SKILL.md](SKILL.md) の各手順で実際に動いたコマンドをまとめる。
`$W` は検証用の worktree、`$V` はスクラッチパッドの作業ディレクトリを指す。
ポートは `ss -ltn` で空いていることを確かめてから決める。

## 環境

### 開始時の記録、worktree とラッパー

```sh
# ユーザーのコンテナーの状態。後片付けで同じ状態か比べる（Status の Up の時間が続いていれば再起動されていない）
# docker ps --filter name=nostr-no-su- は部分一致で nns-verify-nostr-no-su-1 にも当たるので、grep で先頭を合わせる
docker ps -a --format '{{.Names}} {{.State}} {{.Status}}' | grep '^nostr-no-su-' > "$V/baseline-docker-ps.txt" || true

git -C /home/lina/workspace/projects/nostr-no-su fetch origin
git -C /home/lina/workspace/projects/nostr-no-su worktree add "$W" origin/main
```

```sh
# $V/dc.sh
ENVF=${ENVF:-$V/nns.env}
exec docker compose -p nns-verify -f "$W/docker-compose.yml" -f "$V/strfry.yml" --env-file "$ENVF" "$@"
```

最初の `-f` のディレクトリがプロジェクトの基準になるので、`./plugins` は worktree のものが使われる。

```sh
# $V/nns.env
RELAY_URL=ws://strfry-a:7777,ws://strfry-b:7777
ADMIN_PORT=8095
ADMIN_BASE_URL=http://127.0.0.1:8095
ADMIN_PASSWORD=verify-<乱数>
ACCOUNT_MASTER_KEY=<openssl rand -hex 32 の出力>
```

マスターキーが無い場合と不正な場合は、その行だけを変えた env ファイルを別に作り、`ENVF=$V/nns-nokey.env ./dc.sh up -d nostr-no-su` のように切り替える。

### strfry

```sh
docker run --rm --entrypoint cat ghcr.io/hoytech/strfry:latest /app/strfry.conf \
  | sed 's/bind = "127.0.0.1"/bind = "0.0.0.0"/' > "$V/strfry.conf"
```

```yaml
# $V/strfry.yml
services:
  strfry-a:
    image: ghcr.io/hoytech/strfry:latest
    volumes: ["$V/strfry.conf:/app/strfry.conf:ro"]
    ports: ["127.0.0.1:7801:7777"]
  strfry-b:
    image: ghcr.io/hoytech/strfry:latest
    volumes: ["$V/strfry.conf:/app/strfry.conf:ro"]
    ports: ["127.0.0.1:7802:7777"]
```

`$V` は実際のパスに展開して書く。

### テスト

README のテストの手順（5433）と重ならないポートにする。
`docker run` が失敗したときに別の Postgres へつながないよう、`&&` でつなぐ。
コンテナーが止まっていると `docker exec` が失敗し続け、`until` が終わらない。
待つ時間は `timeout` で 60 秒までにする。
イメージの `/var/lib/postgresql/data` は名前の無い volume になるので、`docker rm` に `-v` を付けて一緒に消す。

```sh
docker run -d --name nns-verify-testpg -p 127.0.0.1:5533:5432 \
    -e POSTGRES_PASSWORD=<使い捨て> -e POSTGRES_DB=nostr_no_su_test postgres:17-alpine \
  && timeout 60 sh -c 'until docker exec nns-verify-testpg pg_isready -h 127.0.0.1 -U postgres -d nostr_no_su_test; do sleep 1; done' \
  && (cd "$W" && TEST_DATABASE_URL=postgres://postgres:<使い捨て>@127.0.0.1:5533/nostr_no_su_test gleam test)
docker rm -f -v nns-verify-testpg
```

### event_logger のビルドと起動

```sh
./dc.sh up -d postgres strfry-a strfry-b
docker run --rm -v "$W/plugins-src/event_logger:/src:ro" -v "$W/plugins/event_logger:/out" \
  ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine sh -c 'cp -r /src /work && rm -rf /work/build && cd /work \
  && gleam deps download && gleam export erlang-shipment && cp -r build/erlang-shipment/. /out/ && chmod -R a+rX /out'
./dc.sh build nostr-no-su
./dc.sh up -d nostr-no-su
```

### 起動時の確認

```sh
# DATABASE_URL はパスワードを伏せて表示する
docker exec nns-verify-nostr-no-su-1 printenv DATABASE_URL | sed -E 's#//([^:]+):[^@]+@#//\1:***@#'

# マスターキーは長さだけを見る
docker exec nns-verify-nostr-no-su-1 sh -c '[ ${#ACCOUNT_MASTER_KEY} -eq 64 ] && echo set'

# 操作の間のログだけを取り出す
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)   # 操作の前に記録する
./dc.sh logs --no-color --since "$T0" nostr-no-su
```

## ブラウザー（Playwright）

スクラッチパッドで `bun add nostr-tools@2.23.9 playwright-core@1.63.0` を実行し、スクリプトは node で動かす。
playwright-core はリポジトリの `package.json` と同じ版にする。
ブラウザーはキャッシュ済みの chromium を直接指定する。
キャッシュ（`~/.cache/ms-playwright`）に無ければ、スクラッチパッドで `env -u PLAYWRIGHT_BROWSERS_PATH npx playwright-core install chromium` を実行して、その版の chromium をキャッシュに入れる（`PLAYWRIGHT_BROWSERS_PATH` があると、その場所に入る）。

```js
import { chromium } from "playwright-core";

const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome`,
  headless: true,
});
const context = await browser.newContext({
  httpCredentials: { username: "admin", password: process.env.ADMIN_PASSWORD },
  viewport: { width: 1280, height: 900 },
  locale: "ja-JP",
  permissions: ["clipboard-read", "clipboard-write"],
});
const page = await context.newPage();

// 管理 UI の外への要求が無いことを、最後に hosts で確かめる。
const hosts = new Set();
page.on("request", (r) => hosts.add(new URL(r.url()).host));

// POST の状態コードは page.goto の戻り値に載らないので、クリックと同時に待つ。
// 送信で開いた文書の load も待たないと、page.content() が送信の前のページを返す
// （waitForURL は、今の URL と同じ URL へ送るときは遷移を待たずに解決する）。
// ナビゲーションバーの言語の切り替えもフォームなので、送信先で選ぶ。
const [response] = await Promise.all([
  page.waitForResponse((r) => r.request().method() === "POST"),
  page.waitForEvent("load"),
  page.click('form[action="/accounts/import"] button'),
]);
console.log(response.status());

await page.screenshot({ path: "06-registered.png", fullPage: true, animations: "disabled" });
```

- 制御文字を含むラベルは `String.fromCharCode` で組み立て、`evaluate` の引数で渡す（`locator(...).evaluate((el, value) => { el.value = value; }, "生成" + String.fromCharCode(0x85) + "C")`）
- `maxlength` を超える値も、`evaluate` で入力欄に直接入れる
- コピーのボタンは、押した直後に `[data-copied]` を `waitFor({ timeout: 1000 })` で待ち（2 秒で消える）、`navigator.clipboard.readText()` の値を隣の入力欄の値と比べる
- 狭い画面は `viewport: { width: 375, height: 812 }`、ダークは `colorScheme: "dark"`、JS 無効は `javaScriptEnabled: false` のコンテキストを別に作る。横のはみ出しは `page.evaluate(() => document.documentElement.scrollWidth)` が画面の幅以下であることで確かめる
- 一括の確認と、1 操作ずつ呼べるスクリプト（登録、ローテーション、削除、ラベル、URI の一覧、承認、拒否、取り消し）を分けておくと、シェルのシナリオから組み合わせやすい。URI の一覧は JSON で出し、変更の前に毎回ファイルへ追記する

## 管理 UI の表示（curl）

```sh
AUTH="admin:$ADMIN_PASSWORD"; BASE=http://127.0.0.1:8095
lang() { curl -s -u "$AUTH" "$@" | grep -o '<html lang="[a-z]*"'; }
lang "$BASE/"                                                      # en
lang -H 'Accept-Language: ja' "$BASE/"                             # ja
lang -H 'Accept-Language: ja' -b nostr_no_su_language=en "$BASE/"  # en（cookie が優先）

# 言語の切り替え。戻り先はサーバーが / から組み立て直す
curl -s -D - -o /dev/null -u "$AUTH" -H "Origin: $BASE" -d language=ja \
  --data-urlencode 'return=//evil.example/x' "$BASE/language"
# 303、location: /evil.example/x
# set-cookie: nostr_no_su_language=ja; Max-Age=31536000; Path=/; HttpOnly; SameSite=Lax

# Origin も Referer も無い POST では cookie が使われない。同じ要求に Origin を付けると使われる
lang -b nostr_no_su_language=ja -d nsec=nsec1invalid -d label=x "$BASE/accounts/import"                     # en
lang -b nostr_no_su_language=ja -H "Origin: $BASE" -d nsec=nsec1invalid -d label=x "$BASE/accounts/import"  # ja

# CSS は worktree の生成物と同じ
curl -s -u "$AUTH" "$BASE/static/admin.css" | sha256sum
sha256sum < "$W/priv/static/admin.css"
curl -s -o /dev/null -w '%{http_code}\n' -u "$AUTH" --path-as-is "$BASE/static/../gleam.toml"   # 404
```

## NIP-46 クライアント（bun + nostr-tools）

### 使い捨ての鍵

```sh
bun -e 'import {generateSecretKey,getPublicKey} from "nostr-tools/pure"; import {nsecEncode} from "nostr-tools/nip19";
const sk=generateSecretKey(); console.log(JSON.stringify({nsec:nsecEncode(sk),hex:Buffer.from(sk).toString("hex"),pubhex:getPublicKey(sk)}))'
```

### URI のホストの置き換えと接続

```ts
import { BunkerSigner, parseBunkerInput } from "nostr-tools/nip46";
import { generateSecretKey } from "nostr-tools/pure";

const HOSTS: Record<string, string> = {
  "strfry-a:7777": "127.0.0.1:7801",
  "strfry-b:7777": "127.0.0.1:7802",
};

// relay= の値は URL エンコードされた形と生の形の両方を置き換える
function rewrite(uri: string): string {
  let out = uri;
  for (const [from, to] of Object.entries(HOSTS))
    out = out.split(encodeURIComponent(from)).join(encodeURIComponent(to)).split(from).join(to);
  return out;
}

const pointer = await parseBunkerInput(rewrite(process.argv[2]));
const signer = BunkerSigner.fromBunker(generateSecretKey(), pointer!, {
  onauth: (url) => console.log(`auth_url: ${url}`),
});

// 応答が無いことも結果として扱えるよう、呼び出しを期限付きにする
const withTimeout = <T>(p: Promise<T>, ms = 15000) =>
  Promise.race([p, new Promise<never>((_, reject) => setTimeout(() => reject("timeout"), ms))]);

try {
  await withTimeout(signer.connect());
} catch (e) {
  // 拒否は Error ではなく文字列で届く
  console.log(e instanceof Error ? e.message : String(e));
}
```

### 接続したままのクライアント

上の接続処理を、標準入力から `sign` や `quit` の命令を読み続けるスクリプト（ここでは `nip46.ts` の `session` モード）にしておき、FIFO で命令を流す。

```sh
mkfifo fifo-a
exec 3<>fifo-a
TAG=session-A bun nip46.ts session "$URI" < fifo-a > session-a.log 2>&1 &
echo sign >&3
echo quit >&3
exec 3>&-
```

## DB

```sh
docker pause nns-verify-postgres-1     # 接続を切らずに止める
docker unpause nns-verify-postgres-1
./dc.sh exec -T postgres pg_dump -U nostr -d nostr_no_su > "$V/pgdump.sql"
./dc.sh exec -T postgres psql -U nostr -d nostr_no_su -c 'select count(*), count(distinct id) from events'
```

## 秘密の grep

値そのものも一致した行も出力せず、対象の名前、ファイル、件数（一致した行の数）だけを出す。
grep の終了状態は、一致ありが 0、一致なしが 1、ファイルを読めないとき（グロブが何にも一致しないときを含む）が 2 である。
`count_hits` は 1 を一致なしとして進め、2 以上のときは `ERROR` の行を出して同じ状態を返すので、`set -e` のスクリプトはそこで止まる。
`ERROR` の行を出した呼び出しは、ほかのファイルで一致していても `HIT` の行を出さない。
`targets.txt` が無い、通常のファイルでない（ディレクトリーなど）、読めない、空のいずれかのときは `ERROR targets.txt unreadable or empty` を出し、2 つのループを実行しない。
行が「名前<TAB>値」の形でないとき（名前か値の先頭か末尾に空白があるときを含む）も、値を出さないよう行番号だけを `ERROR targets.txt line <行番号>` として出し、2 つのループを実行しない。
これらの確かめは `if` の条件なので、`set -e` のスクリプトもそこでは止まらず、`ERROR` の行で知らせる。
32 文字の 16 進の保険は `targets.txt` を使わないので、このときも実行する。
確かめるのは、`HIT` と `ERROR` の行が 1 つも出ないことである。
Claude Code の Bash ツールでは `grep` が `-I` 付きで ugrep を呼ぶ関数になっており、NUL を含むファイルを数えずに飛ばすので、`-a` を付ける。

```sh
# count_hits <名前> <grep のオプション> -- <パターン> <ファイル...>
# 一致が 1 件以上のファイルごとに「HIT 名前 ファイル:件数」を出す。grep の失敗（終了状態 2）は ERROR を出して返す
count_hits() {
  local name=$1 rc=0 counts
  shift
  counts=$(grep -a -c -H "$@") || rc=$?
  if [ "$rc" -gt 1 ]; then echo "ERROR $name grep exited $rc"; return "$rc"; fi
  printf '%s\n' "$counts" | awk -F: -v name="$name" '$NF > 0 { print "HIT", name, $0 }'
}

# targets.txt は「名前<TAB>値」の行。nsec と 16 進の秘密鍵、各時点の secret（名前を secret_ で始める）、
# マスターキー、管理パスワード、DB のパスワード
# targets.txt が読めて空でない通常のファイルであること、各行が「名前<TAB>値」であることを確かめる。値を出さないよう、崩れた行は行番号だけを出す
if [ ! -f "$V/targets.txt" ] || [ ! -s "$V/targets.txt" ] || [ ! -r "$V/targets.txt" ]; then
  echo "ERROR targets.txt unreadable or empty"
elif awk -F'\t' 'NF < 2 || $1 == "" || $2 == "" || /\r/ || /(^|\t) | (\t|$)/ { print "ERROR targets.txt line", NR; bad = 2 } END { exit bad }' "$V/targets.txt"; then
  while IFS=$'\t' read -r name value || [ -n "$name" ]; do
    count_hits "$name" -F -- "$value" "$V"/log-*.txt "$V"/pgdump*.sql
  done < "$V/targets.txt"

  # 応答本文。bodies/ には鍵を表示するページ（登録の完了、生成した鍵の確認、秘密鍵の表示）を保存しない。
  # secret の行は飛ばす（理由は SKILL.md の手順 3 の項目 15）。
  awk '!/^secret_/' "$V/targets.txt" | while IFS=$'\t' read -r name value; do
    count_hits "$name" -F -- "$value" "$V"/bodies/*
  done
fi

# 記録漏れの保険（secret は 32 文字の 16 進）
count_hits hex32 -w -- '[0-9a-f]\{32\}' "$V"/log-*.txt
```

`hex32` の `HIT` が出たときは、16 進の並びを伏せて、その行が何のログかを見る。
32 文字以上の並びをすべて伏せるので、公開鍵とイベント id も伏せる。
nsec やパスワードは伏せないので、`ERROR` の行が出ているとき、または同じファイルに `hex32` 以外の `HIT` があるときは実行しない。
`ERROR` を出した呼び出しはほかのファイルで一致していても `HIT` を出さないので、先に `ERROR` の原因を直して検索し直す。
`hex32` 以外の `HIT` があるときは、先にその `HIT` を調べる。

```sh
grep -a -n -w -- '[0-9a-f]\{32\}' <HIT のファイル> | sed 's/[0-9a-f]\{32,\}/<hex>/g'
```

## ローカル実行とアクターの kill

テスト用の Postgres（5533）と重ならないポートにする。

```sh
docker run -d --name nns-verify-localpg -p 127.0.0.1:5534:5432 \
  -e POSTGRES_PASSWORD=<使い捨て> -e POSTGRES_DB=nostr_no_su postgres:17-alpine

cd "$W" && env DATABASE_URL=postgres://postgres:<使い捨て>@127.0.0.1:5534/nostr_no_su \
  ACCOUNT_MASTER_KEY=<使い捨て> RELAY_URL= BUNKER_RELAY_URL=ws://127.0.0.1:7801 \
  ADMIN_PORT=8096 ADMIN_PASSWORD=<使い捨て> ADMIN_BASE_URL=http://127.0.0.1:8096 PLUGIN_DIR= \
  ERL_FLAGS="-sname nnsverify -setcookie nnsverifycookie" gleam run > "$V/log-local-run.txt" 2>&1 &
```

アカウントは `curl -u admin:<パスワード> -d nsec=... -d label=... http://127.0.0.1:8096/accounts/import` で登録できる（`Origin` を送らないので CSRF の検査を通る）。

```sh
erl -sname probe$$ -setcookie nnsverifycookie -noshell -eval '
  {ok, H} = inet:gethostname(), N = list_to_atom("nnsverify@" ++ H), pong = net_adm:ping(N),
  Find = fun() -> [{X, rpc:call(N, erlang, whereis, [X])} || X <- rpc:call(N, erlang, registered, []),
                   lists:prefix("nostr_no_su_bunker$", atom_to_list(X))] end,
  B = Find(), io:format("BUNKER-BEFORE ~p~n", [B]),
  [rpc:call(N, erlang, exit, [P, kill]) || {_, P} <- B],
  timer:sleep(3000), io:format("BUNKER-AFTER  ~p~n", [Find()]), halt().'
```

止めるときは本体を先に止め、それから Postgres のコンテナーを消す。

```sh
pkill -f '[b]eam.smp.*nnsverify'
docker rm -f nns-verify-localpg
```

## 投稿と確認

```sh
cd "$V/shots"
gh issue create -R neverclear86/nostr-no-su --title "動作確認レポート: ..." --body-file - <<'EOF'
...
EOF
gh issue comment <番号> -R neverclear86/nostr-no-su --body-file - \
  --attach ./03-dashboard-empty.png --attach ./04-dashboard-accounts.png <<'EOF'
...
![アカウント 0 件のダッシュボード](./03-dashboard-empty.png)
...
EOF
```

本文で参照した画像は本文の代替テキストが使われるので、`--attach` に `#代替テキスト` を付けなくてよい。
画像の並びは本文での参照の位置で決まる。

```sh
gh api repos/neverclear86/nostr-no-su/issues/comments/<コメントの id> --jq .body > posted.md
grep -c '](./' posted.md || true
grep -o '!\[[^]]*\](https://github.com/user-attachments/assets/[^)]*)' posted.md | wc -l
TOKEN=$(gh auth token)
grep -o 'https://github.com/user-attachments/assets/[^)]*' posted.md | while read -r u; do
  curl -s -o /dev/null -w '%{http_code} %{content_type}\n' -L -H "Authorization: token $TOKEN" "$u"
done
```

## 後片付け

```sh
./dc.sh down -v --rmi local
docker images --format '{{.Repository}}:{{.Tag}}' | grep nns-verify || true   # 残っていれば docker rmi で消す
docker run --rm -v "$W/plugins:/p" --entrypoint sh ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine \
  -c 'rm -rf /p/event_logger'
git -C /home/lina/workspace/projects/nostr-no-su worktree remove --force "$W"
cat "$V/baseline-docker-ps.txt"
docker ps -a --format '{{.Names}} {{.State}} {{.Status}}' | grep '^nostr-no-su-' || true
```
