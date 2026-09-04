#!/usr/bin/env python3
"""Draws the app icon at 1024x1024.

Kept as a script rather than a checked-in binary someone has to re-cut by hand:
the icon is geometry, so it regenerates exactly and can be nudged in one place.

iOS masks the corners itself and rejects alpha, so this fills the square edge to
edge and is written as opaque RGB.
"""
from PIL import Image, ImageDraw

SIZE = 1024
SS = 4                      # supersample, then downscale for clean edges
S = SIZE * SS

BACKDROP   = (232, 242, 254)
CARD       = (255, 255, 255)
CARD_LINE  = (228, 231, 235)
LIGHT      = (56, 165, 255)
DARK       = (20, 84, 214)
PLAY       = (244, 249, 255)
LIGHTS     = [(237, 106, 94), (245, 191, 79), (97, 197, 84)]


def bezier(p0, p1, p2, p3, steps=120):
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        out.append((
            u*u*u*p0[0] + 3*u*u*t*p1[0] + 3*u*t*t*p2[0] + t*t*t*p3[0],
            u*u*u*p0[1] + 3*u*u*t*p1[1] + 3*u*t*t*p2[1] + t*t*t*p3[1],
        ))
    return out


def shield_outline(cx, top, half_w, height):
    """Half traced with beziers, then mirrored — a shield is symmetric, and
    hand-listing both sides is how the two stop matching."""
    def pt(nx, ny):
        return (cx + nx * half_w, top + ny * height)

    left = []
    left += bezier(pt(0, .03), pt(-.34, -.02), pt(-.72, .01), pt(-1, .10))
    left += bezier(pt(-1, .10), pt(-1, .30), pt(-.99, .46), pt(-.92, .60))
    left += bezier(pt(-.92, .60), pt(-.80, .80), pt(-.45, .95), pt(0, 1.0))

    right = [(2 * cx - x, y) for x, y in reversed(left)]
    return left + right


def draw() -> Image.Image:
    img = Image.new("RGB", (S, S), BACKDROP)
    d = ImageDraw.Draw(img)

    # Browser card
    m = int(S * 0.105)
    card = (m, m, S - m, S - m)
    d.rounded_rectangle(card, radius=int(S * 0.055), fill=CARD)

    # Title bar: a hairline rather than a filled strip, as in the reference
    bar_y = m + int(S * 0.088)
    d.rectangle((m, bar_y, S - m, bar_y + int(S * 0.004)), fill=CARD_LINE)

    r = int(S * 0.0185)
    lx = m + int(S * 0.052)
    for i, colour in enumerate(LIGHTS):
        cx = lx + i * int(S * 0.062)
        cy = m + int(S * 0.045)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=colour)

    # Shield, drawn once into a mask so the two halves cannot drift apart
    cx = S // 2
    top = int(S * 0.225)
    half_w, height = int(S * 0.255), int(S * 0.600)
    outline = shield_outline(cx, top, half_w, height)

    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(outline, fill=255)

    halves = Image.new("RGB", (S, S), LIGHT)
    ImageDraw.Draw(halves).rectangle((cx, 0, S, S), fill=DARK)
    img.paste(halves, (0, 0), mask)

    # Play triangle. Corners rounded by stroking the outline with a curved
    # join — Pillow has no rounded polygon. The stroke grows the shape by half
    # its width, so the polygon is inset by that much first.
    pw, ph = int(S * 0.175), int(S * 0.205)
    px, py = cx - int(pw * 0.40), top + int(height * 0.44)
    r = int(S * 0.018)
    tri = [(px + r, py - ph // 2 + r), (px + r, py + ph // 2 - r), (px + pw - r, py)]
    d.polygon(tri, fill=PLAY)
    # Wraps one vertex PAST the start: Pillow rounds interior joints only, so
    # closing on tri[0] leaves that corner square with a visible notch.
    d.line(tri + [tri[0], tri[1]], fill=PLAY, width=r * 2, joint="curve")

    return img.resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    import pathlib, sys
    out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png")
    icon = draw()
    assert icon.mode == "RGB", "iOS rejects an icon with an alpha channel"
    icon.save(out, "PNG")
    print(f"{out} {icon.size[0]}x{icon.size[1]} {icon.mode}")
