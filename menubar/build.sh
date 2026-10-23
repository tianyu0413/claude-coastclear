#!/bin/bash
# 编译菜单栏监控 App 为 cc.app (LSUIElement 后台代理，不进 Dock)
set -euo pipefail
cd "$(dirname "$0")"

APP="cc.app"
BIN="cc"
# 版本号统一来自根目录 VERSION，不在构建脚本里写死
APP_VERSION=$(tr -d '[:space:]' <../VERSION)
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION 格式应为 x.y.z：$APP_VERSION" >&2; exit 1; }

# 不指定 -target 时，swiftc 会把二进制的 minos 标成构建机当前系统版本，
# 装到更低版本的 macOS 上 dyld 直接拒绝启动——Info.plist 里写的 12.0 不起作用。
# 同理不 lipo 就只有构建机那一种架构，Intel Mac 打不开。
DEPLOY_TARGET=12.0

echo "编译 Swift (arm64 + x86_64, macOS $DEPLOY_TARGET+) ..."
for arch in arm64 x86_64; do
    swiftc StatusApp.swift -o "$BIN-$arch" -target "$arch-apple-macos$DEPLOY_TARGET" \
        -framework Cocoa -framework WebKit -O
done
lipo -create "$BIN-arm64" "$BIN-x86_64" -output "$BIN"
rm -f "$BIN-arm64" "$BIN-x86_64"

echo "组装 .app 包 ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BIN" "$APP/Contents/MacOS/$BIN"

# 把检测脚本打包进 App，实现自包含可分发
cp ../cc-network.sh "$APP/Contents/Resources/cc-network.sh"
chmod +x "$APP/Contents/Resources/cc-network.sh"
cp ../cc-check.sh "$APP/Contents/Resources/cc-check.sh"
chmod +x "$APP/Contents/Resources/cc-check.sh"
cp ../cc-consent.sh "$APP/Contents/Resources/cc-consent.sh"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>cc</string>
    <key>CFBundleDisplayName</key>     <string>cc</string>
    <key>CFBundleIdentifier</key>      <string>local.cc</string>
    <key>CFBundleExecutable</key>      <string>cc</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleShortVersionString</key> <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>          <string>${APP_VERSION}</string>
    <key>LSUIElement</key>             <true/>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
</dict>
</plist>
PLIST

# 本地临时签名，避免 Gatekeeper 拦截
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "完成: $(pwd)/$APP"
