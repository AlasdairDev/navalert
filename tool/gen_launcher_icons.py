"""Regenerates the Android launcher icons from the master artwork.

    python tool/gen_launcher_icons.py

Source: assets/icons/ALARMA APP ICON.png (2000x2000). That file is a design
source, not a runtime asset, so it is deliberately NOT listed in pubspec.yaml —
the same treatment assets/images/reference/ gets. Bundling a 2 MB PNG the app
never loads would only inflate the APK.

Written with Pillow rather than adding `flutter_launcher_icons`, because
SETUP.md pins every dependency and asks that new packages be raised with the
team first. This needs no entry in pubspec.lock.

WHY THE TWO OUTPUTS DIFFER
--------------------------
*Legacy* `ic_launcher.png` (mipmap-*dpi) is drawn as-is by old launchers, so it
gets the complete design — rounded border included — with only the artwork's
outer transparent margin trimmed so it fills its tile.

*Adaptive* `ic_launcher_foreground.png` cannot. An adaptive layer is 108x108dp
but only its central 72x72dp is ever visible; the outer 18dp per side is
reserved for the launcher's mask and parallax. The emblem spans ~76% of the
design, so a full-bleed foreground would have its wings cropped by a circle
mask, and the artwork's own rounded border would be rounded a second time by
the mask. The foreground is therefore a square crop from INSIDE the border,
scaled so the emblem lands at ~60% of the layer — clear of the safe-zone edge,
while still covering the whole visible area so no seam appears at the boundary.
"""

from PIL import Image
import numpy as np
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "icons", "ALARMA APP ICON.png")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

# Measured from the master artwork: the bright-pixel bounds of the rounded
# square (i.e. the design minus its outer margin), and the emblem's centre.
DESIGN_BBOX = (129, 120, 1871, 1898)
EMBLEM_CENTRE = (1007, 1026)
CROP_SIDE = 1620          # square crop, taken inside the purple border
FOREGROUND_FILL = 0.737   # crop occupies ~79.6dp of the 108dp layer

LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ADAPTIVE = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def main() -> None:
    src = Image.open(SRC).convert("RGBA")

    # ---- legacy: the whole design, squared up and trimmed to fill the tile
    design = src.crop(DESIGN_BBOX)
    side = max(design.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(design, ((side - design.size[0]) // 2,
                          (side - design.size[1]) // 2))
    for density, px in LEGACY.items():
        out = os.path.join(RES, f"mipmap-{density}", "ic_launcher.png")
        square.resize((px, px), Image.LANCZOS).save(out, optimize=True)
        print("legacy  ", out, px)

    # ---- adaptive foreground: emblem crop sized into the safe zone
    cx, cy = EMBLEM_CENTRE
    half = CROP_SIDE // 2
    crop = src.crop((cx - half, cy - half, cx + half, cy + half))
    # Sampled from the crop's own top edge so the fill continues the artwork's
    # backdrop instead of banding against it.
    backdrop = tuple(
        np.asarray(crop.convert("RGB")).reshape(-1, 3)[:200].mean(axis=0).astype(int)
    )
    for density, px in ADAPTIVE.items():
        canvas = Image.new("RGBA", (px, px), backdrop + (255,))
        inner = max(1, int(round(px * FOREGROUND_FILL)))
        canvas.paste(crop.resize((inner, inner), Image.LANCZOS),
                     ((px - inner) // 2, (px - inner) // 2))
        out = os.path.join(RES, f"mipmap-{density}", "ic_launcher_foreground.png")
        canvas.save(out, optimize=True)
        print("adaptive", out, px)

    print("\nic_launcher_background should stay #FF%02X%02X%02X "
          "(res/values/colors.xml)" % backdrop)


if __name__ == "__main__":
    main()
