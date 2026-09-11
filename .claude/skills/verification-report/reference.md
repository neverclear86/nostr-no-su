# 動作確認レポートのコマンド例

[SKILL.md](SKILL.md) の各手順で実際に動いたコマンドをまとめる。
`$W` は検証用の worktree、`$V` はスクラッチパッドの作業ディレクトリを指す。
ポートは `ss -ltn` で空いていることを確かめてから決める。

## 環境

### worktree とラッパー

```sh
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
# 廃止した変数（env-file ではコンテナーに届かない）
./dc.sh run -d --no-deps --name nns-verify-deprecated -e ACCOUNT_KEYS=deprecated-marker \
  -e BUNKER_SECRET=deprecated-marker -e ADMIN_PORT= nostr-no-su
sleep 12; docker logs nns-verify-deprecated > log-deprecated.txt; docker rm -f nns-verify-deprecated

# DATABASE_URL はパスワードを伏せて表示する
docker exec nns-verify-nostr-no-su-1 printenv DATABASE_URL | sed -E 's#//([^:]+):[^@]+@#//\1:***@#'

# マスターキーは長さだけを見る
docker exec nns-verify-nostr-no-su-1 sh -c '[ ${#ACCOUNT_MASTER_KEY} -eq 64 ] && echo set'

# 操作の間のログだけを取り出す
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)   # 操作の前に記録する
./dc.sh logs --no-color --since "$T0" nostr-no-su
```

## ブラウザー（Playwright）

スクラッチパッドで `bun add nostr-tools@2.23.9 playwright-core@1.49.1` を実行し、スクリプトは node で動かす。
ブラウザーはキャッシュ済みの chromium を直接指定する。

```js
import { chromium } from "playwright-core";

const browser = await chromium.launch({
  executablePath: `${process.env.HOME}/.cache/ms-playwright/chromium-1155/chrome-linux/chrome`,
  headless: true,
});
const context = await browser.newContext({
  httpCredentials: { username: "admin", password: process.env.ADMIN_PASSWORD },
  viewport: { width: 1280, height: 900 },
  permissions: ["clipboard-read", "clipboard-write"],
});
const page = await context.newPage();

// POST の状態コードは page.goto の戻り値に載らないので、クリックと同時に待つ
const [response] = await Promise.all([
  page.waitForResponse((r) => r.request().method() === "POST"),
  page.click("form button"),
]);
console.log(response.status());

await page.screenshot({ path: "04-dashboard-accounts.png", fullPage: true });
```

- 制御文字を含むラベルは、ソースに生の文字を埋め込まず `"\u0085"` のようにエスケープで書く
- `maxlength` を超える値は `page.evaluate` で入力欄に直接入れる
- コピーのボタンは、押した後に `navigator.clipboard.readText()` で読み、隣の入力欄の値と比べる
- 一括の確認と、1 操作ずつ呼べるスクリプト（登録、ローテーション、削除、ラベル、URI の一覧、承認、拒否、取り消し）を分けておくと、シェルのシナリオから組み合わせやすい。URI の一覧は JSON で出し、変更の前に毎回ファイルへ追記する

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

値そのものを出力せず、対象の名前と件数だけを出す。

```sh
# targets.txt は「名前<TAB>値」の行。nsec と 16 進の秘密鍵、各時点の secret、マスターキー、管理パスワード、DB のパスワード
while IFS=$'\t' read -r name value; do
  for f in "$V"/log-*.txt "$V/pgdump.sql" "$V"/bodies/*.html; do
    n=$(grep -F -c -- "$value" "$f" || true)
    [ "$n" -gt 0 ] && echo "HIT $name $f $n"
  done
done < "$V/targets.txt"

# 記録漏れの保険（secret は 32 文字の 16 進）
grep -o -w '[0-9a-f]\{32\}' "$V"/log-*.txt | head
```

## ローカル実行とアクターの kill

```sh
docker run -d --name nns-verify-localpg -p 127.0.0.1:5433:5432 \
  -e POSTGRES_PASSWORD=<使い捨て> -e POSTGRES_DB=nostr_no_su postgres:17-alpine

cd "$W" && env DATABASE_URL=postgres://postgres:<使い捨て>@127.0.0.1:5433/nostr_no_su \
  ACCOUNT_MASTER_KEY=<使い捨て> RELAY_URL= BUNKER_RELAY_URL=ws://127.0.0.1:7801 \
  ADMIN_PORT=8096 ADMIN_PASSWORD=<使い捨て> ADMIN_BASE_URL=http://127.0.0.1:8096 PLUGIN_DIR= \
  ERL_FLAGS="-sname nnsverify -setcookie nnsverifycookie" gleam run > "$V/log-local-run.txt" 2>&1 &
```

アカウントは `curl -u admin:<パスワード> -d nsec=... -d label=... http://127.0.0.1:8096/accounts/import` で登録できる（`Origin` を送らないので CSRF の検査を通る）。

```sh
erl -sname probe$$ -setcookie nnsverifycookie -noshell -eval '
  {ok, H} = inet:gethostname(), N = list_to_atom("nnsverify@" ++ H), pong = net_adm:ping(N),
  Find = fun() -> [{X, rpc:call(N, erlang, whereis, [X])} || X <- rpc:call(N, erlang, registered, []),
                   lists:prefix("nostr_no_su_bunker", atom_to_list(X))] end,
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
  --attach ./01-disabled-nokey.png --attach ./04-dashboard-accounts.png <<'EOF'
...
![マスターキーが無いときのダッシュボード](./01-disabled-nokey.png)
...
EOF
```

本文で参照した画像は本文の代替テキストが使われるので、`--attach` に `#代替テキスト` を付けなくてよい。
画像の並びは本文での参照の位置で決まる。

```sh
gh api repos/neverclear86/nostr-no-su/issues/comments/<コメントの id> --jq .body > posted.md
grep -c '](./' posted.md
grep -o '!\[[^]]*\](https://github.com/user-attachments/assets/[^)]*)' posted.md | wc -l
TOKEN=$(gh auth token)
grep -o 'https://github.com/user-attachments/assets/[^)]*' posted.md | while read -r u; do
  curl -s -o /dev/null -w '%{http_code} %{content_type}\n' -L -H "Authorization: token $TOKEN" "$u"
done
```

## 後片付け

```sh
./dc.sh down -v --rmi local
docker run --rm -v "$W/plugins:/p" --entrypoint sh ghcr.io/gleam-lang/gleam:v1.17.0-erlang-alpine \
  -c 'rm -rf /p/event_logger'
git -C /home/lina/workspace/projects/nostr-no-su worktree remove --force "$W"
docker ps --format '{{.Names}} {{.Status}}' | grep nostr-no-su-
```
