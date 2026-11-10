#!/usr/bin/env python3
"""Рисует иконку SinDisk (1024×1024 PNG): кольцевая карта диска на тёмном скруглённом квадрате.

Запуск: python3 scripts/make-icon.py [путь/к/AppIcon.png]
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4  # суперсэмплинг для сглаживания
N = 1024 * S
C = N / 2


def px(v):
    return v * S


def hex_rgb(h, a=255):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (a,)


def mix(c1, c2, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(c1, c2))


def rounded_mask(box, radius):
    m = Image.new("L", (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def annular(draw, r0, r1, a0, a1, fill, gap_deg=1.1):
    """Сегмент кольца от угла a0 до a1 (градусы, 0 — «12 часов», по часовой)."""
    a0 += gap_deg / 2
    a1 -= gap_deg / 2
    if a1 <= a0:
        return
    steps = max(8, int((a1 - a0) * 6))
    pts = []
    for i in range(steps + 1):
        a = math.radians(a0 + (a1 - a0) * i / steps - 90)
        pts.append((C + r1 * math.cos(a), C + r1 * math.sin(a)))
    for i in range(steps, -1, -1):
        a = math.radians(a0 + (a1 - a0) * i / steps - 90)
        pts.append((C + r0 * math.cos(a), C + r0 * math.sin(a)))
    draw.polygon(pts, fill=fill)


def main(out):
    img = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # Тень под плашкой.
    box = (px(100), px(100), px(924), px(924))
    radius = px(185)
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + px(14), box[2], box[3] + px(14)), radius=radius, fill=(0, 0, 0, 110))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(18))))

    # Плашка: вертикальный градиент тёмно-синего.
    top, bottom = hex_rgb("#26346B"), hex_rgb("#0D1230")
    grad = Image.new("RGBA", (N, N))
    gd = ImageDraw.Draw(grad)
    for y in range(N):
        t = min(1, max(0, (y - box[1]) / (box[3] - box[1])))
        gd.line([(0, y), (N, y)], fill=mix(top, bottom, t))
    img.paste(grad, (0, 0), rounded_mask(box, radius))

    # Мягкий блик сверху.
    glow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((px(180), px(40), px(844), px(520)), fill=(120, 150, 255, 46))
    glow = glow.filter(ImageFilter.GaussianBlur(px(70)))
    masked = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    masked.paste(glow, (0, 0), rounded_mask(box, radius))
    img.alpha_composite(masked)

    d = ImageDraw.Draw(img)

    # Ветки: доля круга, базовый цвет, дети (доли внутри ветки) и внуки (доли внутри ребёнка, None — нет).
    branches = [
        (0.36, "#4C8DFF", [0.5, 0.3, 0.2], [[0.6, 0.4], None, [1.0]]),
        (0.26, "#9C6BFF", [0.55, 0.45], [[0.7], [0.5, 0.5]]),
        (0.22, "#FF6B8E", [0.6, 0.4], [None, [1.0]]),
        (0.16, "#FFB547", [0.65, 0.35], [[0.6, 0.4], None]),
    ]
    rings = [(px(128), px(205)), (px(215), px(278)), (px(288), px(330))]
    white = hex_rgb("#FFFFFF")

    angle = 0.0
    for share, color, kids, grandkids in branches:
        base = hex_rgb(color)
        span = 360 * share
        annular(d, *rings[0], angle, angle + span, base, gap_deg=1.6)
        a = angle
        for k, (kshare, gk) in enumerate(zip(kids, grandkids)):
            kspan = span * kshare
            kc = mix(base, white, 0.22 + 0.12 * k)
            annular(d, *rings[1], a, a + kspan, kc, gap_deg=1.4)
            if gk:
                g = a
                for j, gshare in enumerate(gk):
                    gspan = kspan * gshare
                    annular(d, *rings[2], g, g + gspan, mix(base, white, 0.45 + 0.12 * j), gap_deg=1.4)
                    g += gspan
            a += kspan
        angle += span

    # Центр: светлый диск с тонким кольцом — «текущая папка».
    r = px(112)
    d.ellipse((C - r, C - r, C + r, C + r), fill=hex_rgb("#EEF2FF"))
    r2 = px(26)
    d.ellipse((C - r2, C - r2, C + r2, C + r2), fill=hex_rgb("#26346B"))

    img = img.resize((1024, 1024), Image.LANCZOS)
    img.save(out)
    print("saved", out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png")
