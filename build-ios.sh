#!/bin/bash
# ════════════════════════════════════════════════════════════════════
#  build-ios.sh — 不开 Xcode GUI，用 toolchain 绝对路径交叉编译 iPhone arm64
#  产出「未签名」HaloRemote.ipa，供全能签等工具重签后安装（iOS 26+ / iOS27）
# ════════════════════════════════════════════════════════════════════
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
XC=/Applications/Xcode.app/Contents/Developer
SW="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
IOSSDK="$XC/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
TARGET=arm64-apple-ios26

APP=HaloRemote
BUILD="$ROOT/build-ios"
APPDIR="$BUILD/Payload/$APP.app"
rm -rf "$BUILD"; mkdir -p "$APPDIR"

echo "==> 1/4 收集源文件（共享契约 + iPhone 端）"
SRCS=( "$ROOT/src/shared/Protocol.swift" )
while IFS= read -r f; do SRCS+=( "$f" ); done < <(find "$ROOT/src/ios" -name '*.swift' | sort)
echo "    共 ${#SRCS[@]} 个 Swift 文件"

echo "==> 2/4 交叉编译 arm64（iOS）"
"$SW" \
  -parse-as-library \
  -target "$TARGET" \
  -sdk "$IOSSDK" \
  -swift-version 5 \
  -O \
  -framework SwiftUI -framework UIKit -framework CoreBluetooth \
  -framework Network -framework PhotosUI -framework Combine \
  -o "$APPDIR/$APP" \
  "${SRCS[@]}"

echo "==> 3/4 组装 .app"
cp "$ROOT/src/ios/Info.plist" "$APPDIR/Info.plist"

# 图标：actool 依赖需授权的 Xcode 组件，改用扁平 PNG + CFBundleIcons（side-load 兼容）
ICON_SRC="$ROOT/assets/iconwork/master_square.png"
if [ -f "$ICON_SRC" ]; then
  micon(){ sips -z "$2" "$2" "$ICON_SRC" --out "$APPDIR/$1" >/dev/null; }
  micon "Icon-20@2x.png" 40;  micon "Icon-20@3x.png" 60
  micon "Icon-29@2x.png" 58;  micon "Icon-29@3x.png" 87
  micon "Icon-40@2x.png" 80;  micon "Icon-40@3x.png" 120
  micon "Icon-60@2x.png" 120; micon "Icon-60@3x.png" 180
  micon "Icon-76.png" 76;     micon "Icon-76@2x.png" 152
  micon "Icon-83.5@2x.png" 167
  echo "    已生成多尺寸 App 图标"
fi
# 未签名：不生成 CodeResources，交由全能签重签
file "$APPDIR/$APP" | sed 's/^/    /'

echo "==> 4/4 打包未签名 IPA"
cd "$BUILD"
zip -qr "$APP-unsigned.ipa" Payload
cd "$ROOT"
cp "$BUILD/$APP-unsigned.ipa" "$ROOT/$APP-unsigned.ipa"
echo ""
echo "✅ 完成：$ROOT/$APP-unsigned.ipa"
echo "   用全能签重签后安装；最低系统 iOS 26"
