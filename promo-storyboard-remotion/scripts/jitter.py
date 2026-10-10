# Measure text width per frame in a PNG sequence; report roughness vs a smooth fit.
import glob, sys
import numpy as np
from PIL import Image

for d in sys.argv[1:]:
    fs = sorted(glob.glob(f"{d}/*.png"))
    ws = []
    for f in fs:
        a = np.asarray(Image.open(f).convert("L"), float)
        cols = np.where((a > 128).sum(0) > 0)[0]
        # subpixel edges: use intensity-weighted extent
        prof = a.sum(0)
        c = np.cumsum(prof) / prof.sum()
        ws.append(np.interp(0.98, c, np.arange(len(c))) - np.interp(0.02, c, np.arange(len(c))))
    ws = np.array(ws)
    x = np.arange(len(ws))
    fit = np.polyval(np.polyfit(x, ws, 3), x)
    r = ws - fit
    d1 = np.diff(ws)
    print(f"{d:22s} frames {len(ws)}  width {ws[0]:.1f}->{ws[-1]:.1f}  jitter rms {np.sqrt((r**2).mean()):.3f}px  max {np.abs(r).max():.3f}px  reversals {(np.diff(np.sign(d1)) != 0).sum()}")
