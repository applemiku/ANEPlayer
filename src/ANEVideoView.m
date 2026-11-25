//
//  ANEVideoView.m
//

#import "ANEVideoView.h"
#include <mpv/render_gl.h>
#include <OpenGL/gl.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

/// OpenGL 函数地址解析：macOS 上所有 GL 符号都在 com.apple.opengl 这个 bundle 里。
static void *ane_gl_get_proc_address(void *ctx, const char *name)
{
    CFStringRef sym = CFStringCreateWithCString(kCFAllocatorDefault, name,
                                                kCFStringEncodingASCII);
    void *addr = NULL;
    if (sym) {
        addr = CFBundleGetFunctionPointerForName(
            CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl")), sym);
        CFRelease(sym);
    }
    return addr;
}

/// mpv 有新帧时回调（在 mpv 自己的线程上）。只做一件事：回主线程请求重绘。
static void ane_render_wakeup(void *ctx)
{
    ANEVideoView *v = (__bridge ANEVideoView *)ctx;
    if (!v) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [v setNeedsDisplay:YES];
    });
}

@implementation ANEVideoView {
    mpv_handle *_mpv;
    mpv_render_context *_rctx;
}

- (instancetype)initWithFrame:(NSRect)frame mpv:(mpv_handle *)mpv
{
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFADepthSize, 32,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        0
    };
    NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf) {
        // 部分机型拿不到 3.2 Core，退回 legacy profile
        NSOpenGLPixelFormatAttribute fallback[] = {
            NSOpenGLPFAAccelerated, NSOpenGLPFADoubleBuffer,
            NSOpenGLPFADepthSize, 32, 0
        };
        pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:fallback];
    }

    self = [super initWithFrame:frame pixelFormat:pf];
    if (self) {
        _mpv = mpv;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self setWantsBestResolutionOpenGLSurface:YES];
        _renderReady = [self setupRenderContext];
    }
    return self;
}

- (BOOL)setupRenderContext
{
    if (!_mpv) return NO;
    [[self openGLContext] makeCurrentContext];

    mpv_opengl_init_params gl_init = { .get_proc_address = ane_gl_get_proc_address };
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_API_TYPE,           (void *)MPV_RENDER_API_TYPE_OPENGL },
        { MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init },
        { 0, NULL }
    };

    if (mpv_render_context_create(&_rctx, _mpv, params) < 0) {
        NSLog(@"[ANEPlayer] mpv render context 创建失败");
        _rctx = NULL;
        return NO;
    }
    mpv_render_context_set_update_callback(_rctx, ane_render_wakeup,
                                           (__bridge void *)self);
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    if (!_rctx) {
        [[NSColor blackColor] setFill];
        NSRectFill(dirtyRect);
        return;
    }

    [[self openGLContext] makeCurrentContext];

    NSRect b = [self bounds];
    CGFloat scale = self.window.backingScaleFactor ?: 1.0;
    int w = (int)(b.size.width * scale);
    int h = (int)(b.size.height * scale);
    if (w <= 0 || h <= 0) return;

    mpv_opengl_fbo fbo = { .fbo = 0, .w = w, .h = h, .internal_format = 0 };
    int flip = 1;   // OpenGL 原点在左下，mpv 在左上
    mpv_render_param params[] = {
        { MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
        { MPV_RENDER_PARAM_FLIP_Y,     &flip },
        { 0, NULL }
    };
    mpv_render_context_render(_rctx, params);

    [[self openGLContext] flushBuffer];
}

- (void)shutdown
{
    if (_rctx) {
        mpv_render_context_set_update_callback(_rctx, NULL, NULL);
        mpv_render_context_free(_rctx);
        _rctx = NULL;
    }
    _renderReady = NO;
}

- (BOOL)acceptsFirstResponder { return YES; }

@end
