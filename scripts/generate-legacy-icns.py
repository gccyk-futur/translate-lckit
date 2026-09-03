#!/usr/bin/env python3
"""生成 macOS 14 兜底用的 AppIcon-Legacy.icns。

背景（K1）：Xcode 26 的 actool 把 .appiconset 位图替换为自动生成的 icon stack，
macOS 14 的 CoreUI 解析不了，系统回退到 AppIcon.icns——而 Xcode 生成的 icns
只有 16/128 两档且是满出血方图，在老系统上显示为「方方正正」的大方块。

本脚本从 1024 主图手工烘焙经典 Big Sur 风格图标：
满版方图 → 824/1024 安全区内居中 → 超椭圆（n=5，近似 Apple squircle）蒙版
→ 轻微投影 → iconutil 打包成全尺寸 icns。构建期由 postBuild 脚本覆盖
actool 产出的 AppIcon.icns；macOS 26 仍走 Assets.car，不受影响。

产物提交进仓库，日常构建无需 Pillow；仅重新生成时需要：
    python3 -m pip install Pillow   # 或用任意带 Pillow 的 Python
用法：python3 scripts/generate-legacy-icns.py [主图路径]
"""

import math
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Sources/TLKit/Resources/AppIcon-1024.png"
OUT = ROOT / "Sources/TLKit/Resources/AppIcon-Legacy.icns"

# Big Sur 图标网格：内容区 824/1024，四周透明留白
CONTENT_RATIO = 824 / 1024
SUPERELLIPSE_N = 5.0  # 近似 Apple 连续曲率圆角
SS = 4  # 抗锯齿超采样倍数

# iconutil 槽位：文件名 → 像素尺寸
SLOTS = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}


def superellipse_mask(size: int) -> Image.Image:
    """size×size 的超椭圆 alpha 蒙版，4x 超采样后降回。"""
    big = size * SS
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    half = big / 2
    n = SUPERELLIPSE_N
    # 超椭圆 |x|^n + |y|^n = r^n 的参数化多边形
    points = []
    steps = max(64, big // 2)
    for i in range(steps + 1):
        t = (i / steps) * (math.pi / 2)
        ct, st = math.cos(t), math.sin(t)
        x = half * math.copysign(ct ** (2 / n), 1)
        y = half * math.copysign(st ** (2 / n), 1)
        points.append((half + x, half + y))
    # 四象限镜像
    q1 = points
    q2 = [(big - px, py) for px, py in reversed(q1)]
    q3 = [(big - px, big - py) for px, py in q1]
    q4 = [(px, big - py) for px, py in reversed(q1)]
    draw.polygon(q1 + q2 + q3 + q4, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def render(master: Image.Image, canvas: int) -> Image.Image:
    content = max(1, round(canvas * CONTENT_RATIO))
    icon = master.resize((content, content), Image.LANCZOS)
    mask = superellipse_mask(content)

    # 轻微投影：蒙版形黑影，向下偏移，高斯柔化
    shadow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    black = Image.new("RGBA", (content, content), (0, 0, 0, 60))
    offset = (canvas - content) // 2
    shadow.paste(black, (offset, offset + max(1, round(canvas * 0.012))), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(1, canvas * 0.008)))

    result = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    result.alpha_composite(shadow)
    result.paste(icon, (offset, offset), mask)
    return result


def main() -> None:
    if not SRC.exists():
        sys.exit(f"主图不存在：{SRC}")
    master = Image.open(SRC).convert("RGBA")

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for name, px in SLOTS.items():
            render(master, px).save(iconset / name)
            print(f"生成 {name} ({px}px)")
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)],
            check=True,
        )
    print(f"完成：{OUT}")


if __name__ == "__main__":
    main()
