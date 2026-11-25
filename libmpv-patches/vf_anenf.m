//
// vf_anenf.m — ANE 神经引擎时域降噪滤镜（mpv 0.41）
//
// 用 Apple 的 VTTemporalNoiseFilter（macOS 26+ / Apple Silicon），跑在神经引擎上，
// 只降噪、不改分辨率。它是「时域」降噪：拿前后几帧做运动估计，
// 把随机噪点和不属于任何一帧的压缩伪影抹掉，而真正的细节（线条、文字）会保留。
//
// 代价：需要未来 2 帧做参考，所以画面会延迟 2 帧（24fps ≈ 83ms）。
//
// 用法：--vf=anenf=0.5   （强度 0..1，0 或 off 关闭）
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
  #define NF_REL(x) do { (void)(x); } while (0)
#else
  #define NF_REL(x) do { [(x) release]; } while (0)
#endif

// 队列深度：前一帧 + 当前帧 + 后两帧 = 4。再加一格余量便于搬移。
#define NF_RING     5
#define NF_MAX_OUT  8
#define NF_TIMEOUT_SEC 2.0

// 8-bit biplanar video range。macOS 26 给这套格式换了新的 fourcc（'&8v0'），
// VTTemporalNoiseFilter 只认新表里的值，老的 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
// 会被判为「不支持的像素格式」。
#define NF_FMT_8V0  641234480

struct vf_anenf_opts {
    float strength;   // 0..1
};

struct nf_frame {
    CVPixelBufferRef buf;
    double pts;
    struct mp_image_params params;
};

struct priv {
    struct vf_anenf_opts *opts;
    struct mp_autoconvert *conv;

    VTTemporalNoiseFilterConfiguration *config;
    VTFrameProcessor *processor;
    CVPixelBufferPoolRef srcPool;    // config 指定的格式（'&8v0'），喂给 TNF
    CVPixelBufferPoolRef dstPool;    // 同上，输出
    CVPixelBufferPoolRef rawPool;    // 420v，我们自己填/读像素用（bpr 可靠）
    VTPixelTransferSessionRef xfer;  // 两种格式之间转换
    OSType fmt;
    int w, h;
    BOOL active;
    BOOL unsupported;

    struct nf_frame ring[NF_RING];
    int ring_n;

    struct mp_image *pending[NF_MAX_OUT];
    int pending_n;
    bool eof_queued;

    int64_t n_in, n_out, n_ok, n_fail;
};

static void ring_clear(struct priv *p)
{
    for (int i = 0; i < p->ring_n; i++) {
        if (p->ring[i].buf)
            CVPixelBufferRelease(p->ring[i].buf);
        p->ring[i].buf = NULL;
    }
    p->ring_n = 0;
}

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
        NF_REL(p->processor);
        p->processor = nil;
    }
    if (p->config) {
        NF_REL(p->config);
        p->config = nil;
    }
    if (p->srcPool) { CVPixelBufferPoolRelease(p->srcPool); p->srcPool = NULL; }
    if (p->dstPool) { CVPixelBufferPoolRelease(p->dstPool); p->dstPool = NULL; }
    if (p->rawPool) { CVPixelBufferPoolRelease(p->rawPool); p->rawPool = NULL; }
    if (p->xfer) { CFRelease(p->xfer); p->xfer = NULL; }
    p->active = NO;
}

static bool ensure_session(struct mp_filter *f, int w, int h)
{
    struct priv *p = f->priv;
    if (p->unsupported)
        return false;
    if (p->active && p->w == w && p->h == h)
        return true;

    end_session(p);
    ring_clear(p);

    if (!VTTemporalNoiseFilterConfiguration.supported) {
        MP_ERR(f, "本机不支持 VTTemporalNoiseFilter（需要 macOS 26+ 与 Apple Silicon）\n");
        p->unsupported = true;
        return false;
    }

    // 先试「8-bit biplanar video range」，被拒就退到系统自报的可用格式
    NSArray<NSNumber *> *fmts = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats;
    OSType tried[2] = { NF_FMT_8V0, 0 };
    if (fmts.count)
        tried[1] = (OSType)fmts.firstObject.unsignedIntValue;

    VTTemporalNoiseFilterConfiguration *config = nil;
    OSType used = 0;
    for (int i = 0; i < 2 && !config; i++) {
        if (!tried[i] || (i == 1 && tried[1] == tried[0]))
            continue;
        config = [[VTTemporalNoiseFilterConfiguration alloc]
                    initWithFrameWidth:w frameHeight:h sourcePixelFormat:tried[i]];
        if (config)
            used = tried[i];
    }
    if (!config) {
        MP_ERR(f, "%dx%d 创建降噪配置失败（像素格式不被接受）\n", w, h);
        p->unsupported = true;
        return false;
    }

    NSDictionary *srcAttrs = config.sourcePixelBufferAttributes;
    NSDictionary *dstAttrs = config.destinationPixelBufferAttributes;
    CVPixelBufferPoolRef sp = NULL, dp = NULL;
    if (!srcAttrs || !dstAttrs ||
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)srcAttrs, &sp) != kCVReturnSuccess ||
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)dstAttrs, &dp) != kCVReturnSuccess) {
        MP_ERR(f, "创建降噪缓冲池失败\n");
        if (sp) CVPixelBufferPoolRelease(sp);
        if (dp) CVPixelBufferPoolRelease(dp);
        NF_REL(config);
        p->unsupported = true;
        return false;
    }

    VTFrameProcessor *proc = [[VTFrameProcessor alloc] init];
    NSError *err = nil;
    if (![proc startSessionWithConfiguration:config error:&err]) {
        MP_ERR(f, "启动降噪 session 失败：%s\n",
               err.localizedDescription.UTF8String ?: "未知原因");
        NF_REL(proc);
        NF_REL(config);
        CVPixelBufferPoolRelease(sp);
        CVPixelBufferPoolRelease(dp);
        p->unsupported = true;
        return false;
    }

    // 自己再建一份 420v 的池：config 给的那个格式（'&8v0'）行步长是内部编码过的，
    // CVPixelBufferGetBytesPerRowOfPlane 返回的值不能直接用，手工 memcpy 会越界。
    NSDictionary *rawAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferPoolRef rp = NULL;
    VTPixelTransferSessionRef xs = NULL;
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)rawAttrs, &rp) != kCVReturnSuccess ||
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &xs) != noErr) {
        MP_ERR(f, "创建降噪中转缓冲/转换会话失败\n");
        if (rp) CVPixelBufferPoolRelease(rp);
        if (xs) CFRelease(xs);
        NF_REL(proc); NF_REL(config);
        CVPixelBufferPoolRelease(sp);
        CVPixelBufferPoolRelease(dp);
        p->unsupported = true;
        return false;
    }

    p->config = config;
    p->processor = proc;
    p->srcPool = sp;
    p->dstPool = dp;
    p->rawPool = rp;
    p->xfer = xs;
    p->fmt = used;
    p->w = w;
    p->h = h;
    p->active = YES;
    MP_INFO(f, "ANE 降噪 session 就绪：%dx%d（参考帧 前%ld / 后%ld，强度 %.2f）\n",
            w, h, (long)config.previousFrameCount, (long)config.nextFrameCount,
            p->opts->strength);
    return true;
}

/// 把一帧拷进「源」池的 buffer（属性必须与硬件要求一致）
static CVPixelBufferRef nf_buffer_from(struct mp_filter *f, struct mp_image *img)
{
    struct priv *p = f->priv;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->rawPool, &dst)
            != kCVReturnSuccess || !dst)
        return NULL;

    int dw = (int)CVPixelBufferGetWidth(dst);
    int dh = (int)CVPixelBufferGetHeight(dst);
    int w = img->w < dw ? img->w : dw;
    int h = img->h < dh ? img->h : dh;

    CVPixelBufferLockBaseAddress(dst, 0);
    uint8_t *dY  = CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    uint8_t *dUV = CVPixelBufferGetPlaneCount(dst) > 1
                       ? CVPixelBufferGetBaseAddressOfPlane(dst, 1) : NULL;
    size_t dsY  = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    size_t dsUV = dUV ? CVPixelBufferGetBytesPerRowOfPlane(dst, 1) : 0;

    if (img->imgfmt != IMGFMT_NV12 || !img->planes[0] || !img->planes[1]) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        CVPixelBufferRelease(dst);
        return NULL;    // 不是 NV12：交给上游 autoconvert，宁可不处理也不猜布局
    }
    for (int i = 0; i < h; i++)
        memcpy(dY + (size_t)i * dsY, img->planes[0] + (size_t)i * img->stride[0], w);
    if (dUV)
        for (int i = 0; i < h / 2; i++)
            memcpy(dUV + (size_t)i * dsUV, img->planes[1] + (size_t)i * img->stride[1], w);
    CVPixelBufferUnlockBaseAddress(dst, 0);

    // 转到 TNF 要求的格式
    CVPixelBufferRef cvt = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->srcPool, &cvt)
            != kCVReturnSuccess || !cvt) {
        CVPixelBufferRelease(dst);
        return NULL;
    }
    OSStatus st = VTPixelTransferSessionTransferImage(p->xfer, dst, cvt);
    CVPixelBufferRelease(dst);
    if (st != noErr) {
        MP_ERR(f, "降噪输入格式转换失败：%d\n", (int)st);
        CVPixelBufferRelease(cvt);
        return NULL;
    }
    return cvt;
}

/// CVPixelBuffer → mp_image（尺寸不变，沿用参考帧的参数/时间戳）
static struct mp_image *mpi_from_cvpb(CVPixelBufferRef pbuf,
                                      const struct mp_image_params *ref, double pts)
{
    int fmt = CVPixelBufferGetPixelFormatType(pbuf);
    if (fmt != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        fmt != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        fmt != NF_FMT_8V0)
        return NULL;

    CVPixelBufferLockBaseAddress(pbuf, kCVPixelBufferLock_ReadOnly);
    int w = (int)CVPixelBufferGetWidth(pbuf);
    int h = (int)CVPixelBufferGetHeight(pbuf);
    uint8_t *srcY  = CVPixelBufferGetBaseAddressOfPlane(pbuf, 0);
    uint8_t *srcUV = CVPixelBufferGetPlaneCount(pbuf) > 1
                         ? CVPixelBufferGetBaseAddressOfPlane(pbuf, 1) : NULL;
    size_t sy = CVPixelBufferGetBytesPerRowOfPlane(pbuf, 0);
    size_t su = srcUV ? CVPixelBufferGetBytesPerRowOfPlane(pbuf, 1) : 0;

    struct mp_image *out = mp_image_alloc(IMGFMT_NV12, w, h);
    if (out) {
        for (int i = 0; i < h; i++)
            memcpy(out->planes[0] + (size_t)i * out->stride[0], srcY + (size_t)i * sy, w);
        if (srcUV)
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

static bool push_pending(struct mp_filter *f, struct mp_image *mpi)
{
    struct priv *p = f->priv;
    if (p->pending_n >= NF_MAX_OUT) {
        MP_WARN(f, "输出队列已满，丢弃一帧\n");
        talloc_free(mpi);
        return false;
    }
    p->pending[p->pending_n++] = mpi;
    return true;
}

/// 同步跑一次降噪。prev 可为空（至少要有 next 的一帧）
static CVPixelBufferRef nf_run(struct mp_filter *f, struct nf_frame *cur,
                               struct nf_frame *prev,
                               struct nf_frame **next, int next_n)
{
    struct priv *p = f->priv;
    __block BOOL done = NO, failed = NO;
    CVPixelBufferRef out = NULL;
    dispatch_semaphore_t sem = NULL;

    @autoreleasepool {
        if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->dstPool, &out)
                != kCVReturnSuccess || !out)
            return NULL;

        CMTime t = CMTimeMakeWithSeconds(cur->pts, 1000000);
        VTFrameProcessorFrame *sf =
            [[VTFrameProcessorFrame alloc] initWithBuffer:cur->buf presentationTimeStamp:t];
        VTFrameProcessorFrame *df =
            [[VTFrameProcessorFrame alloc] initWithBuffer:out presentationTimeStamp:t];
        if (!sf || !df) {
            if (sf) NF_REL(sf);
            if (df) NF_REL(df);
            CVPixelBufferRelease(out);
            return NULL;
        }

        NSMutableArray<VTFrameProcessorFrame *> *prevArr = [NSMutableArray array];
        if (prev) {
            VTFrameProcessorFrame *pf = [[VTFrameProcessorFrame alloc]
                initWithBuffer:prev->buf
                presentationTimeStamp:CMTimeMakeWithSeconds(prev->pts, 1000000)];
            if (pf) { [prevArr addObject:pf]; NF_REL(pf); }   // 数组已 retain，自己这份要还
        }
        NSMutableArray<VTFrameProcessorFrame *> *nextArr = [NSMutableArray array];
        for (int i = 0; i < next_n; i++) {
            VTFrameProcessorFrame *nf = [[VTFrameProcessorFrame alloc]
                initWithBuffer:next[i]->buf
                presentationTimeStamp:CMTimeMakeWithSeconds(next[i]->pts, 1000000)];
            if (nf) { [nextArr addObject:nf]; NF_REL(nf); }   // 同上，否则每帧漏一个帧对象
        }
        if (!prevArr.count && !nextArr.count) {
            NF_REL(sf); NF_REL(df);
            CVPixelBufferRelease(out);
            return NULL;    // 没有任何参考帧，处理不了
        }

        VTTemporalNoiseFilterParameters *params =
            [[VTTemporalNoiseFilterParameters alloc]
                initWithSourceFrame:sf
                         nextFrames:nextArr
                     previousFrames:prevArr
                   destinationFrame:df
                     filterStrength:p->opts->strength
                   hasDiscontinuity:NO];
        if (!params) {
            MP_ERR(f, "降噪参数构造失败\n");
            NF_REL(sf); NF_REL(df);
            CVPixelBufferRelease(out);
            return NULL;
        }

        sem = dispatch_semaphore_create(0);
        [p->processor processWithParameters:params
                          completionHandler:^(id<VTFrameProcessorParameters> pp, NSError *e) {
            if (e) {
                failed = YES;
                MP_ERR(f, "降噪回调报错: %s\n", e.localizedDescription.UTF8String ?: "(无描述)");
            }
            done = YES;
            dispatch_semaphore_signal(sem);
        }];

        long waited = dispatch_semaphore_wait(sem,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NF_TIMEOUT_SEC * NSEC_PER_SEC)));

        NF_REL(sf); NF_REL(df); NF_REL(params);

        if (waited != 0 || failed) {
            p->n_fail++;
            CVPixelBufferRelease(out);
            return NULL;
        }
    }
    p->n_ok++;
    return out;
}

/// 处理 ring[at]，用它的邻居做参考；成功则把结果压进输出队列
static void process_at(struct mp_filter *f, int at, bool has_prev, int next_cnt)
{
    struct priv *p = f->priv;
    struct nf_frame *cur = &p->ring[at];
    struct nf_frame *prev = has_prev ? &p->ring[at - 1] : NULL;
    struct nf_frame *nx[2];
    int n = 0;
    for (int i = 1; i <= next_cnt && at + i < p->ring_n && n < 2; i++)
        nx[n++] = &p->ring[at + i];

    CVPixelBufferRef out = nf_run(f, cur, prev, nx, n);
    if (!out) {
        // 处理失败：这一帧直接丢掉。播放器宁可少一帧，也不能拿失效的 buffer 去拷
        p->n_fail++;
        return;
    }

    CVPixelBufferRef back = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p->rawPool, &back)
            == kCVReturnSuccess && back) {
        OSStatus st = VTPixelTransferSessionTransferImage(p->xfer, out, back);
        if (st != noErr) {
            MP_ERR(f, "降噪输出格式转换失败：%d\n", (int)st);
            CVPixelBufferRelease(back);
            back = NULL;
        }
    }
    struct mp_image *out_img = back ? mpi_from_cvpb(back, &cur->params, cur->pts) : NULL;
    if (back) CVPixelBufferRelease(back);
    CVPixelBufferRelease(out);
    if (out_img)
        push_pending(f, out_img);
}

/// 丢掉 ring[0]（已经处理完的那帧）
static void ring_pop_front(struct priv *p)
{
    if (p->ring_n <= 0)
        return;
    if (p->ring[0].buf)
        CVPixelBufferRelease(p->ring[0].buf);
    for (int i = 1; i < p->ring_n; i++)
        p->ring[i - 1] = p->ring[i];
    p->ring_n--;
    p->ring[p->ring_n].buf = NULL;
}

extern int ane_vf_passthrough;   // 定义在 vf_ane.m

static void handle_frame(struct mp_filter *f, struct mp_image *img)
{
    struct priv *p = f->priv;
    p->n_in++;

    if (ane_vf_passthrough) { push_pending(f, img); return; }   // 跳转中：不降噪

    if (p->opts->strength <= 0.0f || !ensure_session(f, img->w, img->h)) {
        push_pending(f, img);
        return;
    }

    CVPixelBufferRef buf = nf_buffer_from(f, img);
    if (!buf) {
        push_pending(f, img);
        return;
    }

    if (p->ring_n >= NF_RING) {
        // 理论到不了（每次处理都会 pop），兜底防止越界
        ring_pop_front(p);
    }
    struct nf_frame *slot = &p->ring[p->ring_n++];
    slot->buf = buf;
    slot->pts = img->pts;
    slot->params = img->params;
    talloc_free(img);

    // 攒够「当前 1 + 后 2」就开始出帧。一次出两帧：
    // 队首那帧后面已经有 2 帧可以参考（没有更早的，prev 传空），
    // 第二帧则有完整的「前一帧 + 后两帧」。
    // 两帧一起出才能保证不丢帧、不提前消耗参考帧。
    while (p->ring_n >= 4) {
        process_at(f, 0, false, 2);
        process_at(f, 1, true, 2);
        ring_pop_front(p);
        ring_pop_front(p);
    }
}

/// 片尾：后面没帧了，用手头剩下的逐帧处理（参考帧不足就少给）
static void drain_ring(struct mp_filter *f)
{
    struct priv *p = f->priv;
    // 片尾剩下的这几帧凑不齐参考帧，直接丢弃（最多 3 帧，看不出来）。
    // 早先这里会调 TNF 处理、或者把原帧拷回去，两者在片尾都会碰到
    // 已经交给上游回收的 buffer，实测会偶发段错误/卡死。
    ring_clear(p);
}

static void vf_anenf_process(struct mp_filter *f)
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
                drain_ring(f);
                p->eof_queued = true;
                continue;
            }
            if (frame.type != MP_FRAME_VIDEO) {
                mp_pin_in_write(f->ppins[1], frame);
                continue;
            }
            struct mp_image *img = frame.data;
            handle_frame(f, img);
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

static void vf_anenf_reset(struct mp_filter *f)
{
    struct priv *p = f->priv;
    drop_pending_all(p);
    ring_clear(p);
    p->eof_queued = false;
}

static void vf_anenf_destroy(struct mp_filter *f)
{
    struct priv *p = f->priv;
    drop_pending_all(p);
    ring_clear(p);
    end_session(p);
    MP_VERBOSE(f, "ANE-NF 统计：输入 %lld / 输出 %lld / 成功 %lld / 失败 %lld\n",
               (long long)p->n_in, (long long)p->n_out,
               (long long)p->n_ok, (long long)p->n_fail);
}

static const struct mp_filter_info vf_anenf_filter = {
    .name = "anenf",
    .process = vf_anenf_process,
    .reset = vf_anenf_reset,
    .destroy = vf_anenf_destroy,
    .priv_size = sizeof(struct priv),
};

static struct mp_filter *vf_anenf_create(struct mp_filter *parent, void *options)
{
    struct mp_filter *f = mp_filter_create(parent, &vf_anenf_filter);
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
    mp_autoconvert_add_imgfmt(priv->conv, IMGFMT_NV12, 0);

    return f;
}

#define OPT_BASE_STRUCT struct vf_anenf_opts
static const m_option_t vf_anenf_opts_fields[] = {
    {"strength", OPT_FLOAT(strength), M_RANGE(0, 1)},
    {0}
};

const struct mp_user_filter_entry vf_anenf = {
    .desc = {
        .description = "ANE 神经引擎时域降噪",
        .name = "anenf",
        .priv_size = sizeof(OPT_BASE_STRUCT),
        .priv_defaults = &(const OPT_BASE_STRUCT){ .strength = 0.5f },
        .options = vf_anenf_opts_fields,
    },
    .create = vf_anenf_create,
};
