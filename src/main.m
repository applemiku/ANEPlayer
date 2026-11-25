//
//  ANEPlayer — 基于 libmpv 的独立播放器（macOS 原生界面）
//
//  播放能力全部来自 mpv（解封装 / 解码 / 字幕 / 音轨 / 缓存 / 格式支持），
//  补帧由内置在 libmpv 里的 vf_ane 滤镜完成（进程内，零拷贝零编码）。
//  窗口与控制条是 AppKit 原生控件，所以外观和操作习惯跟 QuickTime / IINA 一致。
//

#import <Cocoa/Cocoa.h>
#import "ANEVideoView.h"
#import "ANEDanmaku.h"
#include <dispatch/dispatch.h>
#include <math.h>
#include <string.h>

// ── mpv 侧：属性读写小工具 ──────────────────────────────────────────────────

static double mpv_num(mpv_handle *h, const char *name)
{
    double v = 0;
    mpv_get_property(h, name, MPV_FORMAT_DOUBLE, &v);
    return v;
}
static BOOL mpv_bool(mpv_handle *h, const char *name)
{
    int v = 0;
    mpv_get_property(h, name, MPV_FORMAT_FLAG, &v);
    return v != 0;
}
static NSString *mpv_str(mpv_handle *h, const char *name)
{
    char *s = mpv_get_property_string(h, name);
    if (!s) return nil;
    NSString *r = @(s);
    mpv_free(s);
    return r;
}
static void mpv_cmd(mpv_handle *h, const char *args[])
{
    if (h) mpv_command(h, args);
}

// 注意：不能叫 mpv_wakeup —— mpv 的 client.h 已经导出了同名的 API 函数。
static void ane_wakeup(void *ctx);

// 控制条高度（贴底全宽），布局和计算共用同一个值
// libmpv 里的全局直通开关（vf_ane.m 里定义）
extern void ane_set_vf_passthrough(int on);

static const double kSeekSettleDelay = 0.40;   // 松开进度条后等这么久再跳（连续拖动会不断重置）
static const CGFloat kBarHeight = 46.0;   // 收紧凑一点（IINA 差不多这个高度）
// 信息面板距窗口顶部的留白（透明标题栏下有交通灯）
static const CGFloat kStatsTopInset = 55.0;

// ── 时间格式化 ──────────────────────────────────────────────────────────────

static NSString *fmt_time(double s)
{
    if (!isfinite(s) || s < 0) s = 0;
    int total = (int)s;
    int h = total / 3600, m = (total % 3600) / 60, sec = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%d:%02d:%02d", h, m, sec];
    return [NSString stringWithFormat:@"%02d:%02d", m, sec];
}

// ── AppDelegate ─────────────────────────────────────────────────────────────

/// 从上往下排的容器。AppKit 默认 y 轴向上，手写列表布局很别扭，
/// 面板里的行都塞进这个翻转视图，y 直接当「距顶部的距离」用。
@interface ANEFlippedView : NSView
@end
@implementation ANEFlippedView
- (BOOL)isFlipped { return YES; }
@end

/// NSButton 没有 representedObject（那是 NSMenuItem 的），挂个 payload 自己存
@interface ANETrackButton : NSButton
@property (nonatomic, strong) NSDictionary *payload;
@end
@implementation ANETrackButton
@end

/// 卡片行（搜索结果用）：圆角半透明底 + 主副两行字，
/// 层叠卡片比裸文字行有「列表项」的分组感，浅色玻璃上也更容易扫读。
/// 全部自绘、不建子视图 —— NSTextField 子视图会吃掉 mouseDown，点击就废了。
@interface ANECardRow : ANETrackButton
@property (nonatomic, copy) NSString *mainText;
@property (nonatomic, copy) NSString *subText;
@end

@implementation ANECardRow
{
    BOOL _down;
}

- (BOOL)isFlipped { return YES; }

- (void)setDown:(BOOL)v
{
    _down = v;
    [self setNeedsDisplay:YES];
}

- (void)mouseDown:(NSEvent *)event
{
    [self setDown:YES];
    [super mouseDown:event];
    [self setDown:NO];
}

- (void)drawRect:(NSRect)dirtyRect
{
    NSRect r = self.bounds;
    if (NSWidth(r) < 8 || NSHeight(r) < 8) return;

    // 底：比面板略深一层的灰（0.075 ≈ 分段控件的底槽，视觉统一），按下时加深
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:7 yRadius:7];
    [[NSColor.labelColor colorWithAlphaComponent:(_down ? 0.16 : 0.075)] setFill];
    [bg fill];
    // 极淡描边：浅色玻璃上没它边界会糊
    [[NSColor.labelColor colorWithAlphaComponent:0.07] setStroke];
    bg.lineWidth = 1.0;
    [bg stroke];

    CGFloat pad = 11.0;
    CGFloat tw = NSWidth(r) - pad * 2;
    if (tw <= 4) return;

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;

    NSAttributedString *t = [[NSAttributedString alloc] initWithString:(_mainText ?: @"")
        attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                      NSForegroundColorAttributeName:
                          [NSColor.labelColor colorWithAlphaComponent:0.88],
                      NSParagraphStyleAttributeName: ps }];
    [t drawInRect:NSMakeRect(pad, 6, tw, 17)];

    NSAttributedString *s = [[NSAttributedString alloc] initWithString:(_subText ?: @"")
        attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:9.5],
                      NSForegroundColorAttributeName:
                          [NSColor.labelColor colorWithAlphaComponent:0.48],
                      NSParagraphStyleAttributeName: ps }];
    [s drawInRect:NSMakeRect(pad, 24, tw, 14)];
}

@end

/// 控制条上的下拉选择框（替代系统 NSMenu）。
/// 系统菜单贴着窗口底边弹会显得又窄又小，这里改成一块毛玻璃圆角卡片：
/// 贴在按钮上方、每行居中、当前项左侧打勾、鼠标划过整行浅色高亮。
///
/// 拆成两层是因为 NSVisualEffectView 重写 drawRect 画不出东西（磨砂层会盖住绘制内容），
/// 文字必须落在它上面的子视图里；而子视图又要把数据自己带一份（用 weak 反指父视图时，
/// 实测 drawRect 里拿不到父对象，字就全丢了）。
/// 卡片底：macOS 26 起用和设置面板同一套液态玻璃（NSGlassEffectView，圆角 16），
/// 旧系统退回浅色毛玻璃，观感尽量贴近
@interface ANEMenuBg : NSView
@end
@implementation ANEMenuBg
- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        if (@available(macOS 26.0, *)) {
            NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:self.bounds];
            g.style = NSGlassEffectViewStyleRegular;
            g.cornerRadius = 16;
            g.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            g.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            // 必须给 contentView：只保证 contentView 落在玻璃层里，
            // 不设的话玻璃会按自己的默认尺寸画，比 bounds 小一圈
            NSView *inner = [[NSView alloc] initWithFrame:g.bounds];
            inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            g.contentView = inner;
            [self addSubview:g];
        } else {
            NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
            v.material = NSVisualEffectMaterialPopover;
            v.blendingMode = NSVisualEffectBlendingModeWithinWindow;
            v.state = NSVisualEffectStateActive;
            v.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            v.wantsLayer = YES;
            v.layer.cornerRadius = 16;
            v.layer.masksToBounds = YES;
            v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [self addSubview:v];
        }
    }
    return self;
}
- (NSView *)hitTest:(NSPoint)p { return nil; }   // 别抢父视图的点击
@end

/// 只负责画字，不吃鼠标事件
@interface ANEMenuLabels : NSView
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic) NSInteger hover;
@end

@implementation ANEMenuLabels
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)p { return nil; }

- (void)setTitles:(NSArray<NSString *> *)v
{
    _titles = [v copy];
    [self setNeedsDisplay:YES];
}

- (void)setSelectedIndex:(NSInteger)v
{
    _selectedIndex = v;
    [self setNeedsDisplay:YES];
}

- (void)setHover:(NSInteger)v
{
    if (_hover == v) return;
    _hover = v;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
    CGFloat w = NSWidth(self.bounds);
    NSInteger n = (NSInteger)self.titles.count;
    if (n <= 0 || w <= 0) return;

    CGFloat rowH = (NSHeight(self.bounds) - 20.0) / (CGFloat)n;

    for (NSInteger i = 0; i < n; i++) {
        // 行样式对齐设置面板的列表行：x=8、宽 w-16、高 24、圆角 6
        NSRect row = NSMakeRect(18, 10 + i * rowH, w - 40, rowH - 2);
        BOOL on = (i == self.selectedIndex);

        if (on) {
            NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:row
                                                                xRadius:6 yRadius:6];
            [[[NSColor blackColor] colorWithAlphaComponent:0.14] setFill];
            [pill fill];
        }

        // 文字一律左对齐（缩进 10，与设置面板列表行一致），不再跟着对勾左右飘
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = NSTextAlignmentLeft;
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSAttributedString *t = [[NSAttributedString alloc]
            initWithString:self.titles[i]
                attributes:@{
                    NSFontAttributeName: [NSFont systemFontOfSize:12
                                                           weight:(on ? NSFontWeightSemibold
                                                                      : NSFontWeightRegular)],
                    NSForegroundColorAttributeName:
                        on ? [NSColor labelColor]
                           : [[NSColor labelColor] colorWithAlphaComponent:0.72],
                    NSParagraphStyleAttributeName: ps,
                }];
        NSSize sz = t.size;
        [t drawInRect:NSMakeRect(row.origin.x + 13, NSMidY(row) - sz.height / 2.0,
                                 row.size.width - 26, sz.height)];
    }
}
@end

@interface ANEChoiceMenu : NSView
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
@end

@implementation ANEChoiceMenu
{
    ANEMenuBg *_bg;
    ANEMenuLabels *_labels;
    NSInteger _hover;
}

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 16;
        self.layer.masksToBounds = YES;
        _hover = -1;

        _bg = [[ANEMenuBg alloc] initWithFrame:self.bounds];
        _bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self addSubview:_bg];

        _labels = [[ANEMenuLabels alloc] initWithFrame:self.bounds];
        _labels.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        // 锁浅色外观：labelColor 是动态色，压在深色视频上容易被判成深色外观、字变白
        _labels.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        [self addSubview:_labels];
    }
    return self;
}

- (void)layout
{
    [super layout];
    _bg.frame = self.bounds;
    _labels.frame = self.bounds;
}

- (void)setTitles:(NSArray<NSString *> *)v
{
    _titles = [v copy];
    _labels.titles = _titles;
}

- (void)setSelectedIndex:(NSInteger)v
{
    _selectedIndex = v;
    _labels.selectedIndex = v;
}

- (CGFloat)rowHeight
{
    return (NSHeight(self.bounds) - 20.0) / MAX((CGFloat)self.titles.count, 1.0);
}

- (NSInteger)indexAtPoint:(NSPoint)p
{
    CGFloat rowH = [self rowHeight];
    NSInteger idx = (NSInteger)floor((p.y - 10.0) / MAX(rowH, 1.0));
    if (idx < 0 || idx >= (NSInteger)self.titles.count) return -1;
    return idx;
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea *t in [self.trackingAreas copy]) [self removeTrackingArea:t];
    NSTrackingArea *ta = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                      NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
               owner:self
            userInfo:nil];
    [self addTrackingArea:ta];
}

- (void)mouseMoved:(NSEvent *)e
{
    NSInteger idx = [self indexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    if (idx != _hover) {
        _hover = idx;
        _labels.hover = idx;
    }
}

- (void)mouseExited:(NSEvent *)e
{
    _hover = -1;
    _labels.hover = -1;
}

- (void)mouseDown:(NSEvent *)e
{
    NSInteger idx = [self indexAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
    if (idx < 0) return;
    self.selectedIndex = idx;
    if (self.target && self.action) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
    }
}

@end

/// 自绘分段控件（替代 NSSegmentedControl）：
/// 1) 选中块用灰色，不用系统蓝；
/// 2) **每次点击都会回调**（含点已选中项）—— 这样「点弹幕开关 = 重新加载」才成立，
///    NSSegmentedControl 点已选中项是不发 action 的。
@interface ANESegmentedView : NSView
@property (nonatomic, copy) NSArray<NSString *> *items;
@property (nonatomic) NSInteger selectedSegment;
@property (nonatomic) CGFloat fontSize;      // 默认 10；顶部页签用 11
@property (nonatomic, weak) id target;
@property (nonatomic) SEL action;
- (void)setupItems:(NSArray<NSString *> *)items selected:(NSInteger)idx;
@end

@implementation ANESegmentedView

- (BOOL)isFlipped { return YES; }

- (void)setupItems:(NSArray<NSString *> *)items selected:(NSInteger)idx
{
    self.items = items;
    self.selectedSegment = idx;
    [self setNeedsDisplay:YES];
}

- (void)setSelectedSegment:(NSInteger)v
{
    _selectedSegment = v;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect
{
    CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    NSInteger n = (NSInteger)self.items.count;
    if (n <= 0 || w <= 0) return;

    // 底槽
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds
                                                      xRadius:6 yRadius:6];
    [[NSColor.labelColor colorWithAlphaComponent:0.07] setFill];
    [bg fill];

    // 选中块（灰，不用系统蓝）
    CGFloat segW = w / n;
    if (_selectedSegment >= 0 && _selectedSegment < n) {
        NSRect pill = NSMakeRect(_selectedSegment * segW + 2, 2, segW - 4, h - 4);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:pill xRadius:5 yRadius:5];
        [[NSColor.labelColor colorWithAlphaComponent:0.20] setFill];
        [p fill];
    }

    // 文字直接画，不建子视图 —— 子视图会挡住 mouseDown，导致点击失效
    for (NSInteger i = 0; i < n; i++) {
        BOOL on = (i == _selectedSegment);
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.alignment = NSTextAlignmentCenter;
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:(self.fontSize > 0 ? self.fontSize : 10)],
            NSForegroundColorAttributeName: on ? NSColor.labelColor
                                               : [NSColor.labelColor colorWithAlphaComponent:0.62],
            NSParagraphStyleAttributeName: ps,
        };
        NSString *t = self.items[i];
        NSSize sz = [t sizeWithAttributes:attrs];
        NSRect r = NSMakeRect(i * segW, (h - sz.height) / 2.0, segW, sz.height);
        [t drawInRect:r withAttributes:attrs];
    }
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat w = NSWidth(self.bounds);
    NSInteger n = (NSInteger)self.items.count;
    if (n <= 0 || w <= 0) return;

    NSInteger idx = (NSInteger)(pt.x / (w / n));
    if (idx < 0) idx = 0;
    if (idx >= n) idx = n - 1;

    self.selectedSegment = idx;      // 点已选中项也重设（视觉无变化，但会回调）
    if (self.target && self.action && [self.target respondsToSelector:self.action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
    }
}
@end


/// 进度条上的章节刻度：一条条竖线标出每章起点。
/// 盖在滑块上面一层，但 hitTest 返回 nil —— 鼠标事件照旧落到下面的滑块，
/// 「点进度条跳转」完全不受影响。
@interface ANEChapterTrack : NSView
@property (nonatomic, copy) NSArray<NSNumber *> *fractions;   // 0…1，升序
@end

@implementation ANEChapterTrack
- (NSView *)hitTest:(NSPoint)point { return nil; }   // nil = 不吃鼠标事件

- (void)drawRect:(NSRect)dirtyRect
{
    if (self.fractions.count == 0) return;
    CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    // 滑块轨道两端各让出半个葫芦（15pt 葫芦 ≈ 7.5），刻度才和真实进度对得上
    CGFloat inset = 7.5;
    CGFloat trackW = w - inset * 2.0;
    if (trackW < 8) return;

    CGFloat cy = round(h / 2.0);
    CGFloat th = 7.0;
    NSColor *dark  = [NSColor.labelColor colorWithAlphaComponent:0.62];
    NSColor *light = [NSColor.whiteColor colorWithAlphaComponent:0.95];

    for (NSNumber *n in self.fractions) {
        double f = n.doubleValue;
        if (f <= 0.002 || f >= 0.998) continue;   // 首尾两条不画，那就是进度条两端
        CGFloat x = round(inset + f * trackW);
        // 一深一浅两条 1px：深色在浅色未播放段可见，浅色在深色已播放段可见
        [dark setFill];
        NSRectFill(NSMakeRect(x - 0.5, cy - th / 2.0, 1.0, th));
        [light setFill];
        NSRectFill(NSMakeRect(x + 0.5, cy - th / 2.0, 1.0, th));
    }
}
@end


@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate>

@property (nonatomic) mpv_handle *mpv;
@property (nonatomic) NSWindow *window;
@property (nonatomic) ANEVideoView *videoView;

@property (nonatomic) NSView *controls;
@property (nonatomic) NSView *controlsInner;
@property (nonatomic) NSButton *playBtn;
@property (nonatomic) NSSlider *progress;
// 进度条章节刻度
@property (nonatomic) ANEChapterTrack *chapterTrack;
@property (nonatomic) BOOL showChapterMarks;
@property (nonatomic) NSString *chapterSig;     // 章节/时长变了才重算，避免每 tick 重绘
@property (nonatomic) NSTextField *timeLabel;
@property (nonatomic) NSButton *muteBtn;
@property (nonatomic) NSSlider *volume;
@property (nonatomic) NSButton *aneBtn;
@property (nonatomic) ANEChoiceMenu *factorMenu;   // 补帧倍率下拉（自绘，不是系统 NSMenu）
@property (nonatomic) NSButton *fsBtn;
@property (nonatomic) NSButton *listBtn;
@property (nonatomic) NSButton *settingsBtn;
@property (nonatomic) NSButton *shotBtn;          // 截图
- (void)takeScreenshot;
@property (nonatomic) NSView *toastBox;         // 轻提示的玻璃卡片
@property (nonatomic) NSImageView *toastIcon;       // 卡片里的对勾图标
@property (nonatomic) NSTextField *toastLabel;    // 轻提示（截图已保存…）
@property (nonatomic) NSTimer *toastTimer;

// 播放信息面板（Tab 唤起）
@property (nonatomic) NSView *statsView;
@property (nonatomic) NSTextView *statsText;
@property (nonatomic) BOOL statsVisible;
// 轨道菜单：文件加载后按需重建一次
@property (nonatomic) BOOL tracksBuilt;
@property (nonatomic) NSMenu *subMenu;
@property (nonatomic) NSMenu *audioMenu;
// 轨道列表分别放在这两个子菜单里，避免每次重建把静态项也清掉
@property (nonatomic) NSMenu *subTrackMenu;
@property (nonatomic) NSMenu *audioTrackMenu;
@property (nonatomic) NSMenu *windowMenu;
// 命令行 --sub 传进来的外挂字幕，等文件加载完再挂上去
@property (nonatomic) NSMutableArray<NSString *> *pendingSubs;
// LS 在 mpv 就绪前就传进来的文件
@property (nonatomic) NSString *pendingFile;
@property (nonatomic) BOOL alwaysOnTop;

@property (nonatomic) NSTimer *uiTimer;
// 长按空格临时加速（1.5x），松开恢复
@property (nonatomic) BOOL spaceDown;
@property (nonatomic) BOOL spaceBoosted;
@property (nonatomic) double savedSpeed;
@property (nonatomic) NSTimer *spaceTimer;
@property (nonatomic) double holdBoost;     // 长按空格的倍率：1.5 或 2
@property (nonatomic) NSSize lastDanmakuVideoSize;   // 弹幕层上次按哪个视频尺寸排的
@property (nonatomic) NSInteger dmSubTab;                // 弹幕页内的二级页：0 基础 / 1 高级 / 2 过滤
@property (nonatomic) NSInteger aneNoise;      // 0 关 / 1 轻 / 2 强（ANE 时域降噪）
@property (nonatomic) NSInteger anime4kMode;   // 0 关 / 1 轻量 / 2 增强 / 3 2x 超分
// 弹幕（渲染层复用 iina-plugin-danmaku-cosmos 的 overlay）
@property (nonatomic) ANEDanmaku *danmaku;
@property (nonatomic) NSMutableDictionary *dmPrefs;
@property (nonatomic) NSTextField *dmStatusLabel;
@property (nonatomic) NSString *dmStatusText;     // 最近一次匹配结果（面板重建后还要能显示）
// 手动搜索状态
@property (nonatomic) NSTextField *dmSearchField;
@property (nonatomic) NSArray<NSDictionary *> *dmSearchResults;
@property (nonatomic) NSArray<NSDictionary *> *dmAnimeResults;   // 返回上一层时用
@property (nonatomic) NSInteger dmSearchMode;      // 0 无 / 1 番剧列表 / 2 剧集列表
@property (nonatomic) NSString *dmSearchKeyword;
@property (nonatomic) NSString *dmSearchAnimeTitle;
@property (nonatomic) BOOL dmSearchBusy;
@property (nonatomic) NSScrollView *settingsScroll;
@property (nonatomic) BOOL aneSR;              // ANE 超分（VTLowLatencySuperResolutionScaler）
@property (nonatomic) NSTimer *hideTimer;
@property (nonatomic) BOOL seeking;
@property (nonatomic) int factor;      // 1=关 2=2x 4=4x
// seek 相关：补帧/超分/降噪在跳转期间临时断开，跳完立刻接回
@property (nonatomic) BOOL filtersSuspended;
@property (nonatomic) NSTimer *seekTimer;        // 松手后的防抖
@property (nonatomic) NSTimer *seekPollTimer;    // 轮询 seeking，等跳转结束
@property (nonatomic) double seekTarget;
@property (nonatomic) BOOL seekInFlight;
@property (nonatomic) BOOL seekQueued;
@property (nonatomic) BOOL seekSawSeeking;
@property (nonatomic) NSInteger seekPolls;
@property (nonatomic) CFAbsoluteTime lastSeekTouch;
@property (nonatomic) NSString *currentFile;
@property (nonatomic) NSString *currentVideoBase;   // 无扩展名，用来裁掉字幕名里的长前缀
// 窗口按视频比例自适应：换片时重置，第一个有效尺寸出来后只做一次
@property (nonatomic) BOOL didFitWindow;
@property (nonatomic) BOOL lockAspect;
@property (nonatomic) NSSize fittedAspect;

// 字幕面板（仿 IINA 右侧面板）
@property (nonatomic) NSView *subPanel;
@property (nonatomic) NSView *subPanelContent;   // 翻转容器，从上往下排
@property (nonatomic) NSButton *subBtn;          // 控制条上的字幕开关
@property (nonatomic) NSSlider *subDelaySlider;
@property (nonatomic) NSTextField *subDelayLabel;
@property (nonatomic) NSTextField *subPosLabel;
@property (nonatomic) NSView *settingsBody;
@property (nonatomic) NSInteger settingsTab;
@property (nonatomic) NSTextField *audioDelayLabel;
@property (nonatomic) NSTextField *speedLabel;
// 播放列表面板
@property (nonatomic) NSView *playlistPanel;
@property (nonatomic) NSView *playlistContent;
@property (nonatomic) NSString *playlistSig;     // 列表内容签名，变了才重建
// 设置面板（先占位）
@property (nonatomic) NSView *settingsPanel;
@property (nonatomic) NSView *settingsContent;
@property (nonatomic) BOOL liveResizing;
// 卡顿诊断：ANEPLAYER_LAGLOG=/tmp/lag.txt 记录拖动窗口时主线程最长停顿
@property (nonatomic) NSMutableArray<NSNumber *> *lagSamples;
@property (nonatomic) NSTimer *lagTimer;
@end

@implementation AppDelegate

// ── mpv 初始化 ──────────────────────────────────────────────────────────────

- (void)setupMpv
{
    _mpv = mpv_create();
    if (!_mpv) { NSLog(@"[ANEPlayer] mpv_create 失败"); return; }

    // vo=libmpv：mpv 不开窗口，把画面交给我们的 OpenGL 视图
    mpv_set_option_string(_mpv, "vo", "libmpv");
    mpv_set_option_string(_mpv, "keep-open", "always");
    mpv_set_option_string(_mpv, "osc", "no");
    mpv_set_option_string(_mpv, "osd-level", "1");
    // OSD 挪到画面底部中间偏上：默认在左上角，会和 Tab 面板打架
    mpv_set_option_string(_mpv, "osd-align-y", "bottom");
    mpv_set_option_string(_mpv, "osd-margin-y", "76");
    mpv_set_option_string(_mpv, "hwdec", "auto");
    mpv_set_option_string(_mpv, "config", "yes");
    // 千万别用 all/fuzzy：那会把同目录里别的集数字幕全加进来（一屏十几条）。
    // 外挂字幕改由 autoLoadExternalSubs 按「和视频同名」精确匹配后手动挂载。
    mpv_set_option_string(_mpv, "sub-auto", "no");
    // 字幕语言优先中文；有菜单可随时切换轨道
    mpv_set_option_string(_mpv, "slang", "chi,chs,sc,zho,zh,jpn,jp,eng,en");
    mpv_set_option_string(_mpv, "sub-visibility", "yes");
    mpv_set_option_string(_mpv, "volume-max", "100");   // 音量最高 100%，不要 mpv 默认的 130
    mpv_set_option_string(_mpv, "sub-pos", "100");      // 字幕贴底（mpv 默认值，显式写死避免被 mpv.conf 改）
    // 底部留白收到 8px：3:2 的屏放 16:9 的片时字幕要能整个落进下方黑边；
    // 留白太大字会被顶回画面里，设成 0 又会让多行字幕被窗口底裁掉
    mpv_set_option_string(_mpv, "sub-margin-y", "8");
    // ASS 字幕（番剧外挂最常见）的位置写死在样式里，不吃 sub-pos；
    // 强制它使用外面的 margin，位置滑块才对 ASS 也生效（样式本身不变）
    mpv_set_option_string(_mpv, "sub-ass-force-margins", "yes");
    // ASS 字幕（番剧外挂最常见）的位置写死在样式里，不吃 sub-pos；
    // 强制它使用外面的 margin，位置滑块才对 ASS 也生效（样式本身不变）
    mpv_set_option_string(_mpv, "sub-ass-force-margins", "yes");
    mpv_set_option_string(_mpv, "audio-file-auto", "exact");
    mpv_set_option_string(_mpv, "screenshot-directory", "~/Desktop");
    // 补帧靠 vf_ane，音画同步完全交给 mpv 的播放时钟
    mpv_set_option_string(_mpv, "video-sync", "audio");

    mpv_request_log_messages(_mpv, "info");
    mpv_set_wakeup_callback(_mpv, ane_wakeup, (__bridge void *)self);

    // 排查用：ANEPLAYER_LOGFILE=/tmp/ane.log 打开应用，mpv 日志会落到该文件
    const char *logfile = getenv("ANEPLAYER_LOGFILE");
    if (logfile && logfile[0]) {
        mpv_set_option_string(_mpv, "log-file", logfile);
        mpv_set_option_string(_mpv, "msg-level", "all=info");
    }

    if (mpv_initialize(_mpv) < 0) {
        NSLog(@"[ANEPlayer] mpv_initialize 失败");
        _mpv = NULL;
    }
}

static void ane_wakeup(void *ctx)
{
    AppDelegate *d = (__bridge AppDelegate *)ctx;
    if (!d) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [d drainEvents]; });
}

- (void)drainEvents
{
    if (!_mpv) return;
    while (1) {
        mpv_event *ev = mpv_wait_event(_mpv, 0);
        if (!ev || ev->event_id == MPV_EVENT_NONE) break;
        if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
        if (ev->event_id == MPV_EVENT_END_FILE) {
            [self updatePlayButton];
        }
    }
}

// ── 补帧档位 ────────────────────────────────────────────────────────────────

/// 与滤镜实测行为配套：重复 add 会叠加，remove 只删一条且对不存在的滤镜是 no-op，
/// 所以切档一律「先清掉所有档位，再挂目标档位」。
- (void)setFactor:(int)f
{
    if (!_mpv) return;
    if (f != 1 && f != 2 && f != 4) f = 1;

    _factor = f;
    [self applyVideoChain];
    [self updateAneButton];
}

/// 点补帧胶囊弹出档位选择（自绘毛玻璃卡片，贴在胶囊上方）
- (void)showFactorMenu
{
    if (_factorMenu) {          // 再点一次 = 收起
        [self hideFactorMenu];
        return;
    }

    NSArray<NSString *> *titles = @[@"关闭", @"2x", @"4x"];
    CGFloat w = 148.0, rowH = 26.0, pad = 10.0;
    CGFloat h = rowH * titles.count + pad * 2.0;

    NSView *host = _window.contentView;
    NSRect anchor = [_aneBtn convertRect:_aneBtn.bounds toView:host];

    CGFloat x = NSMidX(anchor) - w / 2.0;
    x = MAX(8.0, MIN(x, NSWidth(host.bounds) - w - 8.0));
    // 用「控制条上沿」而不是按钮上沿当基准：按钮比控制条矮一圈，
    // 按按钮算的话卡片会正好卡进控制条里，看着像粘住了
    CGFloat barTop = _controls ? NSMaxY(_controls.frame) : NSMaxY(anchor);
    CGFloat y = MAX(NSMaxY(anchor), barTop) + 10.0;
    if (y + h > NSHeight(host.bounds) - 10.0) y = NSMinY(anchor) - h - 10.0;

    ANEChoiceMenu *menu = [[ANEChoiceMenu alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    menu.titles = titles;
    menu.selectedIndex = (_factor == 1) ? 0 : (_factor == 2 ? 1 : 2);
    menu.target = self;
    menu.action = @selector(pickFactorMenu:);
    [host addSubview:menu positioned:NSWindowAbove relativeTo:nil];
    _factorMenu = menu;
    _window.acceptsMouseMovedEvents = YES;   // hover 高亮要靠 mouseMoved
    [menu setNeedsDisplay:YES];
    [self showControls];                     // 弹着菜单时别让控制条自己淡出
}

- (void)hideFactorMenu
{
    if (!_factorMenu) return;
    [_factorMenu removeFromSuperview];
    _factorMenu = nil;
}

- (void)pickFactorMenu:(ANEChoiceMenu *)menu
{
    static const int vals[3] = {1, 2, 4};
    NSInteger i = menu.selectedIndex;
    [self hideFactorMenu];
    if (i >= 0 && i < 3) [self setFactor:vals[i]];
}

/// 把「补帧 + 超分」组合成一条滤镜链整条设进去。
/// 顺序：先补帧（源分辨率上插帧，便宜）→ 再超分（每帧放大）。
- (void)applyVideoChain
{
    if (!_mpv) return;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    // 降噪放最前：先吃原始帧，补帧之后帧数翻倍再降噪会白白多花一倍算力
    // 每个滤镜都打 label：拖动进度条时可以 vf toggle @xxx 临时让它直通，
    // 而不必重建整条链（重建 = VTFrameProcessor session 重建，要 300ms）
    if (_aneNoise >= 1) {
        double st = (_aneNoise == 1) ? 0.35 : 0.70;
        [parts addObject:[NSString stringWithFormat:@"@nf:anenf=strength=%.2f", st]];
    }
    if (_factor >= 2)
        [parts addObject:[NSString stringWithFormat:@"@ane:ane=factor=%dx", _factor]];
    if (_aneSR)
        [parts addObject:@"@sr:anesr=2x"];

    _filtersSuspended = NO;      // 整条链重建，之前 toggle 掉的状态已经不存在

    NSString *chain = [parts componentsJoinedByString:@","];
    if (chain.length) {
        mpv_set_property_string(_mpv, "vf", chain.UTF8String);
    } else {
        mpv_cmd(_mpv, (const char *[]){"vf", "clr", "", NULL});
    }

    NSString *got = mpv_str(_mpv, "vf") ?: @"";
    NSLog(@"[ANEPlayer] 滤镜链 → [%@]，实际 vf=[%@]", chain, got);
    BOOL lost = (_factor >= 2 && ![got containsString:@"ane="]) ||
                (_aneSR && ![got containsString:@"anesr"]) ||
                (_aneNoise >= 1 && ![got containsString:@"anenf"]);
    if (lost) NSLog(@"[ANEPlayer] 警告：滤镜链没挂全，实际 %@", got);
}

- (void)cycleFactor
{
    [self setFactor:(_factor == 1) ? 2 : (_factor == 2 ? 4 : 1)];
}

- (void)updateAneButton
{
    // 只显示档位，不要中文：「补帧 2x」→「2x」，关掉时就是「1x」
    NSString *t = (_factor == 1) ? @"1x" : [NSString stringWithFormat:@"%dx", _factor];
    _aneBtn.attributedTitle = [[NSAttributedString alloc]
        initWithString:t
            attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:11
                                                             weight:NSFontWeightMedium],
                          NSForegroundColorAttributeName:
                              (_factor == 1) ? NSColor.secondaryLabelColor
                                             : NSColor.labelColor }];
    _aneBtn.layer.backgroundColor = (_factor == 1)
        ? NSColor.clearColor.CGColor
        : [NSColor.blackColor colorWithAlphaComponent:0.10].CGColor;
    _aneBtn.toolTip = (_factor == 1) ? @"补帧已关闭（点击切换）"
                                     : [NSString stringWithFormat:@"补帧 %dx（点击切换）", _factor];
}

// ── 播放控制 ────────────────────────────────────────────────────────────────

- (void)setWindowOnTop:(BOOL)on
{
    _alwaysOnTop = on;
    _window.level = on ? NSFloatingWindowLevel : NSNormalWindowLevel;
}

- (void)toggleAlwaysOnTop
{
    [self setWindowOnTop:!_alwaysOnTop];
    // 同步菜单勾选状态
    for (NSMenuItem *i in _windowMenu.itemArray) {
        if (i.tag == 1001) i.state = _alwaysOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)togglePlay
{
    mpv_cmd(_mpv, (const char *[]){"cycle", "pause", NULL});
    [self updatePlayButton];
}

- (void)setSymbol:(NSString *)sym onButton:(NSButton *)b
{
    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:nil];
        img.template = YES;
        b.image = img;
    } else {
        b.title = sym;
    }
}

- (void)updatePlayButton
{
    BOOL paused = mpv_bool(_mpv, "pause");
    [self setSymbol:(paused ? @"play.fill" : @"pause.fill") onButton:_playBtn];
}

- (void)seekTo:(double)t
{
    char buf[64];
    snprintf(buf, sizeof(buf), "%f", t);
    mpv_cmd(_mpv, (const char *[]){"seek", buf, "absolute+exact", NULL});
}

// ── 拖动进度条：防抖 + 跳转期间让补帧/超分/降噪临时直通 ──────────────────
// 为什么会卡：精确 seek 要从上一个关键帧解码到目标，这中间每一帧都会流经
// vf 链。补帧是拿 ANE 一帧一帧算的（1080p 约 10-20ms/帧），隔 60 帧就是
// 一秒多；实测有补帧时 seek 200~1260ms，把滤镜断掉只要 50~130ms。
// 断开的办法是 `vf toggle @label`：只翻转 enabled 标志，VTFrameProcessor 的
// session 还在，跳完再 toggle 回来是零成本的（重建 session 要 300ms）。

- (void)suspendEnhanceFilters
{
    if (_filtersSuspended) return;
    _filtersSuspended = YES;
    // 直接让滤镜内部直通：不改 vf 链（改链会触发 video-reconfig，反而更慢），
    // 也不会丢掉已经建好的 ANE session
    ane_set_vf_passthrough(1);
}

- (void)resumeEnhanceFilters
{
    if (!_filtersSuspended) return;
    _filtersSuspended = NO;
    ane_set_vf_passthrough(0);
}

/// 进度条松手后调用：先等 settle，连续拖只会跳最后一次
- (void)commitSeekTo:(double)t
{
    if (!_mpv) return;
    double dur = mpv_num(_mpv, "duration");
    if (dur > 0.2) t = MIN(MAX(t, 0.0), MAX(0.0, dur - 0.15));
    _seekTarget = t;
    _lastSeekTouch = CFAbsoluteTimeGetCurrent();
    _seeking = YES;                 // 锁住进度条，tick 别把滑块拽回播放位置
    [self armSeekTimer:kSeekSettleDelay];
}

/// 排一次「等会儿再跳」。拖动中会被反复重置，所以只在手停下之后才真正执行
- (void)armSeekTimer:(NSTimeInterval)delay
{
    [_seekTimer invalidate];
    __weak typeof(self) wself = self;
    _seekTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                 repeats:NO
                                                   block:^(NSTimer *tm) {
        AppDelegate *s = wself;
        if (s) [s runPendingSeek];
    }];
}

- (void)runPendingSeek
{
    if (!_mpv) return;
    // 鼠标还按着 = 用户还在拖（NSSlider 松手后还会补发一次 value change），
    // 这时候跳会把画面拽走，等松开再说
    if (NSEvent.pressedMouseButtons & 1) {
        [self armSeekTimer:0.15];
        return;
    }
    if (_seekInFlight) { _seekQueued = YES; return; }
    _seekInFlight = YES;
    _seekSawSeeking = NO;
    _seekPolls = 0;
    [self suspendEnhanceFilters];

    char buf[64];
    snprintf(buf, sizeof(buf), "%f", _seekTarget);
    mpv_cmd(_mpv, (const char *[]){"seek", buf, "absolute+exact", NULL});
    [self startSeekPolling];
}

- (void)startSeekPolling
{
    if (_seekPollTimer) return;
    __weak typeof(self) wself = self;
    _seekPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.04 repeats:YES
                                                     block:^(NSTimer *tm) {
        AppDelegate *s = wself;
        if (s) [s seekPollTick];
    }];
}

- (void)seekPollTick
{
    if (!_mpv) { [self finishSeek]; return; }
    _seekPolls++;

    BOOL seeking = mpv_bool(_mpv, "seeking");
    double pos = mpv_num(_mpv, "time-pos");
    if (seeking) _seekSawSeeking = YES;

    // 光看 seeking 不够：mpv 是异步命令，前几十毫秒可能还没置位，
    // 早退会「提前恢复滤镜」，剩下的解码又带着补帧跑，等于白优化。
    // 所以要求「不在 seek」且「位置已经贴到目标」才算完
    BOOL arrived = !seeking && isfinite(pos) && fabs(pos - _seekTarget) < 1.5;
    if (_seekPolls >= 3 && arrived) { [self finishSeek]; return; }
    if (_seekPolls > 100) [self finishSeek];   // 4 秒兜底，别把进度条永远锁住
}

- (void)finishSeek
{
    [_seekPollTimer invalidate];
    _seekPollTimer = nil;
    _seekInFlight = NO;
    _seeking = NO;
    [self resumeEnhanceFilters];
    if (_seekQueued) { _seekQueued = NO; [self runPendingSeek]; }
}

/// 方向键：转成绝对位置走同一条链路（同样会临时断开滤镜）
- (void)seekBy:(double)d
{
    if (!_mpv) return;
    double base = mpv_num(_mpv, "time-pos");
    if (!isfinite(base)) return;
    _seekTarget = base + d;
    _lastSeekTouch = CFAbsoluteTimeGetCurrent();
    [self runPendingSeek];
}

// 不能叫 setVolume: —— 与 volume 这个 NSSlider 属性自动合成的 setter 撞名
/// 音量统一在这里落地：上限锁 100%，不跟 mpv 默认的 130% 走
- (void)applyVolume:(double)v
{
    if (v > 100) v = 100;
    if (v < 0) v = 0;
    mpv_set_property(_mpv, "volume", MPV_FORMAT_DOUBLE, &v);
    if (v > 0 && mpv_bool(_mpv, "mute")) {
        int zero = 0;
        mpv_set_property(_mpv, "mute", MPV_FORMAT_FLAG, &zero);
    }
    [self updateMuteButton];
}

/// , / . 键调音量，一次 5%
- (void)adjustVolumeBy:(double)dv
{
    double v = mpv_num(_mpv, "volume") + dv;
    if (v > 100) v = 100; else if (v < 0) v = 0;
    [self applyVolume:v];
    [self showControls];
}

- (void)toggleMute
{
    int m = mpv_bool(_mpv, "mute") ? 0 : 1;
    mpv_set_property(_mpv, "mute", MPV_FORMAT_FLAG, &m);
    [self updateMuteButton];
}

- (void)updateMuteButton
{
    BOOL muted = mpv_bool(_mpv, "mute");
    double v = mpv_num(_mpv, "volume");
    [self setSymbol:(muted || v <= 0) ? @"speaker.slash.fill" : @"speaker.fill"
           onButton:_muteBtn];
    if (!_seeking) _volume.doubleValue = v;
}

- (void)setSpeed:(double)s
{
    mpv_set_property(_mpv, "speed", MPV_FORMAT_DOUBLE, &s);
}

- (void)toggleFullScreen
{
    [_window toggleFullScreen:nil];
}

// ── 打开文件 ────────────────────────────────────────────────────────────────

- (void)openFile:(NSString *)path
{
    NSLog(@"[ANEPlayer] openFile: %@ (mpv=%p)", path, (void *)_mpv);
    if (!path) return;
    if (!_mpv) {
        // 启动早期（openFiles: 有时比 applicationDidFinishLaunching 还早），
        // mpv 还没建好，先把文件记下来，等 mpv 就绪后再打开
        _pendingFile = path;
        return;
    }
    mpv_cmd(_mpv, (const char *[]){"loadfile", path.UTF8String, NULL});
    // 已经开了：清掉早期缓存的路径，避免 didFinishLaunching 里再补开一次
    _pendingFile = nil;

    _currentFile = path.lastPathComponent;
    _currentVideoBase = path.lastPathComponent.stringByDeletingPathExtension;
    _window.title = _currentFile;
    mpv_cmd(_mpv, (const char *[]){"set", "pause", "no", NULL});
    _tracksBuilt = NO;              // 触发轨道菜单重建
    // 换片：等新视频的尺寸出来再重新适配窗口比例（旧约束先解开，免得瞬间被夹变形）
    _didFitWindow = NO;
    _fittedAspect = NSZeroSize;
    _window.contentAspectRatio = NSZeroSize;
    [self showControls];

    // 加载视频之外找一遍同名外挂字幕（sub-auto 只认白名单目录，这里放宽到同目录）
    [self autoLoadExternalSubs:path];
    [self reloadDanmakuForPath:path];

    // 命令行带进来的外挂字幕：loadfile 之后再 add，否则会被 loadfile 清掉
    NSArray *subs = [_pendingSubs copy];
    if (subs.count) {
        [_pendingSubs removeAllObjects];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            for (NSString *s in subs) [self addSubtitle:s select:YES];
        });
    }
}

/// 找出「和这个视频同名」的外挂字幕。
/// 只认两种：`视频名.ass` 和 `视频名.语言.ass`（xx.sc.ass / xx.tc.ass 这类），
/// 同目录里别的集数（[01][02]…）一律不算——这就是之前列出十几条的元凶。
- (NSArray<NSString *> *)externalSubsForVideo:(NSString *)video
{
    if (!video.length) return @[];
    NSString *dir  = video.stringByDeletingLastPathComponent;
    NSString *base = video.lastPathComponent.stringByDeletingPathExtension;
    NSSet *exts = [NSSet setWithArray:@[@"srt", @"ass", @"ssa", @"vtt",
                                        @"sub", @"idx", @"sup", @"mks"]];
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSString *f in all) {
        if ([f hasPrefix:@"."]) continue;
        if (![exts containsObject:f.pathExtension.lowercaseString]) continue;
        NSString *stem = f.stringByDeletingPathExtension;
        if ([stem isEqualToString:base] ||
            [stem hasPrefix:[base stringByAppendingString:@"."]]) {
            [hits addObject:[dir stringByAppendingPathComponent:f]];
        }
    }
    [hits sortUsingSelector:@selector(localizedStandardCompare:)];
    return hits;
}

/// 同目录下「和视频同名」的外挂字幕全部挂上（简体/繁体双轨很常见）
- (void)autoLoadExternalSubs:(NSString *)video
{
    NSArray<NSString *> *subs = [self externalSubsForVideo:video];
    if (!subs.count) return;
    NSLog(@"[ANEPlayer] 同名外挂字幕 %lu 个: %@", (unsigned long)subs.count, subs);

    // 默认选中简体优先（sc/tc/chs/chi/zh），否则第一条
    NSUInteger best = 0;
    for (NSUInteger i = 0; i < subs.count; i++) {
        NSString *n = subs[i].lastPathComponent.lowercaseString;
        if ([n containsString:@".sc."] || [n containsString:@".chs."] ||
            [n containsString:@".zh."] || [n containsString:@".chi."] ||
            [n containsString:@".tc."]) { best = i; break; }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.4 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        for (NSUInteger i = 0; i < subs.count; i++) {
            [self addSubtitle:subs[i] select:(i == best)];
        }
    });
}

- (void)addSubtitle:(NSString *)path select:(BOOL)sel
{
    if (!path || !_mpv) return;
    NSLog(@"[ANEPlayer] sub-add: %@ select=%d", path, sel);
    if (sel) mpv_cmd(_mpv, (const char *[]){"sub-add", path.UTF8String, "select", NULL});
    else     mpv_cmd(_mpv, (const char *[]){"sub-add", path.UTF8String, NULL});

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.6 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [self rebuildTrackMenus];
        self.tracksBuilt = YES;
    });
}

- (void)openSubtitlePanel
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.message = @"选择字幕文件";
    if ([p runModal] == NSModalResponseOK && p.URL) {
        [self addSubtitle:p.URL.path select:YES];
    }
}

- (void)selectTrack:(NSMenuItem *)item
{
    // mpv_rec 放在 userInfo：@[prop, id]
    NSString *prop = item.representedObject[@"prop"];
    NSNumber *tid  = item.representedObject[@"id"];
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)tid.integerValue);
    mpv_cmd(_mpv, (const char *[]){"set", prop.UTF8String, buf, NULL});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ [self rebuildTrackMenus]; });
}

- (void)toggleSubVisibility
{
    BOOL vis = mpv_bool(_mpv, "sub-visibility");
    int v = vis ? 0 : 1;
    mpv_set_property(_mpv, "sub-visibility", MPV_FORMAT_FLAG, &v);
    [self rebuildTrackMenus];
}

/// 列出某类轨道（"sub" / "audio"）
- (NSArray *)mpvTracks:(const char *)type
{
    mpv_node node;
    if (mpv_get_property(_mpv, "track-list", MPV_FORMAT_NODE, &node) < 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    if (node.format == MPV_FORMAT_NODE_ARRAY) {
        for (int i = 0; i < node.u.list->num; i++) {
            mpv_node *t = &node.u.list->values[i];
            if (t->format != MPV_FORMAT_NODE_MAP) continue;
            NSString *ty = nil, *lang = nil, *title = nil, *codec = nil, *extfile = nil;
            int64_t tid = -1; BOOL sel = NO;
            for (int j = 0; j < t->u.list->num; j++) {
                const char *k = t->u.list->keys[j];
                mpv_node *v = &t->u.list->values[j];
                if (!strcmp(k, "type") && v->format == MPV_FORMAT_STRING)        ty = @(v->u.string);
                else if (!strcmp(k, "id") && v->format == MPV_FORMAT_INT64)      tid = v->u.int64;
                else if (!strcmp(k, "selected") && v->format == MPV_FORMAT_FLAG) sel = v->u.flag;
                else if (!strcmp(k, "lang") && v->format == MPV_FORMAT_STRING)   lang = @(v->u.string);
                else if (!strcmp(k, "title") && v->format == MPV_FORMAT_STRING)  title = @(v->u.string);
                else if (!strcmp(k, "codec") && v->format == MPV_FORMAT_STRING)  codec = @(v->u.string);
                else if (!strcmp(k, "external-filename") && v->format == MPV_FORMAT_STRING)
                    extfile = @(v->u.string);
            }
            if (ty && strcmp(type, ty.UTF8String) == 0) {
                [out addObject:@{ @"id": @(tid), @"selected": @(sel),
                                  @"lang": lang ?: @"", @"title": title ?: @"",
                                  @"codec": codec ?: @"", @"file": extfile ?: @"" }];
            }
        }
    }
    mpv_free_node_contents(&node);
    return out;
}

/// 重建「字幕」「音轨」两个菜单。文件切换后调用。
- (void)rebuildTrackMenus
{
    [self fillTrackMenu:_subTrackMenu   mpvProp:"sid"   trackType:"sub"   noneTitle:@"关闭字幕"];
    [self fillTrackMenu:_audioTrackMenu mpvProp:"aid"   trackType:"audio" noneTitle:@"关闭音轨"];
    // 面板开着的话一起刷新（换片 / 加字幕 / 切轨都会走到这里）
    if (_subPanel && !_subPanel.hidden) [self reloadSubPanel];
}

- (void)fillTrackMenu:(NSMenu *)menu mpvProp:(const char *)prop
            trackType:(const char *)type noneTitle:(NSString *)noneTitle
{
    if (!menu) return;
    [menu removeAllItems];

    NSMenuItem *off = [[NSMenuItem alloc] initWithTitle:noneTitle
                                                 action:@selector(selectTrack:)
                                          keyEquivalent:@""];
    off.target = self;
    off.representedObject = @{ @"prop": @(prop), @"id": @(0) };
    [menu addItem:off];

    NSArray *tracks = [self mpvTracks:type];
    int64_t cur = (int64_t)mpv_num(_mpv, prop);
    if (tracks.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc] initWithTitle:@"（无）" action:nil keyEquivalent:@""];
        none.enabled = NO;
        [menu addItem:none];
    }
    for (NSDictionary *t in tracks) {
        NSString *label = [NSString stringWithFormat:@"#%@  %@%@",
                           t[@"id"],
                           t[@"lang"] && [t[@"lang"] length] ? [t[@"lang"] stringByAppendingString:@"  "] : @"",
                           t[@"title"] && [t[@"title"] length] ? t[@"title"] : (t[@"codec"] ?: @"")];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:label
                                                    action:@selector(selectTrack:)
                                             keyEquivalent:@""];
        it.target = self;
        it.representedObject = @{ @"prop": @(prop), @"id": t[@"id"] };
        NSNumber *sel = t[@"selected"];
        NSNumber *tid = t[@"id"];
        it.state = (sel.boolValue || (cur == tid.integerValue && cur != 0))
                     ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }
}

- (void)openPanel
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.allowedContentTypes = @[];  // 空 = 允许任意文件，交给 mpv 判断能不能解
    if ([p runModal] == NSModalResponseOK && p.URL) {
        [self openFile:p.URL.path];
    }
}

// ── UI 构建 ─────────────────────────────────────────────────────────────────

- (void)buildWindow
{
    _lockAspect = YES;      // 默认锁定窗口比例，拖边不会把画面拉变形
    NSRect frame = NSMakeRect(0, 0, 1000, 620);
    NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                       NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                       NSWindowStyleMaskFullSizeContentView;
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"ANEPlayer";
    _window.delegate = self;
    // 最小尺寸放小一点：按视频比例自适应时（比如 21:9 或竖屏）不能被旧的
    // 660x400 硬限制顶回去，那样比例就错了
    _window.minSize = NSMakeSize(480, 270);
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;   // 标题别压在画面上
    _window.titleVisibility = NSWindowTitleHidden;   // 标题别压在画面上
    _window.backgroundColor = NSColor.blackColor;
    [_window center];
    [_window makeKeyAndOrderFront:nil];

    NSView *root = _window.contentView;
    root.wantsLayer = YES;

    _videoView = [[ANEVideoView alloc] initWithFrame:root.bounds mpv:_mpv];
    _videoView.frame = root.bounds;
    _videoView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_videoView];

    // 拖文件到窗口即打开
    [_videoView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];

    [self buildControls];
    [self buildStats];
    _pendingSubs = [NSMutableArray array];
    [self setupMenus];
    [self setupKeys];

    _uiTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                               target:self
                                             selector:@selector(tick)
                                             userInfo:nil
                                              repeats:YES];
    [self layoutChrome];
    [self showControls];
}

/// 图标按钮：用 SF Symbols（macOS 11+），template 渲染 + labelColor，
/// 这样在玻璃上会跟着明暗自动反转，亮画面下也看得清。
- (NSButton *)iconButton:(NSString *)symbol action:(SEL)sel
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    if (@available(macOS 11.0, *)) {
        NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                                 accessibilityDescription:nil];
        img.template = YES;
        b.image = img;
        b.imagePosition = NSImageOnly;
        b.imageScaling = NSImageScaleProportionallyDown;
    } else {
        b.title = symbol;
    }
    b.target = self;
    b.action = sel;
    b.bezelStyle = NSBezelStyleRounded;
    b.bordered = NO;
    b.contentTintColor = NSColor.labelColor;
    [b setButtonType:NSButtonTypeMomentaryChange];
    return b;
}

/// 带文字的胶囊按钮（补帧档位）：保留系统 bezel，macOS 26 下自动是玻璃质感。
- (NSButton *)pillButton:(NSString *)title action:(SEL)sel
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.title = title;
    b.target = self;
    b.action = sel;
    b.bordered = NO;                // 自己画底：系统 bezel 在深色条上偏亮，白字看不清
    b.wantsLayer = YES;
    b.layer.cornerRadius = 7;
    b.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [b setButtonType:NSButtonTypeMomentaryPushIn];
    return b;
}

/// 所有玻璃面统一用 NSVisualEffectView（HUD 深色模糊）。
/// 之前用 NSGlassEffectView（macOS 26 的「液态玻璃」）：它不做背景模糊，只叠一层
/// 半透明色膜，压在视频上像张有色玻璃纸，颜色跟着画面乱飘——这就是「怪怪的」来源。
/// 换成经典毛玻璃后，背后画面被真正虚化，观感跟 IINA 一致。
- (NSView *)makeEffectView:(NSRect)rc radius:(CGFloat)radius
{
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:rc];
        g.style = NSGlassEffectViewStyleRegular;
        g.cornerRadius = radius;
        if (@available(macOS 27.0, *)) {
            if ([g respondsToSelector:@selector(setEffectIsInteractive:)])
                g.effectIsInteractive = YES;
        }
        // 液态玻璃会按背后画面自动挑明/暗，遇到亮画面就把文字变白，
        // 压在彩条上完全看不清。这里锁死浅色外观 → 文字恒为深色（IINA 的观感）
        g.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        // 液态玻璃会按背后画面自动挑明/暗，遇到亮画面就把文字变白，
        // 压在彩条上完全看不清。这里锁死浅色外观 → 文字恒为深色（IINA 的观感）
        g.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        return g;
    }
    // 旧系统回退：浅色毛玻璃，观感尽量贴近液态玻璃
    NSVisualEffectView *ve = [[NSVisualEffectView alloc] initWithFrame:rc];
    ve.material = NSVisualEffectMaterialPopover;
    ve.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    ve.state = NSVisualEffectStateActive;
    ve.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    ve.wantsLayer = YES;
    ve.layer.cornerRadius = radius;
    ve.layer.masksToBounds = YES;
    return ve;
}

/// 取「可以往里放控件」的那一层：液态玻璃必须用 contentView（否则控件不在玻璃层里），
/// 老毛玻璃直接 addSubview 即可。
- (NSView *)contentHostForPanel:(NSView *)panel flipped:(BOOL)flipped
{
    NSView *inner = flipped ? [[ANEFlippedView alloc] initWithFrame:panel.bounds]
                            : [[NSView alloc] initWithFrame:panel.bounds];
    inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (@available(macOS 26.0, *)) {
        if ([panel isKindOfClass:NSGlassEffectView.class]) {
            ((NSGlassEffectView *)panel).contentView = inner;
            return inner;
        }
    }
    [panel addSubview:inner];
    return inner;
}

/// 控制条 = 浮动液态玻璃胶囊（macOS 26+ 用 NSGlassEffectView，旧系统回退 HUD 毛玻璃）。
/// 所有控件必须放进 contentView——NSGlassEffectView 只保证 contentView 位于玻璃层内。
- (void)buildControls
{
    CGFloat H = kBarHeight;
    NSRect rootB = _window.contentView.bounds;
    // 固定贴底、左右到边（不是浮动胶囊）
    NSRect rc = NSMakeRect(0, 0, NSWidth(rootB), H);

    NSView *bar = [self makeEffectView:rc radius:0];
    NSView *inner = [self contentHostForPanel:bar flipped:NO];

    inner.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // 贴底要的是「顶部边距可伸缩」（NSViewMaxYMargin）。
    // 写成 NSViewMinYMargin 是反的：底部边距可伸缩 → 控件跟着顶边走，
    // 窗口一变高控制条就往上飘，底部露出一截黑边。
    bar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _controls = bar;
    [_window.contentView addSubview:bar positioned:NSWindowAbove relativeTo:[self chromeAnchor]];

    _controlsInner = inner;
    CGFloat W = NSWidth(rootB);

    // 控件只管创建，位置统一交给 layoutControls 算 —— 窗口一改宽就要重排，
    // 光靠 autoresizingMask 会让右侧那串按钮互相压住。
    _playBtn = [self iconButton:@"pause.fill" action:@selector(togglePlay)];
    [inner addSubview:_playBtn];

    _timeLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _timeLabel.stringValue = @"00:00 / 00:00";
    _timeLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightSemibold];
    _timeLabel.textColor = NSColor.secondaryLabelColor;   // 灰色，跟 IINA 控制条一致
    [self styleLabel:_timeLabel];
    [inner addSubview:_timeLabel];

    _fsBtn = [self iconButton:@"arrow.up.left.and.arrow.down.right" action:@selector(toggleFullScreen)];
    [inner addSubview:_fsBtn];

    _aneBtn = [self pillButton:@"2x" action:@selector(showFactorMenu)];
    [inner addSubview:_aneBtn];

    _subBtn = [self iconButton:@"captions.bubble" action:@selector(toggleSubPanel)];
    if (!_subBtn.image) [self setSymbol:@"text.bubble" onButton:_subBtn];
    _subBtn.toolTip = @"字幕面板";
    [inner addSubview:_subBtn];

    _listBtn = [self iconButton:@"list.bullet" action:@selector(togglePlaylistPanel)];
    _listBtn.toolTip = @"播放列表";
    [inner addSubview:_listBtn];

    _settingsBtn = [self iconButton:@"gearshape" action:@selector(toggleSettingsPanel)];
    _settingsBtn.toolTip = @"设置";
    [inner addSubview:_settingsBtn];

    _shotBtn = [self iconButton:@"camera" action:@selector(takeScreenshot)];
    if (!_shotBtn.image) [self setSymbol:@"camera.fill" onButton:_shotBtn];
    _shotBtn.toolTip = @"截图（⌘S）";
    [inner addSubview:_shotBtn];

    _volume = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _volume.minValue = 0; _volume.maxValue = 100;
    _volume.doubleValue = 100;
    _volume.target = self;
    _volume.action = @selector(volumeChanged:);
    [inner addSubview:_volume];

    _muteBtn = [self iconButton:@"speaker.fill" action:@selector(toggleMute)];
    [inner addSubview:_muteBtn];

    _progress = [[NSSlider alloc] initWithFrame:NSZeroRect];
    _progress.minValue = 0; _progress.maxValue = 100;
    _progress.doubleValue = 0;
    _progress.target = self;
    _progress.action = @selector(progressChanged:);
    [inner addSubview:_progress];

    // 章节刻度层：在滑块之上，但不吃鼠标事件
    _chapterTrack = [[ANEChapterTrack alloc] initWithFrame:NSZeroRect];
    _chapterTrack.hidden = YES;
    [inner addSubview:_chapterTrack positioned:NSWindowAbove relativeTo:_progress];

    // 滑块填充色改成白色（默认是系统强调蓝，用户不要蓝色）
    _progress.trackFillColor = [NSColor.labelColor colorWithAlphaComponent:0.75];
    _volume.trackFillColor   = [NSColor.labelColor colorWithAlphaComponent:0.75];

    NSLog(@"[ANEPlayer] 控制条构建：窗口宽 %.0f", W);
    [self layoutControls];
    [self updateAneButton];
}

/// 按当前窗口宽度重排控制条：从右往左摆，窄窗口收起音量，
/// 保证进度条始终有位置、按钮之间永远不重叠。
/// 右起顺序：设置 · 全屏 · 补帧 · 字幕 · 播放列表 · 音量 · 静音
- (void)layoutControls
{
    if (!_controlsInner) return;
    NSRect b = _window.contentView.bounds;
    CGFloat W = NSWidth(b), H = kBarHeight, mid = H / 2.0;
    if (W <= 0) return;

    // 玻璃的 contentView 必须和外层同步（某些系统版本里它不自动跟）
    _controlsInner.frame = NSMakeRect(0, 0, W, H);

    _playBtn.frame   = NSMakeRect(11, mid - 13, 26, 26);
    _timeLabel.frame = NSMakeRect(42, mid - 9, 104, 18);

    CGFloat x = W - 12.0;

    x -= 24;
    _settingsBtn.frame = NSMakeRect(x, mid - 12, 24, 24);

    x -= (3 + 28);
    _shotBtn.frame = NSMakeRect(x, mid - 14, 28, 28);

    x -= (3 + 28);
    _fsBtn.frame = NSMakeRect(x, mid - 14, 28, 28);

    x -= (3 + 28);
    _subBtn.frame = NSMakeRect(x, mid - 14, 28, 28);

    x -= (3 + 28);
    _listBtn.frame = NSMakeRect(x, mid - 14, 28, 28);

    x -= (3 + 40);
    _aneBtn.frame = NSMakeRect(x, mid - 12, 40, 24);   // 补帧放这一排最左（第一位）

    BOOL showVolume = (W >= 520);
    _volume.hidden = !showVolume;
    _muteBtn.hidden = !showVolume;
    if (showVolume) {
        x -= (6 + 64);
        _volume.frame = NSMakeRect(x, mid - 9, 64, 18);
        x -= (2 + 26);
        _muteBtn.frame = NSMakeRect(x, mid - 13, 26, 26);
    }

    CGFloat progX = 154.0;
    CGFloat progW = x - 8.0 - progX;
    if (progW < 60) progW = 60;
    _progress.frame = NSMakeRect(progX, mid - 8, progW, 16);
    _chapterTrack.frame = _progress.frame;      // 刻度层和滑块同框
}

// ── 窗口布局：控制条贴底、面板贴顶、窗口跟随视频比例 ─────────────────────────

/// Live resize / 全屏进出时再对齐一次。autoresizingMask 已经能应付绝大多数
/// 情况，这里加一道保险：无论窗口怎么变，控制条一定在 y=0，面板一定贴顶。
- (void)layoutChrome
{
    if (!_window || !_window.contentView) return;
    NSRect b = _window.contentView.bounds;
    if (NSWidth(b) <= 0 || NSHeight(b) <= 0) return;

    if (_controls) {
        _controls.frame = NSMakeRect(0, 0, NSWidth(b), kBarHeight);
        [self layoutControls];
    }
    if (_statsView) {
        NSRect f = _statsView.frame;
        CGFloat y = NSHeight(b) - NSHeight(f) - kStatsTopInset;
        if (fabs(NSMinY(f) - y) > 0.5) {
            _statsView.frame = NSMakeRect(NSMinX(f), y, NSWidth(f), NSHeight(f));
        }
    }
    if (_danmaku) [self updateDanmakuFrame];
    if (_subPanel && !_subPanel.hidden) [self reloadSubPanel];   // 位置和高度都按当前窗口重算
    if (_playlistPanel && !_playlistPanel.hidden) [self reloadPlaylist];
    if (_settingsPanel && !_settingsPanel.hidden) [self buildSettingsContent];
}

/// 字幕贴底（mpv 默认位置）。之前为了躲开控制条把 sub-pos 抬到 88 左右，
/// 但那会让字幕浮在半空——用户更希望它就在画面底部，被控制条盖住无所谓。

/// 拖动窗口时只做「摆控制条」这一件廉价的事，别的都留到松手后再做。
- (void)windowDidResignKey:(NSNotification *)n { [self restoreSpaceBoost]; }

- (void)windowDidResize:(NSNotification *)n
{
    if (_liveResizing) {
        NSRect b = _window.contentView.bounds;
        _controls.frame = NSMakeRect(0, 0, NSWidth(b), kBarHeight);
        [self layoutControls];
        // 面板只挪位置，不重建（重建要塞十几行单选按钮，太重）
        for (NSView *p in @[_subPanel ?: NSNull.null, _playlistPanel ?: NSNull.null,
                            _settingsPanel ?: NSNull.null]) {
            if ((id)p == NSNull.null || p.hidden) continue;
            NSRect f = p.frame;
            p.frame = NSMakeRect(NSWidth(b) - NSWidth(f) - 12,
                                 kBarHeight + 12, NSWidth(f), NSHeight(f));
        }
        return;
    }
    [self layoutChrome];
    [self showControls];        // 拖动窗口时把控制条叫出来，方便观察
}

- (void)windowWillStartLiveResize:(NSNotification *)n
{
    _liveResizing = YES;
    [self showControls];        // 只叫一次，别每个事件都重启隐藏计时器
    [self startLagProbe];
}

- (void)windowDidEndLiveResize:(NSNotification *)n
{
    _liveResizing = NO;
    [self layoutChrome];        // 到这才把字幕位置、面板高度重算一遍
    [self showControls];
    [self tick];
    [self reportLagProbe];
}

- (void)windowDidEnterFullScreen:(NSNotification *)n { [self layoutChrome]; }
- (void)windowDidExitFullScreen:(NSNotification *)n  { [self layoutChrome]; }

// ── 拖动卡顿诊断（仅 ANEPLAYER_LAGLOG=/path 时启用，正常使用零开销）──────────

- (void)startLagProbe
{
    const char *p = getenv("ANEPLAYER_LAGLOG");
    if (!p || !p[0]) return;
    _lagSamples = [NSMutableArray array];
    [_lagTimer invalidate];
    __weak typeof(self) wself = self;
    _lagTimer = [NSTimer timerWithTimeInterval:1.0 / 120.0 repeats:YES block:^(NSTimer *t) {
        AppDelegate *s = wself;
        [s.lagSamples addObject:@(NSDate.date.timeIntervalSince1970)];
    }];
    // 必须挂到 commonModes：拖动窗口时 runloop 处于 eventTracking 模式
    [NSRunLoop.mainRunLoop addTimer:_lagTimer forMode:NSRunLoopCommonModes];
}

- (void)reportLagProbe
{
    if (!_lagTimer) return;
    [_lagTimer invalidate];
    _lagTimer = nil;
    NSArray<NSNumber *> *a = _lagSamples ?: @[];
    _lagSamples = nil;
    if (a.count < 4) return;

    double maxGap = 0, sum = 0;
    for (NSUInteger i = 1; i < a.count; i++) {
        double d = a[i].doubleValue - a[i - 1].doubleValue;
        if (d > maxGap) maxGap = d;
        sum += d;
    }
    double total = a.lastObject.doubleValue - a.firstObject.doubleValue;
    double avg = (sum / (a.count - 1)) * 1000.0;
    NSLog(@"[LAG] 采样 %lu 次 / %.2fs → 最长停顿 %.1fms，平均间隔 %.1fms",
          (unsigned long)a.count, total, maxGap * 1000.0, avg);

    const char *p = getenv("ANEPLAYER_LAGLOG");
    if (p && p[0]) {
        NSString *line = [NSString stringWithFormat:
            @"samples=%lu total=%.2fs maxStall=%.1fms avgGap=%.1fms\n",
            (unsigned long)a.count, total, maxGap * 1000.0, avg];
        [line writeToFile:@(p) atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

/// 拿到视频尺寸后把窗口调成同样的比例：黑边消失，之后拖边也不会变形。
/// 每换一个文件只做一次，靠 tick 轮询等第一个有效尺寸。
- (void)fitWindowToVideoIfNeeded
{
    if (_didFitWindow || !_mpv) return;
    NSSize vs = [self videoSize];
    if (vs.width < 16 || vs.height < 16) return;        // 还没解出画面，等下一轮

    // 竖屏视频在 video-params 里仍是存储方向，靠 rotate 标记才知道要转
    int64_t rot = 0;
    if (mpv_get_property(_mpv, "video-params/rotate", MPV_FORMAT_INT64, &rot) >= 0 &&
        rot != 0 && (labs((long)rot) / 90) % 2 == 1) {
        CGFloat t = vs.width; vs.width = vs.height; vs.height = t;
    }
    _didFitWindow = YES;
    _fittedAspect = vs;

    _window.contentAspectRatio = _lockAspect ? vs : NSZeroSize;

    if (_window.styleMask & NSWindowStyleMaskFullScreen) return;   // 全屏别动

    NSScreen *scr = _window.screen ?: NSScreen.mainScreen;
    NSRect vis = scr.visibleFrame;
    CGFloat aspect = vs.width / vs.height;
    CGFloat maxW = NSWidth(vis) * 0.9;
    CGFloat maxH = NSHeight(vis) * 0.9;

    // 起点沿用当前窗口宽度；上次被拖得太小就放大到舒服的尺寸
    CGFloat w = MIN(NSWidth(_window.frame), maxW);
    if (w < 640) w = MIN(960, maxW);
    CGFloat h = w / aspect;
    if (h > maxH) { h = maxH; w = h * aspect; }
    if (h < 260)  { h = 260;  w = h * aspect; }

    // 以窗口中心为锚点缩放，然后夹回屏幕可见区，别把标题栏顶到屏幕外
    NSRect f = _window.frame;
    NSRect t = NSMakeRect(NSMidX(f) - w / 2, NSMidY(f) - h / 2, w, h);
    if (w <= NSWidth(vis))  t.origin.x = MIN(MAX(NSMinX(t), NSMinX(vis)), NSMaxX(vis) - w);
    if (h <= NSHeight(vis)) t.origin.y = MIN(MAX(NSMinY(t), NSMinY(vis)), NSMaxY(vis) - h);

    [self layoutChrome];
    [_window setFrame:t display:YES animate:YES];
    NSLog(@"[ANEPlayer] 窗口适配视频比例 %.0fx%.0f → %.0fx%.0f",
          vs.width, vs.height, w, h);
}

/// 「窗口 → 按视频比例锁定窗口」：关掉后可以随便拖成任意形状（会出现黑边）
- (void)toggleLockAspect
{
    _lockAspect = !_lockAspect;
    _window.contentAspectRatio = _lockAspect ? _fittedAspect : NSZeroSize;
    for (NSMenuItem *i in _windowMenu.itemArray) {
        if (i.tag == 1002)
            i.state = _lockAspect ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self showControls];
}

/// 标签通用设置：无边框无背景，靠玻璃的 vibrancy 自动保证对比度
- (void)styleLabel:(NSTextField *)lb
{
    lb.bezeled = NO;
    lb.drawsBackground = NO;
    lb.editable = NO;
    lb.selectable = NO;
}

// ── 播放信息面板（Tab 唤起）──────────────────────────────────────────────────

- (void)buildStats
{
    CGFloat w = 360, h = 322;
    NSRect rootB = _window.contentView.bounds;
    // 55pt 的顶部留白：标题栏透明后内容区会延伸到交通灯下面，太靠上会被压住
    NSRect rc = NSMakeRect(16, NSHeight(rootB) - h - kStatsTopInset, w, h);

    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(14, 12, w - 28, h - 24)];
    tv.editable = NO;
    tv.selectable = YES;
    tv.drawsBackground = NO;
    tv.richText = NO;
    tv.textContainer.widthTracksTextView = YES;
    tv.textContainerInset = NSMakeSize(0, 0);
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    // 灰色文字（跟 IINA 的信息面板一致），纯白/纯黑压在画面上太抢
    tv.textColor = NSColor.secondaryLabelColor;
    tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *panel = [self makeEffectView:rc radius:14];
    NSView *inner = [self contentHostForPanel:panel flipped:NO];
    [inner addSubview:tv];
    panel.autoresizingMask = NSViewMinYMargin;      // 始终贴顶
    panel.hidden = YES;
    _statsView = panel;
    _statsText = tv;
    _statsVisible = NO;
    [_window.contentView addSubview:panel positioned:NSWindowAbove relativeTo:[self chromeAnchor]];
}

- (void)toggleStats
{
    _statsVisible = !_statsVisible;
    _statsView.hidden = !_statsVisible;
    if (_statsVisible) {
        [self updateStats];
        [self showControls];
    }
}

/// 调试：把进度标记追加写到小文件（进程被杀/崩溃时能看到走到哪一步）
static void ANEMark(NSString *msg)
{
    const char *p = getenv("ANEPLAYER_MARKLOG");
    if (!p || !p[0]) return;
    NSString *path = @(p);
    NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [d writeToFile:path atomically:YES]; return; }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:d];
    } @catch (NSException *e) { /* 忽略 */ }
    [fh closeFile];
}

- (void)updateStats
{
    if (!_statsVisible || !_mpv) return;
    ANEMark(@"--- enter updateStats ---");

    NSSize vs = [self videoSize];
    double cfp  = mpv_num(_mpv, "container-fps");
    double vfps = mpv_num(_mpv, "estimated-vf-fps");
    double dfps = mpv_num(_mpv, "estimated-display-fps");
    ANEMark(@"  basic ok");

    NSString *vcodec = [self shortCodec:mpv_str(_mpv, "video-codec")] ?: @"-";
    NSString *hw = mpv_str(_mpv, "hwdec-current");
    BOOL hwOn = hw.length > 0 && ![hw isEqualToString:@"no"] && ![hw isEqualToString:@"auto"];
    NSString *hwpf = mpv_str(_mpv, "video-params/hw-pixelformat");
    NSSize outSize = [self sizeFromProp:"video-out-params"];
    ANEMark(@"  video params ok");

    double dropD   = mpv_num(_mpv, "decoder-frame-drop-count");
    double dropV   = mpv_num(_mpv, "vo-drop-frame-count");
    double delayed = mpv_num(_mpv, "vo-delayed-frame-count");
    double mist    = mpv_num(_mpv, "mistimed-drop-count");
    double avsync  = mpv_num(_mpv, "avsync");
    double cacheP  = mpv_num(_mpv, "cache-buffering-state");
    double cacheS  = mpv_num(_mpv, "demuxer-cache-duration");
    ANEMark(@"  perf counters ok");

    NSString *acodec = [self shortCodec:mpv_str(_mpv, "audio-codec")];
    double sr = mpv_num(_mpv, "audio-params/samplerate");
    NSString *ch = mpv_str(_mpv, "audio-params/channel-count");
    ANEMark(@"  audio ok");

    double outFps = dfps > 0 ? dfps : vfps;   // vo=libmpv 时 display-fps 恒为 0

    NSMutableString *s = [NSMutableString string];
    [s appendString:@"\n── 视频 ──────────────────\n"];
    if (cfp > 0)
        [s appendFormat:@"源      %.0fx%.0f  %@  %.1f fps\n", vs.width, vs.height, vcodec, cfp];
    else
        [s appendFormat:@"源      %.0fx%.0f  %@\n", vs.width, vs.height, vcodec];
    if (hwOn)
        [s appendFormat:@"解码    硬解  %@\n", hwpf.length ? hwpf : hw];
    else
        [s appendString:@"解码    软解  CPU\n"];
    [s appendFormat:@"输出    %.0fx%.0f  %.1f fps\n",
        outSize.width, outSize.height, outFps];
    [s appendFormat:@"补帧    %@\n", (_factor == 1) ? @"关" :
                                     [NSString stringWithFormat:@"%dx", _factor]];

    [s appendString:@"\n── 流畅度 ────────────────\n"];
    [s appendFormat:@"丢帧    解码 %.0f · 显示 %.0f · 误时 %.0f\n", dropD, dropV, mist];
    [s appendFormat:@"积压    %.0f 帧\n", delayed];
    [s appendFormat:@"音画    %+.3f s\n", avsync];
    [s appendFormat:@"缓存    %.0f%%  %.1f s\n", cacheP, cacheS];

    [s appendString:@"\n── 音频 ──────────────────\n"];
    if (!acodec.length) {
        [s appendString:@"（无音轨）\n"];
    } else {
        NSString *chName = @"多声道";
        if ([ch isEqualToString:@"1"])       chName = @"单声道";
        else if ([ch isEqualToString:@"2"])  chName = @"立体声";
        else if ([ch isEqualToString:@"6"])  chName = @"5.1";
        else if ([ch isEqualToString:@"8"])  chName = @"7.1";
        [s appendFormat:@"%@  %.0f Hz  %@\n", acodec, sr,
            ch ? [NSString stringWithFormat:@"%@ 声道 (%@)", ch, chName] : @""];
    }

    ANEMark(@"  string built ok");

    _statsText.string = s;
    ANEMark(@"  assigned to NSTextView ok");

    // 面板高度跟着内容走。固定高度会裁字：内容一多，最上面一行（位置）就被切掉。
    NSTextContainer *tc = _statsText.textContainer;
    NSLayoutManager *lm = _statsText.layoutManager;
    [lm ensureLayoutForTextContainer:tc];
    CGFloat textH = ceil(NSHeight([lm usedRectForTextContainer:tc]));
    CGFloat panelH = textH + 26.0;                      // 上下各 13pt 内边距
    CGFloat availH = NSHeight(_window.contentView.bounds) - kStatsTopInset - 16.0;
    if (availH < 140) availH = 140;
    if (panelH > availH) panelH = availH;
    CGFloat panelW = 360.0;
    NSRect pf = NSMakeRect(16, NSHeight(_window.contentView.bounds) - panelH - kStatsTopInset,
                           panelW, panelH);
    if (!NSEqualRects(_statsView.frame, pf)) _statsView.frame = pf;
    NSRect tf = NSMakeRect(14, 13, panelW - 28, panelH - 26);
    if (!NSEqualRects(_statsText.frame, tf)) _statsText.frame = tf;

    // 排查开关：ANEPLAYER_STATSLOG=/tmp/stats.txt 可把同样的文本落盘，
    // 便于确认「面板看到的」和「mpv 实际给的」是否一致
    const char *dump = getenv("ANEPLAYER_STATSLOG");
    if (dump && dump[0]) {
        [s writeToFile:@(dump) atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

// ── 字幕面板（仿 IINA 的右侧面板）────────────────────────────────────────────

/// 液态玻璃统一深色：面板 appearance 设成 DarkAqua（文字/控件自动转深色版），
/// 再在内容层压一块半透明黑，保证压过亮画面时也是「深色玻璃」的观感。

/// 面板里的滑块统一去掉系统强调蓝
- (void)neutralSlider:(NSSlider *)sl
{
    sl.trackFillColor = [NSColor.labelColor colorWithAlphaComponent:0.75];
}

- (NSTextField *)panelLabel:(NSString *)text size:(CGFloat)sz weight:(NSFontWeight)wt
{
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSZeroRect];
    l.stringValue = text;
    l.font = [NSFont systemFontOfSize:sz weight:wt];
    // 灰色而不是纯黑：跟 IINA 的面板一致，压过亮画面时也不至于像贴了块黑字
    l.textColor = NSColor.secondaryLabelColor;
    [self styleLabel:l];
    return l;
}

/// 造一个右侧玻璃面板（三个面板共用：字幕 / 播放列表 / 设置）
- (NSView *)makeSidePanelWithWidth:(CGFloat)w content:(NSView **)outInner
{
    NSRect b = _window.contentView.bounds;
    CGFloat h = MAX(240, NSHeight(b) - kBarHeight - 24);
    NSRect rc = NSMakeRect(NSWidth(b) - w - 12, kBarHeight + 12, w, h);

    NSView *panel = [self makeEffectView:rc radius:16];
    NSView *inner = [self contentHostForPanel:panel flipped:YES];
    panel.hidden = YES;
    [_window.contentView addSubview:panel positioned:NSWindowAbove relativeTo:[self chromeAnchor]];
    if (outInner) *outInner = inner;
    return panel;
}

- (void)buildSubPanel
{
    NSView *inner = nil;
    _subPanel = [self makeSidePanelWithWidth:330 content:&inner];
    _subPanelContent = inner;
}

- (void)toggleSubPanel
{
    if (!_subPanel) [self buildSubPanel];
    BOOL show = _subPanel.hidden;
    [self hideSidePanelsExcept:_subPanel];
    _subPanel.hidden = !show;
    if (show) {
        [self reloadSubPanel];
        [self showControls];
    }
    [self updateSideButtons];
}

/// 同一时间只留一个右侧面板（字幕 / 播放列表 / 设置）
- (void)hideSidePanelsExcept:(NSView *)keep
{
    if (_subPanel && _subPanel != keep)      _subPanel.hidden = YES;
    if (_playlistPanel && _playlistPanel != keep) _playlistPanel.hidden = YES;
    if (_settingsPanel && _settingsPanel != keep) _settingsPanel.hidden = YES;
}

/// 当前显示着的那个右侧面板（没有就返回 nil）—— 给「点外面就收起」用
- (NSView *)visibleSidePanel
{
    if (_settingsPanel && !_settingsPanel.hidden) return _settingsPanel;
    if (_subPanel && !_subPanel.hidden)           return _subPanel;
    if (_playlistPanel && !_playlistPanel.hidden) return _playlistPanel;
    return nil;
}

- (void)updateSideButtons
{
    BOOL sub  = _subPanel && !_subPanel.hidden;
    BOOL list = _playlistPanel && !_playlistPanel.hidden;
    BOOL set  = _settingsPanel && !_settingsPanel.hidden;
    _subBtn.contentTintColor      = sub  ? NSColor.labelColor : NSColor.secondaryLabelColor;
    _listBtn.contentTintColor     = list ? NSColor.labelColor : NSColor.secondaryLabelColor;
    _settingsBtn.contentTintColor = set  ? NSColor.labelColor : NSColor.secondaryLabelColor;
}

/// 轨道显示名：优先外挂文件名（tc.ass / sc.ass 这种才分得清），
/// 其次 title / 语言，末尾补格式，跟 IINA 的「tc.ass (ass)」一致
- (NSString *)subTrackName:(NSDictionary *)t kind:(NSString *)kind
{
    NSString *name = nil;
    NSString *file = t[@"file"];
    if (file.length) name = file.lastPathComponent;
    if (!name.length) name = t[@"title"];
    if (!name.length && [t[@"lang"] length]) name = [t[@"lang"] uppercaseString];
    if (!name.length) name = [NSString stringWithFormat:@"%@ #%@", kind, t[@"id"]];

    // 外挂字幕一般直接是「视频名.zh.ass」，列表里每条都顶着几十个字的一样的
    // 长前缀，完全看不出区别。把前缀裁掉只留后面那截（zh.ass / tc.ass）。
    NSString *base = _currentVideoBase;
    if (base.length && name.length > base.length && [name hasPrefix:base]) {
        NSString *rest = [name substringFromIndex:base.length];
        NSRange r = [rest rangeOfCharacterFromSet:
                     [[NSCharacterSet characterSetWithCharactersInString:@". _-"] invertedSet]];
        if (r.location != NSNotFound && rest.length - r.location > 0)
            name = [rest substringFromIndex:r.location];
    }

    NSString *codec = t[@"codec"];
    if (codec.length && ![name.pathExtension.lowercaseString isEqualToString:codec.lowercaseString])
        return [NSString stringWithFormat:@"%@ (%@)", name, codec];
    return name;
}

/// 列表行：不用系统单选按钮（它的选中态是系统强调蓝，用户不要蓝色），
/// 改成「选中 = 一层浅色圆角高亮 + 亮色文字」，未选中 = 灰色文字。
- (ANETrackButton *)addListRowTo:(NSView *)host index:(NSInteger)idx title:(NSString *)title
                        selected:(BOOL)sel payload:(NSDictionary *)payload
                          action:(SEL)action width:(CGFloat)w rowH:(CGFloat)rowH
                            size:(CGFloat)fs
{
    ANETrackButton *row = [[ANETrackButton alloc]
        initWithFrame:NSMakeRect(16, idx * rowH, w - 32, rowH - 2)];
    row.bordered = NO;
    row.wantsLayer = YES;
    row.layer.cornerRadius = 6;
    row.layer.backgroundColor = sel
        ? [NSColor.blackColor colorWithAlphaComponent:0.10].CGColor
        : NSColor.clearColor.CGColor;

    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.firstLineHeadIndent = 10;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    row.attributedTitle = [[NSAttributedString alloc]
        initWithString:title
            attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:fs],
                          // 未选中用「72% 的正文色」而不是系统次级灰：
                          // 浅色玻璃压在亮画面上时，次级灰几乎看不见
                          NSForegroundColorAttributeName:
                              sel ? NSColor.labelColor
                                  : [NSColor.labelColor colorWithAlphaComponent:0.72],
                          NSParagraphStyleAttributeName: ps }];
    row.payload = payload;
    row.target = self;
    row.action = action;
    [host addSubview:row];
    return row;
}

/// 生成一段字幕轨单选列表，返回下一个可用的 y（翻转坐标，从上往下累加）
- (CGFloat)addTrackSectionTo:(NSView *)host top:(CGFloat)y width:(CGFloat)w
                       prop:(const char *)prop title:(NSString *)title
                     tracks:(NSArray<NSDictionary *> *)tracks action:(SEL)action
{
    NSTextField *cap = [self panelLabel:title size:11 weight:NSFontWeightSemibold];
    cap.textColor = NSColor.secondaryLabelColor;
    cap.frame = NSMakeRect(16, y, w - 32, 16);
    [host addSubview:cap];
    y += 22;

    int64_t cur = (int64_t)mpv_num(_mpv, prop);
    NSString *kind = (strcmp(prop, "aid") == 0) ? @"音轨" : @"字幕";

    NSMutableArray *names = [NSMutableArray arrayWithObject:@"关闭"];
    NSMutableArray *ids   = [NSMutableArray arrayWithObject:@(0)];
    for (NSDictionary *t in tracks) {
        [ids addObject:t[@"id"]];
        [names addObject:[self subTrackName:t kind:kind]];
    }

    CGFloat rowH = 24.0;
    ANEFlippedView *box = [[ANEFlippedView alloc]
        initWithFrame:NSMakeRect(0, y, w, rowH * names.count)];
    for (NSUInteger i = 0; i < names.count; i++) {
        BOOL on = ([ids[i] longLongValue] == cur);
        [self addListRowTo:box index:(NSInteger)i title:names[i] selected:on
                   payload:@{ @"prop": @(prop), @"id": ids[i] }
                    action:action width:w rowH:rowH size:12];
    }
    [host addSubview:box];
    return y + rowH * names.count;
}

- (void)reloadSubPanel
{
    if (!_subPanel || _subPanel.hidden) return;
    NSView *inner = _subPanelContent;
    for (NSView *v in [inner.subviews copy]) [v removeFromSuperview];

    CGFloat hostW = NSWidth(_window.contentView.bounds);
    CGFloat hostH = NSHeight(_window.contentView.bounds);
    CGFloat panelW = MIN(340.0, MAX(280.0, hostW - 24.0));
    CGFloat maxH = MAX(320.0, hostH - kBarHeight - 24.0);

    NSArray<NSDictionary *> *tracks = [self mpvTracks:"sub"];
    CGFloat rowH = 24.0;
    CGFloat rows = (CGFloat)tracks.count + 1.0;      // +1 是「关闭」
    CGFloat listH = 22.0 + rows * rowH;              // 小标题 + 各行
    CGFloat contentH = 14.0 + 30.0 + listH + 6.0 + listH + 12.0;
    CGFloat bottomH = 152.0;                         // 加载按钮 + 延迟 + 位置
    CGFloat panelH = MIN(contentH + bottomH, maxH);
    if (panelH < 320) panelH = 320;

    _subPanel.frame = NSMakeRect(hostW - panelW - 12, kBarHeight + 12, panelW, panelH);

    // 轨道列表可滚动：番剧 BD 经常有十几条字幕轨，硬排会顶出面板
    CGFloat scrollH = panelH - bottomH;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, panelW, scrollH)];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.scrollerStyle = NSScrollerStyleOverlay;
    sv.borderType = NSNoBorder;
    sv.verticalScrollElasticity = NSScrollElasticityAllowed;

    ANEFlippedView *doc = [[ANEFlippedView alloc]
        initWithFrame:NSMakeRect(0, 0, panelW, MAX(contentH, scrollH))];
    sv.documentView = doc;
    [inner addSubview:sv];

    CGFloat w = panelW - 6;
    CGFloat y = 14.0;
    NSTextField *title = [self panelLabel:@"字幕" size:13 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(16, y, w - 32, 20);
    [doc addSubview:title];
    y += 30;

    y = [self addTrackSectionTo:doc top:y width:w prop:"sid" title:@"主字幕"
                         tracks:tracks action:@selector(subTrackPicked:)];
    y += 6;
    y = [self addTrackSectionTo:doc top:y width:w prop:"secondary-sid" title:@"二级字幕"
                         tracks:tracks action:@selector(subTrackPicked:)];
    y += 12;
    doc.frame = NSMakeRect(0, 0, panelW, MAX(y, scrollH));

    // ── 底部固定操作区：加载 / 延迟 / 位置 ──
    CGFloat by = panelH - bottomH + 6;
    NSButton *load = [[NSButton alloc] initWithFrame:NSMakeRect(16, by, panelW - 32, 26)];
    load.title = @"加载字幕文件…";
    load.bezelStyle = NSBezelStyleRounded;
    load.font = [NSFont systemFontOfSize:12];
    load.target = self;
    load.action = @selector(openSubtitlePanel);
    [inner addSubview:load];

    double d = mpv_num(_mpv, "sub-delay");
    NSTextField *dCap = [self panelLabel:@"延迟" size:12 weight:NSFontWeightMedium];
    dCap.frame = NSMakeRect(16, by + 38, 120, 18);
    [inner addSubview:dCap];
    _subDelayLabel = [self panelLabel:[NSString stringWithFormat:@"%+.1f s", d]
                                 size:12 weight:NSFontWeightRegular];
    _subDelayLabel.alignment = NSTextAlignmentRight;
    _subDelayLabel.frame = NSMakeRect(panelW - 100, by + 38, 84, 18);
    [inner addSubview:_subDelayLabel];

    NSSlider *dSl = [[NSSlider alloc] initWithFrame:NSMakeRect(16, by + 58, panelW - 32, 20)];
    dSl.minValue = -5.0;
    dSl.maxValue = 5.0;
    dSl.doubleValue = d;
    dSl.continuous = YES;
    dSl.target = self;
    dSl.action = @selector(subDelayChanged:);
    [self neutralSlider:dSl];
    _subDelaySlider = dSl;
    [inner addSubview:dSl];

    // 位置：控制字幕的垂直高度（mpv 的 sub-pos，100 = 贴底，0 = 贴顶）
    double pos = mpv_num(_mpv, "sub-pos");
    if (!isfinite(pos) || pos <= 0) pos = 100.0;
    NSTextField *pCap = [self panelLabel:@"位置" size:12 weight:NSFontWeightMedium];
    pCap.frame = NSMakeRect(16, by + 90, 120, 18);
    [inner addSubview:pCap];
    _subPosLabel = [self panelLabel:[NSString stringWithFormat:@"%.0f%%", pos]
                               size:12 weight:NSFontWeightRegular];
    _subPosLabel.alignment = NSTextAlignmentRight;
    _subPosLabel.frame = NSMakeRect(panelW - 100, by + 90, 84, 18);
    [inner addSubview:_subPosLabel];

    NSSlider *pSl = [[NSSlider alloc] initWithFrame:NSMakeRect(16, by + 110, panelW - 32, 20)];
    pSl.minValue = 0.0;
    pSl.maxValue = 100.0;
    pSl.doubleValue = pos;
    pSl.continuous = YES;
    pSl.target = self;
    pSl.action = @selector(subPosChanged:);
    [self neutralSlider:pSl];
    [inner addSubview:pSl];
}

/// 位置滑块：sub-pos 是「字幕距画面顶部」的百分比，数字越小越高
- (void)subPosChanged:(NSSlider *)s
{
    double pos = round(s.doubleValue);
    mpv_set_property(_mpv, "sub-pos", MPV_FORMAT_DOUBLE, &pos);
    // 100% = 紧贴窗口下沿（留 8px，再小多行字幕会被裁）；其余档位恢复 mpv 的自动留白
    double margin = (pos >= 99.5) ? 8.0 : -1.0;
    mpv_set_property(_mpv, "sub-margin-y", MPV_FORMAT_DOUBLE, &margin);
    _subPosLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", pos];
}

- (void)subTrackPicked:(ANETrackButton *)b
{
    NSString *prop = b.payload[@"prop"];
    NSNumber *tid  = b.payload[@"id"];
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)tid.longLongValue);
    mpv_cmd(_mpv, (const char *[]){"set", prop.UTF8String, buf, NULL});
    [self rebuildTrackMenus];        // 里面会顺手刷新字幕面板的选中态
    if (_settingsPanel && !_settingsPanel.hidden) [self fillSettingsBody];
}

- (void)subDelayChanged:(NSSlider *)s
{
    double d = s.doubleValue;
    // 0.1s 一档，避免拖动时出现 0.30000000000000004 这种鬼值
    d = round(d * 10.0) / 10.0;
    mpv_set_property(_mpv, "sub-delay", MPV_FORMAT_DOUBLE, &d);
    _subDelayLabel.stringValue = [NSString stringWithFormat:@"%+.1f s", d];
}

// ── 播放列表面板 ────────────────────────────────────────────────────────────

/// 读 mpv 的 playlist 属性：每条只有 filename / current 有用
- (NSArray<NSDictionary *> *)mpvPlaylist
{
    if (!_mpv) return @[];
    mpv_node node;
    if (mpv_get_property(_mpv, "playlist", MPV_FORMAT_NODE, &node) < 0) return @[];
    NSMutableArray *out = [NSMutableArray array];
    if (node.format == MPV_FORMAT_NODE_ARRAY) {
        for (int i = 0; i < node.u.list->num; i++) {
            mpv_node *e = &node.u.list->values[i];
            if (e->format != MPV_FORMAT_NODE_MAP) continue;
            NSString *fn = nil;
            BOOL cur = NO;
            for (int j = 0; j < e->u.list->num; j++) {
                const char *k = e->u.list->keys[j];
                mpv_node *v = &e->u.list->values[j];
                if (!strcmp(k, "filename") && v->format == MPV_FORMAT_STRING) fn = @(v->u.string);
                else if (!strcmp(k, "current") && v->format == MPV_FORMAT_FLAG) cur = v->u.flag;
            }
            [out addObject:@{ @"name": fn.lastPathComponent ?: @"?", @"current": @(cur) }];
        }
    }
    mpv_free_node_contents(&node);
    return out;
}

- (void)togglePlaylistPanel
{
    if (!_playlistPanel) {
        NSView *inner = nil;
        _playlistPanel = [self makeSidePanelWithWidth:470 content:&inner];
        _playlistContent = inner;
        _playlistSig = nil;
    }
    BOOL show = _playlistPanel.hidden;
    [self hideSidePanelsExcept:_playlistPanel];
    _playlistPanel.hidden = !show;
    if (show) {
        [self reloadPlaylist];
        [self showControls];
    }
    [self updateSideButtons];
}

/// 列出某个文件夹里的视频文件（自然排序：[01] [02] … [10] 不会乱）
- (NSArray<NSString *> *)videosInFolder:(NSString *)dir
{
    if (!dir.length) return @[];
    NSSet *exts = [NSSet setWithArray:@[@"mp4", @"mkv", @"mov", @"m4v", @"avi",
                                        @"webm", @"flv", @"wmv", @"ts", @"m2ts",
                                        @"mpg", @"mpeg", @"rmvb", @"asf", @"ogv", @"3gp"]];
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in all) {
        if ([f hasPrefix:@"."]) continue;
        if ([exts containsObject:f.pathExtension.lowercaseString])
            [out addObject:[dir stringByAppendingPathComponent:f]];
    }
    [out sortUsingSelector:@selector(localizedStandardCompare:)];
    return out;
}

- (void)reloadPlaylist
{
    if (!_playlistPanel || _playlistPanel.hidden) return;
    NSView *inner = _playlistContent;
    for (NSView *v in [inner.subviews copy]) if (![v.identifier isEqualToString:@"aneScrim"]) [v removeFromSuperview];

    // 播放列表 = 当前视频所在文件夹里的视频（跟 IINA 的文件夹列表一个意思）
    NSString *curPath = mpv_str(_mpv, "path");
    NSString *dir = curPath.stringByDeletingLastPathComponent;
    NSArray<NSString *> *items = [self videosInFolder:dir];

    CGFloat hostW = NSWidth(_window.contentView.bounds);
    CGFloat hostH = NSHeight(_window.contentView.bounds);
    // 470 宽：BD 那种完整文件名（约 67 字符 / 60+ 全角偏旁）刚好一行放得下
    CGFloat panelW = MIN(470.0, MAX(280.0, hostW - 24.0));
    CGFloat maxH = MAX(280.0, hostH - kBarHeight - 24.0);
    CGFloat rowH = 26.0;

    CGFloat headH = 48.0;
    CGFloat listH = MAX(rowH, items.count * rowH);
    CGFloat panelH = MIN(maxH, headH + listH + 14.0);
    if (panelH < 150) panelH = 150;
    _playlistPanel.frame = NSMakeRect(hostW - panelW - 12, kBarHeight + 12, panelW, panelH);

    NSTextField *title = [self panelLabel:
        [NSString stringWithFormat:@"播放列表  %lu", (unsigned long)items.count]
                                    size:13 weight:NSFontWeightSemibold];
    title.textColor = NSColor.labelColor;
    title.frame = NSMakeRect(16, 12, panelW - 32, 18);
    [inner addSubview:title];

    NSTextField *folder = [self panelLabel:dir.lastPathComponent ?: dir
                                      size:10 weight:NSFontWeightRegular];
    folder.textColor = NSColor.secondaryLabelColor;
    folder.lineBreakMode = NSLineBreakByTruncatingMiddle;
    folder.frame = NSMakeRect(16, 30, panelW - 32, 14);
    [inner addSubview:folder];

    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(0, headH, panelW, panelH - headH - 10)];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.scrollerStyle = NSScrollerStyleOverlay;
    sv.borderType = NSNoBorder;
    sv.verticalScrollElasticity = NSScrollElasticityAllowed;

    CGFloat docH = MAX(listH, NSHeight(sv.frame));
    ANEFlippedView *doc = [[ANEFlippedView alloc]
        initWithFrame:NSMakeRect(0, 0, panelW, docH)];
    sv.documentView = doc;
    [inner addSubview:sv];

    if (!items.count) {
        NSTextField *empty = [self panelLabel:@"（这个文件夹里没有视频）"
                                         size:12 weight:NSFontWeightRegular];
        empty.frame = NSMakeRect(16, 4, panelW - 32, 18);
        [doc addSubview:empty];
        return;
    }

    for (NSUInteger i = 0; i < items.count; i++) {
        NSString *path = items[i];
        BOOL cur = [path isEqualToString:curPath];
        ANETrackButton *row =
        [self addListRowTo:doc index:i title:path.lastPathComponent
                   selected:cur payload:@{ @"path": path }
                     action:@selector(playlistRowPicked:) width:panelW rowH:rowH size:11];
        row.toolTip = path;
    }
}

- (void)playlistRowPicked:(ANETrackButton *)b
{
    NSString *path = b.payload[@"path"];
    if (!path.length || !_mpv) return;
    mpv_cmd(_mpv, (const char *[]){"loadfile", path.UTF8String, NULL});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.45 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        self.playlistSig = nil;
        [self reloadPlaylist];
    });
}

/// 把文件追加进播放列表（拖一堆文件进来时用）
- (void)appendFilesToPlaylist:(NSArray<NSString *> *)paths
{
    for (NSString *p in paths) {
        mpv_cmd(_mpv, (const char *[]){"loadfile", p.UTF8String, "append", NULL});
    }
    _playlistSig = nil;
    if (_playlistPanel && !_playlistPanel.hidden) [self reloadPlaylist];
}

// ── 设置面板（先占位，功能待定）─────────────────────────────────────────────

- (void)toggleSettingsPanel
{
    if (!_settingsPanel) {
        NSView *inner = nil;
        _settingsPanel = [self makeSidePanelWithWidth:300 content:&inner];
        _settingsContent = inner;
    }
    BOOL show = _settingsPanel.hidden;
    [self hideSidePanelsExcept:_settingsPanel];
    _settingsPanel.hidden = !show;
    if (show) {
        [self buildSettingsContent];
        [self showControls];
    }
    [self updateSideButtons];
}

- (void)settingsTabChanged:(ANESegmentedView *)seg
{
    _settingsTab = seg.selectedSegment;
    [[NSUserDefaults standardUserDefaults] setInteger:_settingsTab forKey:@"settingsTab"];
    [self fillSettingsBody];
    [self settingsScrollTop];   // 换页从头看，别继承上一页的滚动位置
}

- (void)buildSettingsContent
{
    NSView *inner = _settingsContent;
    for (NSView *v in [inner.subviews copy]) if (![v.identifier isEqualToString:@"aneScrim"]) [v removeFromSuperview];

    CGFloat hostW = NSWidth(_window.contentView.bounds);
    CGFloat hostH = NSHeight(_window.contentView.bounds);
    CGFloat panelW = MIN(360.0, MAX(280.0, hostW - 24.0));
    CGFloat panelH = MIN(MAX(320.0, hostH - kBarHeight - 24.0), 430.0);
    _settingsPanel.frame = NSMakeRect(hostW - panelW - 12, kBarHeight + 12, panelW, panelH);

    NSTextField *title = [self panelLabel:@"设置" size:13 weight:NSFontWeightSemibold];
    title.textColor = NSColor.labelColor;
    title.frame = NSMakeRect(16, 12, panelW - 32, 20);
    [inner addSubview:title];

    // 用自绘分段控件：系统 NSSegmentedControl 的选中块是系统蓝，播放器里不要那个颜色
    if (_settingsTab < 0 || _settingsTab > 3) _settingsTab = 0;
    ANESegmentedView *seg = [[ANESegmentedView alloc]
        initWithFrame:NSMakeRect(16, 38, panelW - 32, 24)];
    seg.fontSize = 11;
    seg.target = self;
    seg.action = @selector(settingsTabChanged:);
    [seg setupItems:@[@"音频", @"视频", @"弹幕", @"其他"] selected:_settingsTab];
    [inner addSubview:seg];

    // 内容区可滚动：弹幕那一页参数多，窗口不够高时得能翻
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 68, panelW, panelH - 76)];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;                       // 平时不画，滚动时才浮出来
    sv.scrollerStyle = NSScrollerStyleOverlay;         // 悬浮式，不占内容宽度
    sv.borderType = NSNoBorder;
    sv.verticalScrollElasticity = NSScrollElasticityAllowed;

    ANEFlippedView *body = [[ANEFlippedView alloc]
        initWithFrame:NSMakeRect(0, 0, panelW, MAX(120.0, panelH - 76))];
    body.identifier = @"aneBody";
    sv.documentView = body;
    [inner addSubview:sv];
    _settingsScroll = sv;
    _settingsBody = body;

    [self fillSettingsBody];
}

/// 按当前 tab 重排内容，并把面板高度收到内容高度
- (void)fillSettingsBody
{
    NSView *body = _settingsBody;
    if (!body || !_settingsPanel || _settingsPanel.hidden) return;
    for (NSView *v in [body.subviews copy]) [v removeFromSuperview];

    CGFloat w = NSWidth(body.bounds);
    CGFloat y = 0;
    if (_settingsTab == 1)      y = [self fillVideoTab:body width:w];
    else if (_settingsTab == 2) y = [self fillDanmakuTab:body width:w];
    else if (_settingsTab == 3) y = [self fillOtherTab:body width:w];
    else                        y = [self fillAudioTab:body width:w];
    y += 10;

    CGFloat hostH = NSHeight(_window.contentView.bounds);
    CGFloat maxH = MAX(320.0, hostH - kBarHeight - 24.0);
    CGFloat panelH = MIN(maxH, 76.0 + y + 12.0);
    NSRect f = _settingsPanel.frame;
    _settingsPanel.frame = NSMakeRect(NSMinX(f), kBarHeight + 12, NSWidth(f), panelH);
    body.frame = NSMakeRect(0, 0, NSWidth(f), MAX(y, panelH - 76));
    if (_settingsScroll) {
        _settingsScroll.frame = NSMakeRect(0, 68, NSWidth(f), panelH - 76);
    }
}

- (NSButton *)wideButton:(NSString *)title action:(SEL)sel
{
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.title = title;
    b.bezelStyle = NSBezelStyleRounded;
    b.font = [NSFont systemFontOfSize:12];
    b.target = self;
    b.action = sel;
    return b;
}

/// 一行「标题 + 一排分段按钮」，返回下一个 y
- (CGFloat)addSegmentedRowTo:(NSView *)host top:(CGFloat)y width:(CGFloat)w
                       title:(NSString *)title items:(NSArray<NSString *> *)items
                    selected:(NSInteger)sel action:(SEL)action
{
    NSTextField *cap = [self panelLabel:title size:11 weight:NSFontWeightSemibold];
    cap.frame = NSMakeRect(16, y, w - 32, 15);
    [host addSubview:cap];
    y += 17;

    ANESegmentedView *seg = [[ANESegmentedView alloc]
        initWithFrame:NSMakeRect(16, y, w - 32, 20)];
    seg.target = self;
    seg.action = action;
    [seg setupItems:items selected:sel];
    [host addSubview:seg];
    return y + 22;
}

// ── 音频 tab ────────────────────────────────────────────────────────────────

- (CGFloat)fillAudioTab:(NSView *)body width:(CGFloat)w
{
    CGFloat y = 0;
    y = [self addTrackSectionTo:body top:y width:w prop:"aid" title:@"音频轨"
                         tracks:[self mpvTracks:"audio"]
                         action:@selector(subTrackPicked:)];
    y += 6;

    NSButton *load = [self wideButton:@"加载外置音频…" action:@selector(openAudioPanel)];
    load.frame = NSMakeRect(16, y, w - 32, 26);
    [body addSubview:load];
    y += 26 + 12;

    double d = mpv_num(_mpv, "audio-delay");
    NSTextField *cap = [self panelLabel:@"延迟" size:11 weight:NSFontWeightSemibold];
    cap.frame = NSMakeRect(16, y, 100, 16);
    [body addSubview:cap];
    _audioDelayLabel = [self panelLabel:[NSString stringWithFormat:@"%+.1f s", d]
                                   size:12 weight:NSFontWeightRegular];
    _audioDelayLabel.alignment = NSTextAlignmentRight;
    _audioDelayLabel.frame = NSMakeRect(w - 106, y, 90, 16);
    [body addSubview:_audioDelayLabel];
    y += 20;

    NSSlider *sl = [[NSSlider alloc] initWithFrame:NSMakeRect(16, y, w - 32, 20)];
    sl.minValue = -5.0;
    sl.maxValue = 5.0;
    sl.doubleValue = d;
    sl.continuous = YES;
    sl.target = self;
    sl.action = @selector(audioDelayChanged:);
    [self neutralSlider:sl];
    [body addSubview:sl];
    return y + 26;
}

- (void)audioDelayChanged:(NSSlider *)s
{
    double d = round(s.doubleValue * 10.0) / 10.0;
    mpv_set_property(_mpv, "audio-delay", MPV_FORMAT_DOUBLE, &d);
    _audioDelayLabel.stringValue = [NSString stringWithFormat:@"%+.1f s", d];
}

- (void)openAudioPanel
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = NO;
    p.allowsMultipleSelection = NO;
    p.message = @"选择音频文件（外挂音轨）";
    if ([p runModal] == NSModalResponseOK && p.URL) {
        mpv_cmd(_mpv, (const char *[]){"audio-add", p.URL.path.UTF8String, "select", NULL});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [self fillSettingsBody];
        });
    }
}

// ── 视频 tab ────────────────────────────────────────────────────────────────

- (CGFloat)fillVideoTab:(NSView *)body width:(CGFloat)w
{
    // 长宽比
    NSArray *aspectNames = @[@"默认", @"4:3", @"16:9", @"16:10", @"21:9", @"5:4"];
    NSArray *aspectVals  = @[@"-1", @"4:3", @"16:9", @"16:10", @"21:9", @"5:4"];
    NSString *curAspect = mpv_str(_mpv, "video-aspect-override") ?: @"-1";
    NSInteger aSel = 0;
    for (NSUInteger i = 0; i < aspectVals.count; i++)
        if ([aspectVals[i] isEqualToString:curAspect]) aSel = (NSInteger)i;

    CGFloat y = 0;
    y = [self addSegmentedRowTo:body top:y width:w title:@"长宽比" items:aspectNames
                       selected:aSel action:@selector(videoAspectChanged:)];
    y += 4;

    // 旋转
    int rot = (int)mpv_num(_mpv, "video-rotate");
    NSInteger rSel = (rot == 90) ? 1 : (rot == 180) ? 2 : (rot == 270) ? 3 : 0;
    y = [self addSegmentedRowTo:body top:y width:w title:@"旋转"
                          items:@[@"0°", @"90°", @"180°", @"270°"]
                       selected:rSel action:@selector(videoRotateChanged:)];
    y += 10;

    // 速度（0.25x ~ 16x，对数刻度：1x 在 1/3 处、4x 在 2/3 处，跟 IINA 一样）
    NSTextField *cap = [self panelLabel:@"速度" size:11 weight:NSFontWeightSemibold];
    cap.frame = NSMakeRect(16, y, 100, 16);
    [body addSubview:cap];
    double sp = mpv_num(_mpv, "speed");
    if (sp <= 0) sp = 1.0;
    _speedLabel = [self panelLabel:[NSString stringWithFormat:@"%.2gx", sp]
                              size:12 weight:NSFontWeightRegular];
    _speedLabel.alignment = NSTextAlignmentRight;
    _speedLabel.frame = NSMakeRect(w - 106, y, 90, 16);
    [body addSubview:_speedLabel];
    y += 20;

    double t = log(sp / 0.25) / log(4.0) / 3.0;
    if (t < 0) t = 0; if (t > 1) t = 1;
    NSSlider *sl = [[NSSlider alloc] initWithFrame:NSMakeRect(16, y, w - 32, 20)];
    sl.minValue = 0.0;
    sl.maxValue = 1.0;
    sl.doubleValue = t;
    sl.continuous = YES;
    sl.target = self;
    sl.action = @selector(speedSlideChanged:);
    [self neutralSlider:sl];
    [body addSubview:sl];
    y += 26;

    // 长按空格的加速倍率
    y = [self addSegmentedRowTo:body top:y width:w title:@"长按空格倍速"
                          items:@[@"1.5x", @"2x"]
                       selected:(_holdBoost >= 1.75) ? 1 : 0
                         action:@selector(holdBoostChanged:)];
    return y + 4;
}

- (void)videoAspectChanged:(ANESegmentedView *)seg
{
    NSArray<NSString *> *vals = @[@"-1", @"4:3", @"16:9", @"16:10", @"21:9", @"5:4"];
    NSInteger i = seg.selectedSegment;
    if (i < 0 || i >= (NSInteger)vals.count) return;
    mpv_set_property_string(_mpv, "video-aspect-override", vals[i].UTF8String);
    // 改完比例，窗口也跟着重新适配
    _didFitWindow = NO;
}

- (void)videoRotateChanged:(ANESegmentedView *)seg
{
    int deg = (int)seg.selectedSegment * 90;
    mpv_set_property(_mpv, "video-rotate", MPV_FORMAT_INT64, &(int64_t){deg});
    _didFitWindow = NO;
}

- (void)holdBoostChanged:(ANESegmentedView *)seg
{
    _holdBoost = (seg.selectedSegment == 1) ? 2.0 : 1.5;
    [[NSUserDefaults standardUserDefaults] setDouble:_holdBoost forKey:@"holdBoost"];
    NSLog(@"[ANEPlayer] 长按空格倍速 → %.1fx", _holdBoost);
}

- (void)speedSlideChanged:(NSSlider *)s
{
    double sp = 0.25 * pow(4.0, 3.0 * s.doubleValue);
    if (fabs(sp - 1.0) < 0.06) sp = 1.0;          // 手感：中间吸附到 1x
    sp = round(sp * 100.0) / 100.0;
    mpv_set_property(_mpv, "speed", MPV_FORMAT_DOUBLE, &sp);
    _speedLabel.stringValue = [NSString stringWithFormat:@"%.2gx", sp];
}

// ── 弹幕 tab ────────────────────────────────────────────────────────────────

/// 滑块行：标题 + 右侧数值 + 下面一条滑块，返回下一个 y
- (CGFloat)addSliderRowTo:(NSView *)host top:(CGFloat)y width:(CGFloat)w
                    title:(NSString *)title min:(double)mn max:(double)mx
                    value:(double)val tag:(NSInteger)tag action:(SEL)action
{
    // 单行布局：标题 74pt · 滑块占剩余 · 数值右对齐 —— 比「标题一行 + 滑块一行」省一半高度
    CGFloat labelW = 74.0, valueW = 54.0;
    CGFloat sliderX = 16 + labelW + 4;
    CGFloat sliderW = MAX(60.0, (w - 16 - valueW - 6) - sliderX);

    NSTextField *cap = [self panelLabel:title size:11 weight:NSFontWeightSemibold];
    cap.frame = NSMakeRect(16, y + 3, labelW, 15);
    [host addSubview:cap];

    NSSlider *sl = [[NSSlider alloc] initWithFrame:NSMakeRect(sliderX, y, sliderW, 20)];
    sl.minValue = mn;
    sl.maxValue = mx;
    sl.doubleValue = val;
    sl.tag = tag;
    sl.continuous = YES;
    sl.target = self;
    sl.action = action;
    [self neutralSlider:sl];
    [host addSubview:sl];

    NSTextField *valueLabel = [self panelLabel:@"" size:11 weight:NSFontWeightRegular];
    valueLabel.alignment = NSTextAlignmentRight;
    valueLabel.tag = tag + 500;
    valueLabel.textColor = NSColor.secondaryLabelColor;
    valueLabel.frame = NSMakeRect(w - 16 - valueW, y + 3, valueW, 15);
    [host addSubview:valueLabel];
    valueLabel.stringValue = [self dmTextForTag:tag value:val];

    return y + 25;
}

- (NSString *)dmTextForTag:(NSInteger)tag value:(double)v
{
    switch (tag) {
        case 1001: return [NSString stringWithFormat:@"%.0f%%", v * 100];   // 不透明度
        case 1002: return [NSString stringWithFormat:@"%.2fx", v];          // 字号
        case 1003: return [NSString stringWithFormat:@"%.2fx", v];          // 滚动速度
        case 1004: return [NSString stringWithFormat:@"%.1f", v];           // 描边宽度
        case 1005: return [NSString stringWithFormat:@"%.0f%%", v * 100];   // 描边不透明度
        case 1006: return (v < 1) ? @"不限" : [NSString stringWithFormat:@"%.0f 条", v];
        case 1007: return [NSString stringWithFormat:@"%+.1f s", v];        // 时间偏移
        case 1008: return (v < 0.5) ? @"贴画面" : [NSString stringWithFormat:@"%.0f%%", v];
    }
    return @"";
}

/// 弹幕面板重排后把内容区滚回顶部 —— 搜索结果一刷新就有几十张卡片，
/// 不回到顶部会停在半截处，让人以为列表只有下半段。
- (void)settingsScrollTop
{
    if (!_settingsScroll) return;
    [_settingsScroll.contentView scrollToPoint:NSZeroPoint];
    [_settingsScroll reflectScrolledClipView:_settingsScroll.contentView];
}

// ── 弹幕二级页：基础 / 高级 / 过滤 ───────────────────────────────────────────

/// 二级页签条：整行铺满、不带左侧标题（这是切页，不是一项设置）
- (CGFloat)addSubTabRowTo:(NSView *)host top:(CGFloat)y width:(CGFloat)w
                    items:(NSArray<NSString *> *)items
                 selected:(NSInteger)sel action:(SEL)action
{
    ANESegmentedView *seg = [[ANESegmentedView alloc] initWithFrame:NSMakeRect(16, y, w - 32, 24)];
    seg.target = self;
    seg.action = action;
    [seg setupItems:items selected:sel];
    [host addSubview:seg];
    return y + 32;
}

- (void)dmSubTabChanged:(ANESegmentedView *)seg
{
    _dmSubTab = seg.selectedSegment;
    [[NSUserDefaults standardUserDefaults] setInteger:_dmSubTab forKey:@"danmakuSubTab"];
    [self fillSettingsBody];
    [self settingsScrollTop];       // 换页从头看
}

- (CGFloat)fillDanmakuTab:(NSView *)body width:(CGFloat)w
{
    CGFloat y = [self addSubTabRowTo:body top:0 width:w
                               items:@[@"基础", @"高级", @"过滤"]
                            selected:_dmSubTab action:@selector(dmSubTabChanged:)];

    CGFloat h;
    if (_dmSubTab == 1)      h = [self fillDanmakuAdvancedTab:body top:y width:w];
    else if (_dmSubTab == 2) h = [self fillDanmakuFilterTab:body top:y width:w];
    else                     h = [self fillDanmakuBasicTab:body top:y width:w];

    // 跟别的 tab 一样：按内容高度收，不硬撑到同一高度，
    // 否则页面短的时候底下会空出一大块；末尾留 14pt 免得最后一行贴着玻璃边
    return h + 14.0;
}

/// 基础：开关 / 匹配状态 / 手动搜索 / 最常调的几项
- (CGFloat)fillDanmakuBasicTab:(NSView *)body top:(CGFloat)y width:(CGFloat)w
{
    // 开关
    y = [self addSegmentedRowTo:body top:y width:w title:@"弹幕"
                                  items:@[@"关", @"开"]
                               selected:([_dmPrefs[@"danmakuEnabled"] boolValue] ? 1 : 0)
                                 action:@selector(dmEnabledChanged:)];

    // 状态（匹配结果 / 条数）
    _dmStatusLabel = [self panelLabel:(_dmStatusText.length ? _dmStatusText : @"正在匹配弹幕…")
                                 size:10 weight:NSFontWeightRegular];
    _dmStatusLabel.textColor = NSColor.secondaryLabelColor;
    _dmStatusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _dmStatusLabel.frame = NSMakeRect(16, y, w - 32, 14);
    [body addSubview:_dmStatusLabel];
    y += 20;

    // ── 手动搜索（匹配不到/匹配错时可以自己找）──
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(16, y, w - 32 - 66, 22)];
    field.placeholderString = @"动画标题…";
    field.font = [NSFont systemFontOfSize:11];
    field.bezeled = YES;
    field.target = self;
    field.action = @selector(dmDoSearch);
    if (_dmSearchKeyword.length) field.stringValue = _dmSearchKeyword;
    [body addSubview:field];
    _dmSearchField = field;

    NSButton *searchBtn = [[NSButton alloc] initWithFrame:NSMakeRect(w - 16 - 60, y, 60, 22)];
    searchBtn.title = @"搜索";
    searchBtn.bezelStyle = NSBezelStyleRounded;
    searchBtn.font = [NSFont systemFontOfSize:11];
    searchBtn.target = self;
    searchBtn.action = @selector(dmDoSearch);
    [body addSubview:searchBtn];
    y += 30;

    if (_dmSearchBusy) {
        NSTextField *busy = [self panelLabel:@"搜索中…" size:10 weight:NSFontWeightRegular];
        busy.textColor = NSColor.secondaryLabelColor;
        busy.frame = NSMakeRect(16, y, w - 32, 14);
        [body addSubview:busy];
        y += 18;
    }

    if (_dmSearchMode == 2 && _dmSearchAnimeTitle.length) {
        NSButton *back = [[NSButton alloc] initWithFrame:NSMakeRect(16, y, 54, 18)];
        back.title = @"‹ 返回";
        back.bezelStyle = NSBezelStyleInline;
        back.font = [NSFont systemFontOfSize:11];
        back.target = self;
        back.action = @selector(dmSearchBack);
        [body addSubview:back];

        NSTextField *name = [self panelLabel:_dmSearchAnimeTitle size:10 weight:NSFontWeightRegular];
        name.textColor = NSColor.secondaryLabelColor;
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        name.frame = NSMakeRect(74, y + 1, w - 74 - 16, 14);
        [body addSubview:name];
        y += 22;
    }

    if (_dmSearchResults.count) {
        // 卡片式列表：每项一层圆角半透明底，项间留 5pt 缝
        CGFloat cardH = 42.0, gap = 5.0;
        NSInteger total = (NSInteger)_dmSearchResults.count;
        NSInteger n = (NSInteger)MIN((NSUInteger)total, (NSUInteger)60);

        NSString *headText = (_dmSearchMode == 2)
            ? [NSString stringWithFormat:@"剧集 (%ld)", (long)total]
            : [NSString stringWithFormat:@"搜索结果 (%ld)", (long)total];
        if (n < total) headText = [headText stringByAppendingFormat:@" · 只列前 %ld 项", (long)n];

        NSTextField *head = [self panelLabel:headText size:10 weight:NSFontWeightMedium];
        head.textColor = NSColor.secondaryLabelColor;
        head.lineBreakMode = NSLineBreakByTruncatingTail;
        head.frame = NSMakeRect(16, y, w - 32, 14);
        [body addSubview:head];
        y += 20;

        ANEFlippedView *box = [[ANEFlippedView alloc]
            initWithFrame:NSMakeRect(0, y, w, (cardH + gap) * n)];
        for (NSInteger i = 0; i < n; i++) {
            NSDictionary *it = _dmSearchResults[i];
            NSString *ttl = it[@"title"] ?: @"";
            NSString *sub = it[@"sub"] ?: @"";
            NSString *hint;
            if (_dmSearchMode == 2) {
                hint = @"点按加载此集弹幕";
            } else {
                hint = sub.length
                    ? [NSString stringWithFormat:@"%@ · 点按加载集数", sub]
                    : @"点按加载集数";
            }

            ANECardRow *row = [[ANECardRow alloc]
                initWithFrame:NSMakeRect(16, i * (cardH + gap), w - 32, cardH)];
            row.bordered = NO;
            row.mainText = ttl;
            row.subText = hint;
            row.payload = @{ @"id": it[@"id"] ?: @0, @"title": ttl };
            row.target = self;
            row.action = (_dmSearchMode == 2 ? @selector(dmEpisodePicked:)
                                             : @selector(dmAnimePicked:));
            [box addSubview:row];
        }
        [body addSubview:box];
        y += (cardH + gap) * n + 8;
    }

    // 常用外观
    y = [self addSliderRowTo:body top:y width:w title:@"不透明度" min:0.1 max:1.0
                       value:[_dmPrefs[@"danmakuCanvasOpacity"] doubleValue]
                         tag:1001 action:@selector(dmSliderChanged:)];
    y = [self addSliderRowTo:body top:y width:w title:@"字号" min:0.2 max:2.0
                       value:[_dmPrefs[@"niconicommentsFontScale"] doubleValue]
                         tag:1002 action:@selector(dmSliderChanged:)];
    y = [self addSliderRowTo:body top:y width:w title:@"滚动速度" min:0.2 max:2.0
                       value:[_dmPrefs[@"scrollSpeed"] doubleValue]
                         tag:1003 action:@selector(dmSliderChanged:)];
    y = [self addSliderRowTo:body top:y width:w title:@"描边宽度" min:0.0 max:8.0
                       value:[_dmPrefs[@"strokeWidth"] doubleValue]
                         tag:1004 action:@selector(dmSliderChanged:)];
    y = [self addSliderRowTo:body top:y width:w title:@"描边不透明度" min:0.0 max:1.0
                       value:[_dmPrefs[@"strokeOpacity"] doubleValue]
                         tag:1005 action:@selector(dmSliderChanged:)];

    return y;
}

/// 高级：位置 / 显示区域 / 时间轴 / 描边 / 渲染方式
- (CGFloat)fillDanmakuAdvancedTab:(NSView *)body top:(CGFloat)y width:(CGFloat)w
{
    y = [self addSliderRowTo:body top:y width:w title:@"弹幕位置" min:0 max:100
                       value:[_dmPrefs[@"danmakuTopPercent"] doubleValue]
                         tag:1008 action:@selector(dmSliderChanged:)];

    y = [self addSliderRowTo:body top:y width:w title:@"显示上限" min:0 max:1000
                       value:[_dmPrefs[@"commentLimit"] doubleValue]
                         tag:1006 action:@selector(dmSliderChanged:)];
    y = [self addSliderRowTo:body top:y width:w title:@"时间偏移" min:-10.0 max:10.0
                       value:[_dmPrefs[@"danmakuTimeOffset"] doubleValue]
                         tag:1007 action:@selector(dmSliderChanged:)];

    NSInteger areaIdx = 3;
    NSInteger areaVal = [_dmPrefs[@"danmakuDisplayArea"] integerValue];
    if (areaVal <= 25) areaIdx = 0;
    else if (areaVal <= 50) areaIdx = 1;
    else if (areaVal <= 75) areaIdx = 2;
    y = [self addSegmentedRowTo:body top:y width:w title:@"显示区域"
                          items:@[@"25%", @"50%", @"75%", @"全部"]
                       selected:areaIdx action:@selector(dmDisplayAreaChanged:)];

    NSInteger mode = [_dmPrefs[@"canvasMode"] isEqualToString:@"canvas"] ? 1 : 0;
    y = [self addSegmentedRowTo:body top:y width:w title:@"渲染模式"
                          items:@[@"CSS", @"Canvas"]
                       selected:mode action:@selector(dmCanvasModeChanged:)];

    y = [self addSegmentedRowTo:body top:y width:w title:@"繁简转换"
                          items:@[@"不转换", @"繁体", @"简体"]
                       selected:[_dmPrefs[@"dandanplayChConvert"] integerValue]
                         action:@selector(dmChConvertChanged:)];

    // 匹配相关（不常改，放高级里）
    y = [self addSegmentedRowTo:body top:y width:w title:@"关联剧集弹幕"
                          items:@[@"关", @"开"]
                       selected:([_dmPrefs[@"dandanplayWithRelated"] boolValue] ? 1 : 0)
                         action:@selector(dmRelatedChanged:)];
    y = [self addSegmentedRowTo:body top:y width:w title:@"自动联网匹配"
                          items:@[@"关", @"开"]
                       selected:([_dmPrefs[@"dandanplayAutoNetwork"] boolValue] ? 1 : 0)
                         action:@selector(dmAutoNetworkChanged:)];

    return y;
}

/// 过滤：屏蔽词 / 纯重复 / 去重
- (CGFloat)fillDanmakuFilterTab:(NSView *)body top:(CGFloat)y width:(CGFloat)w
{
    BOOL blockOn = [_dmPrefs[@"danmakuBlockEnabled"] boolValue];

    y = [self addSegmentedRowTo:body top:y width:w title:@"屏蔽词"
                          items:@[@"关", @"开"]
                       selected:(blockOn ? 1 : 0)
                         action:@selector(dmBlockEnabledChanged:)];
    if (blockOn) {
        NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(16, y, w - 32, 24)];
        tf.font = [NSFont systemFontOfSize:11];
        tf.placeholderString = @"多个词用空格或逗号分隔";
        tf.stringValue = _dmPrefs[@"danmakuBlockWords"] ?: @"";
        tf.tag = 9101;
        tf.delegate = self;
        tf.bezelStyle = NSTextFieldRoundedBezel;
        tf.focusRingType = NSFocusRingTypeExterior;
        [body addSubview:tf];
        y += 30;

        BOOL exact = [_dmPrefs[@"danmakuBlockExact"] boolValue];
        y = [self addSegmentedRowTo:body top:y width:w title:@"匹配方式"
                              items:@[@"包含", @"整条"]
                           selected:(exact ? 1 : 0)
                             action:@selector(dmBlockExactChanged:)];
        NSTextField *hint = [self panelLabel:(exact
                    ? @"整条：只有整条弹幕全是这个词才拦（啊 / 哈哈），不会误伤"
                    : @"包含：句子里出现这个词就拦，最狠，但会误伤正常句子")
                                       size:9 weight:NSFontWeightRegular];
        hint.textColor = NSColor.tertiaryLabelColor;
        hint.lineBreakMode = NSLineBreakByTruncatingTail;
        hint.frame = NSMakeRect(16, y, w - 32, 13);
        [body addSubview:hint];
        y += 18;
    }

    y = [self addSegmentedRowTo:body top:y width:w title:@"纯重复弹幕"
                          items:@[@"关", @"开"]
                       selected:([_dmPrefs[@"danmakuFilterRepeat"] boolValue] ? 1 : 0)
                         action:@selector(dmRepeatFilterChanged:)];
    NSTextField *rh = [self panelLabel:@"整条只有同一个字反复（啊啊啊 / 哈哈哈 / www）才拦"
                                  size:9 weight:NSFontWeightRegular];
    rh.textColor = NSColor.tertiaryLabelColor;
    rh.lineBreakMode = NSLineBreakByTruncatingTail;
    rh.frame = NSMakeRect(16, y, w - 32, 13);
    [body addSubview:rh];
    y += 20;

    y = [self addSegmentedRowTo:body top:y width:w title:@"弹幕去重"
                          items:@[@"关", @"开"]
                       selected:([_dmPrefs[@"danmakuDedupe"] boolValue] ? 1 : 0)
                         action:@selector(dmDedupeChanged:)];
    NSTextField *dh = [self panelLabel:@"同样的弹幕 3 秒内只保留一条"
                                  size:9 weight:NSFontWeightRegular];
    dh.textColor = NSColor.tertiaryLabelColor;
    dh.lineBreakMode = NSLineBreakByTruncatingTail;
    dh.frame = NSMakeRect(16, y, w - 32, 13);
    [body addSubview:dh];
    y += 24;

    return y;
}


// ── 手动搜索 ────────────────────────────────────────────────────────────────

- (void)dmDoSearch
{
    NSString *kw = _dmSearchField.stringValue ?: @"";
    kw = [kw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!kw.length) return;

    _dmSearchKeyword = kw;
    _dmSearchBusy = YES;
    _dmSearchMode = 1;
    _dmSearchAnimeTitle = nil;
    _dmSearchResults = @[];
    [self fillSettingsBody];
    [self settingsScrollTop];

    __weak typeof(self) wself = self;
    [_danmaku searchAnime:kw completion:^(NSArray<NSDictionary *> *items) {
        AppDelegate *s = wself;
        if (!s) return;
        s.dmSearchBusy = NO;
        s.dmSearchMode = 1;
        s.dmAnimeResults = items;
        s.dmSearchResults = items;
        if (!items.count) s.dmStatusText = [NSString stringWithFormat:@"没搜到「%@」", kw];
        [s fillSettingsBody];
        [s settingsScrollTop];
    }];
}

- (void)dmAnimePicked:(ANETrackButton *)b
{
    NSNumber *aid = b.payload[@"id"];
    NSString *name = b.payload[@"title"] ?: @"";
    if (!aid) return;

    _dmSearchBusy = YES;
    _dmSearchAnimeTitle = name;
    _dmSearchResults = @[];
    [self fillSettingsBody];
    [self settingsScrollTop];

    __weak typeof(self) wself = self;
    [_danmaku fetchEpisodes:aid completion:^(NSArray<NSDictionary *> *items) {
        AppDelegate *s = wself;
        if (!s) return;
        s.dmSearchBusy = NO;
        s.dmSearchMode = 2;
        s.dmSearchResults = items;
        if (!items.count) s.dmStatusText = [NSString stringWithFormat:@"「%@」没有剧集", name];
        [s fillSettingsBody];
        [s settingsScrollTop];
    }];
}

- (void)dmEpisodePicked:(ANETrackButton *)b
{
    NSNumber *eid = b.payload[@"id"];
    NSString *title = b.payload[@"title"] ?: @"";
    if (!eid) return;

    _dmStatusText = [NSString stringWithFormat:@"正在取「%@」的弹幕…", title];
    if (_dmStatusLabel) _dmStatusLabel.stringValue = _dmStatusText;
    NSLog(@"[Danmaku] 手动选择：%@", title);
    [_danmaku loadEpisode:eid title:title];

    // 选完就收起列表，回到正常状态
    _dmSearchMode = 0;
    _dmSearchResults = @[];
    _dmSearchAnimeTitle = nil;
    [self fillSettingsBody];
}

- (void)dmSearchBack
{
    _dmSearchMode = 1;
    _dmSearchAnimeTitle = nil;
    _dmSearchResults = _dmAnimeResults ?: @[];
    [self fillSettingsBody];
    [self settingsScrollTop];
}

- (void)dmEnabledChanged:(ANESegmentedView *)seg
{
    BOOL on = (seg.selectedSegment == 1);
    BOOL wasOn = [_dmPrefs[@"danmakuEnabled"] boolValue];
    [self setDmPref:@"danmakuEnabled" value:@(on)];

    if (on) {
        // 点「开」既当开启、也当重新加载——省掉一个独立的刷新按钮
        NSString *p = mpv_str(_mpv, "path");
        if (p.length) {
            _dmStatusText = wasOn ? @"正在重新加载弹幕…" : @"正在匹配弹幕…";
            if (_dmStatusLabel) _dmStatusLabel.stringValue = _dmStatusText;
            [_danmaku reloadForVideo:p duration:mpv_num(_mpv, "duration") purgeCache:NO];
        }
    } else {
        [_danmaku clear];
    }
    [self fillSettingsBody];
}

- (void)dmSliderChanged:(NSSlider *)sl
{
    double v = sl.doubleValue;
    NSString *key = nil;
    switch (sl.tag) {
        case 1001: key = @"danmakuCanvasOpacity"; break;
        case 1002: key = @"niconicommentsFontScale"; break;
        case 1003: key = @"scrollSpeed"; break;
        case 1004: key = @"strokeWidth"; v = round(v * 10) / 10.0; break;
        case 1005: key = @"strokeOpacity"; break;
        case 1006: key = @"commentLimit"; if (v < 1) v = 0; else v = round(v); break;
        case 1007: key = @"danmakuTimeOffset"; v = round(v * 10) / 10.0; break;
        case 1008: key = @"danmakuTopPercent"; break;
    }
    if (!key) return;

    NSTextField *lb = (NSTextField *)[sl.superview viewWithTag:sl.tag + 500];
    if ([lb isKindOfClass:NSTextField.class]) lb.stringValue = [self dmTextForTag:sl.tag value:v];
    [self setDmPref:key value:@(v)];
    if (sl.tag == 1008) [self updateDanmakuFrame];   // 位置只动弹幕层，不用重载弹幕
}

- (void)dmBlockEnabledChanged:(ANESegmentedView *)seg
{
    [self setDmPref:@"danmakuBlockEnabled" value:@(seg.selectedSegment == 1)];
    [self fillSettingsBody];        // 打开时多出一个词表输入框
}

- (void)dmBlockExactChanged:(ANESegmentedView *)seg
{
    [self setDmPref:@"danmakuBlockExact" value:@(seg.selectedSegment == 1)];
    [self fillSettingsBody];
}

- (void)dmRepeatFilterChanged:(ANESegmentedView *)seg
{
    [self setDmPref:@"danmakuFilterRepeat" value:@(seg.selectedSegment == 1)];
}

- (void)dmDedupeChanged:(ANESegmentedView *)seg
{
    [self setDmPref:@"danmakuDedupe" value:@(seg.selectedSegment == 1)];
}

/// 词表输入框：结束编辑（回车或点到别处）才保存，避免每敲一个字重建一次渲染器
- (void)controlTextDidEndEditing:(NSNotification *)note
{
    NSTextField *tf = note.object;
    if (![tf isKindOfClass:NSTextField.class] || tf.tag != 9101) return;
    [self setDmPref:@"danmakuBlockWords" value:(tf.stringValue ?: @"")];
}

- (void)dmDisplayAreaChanged:(ANESegmentedView *)seg
{
    static const NSInteger vals[4] = {25, 50, 75, 100};
    NSInteger idx = seg.selectedSegment;
    if (idx < 0 || idx > 3) idx = 3;
    [self setDmPref:@"danmakuDisplayArea" value:@(vals[idx])];
    [self updateDanmakuFrame];      // 层高跟着变，渲染层会按新宽高比重建
}

- (void)dmCanvasModeChanged:(ANESegmentedView *)seg
{
    [self setDmPref:@"canvasMode" value:(seg.selectedSegment == 1 ? @"canvas" : @"css")];
}

- (void)dmChConvertChanged:(ANESegmentedView *)seg
{
    // 繁简是服务端转换的，改了得重新拉一遍（并清掉旧缓存）
    [self setDmPref:@"dandanplayChConvert" value:@(seg.selectedSegment)];
    NSString *p = mpv_str(_mpv, "path");
    if (p.length) {
        [_danmaku reloadForVideo:p duration:mpv_num(_mpv, "duration") purgeCache:YES];
    }
    [self fillSettingsBody];
}

- (void)dmRelatedChanged:(ANESegmentedView *)seg
{
    [self setDmPref:@"dandanplayWithRelated" value:@(seg.selectedSegment == 1)];
    NSString *p = mpv_str(_mpv, "path");
    if (p.length) {
        [_danmaku reloadForVideo:p duration:mpv_num(_mpv, "duration") purgeCache:YES];
    }
    [self fillSettingsBody];
}

- (void)dmAutoNetworkChanged:(ANESegmentedView *)seg
{
    BOOL on = (seg.selectedSegment == 1);
    [self setDmPref:@"dandanplayAutoNetwork" value:@(on)];
    if (on) {
        NSString *p = mpv_str(_mpv, "path");
        if (p.length) [self reloadDanmakuForPath:p];
    } else {
        [_danmaku clear];
    }
    [self fillSettingsBody];
}

// ── 其他 tab ────────────────────────────────────────────────────────────────

- (CGFloat)fillOtherTab:(NSView *)body width:(CGFloat)w
{
    CGFloat ys = 0;

    // 进度条章节刻度
    ys = [self addSegmentedRowTo:body top:ys width:w title:@"进度条章节刻度"
                           items:@[@"关", @"开"]
                        selected:_showChapterMarks ? 1 : 0
                          action:@selector(chapterMarksChanged:)];

    // ANE 超分：Apple 的 VTLowLatencySuperResolutionScaler，跑神经引擎
    ys = [self addSegmentedRowTo:body top:ys width:w title:@"ANE 超分（神经引擎）"
                           items:@[@"关", @"2x"]
                        selected:_aneSR ? 1 : 0
                          action:@selector(aneSRChanged:)];

    NSTextField *h3 = [self panelLabel:@"把画面放大一倍，锐度比普通拉伸好得多；"
                                  size:10 weight:NSFontWeightRegular];
    h3.textColor = NSColor.secondaryLabelColor;
    h3.frame = NSMakeRect(16, ys, w - 32, 14);
    [body addSubview:h3];
    ys += 16;
    NSTextField *h4 = [self panelLabel:@"仅有 ≤720p 片源支持（1080p 苹果还没开放）；"
                                  size:10 weight:NSFontWeightRegular];
    h4.textColor = NSColor.secondaryLabelColor;
    h4.frame = NSMakeRect(16, ys, w - 32, 14);
    [body addSubview:h4];
    ys += 16;
    NSTextField *h5 = [self panelLabel:@"720p 会 1.5x 拉到 1080p，跟补帧同开可能掉帧。"
                                  size:10 weight:NSFontWeightRegular];
    h5.textColor = NSColor.secondaryLabelColor;
    h5.frame = NSMakeRect(16, ys, w - 32, 14);
    [body addSubview:h5];
    ys += 26;

    // ANE 时域降噪：VTTemporalNoiseFilter，同样跑神经引擎，但只降噪、不改尺寸
    ys = [self addSegmentedRowTo:body top:ys width:w title:@"ANE 降噪（时域）"
                           items:@[@"关", @"轻", @"强"]
                        selected:_aneNoise
                          action:@selector(aneNoiseChanged:)];
    NSTextField *hn = [self panelLabel:@"拿前后帧做运动估计，抹掉噪点和压缩伪影，尺寸不变；"
                                   size:10 weight:NSFontWeightRegular];
    hn.textColor = NSColor.secondaryLabelColor;
    hn.frame = NSMakeRect(16, ys, w - 32, 14);
    [body addSubview:hn];
    ys += 16;
    NSTextField *hn2 = [self panelLabel:@"任何分辨率都能用（4K 也行），代价是画面延后 2 帧。"
                                    size:10 weight:NSFontWeightRegular];
    hn2.textColor = NSColor.secondaryLabelColor;
    hn2.frame = NSMakeRect(16, ys, w - 32, 14);
    [body addSubview:hn2];
    ys += 26;

    // Anime4K：跟 IINA/mpv 用同一套 GLSL 着色器（bloc97/Anime4K，MIT），
    // 走 mpv 的 glsl-shaders，GPU 上跑，跟我们的 ANE 补帧互不干扰。
    CGFloat y = ys;
    y = [self addSegmentedRowTo:body top:y width:w title:@"Anime4K 画质增强"
                                 items:@[@"关", @"轻量", @"增强", @"2x 超分"]
                              selected:_anime4kMode
                                action:@selector(anime4kChanged:)];

    NSTextField *h1 = [self panelLabel:@"「轻量」小号 CNN，线条略锐、几乎不吃显卡；"
                                  size:10 weight:NSFontWeightRegular];
    h1.textColor = NSColor.secondaryLabelColor;
    h1.frame = NSMakeRect(16, y, w - 32, 14);
    [body addSubview:h1];
    y += 16;
    NSTextField *h2 = [self panelLabel:@"「增强」大号 CNN，锐化线条、压噪点，尺寸不变；"
                                  size:10 weight:NSFontWeightRegular];
    h2.textColor = NSColor.secondaryLabelColor;
    h2.frame = NSMakeRect(16, y, w - 32, 14);
    [body addSubview:h2];
    y += 16;
    NSTextField *h2b = [self panelLabel:@"「2x 超分」再把画面放大一倍（更吃显卡）。"
                                   size:10 weight:NSFontWeightRegular];
    h2b.textColor = NSColor.secondaryLabelColor;
    h2b.frame = NSMakeRect(16, y, w - 32, 14);
    [body addSubview:h2b];
    y += 22;

    // 截图保存位置
    NSTextField *cap = [self panelLabel:@"截图保存位置" size:11 weight:NSFontWeightSemibold];
    cap.frame = NSMakeRect(16, y, w - 32, 15);
    [body addSubview:cap];
    y += 17;

    NSButton *dirBtn = [self wideButton:[self prettyPath:[self screenshotDir]]
                                 action:@selector(chooseScreenshotDir)];
    dirBtn.alignment = NSTextAlignmentLeft;
    dirBtn.font = [NSFont systemFontOfSize:11];
    dirBtn.toolTip = @"点击选择文件夹";
    dirBtn.frame = NSMakeRect(16, y, w - 32, 24);
    [body addSubview:dirBtn];
    y += 30;

    return y + 16;
}

- (void)chapterMarksChanged:(ANESegmentedView *)seg
{
    _showChapterMarks = (seg.selectedSegment == 1);
    [[NSUserDefaults standardUserDefaults] setBool:_showChapterMarks
                                            forKey:@"chapterMarks"];
    _chapterSig = nil;                  // 强制下一帧重算
    [self refreshChapterMarks];
    NSLog(@"[ANEPlayer] 章节刻度 → %@", _showChapterMarks ? @"开" : @"关");
}

- (void)aneSRChanged:(ANESegmentedView *)seg
{
    _aneSR = (seg.selectedSegment == 1);
    [[NSUserDefaults standardUserDefaults] setBool:_aneSR forKey:@"aneSR"];
    [self applyVideoChain];
    [self fillSettingsBody];
}

- (void)aneNoiseChanged:(ANESegmentedView *)seg
{
    _aneNoise = seg.selectedSegment;
    [[NSUserDefaults standardUserDefaults] setInteger:_aneNoise forKey:@"aneNoise"];
    [self applyVideoChain];
    [self fillSettingsBody];
}

- (void)anime4kChanged:(ANESegmentedView *)seg
{
    _anime4kMode = seg.selectedSegment;
    [[NSUserDefaults standardUserDefaults] setInteger:_anime4kMode forKey:@"anime4kMode"];
    [self applyAnime4k];
    [self fillSettingsBody];
}

/// 把 Anime4K 的 GLSL 着色器挂到 mpv（顺序：Clamp → Restore → AutoDownscalePre → Upscale）
- (void)applyAnime4k
{
    if (!_mpv) return;
    NSString *dir = [[NSBundle mainBundle] pathForResource:@"anime4k" ofType:nil];
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    void (^addFile)(NSString *) = ^(NSString *name) {
        NSString *p = [dir stringByAppendingPathComponent:name];
        if (dir && [[NSFileManager defaultManager] fileExistsAtPath:p]) [list addObject:p];
    };
    if (_anime4kMode >= 1) {
        addFile(@"Anime4K_Clamp_Highlights.glsl");
        // 轻量档用 S（小号 CNN，权重约 M 的一半）；增强/超分档用 M
        addFile(_anime4kMode == 1 ? @"Anime4K_Restore_CNN_S.glsl"
                                  : @"Anime4K_Restore_CNN_M.glsl");
    }
    if (_anime4kMode >= 3) {
        addFile(@"Anime4K_AutoDownscalePre_x2.glsl");
        addFile(@"Anime4K_Upscale_CNN_x2_M.glsl");
    }
    // glsl-shaders 是「列表属性」，直接把一串 path 拼起来会被当成一个文件名
    // （实测报 Cannot open file '...;...'）。必须用 change-list 逐条追加。
    mpv_cmd(_mpv, (const char *[]){"change-list", "glsl-shaders", "clr", "", NULL});
    for (NSString *path in list) {
        mpv_cmd(_mpv, (const char *[]){"change-list", "glsl-shaders", "append",
                                      path.UTF8String, NULL});
    }
    NSLog(@"[ANEPlayer] Anime4K 模式 %ld，着色器 %lu 个", (long)_anime4kMode,
          (unsigned long)list.count);
}

// ── 截图 ────────────────────────────────────────────────────────────────────

/// 截图目录：偏好里没有就用 ~/Pictures（首次截图时才建）
- (NSString *)screenshotDir
{
    NSString *d = [[NSUserDefaults standardUserDefaults] stringForKey:@"screenshotDir"];
    if (!d.length) d = [NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:d]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:d
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:NULL];
    }
    return d;
}

/// 路径太长时把 home 缩成 ~，面板上才放得下
- (NSString *)prettyPath:(NSString *)p
{
    NSString *home = NSHomeDirectory();
    if ([p hasPrefix:home]) return [@"~" stringByAppendingString:[p substringFromIndex:home.length]];
    return p;
}

- (void)takeScreenshot
{
    if (!_mpv) return;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"ANEPlayer-%@.png",
                      [df stringFromDate:[NSDate date]]];
    NSString *path = [[self screenshotDir] stringByAppendingPathComponent:name];

    // flags 用 subtitles：字幕一起截进去（弹幕是网页层，本来就不在 mpv 画面里）
    const char *args[] = { "screenshot-to-file", path.UTF8String, "subtitles", NULL };
    if (mpv_command(_mpv, args) < 0) {
        [self flashToast:@"截图失败"];
    } else {
        [self flashToast:[NSString stringWithFormat:@"已截图 → %@", [self prettyPath:path]]];
    }
}

- (void)chooseScreenshotDir
{
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO;
    p.canChooseDirectories = YES;
    p.allowsMultipleSelection = NO;
    p.prompt = @"选择";
    p.directoryURL = [NSURL fileURLWithPath:[self screenshotDir]];
    __weak typeof(self) wself = self;
    // 全屏窗口挂 sheet 有时不显示，用独立面板更稳
    [p beginWithCompletionHandler:^(NSModalResponse r) {
        AppDelegate *s = wself;
        if (!s || r != NSModalResponseOK || !p.URL) return;
        [[NSUserDefaults standardUserDefaults] setObject:p.URL.path forKey:@"screenshotDir"];
        [s fillSettingsBody];       // 按钮上的路径跟着变
    }];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)flashToast:(NSString *)text
{
    if (!_window || !text.length) return;

    CGFloat h = 36.0;
    CGFloat textW = MIN(430.0, MAX(60.0, text.length * 6.9 + 4.0));
    CGFloat w = 34.0 + textW + 16.0;        // 图标起点 13 + 图标 15 + 间隙 6

    if (!_toastBox) {
        // 跟控制条、面板同一套液态玻璃（旧系统自动退回浅色毛玻璃）
        NSView *glass = [self makeEffectView:NSMakeRect(0, 0, w, h) radius:12];
        NSView *host = [self contentHostForPanel:glass flipped:NO];

        // 压在深色画面上时，纯玻璃会发灰、深色字看不清，垫一层很淡的白让文字稳一点
        NSView *tint = [[NSView alloc] initWithFrame:host.bounds];
        tint.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        tint.wantsLayer = YES;
        tint.layer.backgroundColor = [[NSColor whiteColor] colorWithAlphaComponent:0.46].CGColor;
        tint.layer.cornerRadius = 12;
        tint.layer.masksToBounds = YES;
        [host addSubview:tint];

        _toastIcon = [[NSImageView alloc] initWithFrame:NSMakeRect(13, (h - 15) / 2.0, 15, 15)];
        _toastIcon.contentTintColor = NSColor.labelColor;
        [host addSubview:_toastIcon];

        _toastLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(34, (h - 17) / 2.0, textW, 17)];
        _toastLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        _toastLabel.textColor = NSColor.labelColor;
        _toastLabel.alignment = NSTextAlignmentLeft;
        _toastLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _toastLabel.bordered = NO;
        _toastLabel.drawsBackground = NO;
        _toastLabel.editable = NO;
        _toastLabel.selectable = NO;
        [host addSubview:_toastLabel];

        [_window.contentView addSubview:glass
                              positioned:NSWindowAbove relativeTo:[self chromeAnchor]];
        _toastBox = glass;
    }

    _toastLabel.stringValue = text;
    _toastIcon.image = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                                accessibilityDescription:nil];

    // 右下角，浮在控制条上方；右侧面板开着时让到面板左边，别压在上面
    NSRect b = _window.contentView.bounds;
    CGFloat x = NSWidth(b) - w - 14.0;
    NSView *panel = [self visibleSidePanel];
    if (panel) x = MIN(x, NSMinX(panel.frame) - w - 10.0);
    x = MAX(14.0, x);
    _toastBox.frame = NSMakeRect(x, kBarHeight + 14.0, w, h);
    _toastLabel.frame = NSMakeRect(34, (h - 17) / 2.0, w - 34 - 16, 17);

    // 直接从 hidden 里做 alpha 动画不会生效（视图还没参与合成，动画跑在 0 上），
    // 所以出现是瞬间的，只有消失做淡出 —— 提示条本来就该「啪」一下出现
    _toastBox.hidden = NO;
    _toastBox.alphaValue = 1.0;

    [_toastTimer invalidate];
    __weak typeof(self) wself = self;
    _toastTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 repeats:NO block:^(NSTimer *t) {
        AppDelegate *s = wself;
        if (!s) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.3;
            s.toastBox.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (s.toastBox.alphaValue < 0.05) s.toastBox.hidden = YES;
        }];
    }];
}

// ── 控制条自动隐藏 ──────────────────────────────────────────────────────────

- (void)showControls
{
    _controls.hidden = NO;
    _controls.alphaValue = 1.0;
    [_hideTimer invalidate];
    __weak typeof(self) wself = self;
    _hideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer *t) {
        AppDelegate *s = wself;
        if (!s) return;
        BOOL paused = mpv_bool(s.mpv, "pause");
        BOOL playing = mpv_num(s.mpv, "duration") > 0;
        if (!paused && playing) {
            [s hideFactorMenu];     // 控制条淡出还留个浮层会很怪
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = 0.35;
                s.controls.animator.alphaValue = 0.0;
            } completionHandler:^{
                if (s.controls.alphaValue < 0.05) s.controls.hidden = YES;
            }];
        }
    }];
}

/// 单击画面：马上把控制条收掉（不用等 3 秒）
- (void)hideControlsNow
{
    [_hideTimer invalidate];
    [self hideFactorMenu];
    if (!_controls || _controls.hidden) return;
    __weak typeof(self) wself = self;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.18;
        wself.controls.animator.alphaValue = 0.0;
    } completionHandler:^{
        AppDelegate *s = wself;
        if (s && s.controls.alphaValue < 0.05) s.controls.hidden = YES;
    }];
}

// ── 动作 ────────────────────────────────────────────────────────────────────

- (void)progressChanged:(NSSlider *)s
{
    // 拖动中只更新显示，松手才真正 seek（避免拖动过程疯狂 seek）
    double dur = mpv_num(_mpv, "duration");
    _timeLabel.stringValue = [NSString stringWithFormat:@"%@ / %@",
                              fmt_time(s.doubleValue), fmt_time(dur)];
    _seeking = YES;
    _lastSeekTouch = CFAbsoluteTimeGetCurrent();
    // 每次变化都重置防抖（不是取消）：松手瞬间 NSSlider 还会补发一次 value change，
    // 早先这里直接 invalidate 会把待执行的那次跳转吞掉，松手后永远不跳
    [self armSeekTimer:kSeekSettleDelay];
}

- (void)speedChanged:(NSPopUpButton *)b
{
    NSString *t = b.titleOfSelectedItem;
    [self setSpeed:[t doubleValue]];
}

- (void)volumeChanged:(NSSlider *)s
{
    [self applyVolume:s.doubleValue];
}

// ── 弹幕 ────────────────────────────────────────────────────────────────────

/// 偏好键名沿用 IINA 插件的命名，方便对照插件文档
- (NSDictionary *)defaultDanmakuPrefs
{
    NSDictionary *defs = @{
        @"danmakuEnabled":        @YES,
        @"danmakuCanvasOpacity":  @0.8,
        @"niconicommentsFontScale": @1.0,
        @"canvasMode":            @"css",
        @"strokeColor":           @"#000000",
        @"strokeInversionColor":  @"#ffffff",
        @"strokeOpacity":         @0.4,
        @"strokeWidth":           @2.8,
        @"commentLimit":          @0,
        @"scrollSpeed":           @1.0,
        @"danmakuTimeOffset":     @0,
        @"danmakuTopPercent":     @0,
        @"danmakuDisplayArea":    @100,
        @"danmakuBlockEnabled":   @NO,
        @"danmakuBlockWords":     @"",
        @"danmakuBlockExact":     @NO,
        @"danmakuFilterRepeat":   @NO,
        @"danmakuDedupe":         @NO,
        @"danmakuFontFamily":     @"",
        @"danmakuFontWeight":     @"400",
        @"dandanplayChConvert":   @0,
        @"dandanplayWithRelated": @YES,
        @"dandanplayAutoNetwork": @YES,
    };
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in defs) {
        id v = [d objectForKey:k];
        out[k] = v ?: defs[k];
    }
    return out;
}

/// 浮层的锚点：有弹幕层就压在弹幕之上（弹幕只该盖住视频画面）
- (NSView *)chromeAnchor
{
    NSView *web = _danmaku.webView;
    return web ?: _videoView;
}

- (void)setupDanmaku
{
    _settingsTab = [[NSUserDefaults standardUserDefaults] integerForKey:@"settingsTab"];
    if (_settingsTab < 0 || _settingsTab > 3) _settingsTab = 0;
    _dmSubTab = [[NSUserDefaults standardUserDefaults] integerForKey:@"danmakuSubTab"];
    if (_dmSubTab < 0 || _dmSubTab > 2) _dmSubTab = 0;
    _dmPrefs = [[self defaultDanmakuPrefs] mutableCopy];
    // 把上次存的偏好读回来（之前只写不读，所以每次启动都被默认值盖掉）。
    // 遍历 defaults 而不是默认值表：新加的键哪怕默认值表里漏了也能读到
    NSUserDefaults *dmDefaults = [NSUserDefaults standardUserDefaults];
    for (NSString *k in [[dmDefaults dictionaryRepresentation] allKeys]) {
        if (![_dmPrefs objectForKey:k]) continue;   // 只认已知的偏好键
        id saved = [dmDefaults objectForKey:k];
        if (saved) _dmPrefs[k] = saved;
    }

    _danmaku = [[ANEDanmaku alloc] initWithHostView:_window.contentView];
    __weak typeof(self) wself = self;
    _danmaku.statusHandler = ^(NSString *text) {
        AppDelegate *s = wself;
        if (!s) return;
        s.dmStatusText = text ?: @"";
        if (s.dmStatusLabel) s.dmStatusLabel.stringValue = s.dmStatusText;
    };
    // 插在视频之上、控制条/面板之下：addSubview:positioned:above 会把它塞进
    // 紧贴视频的位置，已经存在的控制条自动留在它上面
    NSView *web = _danmaku.webView;
    if (web) [_window.contentView addSubview:web positioned:NSWindowAbove relativeTo:_videoView];

    _danmaku.filesDroppedHandler = ^(NSArray<NSString *> *paths) {
        AppDelegate *s = wself;
        if (!s || !paths.count) return;
        NSArray<NSString *> *playable = [s playableOnly:paths];
        NSLog(@"[Drop] 收到 %lu 个文件，可播放 %lu 个",
              (unsigned long)paths.count, (unsigned long)playable.count);
        if (playable.count > 1) [s openFileList:playable];
        else                    [s openFile:playable.firstObject];
    };

    [_danmaku applySettings:_dmPrefs];
    [self updateDanmakuFrame];

    NSString *p = mpv_str(_mpv, "path");
    if (p.length) [_danmaku loadForVideo:p duration:mpv_num(_mpv, "duration")];
}

/// 弹幕铺在「视频实际显示区」上（去掉黑边），否则比例不对会跟画面错位。
/// 「弹幕位置」滑块可以让整块弹幕区往上顶，把上方黑边也吃进来（默认 0 = 贴着画面顶）。
- (void)updateDanmakuFrame
{
    if (!_danmaku || !_window) return;
    NSRect b = _window.contentView.bounds;
    if (NSWidth(b) < 2 || NSHeight(b) < 2) return;

    NSRect rect = b;
    NSSize vs = [self videoSize];
    if (vs.width > 1 && vs.height > 1) {
        double vA = vs.width / vs.height;
        double bA = NSWidth(b) / MAX(1.0, NSHeight(b));
        if (vA > bA) {
            CGFloat h = NSWidth(b) / vA;
            rect = NSMakeRect(0, (NSHeight(b) - h) / 2.0, NSWidth(b), h);
        } else {
            CGFloat w = NSHeight(b) * vA;
            rect = NSMakeRect((NSWidth(b) - w) / 2.0, 0, w, NSHeight(b));
        }
    }

    // 显示区域：弹幕只占画面顶部这么高（25%~100%），顶部对齐画面顶。
    // 注意这里只裁 native 这一层，渲染层的画布会按这块区域的宽高比自适应；
    // 早先两边各缩一次（层缩到 25%、画布 style 高度又乘 25%），
    // 结果实际只剩 6%，弹幕全挤成一条 —— 用户看到的“哪是 25%”就是这个。
    double area = [_dmPrefs[@"danmakuDisplayArea"] doubleValue] / 100.0;
    area = MAX(0.25, MIN(1.0, area));
    CGFloat areaH = rect.size.height * area;
    rect = NSMakeRect(rect.origin.x, NSMaxY(rect) - areaH, rect.size.width, areaH);

    // 弹幕位置：把这块区域整体往上顶进顶部黑边（只抬高顶边，底边不动），
    // 百分比按「区域顶到窗口顶」那段黑边的高度算，100% 正好贴到窗口上沿
    double pct = [_dmPrefs[@"danmakuTopPercent"] doubleValue];
    if (pct > 0.5) {
        CGFloat room = NSHeight(b) - NSMaxY(rect);
        if (room > 0.5) {
            CGFloat up = room * MIN(100.0, pct) / 100.0;
            rect.size.height += up;
        }
    }
    [_danmaku setContentRect:rect];
}

- (void)updateDanmaku:(double)pos
{
    if (!_danmaku || !_mpv) return;
    // 刚打开文件时 video-params 还没就绪，弹幕层会先按「整个窗口」排一遍；
    // 等尺寸出来再按真实画面重排，否则「显示区域」的基准是窗口而不是画面，
    // 25% 会跑到黑边上面去
    NSSize vsz = [self videoSize];
    if (!NSEqualSizes(vsz, _lastDanmakuVideoSize)) {
        _lastDanmakuVideoSize = vsz;
        [self updateDanmakuFrame];
    }
    [_danmaku updateTime:pos
                duration:mpv_num(_mpv, "duration")
                  paused:mpv_bool(_mpv, "pause")
                   speed:mpv_num(_mpv, "speed")];
}

/// 改一个弹幕参数：存偏好 → 立刻推给渲染层
- (void)setDmPref:(NSString *)key value:(id)value
{
    _dmPrefs[key] = value;
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:key];
    [_danmaku applySettings:_dmPrefs];
}

/// 换片：重新取弹幕（同一个文件不会重复请求）
- (void)reloadDanmakuForPath:(NSString *)path
{
    if (!_danmaku || !path.length) return;
    [_danmaku loadForVideo:path duration:mpv_num(_mpv, "duration")];
}

// ── 定时刷新 ────────────────────────────────────────────────────────────────

/// 读 mpv 的 chapter-list（[{title, time}, …]）换算成百分比喂给刻度层。
/// 只在「时长/章节数/开关」变化时重算，否则每 0.25s 都会重绘一遍刻度。
- (void)refreshChapterMarks
{
    if (!_mpv || !_chapterTrack) return;

    double dur = mpv_num(_mpv, "duration");
    NSMutableArray<NSNumber *> *times = [NSMutableArray array];

    mpv_node node;
    if (mpv_get_property(_mpv, "chapter-list", MPV_FORMAT_NODE, &node) >= 0) {
        if (node.format == MPV_FORMAT_NODE_ARRAY) {
            for (int i = 0; i < node.u.list->num; i++) {
                mpv_node *it = &node.u.list->values[i];
                if (it->format != MPV_FORMAT_NODE_MAP) continue;
                for (int j = 0; j < it->u.list->num; j++) {
                    const char *k = it->u.list->keys[j];
                    mpv_node *v = &it->u.list->values[j];
                    if (!k) continue;
                    if (!strcmp(k, "time") && v->format == MPV_FORMAT_DOUBLE) {
                        [times addObject:@(v->u.double_)];
                        break;
                    }
                }
            }
        }
        mpv_free_node_contents(&node);
    }

    NSString *sig = [NSString stringWithFormat:@"%.2f|%lu|%d", dur,
                     (unsigned long)times.count, (int)_showChapterMarks];
    if ([_chapterSig isEqualToString:sig]) return;
    _chapterSig = sig;

    // 少于两章就没必要画刻度（一条线等于没有）
    if (!_showChapterMarks || dur <= 0 || times.count < 2) {
        _chapterTrack.fractions = @[];
        _chapterTrack.hidden = YES;
        return;
    }

    NSMutableArray<NSNumber *> *fr = [NSMutableArray arrayWithCapacity:times.count];
    for (NSNumber *t in times) {
        double f = t.doubleValue / dur;
        if (f < 0) f = 0;
        if (f > 1) f = 1;
        [fr addObject:@(f)];
    }
    _chapterTrack.fractions = fr;
    _chapterTrack.hidden = NO;
    [_chapterTrack setNeedsDisplay:YES];
    NSLog(@"[ANEPlayer] 章节刻度：%lu 章", (unsigned long)times.count);
}

- (void)tick
{
    if (!_mpv) return;
    // 拖动窗口期间不刷新：每 0.25s 读二十多个 mpv 属性 + 改文本，会跟重绘抢主线程
    if (_liveResizing) return;
    double pos = mpv_num(_mpv, "time-pos");
    double dur = mpv_num(_mpv, "duration");

    // 保险：如果鼠标在窗口外松开，收不到 mouseUp，_seeking 会一直卡住
    if (_seeking && !_seekTimer && !_seekPollTimer &&
        CFAbsoluteTimeGetCurrent() - _lastSeekTouch > 6.0) {
        _seeking = NO;
        [self resumeEnhanceFilters];
    }

    if (dur > 0) {
        _progress.maxValue = dur;
        if (!_seeking) {
            _progress.doubleValue = pos;
            NSString *t = [NSString stringWithFormat:@"%@ / %@",
                           fmt_time(pos), fmt_time(dur)];
            if (![_timeLabel.stringValue isEqualToString:t]) _timeLabel.stringValue = t;
        }
    }
    [self updatePlayButton];
    [self updateMuteButton];

    // 文件加载完成后（duration 有了）轨道菜单重建一次
    if (!_tracksBuilt && dur > 0) {
        [self rebuildTrackMenus];
        _tracksBuilt = YES;
    }
    // 播放列表切到别的文件时（title 还挂在上一个片名上）跟着更新，
    // 并且给新文件重新找一遍同名外挂字幕
    NSString *fn = mpv_str(_mpv, "filename");
    if (fn.length && ![_currentFile isEqualToString:fn]) {
        _currentFile = fn;
        _currentVideoBase = fn.stringByDeletingPathExtension;
        _window.title = fn;
        _tracksBuilt = NO;
        NSString *p = mpv_str(_mpv, "path");
        if (p.length && [p hasPrefix:@"/"]) {
            [self autoLoadExternalSubs:p];
            [self reloadDanmakuForPath:p];
        }
    }

    // 视频尺寸一出来就把窗口比例调对（换片时 didFitWindow 已重置）
    [self fitWindowToVideoIfNeeded];
    [self updateStats];
    [self refreshChapterMarks];
    [self updateDanmaku:pos];

    // 播放列表变了才重建面板（比 count + pos 签名，避免每 0.25s 重排）
    if (_playlistPanel && !_playlistPanel.hidden) {
        NSString *sig = [NSString stringWithFormat:@"%.0f|%.0f",
                         mpv_num(_mpv, "playlist-count"), mpv_num(_mpv, "playlist-pos")];
        if (![_playlistSig isEqualToString:sig]) {
            _playlistSig = sig;
            [self reloadPlaylist];
        }
    }
}

/// 从 video-params / video-out-params 这类 MAP 里按键名取 w/h。
/// 注意：不能按「前两个值」取 —— MAP 的键顺序不保证是 w、h。
- (NSSize)sizeFromProp:(const char *)prop
{
    NSSize s = NSZeroSize;
    if (!_mpv) return s;
    mpv_node node;
    if (mpv_get_property(_mpv, prop, MPV_FORMAT_NODE, &node) < 0) return s;
    if (node.format == MPV_FORMAT_NODE_MAP) {
        for (int i = 0; i < node.u.list->num; i++) {
            const char *k = node.u.list->keys[i];
            mpv_node *v = &node.u.list->values[i];
            if (!k) continue;
            if (strcmp(k, "w") == 0 && v->format == MPV_FORMAT_INT64)
                s.width = (CGFloat)v->u.int64;
            else if (strcmp(k, "h") == 0 && v->format == MPV_FORMAT_INT64)
                s.height = (CGFloat)v->u.int64;
        }
    }
    mpv_free_node_contents(&node);
    return s;
}

- (NSSize)videoSize { return [self sizeFromProp:"video-params"]; }

/// mpv 的编解码器名是一串别名： "H.264 / AVC / MPEG-4 AVC / ..."，只留第一个
- (NSString *)shortCodec:(NSString *)full
{
    if (!full.length) return nil;
    NSArray *parts = [full componentsSeparatedByString:@" / "];
    return parts.firstObject;
}

// ── 键盘 ────────────────────────────────────────────────────────────────────

/// 按住超过这么久才算「长按」，短按仍然当播放/暂停
static const double kSpaceHoldDelay = 0.26;


- (void)spacePressed
{
    if (_spaceDown) return;          // 系统自动重复，忽略
    _spaceDown = YES;
    [_spaceTimer invalidate];
    __weak typeof(self) wself = self;
    _spaceTimer = [NSTimer scheduledTimerWithTimeInterval:kSpaceHoldDelay
                                                  repeats:NO
                                                    block:^(NSTimer *t) {
        AppDelegate *s = wself;
        if (!s || !s.spaceDown) return;
        double cur = mpv_num(s.mpv, "speed");
        if (cur <= 0) cur = 1.0;
        s.savedSpeed = cur;
        double sp = cur * (s.holdBoost > 0 ? s.holdBoost : 1.5);   // 默认 1x → 1.5x
        mpv_set_property(s.mpv, "speed", MPV_FORMAT_DOUBLE, &sp);
        s.spaceBoosted = YES;
        NSLog(@"[HOLD] 长按加速 %.2fx → %.2fx", cur, sp);
    }];
}

- (void)spaceReleased
{
    _spaceDown = NO;
    [_spaceTimer invalidate];
    _spaceTimer = nil;

    if (_spaceBoosted) {
        double sp = (_savedSpeed > 0) ? _savedSpeed : 1.0;
        mpv_set_property(_mpv, "speed", MPV_FORMAT_DOUBLE, &sp);
        _spaceBoosted = NO;
        NSLog(@"[HOLD] 松开，恢复 %.2fx", sp);
        if (_settingsPanel && !_settingsPanel.hidden) [self fillSettingsBody];
    } else {
        NSLog(@"[HOLD] 短按 → 播放/暂停");
        [self togglePlay];                      // 没长按 → 普通播放/暂停
    }
}

/// 切到别的 App 时如果还按着空格（收不到 keyUp），把速度还原
- (void)restoreSpaceBoost
{
    if (!_spaceBoosted) return;
    double sp = (_savedSpeed > 0) ? _savedSpeed : 1.0;
    mpv_set_property(_mpv, "speed", MPV_FORMAT_DOUBLE, &sp);
    _spaceBoosted = NO;
    _spaceDown = NO;
    [_spaceTimer invalidate];
}

/// 当前焦点是不是落在可编辑的文本框里（设置里的屏蔽词、弹幕搜索框…）。
/// 中文输入法选字要按空格，如果不拦一下，播放器会把它当成播放/暂停。
- (BOOL)isEditingText
{
    NSResponder *fr = _window.firstResponder;
    if ([fr isKindOfClass:NSTextView.class]) return [(NSTextView *)fr isEditable];
    if ([fr isKindOfClass:NSTextField.class]) return [(NSTextField *)fr isEditable];
    return NO;
}

- (void)setupKeys
{
    __weak typeof(self) wself = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
        AppDelegate *s = wself;
        if (!s) return e;
        NSString *ch = e.charactersIgnoringModifiers;
        NSUInteger flags = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        BOOL cmd = (flags & NSEventModifierFlagCommand) != 0;

        // 正在文本框里输入（尤其是拼音选字按空格）→ 全部放行，别抢键
        if ([s isEditingText]) return e;

        if (cmd && [ch isEqualToString:@"o"]) { [s openPanel]; return nil; }
        if (cmd && [ch isEqualToString:@"f"]) { [s toggleFullScreen]; return nil; }
        if (cmd && [ch isEqualToString:@"s"]) { [s takeScreenshot]; return nil; }   // cmdSShot

        unichar c = ch.length ? [ch characterAtIndex:0] : 0;
        switch (c) {
            case ',': case 0xFF0C: [s adjustVolumeBy:-5]; return nil;   // , 音量 -
            case '.': case 0x3002: case 0xFF0E:                          // . 。 ．
                                              [s adjustVolumeBy:5];  return nil;
            case ' ': if (cmd) return e; [s spacePressed]; return nil;
            case 'f': [s toggleFullScreen]; return nil;
            case 'm': [s toggleMute]; return nil;
            case 'a': [s cycleFactor]; return nil;
            case 's': [s toggleSubPanel]; return nil;
            case 'l': [s togglePlaylistPanel]; return nil;
            case 'p': [s toggleSettingsPanel]; return nil;   // 设置面板（, . 让给音量了）
            case NSTabCharacter: [s toggleStats]; return nil;   // 播放信息面板
            case 0x1B:                                          // Esc：先关面板
                if ((s.subPanel && !s.subPanel.hidden) ||
                    (s.playlistPanel && !s.playlistPanel.hidden) ||
                    (s.settingsPanel && !s.settingsPanel.hidden)) {
                    [s hideSidePanelsExcept:nil];
                    [s updateSideButtons];
                    return nil;
                }
                return e;
            case NSRightArrowFunctionKey: [s seekBy:5];  return nil;
            case NSLeftArrowFunctionKey:  [s seekBy:-5]; return nil;
            case NSUpArrowFunctionKey:    [s applyVolume:mpv_num(s.mpv, "volume") + 5]; return nil;
            case NSDownArrowFunctionKey:  [s applyVolume:mpv_num(s.mpv, "volume") - 5]; return nil;
        }
        return e;
    }];

    // 空格松开：长按过就恢复原速，没长按就当成播放/暂停
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyUp
                                          handler:^NSEvent *(NSEvent *e) {
        AppDelegate *s = wself;
        if (!s) return e;
        if ([s isEditingText]) return e;
        NSString *ch = e.charactersIgnoringModifiers;
        if (ch.length && [ch characterAtIndex:0] == ' ') { [s spaceReleased]; return nil; }
        return e;
    }];

    // 松手时才 seek
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *e) {
        AppDelegate *s = wself;
        if (s && s.seeking) {
            // 这里不直接 seek：先交给 commitSeekTo 做一小段防抖，
            // 手抖/连续拖动只会跳最终那一次
            [s commitSeekTo:s.progress.doubleValue];
        }
        return e;
    }];

    // 鼠标移动 / 进入控制条 → 重新显示
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                          handler:^NSEvent *(NSEvent *e) {
        AppDelegate *s = wself;
        if (s) [s showControls];
        return e;
    }];

    // 画面上的鼠标行为：单击收控制条、双击全屏；点浮层外面先收浮层
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                          handler:^NSEvent *(NSEvent *e) {
        AppDelegate *s = wself;
        if (!s || !s.window || e.window != s.window) return e;

        NSPoint p = e.locationInWindow;                 // 窗口坐标，原点在左下
        CGFloat hostH = NSHeight(s.window.contentView.bounds);
        NSView *panel = [s visibleSidePanel];
        ANEChoiceMenu *menu = s.factorMenu;

        // 顶部这条带子留给系统：交通灯、拖窗口、双击缩放都靠它
        if (p.y > hostH - 40) {
            if (panel) { [s hideSidePanelsExcept:nil]; [s updateSideButtons]; }
            if (menu) [s hideFactorMenu];
            return e;
        }

        // 点在浮层自己身上：交给它处理
        if (menu && NSPointInRect(p, menu.frame)) return e;
        if (panel && NSPointInRect(p, panel.frame)) return e;

        // 控制条：照常响应按钮，但先把浮层收掉
        if (s.controls && !s.controls.hidden && NSPointInRect(p, s.controls.frame)) {
            BOOL had = (panel || menu);
            if (panel) { [s hideSidePanelsExcept:nil]; [s updateSideButtons]; }
            if (menu) [s hideFactorMenu];
            if (had) {
                NSView *hit = [s.window.contentView hitTest:p];
                if (hit == s.settingsBtn || hit == s.listBtn || hit == s.subBtn ||
                    hit == s.shotBtn || hit == s.aneBtn)
                    return nil;     // 这几个刚把浮层收掉了，别再让按钮把它打开
            }
            return e;
        }

        // 画面区域
        if (panel) { [s hideSidePanelsExcept:nil]; [s updateSideButtons]; }
        if (menu) [s hideFactorMenu];

        if (e.clickCount >= 2) { [s toggleFullScreen]; return nil; }
        [s hideControlsNow];        // 单击：不用等 3 秒，立刻收
        return nil;
    }];
}

// ── 菜单 ────────────────────────────────────────────────────────────────────

- (void)setupMenus
{
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"打开文件…"
                                                action:@selector(openPanel)
                                         keyEquivalent:@"o"]];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"退出 ANEPlayer"
                                                action:@selector(terminate:)
                                         keyEquivalent:@"q"]];
    appItem.submenu = appMenu;
    [main addItem:appItem];

    NSMenuItem *playItem = [NSMenuItem new];
    NSMenu *playMenu = [[NSMenu alloc] initWithTitle:@"播放"];
    [playMenu addItem:[[NSMenuItem alloc] initWithTitle:@"播放/暂停"
                                                 action:@selector(togglePlay)
                                          keyEquivalent:@" "]];
    [playMenu addItem:[[NSMenuItem alloc] initWithTitle:@"补帧档位切换"
                                                 action:@selector(cycleFactor)
                                          keyEquivalent:@"a"]];
    [playMenu addItem:[[NSMenuItem alloc] initWithTitle:@"全屏"
                                                 action:@selector(toggleFullScreen)
                                          keyEquivalent:@"f"]];
    [playMenu addItem:[NSMenuItem separatorItem]];
    [playMenu addItem:[[NSMenuItem alloc] initWithTitle:@"播放列表"
                                                 action:@selector(togglePlaylistPanel)
                                          keyEquivalent:@"l"]];
    [playMenu addItem:[[NSMenuItem alloc] initWithTitle:@"设置…"
                                                 action:@selector(toggleSettingsPanel)
                                          keyEquivalent:@"p"]];
    playItem.submenu = playMenu;
    [main addItem:playItem];

    // ── 字幕 ──
    NSMenuItem *subItem = [NSMenuItem new];
    NSMenu *subMenu = [[NSMenu alloc] initWithTitle:@"字幕"];
    [subMenu addItem:[[NSMenuItem alloc] initWithTitle:@"加载字幕文件…"
                                               action:@selector(openSubtitlePanel)
                                        keyEquivalent:@""]];
    [subMenu addItem:[[NSMenuItem alloc] initWithTitle:@"显示 / 隐藏字幕"
                                               action:@selector(toggleSubVisibility)
                                        keyEquivalent:@"v"]];
    [subMenu addItem:[[NSMenuItem alloc] initWithTitle:@"字幕面板"
                                               action:@selector(toggleSubPanel)
                                        keyEquivalent:@"S"]];
    [subMenu addItem:[NSMenuItem separatorItem]];
    NSMenu *subTracks = [[NSMenu alloc] initWithTitle:@"字幕轨"];
    NSMenuItem *subTrackItem = [[NSMenuItem alloc] initWithTitle:@"选择字幕轨"
                                                          action:nil keyEquivalent:@""];
    subTrackItem.submenu = subTracks;
    [subMenu addItem:subTrackItem];
    _subMenu = subMenu;
    _subTrackMenu = subTracks;
    subItem.submenu = subMenu;
    [main addItem:subItem];

    // ── 音轨 ──
    NSMenuItem *audioItem = [NSMenuItem new];
    NSMenu *audioMenu = [[NSMenu alloc] initWithTitle:@"音轨"];
    NSMenu *audioTracks = [[NSMenu alloc] initWithTitle:@"音轨"];
    NSMenuItem *audioTrackItem = [[NSMenuItem alloc] initWithTitle:@"选择音轨"
                                                            action:nil keyEquivalent:@""];
    audioTrackItem.submenu = audioTracks;
    [audioMenu addItem:audioTrackItem];
    _audioMenu = audioMenu;
    _audioTrackMenu = audioTracks;
    audioItem.submenu = audioMenu;
    [main addItem:audioItem];

    // ── 窗口 ──
    NSMenuItem *winItem = [NSMenuItem new];
    NSMenu *winMenu = [[NSMenu alloc] initWithTitle:@"窗口"];
    NSMenuItem *topItem = [[NSMenuItem alloc] initWithTitle:@"窗口置顶"
                                                     action:@selector(toggleAlwaysOnTop)
                                              keyEquivalent:@"t"];
    topItem.tag = 1001;
    [winMenu addItem:topItem];

    NSMenuItem *aspectItem = [[NSMenuItem alloc] initWithTitle:@"按视频比例锁定窗口"
                                                        action:@selector(toggleLockAspect)
                                                 keyEquivalent:@""];
    aspectItem.tag = 1002;
    aspectItem.state = NSControlStateValueOn;
    [winMenu addItem:aspectItem];

    [winMenu addItem:[[NSMenuItem alloc] initWithTitle:@"播放信息面板"
                                               action:@selector(toggleStats)
                                        keyEquivalent:@"\t"]];
    _windowMenu = winMenu;
    winItem.submenu = winMenu;
    [main addItem:winItem];

    NSApp.mainMenu = main;
    [self rebuildTrackMenus];
}

// ── 拖拽 ────────────────────────────────────────────────────────────────────

/// 拖进来的一堆文件里可能混着封面图、nfo、字幕；只留能播的
- (NSArray<NSString *> *)playableOnly:(NSArray<NSString *> *)paths
{
    static NSSet *exts = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[@"mp4", @"mkv", @"mov", @"m4v", @"avi", @"webm", @"flv",
                                     @"wmv", @"ts", @"m2ts", @"mpg", @"mpeg", @"rmvb",
                                     @"rm", @"asf", @"ogv", @"3gp", @"mp3", @"flac",
                                     @"aac", @"m4a", @"wav", @"ogg", @"opus"]];
    });
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in paths) {
        if ([exts containsObject:p.pathExtension.lowercaseString]) [out addObject:p];
    }
    // 一个能播的都没有（比如拖了整包的其他东西）就按原样交给 mpv，让它自己报错
    return out.count ? out : paths;
}

- (void)handleDrop:(id<NSDraggingInfo>)sender
{
    NSPasteboard *pb = sender.draggingPasteboard;
    NSArray *urls = [pb readObjectsForClasses:@[NSURL.class] options:nil];
    NSMutableArray *paths = [NSMutableArray array];
    for (NSURL *u in urls) if (u.isFileURL) [paths addObject:u.path];
    [self openFileList:[self playableOnly:paths]];
}

/// 打开一批文件：第一个直接播，其余追加进播放列表
- (void)openFileList:(NSArray<NSString *> *)paths
{
    NSString *first = paths.firstObject;
    if (!first) return;
    [self openFile:first];
    if (paths.count > 1) {
        NSArray *rest = [paths subarrayWithRange:NSMakeRange(1, paths.count - 1)];
        // loadfile 会把列表清空，追加得等它落地
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.35 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            [self appendFilesToPlaylist:rest];
        });
    }
}

// ── 生命周期 ────────────────────────────────────────────────────────────────

/// 解析命令行。兼容 IINA 插件的调用方式（--sub / --pos / --factor 会被识别，
/// 其余未知选项忽略），这样旧的「接管播放」入口仍然能用。
- (void)applyArguments
{
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSString *file = nil;
    int factor = 2;
    double startPos = 0;

    for (NSInteger i = 1; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"--factor"] && i + 1 < args.count) {
            factor = [args[++i] intValue];
        } else if ([a isEqualToString:@"--pos"] && i + 1 < args.count) {
            startPos = [args[++i] doubleValue];
        } else if ([a isEqualToString:@"--sub"] && i + 1 < args.count) {
            // 以前这里只是「跳过」，导致外挂字幕根本没加载
            NSString *sub = args[++i];
            [_pendingSubs addObject:sub];
        } else if ([a isEqualToString:@"--ontop"]) {
            self.alwaysOnTop = YES;
        } else if (![a hasPrefix:@"-"] && !file) {
            file = a;
        }
    }

    if (_alwaysOnTop) [self setWindowOnTop:YES];

    [self setFactor:factor];
    if (file) {
        [self openFile:file];
        if (startPos > 1) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.6 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ [self seekTo:startPos]; });
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    double hb = [[NSUserDefaults standardUserDefaults] doubleForKey:@"holdBoost"];
    _holdBoost = (hb >= 1.75) ? 2.0 : 1.5;     // 没存过就是 1.5
    _anime4kMode = [[NSUserDefaults standardUserDefaults] integerForKey:@"anime4kMode"];
    // 加了「轻量」档后编号整体后移：旧版的 2（2x 超分）要跟着变成 3，
    // 否则老用户升级后会被静默降成「增强」
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"anime4kModeV2"]) {
        if (_anime4kMode >= 2) {
            _anime4kMode += 1;
            [[NSUserDefaults standardUserDefaults] setInteger:_anime4kMode forKey:@"anime4kMode"];
        }
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"anime4kModeV2"];
    }
    if (_anime4kMode < 0 || _anime4kMode > 3) _anime4kMode = 0;
    _aneSR = [[NSUserDefaults standardUserDefaults] boolForKey:@"aneSR"];
    _aneNoise = [[NSUserDefaults standardUserDefaults] integerForKey:@"aneNoise"];
    if (_aneNoise < 0 || _aneNoise > 2) _aneNoise = 0;
    // 章节刻度默认开（没存过就别当成关）
    id cm = [[NSUserDefaults standardUserDefaults] objectForKey:@"chapterMarks"];
    _showChapterMarks = cm ? [cm boolValue] : YES;
    [self setupMpv];
    [self buildWindow];
    [self setupDanmaku];
    [self applyAnime4k];          // 上次选的 Anime4K 模式接着用
    [self applyArguments];

    // LS 可能在 mpv 就绪之前就把文件送进来了（openFiles: 早于本方法）
    if (_pendingFile) {
        NSString *f = _pendingFile;
        _pendingFile = nil;
        NSLog(@"[ANEPlayer] 补开启动早期传入的文件: %@", f);
        [self openFile:f];
    }

    // 把窗口提到最前：从命令行直接启动时（非 LaunchServices 启动），
    // 窗口虽然创建了却会躺在别的窗口后面。
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)n
{
    [_uiTimer invalidate];
    [_hideTimer invalidate];
    [_videoView shutdown];
    if (_mpv) { mpv_terminate_destroy(_mpv); _mpv = NULL; }
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
    [self openFile:filename];
    return YES;
}

/// LaunchServices（双击视频 / open -a / 「打开方式」）走的是复数版，
/// 只实现单数版会导致文件传进来却打不开。
- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames
{
    NSLog(@"[ANEPlayer] openFiles: %@", filenames);
    [self openFileList:filenames];
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

@end

// ── 拖拽接收（挂在 videoView 上）────────────────────────────────────────────

@interface ANEVideoView (Drop) <NSDraggingDestination>
@end
@implementation ANEVideoView (Drop)
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    NSLog(@"[Drop] 视频视图 draggingEntered");
    return NSDragOperationCopy;
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    id del = NSApp.delegate;
    if ([del respondsToSelector:@selector(handleDrop:)]) {
        [del performSelector:@selector(handleDrop:) withObject:sender];
        return YES;
    }
    return NO;
}
@end

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
