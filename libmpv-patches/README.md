# ANE 滤镜（mpv 补丁）

三个自定义 mpv 视频滤镜，直接调用 macOS 26 的 `VTFrameProcessor`，跑在 Apple Silicon 的神经引擎上：

| 文件 | 滤镜名 | 作用 | 使用到的 API |
|---|---|---|---|
| `vf_ane.m` | `ane` | 补帧 2x / 4x | `VTLowLatencyFrameInterpolationConfiguration` |
| `vf_anenf.m` | `anenf` | 时域降噪 | `VTTemporalNoiseFilterConfiguration` |
| `vf_anesr.m` | `anesr` | 2x 超分 | `VTLowLatencySuperResolutionScalerConfiguration` |

## 怎么接进 mpv

`scripts/build-libmpv.sh` 会自动做完下面这些，一般不需要手动操作。手工流程是：

```bash
git clone --depth 1 --branch v0.41.0 https://github.com/mpv-player/mpv.git
cd mpv
python3 /path/to/ANEPlayer/libmpv-patches/apply.py .   # 拷贝源码 + 打 3 处注册补丁
meson setup build -Dlibmpv=true -Dbuildtype=release --default-library=shared
ninja -C build
```

`apply.py` 会做四件事（重复执行安全）：

1. 把三个 `.m` 拷到 `video/filter/`
2. `meson.build`：加 `ane_interp` 特性开关，并把三个源文件加进 `sources`（`libmpv = library(` 之前）
3. `filters/user_filters.h`：声明三个 `mp_user_filter_entry`
4. `filters/user_filters.c`：在 `vf_list[]` 里注册（用 `#if HAVE_ANE_INTERP` 包住）

## 用法

```bash
mpv --vf=ane=factor=2x          # 补帧
mpv --vf=anenf=strength=0.7     # 时域降噪
mpv --vf=anesr=2x               # 超分
mpv --vf=anenf=strength=0.35,ane=factor=2x   # 可以串起来，降噪放前面
```

## 几个实现上的坑（都踩过）

- **格式**：`VTFrameProcessor` 只吃它有把握的 CVPixelBuffer。手工 `CVPixelBufferCreate` 出来的帧和池子里的帧属性不一致时，参数对象会直接返回 `nil`。所以输入帧也要从同一个 `CVPixelBufferPool` 分配再拷进去。
- **行步长**：降噪配置给的像素格式（`'&8v0'`）其 `CVPixelBufferGetBytesPerRowOfPlane` 返回值不能直接用来 memcpy，会越界。两侧统一用 420v + `VTPixelTransferSession` 桥接。
- **引用计数**：mpv 的 `.m` 默认不开 ARC。`[[VTFrameProcessorFrame alloc] initWithBuffer:...]` 加进数组后，自己那份引用必须 release，否则每帧漏一个 3MB 的 IOSurface——1080p 补帧大约 75MB/s，一晚上能把内存和 swap 吃干。
- **直通开关**：`ane_set_vf_passthrough()` 是给播放器用的。拖动进度条时精确 seek 会解码几十帧，每帧都过滤镜就是一秒多的卡顿；打开直通后这些帧直接放行，seek 从 1.2s 降到 60ms 左右，同时不重建 ANE session。导出符号必须带 `__attribute__((visibility("default")))`——mpv 编译时统一 `-fvisibility=hidden`。

## 许可

这三个文件是 ANEPlayer 的一部分，随项目以 GPL-3.0 发布（与 mpv 的 GPL 构建保持一致）。
