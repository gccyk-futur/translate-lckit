#!/bin/bash
# 从 1024×1024 主图生成 AppIcon.appiconset 全部槽位。
# 主图来源：Gemini 生成的水墨书法「译」（与 VoiceKit「语」同系列），
# 提交在 Resources/AppIcon-1024.png，保证图标可追溯、可重现。
# 用法：scripts/generate-icon.sh [主图路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/Sources/TLKit/Resources/AppIcon-1024.png}"
ICONSET="$ROOT/Sources/TLKit/Resources/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$SRC" ]; then
  echo "主图不存在：$SRC" >&2
  exit 1
fi

# size(点数) scale → 像素 = size * scale
for slot in "16 1" "16 2" "32 1" "32 2" "128 1" "128 2" "256 1" "256 2" "512 1" "512 2"; do
  size="${slot% *}"
  scale="${slot#* }"
  px=$((size * scale))
  name="icon_${size}x${size}.png"
  [ "$scale" = "2" ] && name="icon_${size}x${size}@2x.png"
  sips -z "$px" "$px" "$SRC" --out "$ICONSET/$name" >/dev/null
  echo "生成 $name (${px}px)"
done

echo "完成：$ICONSET"
