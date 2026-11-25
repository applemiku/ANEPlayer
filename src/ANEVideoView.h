//
//  ANEVideoView.h — 用 libmpv 的 render API 把画面渲染到 NSOpenGLView
//
//  mpv 侧用 vo=libmpv：mpv 不自己开窗口，而是把画面交给我们指定的 FBO，
//  这样窗口、控制条、全屏全部由 AppKit 管理，符合 macOS 原生播放器的观感。
//

#import <Cocoa/Cocoa.h>
#include <mpv/client.h>
#include <mpv/render.h>

@interface ANEVideoView : NSOpenGLView

- (instancetype)initWithFrame:(NSRect)frame mpv:(mpv_handle *)mpv;

/// 退出前调用：解绑回调并释放 render context
- (void)shutdown;

/// 当前是否成功建立了渲染上下文
@property (nonatomic, readonly) BOOL renderReady;

@end
