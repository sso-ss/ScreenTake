# Contact sheet: python3 scripts/sheet.py out.jpg a.png b.png ... (2 columns)
import sys
from PIL import Image
out, files = sys.argv[1], sys.argv[2:]
ims = [Image.open(f).convert("RGB") for f in files]
w = 800
ims = [im.resize((w, round(im.height * w / im.width))) for im in ims]
h = max(im.height for im in ims)
cols = 2
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (w * cols + 8, h * rows + 4 * rows), "white")
for i, im in enumerate(ims):
    sheet.paste(im, ((i % cols) * (w + 8), (i // cols) * (h + 4)))
sheet.save(out, quality=85)
