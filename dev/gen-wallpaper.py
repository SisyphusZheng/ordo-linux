#!/usr/bin/env python3
"""生成 Ordo 默认壁纸。

参数来自 docs/design：3840x2160 七层绘制。产物提交入库，
运行期只有 swaybg 读 PNG，零额外依赖。本脚本仅在构建期运行。

用法：python3 dev/gen-wallpaper.py [输出路径]
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

W, H = 3840, 2160
ACCENT = (0x33, 0xFF, 0x66)   # geek 荧光绿：也是调色板提取的主色
TEXT = (0xC8, 0xE6, 0xC8)     # TEXT
CX, CY = 2760, 900
ROT = -12.0

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

img = Image.new("RGB", (W, H), (0x0F, 0x10, 0x0F))
d = ImageDraw.Draw(img, "RGBA")

# ① 底色：垂直线性渐变 #080a08 -> #0b0e0b -> #0f100f
top, mid, bot = (0x15, 0x28, 0x15), (0x1C, 0x34, 0x1C), (0x24, 0x42, 0x24)
for y in range(H):
    t = y / (H - 1)
    c = lerp(top, mid, t / 0.55) if t < 0.55 else lerp(mid, bot, (t - 0.55) / 0.45)
    d.line([(0, y), (W, y)], fill=c)

# ② 三条全宽斜线，斜率 -0.2126，右端淡出
SLOPE = -0.2126
FADE_START, FADE_END = 1700, 3000
for y0, alpha in ((1150, 0.55), (1630, 0.48), (2110, 0.42)):
    for x in range(W):
        if x >= FADE_END:
            break
        a = alpha if x <= FADE_START else alpha * (1 - (x - FADE_START) / (FADE_END - FADE_START))
        y = int(y0 + SLOPE * x)
        if 0 <= y < H:
            d.point((x, y), fill=(ACCENT[0], ACCENT[1], ACCENT[2], int(a * 255)))

# ③ 光晕：径向，圆心 (2760,900)，r<0.6 恒定 8.5%，之后线性降到 3.0%
R = 1900
glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
# 逐圈绘制时每圈只补足"到该半径应有的累计 alpha"，避免叠加成数倍亮度
steps = 160
prev_a = 0.0
for i in range(steps, 0, -1):
    f = i / steps
    rad = int(R * f)
    target = 0.32 if f < 0.6 else 0.32 - (0.32 - 0.08) * ((f - 0.6) / 0.4)
    if target <= prev_a:
        continue
    delta = target - prev_a
    gd.ellipse([CX - rad, CY - rad, CX + rad, CY + rad],
               fill=(ACCENT[0], ACCENT[1], ACCENT[2], int(delta * 255)))
    prev_a = target
img = Image.alpha_composite(img.convert("RGBA"), glow.filter(ImageFilter.GaussianBlur(90))).convert("RGB")
d = ImageDraw.Draw(img, "RGBA")

# ④ 七层同心椭圆，旋转 -12°，短半轴 = 长半轴 x 0.36
RINGS = [
    (323, 2.0, 0.85), (453, 2.0, 0.70), (618, 1.5, 0.55),
    (806, 1.0, 0.42), (1805, 1.0, 0.32), (2688, 1.0, 0.26), (3610, 1.0, 0.20),
]
ring_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
rd = ImageDraw.Draw(ring_layer)
for rx, width, alpha in RINGS:
    ry = rx * 0.36
    # 在独立图层上画正椭圆，再整体旋转
    box = [CX - rx, CY - ry, CX + rx, CY + ry]
    rd.ellipse(box, outline=(ACCENT[0], ACCENT[1], ACCENT[2], int(alpha * 255)),
               width=max(1, int(width)))
ring_layer = ring_layer.rotate(ROT, center=(CX, CY), resample=Image.BICUBIC)
img = Image.alpha_composite(img.convert("RGBA"), ring_layer).convert("RGB")
d = ImageDraw.Draw(img, "RGBA")

# ⑤ 地平线：y=1580，左右两段，中央留 1520px 缺口
for x0, x1 in ((300, 1240), (2760, 3540)):
    d.line([(x0, 1580), (x1, 1580)], fill=(TEXT[0], TEXT[1], TEXT[2], int(0.22 * 255)), width=1)

# ⑥ 竖向刻度：x in {300,430,560}，y in [1200,1700]
for x in (300, 430, 560):
    d.line([(x, 1200), (x, 1700)], fill=(ACCENT[0], ACCENT[1], ACCENT[2], int(0.20 * 255)), width=1)

# ⑦ 暗角：r<0.55R 为 0，到 1.0R 线性到 12% 纯黑
VR = 2380
vig = Image.new("L", (W, H), 0)
vp = vig.load()
vcx, vcy = W // 2, H // 2
for y in range(0, H, 2):
    for x in range(0, W, 2):
        dist = ((x - vcx) ** 2 + (y - vcy) ** 2) ** 0.5 / VR
        if dist <= 0.55:
            v = 0
        else:
            v = min(1.0, (dist - 0.55) / 0.45) * 0.12 * 255
        v = int(v)
        vp[x, y] = v
        if x + 1 < W:
            vp[x + 1, y] = v
        if y + 1 < H:
            vp[x, y + 1] = v
            if x + 1 < W:
                vp[x + 1, y + 1] = v
vig = vig.filter(ImageFilter.GaussianBlur(40))
img = Image.composite(Image.new("RGB", (W, H), (0, 0, 0)), img, vig)

out = sys.argv[1] if len(sys.argv) > 1 else "config/desktop/wallpapers/wallpaper-seven.png"
img.save(out, optimize=True)
print(f"saved {out} {img.size}")
