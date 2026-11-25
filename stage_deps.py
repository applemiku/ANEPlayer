#!/usr/bin/env python3
"""
把可执行文件依赖的非系统动态库复制进 app bundle，并把引用改成 @loader_path 形式。

用法: stage_deps.py <可执行文件> <Frameworks目录> <libmpv 所在目录>
"""
import os
import re
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = (
    "/usr/lib/",
    "/System/Library/",
    "/usr/libexec/",
)

def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    res = []
    for line in out.splitlines()[1:]:
        m = re.match(r"\s+(\S+)\s+\(", line)
        if m:
            res.append(m.group(1))
    return res

def is_system(p):
    return any(p.startswith(x) for x in SYSTEM_PREFIXES)

def resolve(d, mpvdir):
    """把 @rpath/xxx 这类引用解析成真实文件路径。"""
    if d.startswith("@rpath/") or d.startswith("@loader_path/"):
        base = os.path.basename(d)
        cand = os.path.join(mpvdir, base)
        if os.path.exists(cand):
            return cand
        return None
    return d if os.path.exists(d) else None

def main():
    binary = os.path.abspath(sys.argv[1])
    fwdir = os.path.abspath(sys.argv[2])
    mpvdir = os.path.abspath(sys.argv[3])
    os.makedirs(fwdir, exist_ok=True)

    staged = {}          # 原始绝对路径 -> Frameworks 里的文件名
    queue = [binary]
    # libmpv 本身也要进来
    libmpv = os.path.join(mpvdir, "libmpv.2.dylib")
    if os.path.exists(libmpv):
        queue.append(libmpv)

    while queue:
        cur = queue.pop(0)
        for d in deps(cur):
            if is_system(d):
                continue
            real = resolve(d, mpvdir)
            if not real:
                if not d.startswith("@"):
                    print(f"  [!] 依赖不存在，跳过: {d}")
                continue
            base = os.path.basename(d)
            target = os.path.join(fwdir, base)
            if base not in {os.path.basename(v) for v in staged.values()}:
                if not os.path.exists(target):
                    shutil.copy2(real, target)
                    os.chmod(target, 0o755)
                    print(f"  + 复制 {base}")
                    queue.append(target)
            staged[d] = target

    # 改引用
    def fix(path):
        for orig, target in staged.items():
            subprocess.run(["install_name_tool", "-change", orig,
                            "@loader_path/../Frameworks/" + os.path.basename(target),
                            path], capture_output=True)
        # 自身 id
        subprocess.run(["install_name_tool", "-id",
                        "@loader_path/../Frameworks/" + os.path.basename(path),
                        path], capture_output=True)

    fix(binary)
    for t in set(staged.values()):
        fix(t)

    print(f"  共处理 {len(set(staged.values()))} 个动态库")
    leftover = []
    for t in set(staged.values()):
        for d in deps(t):
            if not is_system(d) and not d.startswith("@"):
                leftover.append((os.path.basename(t), d))
    if leftover:
        print("  [!] 仍有绝对路径依赖:")
        for a, b in leftover[:10]:
            print(f"      {a} -> {b}")

if __name__ == "__main__":
    main()
