#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# ============================================================
#  TLKit 官网版构建脚本（Developer ID + 公证，无沙盒）
# ============================================================

APP_NAME="TLKit"
BUNDLE_ID="me.ckai.translate"
BUILD_DIR="./build"
NOTARY_PROFILE="TLKit-Notary"

# 开发者身份：签名凭证经 1Password CLI 注入，按需改 vault 路径。
TEAM_ID="$(op read op://My-Keys/apple/TEAM_ID)"
SIGNING_NAME="$(op read op://My-Keys/apple/SIGNING_NAME)"
export TLKIT_TEAM_ID="${TEAM_ID}"
export TLKIT_SIGNING_NAME="${SIGNING_NAME}"

# 公证凭证：不存在则提示先跑 setup-notary.sh，并降级为仅签名不公证。
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" &>/dev/null; then
  echo "⚠ 公证凭证未配置，跳过公证步骤（仅签名 + dmg）。配置：./scripts/setup-notary.sh"
  SKIP_NOTARY=true
else
  SKIP_NOTARY=false
fi

step()  { echo "▶ $1"; }

step "xcodegen 生成工程"
xcodegen generate

step "Archive（Release，Developer ID 签名）"
rm -rf "${BUILD_DIR}/${APP_NAME}.xcarchive"
xcodebuild archive \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application: ${SIGNING_NAME} (${TEAM_ID})" \
  CODE_SIGN_ENTITLEMENTS=Sources/TLKit/Resources/TLKit-Direct.entitlements \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  -quiet

APP_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app"

step "压缩 .app 为 zip（notarytool 仅接受 zip/pkg/dmg）"
ZIP_PATH="${BUILD_DIR}/${APP_NAME}.zip"
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

if [ "${SKIP_NOTARY}" = false ]; then
  step "公证 .app（notarytool）"
  xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
  xcrun stapler staple "${APP_PATH}"
else
  step "跳过 .app 公证"
fi

step "打包 dmg"
rm -f "${BUILD_DIR}/${APP_NAME}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${APP_PATH}" \
  -ov -format UDZO "${BUILD_DIR}/${APP_NAME}.dmg"

if [ "${SKIP_NOTARY}" = false ]; then
  step "公证 dmg（notarytool）"
  xcrun notarytool submit "${BUILD_DIR}/${APP_NAME}.dmg" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait
  xcrun stapler staple "${BUILD_DIR}/${APP_NAME}.dmg"
else
  step "跳过 dmg 公证"
fi

step "完成：${BUILD_DIR}/${APP_NAME}.dmg"
