#!/usr/bin/env bash
# 构建 Release 版 universal app（ad-hoc 签名），并打包成 .dmg
# 用法：scripts/build-dmg.sh [版本号]，产物在 build/dist/
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-1.0}"
APP_NAME="DeathAdder Control"
DERIVED="build/DerivedData-release"
DIST="build/dist"
DMG="$DIST/DeathAdderControl-$VERSION.dmg"

rm -rf "$DERIVED" "$DIST"
mkdir -p "$DIST"

# 没有开发者证书：用 ad-hoc 签名（"-"），去掉团队和自动签名
xcodebuild \
  -project DeathAdderControl.xcodeproj \
  -scheme DeathAdderControl \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  build

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
codesign --verify --deep --strict "$APP"
lipo -info "$APP/Contents/MacOS/$APP_NAME"

# dmg 里放 app 和一个指向 /Applications 的快捷方式，方便拖进去安装
STAGING="$DIST/staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"
rm -rf "$STAGING"

echo "$DMG"
