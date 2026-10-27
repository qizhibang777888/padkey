#!/bin/bash
# PadKey 构建:swiftc 编译 → 组装 .app → ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

APP="PadKey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "[1/3] 编译 Swift 源码…"
swiftc -O -o "$APP/Contents/MacOS/PadKey" Sources/*.swift

echo "[2/3] 写入 Info.plist…"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PadKey</string>
    <key>CFBundleDisplayName</key><string>PadKey</string>
    <key>CFBundleIdentifier</key><string>local.qzbworks.padkey</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>PadKey</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 从 Assets/icon.png 生成全套尺寸图标 → AppIcon.icns(sips 缩放 + iconutil 打包;换图标只需替换该 png)
if [ -f Assets/icon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET" "$APP/Contents/Resources"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" Assets/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" Assets/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    echo "图标已生成:AppIcon.icns"
fi

echo "[3/3] 签名(优先稳定证书,避免每次重编译后辅助功能授权失效)…"
if codesign --force --sign "PadKey Local Signer" "$APP" 2>/dev/null; then
    echo "已用稳定自签证书签名:重编译不再导致授权失效"
else
    codesign --force --sign - "$APP"
    echo "⚠️ 未找到「PadKey Local Signer」证书,回退 ad-hoc 签名(重编译后需重新授辅助功能权限)"
fi

echo "✅ 构建完成:$APP"
