#!/usr/bin/env python3
"""Render four original silk-wave wallpapers (requires numpy and Pillow)."""
from pathlib import Path
import json
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

WIDTH, HEIGHT = 3840, 2160
ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'Screen/Assets.xcassets'
x = np.linspace(0, 1, WIDTH, dtype=np.float32)[None, :]
y = np.linspace(0, 1, HEIGHT, dtype=np.float32)[:, None]


def glow(cx, cy, rx, ry):
    return np.exp(-0.5 * (((x-cx)/rx)**2 + ((y-cy)/ry)**2))


def crest(v):
    return (.90 - .58*v - .22*np.exp(-((v-.40)/.17)**2)
            + .08*np.exp(-((v-.72)/.17)**2) - .34*np.exp(-((v-1.02)/.16)**2))


# A shared fabric surface gives all four palettes the same visual concept.
mesh = Image.new('RGBA', (WIDTH, HEIGHT))
draw = ImageDraw.Draw(mesh)
xs = np.linspace(-.03, 1.04, 1200)
for index in range(80):
    t = index / 79
    ys = crest(xs) + (t-.15)*(.018 + .13*np.sin(np.pi*np.clip(xs,0,1))**2)
    ys += .020*np.sin(xs*6)*t
    points = list(zip((xs*WIDTH).astype(int), (ys*HEIGHT).astype(int)))
    draw.line(points, fill=(255, 255, 255, round(54*np.sin(np.pi*t)**.8)), width=2)
for index in range(65):
    t = index / 64
    ys = .12 + .13*np.sin(xs*4.3-.4) + .055*t - .25*xs
    points = list(zip((xs*WIDTH).astype(int), (ys*HEIGHT).astype(int)))
    draw.line(points, fill=(255, 255, 255, round(7*np.sin(np.pi*t))), width=1)
mesh = mesh.filter(ImageFilter.GaussianBlur(.25))
ridge = crest(x)
spread = .075 + .07*np.sin(np.pi*x)**2
shadow = np.exp(-.5*((y-ridge-.065)/spread)**2)*.22
highlight = np.exp(-.5*((y-ridge+.012)/.025)**2)*.36


def render(name, base, shadow_rgb, clouds, vertical_palette=None):
    color = np.empty((HEIGHT, WIDTH, 3), dtype=np.float32)
    color[:] = base
    if vertical_palette is not None:
        stops = np.linspace(0, 1, len(vertical_palette))
        for channel in range(3):
            color[:, :, channel] = np.interp(y[:, 0], stops, np.array(vertical_palette)[:, channel])[:, None]

    def glaze(rgb, opacity):
        nonlocal color
        color += (np.array(rgb, dtype=np.float32)-color)*opacity[..., None]

    for rgb, cx, cy, rx, ry, strength in clouds:
        glaze(rgb, glow(cx, cy, rx, ry)*strength)
    glaze(shadow_rgb, shadow)
    glaze([255, 252, 253] if name == 'Silk' else [255, 255, 255], highlight)
    # Subtle reproducible dithering avoids banding in the pastel gradients.
    color += np.random.default_rng(17).uniform(-.35, .35, (HEIGHT, WIDTH, 1)).astype(np.float32)
    image = Image.fromarray(np.clip(color, 0, 255).astype(np.uint8))
    image = Image.alpha_composite(image.convert('RGBA'), mesh).convert('RGB')
    folder = OUTPUT / f'Wallpaper{name}.imageset'
    folder.mkdir(parents=True, exist_ok=True)
    image.save(folder / 'wallpaper.png', optimize=True)
    (folder / 'Contents.json').write_text(json.dumps({
        'images': [{'filename': 'wallpaper.png', 'idiom': 'universal'}],
        'info': {'author': 'xcode', 'version': 1}
    }, indent=2)+'\n')
    image.resize((1280,720), Image.Resampling.LANCZOS).save(f'/tmp/screentake-{name.lower()}-preview.png')
    print(f'Generated {name}: {WIDTH}×{HEIGHT}', flush=True)


render('Silk', [253,225,231], [235,151,178], [
    ([246,177,196], .33,.77,.19,.34,.70),
    ([246,185,202], .73,.25,.18,.28,.58),
    ([255,240,242], .53,.45,.19,.20,.42),
    ([255,236,240], .98,.92,.35,.45,.44),
])
render('Pastel', [247,239,253], [174,155,225], [
    ([249,194,253], .22,.05,.35,.54,.92),
    ([187,137,246], .02,1.08,.28,.35,.72),
    ([108,190,252], 1.02,.13,.30,.43,.85),
    ([176,226,255], .95,.70,.27,.48,.88),
    ([211,255,252], .65,1.15,.25,.33,.94),
    ([255,247,252], .48,.57,.17,.28,.40),
])
render('Breeze', [232,246,242], [142,190,213], [
    ([248,251,246], 1.02,.05,.38,.47,.54),
], vertical_palette=[[240,246,235], [214,239,241], [184,230,245], [211,211,244], [242,191,234]])
render('Mint', [233,255,229], [132,214,163], [
    ([158,255,213], .02,.02,.57,.52,.88),
    ([237,255,188], .94,.82,.38,.55,.88),
    ([253,255,248], .98,.0,.25,.38,.90),
    ([239,255,249], .0,1.0,.31,.40,.78),
])
sheet = Image.new('RGB', (1280,720))
for index, name in enumerate(['Silk','Pastel','Breeze','Mint']):
    with Image.open(OUTPUT / f'Wallpaper{name}.imageset/wallpaper.png') as image:
        tile = image.resize((640,360), Image.Resampling.LANCZOS)
        sheet.paste(tile, ((index%2)*640, (index//2)*360))
preview = ROOT / '.build/backgrounds-preview.png'
preview.parent.mkdir(parents=True, exist_ok=True)
sheet.save(preview)
print(f'Preview: {preview}')
