#!/bin/sh
# 生成 Ordo 品牌资产（logo / wallpaper / fastfetch）
# 纯 POSIX sh + 无外部依赖（除可选 ImageMagick）

set -eu
OUT="${1:-assets}"
mkdir -p "$OUT"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# ---------- 1. ASCII logo（fastfetch 用） ----------
say "生成 ASCII logo"
cat > "$OUT/ordo-ascii.txt" << 'EOF'
                    ▄▄▄▄▄▄▄▄
                 ▄██████████████▄
              ▄████████████████████▄
            ▄████████▀▀    ▀▀████████▄
           ████████▀          ▀████████
          ████████     ▄▄▄▄     ████████
         ████████     ██████     ████████
         ████████     ██████     ████████
          ████████     ▀▀▀▀     ████████
           ████████▄          ▄████████
            ▀████████▄▄    ▄▄████████▀
              ▀████████████████████▀
                 ▀██████████████▀
                    ▀▀▀▀▀▀▀▀

                    O R D O
               ordo ab chao
EOF

# ---------- 2. fastfetch 配置 ----------
say "生成 fastfetch 配置"
cat > "$OUT/fastfetch.jsonc" << 'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "/usr/share/ordo/logo.txt",
    "padding": { "top": 1, "left": 2 },
    "color": { "1": "cyan", "2": "blue" }
  },
  "display": {
    "separator": "  ",
    "color": { "keys": "cyan", "title": "blue" }
  },
  "modules": [
    "title",
    "separator",
    "os",
    "host",
    "kernel",
    "uptime",
    "packages",
    "shell",
    "wm",
    "de",
    "terminal",
    "cpu",
    "gpu",
    "memory",
    "disk",
    "localip",
    "break",
    "colors"
  ]
}
EOF

# ---------- 3. wallpaper（SVG，可缩放） ----------
say "生成 wallpaper"
cat > "$OUT/ordo-wallpaper.svg" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="3840" height="2160" viewBox="0 0 3840 2160">
  <defs>
    <radialGradient id="bg" cx="50%" cy="45%" r="75%">
      <stop offset="0%" stop-color="#1a2332"/>
      <stop offset="60%" stop-color="#0d1117"/>
      <stop offset="100%" stop-color="#05080d"/>
    </radialGradient>
    <linearGradient id="ring" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#4a9eff" stop-opacity="0.9"/>
      <stop offset="50%" stop-color="#7c5cff" stop-opacity="0.7"/>
      <stop offset="100%" stop-color="#4a9eff" stop-opacity="0.3"/>
    </linearGradient>
    <filter id="glow">
      <feGaussianBlur stdDeviation="24" result="blur"/>
      <feMerge>
        <feMergeNode in="blur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
  </defs>

  <rect width="3840" height="2160" fill="url(#bg)"/>

  <!-- 同心圆环：秩序从混沌中生成 -->
  <g filter="url(#glow)" opacity="0.85">
    <circle cx="1920" cy="972" r="420" fill="none" stroke="url(#ring)" stroke-width="3"/>
    <circle cx="1920" cy="972" r="330" fill="none" stroke="url(#ring)" stroke-width="2" opacity="0.7"/>
    <circle cx="1920" cy="972" r="240" fill="none" stroke="url(#ring)" stroke-width="2" opacity="0.5"/>
    <circle cx="1920" cy="972" r="150" fill="none" stroke="url(#ring)" stroke-width="2" opacity="0.35"/>
  </g>

  <!-- 中心点 -->
  <circle cx="1920" cy="972" r="14" fill="#4a9eff" filter="url(#glow)"/>

  <!-- 标题 -->
  <text x="1920" y="1640" font-family="Helvetica Neue, Helvetica, Arial, sans-serif"
        font-size="180" font-weight="200" letter-spacing="48"
        fill="#e6edf3" text-anchor="middle" opacity="0.95">ORDO</text>
  <text x="1920" y="1740" font-family="Helvetica Neue, Helvetica, Arial, sans-serif"
        font-size="48" font-weight="300" letter-spacing="16"
        fill="#8b949e" text-anchor="middle" opacity="0.8">ORDO AB CHAO</text>
</svg>
EOF

say "完成：$OUT/"
ls -lh "$OUT/"
