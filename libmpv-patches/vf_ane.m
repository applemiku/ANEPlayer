//
// vf_ane.m — ANE 神经引擎实时补帧滤镜（mpv 0.41）
//
// 用 Apple 的 VTLowLatencyFrameInterpolation（macOS 26+ / Apple Silicon）在 mpv
// 的视频滤镜链内部直接插帧。因为是进程内滤镜，不产生跨进程拷贝、不重新编码，
// 所以没有画质损耗也没有延迟，音画同步由 mpv 自己的播放时钟保证。
//
// 用法：--vf=ane:factor=2x   （或 lavfi 链里当作普通滤镜插入）
//

#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <dispatch/dispatch.h>

#include <libavutil/buffer.h>
#include <libavutil/frame.h>

#include "common/common.h"
#include "common/msg.h"
#include "filters/f_autoconvert.h"
#include "filters/filter.h"
#include "filters/filter_internal.h"
#include "filters/user_filters.h"
#include "options/m_option.h"
#include "video/img_format.h"
#include "video/mp_image.h"

// mpv 的 ObjC 编译不一定开 ARC，这里两种模式都兼容。
#if __has_feature(objc_arc)
  #define ANE_REL(x) do { (void)(x); } while (0)
#else
  #define ANE_REL(x) do { [(x) release]; } while (0)
#endif

// 全局直通开关：播放器拖动进度条时置 1，滤镜立刻变成纯直通。
// 这样 seek 期间不用改 vf 链（改链会触发 video-reconfig，反而更慢），
// 也不会丢掉已建好的 ANE session。
int ane_vf_passthrough = 0;
// 必须显式 default 可见性：mpv 编译时统一用了 -fvisibility=hidden，
// 不加这行 app 链接时会报 undefined symbol
__attribute__((visibility("default")))
void ane_set_vf_passthrough(int on) { ane_vf_passthrough = on ? 1 : 0; }

#define ANE_MAX_OUT      8
#define ANE_TIMEOUT_SEC  2.0

struct vf_ane_opts {
    int factor;   // 1=直通，2=2x（插 1 帧），4=4x（插 3 帧）
};

struct priv {
    struct vf_ane_opts *opts;
    struct mp_autoconvert *conv;

    // ── ANE session ──
    VTLowLatencyFrameInterpolationConfiguration *config;
    VTFrameProcessor *processor;
    CVPixelBufferPoolRef pool;
    int sw, sh;
    BOOL active;
    BOOL unsupported;      // 硬件/尺寸不支持时置位，之后直通，不再反复重试

    // ── 前一帧 ──
    CVPixelBufferRef prev;
    double prev_pts;
    struct mp_image_params prev_params;

    // ── 待输出队列（filter 持有引用）──
    struct mp_image *pending[ANE_MAX_OUT];
    int pending_n;
    bool eof_queued;

    int64_t n_in, n_out, n_interp, n_fail;
};

static void drop_pending_all(struct priv *p)
{
    for (int i = 0; i < p->pending_n; i++)
        talloc_free(p->pending[i]);
    p->pending_n = 0;
}

static void end_session(struct priv *p)
{
    if (p->processor) {
        [p->processor endSession];
        ANE_REL(p->processor);
        p->processor = nil;
    }
    if (p->config) {
        ANE_REL(p->config);
        p->config = nil;
    }
    if (p->pool) {
        CVPixelBufferPoolRelease(p->pool);
        p->pool = NULL;
    }
    p->active = NO;
}

/// 确保 session 与当前尺寸匹配。尺寸变化（分辨率切换）时必须重建，
/// 因为 config 的 frameWidth/frameHeight 在配置后不可更改。
static bool ensure_session(struct mp_filter *f, int w, int h)
{
    struct priv *p = f->priv;
    if (p->unsupported)
        return false;
    if (p->active && p->sw == w && p->sh == h)
        return true;

    end_session(p);

    if (!VTLowLatencyFrameInterpolationConfiguration.supported) {
        MP_ERR(f, "本机不支持 VTLowLatencyFrameInterpolation（需要 macOS 26+ 与 Apple Silicon）\n");
        p->unsupported = true;
        return false;
    }

    int want = p->opts->factor - 1;
    VTLowLatencyFrameInterpolationConfiguration *config =
        [[VTLowLatencyFrameInterpolationConfiguration alloc]
            initWithFrameWidth:w frameHeight:h numberOfInterpolatedFrames:want];
    if (!config) {
        MP_ERR(f, "硬件不支持 %dx%d 的插帧（超出该尺寸的像素预算）\n", w, h);
        p->unsupported = true;
        return false;
    }

    // 输出 buffer 池：用 config 提供的 attributes，保证格式与硬件对齐
    NSDictionary *poolAttrs = config.destinationPixelBufferAttributes;
    if (!poolAttrs) {
        MP_ERR(f, "插帧配置未提供输出缓冲属性\n");
        ANE_REL(config);
        p->unsupported = true;
        return false;
    }

    CVPixelBufferPoolRef pool = NULL;
    OSStatus st = CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                          (__bridge CFDictionaryRef)poolAttrs, &pool);
    if (st != kCVReturnSuccess || !pool) {
        MP_ERR(f, "创建输出缓冲池失败 (%d)\n", (int)st);
        ANE_REL(config);
        p->unsupported = true;
        return false;
    }

    VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
    NSError *err = nil;
    if (![proc startSessionWithConfiguration:config error:&err]) {
        MP_ERR(f, "启动插帧 session 失败：%s\n", err.localizedDescription.UTF8String ?: "未知原因");
        ANE_REL(proc);
        ANE_REL(config);
        CVPixelBufferPoolRelease(pool);
        p->unsupported = true;
        return false;
    }

    p->config = config;
    p->processor = proc;
    p->pool = pool;
    MP_INFO(f, "[ANE-DIAG] session 建立成功 %dx%d，插帧数=%d\n", w, h, want);
    MP_INFO(f, "[ANE-DIAG] poolAttrs = %s\n",
            poolAttrs ? poolAttrs.description.UTF8String : "(nil)");
    p->sw = w;
    p->sh = h;
    p->active = YES;
    MP_INFO(f, "ANE 插帧 session 就绪：%dx%d，%dx（每对源帧插 %d 帧）\n",
            w, h, p->opts->factor, want);
    return true;
}

/// AVBufferRef 的释放回调：最后一个引用消失时释放 CVPixelBuffer。
static void cvpb_free(void *opaque, uint8_t *data)
{
    CVPixelBufferRelease((CVPixelBufferRef)opaque);
}

/// 把插值输出的 CVPixelBuffer 包装成 mp_image。
/// 用 AVFrame 作中间层：format=AV_PIX_FMT_VIDEOTOOLBOX，data[3] 放 CVPixelBuffer，
/// 由 buf[0] 持有其生命周期，这样 mpv 的渲染路径（hwdec_vt）能直接识别。
static struct mp_image *wrap_cvpb(void *ta_ctx, CVPixelBufferRef pbuf,
                                  const struct mp_image_params *ref, double pts)
{
    AVFrame *avf = av_frame_alloc();
    if (!avf)
        goto fail;

    avf->format = AV_PIX_FMT_VIDEOTOOLBOX;
    avf->width  = (int)CVPixelBufferGetWidth(pbuf);
    avf->height = (int)CVPixelBufferGetHeight(pbuf);
    avf->data[3] = (uint8_t *)pbuf;

    avf->buf[0] = av_buffer_create(NULL, 0, cvpb_free, pbuf, 0);
    if (!avf->buf[0]) {
        av_frame_free(&avf);
        goto fail;
    }

    struct mp_image *mpi = mp_image_from_av_frame(avf);
    av_frame_free(&avf);
    if (!mpi)
        goto fail;

    mpi->params = *ref;
    mpi->params.imgfmt    = IMGFMT_VIDEOTOOLBOX;
    mpi->params.hw_subfmt = IMGFMT_NV12;   // 插值输出固定 NV12
    mpi->pts = pts;
    return mpi;

fail:
    CVPixelBufferRelease(pbuf);
    return NULL;
}

/// 软件 NV12 帧 → CVPixelBuffer（上行转换）。
/// 软解、或 vo 不支持硬件帧时，mpv 给到滤镜的是系统内存里的 nv12，
/// 而 ANE 只吃 CVPixelBuffer，所以必须自己上传一次。
static CVPixelBufferRef cvpb_from_nv12(struct mp_image *img)
{
    if (img->imgfmt != IMGFMT_NV12)
        return NULL;

    CVPixelBufferRef pb = NULL;
    CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, img->w, img->h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     NULL, &pb);
    if (r != kCVReturnSuccess || !pb)
        return NULL;

    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dstY  = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    uint8_t *dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    size_t su = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    int h = img->h;

    for (int i = 0; i < h; i++)
        memcpy(dstY + (size_t)i * sy, img->planes[0] + (size_t)i * img->stride[0], img->w);
    for (int i = 0; i < h / 2; i++)
        memcpy(dstUV + (size_t)i * su, img->planes[1] + (size_t)i * img->stride[1], img->w);

    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

/// CVPixelBuffer → 软件 NV12 帧（下行转换）。
/// 输出统一用系统内存 nv12：任何 vo（含软件 vo）都能接受，不必依赖硬件帧路径。
static struct mp_image *mpi_from_cvpb(CVPixelBufferRef pbuf,
                                      const struct mp_image_params *ref, double pts)
{
    int fmt = CVPixelBufferGetPixelFormatType(pbuf);
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        return NULL;

    CVPixelBufferLockBaseAddress(pbuf, kCVPixelBufferLock_ReadOnly);
    int w = (int)CVPixelBufferGetWidth(pbuf);
    int h = (int)CVPixelBufferGetHeight(pbuf);
    uint8_t *srcY  = CVPixelBufferGetBaseAddressOfPlane(pbuf, 0);
    uint8_t *srcUV = CVPixelBufferGetBaseAddressOfPlane(pbuf, 1);
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(pbuf, 0);
    size_t su = CVPixelBufferGetBytesPerRowOfPlane(pbuf, 1);

    struct mp_image *out = mp_image_alloc(IMGFMT_NV12, w, h);
    if (out) {
        for (int i = 0; i < h; i++)
            memcpy(out->planes[0] + (size_t)i * out->stride[0], srcY + (size_t)i * sy, w);
        for (int i = 0; i < h / 2; i++)
            memcpy(out->planes[1] + (size_t)i * out->stride[1], srcUV + (size_t)i * su, w);
        out->params = *ref;
        out->params.imgfmt = IMGFMT_NV12;
        out->params.hw_subfmt = 0;
        out->pts = pts;
    }
    CVPixelBufferUnlockBaseAddress(pbuf, kCVPixelBufferLock_ReadOnly);
    return out;
}

/// 把输入帧搬进与输出同属性的 pool buffer。
///
/// ANE 要求 sourceFrame / previousFrame / destinationFrames 三者属性完全一致，
/// 手工 CVPixelBufferCreate 出来的帧与 pool 产物 backing 不同，会让参数对象构造失败（返回 nil），
/// 所以输入也必须从同一个池里分配再拷进去。
static CVPixelBufferRef pool_buffer_from(struct mp_filter *f, struct mp_image *img)
{
    struct priv *p = f->priv;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->pool, &dst) != kCVReturnSuccess)
        return NULL;
    if (!dst)
        return NULL;
    int dw = (int)CVPixelBufferGetWidth(dst);
    int dh = (int)CVPixelBufferGetHeight(dst);
    int w  = img->w < dw ? img->w : dw;
    int h  = img->h < dh ? img->h : dh;

    CVPixelBufferLockBaseAddress(dst, 0);
    uint8_t *dY  = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    uint8_t *dUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t dsY  = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    size_t dsUV = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);

    CVPixelBufferRef src = (img->imgfmt == IMGFMT_VIDEOTOOLBOX)
                              ? (CVPixelBufferRef)img->planes[3] : NULL;
    if (src && CVPixelBufferGetPlaneCount(src) >= 2) {
        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        uint8_t *sY  = CVPixelBufferGetBaseAddressOfPlane(src, 0);
        uint8_t *sUV = CVPixelBufferGetBaseAddressOfPlane(src, 1);
        size_t ssY  = CVPixelBufferGetBytesPerRowOfPlane(src, 0);
        size_t ssUV = CVPixelBufferGetBytesPerRowOfPlane(src, 1);
        for (int i = 0; i < h; i++)
            memcpy(dY  + (size_t)i * dsY,  sY  + (size_t)i * ssY,  w);
        for (int i = 0; i < h / 2; i++)
            memcpy(dUV + (size_t)i * dsUV, sUV + (size_t)i * ssUV, w);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    } else if (img->imgfmt == IMGFMT_NV12) {
        for (int i = 0; i < h; i++)
            memcpy(dY  + (size_t)i * dsY,  img->planes[0] + (size_t)i * img->stride[0], w);
        for (int i = 0; i < h / 2; i++)
            memcpy(dUV + (size_t)i * dsUV, img->planes[1] + (size_t)i * img->stride[1], w);
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return dst;
}

static bool push_pending(struct mp_filter *f, struct mp_image *mpi)
{
    struct priv *p = f->priv;
    if (p->pending_n >= ANE_MAX_OUT) {
        MP_WARN(f, "输出队列已满，丢弃一帧\n");
        talloc_free(mpi);
        return false;
    }
    p->pending[p->pending_n++] = mpi;
    return true;
}

/// 对 prev/cur 两帧做插帧，产出 want 张中间帧。
/// 返回实际生成的帧数；调用方获得 outs[] 里每个 CVPixelBuffer 的所有权。
static int ane_interp(struct mp_filter *f, CVPixelBufferRef prev, CVPixelBufferRef cur,
                      double prev_pts, double cur_pts, CVPixelBufferRef *outs, int want)
{
    struct priv *p = f->priv;
    // __block 变量带 cleanup 属性，必须声明在任何 goto 之前：
    // goto 跨越其初始化会编译报错（cannot jump from this goto statement to its label）。
    __block BOOL done = NO;
    __block BOOL failed = NO;
    dispatch_semaphore_t sem = NULL;
    int result = 0;

    @autoreleasepool {
        // 相位：Apple 硬件把插值相位量化到 1/8 格点。
        // 2x -> [0.5]；4x -> [0.25, 0.5, 0.75]，全部落在格点上。
        NSMutableArray *phases = [NSMutableArray arrayWithCapacity:want];
        for (int i = 0; i < want; i++)
            [phases addObject:@((double)(i + 1) / (double)(want + 1))];

        NSMutableArray *dstFrames = [NSMutableArray arrayWithCapacity:want];
        NSMutableArray *dstBufs   = [NSMutableArray arrayWithCapacity:want];

        for (int i = 0; i < want; i++) {
            CVPixelBufferRef buf = NULL;
            CVReturn cr = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->pool, &buf);
            if (p->n_in <= 3)
                MP_INFO(f, "[ANE-DIAG] 池分配#%d cr=%d buf=%p %s\n", i, (int)cr, (void *)buf,
                        buf ? [[NSString stringWithFormat:@"%dx%d fmt=0x%x",
                                (int)CVPixelBufferGetWidth(buf), (int)CVPixelBufferGetHeight(buf),
                                (unsigned)CVPixelBufferGetPixelFormatType(buf)] UTF8String] : "");
            if (cr != kCVReturnSuccess || !buf)
                break;
            double t = prev_pts + (cur_pts - prev_pts) * ((double)(i + 1) / (want + 1));
            CMTime ct = CMTimeMakeWithSeconds(t, 1000000);
            VTFrameProcessorFrame *fr =
                [[VTFrameProcessorFrame alloc] initWithBuffer:buf presentationTimeStamp:ct];
            if (!fr) {
                CVPixelBufferRelease(buf);
                break;
            }
            [dstBufs addObject:(__bridge id)buf];
            [dstFrames addObject:fr];
            // 关键：fr 是 alloc 出来的，加进数组只多了一份引用，
            // 我们自己这份必须还回去。否则每帧漏一个 VTFrameProcessorFrame，
            // 它持有目的帧 CVPixelBuffer（1080p NV12 ≈ 3MB），
            // 内存就会一路涨到把 RAM 吃光、系统疯狂建 swapfile。
            ANE_REL(fr);
        }

        if ((int)dstFrames.count != want) {
            MP_ERR(f, "[ANE-DIAG] 目标帧不足 %d/%d\n", (int)dstFrames.count, want);
            goto cleanup;
        }

        CMTime tp = CMTimeMakeWithSeconds(prev_pts, 1000000);
        CMTime tc = CMTimeMakeWithSeconds(cur_pts, 1000000);
        VTFrameProcessorFrame *pf =
            [[VTFrameProcessorFrame alloc] initWithBuffer:prev presentationTimeStamp:tp];
        VTFrameProcessorFrame *sf =
            [[VTFrameProcessorFrame alloc] initWithBuffer:cur  presentationTimeStamp:tc];

        VTLowLatencyFrameInterpolationParameters *params =
            [[VTLowLatencyFrameInterpolationParameters alloc]
                initWithSourceFrame:sf previousFrame:pf
                 interpolationPhase:phases destinationFrames:dstFrames];

        if (!params) {
            MP_ERR(f, "[ANE-DIAG] VTLowLatencyFrameInterpolationParameters 构造失败\n");
            ANE_REL(pf);
            ANE_REL(sf);
            goto cleanup;
        }

        sem = dispatch_semaphore_create(0);
        [p->processor processWithParameters:params
                          completionHandler:^(id<VTFrameProcessorParameters> pp, NSError *e) {
            if (e) {
                failed = YES;
                MP_ERR(f, "[ANE-DIAG] 插帧回调报错: %s\n",
                       e.localizedDescription.UTF8String ?: "(无描述)");
            }
            done = YES;
            dispatch_semaphore_signal(sem);
        }];

        // 同步等待。engine 卡住时不能无限等，否则整个播放线程被堵死。
        long waited = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ANE_TIMEOUT_SEC * NSEC_PER_SEC)));

        ANE_REL(pf);
        ANE_REL(sf);
        ANE_REL(params);

        if (waited != 0 || failed) {
            // 超时后 completion 仍可能回调并 signal 一个即将出作用域的信号量，
            // 这里短等一下确保回调已执行，杜绝悬空信号导致的崩溃。
            int drain = 0;
            while (!done && drain++ < 20)
                dispatch_semaphore_wait(sem,
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)));
            p->n_fail++;
            goto cleanup;
        }

        for (int i = 0; i < want; i++)
            outs[i] = (__bridge CVPixelBufferRef)dstBufs[i];
        p->n_interp += want;
        result = want;
        return result;

cleanup:
        for (id b in dstBufs)
            CVPixelBufferRelease((__bridge CVPixelBufferRef)b);
        result = 0;
    }

    return result;
}

/// 处理一帧视频帧：产生「中间插值帧 + 当前帧」放入待输出队列。
static void handle_frame(struct mp_filter *f, struct mp_frame frame)
{
    struct priv *p = f->priv;
    struct mp_image *img = frame.data;
    p->n_in++;

    if (ane_vf_passthrough) {
        // 跳转中：原样放行。同时把上一帧扔掉，避免恢复后拿「跳转前」的帧去配对
        if (p->prev) { CVPixelBufferRelease(p->prev); p->prev = NULL; }
        push_pending(f, img);
        return;
    }

    // 先建立 session：pool 存在后才能分配与输出同属性的 buffer
    if (p->opts->factor < 2 || !ensure_session(f, img->w, img->h)) {
        if (p->n_in <= 3) {
            MP_INFO(f, "[ANE-DIAG] -> 直通，原因: %s\n",
                    p->opts->factor < 2 ? "factor<2" : "ensure_session 失败（见上方错误）");
        }
        push_pending(f, img);
        return;
    }

    // 当前帧统一搬进 pool buffer：源帧 / 参考帧 / 目标帧必须属性一致，
    // 否则 VTLowLatencyFrameInterpolationParameters 会直接返回 nil。
    CVPixelBufferRef cur = pool_buffer_from(f, img);
    if (!cur) {
        if (p->n_in <= 3)
            MP_ERR(f, "[ANE-DIAG] pool buffer 分配失败\n");
        push_pending(f, img);
        return;
    }

    if (p->n_in <= 3) {
        MP_INFO(f, "[ANE-DIAG] 第%d帧 入=%s(%d) %dx%d -> 池帧 %dx%d fmt=0x%x\n",
                p->n_in, mp_imgfmt_to_name(img->imgfmt), (int)img->imgfmt, img->w, img->h,
                (int)CVPixelBufferGetWidth(cur), (int)CVPixelBufferGetHeight(cur),
                (unsigned)CVPixelBufferGetPixelFormatType(cur));
    }

    double pts = img->pts;
    int want = p->opts->factor - 1;

    if (p->prev) {
        CVPixelBufferRef outs[ANE_MAX_OUT] = {0};
        int got = ane_interp(f, p->prev, cur, p->prev_pts, pts, outs, want);
        if (p->n_in <= 3 || p->n_in % 60 == 0) {
            MP_INFO(f, "[ANE-DIAG] 插帧: 请求%d 实得%d\n", want, got);
        }
        for (int i = 0; i < got; i++) {
            double t = p->prev_pts + (pts - p->prev_pts) * ((double)(i + 1) / (want + 1));
            struct mp_image *mpi = mpi_from_cvpb(outs[i], &p->prev_params, t);
            if (mpi)
                push_pending(f, mpi);
            CVPixelBufferRelease(outs[i]);
        }
    }

    // 统一以软件 nv12 输出：不向下游混发硬件帧与软件帧
    if (img->imgfmt == IMGFMT_VIDEOTOOLBOX) {
        struct mp_image *sw = mpi_from_cvpb(cur, &img->params, img->pts);
        if (sw) {
            talloc_free(img);
            push_pending(f, sw);
        } else {
            push_pending(f, img);
        }
    } else {
        push_pending(f, img);
    }

    // 当前帧成为下一轮的「前一帧」。CVPixelBuffer 由我们 retain，
    // 与 mp_image 的生命周期解耦（mp_image 写出后即释放）。
    if (p->prev)
        CVPixelBufferRelease(p->prev);
    p->prev = cur;
    CVPixelBufferRetain(p->prev);
    CVPixelBufferRelease(cur);   // cur 始终由本函数从 pool 分配，交还自己的引用
    p->prev_pts = pts;
    p->prev_params = img->params;
}

static void vf_ane_process(struct mp_filter *f)
{
    struct priv *p = f->priv;
    struct mp_autoconvert *c = p->conv;

    for (;;) {
        // 1) 先把待输出队列尽量写出去（一帧输入会产生多帧输出）
        if (p->pending_n > 0) {
            if (!mp_pin_in_needs_data(f->ppins[1]))
                return;
            struct mp_frame fr = { .type = MP_FRAME_VIDEO, .data = p->pending[0] };
            mp_pin_in_write(f->ppins[1], fr);
            for (int i = 1; i < p->pending_n; i++)
                p->pending[i - 1] = p->pending[i];
            p->pending[--p->pending_n] = NULL;
            p->n_out++;
            continue;
        }

        if (p->eof_queued) {
            mp_pin_in_write(f->ppins[1], MP_EOF_FRAME);
            p->eof_queued = false;
            continue;
        }

        // 2) 自动转换器的输出 → 我们（此时格式已保证符合要求）
        if (mp_pin_can_transfer_data(f->ppins[1], c->f->pins[1])) {
            struct mp_frame frame = mp_pin_out_read(c->f->pins[1]);
            if (!frame.type)
                return;
            if (frame.type == MP_FRAME_EOF) {
                p->eof_queued = true;
                continue;
            }
            if (frame.type != MP_FRAME_VIDEO) {
                mp_pin_in_write(f->ppins[1], frame);
                continue;
            }
            handle_frame(f, frame);
            continue;
        }

        // 3) 上游 → 自动转换器输入
        if (mp_pin_can_transfer_data(c->f->pins[0], f->ppins[0])) {
            struct mp_frame frame = mp_pin_out_read(f->ppins[0]);
            if (frame.type)
                mp_pin_in_write(c->f->pins[0], frame);
            continue;
        }

        return;
    }
}

/// seek / 重新初始化时必须清空：不能让上一帧跨越 seek 与下一帧配对。
static void vf_ane_reset(struct mp_filter *f)
{
    struct priv *p = f->priv;
    drop_pending_all(p);
    if (p->prev) {
        CVPixelBufferRelease(p->prev);
        p->prev = NULL;
    }
    p->eof_queued = false;
}

static void vf_ane_destroy(struct mp_filter *f)
{
    struct priv *p = f->priv;
    drop_pending_all(p);
    if (p->prev)
        CVPixelBufferRelease(p->prev);
    end_session(p);
    MP_VERBOSE(f, "ANE 统计：输入 %lld / 输出 %lld / 插值 %lld / 失败 %lld\n",
               (long long)p->n_in, (long long)p->n_out,
               (long long)p->n_interp, (long long)p->n_fail);
}

static const struct mp_filter_info vf_ane_filter = {
    .name = "ane",
    .process = vf_ane_process,
    .reset = vf_ane_reset,
    .destroy = vf_ane_destroy,
    .priv_size = sizeof(struct priv),
};

static struct mp_filter *vf_ane_create(struct mp_filter *parent, void *options)
{
    struct mp_filter *f = mp_filter_create(parent, &vf_ane_filter);
    if (!f) {
        talloc_free(options);
        return NULL;
    }

    struct priv *priv = f->priv;
    priv->opts = talloc_steal(priv, options);

    mp_filter_add_pin(f, MP_PIN_IN, "in");
    mp_filter_add_pin(f, MP_PIN_OUT, "out");

    MP_INFO(f, "[ANE-DIAG] create 被调用：滤镜已实例化，factor=%d\n",
            priv->opts ? priv->opts->factor : -1);

    // 输入优先走 VideoToolbox 硬解帧（planes[3] 直接是 CVPixelBuffer，零拷贝）；
    // 软解时退化为系统内存 NV12，由 autoconvert 转过来。
    priv->conv = mp_autoconvert_create(f);
    if (!priv->conv) {
        talloc_free(f);
        return NULL;
    }
    mp_autoconvert_add_imgfmt(priv->conv, IMGFMT_VIDEOTOOLBOX, IMGFMT_NV12);
    mp_autoconvert_add_imgfmt(priv->conv, IMGFMT_NV12, 0);

    return f;
}

#define OPT_BASE_STRUCT struct vf_ane_opts
static const m_option_t vf_ane_opts_fields[] = {
    {"factor", OPT_CHOICE(factor, {"off", 1}, {"2x", 2}, {"4x", 4})},
    {0}
};

const struct mp_user_filter_entry vf_ane = {
    .desc = {
        .description = "ANE 神经引擎实时补帧",
        .name = "ane",
        .priv_size = sizeof(OPT_BASE_STRUCT),
        .priv_defaults = &(const OPT_BASE_STRUCT){ .factor = 2 },
        .options = vf_ane_opts_fields,
    },
    .create = vf_ane_create,
};
