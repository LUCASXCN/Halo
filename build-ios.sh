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
VERSION=V1.4
BUILD="$ROOT/build-ios"
APPDIR="$BUILD/Payload/$APP.app"
rm -rf "$BUILD"; mkdir -p "$APPDIR"

echo "==> 1/4 收集源文件（共享契约 + iPhone 端）"
SRCS=( "$ROOT/src/shared/Protocol.swift" "$ROOT/src/shared/ZoneEngine.swift" )
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
# PkgInfo：对齐主流可侧载 App 的标准结构（SoniCast 等可装包均含此文件）
printf 'APPL????' > "$APPDIR/PkgInfo"
file "$APPDIR/$APP" | sed 's/^/    /'

echo "==> 4/4 打包双版本（纯净未签名 + ad-hoc 自签）"
cd "$BUILD"

# 版本 A：纯净未签名 IPA（不含 _CodeSignature / embedded.mobileprovision）
# —— 主用「全能签」等工具重签，结构与已验证可装的 SoniCast 完全一致
rm -f "$APP-$VERSION-unsigned.ipa"
zip -qry "$APP-$VERSION-unsigned.ipa" Payload

# 版本 B：ad-hoc 自签 IPA（本机无 Apple 证书，只能做 ad-hoc；供 Sideloadly/AltStore/
# 巨魔等偏好「已签名形态」的侧载工具，全能签同样可对其再次重签）
cat > "$BUILD/HaloRemote.entitlements" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>get-task-allow</key><true/>
</dict></plist>
PL
codesign --force --sign - --entitlements "$BUILD/HaloRemote.entitlements" "$APPDIR"
rm -f "$APP-$VERSION-adhoc.ipa"
zip -qry "$APP-$VERSION-adhoc.ipa" Payload

cd "$ROOT"
cp "$BUILD/$APP-$VERSION-unsigned.ipa" "$ROOT/$APP-$VERSION-unsigned.ipa"
cp "$BUILD/$APP-$VERSION-adhoc.ipa"    "$ROOT/$APP-$VERSION-adhoc.ipa"
echo ""
echo "✅ 完成 $VERSION（最低系统 iOS 26，arm64）："
echo "   A 未签名: $ROOT/$APP-$VERSION-unsigned.ipa  （全能签主用）"
echo "   B 自签版: $ROOT/$APP-$VERSION-adhoc.ipa     （侧载工具备用，仍需重签才能上真机）"
