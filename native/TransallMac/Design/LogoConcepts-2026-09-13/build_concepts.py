"""Rebuild editable concepts and review images. Requires Pillow and resvg-py."""
from pathlib import Path
from io import BytesIO
from html import escape
import json

from PIL import Image, ImageDraw, ImageFont
import resvg_py

ROOT = Path(__file__).resolve().parent
PREVIEW = ROOT / "previews"
PREVIEW.mkdir(exist_ok=True)
FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
LATIN = "/System/Library/Fonts/SFNS.ttf"

DEFS = '''
<linearGradient id="base" x1="0" y1="0" x2="0.65" y2="1">
 <stop stop-color="#FFFFFF"/><stop offset="0.52" stop-color="#F7F9FD"/><stop offset="1" stop-color="#E7EDF7"/>
</linearGradient>
<linearGradient id="blue" x1="0.15" y1="0" x2="0.8" y2="1">
 <stop stop-color="#619CF3"/><stop offset="0.45" stop-color="#2876E3"/><stop offset="1" stop-color="#1556B9"/>
</linearGradient>
<linearGradient id="ribbon" x1="0" y1="0" x2="0.9" y2="1">
 <stop stop-color="#80B2F8"/><stop offset="0.26" stop-color="#3C8AEC"/>
 <stop offset="0.44" stop-color="#1C65CF"/><stop offset="0.56" stop-color="#5497EC"/>
 <stop offset="0.75" stop-color="#2472D9"/><stop offset="1" stop-color="#1656B7"/>
</linearGradient>
<linearGradient id="rear" x1="0" y1="0" x2="1" y2="1">
 <stop stop-color="#9AC4FA"/><stop offset="1" stop-color="#4E8CE1"/>
</linearGradient>
<linearGradient id="middle" x1="0" y1="0" x2="1" y2="1">
 <stop stop-color="#70ADF7"/><stop offset="1" stop-color="#2267C8"/>
</linearGradient>
<filter id="baseShadow" x="-15%" y="-15%" width="130%" height="140%" color-interpolation-filters="sRGB">
 <feDropShadow dx="0" dy="12" stdDeviation="12" flood-color="#1B3154" flood-opacity="0.14"/>
</filter>
<filter id="markShadow" x="-20%" y="-20%" width="140%" height="145%" color-interpolation-filters="sRGB">
 <feDropShadow dx="0" dy="9" stdDeviation="7" flood-color="#1A4D91" flood-opacity="0.14"/>
</filter>
'''

A_PATH = "M682 294H435C326 294 299 401 394 454L630 586C725 639 698 746 589 746H342"
B_PATH = "M334 250H618Q654 250 654 286V348Q654 384 618 384H448Q416 384 416 416V530Q416 566 380 566H306Q270 566 270 530V314Q270 250 334 250Z"
SHEETS = [(244, 244, 344, 48), (346, 346, 344, 98), (448, 448, 344, 156)]
NAMES = {"A": ("转折", "Turn", "一条宽带，一次转折"), "B": ("交接", "Handoff", "两个形体，错位嵌合"), "C": ("重组", "Reshape", "三片形态，由方到圆")}


def rect(shape, fill, extra=""):
    x, y, size, radius = shape
    return f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="{radius}" fill="{fill}" {extra}/>'


def mark(key, mono=None, optical_size=None):
    if key == "A":
        return f'<path d="{A_PATH}" fill="none" stroke="{mono or "url(#ribbon)"}" stroke-width="140" stroke-linecap="round"/>'
    if key == "B":
        fill = mono or "url(#blue)"
        return f'<path d="{B_PATH}" fill="{fill}"/><path d="{B_PATH}" transform="rotate(180 512 512)" fill="{fill}"/>'
    # Knockout channels keep all three layers legible even in one ink.
    masks = "<defs>"
    for i in range(2):
        masks += f'<mask id="layer{i}" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="white"/>'
        for s in SHEETS[i + 1:]:
            channel = max(32, 2048 / optical_size) if optical_size else 32
            masks += rect(s, "black", f'stroke="black" stroke-width="{channel:g}"')
        masks += "</mask>"
    masks += "</defs>"
    fills = ["url(#rear)", "url(#middle)", "url(#blue)"]
    return masks + "".join(rect(s, mono or fills[i], f'mask="url(#layer{i})"' if i < 2 else "") for i, s in enumerate(SHEETS))


def svg(key, mono=None, optical_size=None):
    title = escape(f"Transall · {key} {NAMES[key][0]} · concept")
    base = '' if mono else '''<g id="base-surface"><rect x="72" y="72" width="880" height="880" rx="198" fill="url(#base)" filter="url(#baseShadow)"/>
<rect x="73" y="73" width="878" height="878" rx="197" fill="none" stroke="#FFFFFF" stroke-width="2" stroke-opacity="0.95"/>
<rect x="77" y="77" width="870" height="870" rx="193" fill="none" stroke="#C4D1E6" stroke-width="1.5" stroke-opacity="0.4"/></g>'''
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
<title id="title">{title}</title><desc id="desc">Editable vector concept; not an installed application icon.</desc>
<defs>{DEFS if not mono else ''}</defs>{base}<g id="symbol" {'' if mono else 'filter="url(#markShadow)"'}>{mark(key, mono, optical_size)}</g></svg>'''


def render(source, size):
    return Image.open(BytesIO(resvg_py.svg_to_bytes(svg_string=source, width=size, height=size))).convert("RGBA")


def font(size, latin=False):
    return ImageFont.truetype(LATIN if latin else FONT, size)


def label(canvas, xy, text, size=22, fill="#263851", latin=False):
    ImageDraw.Draw(canvas).text(xy, text, font=font(size, latin), fill=fill)


def center_label(canvas, center_x, y, text, size=22, fill="#263851", latin=False):
    f = font(size, latin)
    d = ImageDraw.Draw(canvas)
    width = d.textlength(text, font=f)
    d.text((center_x - width / 2, y), text, font=f, fill=fill)


def place(canvas, im, x, y):
    canvas.paste(im, (int(x), int(y)), im)


icons = {}
for key, (_, english, _) in NAMES.items():
    folder = ROOT / f"{key}-{english}"
    folder.mkdir(exist_ok=True)
    source = svg(key)
    (folder / "icon.svg").write_text(source)
    icons[key] = {}
    for size in [16, 32, 64, 128, 1024]:
        im = render(svg(key, optical_size=size), size)
        icons[key][size] = im
        im.save(folder / f"icon-{size}.png")
        if key == "C" and size in [16, 32]:
            (folder / f"icon-optical-{size}.svg").write_text(svg(key, optical_size=size))
            for variant, ink in [("mono-dark", "#233650"), ("mono-light", "#F2F5FB")]:
                (folder / f"{variant}-optical-{size}.svg").write_text(svg(key, ink, size))
    for variant, ink in [("mono-dark", "#233650"), ("mono-light", "#F2F5FB")]:
        mono = svg(key, ink)
        (folder / f"{variant}.svg").write_text(mono)
        render(mono, 1024).save(folder / f"{variant}.png")

# One comparison sheet includes hero views, native-pixel samples, monochrome marks,
# and both surrounding appearances. No screenshot is represented as a live Dock.
board = Image.new("RGB", (1800, 1650), "#F5F7FA")
d = ImageDraw.Draw(board)
label(board, (72, 45), "Transall", 45, latin=True)
label(board, (72, 105), "标志概念 / 抽象转换", 22, "#5F6E83")
label(board, (1430, 66), "2026.09  /  01–03", 22, "#718098", True)
d.line((72, 156, 1728, 156), fill="#D9E0EA", width=1)
for i, key in enumerate(NAMES):
    cx = 330 + i * 570
    chinese, english, desc = NAMES[key]
    center_label(board, cx, 192, f"{key}  {chinese}", 31)
    place(board, render(svg(key), 440), cx - 220, 244)
    center_label(board, cx, 710, desc, 22, "#5F6E83")
    for size, offset in [(16, -176), (32, -104), (64, -8), (128, 130)]:
        place(board, icons[key][size], cx + offset - size / 2, 890 - size / 2)
        center_label(board, cx + offset, 980, str(size), 18, "#6F7D90", True)
    place(board, render(svg(key, "#233650"), 172), cx - 86, 1084)
    # Identical appearance previews for all concepts.
    d.rounded_rectangle((cx - 224, 1350, cx - 14, 1560), radius=24, fill="#E4EAF2")
    d.rounded_rectangle((cx + 14, 1350, cx + 224, 1560), radius=24, fill="#1B2535")
    place(board, render(svg(key), 166), cx - 202, 1368)
    place(board, render(svg(key), 166), cx + 36, 1368)

for y, title in [(786, "实际像素尺寸 · 16 / 32 / 64 / 128 px"), (1044, "单色轮廓 · 去除底座、材质与阴影"), (1290, "深浅背景预览 · 同一图标")]:
    d.line((72, y - 17, 1728, y - 17), fill="#D9E0EA", width=1)
    label(board, (72, y), title, 19, "#6B7B90")
label(board, (72, 1600), "概念预览，尚未替换 App 图标。小尺寸请按图片原始大小查看。", 18, "#718098")
board.save(PREVIEW / "comparison.png")

# Pixel-expanded samples expose raster issues without interpolation.
qa = Image.new("RGB", (1560, 1120), "#F5F7FA")
label(qa, (55, 35), "小尺寸检查", 32)
label(qa, (55, 88), "上排为原始尺寸；下排为最近邻放大，不增加细节。", 20, "#6F7D90")
for i, key in enumerate(NAMES):
    x = 95 + i * 505
    label(qa, (x, 148), f"{key} · {NAMES[key][0]}", 28)
    for j, size in enumerate([16, 32, 64]):
        yy = 240 + j * 285
        label(qa, (x, yy - 26), f"{size} px", 20, latin=True)
        place(qa, icons[key][size], x + 90, yy - 25)
        place(qa, icons[key][size].resize((192, 192), Image.Resampling.NEAREST), x, yy + 50)
        mono = render(svg(key, "#233650", size), size)
        place(qa, mono.resize((192, 192), Image.Resampling.NEAREST), x + 214, yy + 50)
qa.save(PREVIEW / "pixel-check.png")

# Dedicated one-ink sheet: dark and reverse marks, including 16/32/64 pixels.
mono_board = Image.new("RGB", (1800, 1020), "#F5F7FA")
md = ImageDraw.Draw(mono_board)
md.rectangle((0, 510, 1800, 1020), fill="#1B2535")
label(mono_board, (65, 30), "单色标志 / 正形", 24)
label(mono_board, (65, 540), "单色标志 / 反白", 24, "#E7EDF7")
for i, key in enumerate(NAMES):
    cx = 330 + i * 570
    for y, ink in [(0, "#233650"), (510, "#F2F5FB")]:
        center_label(mono_board, cx, y + 78, f"{key} · {NAMES[key][0]}", 25, ink)
        place(mono_board, render(svg(key, ink), 330), cx - 165, y + 122)
        for size, offset in [(16, -76), (32, 0), (64, 92)]:
            place(mono_board, render(svg(key, ink, size), size), cx + offset - size / 2, y + 453 - size / 2)
mono_board.save(PREVIEW / "monochrome.png")

# Browser companion keeps the small samples at their actual CSS size on Retina.
html = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Transall · 标志概念</title><style>
*{box-sizing:border-box}body{margin:0;background:#f5f7fa;color:#24364e;font:16px -apple-system,BlinkMacSystemFont,sans-serif}main{max-width:1320px;margin:auto;padding:52px 36px}header{border-bottom:1px solid #d9e0ea;padding-bottom:24px;margin-bottom:30px}h1{font-size:36px;letter-spacing:-1px;margin:0 0 12px}p{color:#68778c;line-height:1.65}h2{font-size:24px;font-weight:600}h3{font-size:14px;font-weight:500;color:#68778c;margin:30px 0 18px}.grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:32px}.concept{text-align:center;min-width:0}.hero{width:min(100%,340px)}.sizes{display:flex;justify-content:space-around;align-items:center;height:170px;gap:8px}.sample{display:flex;flex-direction:column;align-items:center;justify-content:end;gap:14px;font-size:12px;color:#68778c}.pair{display:flex;justify-content:center;gap:12px}.pair div{width:46%;border-radius:18px;padding:15px;background:#e4eaf2}.pair .dark{background:#1b2535}.pair img{width:100%;display:block}.mono{width:150px}.links a{color:#1e63bc;margin:0 8px;line-height:2.2}footer{border-top:1px solid #d9e0ea;margin-top:38px;padding-top:16px;font-size:14px}@media(max-width:820px){.grid{grid-template-columns:1fr}.concept{border-bottom:1px solid #d9e0ea;padding-bottom:30px}.sizes{max-width:420px;margin:auto}.pair{max-width:380px;margin:auto}}</style><main><header><h1>Transall</h1><p>三款抽象转换标志 · 克制的原生质感 · 2026.09</p></header><div class="grid">'''
for key, (chinese, english, desc) in NAMES.items():
    folder = f"{key}-{english}"
    html += f'<section class="concept"><h2>{key} · {chinese}</h2><img class="hero" src="{folder}/icon.svg" alt="{chinese}图标"><p>{desc}</p><h3>实际尺寸 · 16 / 32 / 64 / 128 px</h3><div class="sizes">'
    for size in [16, 32, 64, 128]:
        source_name = f"icon-optical-{size}.svg" if key == "C" and size in [16, 32] else "icon.svg"
        html += f'<div class="sample"><img src="{folder}/{source_name}" width="{size}" height="{size}" alt="{size}像素"><span>{size}</span></div>'
    html += f'</div><h3>单色轮廓</h3><img class="mono" src="{folder}/mono-dark.svg" alt="单色轮廓"><h3>深浅背景</h3><div class="pair"><div><img src="{folder}/icon.svg" alt="浅色背景"></div><div class="dark"><img src="{folder}/icon.svg" alt="深色背景"></div></div><p class="links"><a href="{folder}/icon.svg">SVG</a><a href="{folder}/icon-1024.png">PNG 1024</a><a href="{folder}/mono-dark.svg">单色 SVG</a></p></section>'
html += '</div><footer><p>概念预览，尚未替换 App 图标。网页的小图使用矢量源，在高分屏上按标注的逻辑尺寸显示；像素检查图另用真实低分辨率 PNG。</p><p><a href="previews/comparison.png">比较图</a> · <a href="previews/pixel-check.png">像素检查</a> · <a href="previews/monochrome.png">单色正反形</a></p></footer></main></html>'
(ROOT / "index.html").write_text(html)
print(json.dumps({"output": str(ROOT), "concepts": len(NAMES), "png_size": 1024, "previews": [p.name for p in PREVIEW.glob("*.png")]}, ensure_ascii=False))
