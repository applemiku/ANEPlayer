#!/bin/bash
#
# ANEPlayer（libmpv 版）构建脚本
#
#   ./build.sh          编译并打包到 build/ANEPlayer.app
#   ./build.sh run      打包后直接启动（用于自测）
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/build/ANEPlayer.app"

# libmpv（带 ANE 滤镜）搜索顺序：
#   1) 环境变量 MPV_LIB_DIR 指定的目录（需含 libmpv.2.dylib 与 include/mpv/）
#   2) ./vendor/libmpv —— scripts/build-libmpv.sh 的默认产物
if [ -n "${MPV_LIB_DIR:-}" ]; then
    MPV_INC="${MPV_INC:-$MPV_LIB_DIR/include}"
elif [ -f "$HERE/vendor/libmpv/libmpv.2.dylib" ]; then
    MPV_LIB_DIR="$HERE/vendor/libmpv"
    MPV_INC="$HERE/vendor/libmpv/include"
else
    echo "找不到 libmpv。先跑一次："
    echo "    ./scripts/build-libmpv.sh"
    echo "或者用 MPV_LIB_DIR=/path/to/libmpv ./build.sh 指定现成的库。"
    exit 1
fi

echo "=== 1/4 编译 ObjC 源码 ==="
rm -rf "$HERE/build"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

clang -fobjc-arc -O2 -Wall \
  -o "$OUT/Contents/MacOS/ANEPlayer" \
  "$HERE/src/main.m" "$HERE/src/ANEVideoView.m" "$HERE/src/ANEDanmaku.m" \
  -I"$MPV_INC" \
  -L"$MPV_LIB_DIR" -lmpv \
  -framework Cocoa -framework OpenGL -framework CoreFoundation -framework CoreVideo \
  -framework WebKit \
  -Wl,-rpath,"@loader_path/../Frameworks" \
  -mmacosx-version-min=11.0

echo "=== 2/4 收集动态库依赖 ==="
python3 "$HERE/stage_deps.py" "$OUT/Contents/MacOS/ANEPlayer" "$OUT/Contents/Frameworks" "$MPV_LIB_DIR"

echo "=== 2.5/4 拷贝 Anime4K 着色器 ==="
if [ -d "$HERE/assets/anime4k" ]; then
  mkdir -p "$OUT/Contents/Resources/anime4k"
  cp "$HERE/assets/anime4k/"*.glsl "$OUT/Contents/Resources/anime4k/"
  echo "  已打入 $(ls "$OUT/Contents/Resources/anime4k" | wc -l | tr -d ' ') 个 .glsl"
else
  echo "  （没有 assets/anime4k，跳过）"
fi

echo "=== 2.6/4 拷贝弹幕渲染层 ==="
if [ -d "$HERE/assets/danmaku" ]; then
  rm -rf "$OUT/Contents/Resources/danmaku"
  cp -R "$HERE/assets/danmaku" "$OUT/Contents/Resources/danmaku"
  echo "  弹幕层已打入（$(ls "$OUT/Contents/Resources/danmaku" | wc -l | tr -d ' ') 个文件）"
else
  echo "  （没有 assets/danmaku，跳过）"
fi

echo "=== 2.7/4 拷贝应用图标 ==="
if [ -f "$HERE/assets/AppIcon.icns" ]; then
  cp "$HERE/assets/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
  echo "  图标已打入 AppIcon.icns"
else
  echo "  （没有 assets/AppIcon.icns，跳过；可用 assets/make_appicon.swift 重新生成）"
fi

echo "=== 3/4 写 Info.plist ==="
cat > "$OUT/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ANEPlayer</string>
  <key>CFBundleDisplayName</key><string>ANEPlayer</string>
  <key>CFBundleIdentifier</key><string>cn.zxwzz.aneplayer.mpv</string>
  <key>CFBundleExecutable</key><string>ANEPlayer</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Media File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.audiovisual-content</string>
        <string>public.audio</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "=== 4/4 ad-hoc 签名 ==="
codesign --force --deep --sign - "$OUT"
codesign -v "$OUT" && echo "  签名有效"

echo ""
echo "完成：$OUT"
if [ "${1:-}" = "run" ]; then
  echo "启动…"
  open -a "$OUT"
fi
