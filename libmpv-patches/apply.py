#!/usr/bin/env python3
"""把三个 ANE 滤镜接进 mpv 源码树。

用法： python3 apply.py /path/to/mpv
（在 build-libmpv.sh 里会自动调用；重复执行是安全的）
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

MESON_BLOCK = """
# ANE 神经引擎滤镜：补帧 / 超分 / 时域降噪，都跑在 Apple Silicon 的 ANE 上
ane_fws = dependency('appleframeworks', modules: ['CoreVideo', 'VideoToolbox'],
                     required: false)
ane_interp = darwin and ane_fws.found()
features += {'ane-interp': ane_interp}
if ane_interp
    dependencies += ane_fws
    sources += files('video/filter/vf_ane.m')
    sources += files('video/filter/vf_anesr.m')
    sources += files('video/filter/vf_anenf.m')
endif

"""

VF_LIST_OLD = "    &vf_lavfi_bridge,\n"
VF_LIST_NEW = """    &vf_lavfi_bridge,
#if HAVE_ANE_INTERP
    &vf_ane,
    &vf_anesr,
    &vf_anenf,
#endif
"""

H_EXTERN_OLD = "extern const struct mp_user_filter_entry vf_gpu;\n"
H_EXTERN_NEW = """extern const struct mp_user_filter_entry vf_gpu;

// ANE 神经引擎滤镜（补帧 / 超分 / 时域降噪）
extern const struct mp_user_filter_entry vf_ane;
extern const struct mp_user_filter_entry vf_anesr;
extern const struct mp_user_filter_entry vf_anenf;
"""


def patch(path, old, new, marker):
    with open(path, encoding="utf-8") as f:
        s = f.read()
    if marker in s:
        print("  跳过（已打过）:", path)
        return
    if old not in s:
        sys.exit("补丁锚点没找到: %s\n  期望: %r" % (path, old))
    with open(path, "w", encoding="utf-8") as f:
        f.write(s.replace(old, new, 1))
    print("  已修改:", path)


def main():
    if len(sys.argv) < 2:
        sys.exit("用法: apply.py /path/to/mpv")
    root = sys.argv[1]

    for name in ("vf_ane.m", "vf_anesr.m", "vf_anenf.m"):
        src = os.path.join(HERE, name)
        dst = os.path.join(root, "video", "filter", name)
        with open(src, "rb") as fi, open(dst, "wb") as fo:
            fo.write(fi.read())
        print("  已拷贝:", dst)

    meson = os.path.join(root, "meson.build")
    with open(meson, encoding="utf-8") as f:
        s = f.read()
    if "ane-interp" not in s:
        anchor = "\nlibmpv = library("
        if anchor not in s:
            sys.exit("meson.build 里找不到 libmpv = library( 锚点")
        s = s.replace(anchor, MESON_BLOCK + anchor, 1)
        with open(meson, "w", encoding="utf-8") as f:
            f.write(s)
        print("  已修改:", meson)
    else:
        print("  跳过（已打过）:", meson)

    patch(os.path.join(root, "filters", "user_filters.c"),
          VF_LIST_OLD, VF_LIST_NEW, "vf_anesr")
    patch(os.path.join(root, "filters", "user_filters.h"),
          H_EXTERN_OLD, H_EXTERN_NEW, "vf_anesr")

    print("完成。接下来：meson setup build -Dlibmpv=true -Dbuildtype=release && ninja -C build")


if __name__ == "__main__":
    main()
