#!/bin/sh
# 管理 UI の上部のロゴの製品名「Nostr-no-Su」を、M PLUS 2 の字形のパスにした Gleam のモジュールに書き出す。
# 「Nostr」と「Su」は ExtraBold（800）、「-no-」は Medium（500）で、字送りを 0.015 em 詰めて並べる（カーニングは使わない）。
# フォントは google/fonts の固定のコミットから実行時に取得して SHA-256 を照合し、リポジトリには置かない。
# fontTools は一時ディレクトリーの venv に入れ、終わったら消す。python3、curl、gleam とネットワークが要る。
# 使い方: sh dev/logo_wordmark.sh [出力先]（既定は src/nostr_no_su/admin/wordmark.gleam）
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/src/nostr_no_su/admin/wordmark.gleam}"
# 角括弧は curl がグロブとして読むので %5B と %5D に符号化する
font_url="https://raw.githubusercontent.com/google/fonts/badb95c58fccad31fa1c5c29c5dcbced87d695ec/ofl/mplus2/MPLUS2%5Bwght%5D.ttf"
font_sha256="2e4f45c2391355fb03195da4854ffbe85fea49bfdff5cc51020238083af6b75c"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL -o "$tmp/MPLUS2.ttf" "$font_url"
echo "$font_sha256  $tmp/MPLUS2.ttf" | sha256sum -c --quiet

python3 -m venv "$tmp/venv"
"$tmp/venv/bin/pip" install --quiet "fonttools==4.65.0"

"$tmp/venv/bin/python" - "$tmp/MPLUS2.ttf" "$out" <<'PY'
import math
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

font_path, out_path = sys.argv[1], sys.argv[2]
font = TTFont(font_path)
cmap = font.getBestCmap()
# 字送りの詰め（1000 units/em で 0.015 em）
tracking = -15

runs = [("Nostr", 800, "heavy"), ("-no-", 500, "medium"), ("Su", 800, "heavy")]
paths, bounds, x = {"heavy": "", "medium": ""}, BoundsPen(None), 0
for text, weight, key in runs:
    glyphs = font.getGlyphSet(location={"wght": weight})
    for char in text:
        glyph = glyphs[cmap[ord(char)]]
        transform = (1, 0, 0, -1, x, 0)  # y を下向きにし、基線を y = 0 に置く
        pen = SVGPathPen(glyphs, ntos=lambda v: str(round(v)))
        glyph.draw(TransformPen(pen, transform))
        glyph.draw(TransformPen(bounds, transform))
        paths[key] += pen.getCommands()
        x += glyph.width + tracking

x_min, y_min, x_max, y_max = bounds.bounds
left, top = math.floor(x_min), math.floor(y_min)
view_box = f"{left} {top} {math.ceil(x_max) - left} {math.ceil(y_max) - top}"

with open(out_path, "w", encoding="utf-8") as out:
    out.write(
        "//// 管理 UI の上部のロゴの製品名「Nostr-no-Su」の字形のパス。`dev/logo_wordmark.sh` が\n"
        "//// M PLUS 2（SIL Open Font License 1.1）から生成する。手で直さない。\n"
        "\n"
        "/// 字形の座標（1000 units/em、基線が y = 0）を囲む `viewBox`。\n"
        f'pub const view_box = "{view_box}"\n'
        "\n"
        "/// 「Nostr」と「Su」の ExtraBold（800）の字形。\n"
        f'pub const heavy_path = "{paths["heavy"]}"\n'
        "\n"
        "/// 「-no-」の Medium（500）の字形。\n"
        f'pub const medium_path = "{paths["medium"]}"\n'
    )
PY

gleam format "$out"
