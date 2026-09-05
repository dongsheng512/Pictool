#!/bin/bash
# 构建 PureView.app(SPM 编译 + 手工组装 bundle + ad-hoc 签名;可执行文件内部产物名仍为 Pictool)
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="build/PureView.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pictool" "$APP/Contents/MacOS/PureView"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# 声明可用本地化:系统面板(NSPrintPanel 等)据此跟随用户语言渲染,
# 缺失时系统会退回默认开发区域(英文)。空 Localizable.strings 仅作占位。
for lang in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    : > "$APP/Contents/Resources/$lang.lproj/Localizable.strings"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PureView</string>
    <key>CFBundleIdentifier</key><string>com.dongsheng.pureview</string>
    <key>CFBundleName</key><string>PureView</string>
    <key>CFBundleDisplayName</key><string>PureView</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleShortVersionString</key><string>0.5.36</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>图片</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>文件夹</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.directory</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✅ 已构建 $APP"
echo "   运行: open $APP"
