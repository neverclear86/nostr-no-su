# 貢献の手引き

このリポジトリに変更を出す人向けの手引きである。仕様や設計の文書は [README（日本語）](README.ja.md) の「文書」節から辿ること（トップの [README.md](README.md) は同じ内容の英語版）。

## 開発の手順と検査

CI の検査のコマンドと必須の手順は [CLAUDE.md](CLAUDE.md) の「開発」節に、Postgres の起動や CSS のビルドなどローカルでの実行手順は [docs/development.md](docs/development.md) にある。食い違ったら `.github/workflows/ci.yml` が正である。

## 変更の出し方

issue を立ててから PR を出す。PR は main に squash マージする。PR のタイトルとコミットの件名は `feat:`、`fix:`、`docs:`、`refactor:` などの接頭辞と日本語の要約にする（`git log --oneline` の既存のコミットの形に合わせる）。利用者から見える変更は、同じ PR で `CHANGELOG.md` の `[Unreleased]` に書く。

## 版数

[Semantic Versioning](https://semver.org/lang/ja/) に従う。0.x の間は、破壊的変更（環境変数、compose、DB のスキーマ、プラグイン API の非互換）を含むリリースは minor を、それ以外は patch を上げる。

開発中の `version` は前のリリースの版のまま変えない（最初のリリースまでは `0.0.0`）。版を上げるのはリリースの PR だけで、未リリースの変更は `CHANGELOG.md` の `[Unreleased]` が表す。本体（`gleam.toml`）と `plugins-src/` の各プラグインの `gleam.toml` の版は常に同じ値にする。

イメージには、本体、`vendor/stratus`、Hex の依存のライセンスが `dev/collect_licenses.sh` で入る。同梱プラグイン `event_logger` と `profile` の依存は本体の依存の部分集合なので、この収集でそのまま覆われる（検証の手順 2）。

## 依存のライセンス

依存を足す、上げるときは、次を手元で実行する。

```sh
gleam deps download && gleam export erlang-shipment
sh dev/collect_licenses.sh build/erlang-shipment
```

イメージのビルドも同じスクリプトで失敗するので、手元で直してから確かめられる。失敗のメッセージごとの直し方は次のとおりである。

1. `<app> declares no licence and contains no licence file`: 上流のリポジトリでライセンスを確かめ、`dev/licenses-overrides.txt` に「アプリ名 SPDX の識別子 確かめた URL」を 1 行足す。
2. `<app> has a malformed line in dev/licenses-overrides.txt`: `dev/licenses-overrides.txt` の該当の行が空白またはタブで区切った 3 つの欄になっていないので、書き方を直す。
3. `<app> is in the shipment but no package in build/packages matches it`: パッケージの形が `dev/collect_licenses.sh` の想定と違うので、アプリ名の読み方を直す。

依存を外したら、`dev/licenses-overrides.txt` の該当の行も消す。

## 変更履歴

`CHANGELOG.md` の `[Unreleased]` に `### 追加`、`### 変更`、`### 削除`、`### 修正` の小見出しで、1 変更 1 行、issue か PR の番号を添えて書く。破壊的変更は行頭に **破壊的変更** と書く。

## リリース

以下はオーナーが行う手順である。

1. リリースに含めると決めた issue がすべて閉じていることを確かめる。
2. リリースの PR を出す。本体と `plugins-src/` の各プラグインの `gleam.toml` の `version` を出す版にし、`CHANGELOG.md` の `## [Unreleased]` を `## [X.Y.Z] - YYYY-MM-DD` にして、その上に空の `## [Unreleased]` を置く。PR の中で `sh dev/check_release_version.sh vX.Y.Z` が 0 で終わることを確かめる。
3. PR を squash マージし、main のそのコミットの CI（`ci`。main への push では docker イメージの検査を含む全部のジョブが走る。docs/development.md の「CI」）が成功したことを確かめ、そのコミットの SHA を控える。
4. 手順 3 で控えたコミットに注釈付きのタグを切って push する。

   ```sh
   git fetch origin && git tag -a vX.Y.Z -m vX.Y.Z <手順 3 のコミットの SHA> && git push origin vX.Y.Z
   ```

5. Actions の `release` が成功し、`ghcr.io/neverclear86/nostr-no-su` に `X.Y.Z`、`X.Y`、`latest` が付いたことを確かめる。あわせて、`docker buildx imagetools inspect ghcr.io/neverclear86/nostr-no-su:X.Y.Z` の出力に `linux/amd64` と `linux/arm64` の 2 つの Platform が並んでいることを確かめる（`release` の `merge` ジョブも同じ検査を行う）。
6. 最初の公開のときだけ、パッケージの設定（リポジトリの Packages → nostr-no-su → Package settings）で公開範囲を確かめ、公開する場合は Change visibility で public にする。あわせて、Settings → Actions → General の Workflow permissions などで `packages: write` が制限されていないことを確かめる（`release` が権限エラーで失敗したときの確認先）。

`release` が失敗したときは、`git push origin :refs/tags/vX.Y.Z` と `git tag -d vX.Y.Z` でタグを消し、手順 2 から直す。`build` ジョブの版の検査で止まった時点ではイメージは公開されていないが、`merge` ジョブの「両方の platform が付いたことを確かめる」で失敗したときは `X.Y.Z`、`X.Y`、`latest` が既に付いているので、パッケージの設定（リポジトリの Packages → nostr-no-su）から該当のタグも消す。

注意: `latest` は版の大小を比べず最後に公開したタグに付くので、`v0.2.0` の後に `v0.1.1` を push すると `latest` が `0.1.1` に戻る。
