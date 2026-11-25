# 第三方组件与许可

本项目（ANEPlayer）以 GPL-3.0 发布。它链接 / 打包了下列第三方组件，各自的许可与版权归原作者所有。

## 播放内核

| 组件 | 版本 | 许可 | 说明 |
|---|---|---|---|
| [mpv](https://github.com/mpv-player/mpv) | v0.41.0 | GPL-2.0-or-later | 默认（`-Dgpl=true`）构建为 GPL 版本。`scripts/build-libmpv.sh` 未改动该选项 |
| [FFmpeg](https://ffmpeg.org) | 9.0.2（Homebrew） | GPL-2.0-or-later | Homebrew 的 ffmpeg 启用了 `--enable-gpl`，随 app 一起打包 |
| [libplacebo](https://github.com/haasn/libplacebo) | v7.360.1 | LGPL-2.1-or-later | 由 libmpv 引入 |

> 因此本项目（含源码与二进制）整体按 GPL-3.0 分发。如果你要发布编译好的 `.app`，请同时提供对应源码，并保留上述组件的版权声明。

## 画质 / 渲染

| 组件 | 许可 | 说明 |
|---|---|---|
| [Anime4K](https://github.com/bloc97/Anime4K) 着色器 | MIT | `assets/anime4k/*.glsl`，每个文件头保留原始 MIT 声明 |
| [niconicomments](https://github.com/xpadev-net/niconicomments) | MIT | `assets/danmaku/lib/niconicomments.min.js`（v0.3.1，@xpadev-net） |

## 数据来源

- 弹幕数据来自 [弹弹play](https://www.dandanplay.com/) 的公开 API。本项目不包含其数据，只做实时请求；使用前请遵守对方的服务条款。
- 应用图标、UI、滤镜代码为本项目原创（GPL-3.0）。

## 字体 / 系统资源

界面文字全部使用 macOS 系统字体（San Francisco / PingFang SC），未打包任何字体文件。界面图标使用 Apple SF Symbols（通过 `NSImage imageWithSystemSymbolName:` 调用），不随项目分发。
