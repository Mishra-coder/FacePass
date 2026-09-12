#!/usr/bin/env python3
"""Turn Branding/icon.png (icon on a dark blurred backdrop) into a transparent
macOS app icon and an Xcode AppIcon.appiconset.

Run: tools/.venv312/bin/python tools/make_app_icon.py
"""
import json
import pathlib

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Branding" / "icon.png"
OUT_PNG = ROOT / "Branding" / "AppIcon-1024.png"
ICONSET = ROOT / "FacePass" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

CANVAS = 1024
CONTENT = 940  # the blue squircle body fills most of the tile, like Finder/Freeform


def backdrop_color(rgb: np.ndarray) -> np.ndarray:
    h, w, _ = rgb.shape
    b = max(8, min(h, w) // 20)
    corners = np.concatenate([
        rgb[:b, :b].reshape(-1, 3), rgb[:b, -b:].reshape(-1, 3),
        rgb[-b:, :b].reshape(-1, 3), rgb[-b:, -b:].reshape(-1, 3),
    ])
    return np.median(corners, axis=0)


def alpha_from_source(source: Image.Image):
    """Alpha and un-mixed colour for the two kinds of source art we accept.

    A source that already carries transparency is trusted as-is; only the older
    "icon sitting on a dark blurred backdrop" art needs the backdrop lifted out.
    """
    if source.mode == "RGBA" and np.asarray(source)[..., 3].min() < 250:
        rgba = np.asarray(source).astype(np.float32)
        return rgba[..., :3], rgba[..., 3] / 255.0, None

    rgb = np.asarray(source.convert("RGB")).astype(np.float32)
    bg = backdrop_color(rgb)
    lift = np.clip(rgb - bg, 0, None).max(axis=2)
    # The blurred backdrop itself varies by up to ~26 levels, so start above that.
    soft = np.clip((lift - 34.0) / 110.0, 0.0, 1.0)
    return rgb, soft, bg


def main() -> None:
    source = Image.open(SRC)
    rgb, soft, bg = alpha_from_source(source)

    # Solid body: threshold, then flood-fill from the border so enclosed dark
    # details (eyes, mouth) stay opaque.
    # Only the component under the image centre counts, so the gaps between
    # the separate glow sparks are not mistaken for enclosed holes.
    # .copy(): floodfill edits are lost on images that still share a numpy buffer.
    solid = Image.fromarray(((soft > 0.5) * 255).astype(np.uint8), "L").copy()
    ImageDraw.floodfill(solid, (solid.width // 2, solid.height // 2), 200)
    component = Image.fromarray(((np.asarray(solid) == 200) * 255).astype(np.uint8), "L").copy()
    ImageDraw.floodfill(component, (0, 0), 128)
    body = (np.asarray(component) != 128).astype(np.float32)
    body = np.asarray(Image.fromarray((body * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))) / 255.0

    alpha = np.maximum(soft, body)

    if bg is None:
        # Already-transparent art: the colours are final, nothing to un-mix. Keep the
        # source alpha rather than the filled body, or the soft edges go hard.
        fg = rgb
        alpha = soft
    else:
        # Un-mix the backdrop from semi-transparent glow pixels.
        a = np.clip(alpha, 1e-3, 1.0)[..., None]
        fg = np.clip((rgb - (1.0 - a) * bg) / a, 0, 255)
        # Outside the body only the glow sparks remain; un-mixing darkens their halo
        # into a navy fringe on light backgrounds, so floor it at the glow colour.
        glow = np.array([120.0, 190.0, 255.0])
        fg = np.where(body[..., None] < 0.5, np.maximum(fg, glow), fg)
        fg = np.where(alpha[..., None] > 0.02, fg, 0)

    rgba = np.dstack([fg, alpha * 255.0]).astype(np.uint8)
    icon = Image.fromarray(rgba, "RGBA")

    # macOS shows app icons on a rounded tile with no auto-mask, so the blue squircle
    # BODY must fill the standard icon safe area (~82%). Scaling to the body (not the
    # whole art) keeps the tile filled; the glow sparks then sit just outside, overhanging.
    ys, xs = np.where(body > 0.5)
    body_box = (xs.min(), ys.min(), xs.max(), ys.max())
    body_w = body_box[2] - body_box[0]
    body_h = body_box[3] - body_box[1]
    body_cx = (body_box[0] + body_box[2]) / 2
    body_cy = (body_box[1] + body_box[3]) / 2

    scale = CONTENT / max(body_w, body_h)
    scaled = icon.resize((round(icon.width * scale), round(icon.height * scale)), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(scaled, (round(CANVAS / 2 - body_cx * scale),
                                    round(CANVAS / 2 - body_cy * scale)))
    canvas.save(OUT_PNG)
    print(f"backdrop {'none (source already transparent)' if bg is None else bg.round(1)}, "
          f"body {body_box}, saved {OUT_PNG}")

    ICONSET.mkdir(parents=True, exist_ok=True)
    images = []
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            pixels = points * factor
            name = f"icon_{points}x{points}{'@2x' if factor == 2 else ''}.png"
            canvas.resize((pixels, pixels), Image.LANCZOS).save(ICONSET / name)
            images.append({"idiom": "mac", "size": f"{points}x{points}",
                           "scale": f"{factor}x", "filename": name})
    (ICONSET / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))
    (ICONSET.parent / "Contents.json").write_text(json.dumps(
        {"info": {"author": "xcode", "version": 1}}, indent=2))
    print(f"wrote {len(images)} sizes to {ICONSET}")


if __name__ == "__main__":
    main()
