#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

# ============================================================
#  TLKit App Store 构建脚本（沙盒版）
#  签名（Apple Distribution）→ Archive → Export → .pkg
#  APP_STORE 宏的作用：切换渠道标识（App Store / 官网版）。
#  翻译服务两个渠道一致（全部提供），仅 UI 文案避开敏感词。
#  取词统一走剪贴板通道，与宏无关。
# ============================================================

APP_NAME="TLKit"
BUNDLE_ID="me.ckai.translate"
BUILD_DIR="./build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
PKG_PATH="${BUILD_DIR}/${APP_NAME}.pkg"

TEAM_ID="$(op read op://My-Keys/apple/TEAM_ID)"
SIGNING_NAME="$(op read op://My-Keys/apple/SIGNING_NAME)"
export TLKIT_TEAM_ID="${TEAM_ID}"
export TLKIT_SIGNING_NAME="${SIGNING_NAME}"
# Mac App Store 应用签名专用证书（与 Installer 证书区分，避免导出时误选）
DIST_IDENTITY="3rd Party Mac Developer Application: ${SIGNING_NAME} (${TEAM_ID})"

step()  { echo "▶ $1"; }

step "xcodegen 生成工程"
xcodegen generate

step "Archive（App Store 签名 + 沙盒 entitlements + APP_STORE 宏）"
rm -rf "${ARCHIVE_PATH}"
xcodebuild archive \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -archivePath "${ARCHIVE_PATH}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${DIST_IDENTITY}" \
  CODE_SIGN_ENTITLEMENTS=Sources/TLKit/Resources/TLKit.entitlements \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) APP_STORE' \
  DEVELOPMENT_TEAM="${TEAM_ID}" \
  -quiet

step "打包 .pkg（productbuild + productsign，绕开 xcodebuild 导出时的证书误选）"
APP_PATH="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
UNSIGNED_PKG="${BUILD_DIR}/${APP_NAME}-unsigned.pkg"
INSTALLER_IDENTITY="3rd Party Mac Developer Installer: ${SIGNING_NAME} (${TEAM_ID})"
rm -f "${PKG_PATH}" "${UNSIGNED_PKG}"
productbuild --component "${APP_PATH}" /Applications "${UNSIGNED_PKG}"
productsign --sign "${INSTALLER_IDENTITY}" "${UNSIGNED_PKG}" "${PKG_PATH}"
rm -f "${UNSIGNED_PKG}"
pkgutil --check-signature "${PKG_PATH}"

step "完成：${PKG_PATH}（用 Transporter 上传 App Store Connect）"
