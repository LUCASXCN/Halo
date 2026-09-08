#!/bin/bash
# 构建 Halo.app（菜单栏常驻）：主程序(SwiftUI) + 用户态桌面覆盖进程 DesktopOverlay
# universal2（Apple Silicon + Intel），最低系统 macOS 26。
# 全程使用 Xcode 工具链绝对路径，无需打开 Xcode、无需同意其 license。
set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Halo.app"
CONT="$APP/Contents"
MIN="macos26"
VERSION="1.4"

XC="/Applications/Xcode.app/Contents/Developer"
SW="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
LIPO="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo"
MACSDK="$XC/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
[ -d "$MACSDK" ] || MACSDK="$(xcrun --sdk macosx --show-sdk_path 2>/dev/null)"

MAIN_FW=(-framework AppKit -framework SwiftUI -framework Combine -framework CryptoKit \
         -framework CoreBluetooth -framework Network -framework Security -framework ImageIO -framework CoreGraphics)
MAIN_SRC=("$ROOT/src/shared/Protocol.swift" "$ROOT/src/shared/ZoneEngine.swift" $ROOT/src/mac/core/*.swift \
          "$ROOT/src/mac/wallpaper/ImageEngine.swift" "$ROOT/src/mac/wallpaper/WallpaperController.swift" \
          $ROOT/src/mac/ui/*.swift)

echo "==> 1/6 编译覆盖进程 DesktopOverlay（universal2）"
"$SW" -O -target arm64-apple-$MIN -sdk "$MACSDK" "$ROOT/src/mac/wallpaper/DesktopOverlay.swift" -o /tmp/HaloDO.arm -framework AppKit -framework IOKit
"$SW" -O -target x86_64-apple-$MIN -sdk "$MACSDK" "$ROOT/src/mac/wallpaper/DesktopOverlay.swift" -o /tmp/HaloDO.x86 -framework AppKit -framework IOKit
"$LIPO" -create /tmp/HaloDO.arm /tmp/HaloDO.x86 -o /tmp/DesktopOverlay

echo "==> 2/6 编译主程序 Halo（universal2，静态链接 login.framework 锁屏符号）"
"$SW" -O -target arm64-apple-$MIN -sdk "$MACSDK" "${MAIN_SRC[@]}" "$ROOT/vendor/login.tbd" -o /tmp/HaloMain.arm "${MAIN_FW[@]}"
"$SW" -O -target x86_64-apple-$MIN -sdk "$MACSDK" "${MAIN_SRC[@]}" "$ROOT/vendor/login.tbd" -o /tmp/HaloMain.x86 "${MAIN_FW[@]}"
"$LIPO" -create /tmp/HaloMain.arm /tmp/HaloMain.x86 -o /tmp/Halo

echo "==> 3/6 组装 .app"
rm -rf "$APP"; mkdir -p "$CONT/MacOS" "$CONT/Resources"
cp /tmp/Halo "$CONT/MacOS/Halo"
cp /tmp/DesktopOverlay "$CONT/Resources/DesktopOverlay"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$CONT/Resources/AppIcon.icns"
chmod +x "$CONT/MacOS/Halo" "$CONT/Resources/DesktopOverlay"

cat > "$CONT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Halo</string>
  <key>CFBundleDisplayName</key><string>Halo</string>
  <key>CFBundleIdentifier</key><string>com.lucas.halo</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Halo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Halo 通过蓝牙连接你的 iPhone，实现靠近自动解锁、远离自动锁屏。</string>
  <key>NSLocalNetworkUsageDescription</key><string>Halo 在同一 Wi-Fi 下与你的 iPhone 通信，用于遥控锁屏与更换壁纸。</string>
  <key>NSBonjourServices</key><array><string>_halo._tcp</string></array>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 LUCASXCN. All rights reserved.</string>
</dict></plist>
PLIST

echo "==> 4/6 生成 PkgInfo"
echo -n "APPL????" > "$CONT/PkgInfo"

echo "==> 5/6 Ad-hoc 签名（由内向外）"
codesign --force --sign - "$CONT/Resources/DesktopOverlay"
codesign --force --sign - "$CONT/MacOS/Halo"
codesign --force --sign - --identifier com.lucas.halo "$APP"
echo "    签名校验:"; codesign -vvv "$APP" 2>&1 | sed 's/^/      /'

echo "==> 6/6 完成"
echo "产物：$APP"
"$LIPO" -archs "$CONT/MacOS/Halo" | sed 's/^/    主程序架构: /'
ls -la "$CONT/MacOS" "$CONT/Resources"
