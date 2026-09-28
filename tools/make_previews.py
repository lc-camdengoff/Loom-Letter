#!/usr/bin/env python3
"""
Loom Letter - preview card generator.

Draws the stylised preview cards the panel shows for each preset (640x360 PNGs in
Fusion/LoomLetter/previews). They are illustrations of the motion, not renders. To use a
real frame instead, export a still from Resolve and save it over the matching file.

    pip install pillow
    python3 tools/make_previews.py [--font /path/to/Bold.ttf]
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Fusion" / "LoomLetter" / "previews"
W, H = 640, 360
SS = 2  # supersampling factor

FONT_CANDIDATES = {
    "bold": [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
        "C:/Windows/Fonts/arialbd.ttf",
    ],
    "regular": [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
        "C:/Windows/Fonts/arial.ttf",
    ],
    "mono": [
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/System/Library/Fonts/Supplemental/Courier New.ttf",
        "C:/Windows/Fonts/cour.ttf",
    ],
}

ACCENT = (245, 179, 0)


def find_font(kind: str, override: str | None) -> str:
    if override and kind == "bold":
        return override
    for c in FONT_CANDIDATES[kind]:
        if Path(c).exists():
            return c
    raise SystemExit(f"no {kind} font found; pass --font")


class Card:
    def __init__(self, fonts):
        self.fonts = fonts
        self.img = Image.new("RGBA", (W * SS, H * SS))
        self._background()

    def font(self, kind, size):
        return ImageFont.truetype(self.fonts[kind], int(size * SS))

    def _background(self):
        top, bottom = (24, 26, 33), (38, 41, 52)
        d = ImageDraw.Draw(self.img)
        for y in range(H * SS):
            t = y / (H * SS)
            d.line([(0, y), (W * SS, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))

    def layer(self):
        return Image.new("RGBA", self.img.size, (0, 0, 0, 0))

    def paste(self, layer, alpha=1.0, blur=0.0):
        if blur:
            layer = layer.filter(ImageFilter.GaussianBlur(blur * SS))
        if alpha < 1:
            a = layer.getchannel("A").point(lambda v: int(v * alpha))
            layer.putalpha(a)
        self.img = Image.alpha_composite(self.img, layer)

    def text(self, s, cx, cy, size, kind="bold", fill=(255, 255, 255), alpha=1.0, blur=0.0,
             spacing=0.0, anchor="mm", scale=1.0):
        layer = self.layer()
        d = ImageDraw.Draw(layer)
        f = self.font(kind, size * scale)
        if spacing:
            # manual letter spacing
            widths = [d.textlength(ch, font=f) for ch in s]
            total = sum(widths) + spacing * SS * (len(s) - 1)
            x = cx * SS - total / 2 if anchor[0] == "m" else cx * SS
            for ch, w in zip(s, widths):
                d.text((x, cy * SS), ch, font=f, fill=fill + (255,), anchor="l" + anchor[1])
                x += w + spacing * SS
        else:
            d.text((cx * SS, cy * SS), s, font=f, fill=fill + (255,), anchor=anchor)
        self.paste(layer, alpha, blur)

    def rect(self, box, fill, alpha=1.0, blur=0.0, radius=0):
        layer = self.layer()
        d = ImageDraw.Draw(layer)
        x0, y0, x1, y1 = (v * SS for v in box)
        d.rounded_rectangle((x0, y0, x1, y1), radius=radius * SS, fill=fill + (255,))
        self.paste(layer, alpha, blur)

    def draw(self):
        return ImageDraw.Draw(self.img)

    def save(self, name):
        OUT.mkdir(parents=True, exist_ok=True)
        out = self.img.resize((W, H), Image.LANCZOS).convert("RGB")
        out.save(OUT / name, optimize=True)
        print(f"wrote {(OUT / name).relative_to(ROOT)}")


# ------------------------------------------------------------------------------------------
# Titles
# ------------------------------------------------------------------------------------------

def title_slide_up(c: Card):
    for i, (dy, a) in enumerate([(54, 0.10), (34, 0.18), (16, 0.35)]):
        c.text("YOUR TITLE", 320, 180 + dy, 52, alpha=a, blur=1.5)
    c.text("YOUR TITLE", 320, 180, 52)
    d = c.draw()
    x = 320 * SS
    d.line([(x, 262 * SS), (x, 236 * SS)], fill=ACCENT + (255,), width=3 * SS)
    d.polygon([(x - 8 * SS, 240 * SS), (x + 8 * SS, 240 * SS), (x, 228 * SS)], fill=ACCENT + (255,))


def title_blur_in(c: Card):
    c.text("YOUR TITLE", 320, 180, 52, alpha=0.5, blur=10, scale=1.15)
    c.text("YOUR TITLE", 320, 180, 52, alpha=0.6, blur=3, scale=1.05)
    c.text("YOUR TITLE", 320, 180, 52)


def title_pop(c: Card):
    c.text("POP!", 320, 180, 96, fill=ACCENT, alpha=0.18, scale=1.3, blur=6)
    c.text("POP!", 320, 180, 96, fill=ACCENT)
    d = c.draw()
    for ang in range(0, 360, 45):
        r0, r1 = 118, 138
        a = math.radians(ang + 22.5)
        d.line([(320 * SS + r0 * SS * math.cos(a), 180 * SS + r0 * SS * math.sin(a) * 0.62),
                (320 * SS + r1 * SS * math.cos(a), 180 * SS + r1 * SS * math.sin(a) * 0.62)],
               fill=(255, 255, 255, 200), width=3 * SS)


def title_tracking(c: Card):
    c.text("CINEMATIC", 320, 180, 40, kind="regular", spacing=24, alpha=0.16, blur=4)
    c.text("CINEMATIC", 320, 180, 40, kind="regular", spacing=16)
    d = c.draw()
    for x0, x1 in ((56, 92), (584, 548)):
        d.line([(x0 * SS, 180 * SS), (x1 * SS, 180 * SS)], fill=ACCENT + (255,), width=3 * SS)
        tip = x1 * SS
        back = (x1 + (12 if x1 < x0 else -12)) * SS
        d.polygon([(tip, 180 * SS), (back, 172 * SS), (back, 188 * SS)], fill=ACCENT + (255,))


def title_typewriter(c: Card):
    c.text("Type your mess", 110, 180, 36, kind="mono", anchor="lm")
    f = c.font("mono", 36)
    d = c.draw()
    w = d.textlength("Type your mess", font=f) / SS
    c.rect((110 + w + 4, 162, 110 + w + 24, 198), (255, 255, 255))


def title_lower_third(c: Card):
    # a hint of footage behind the lower third
    c.rect((0, 0, W, H), (70, 90, 120), alpha=0.25)
    c.rect((56, 262, 59, 318), ACCENT)
    c.text("JANE DOE", 72, 276, 30, anchor="lm")
    c.text("Title / Role", 72, 306, 20, kind="regular", fill=(215, 215, 215), anchor="lm")


# ------------------------------------------------------------------------------------------
# Cut transitions: frame A on the left, frame B on the right, effect on the seam
# ------------------------------------------------------------------------------------------

def two_frames(c: Card, split=320):
    a = Image.new("RGBA", c.img.size)
    b = Image.new("RGBA", c.img.size)
    da, db = ImageDraw.Draw(a), ImageDraw.Draw(b)
    for x in range(W * SS):
        t = x / (W * SS)
        da.line([(x, 0), (x, H * SS)], fill=(int(214 - 60 * t), int(120 - 30 * t), int(70 + 20 * t), 255))
        db.line([(x, 0), (x, H * SS)], fill=(int(40 + 30 * t), int(110 + 50 * t), int(180 + 40 * t), 255))
    mask = Image.new("L", c.img.size, 0)
    ImageDraw.Draw(mask).polygon([(0, 0), ((split + 40) * SS, 0), ((split - 40) * SS, H * SS), (0, H * SS)], fill=255)
    frame = Image.composite(a, b, mask)
    inset = Image.new("L", c.img.size, 0)
    ImageDraw.Draw(inset).rounded_rectangle((40 * SS, 40 * SS, (W - 40) * SS, (H - 40) * SS), radius=14 * SS, fill=255)
    c.img = Image.composite(frame, c.img, inset)
    c.text("A", 150, 180, 64, alpha=0.55)
    c.text("B", 490, 180, 64, alpha=0.55)


def cut_zoom(c: Card, inward=True):
    """Zoom In: frames and arrows grow outward. Zoom Out: they converge on the centre."""
    two_frames(c)
    d = c.draw()
    cx, cy = 320 * SS, 180 * SS
    for s in [0.3, 0.55, 0.8]:
        w, h = 280 * s, 140 * s
        d.rounded_rectangle((cx - w * SS, cy - h * SS, cx + w * SS, cy + h * SS), radius=8 * SS,
                            outline=(255, 255, 255, 150), width=3 * SS)
    for i in range(8):
        a = math.radians(i * 45 + 22.5)
        ux, uy = math.cos(a), math.sin(a) * 0.55
        r0, r1 = 70, 150
        p0 = (cx + r0 * SS * ux, cy + r0 * SS * uy)
        p1 = (cx + r1 * SS * ux, cy + r1 * SS * uy)
        d.line([p0, p1], fill=(255, 255, 255, 235), width=4 * SS)
        tip, back = (p1, p0) if inward else (p0, p1)
        dx, dy = tip[0] - back[0], tip[1] - back[1]
        n = math.hypot(dx, dy) or 1
        dx, dy = dx / n, dy / n
        size = 14 * SS
        left = (tip[0] - dx * size - dy * size * 0.6, tip[1] - dy * size + dx * size * 0.6)
        right = (tip[0] - dx * size + dy * size * 0.6, tip[1] - dy * size - dx * size * 0.6)
        d.polygon([tip, left, right], fill=(255, 255, 255, 235))


def cut_whip(c: Card):
    two_frames(c)
    layer = c.layer()
    d = ImageDraw.Draw(layer)
    for i, y in enumerate(range(70, 300, 18)):
        x0 = 120 + (i * 37) % 90
        d.line([(x0 * SS, y * SS), ((x0 + 330) * SS, y * SS)], fill=(255, 255, 255, 140), width=3 * SS)
    c.paste(layer, blur=2.5)
    d = c.draw()
    d.polygon([(290 * SS, 180 * SS), (330 * SS, 156 * SS), (330 * SS, 204 * SS)], fill=(255, 255, 255, 235))


def cut_spin(c: Card):
    two_frames(c)
    d = c.draw()
    cx, cy, r = 320 * SS, 180 * SS, 110 * SS
    d.arc((cx - r, cy - r, cx + r, cy + r), start=200, end=520, fill=(255, 255, 255, 220), width=5 * SS)
    a = math.radians(520 - 360)
    tip = (cx + r * math.cos(a), cy + r * math.sin(a))
    d.polygon([tip, (tip[0] - 26 * SS, tip[1] - 6 * SS), (tip[0] - 8 * SS, tip[1] - 26 * SS)], fill=(255, 255, 255, 230))


def cut_flash(c: Card):
    two_frames(c)
    layer = c.layer()
    d = ImageDraw.Draw(layer)
    d.ellipse((200 * SS, 70 * SS, 440 * SS, 290 * SS), fill=(255, 255, 255, 255))
    c.paste(layer, alpha=0.9, blur=40)
    layer = c.layer()
    d = ImageDraw.Draw(layer)
    d.ellipse((270 * SS, 130 * SS, 370 * SS, 230 * SS), fill=(255, 255, 255, 255))
    c.paste(layer, blur=14)


def cut_blur(c: Card):
    two_frames(c)
    seam = c.img.crop((200 * SS, 40 * SS, 440 * SS, (H - 40) * SS)).filter(ImageFilter.GaussianBlur(18 * SS))
    mask = Image.new("L", seam.size, 0)
    md = ImageDraw.Draw(mask)
    for x in range(seam.size[0]):
        t = 1 - abs(x / seam.size[0] - 0.5) * 2
        md.line([(x, 0), (x, seam.size[1])], fill=int(255 * min(1, t * 1.6)))
    c.img.paste(seam, (200 * SS, 40 * SS), mask)
    layer = c.layer()
    d = ImageDraw.Draw(layer)
    for x, y, r in ((270, 120, 26), (340, 210, 34), (300, 250, 18), (365, 130, 20)):
        d.ellipse(((x - r) * SS, (y - r) * SS, (x + r) * SS, (y + r) * SS), fill=(255, 255, 255, 255))
    c.paste(layer, alpha=0.28, blur=3)



# ------------------------------------------------------------------------------------------
# Library presets
# ------------------------------------------------------------------------------------------

RED = (220, 30, 30)
BLUE = (30, 140, 250)
DARKC = (20, 20, 26)


def outline(c, box, color, width=3, radius=0):
    d = c.draw()
    d.rounded_rectangle(tuple(v * SS for v in box), radius=radius * SS, outline=color + (255,), width=width * SS)


def text_width(c, s, size, kind="bold"):
    return c.draw().textlength(s, font=c.font(kind, size)) / SS


def pill(c, cx, cy, w, h, color, alpha=1.0):
    c.rect((cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2), color, alpha=alpha, radius=h / 2)


def ellipse(c, cx, cy, r, fill=None, outline_color=None, width=3, alpha=1.0, blur=0.0):
    layer = c.layer()
    d = ImageDraw.Draw(layer)
    box = ((cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS)
    if fill:
        d.ellipse(box, fill=fill + (255,))
    if outline_color:
        d.ellipse(box, outline=outline_color + (255,), width=int(width * SS))
    c.paste(layer, alpha, blur)


def title_boxed_title(c):
    w = text_width(c, "MOTION GRAPHICS", 40) + 48
    outline(c, (320 - w / 2, 150, 320 + w / 2, 210), ACCENT, 3)
    c.text("MOTION GRAPHICS", 320, 180, 40)
    c.rect((250, 200, 390, 222), ACCENT, radius=3)
    c.text("WITHOUT HASSLE", 320, 211, 13, fill=DARKC)


def title_tag_title(c):
    c.rect((245, 132, 395, 156), ACCENT, radius=3)
    c.text("WITHOUT HASSLE", 320, 144, 14, fill=DARKC)
    c.text("MOTION GRAPHICS", 320, 190, 44)


def title_split_word(c):
    c.text("MISTER", 310, 180, 50, fill=ACCENT, anchor="rm")
    c.rect((318, 150, 322, 210), (255, 255, 255))
    c.text("HORSE", 330, 180, 50, anchor="lm")


def title_underline(c):
    c.text("POWERFUL WORKFLOW", 320, 170, 40)
    c.rect((150, 204, 490, 211), ACCENT, radius=3)


def social_button(c, label, color):
    w = text_width(c, label, 28) + 80
    pill(c, 320, 180, w, 60, color)
    c.text(label, 320, 180, 28)
    d = c.draw()
    x, y = (320 + w / 2 - 30) * SS, 196 * SS
    d.polygon([(x, y), (x, y + 34 * SS), (x + 9 * SS, y + 26 * SS), (x + 16 * SS, y + 40 * SS),
               (x + 22 * SS, y + 37 * SS), (x + 15 * SS, y + 24 * SS), (x + 26 * SS, y + 24 * SS)],
              fill=(255, 255, 255, 255), outline=(0, 0, 0, 255))


def title_handle(c):
    pill(c, 320, 180, 300, 56, (255, 255, 255))
    ellipse(c, 200, 180, 18, fill=ACCENT)
    c.text("@yourname", 232, 180, 26, fill=DARKC, anchor="lm")


def title_chat_bubble(c):
    d = c.draw()
    d.polygon([(232 * SS, 196 * SS), (222 * SS, 222 * SS), (256 * SS, 204 * SS)], fill=(255, 255, 255, 255))
    pill(c, 320, 180, 220, 58, (255, 255, 255))
    c.text("What's up?", 320, 180, 26, kind="regular", fill=DARKC)
    pill(c, 420, 110, 90, 40, (140, 60, 230))
    c.text("Hey!", 420, 110, 18)


def title_counter(c):
    c.text("$38,458", 320, 180, 76)


def title_countdown(c):
    c.rect((215, 130, 425, 230), (30, 30, 36), radius=18)
    c.text("00:05", 320, 172, 56)
    c.rect((255, 208, 385, 212), (80, 80, 88), radius=2)
    c.rect((255, 208, 330, 212), ACCENT, radius=2)


def title_progress_bar(c):
    c.text("1980 VOTES", 160, 150, 20, anchor="lm")
    c.text("80%", 480, 150, 20, anchor="rm")
    c.rect((160, 170, 480, 186), (70, 70, 80), radius=8)
    c.rect((160, 170, 416, 186), ACCENT, radius=8)


def title_bar_stat(c):
    c.rect((230, 110, 270, 250), (60, 60, 70), radius=2)
    c.rect((230, 138, 270, 250), (25, 190, 230), radius=2)
    c.text("80%", 292, 176, 64, anchor="lm")
    c.text("YOUR TITLE", 294, 228, 20, anchor="lm")


def title_glow(c):
    c.text("HORSE OF STEEL", 320, 180, 40, kind="regular", spacing=10, fill=(255, 230, 190), alpha=0.9, blur=14)
    c.text("HORSE OF STEEL", 320, 180, 40, kind="regular", spacing=10)


def title_credits(c):
    c.text("Created by", 320, 146, 18, kind="regular", fill=(200, 200, 200))
    c.text("Mister Horse", 320, 188, 48, kind="regular")


def title_flicker(c):
    word = "PARADOX"
    f = c.font("regular", 58)
    widths = [c.draw().textlength(ch, font=f) / SS + 16 for ch in word]
    x = 320 - sum(widths) / 2
    for i, (ch, w) in enumerate(zip(word, widths)):
        a = 0.15 if i in (1, 4) else 1.0
        c.text(ch, x + w / 2, 180, 58, kind="regular", alpha=a)
        if a == 1.0:
            c.text(ch, x + w / 2, 180, 58, kind="regular", alpha=0.5, blur=8)
        x += w


def title_converge(c):
    c.text("GRAND TITLES", 320, 150, 46, alpha=0.2, blur=3)
    c.text("GRAND TITLES", 320, 210, 46, alpha=0.2, blur=3)
    c.rect((170, 179, 470, 181), ACCENT)
    c.text("GRAND TITLES", 320, 180, 46)


def title_ring_burst(c):
    ellipse(c, 320, 180, 110, outline_color=(255, 255, 255), width=2, alpha=0.35)
    ellipse(c, 320, 180, 78, outline_color=(255, 255, 255), width=6, alpha=0.75)
    ellipse(c, 320, 180, 44, outline_color=(255, 255, 255), width=12)


def title_sparkle(c):
    layer = c.layer()
    d = ImageDraw.Draw(layer)
    for cx, cy, r in ((320, 180, 80), (430, 120, 30), (220, 245, 22)):
        pts = []
        for i in range(8):
            ang = math.radians(i * 45 - 90)
            rr = r if i % 2 == 0 else r * 0.16
            pts.append(((cx + rr * math.cos(ang)) * SS, (cy + rr * math.sin(ang)) * SS))
        d.polygon(pts, fill=(255, 255, 255, 255))
    c.paste(layer, 0.6, blur=6)
    c.paste(layer)


def title_speed_lines(c):
    d = c.draw()
    for i, (x, y, ln) in enumerate(((150, 130, 180), (230, 165, 240), (190, 205, 150), (290, 240, 200))):
        col = ACCENT if i % 2 == 0 else (255, 255, 255)
        d.line([(x * SS, y * SS), ((x + ln) * SS, (y + ln * 0.25) * SS)], fill=col + (255,), width=6 * SS)


def title_circle_pop(c):
    ellipse(c, 320, 180, 100, outline_color=(255, 255, 255), width=4, alpha=0.6)
    ellipse(c, 320, 180, 56, fill=ACCENT)


LIBRARY_PREVIEWS = {
    "title-boxed-title.png": title_boxed_title,
    "title-tag-title.png": title_tag_title,
    "title-split-word.png": title_split_word,
    "title-underline.png": title_underline,
    "title-subscribe.png": lambda c: social_button(c, "SUBSCRIBE", RED),
    "title-follow.png": lambda c: social_button(c, "+  FOLLOW", BLUE),
    "title-handle.png": title_handle,
    "title-chat-bubble.png": title_chat_bubble,
    "title-counter.png": title_counter,
    "title-countdown.png": title_countdown,
    "title-progress-bar.png": title_progress_bar,
    "title-bar-stat.png": title_bar_stat,
    "title-glow.png": title_glow,
    "title-credits.png": title_credits,
    "title-flicker.png": title_flicker,
    "title-converge.png": title_converge,
    "title-ring-burst.png": title_ring_burst,
    "title-sparkle.png": title_sparkle,
    "title-speed-lines.png": title_speed_lines,
    "title-circle-pop.png": title_circle_pop,
}

PREVIEWS = {
    "title-slide-up.png": title_slide_up,
    "title-blur-in.png": title_blur_in,
    "title-pop.png": title_pop,
    "title-tracking.png": title_tracking,
    "title-typewriter.png": title_typewriter,
    "title-lower-third.png": title_lower_third,
    "cut-zoom-in.png": lambda c: cut_zoom(c, True),
    "cut-zoom-out.png": lambda c: cut_zoom(c, False),
    "cut-whip.png": cut_whip,
    "cut-spin.png": cut_spin,
    "cut-flash.png": cut_flash,
    "cut-blur.png": cut_blur,
}
PREVIEWS.update(LIBRARY_PREVIEWS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", help="bold TTF to use for titles")
    args = ap.parse_args()
    fonts = {k: find_font(k, args.font) for k in FONT_CANDIDATES}
    for name, draw in PREVIEWS.items():
        card = Card(fonts)
        draw(card)
        card.save(name)
    contact_sheet()


def contact_sheet():
    """docs/presets.png: every card on one image for the README."""
    cols, tw, th, gap = 6, 320, 180, 12
    names = list(PREVIEWS)
    rows = math.ceil(len(names) / cols)
    sheet = Image.new("RGB", (cols * tw + (cols + 1) * gap, rows * th + (rows + 1) * gap), (12, 13, 17))
    for i, name in enumerate(names):
        im = Image.open(OUT / name).resize((tw, th), Image.LANCZOS)
        sheet.paste(im, (gap + (i % cols) * (tw + gap), gap + (i // cols) * (th + gap)))
    path = ROOT / "docs" / "presets.png"
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(path, optimize=True)
    print(f"wrote {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
