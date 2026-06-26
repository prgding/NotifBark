#!/bin/bash
# 编译、签名、安装 NotifBark.app，并设置开机自启。
# 前置：先跑过 ./setup-cert.sh（创建自签名证书）。
set -e

CN="NotifBark Self Signed"
BUNDLE_ID="com.dings.notifbark"
APP="$HOME/Applications/NotifBark.app"
SRC="$(cd "$(dirname "$0")" && pwd)/Sources/main.swift"
PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
U=$(id -u)

if ! security find-identity -p codesigning | grep -q "$CN"; then
  echo "✗ 找不到签名身份「$CN」，请先运行 ./setup-cert.sh"
  exit 1
fi

echo "→ 组装 app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NotifBark</string>
  <key>CFBundleDisplayName</key><string>NotifBark</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>NotifBark</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF

echo "→ 编译"
/usr/bin/swiftc -O "$SRC" -o "$APP/Contents/MacOS/NotifBark" \
  -framework AppKit -framework Foundation -lsqlite3

echo "→ 签名（同证书同 bundle id → 完全磁盘访问授权不会失效）"
codesign --force --deep --sign "$CN" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose "$APP"

echo "→ 安装开机自启 LaunchAgent"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$BUNDLE_ID</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/NotifBark</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl bootout "gui/$U/$BUNDLE_ID" 2>/dev/null || true
launchctl bootstrap "gui/$U" "$PLIST"

echo
echo "✓ 完成。NotifBark 已安装并启动（菜单栏出现图标）。"
echo "  首次使用："
echo "   1) cp config.example.json ~/.notif2bark/config.json，填入你的 Bark key"
echo "   2) 菜单栏图标 → 「打开『完全磁盘访问』设置」→ 把 ~/Applications/NotifBark.app 加进去并打开"
echo "   3) 菜单栏图标 → 「发送测试推送」验证手机收到"
