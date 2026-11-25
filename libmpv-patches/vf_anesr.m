//
// vf_anesr.m — ANE 神经引擎超分滤镜（mpv 0.41）
//
// 用 Apple 的 VTLowLatencySuperResolutionScaler（macOS 26+ / Apple Silicon）
// 在 mpv 的滤镜链里把画面放大 2x。跟补帧滤镜（vf_ane）是同一套 VTFrameProcessor
// 家族，跑在神经引擎上，不经过 CPU/GPU 缩放的模糊，也不需要下载外部模型。
//
// 用法：--vf=anesr=2x      （关：--vf=anesr=off）
//

#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <dispatch/dispatch.h>

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

#if __has_feature(objc_arc)
  #define SR_REL(x) do { (void)(x); } while (0)
#else
  #define SR_REL(x) do { [(x) release]; } while (0)
#endif

#define SR_MAX_OUT      4
#define SR_TIMEOUT_SEC  2.0

struct vf_anesr_opts {
    int scale;    // 1=直通，2=2x
};

struct priv {
    struct vf_anesr_opts *opts;
    struct mp_autoconvert *conv;

    VTLowLatencySuperResolutionScalerConfiguration *config;
    VTFrameProcessor *processor;
    CVPixelBufferPoolRef srcPool;    // 源帧（w×h）
    CVPixelBufferPoolRef dstPool;    // 输出（2w×2h）
    int sw, sh, dw, dh;
    float factor;
    BOOL active;
    BOOL unsupported;

    struct mp_image *pending[SR_MAX_OUT];
    int pending_n;
    bool eof_queued;

    int64_t n_in, n_out, n_ok, n_fail;
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
        SR_REL(p->processor);
        p->processor = nil;
    }
    if (p->config) {
        SR_REL(p->config);
        p->config = nil;
    }
    if (p->srcPool) { CVPixelBufferPoolRelease(p->srcPool); p->srcPool = NULL; }
    if (p->dstPool) { CVPixelBufferPoolRelease(p->dstPool); p->dstPool = NULL; }
    p->active = NO;
}

static bool ensure_session(struct mp_filter *f, int w, int h)
{
    struct priv *p = f->priv;
    if (p->unsupported)
        return false;
    if (p->active && p->sw == w && p->sh == h)
        return true;

    end_session(p);

    if (!VTLowLatencySuperResolutionScalerConfiguration.supported) {
        MP_ERR(f, "本机不支持 VTLowLatencySuperResolutionScaler（需要 macOS 26+ 与 Apple Silicon）\n");
        p->unsupported = true;
        return false;
    }

    // 该尺寸支持哪些放大倍数（不同分辨率支持的档位不同）
    NSArray<NSNumber *> *factors =
        [VTLowLatencySuperResolutionScalerConfiguration
            supportedScaleFactorsForFrameWidth:w frameHeight:h];
    if (factors.count == 0) {
        MP_ERR(f, "%dx%d 这个尺寸不支持 ANE 超分（超出像素预算）\n", w, h);
        p->unsupported = true;
        return false;
    }

    // Apple 的模型对输入尺寸有硬上限：2x 只到 960x540，1.5x 只到 1280x720，
    // 1080p 及以上直接不支持。所以这里取「不超过期望值的最大档位」，
    // 720p 片源就会自动用 1.5x 放大到 1080p。
    float want = (float)p->opts->scale;
    float factor = 0;
    for (NSNumber *n in factors)
        if (n.floatValue <= want + 0.01f && n.floatValue > factor) factor = n.floatValue;
    if (factor <= 0) factor = factors.firstObject.floatValue;

    VTLowLatencySuperResolutionScalerConfiguration *config =
        [[VTLowLatencySuperResolutionScalerConfiguration alloc]
            initWithFrameWidth:w frameHeight:h scaleFactor:factor];
    if (!config) {
        MP_ERR(f, "创建超分配置失败（%dx%d × %.1f）\n", w, h, factor);
        p->unsupported = true;
        return false;
    }

    NSDictionary *srcAttrs = config.sourcePixelBufferAttributes;
    NSDictionary *dstAttrs = config.destinationPixelBufferAttributes;
    if (!srcAttrs || !dstAttrs) {
        MP_ERR(f, "超分配置没有给出缓冲属性\n");
        SR_REL(config);
        p->unsupported = true;
        return false;
    }

    CVPixelBufferPoolRef sp = NULL, dp = NULL;
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)srcAttrs, &sp) != kCVReturnSuccess ||
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)dstAttrs, &dp) != kCVReturnSuccess) {
        MP_ERR(f, "创建超分缓冲池失败\n");
        if (sp) CVPixelBufferPoolRelease(sp);
        SR_REL(config);
        p->unsupported = true;
        return false;
    }

    VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
    NSError *err = nil;
    if (![proc startSessionWithConfiguration:config error:&err]) {
        MP_ERR(f, "启动超分 session 失败：%s\n",
               err.localizedDescription.UTF8String ?: "未知原因");
        SR_REL(proc);
        SR_REL(config);
        CVPixelBufferPoolRelease(sp);
        CVPixelBufferPoolRelease(dp);
        p->unsupported = true;
        return false;
    }

    p->config = config;
    p->processor = proc;
    p->srcPool = sp;
    p->dstPool = dp;
    p->factor = factor;
    p->sw = w; p->sh = h;
    p->dw = (int)(w * factor);
    p->dh = (int)(h * factor);
    p->active = YES;
    MP_INFO(f, "ANE 超分 session 就绪：%dx%d → %dx%d（×%.1f）\n",
            w, h, p->dw, p->dh, factor);
    return true;
}

/// 把输入帧拷进「源」池分配的 buffer（属性必须与硬件要求一致）
static CVPixelBufferRef source_buffer_from(struct mp_filter *f, struct mp_image *img)
{
    struct priv *p = f->priv;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->srcPool, &dst) != kCVReturnSuccess)
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
            memcpy(dY + (size_t)i * dsY, sY + (size_t)i * ssY, w);
        for (int i = 0; i < h / 2; i++)
            memcpy(dUV + (size_t)i * dsUV, sUV + (size_t)i * ssUV, w);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    } else if (img->imgfmt == IMGFMT_NV12) {
        for (int i = 0; i < h; i++)
            memcpy(dY + (size_t)i * dsY, img->planes[0] + (size_t)i * img->stride[0], w);
        for (int i = 0; i < h / 2; i++)
            memcpy(dUV + (size_t)i * dsUV, img->planes[1] + (size_t)i * img->stride[1], w);
    }
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return dst;
}

/// CVPixelBuffer → mp_image（保持画面比例，宽高按新尺寸重设）
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
        out->params.w = w;
        out->params.h = h;
        // 像素宽高比跟着放大，否则下游会算错显示比例
        if (ref->p_w > 0 && ref->p_h > 0 && ref->w > 0 && ref->h > 0) {
            out->params.p_w = ref->p_w * w / ref->w;
            out->params.p_h = ref->p_h * h / ref->h;
        }
        if (ref->crop.x1 > ref->crop.x0 && ref->crop.y1 > ref->crop.y0) {
            float fx = (float)w / (float)ref->w;
            float fy = (float)h / (float)ref->h;
            out->params.crop.x0 = (int)(ref->crop.x0 * fx);
            out->params.crop.x1 = (int)(ref->crop.x1 * fx);
            out->params.crop.y0 = (int)(ref->crop.y0 * fy);
            out->params.crop.y1 = (int)(ref->crop.y1 * fy);
        }
        out->pts = pts;
    }
    CVPixelBufferUnlockBaseAddress(pbuf, kCVPixelBufferLock_ReadOnly);
    return out;
}

static bool push_pending(struct mp_filter *f, struct mp_image *mpi)
{
    struct priv *p = f->priv;
    if (p->pending_n >= SR_MAX_OUT) {
        MP_WARN(f, "输出队列已满，丢弃一帧\n");
        talloc_free(mpi);
        return false;
    }
    p->pending[p->pending_n++] = mpi;
    return true;
}

/// 同步跑一次超分：成功返回输出 CVPixelBuffer（调用方持有）
static CVPixelBufferRef ane_upscale(struct mp_filter *f, CVPixelBufferRef src, double pts)
{
    struct priv *p = f->priv;
    __block BOOL done = NO, failed = NO;
    dispatch_semaphore_t sem = NULL;
    CVPixelBufferRef dst = NULL;

    @autoreleasepool {
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->dstPool, &dst)
                != kCVReturnSuccess || !dst)
            return NULL;

        CMTime t = CMTimeMakeWithSeconds(pts, 1000000);
        VTFrameProcessorFrame *sf =
            [[VTFrameProcessorFrame alloc] initWithBuffer:src presentationTimeStamp:t];
        VTFrameProcessorFrame *df =
            [[VTFrameProcessorFrame alloc] initWithBuffer:dst presentationTimeStamp:t];
        if (!sf || !df) {
            if (sf) SR_REL(sf);
            if (df) SR_REL(df);
            CVPixelBufferRelease(dst);
            return NULL;
        }

        VTLowLatencySuperResolutionScalerParameters *params =
            [[VTLowLatencySuperResolutionScalerParameters alloc]
                initWithSourceFrame:sf destinationFrame:df];
        if (!params) {
            MP_ERR(f, "超分参数构造失败\n");
            SR_REL(sf); SR_REL(df);
            CVPixelBufferRelease(dst);
            return NULL;
        }

        sem = dispatch_semaphore_create(0);
        [p->processor processWithParameters:params
                          completionHandler:^(id<VTFrameProcessorParameters> pp, NSError *e) {
            if (e) {
                failed = YES;
                MP_ERR(f, "超分回调报错: %s\n", e.localizedDescription.UTF8String ?: "(无描述)");
            }
            done = YES;
            dispatch_semaphore_signal(sem);
        }];

        long waited = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SR_TIMEOUT_SEC * NSEC_PER_SEC)));

        SR_REL(sf); SR_REL(df); SR_REL(params);

        if (waited != 0 || failed) {
            int drain = 0;
            while (!done && drain++ < 20)
                dispatch_semaphore_wait(sem,
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)));
            p->n_fail++;
            CVPixelBufferRelease(dst);
            return NULL;
        }
    }
    p->n_ok++;
    return dst;
}

extern int ane_vf_passthrough;   // 定义在 vf_ane.m

static void handle_frame(struct mp_filter *f, struct mp_frame frame)
{
    struct priv *p = f->priv;
    struct mp_image *img = frame.data;
    p->n_in++;

    if (ane_vf_passthrough) { push_pending(f, img); return; }   // 跳转中：不超分

    if (p->opts->scale < 2 || !ensure_session(f, img->w, img->h)) {
        if (p->n_in <= 3)
            MP_INFO(f, "[ANE-SR] 直通（scale=%d）\n", p->opts->scale);
        push_pending(f, img);
        return;
    }

    CVPixelBufferRef src = source_buffer_from(f, img);
    if (!src) {
        push_pending(f, img);
        return;
    }

    CVPixelBufferRef dst = ane_upscale(f, src, img->pts);
    CVPixelBufferRelease(src);

    if (!dst) {
        push_pending(f, img);      // 失败就原样放行，绝不卡住播放
        return;
    }

    struct mp_image *out = mpi_from_cvpb(dst, &img->params, img->pts);
    CVPixelBufferRelease(dst);
    if (!out) {
        push_pending(f, img);
        return;
    }

    if (p->n_in <= 3 || p->n_in % 120 == 0)
        MP_INFO(f, "[ANE-SR] %dx%d → %dx%d\n", img->w, img->h, out->w, out->h);

    talloc_free(img);
    push_pending(f, out);
}

static void vf_anesr_process(struct mp_filter *f)
{
    struct priv *p = f->priv;
    struct mp_autoconvert *c = p->conv;

    for (;;) {
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

        if (mp_pin_can_transfer_data(c->f->pins[0], f->ppins[0])) {
            struct mp_frame frame = mp_pin_out_read(f->ppins[0]);
            if (frame.type)
                mp_pin_in_write(c->f->pins[0], frame);
            continue;
        }

        return;
    }
}

static void vf_anesr_reset(struct mp_filter *f)
{
    struct priv *p = f->priv;
    drop_pending_all(p);
    p->eof_queued = false;
}

static void vf_anesr_destroy(struct mp_filter *f)
{
    struct priv *p = f->priv;
    drop_pending_all(p);
    end_session(p);
    MP_VERBOSE(f, "ANE-SR 统计：输入 %lld / 输出 %lld / 成功 %lld / 失败 %lld\n",
               (long long)p->n_in, (long long)p->n_out,
               (long long)p->n_ok, (long long)p->n_fail);
}

static const struct mp_filter_info vf_anesr_filter = {
    .name = "anesr",
    .process = vf_anesr_process,
    .reset = vf_anesr_reset,
    .destroy = vf_anesr_destroy,
    .priv_size = sizeof(struct priv),
};

static struct mp_filter *vf_anesr_create(struct mp_filter *parent, void *options)
{
    struct mp_filter *f = mp_filter_create(parent, &vf_anesr_filter);
    if (!f) {
        talloc_free(options);
        return NULL;
    }

    struct priv *priv = f->priv;
    priv->opts = talloc_steal(priv, options);

    mp_filter_add_pin(f, MP_PIN_IN, "in");
    mp_filter_add_pin(f, MP_PIN_OUT, "out");

    priv->conv = mp_autoconvert_create(f);
    if (!priv->conv) {
        talloc_free(f);
        return NULL;
    }
    mp_autoconvert_add_imgfmt(priv->conv, IMGFMT_VIDEOTOOLBOX, IMGFMT_NV12);
    mp_autoconvert_add_imgfmt(priv->conv, IMGFMT_NV12, 0);

    return f;
}

#define OPT_BASE_STRUCT struct vf_anesr_opts
static const m_option_t vf_anesr_opts_fields[] = {
    {"scale", OPT_CHOICE(scale, {"off", 1}, {"2x", 2}, {"3x", 3}, {"4x", 4})},
    {0}
};

const struct mp_user_filter_entry vf_anesr = {
    .desc = {
        .description = "ANE 神经引擎超分",
        .name = "anesr",
        .priv_size = sizeof(OPT_BASE_STRUCT),
        .priv_defaults = &(const OPT_BASE_STRUCT){ .scale = 2 },
        .options = vf_anesr_opts_fields,
    },
    .create = vf_anesr_create,
};
