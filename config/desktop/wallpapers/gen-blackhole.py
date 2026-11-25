#!/usr/bin/env python3
"""生成「黑洞星环」壁纸 —— 复刻 noctalia v5 介绍视频（BV1suMc6vEam）的视觉基调。

为什么用脚本而不是直接收一张图：视频原图版权不明，且「一切皆文件」——
参数化的生成脚本可 diff、可回滚、可复现，改审美等于改参数。

要素（对照视频 t=445s / t=733s 帧）：
  深紫黑渐变底 + 星场、黑洞（纯黑圆 + 紫晕）、
  奶油色星环带彩虹渐变边缘（后半在球后、前半在球前）、
  灰紫色陨石坑小行星（部分景深模糊）、右下大行星弧。

用法：python3 gen-blackhole.py > 输出路径缺省 wallpaper-blackhole.png
"""

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
OUT = HERE / "wallpaper-blackhole.png"
OUT_RING = HERE / "deco-ring.png"  # 桌面 sticker 装饰（粉色圆环，对应视频里的贴纸）

# ---- 画布：用户 VM 输出为 2560x1440，2x 超采样保证环带渐变平滑 ----
W, H = 2560, 1440
SS = 2
CW, CH = W * SS, H * SS

random.seed(7)  # 星场与小行星布局可复现

# ---- 调色板（从视频帧取样）----
BG_TOP = (0x18, 0x12, 0x22)
BG_BOT = (0x0a, 0x08, 0x12)
RING_CREAM = (0xF2, 0xE7, 0xC8)
RING_PINK = (0xEC, 0xC4, 0xD6)
RING_MINT = (0xC9, 0xDF, 0xD3)
RIM_GREEN = (0x9F, 0xE8, 0x82)
RIM_PINK = (0xF2, 0x9E, 0xC9)
RIM_CYAN = (0x9F, 0xE0, 0xDC)
GLOW_VIOLET = (0x8F, 0x7B, 0xB8)
ASTEROID = (0x93, 0x8A, 0xA4)
ASTEROID_DARK = (0x5F, 0x58, 0x74)
ASTEROID_PINK = (0xE3, 0xA6, 0xC6)

HOLE_XY = (1280, 880)  # 黑洞中心
HOLE_R = 225
RING_A, RING_B = 590, 165  # 环椭圆半轴
RING_TILT = -8  # 环倾角（度）
RING_WIDTH = 88


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ring_color(t):
    """沿环参数角的奶油为主、粉/薄荷轻扫的柔和渐变。"""
    seg = t * 3.0 % 3.0
    if seg < 1:
        return lerp(RING_CREAM, RING_PINK, seg * 0.5)
    if seg < 2:
        return lerp(RING_PINK, RING_MINT, (seg - 1) * 0.5)
    return lerp(RING_MINT, RING_CREAM, (seg - 2) * 0.5)


def rim_color(t):
    """彩虹细边：绿→粉→青连续循环。"""
    seg = t * 3.0 % 3.0
    if seg < 1:
        return lerp(RIM_GREEN, RIM_PINK, seg)
    if seg < 2:
        return lerp(RIM_PINK, RIM_CYAN, seg - 1)
    return lerp(RIM_CYAN, RIM_GREEN, seg - 2)


def background():
    """径向渐变底 + 顶部微亮。"""
    img = Image.new("RGB", (CW, CH), BG_BOT)
    dr = ImageDraw.Draw(img)
    cx, cy = int(CW * 0.5), int(CH * 0.62)
    maxd = math.hypot(cx, cy)
    for y in range(0, CH, 4):
        for x in range(0, CW, 4):
            d = math.hypot(x - cx, y - cy) / maxd
            c = lerp(BG_TOP, BG_BOT, min(1.0, d * 1.15))
            dr.rectangle([x, y, x + 4, y + 4], fill=c)
    return img


def stars(img):
    dr = ImageDraw.Draw(img, "RGBA")
    for _ in range(780):
        x, y = random.randrange(CW), random.randrange(CH)
        r = random.choice([1, 1, 1, 2, 2, 3]) * SS
        a = random.randrange(40, 190)
        tint = random.choice([(255, 255, 255), (230, 215, 255), (255, 210, 235)])
        dr.ellipse([x - r, y - r, x + r, y + r], fill=tint + (a,))
    # 几颗带晕的亮星
    for _ in range(14):
        x, y = random.randrange(CW), random.randrange(CH)
        r = random.choice([4, 5, 6]) * SS
        dr.ellipse([x - r * 2, y - r * 2, x + r * 2, y + r * 2], fill=(200, 190, 255, 36))
        dr.ellipse([x - r, y - r, x + r, y + r], fill=(255, 250, 240, 210))


def ring_layer(front_only):
    """星环。front_only=False 画完整环（球后层），True 只画椭圆下半（球前层）。"""
    layer = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    dr = ImageDraw.Draw(layer)
    cx, cy = HOLE_XY[0] * SS, HOLE_XY[1] * SS
    tilt = math.radians(RING_TILT)
    steps = 720

    def pt(a, off):
        """椭圆路径点：off 为沿法向（半轴向外）的偏移。"""
        ex = (RING_A * SS + off) * math.cos(a)
        ey = (RING_B * SS + off) * math.sin(a)
        return (cx + ex * math.cos(tilt) - ey * math.sin(tilt),
                cy + ex * math.sin(tilt) + ey * math.cos(tilt))

    def band(off, width, color_fn, alpha):
        w = width * SS / 2
        for i in range(steps):
            t = i / steps
            ang = t * 2 * math.pi
            # 下半（sin>0）在球前：后半层只画上半，前半层只画下半
            if front_only != (math.sin(ang) > 0):
                continue
            px, py = pt(ang, off)
            c = color_fn(t)
            dr.ellipse([px - w, py - w, px + w, py + w], fill=c + (alpha,))

    band(0, RING_WIDTH, ring_color, 225)          # 奶油主体（半透明，让底层晕透出来）
    band(RING_WIDTH / 2 + 5, 7, rim_color, 235)   # 外缘彩虹细边
    band(-RING_WIDTH / 2 - 5, 7, rim_color, 200)  # 内缘彩虹细边
    return layer.filter(ImageFilter.GaussianBlur(2 * SS))


def glow(img):
    """黑洞周围的紫晕（最底层）。"""
    layer = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    dr = ImageDraw.Draw(layer)
    cx, cy = HOLE_XY[0] * SS, HOLE_XY[1] * SS
    for r, a in ((560, 60), (420, 90), (300, 130)):
        dr.ellipse([cx - r * SS, cy - r * SS * 0.8, cx + r * SS, cy + r * SS * 0.8],
                   fill=GLOW_VIOLET + (a,))
    layer = layer.filter(ImageFilter.GaussianBlur(120 * SS))
    img.paste(Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB"), (0, 0))


def hole(img):
    dr = ImageDraw.Draw(img)
    cx, cy = HOLE_XY[0] * SS, HOLE_XY[1] * SS
    r = HOLE_R * SS
    dr.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(2, 1, 4))


def asteroid(dr, x, y, r, pink=False):
    """土豆形小行星：主椭圆 + 两个偏移椭圆合并，再点陨石坑。"""
    c = ASTEROID_PINK if pink else ASTEROID
    dark = lerp(ASTEROID_PINK, (0x6A, 0x40, 0x58), 0.45) if pink else ASTEROID_DARK
    blobs = [(-r * 0.25, -r * 0.15, r * 0.85), (r * 0.3, r * 0.1, r * 0.7), (0, r * 0.25, r * 0.75)]
    for dx, dy, br in blobs:
        dr.ellipse([(x + dx - br) * SS, (y + dy - br * 0.85) * SS,
                    (x + dx + br) * SS, (y + dy + br * 0.85) * SS], fill=c)
    for _ in range(random.randint(3, 6)):
        crx = x + random.uniform(-r * 0.5, r * 0.5)
        cry = y + random.uniform(-r * 0.4, r * 0.4)
        cr = random.uniform(r * 0.12, r * 0.3)
        dr.ellipse([(crx - cr) * SS, (cry - cr * 0.8) * SS,
                    (crx + cr) * SS, (cry + cr * 0.8) * SS], fill=dark)


def asteroids(img):
    dr = ImageDraw.Draw(img, "RGBA")
    # (x, y, r, 粉色?, 模糊级) —— 避开中央黑洞；布局对照视频帧
    field = [
        (330, 260, 95, False, 1), (520, 170, 55, False, 2), (205, 520, 70, True, 1),
        (700, 360, 40, False, 0), (2150, 310, 80, False, 1), (1930, 190, 45, True, 2),
        (2380, 620, 60, False, 0), (250, 1150, 65, False, 2), (430, 1330, 88, False, 1),
        (1490, 290, 28, False, 0), (1720, 150, 22, True, 1), (2210, 920, 36, False, 0),
        (950, 210, 30, False, 1), (1860, 770, 26, True, 0), (380, 830, 46, False, 1),
        (2050, 1180, 48, False, 2),
    ]
    for x, y, r, pink, blur in field:
        tile = Image.new("RGBA", (int(r * 3.2 * SS), int(r * 3.2 * SS)), (0, 0, 0, 0))
        td = ImageDraw.Draw(tile)
        asteroid(td, r * 1.6, r * 1.6, r, pink)
        if blur:
            tile = tile.filter(ImageFilter.GaussianBlur(blur * SS))
        img.paste(tile.convert("RGB"), (int(x * SS - tile.width / 2), int(y * SS - tile.height / 2)),
                  tile.split()[3])
    # 右下角大行星弧（大部分出画）
    px, py, pr = 2530, 1690, 540
    tile = Image.new("RGBA", (int(pr * 2.4 * SS), int(pr * 2.4 * SS)), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    td.ellipse([(pr * 1.2 - pr) * SS, (pr * 1.2 - pr) * SS,
                (pr * 1.2 + pr) * SS, (pr * 1.2 + pr) * SS], fill=(0x7C, 0x74, 0x92))
    for _ in range(8):
        crx = pr * 1.2 + random.uniform(-pr * 0.6, pr * 0.6)
        cry = pr * 1.2 + random.uniform(-pr * 0.6, pr * 0.6)
        cr = random.uniform(pr * 0.08, pr * 0.16)
        td.ellipse([(crx - cr) * SS, (cry - cr) * SS, (crx + cr) * SS, (cry + cr) * SS],
                   fill=(0x5A, 0x53, 0x72))
    img.paste(tile.convert("RGB"), (int(px * SS - tile.width / 2), int(py * SS - tile.height / 2)),
              tile.split()[3])


def grain(img):
    """轻微胶片噪点，避免大面积渐变出现色带。"""
    noise = Image.effect_noise((CW, CH), 14).convert("L")
    img = Image.composite(img.point(lambda v: min(255, v + 6)), img, noise.point(lambda v: 8 if v > 128 else 0))
    return img


def ring_sticker():
    """粉色圆环贴纸（透明底 600x600），对应视频桌面左侧的装饰 sticker。"""
    S = 600 * SS
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dr = ImageDraw.Draw(layer)
    c = S / 2
    r_band = 190 * SS   # 环中心半径
    w = 46 * SS         # 带宽
    steps = 360
    # 先铺彩虹细边（点半径大一圈，垫在底层当外缘），再铺奶油主体
    for i in range(steps):
        t = i / steps
        ang = t * 2 * math.pi
        px, py = c + r_band * math.cos(ang), c + r_band * math.sin(ang)
        rr = w / 2 + 4 * SS
        dr.ellipse([px - rr, py - rr, px + rr, py + rr], fill=rim_color(t) + (240,))
    for i in range(steps):
        t = i / steps
        ang = t * 2 * math.pi
        px, py = c + r_band * math.cos(ang), c + r_band * math.sin(ang)
        rr = w / 2
        dr.ellipse([px - rr, py - rr, px + rr, py + rr], fill=ring_color(t) + (235,))
    layer = layer.filter(ImageFilter.GaussianBlur(1.5 * SS))
    layer = layer.resize((600, 600), Image.LANCZOS)
    layer.save(OUT_RING, "PNG")
    print(f"OK {OUT_RING} 600x600")


def main():
    img = background()
    stars(img)
    glow(img)
    img.paste(Image.alpha_composite(img.convert("RGBA"), ring_layer(False)).convert("RGB"), (0, 0))
    hole(img)
    img.paste(Image.alpha_composite(img.convert("RGBA"), ring_layer(True)).convert("RGB"), (0, 0))
    asteroids(img)
    img = grain(img)
    img = img.resize((W, H), Image.LANCZOS)
    img.save(OUT, "PNG")
    print(f"OK {OUT} {W}x{H}")
    ring_sticker()


if __name__ == "__main__":
    main()
