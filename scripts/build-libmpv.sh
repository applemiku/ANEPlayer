#!/bin/bash
#
# 编译带 ANE 滤镜（补帧 / 超分 / 时域降噪）的 libmpv
#
#   ./scripts/build-libmpv.sh
#
# 产物：vendor/libmpv/libmpv.2.dylib + vendor/libmpv/include/mpv/*.h
# 之后 ./build.sh 会直接用这里的库。
#
# 依赖：Xcode Command Line Tools、meson、ninja、pkg-config、ffmpeg（Homebrew）
#      brew install meson ninja pkg-config ffmpeg
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
MPV_VERSION="${MPV_VERSION:-v0.41.0}"
WORK="${MPV_BUILD_DIR:-$HERE/vendor/mpv-build}"
OUT="$HERE/vendor/libmpv"

for tool in git meson ninja python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "缺少 $tool，请先安装（brew install meson ninja）"; exit 1; }
done

echo "=== 1/4 准备 mpv 源码（$MPV_VERSION）==="
mkdir -p "$WORK"
if [ ! -d "$WORK/mpv/.git" ]; then
    git clone --depth 1 --branch "$MPV_VERSION" \
        https://github.com/mpv-player/mpv.git "$WORK/mpv"
else
    echo "  复用已有源码树：$WORK/mpv"
fi

echo "=== 2/4 打入 ANE 滤镜 ==="
python3 "$HERE/libmpv-patches/apply.py" "$WORK/mpv"

echo "=== 3/4 编译 libmpv（首次要几分钟）==="
cd "$WORK/mpv"
if [ ! -d build ]; then
    meson setup build -Dlibmpv=true -Dbuildtype=release --default-library=shared
fi
ninja -C build

echo "=== 4/4 收集产物 ==="
mkdir -p "$OUT/include"
cp build/libmpv.2.dylib "$OUT/"
rm -rf "$OUT/include/mpv"
cp -R include/mpv "$OUT/include/"
ln -sf libmpv.2.dylib "$OUT/libmpv.dylib"

echo ""
echo "完成：$OUT"
echo "接着运行 ./build.sh 打包 app"
