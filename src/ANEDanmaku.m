//
//  ANEDanmaku.m
//
//  弹幕层：透明 WKWebView 里跑 niconicomments（来自 iina-plugin-danmaku-cosmos
//  的 overlay 目录，MIT），原生侧负责取弹幕（弹弹play）和时间轴驱动。
//
//  之所以能直接复用插件的渲染层：overlay/main.js 只用 iina.onMessage /
//  iina.postMessage 两个接口，没有任何别 IINA API 依赖，注入一个 10 行的
//  shim 就能跑。
//

#import "ANEDanmaku.h"
#import <WebKit/WebKit.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kDDPAppId     = @"t43832ky57";
static NSString *const kDDPAppSecret = @"IDnPEdEKDIziKeYVxm6VcaJE4Bv2fnzT";
static NSString *const kDDPBase      = @"https://api.dandanplay.net";

// ── 工具 ────────────────────────────────────────────────────────────────────

static NSString *ane_json(id obj)
{
    if (!obj) return @"{}";
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!d) return @"{}";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s ?: @"{}";
}

/// 等价于 JS 的 encodeURIComponent —— overlay 那边用 decodeURIComponent 还原
static NSString *ane_pctEncode(NSString *s)
{
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *b = data.bytes;
    static const char *hex = "0123456789ABCDEF";
    NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        unsigned char c = b[i];
        BOOL keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') ||
                    c == '-' || c == '_' || c == '.' || c == '!' || c == '~' ||
                    c == '*' || c == '\'' || c == '(' || c == ')';
        if (keep) [out appendFormat:@"%c", c];
        else      [out appendFormat:@"%%%c%c", hex[c >> 4], hex[c & 0xF]];
    }
    return out;
}

/// 弹弹play 的文件指纹：前 16MiB 的 MD5（跟插件用的 dd bs=1m count=16 一致）
static NSString *ane_md5Head(NSString *path)
{
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    NSData *head = nil;
    @try { head = [fh readDataOfLength:16 * 1024 * 1024]; } @catch (NSException *e) { head = nil; }
    [fh closeFile];
    if (head.length == 0) return nil;

    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(head.bytes, (CC_LONG)head.length, digest);
#pragma clang diagnostic pop

    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *ane_cacheDir(void)
{
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    NSString *dir = [base stringByAppendingPathComponent:@"ANEPlayer/danmaku"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:NULL];
    return dir;
}

static NSString *ane_cacheKey(NSString *path)
{
    NSData *d = [path dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:40];
    for (int i = 0; i < 12; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/// 弹幕层必须「透明」：hitTest 返回 nil，鼠标事件穿透到下面的视频视图
@interface ANEWebOverlay : WKWebView <NSDraggingDestination>
@property (nonatomic, copy) void (^onFilesDropped)(NSArray<NSString *> *paths);
@end

@implementation ANEWebOverlay
- (NSView *)hitTest:(NSPoint)point { return nil; }

/// 弹幕层盖在视频上面，文件拖进来会先落到它身上；
/// 这里把路径转交给外面，避免「拖了没反应」
- (NSArray<NSString *> *)filePathsFrom:(id<NSDraggingInfo>)sender
{
    NSArray *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class]
                                                             options:nil];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSURL *u in urls) {
        if (u.isFileURL && u.path.length) [out addObject:u.path];
    }
    return out;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
    NSArray *p = [self filePathsFrom:sender];
    NSLog(@"[Drop] 弹幕层 draggingEntered: %lu 个文件", (unsigned long)p.count);
    return p.count ? NSDragOperationCopy : NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
    return [self filePathsFrom:sender].count ? NSDragOperationCopy : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender { }

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender { return YES; }

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
    NSArray<NSString *> *paths = [self filePathsFrom:sender];
    NSLog(@"[Drop] 弹幕层 performDragOperation: %@", paths);
    if (!paths.count) return NO;
    if (self.onFilesDropped) self.onFilesDropped(paths);
    return YES;
}
@end

// ── 弱代理：WKUserContentController 会强引用 handler，避免循环引用 ──────────

@interface ANEWeakShim : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<WKScriptMessageHandler> target;
@end

@implementation ANEWeakShim
- (void)userContentController:(WKUserContentController *)c
      didReceiveScriptMessage:(WKScriptMessage *)m
{
    [self.target userContentController:c didReceiveScriptMessage:m];
}
@end

// ── 主体 ────────────────────────────────────────────────────────────────────

@interface ANEDanmaku () <WKScriptMessageHandler>
@end

@implementation ANEDanmaku {
    WKWebView *_web;
    __weak NSView *_host;
    BOOL _ready;

    // 设置（键名与插件偏好一致）
    BOOL _enabled;
    double _opacity, _fontScale, _strokeWidth, _strokeOpacity;
    double _commentLimit, _scrollSpeed, _offset, _chConvert;
    double _displayArea;     // 弹幕只占画面顶部这么高（1.0 = 全部）
    NSString *_canvasMode, *_strokeColor, *_strokeInversionColor;
    NSString *_fontFamily, *_fontWeight;
    BOOL _autoNetwork, _withRelated;
    NSString *_appId, *_appSecret;

    // 运行状态
    NSString *_loadedPath;
    NSString *_currentPath;      // 当前视频路径（手动搜索的弹幕存到它名下）
    int _lastPaused;
    double _lastSpeed;
    NSURLSession *_session;
    BOOL _pendingLoad;
    NSMutableDictionary<NSString *, NSString *> *_lastSent;   // type → 上次发送的 JSON
    NSString *_pendingJSON;
}

- (instancetype)initWithHostView:(NSView *)host
{
    self = [super init];
    if (!self) return self;
    _host = host;

    // 默认值 = 插件 preferenceDefaults
    _enabled = YES;
    _opacity = 0.8;
    _fontScale = 1.0;
    _strokeWidth = 2.8;
    _strokeOpacity = 0.4;
    _commentLimit = 0;
    _scrollSpeed = 1.0;
    _offset = 0;
    _chConvert = 0;
    _displayArea = 1.0;
    _displayArea = 1.0;
    _canvasMode = @"css";
    _strokeColor = @"#000000";
    _strokeInversionColor = @"#ffffff";
    _fontFamily = @"";
    _fontWeight = @"400";
    _autoNetwork = YES;
    _withRelated = YES;
    _appId = kDDPAppId;
    _appSecret = kDDPAppSecret;
    _lastSpeed = -1;
    _lastPaused = -1;
    _lastSent = [NSMutableDictionary dictionary];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    cfg.timeoutIntervalForResource = 30;
    _session = [NSURLSession sessionWithConfiguration:cfg];

    [self buildWebView];
    return self;
}

/// 注入给 overlay 的 iina 消息接口 shim（overlay 只用到这两个方法）
- (void)buildWebView
{
    static NSString *const kShim =
        @"(function(){"
         "  window.iina = {"
         "    _h: {},"
         "    onMessage: function(t, cb){ (this._h[t] = this._h[t] || []).push(cb); },"
         "    postMessage: function(t, d){"
         "      try { window.webkit.messageHandlers.ane.postMessage({type: t, data: d || {}}); }"
         "      catch(e) {}"
         "    },"
         "    __emit: function(t, d){"
         "      var l = this._h[t] || [];"
         "      for (var i = 0; i < l.length; i++) { try { l[i](d); } catch(e) { console.log(e); } }"
         "    }"
         "  };"
         "  window.onerror = function(m, src, line, col){"
         "    try { iina.postMessage('js-error', {msg: String(m), line: line}); } catch(e) {}"
         "  };"
         "  window.addEventListener('unhandledrejection', function(e){"
         "    try { iina.postMessage('js-error', {msg: 'promise: ' + String(e.reason)}); } catch(e2) {}"
         "  });"
         "})();";

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    WKUserContentController *ucc = [[WKUserContentController alloc] init];

    ANEWeakShim *shim = [[ANEWeakShim alloc] init];
    shim.target = self;
    [ucc addScriptMessageHandler:shim name:@"ane"];
    [ucc addUserScript:[[WKUserScript alloc]
                           initWithSource:kShim
                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                         forMainFrameOnly:YES]];
    cfg.userContentController = ucc;
    cfg.suppressesIncrementalRendering = YES;

    NSRect b = _host ? _host.bounds : NSMakeRect(0, 0, 640, 360);
    _web = [[ANEWebOverlay alloc] initWithFrame:b configuration:cfg];
    _web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _web.wantsLayer = YES;
    _web.layer.backgroundColor = NSColor.clearColor.CGColor;

    // 透明底：CSS 里 body 已经是 background:none，但 WKWebView 自己要单独关掉
    if ([_web respondsToSelector:@selector(setUnderPageBackgroundColor:)]) {
        if (@available(macOS 12.0, *)) _web.underPageBackgroundColor = NSColor.clearColor;
    }
    @try { [_web setValue:@NO forKey:@"drawsBackground"]; } @catch (NSException *e) {}

    _web.hidden = YES;
    __weak typeof(self) wself = self;
    ((ANEWebOverlay *)_web).onFilesDropped = ^(NSArray<NSString *> *paths) {
        ANEDanmaku *me = wself;
        if (me && me.filesDroppedHandler) me.filesDroppedHandler(paths);
    };
    // 自己注册，别让 WebKit 把文件拖拽吞掉（它是 WebView，默认会认文件拖放）
    [_web registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    if (_host) [_host addSubview:_web];

    NSURL *dir = [[NSBundle mainBundle] URLForResource:@"danmaku" withExtension:nil];
    if (dir) {
        NSURL *page = [dir URLByAppendingPathComponent:@"index.html"];
        [_web loadFileURL:page allowingReadAccessToURL:dir];
        NSLog(@"[Danmaku] 加载渲染层 %@", page.path);
    } else {
        NSLog(@"[Danmaku] 找不到 Resources/danmaku，弹幕不可用");
    }
}

// ── JS 通讯 ────────────────────────────────────────────────────────────────

- (void)emitJS:(NSString *)js
{
    if (!_web) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_web evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)emit:(NSString *)type json:(NSString *)json
{
    [self emitJS:[NSString stringWithFormat:@"window.iina&&iina.__emit('%@',%@)",
                  type, json ?: @"{}"]];
}

/// 只在值真的变了才发（按消息类型记上次的 JSON）
- (void)emitOnce:(NSString *)type payload:(NSDictionary *)payload
{
    NSString *json = ane_json(payload);
    if ([_lastSent[type] isEqualToString:json]) return;
    _lastSent[type] = json;
    [self emit:type json:json];
}

- (void)userContentController:(WKUserContentController *)c
      didReceiveScriptMessage:(WKScriptMessage *)m
{
    if (![m.name isEqualToString:@"ane"]) return;
    if (![m.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *body = m.body;
    NSString *type = body[@"type"];
    if (![type isKindOfClass:NSString.class]) return;

    if ([type isEqualToString:@"overlay-ready"]) {
        _ready = YES;
        NSLog(@"[Danmaku] 渲染层就绪");
        [_lastSent removeAllObjects];
        [self pushAllSettings];
        if (_pendingJSON) {           // 渲染层起来之前就取到弹幕了，补发
            NSString *json = _pendingJSON;
            _pendingJSON = nil;
            [self emit:@"load-danmaku" json:json];
        }
    }
    if ([type isEqualToString:@"js-error"]) {
        NSDictionary *d = body[@"data"];
        NSLog(@"[Danmaku][JS] %@ (line %@)", d[@"msg"], d[@"line"]);
        return;
    }
    // seek-disable / seek-enable / jump 是 canvas 可点弹幕用的，这里没有交互，忽略
}

// ── 设置 ────────────────────────────────────────────────────────────────────

- (double)num:(NSDictionary *)d key:(NSString *)k def:(double)def
{
    id v = d[k];
    return v ? [v doubleValue] : def;
}

- (BOOL)flag:(NSDictionary *)d key:(NSString *)k def:(BOOL)def
{
    id v = d[k];
    return v ? [v boolValue] : def;
}

- (NSString *)str:(NSDictionary *)d key:(NSString *)k def:(NSString *)def
{
    id v = d[k];
    return ([v isKindOfClass:NSString.class] && [v length]) ? v : def;
}

- (void)applySettings:(NSDictionary *)p
{
    if (![p isKindOfClass:NSDictionary.class]) return;

    _enabled            = [self flag:p key:@"danmakuEnabled" def:YES];
    _opacity            = [self num:p key:@"danmakuCanvasOpacity" def:0.8];
    _fontScale          = [self num:p key:@"niconicommentsFontScale" def:1.0];
    _strokeWidth        = [self num:p key:@"strokeWidth" def:2.8];
    _strokeOpacity      = [self num:p key:@"strokeOpacity" def:0.4];
    _commentLimit       = [self num:p key:@"commentLimit" def:0];
    _scrollSpeed        = [self num:p key:@"scrollSpeed" def:1.0];
    _offset             = [self num:p key:@"danmakuTimeOffset" def:0];
    _chConvert          = [self num:p key:@"dandanplayChConvert" def:0];
    _blockEnabled       = [self flag:p key:@"danmakuBlockEnabled" def:NO];
    _blockWords         = ([p[@"danmakuBlockWords"] isKindOfClass:NSString.class]
                           ? p[@"danmakuBlockWords"] : @"");
    _dedupeEnabled      = [self flag:p key:@"danmakuDedupe" def:NO];
    _blockExact         = [self flag:p key:@"danmakuBlockExact" def:NO];
    _filterRepeat       = [self flag:p key:@"danmakuFilterRepeat" def:NO];
    _autoNetwork        = [self flag:p key:@"dandanplayAutoNetwork" def:YES];
    _withRelated        = [self flag:p key:@"dandanplayWithRelated" def:YES];
    _canvasMode         = [self str:p key:@"canvasMode" def:@"css"];
    _strokeColor        = [self str:p key:@"strokeColor" def:@"#000000"];
    _strokeInversionColor = [self str:p key:@"strokeInversionColor" def:@"#ffffff"];
    _fontFamily         = ([p[@"danmakuFontFamily"] isKindOfClass:NSString.class]
                           ? p[@"danmakuFontFamily"] : @"");
    _fontWeight         = [self str:p key:@"danmakuFontWeight" def:@"400"];
    _appId              = [self str:p key:@"dandanplayAppId" def:kDDPAppId];
    _appSecret          = [self str:p key:@"dandanplayAppSecret" def:kDDPAppSecret];

    if (!_enabled) {
        _web.hidden = YES;
        [self emit:@"clear-danmaku" json:@"{}"];
        return;
    }
    _web.hidden = NO;
    if (_ready) [self pushAllSettings];
}

/// 把当前设置逐条推给渲染层（幂等，可以反复发）
- (void)pushAllSettings
{
    // 值没变就不重发：渲染层收到 set-* 会整个重建渲染器，连发多条既浪费又容易出问题
    [self emitOnce:@"set-opacity"                payload:@{@"opacity": @(_opacity)}];
    [self emitOnce:@"set-fontscale"              payload:@{@"scale": @(_fontScale)}];
    [self emitOnce:@"set-canvas-mode"            payload:@{@"mode": _canvasMode}];
    [self emitOnce:@"set-stroke-width"           payload:@{@"width": @(_strokeWidth)}];
    [self emitOnce:@"set-stroke-opacity"         payload:@{@"opacity": @(_strokeOpacity)}];
    [self emitOnce:@"set-stroke-color"           payload:@{@"color": _strokeColor}];
    [self emitOnce:@"set-stroke-inversion-color" payload:@{@"color": _strokeInversionColor}];
    [self emitOnce:@"set-comment-limit"          payload:@{@"limit": @(_commentLimit)}];
    [self emitOnce:@"set-scroll-speed"           payload:@{@"speed": @(_scrollSpeed)}];
    [self emitOnce:@"set-danmaku-offset"         payload:@{@"offset": @(_offset)}];
    [self emitOnce:@"set-danmaku-font"           payload:@{@"fontFamily": _fontFamily,
                                                           @"fontWeight": _fontWeight}];
    [self emitOnce:@"toggle-danmaku"             payload:@{@"enabled": @(_enabled)}];
    [self emitOnce:@"set-display-area"           payload:@{@"ratio": @(_displayArea)}];
    [self emitOnce:@"set-danmaku-filter"         payload:@{@"block": @(_blockEnabled),
                                                           @"words": _blockWords ?: @"",
                                                           @"exact": @(_blockExact),
                                                           @"repeat": @(_filterRepeat),
                                                           @"dedupe": @(_dedupeEnabled)}];
}

// ── 布局 ────────────────────────────────────────────────────────────────────

- (NSView *)webView { return _web; }

/// 弹幕只占画面顶部这么高（1.0 = 全部）
- (void)setDisplayAreaRatio:(double)ratio
{
    if (ratio <= 0) ratio = 1.0;
    if (fabs(ratio - _displayArea) < 0.001) return;
    _displayArea = ratio;
    [self emit:@"set-display-area" json:ane_json(@{@"ratio": @(ratio)})];
}

- (void)setContentRect:(NSRect)rect
{
    if (!_web || !_host) return;
    if (NSWidth(rect) < 2 || NSHeight(rect) < 2) return;
    NSRect cur = _web.frame;
    if (NSEqualRects(cur, rect)) return;
    _web.frame = rect;
    [self emit:@"resize" json:@"{}"];
}

// ── 时间轴 ──────────────────────────────────────────────────────────────────

- (void)updateTime:(double)pos duration:(double)dur paused:(BOOL)paused speed:(double)speed
{
    if (!_enabled || !_ready) return;
    if ((paused ? 1 : 0) != _lastPaused) {
        _lastPaused = paused ? 1 : 0;
        [self emit:@"pause-state" json:ane_json(@{@"paused": @(paused)})];
    }
    if (fabs(speed - _lastSpeed) > 0.001) {
        _lastSpeed = speed;
        [self emit:@"playback-speed" json:ane_json(@{@"speed": @(speed)})];
    }
    [self emit:@"time-update" json:ane_json(@{@"time": @(pos)})];
}

- (void)reloadForVideo:(NSString *)path duration:(double)duration purgeCache:(BOOL)purge
{
    if (purge && path.length) {
        NSString *cachePath = [ane_cacheDir() stringByAppendingPathComponent:
                               [ane_cacheKey(path) stringByAppendingPathExtension:@"json"]];
        [[NSFileManager defaultManager] removeItemAtPath:cachePath error:NULL];
    }
    _loadedPath = nil;
    [self loadForVideo:path duration:duration];
}

- (void)clear
{
    _loadedPath = nil;        // 清空后允许同一部片重新加载
    [_lastSent removeAllObjects];
    _pendingJSON = nil;
    [self emit:@"clear-danmaku" json:@"{}"];
}

// ── 取弹幕 ──────────────────────────────────────────────────────────────────

- (void)loadForVideo:(NSString *)path duration:(double)duration
{
    if (!path.length) return;
    _currentPath = path;
    if ([path isEqualToString:_loadedPath]) return;
    _loadedPath = path;
    _pendingJSON = nil;

    if (!_enabled || !_autoNetwork) {
        [self emit:@"clear-danmaku" json:@"{}"];
        if (!_autoNetwork) [self reportStatus:@"未开启联网匹配"];
        return;
    }

    // 1) 缓存命中（同一部片第二次打开不再请求网络）
    NSString *cachePath = [ane_cacheDir() stringByAppendingPathComponent:
                           [ane_cacheKey(path) stringByAppendingPathExtension:@"json"]];
    NSData *cached = [NSData dataWithContentsOfFile:cachePath];
    if (cached) {
        id obj = [NSJSONSerialization JSONObjectWithData:cached options:0 error:NULL];
        if ([obj isKindOfClass:NSDictionary.class] && obj[@"comments"]) {
            [self deliver:obj[@"comments"] title:obj[@"title"] cacheTo:nil];
            return;
        }
    }

    // 2) 联网：算指纹 → 匹配 → 取弹幕
    NSString *fileName = path.lastPathComponent.stringByDeletingPathExtension;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *hash = ane_md5Head(path);
        unsigned long long size = 0;
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if (attr) size = [attr fileSize];

        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        body[@"fileName"] = fileName;
        body[@"fileHash"] = hash ?: @"00000000000000000000000000000000";
        body[@"fileSize"] = @(hash ? size : 0);
        body[@"videoDuration"] = @(0);
        body[@"matchMode"] = hash ? @"hashAndFileName" : @"fileNameOnly";

        [self request:@"POST" path:@"/api/v2/match" query:nil body:body
           completion:^(id json) {
            NSNumber *epId = nil;
            NSString *title = nil;
            if ([json isKindOfClass:NSDictionary.class]) {
                if ([json[@"isMatched"] boolValue] && json[@"match"]) {
                    epId = json[@"match"][@"episodeId"];
                    title = [NSString stringWithFormat:@"%@ %@", json[@"match"][@"animeTitle"] ?: @"",
                             json[@"match"][@"episodeTitle"] ?: @""];
                } else if ([json[@"matches"] isKindOfClass:NSArray.class] &&
                           [json[@"matches"] count] > 0) {
                    NSDictionary *m = json[@"matches"][0];
                    epId = m[@"episodeId"];
                    title = [NSString stringWithFormat:@"%@ %@", m[@"animeTitle"] ?: @"",
                             m[@"episodeTitle"] ?: @""];
                }
            }
            if (!epId) { [self reportStatus:@"未匹配到弹幕"]; return; }

            NSString *q = [NSString stringWithFormat:
                           @"/api/v2/comment/%@", epId];
            NSDictionary *query = @{ @"withRelated": _withRelated ? @"true" : @"false",
                                     @"chConvert": [NSString stringWithFormat:@"%.0f", _chConvert] };
            [self request:@"GET" path:q query:query body:nil completion:^(id cj) {
                NSArray *raw = ([cj isKindOfClass:NSDictionary.class] &&
                                [cj[@"comments"] isKindOfClass:NSArray.class])
                               ? cj[@"comments"] : @[];
                NSArray *list = [self convertComments:raw];
                NSString *cache = [ane_cacheDir() stringByAppendingPathComponent:
                                   [ane_cacheKey(path) stringByAppendingPathExtension:@"json"]];
                [self deliver:list title:title cacheTo:cache];
            }];
        }];
    });
}

- (void)deliver:(NSArray *)list title:(NSString *)title cacheTo:(NSString *)cachePath
{
    NSArray *comments = [list isKindOfClass:NSArray.class] ? list : @[];

    if (cachePath && comments.count) {
        NSDictionary *cacheObj = @{ @"title": title ?: @"",
                                    @"comments": comments };
        NSData *d = [NSJSONSerialization dataWithJSONObject:cacheObj options:0 error:NULL];
        [d writeToFile:cachePath atomically:YES];
    }

    if (!comments.count) {
        [self reportStatus:@"这部片子没有弹幕"];
        return;
    }

    NSData *jd = [NSJSONSerialization dataWithJSONObject:comments options:0 error:NULL];
    NSString *jsonText = jd ? [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding] : @"[]";
    NSString *encoded = ane_pctEncode(jsonText ?: @"[]");

    NSDictionary *payload = @{
        @"xmlContent": encoded,
        @"danmakuType": @"dandanplay",
        // 同一条消息里带上设置，渲染层会顺手应用（applyOverlaySettings）
        @"opacity": @(_opacity),
        @"canvasFontScale": @(_fontScale),
        @"canvasMode": _canvasMode,
        @"strokeColor": _strokeColor,
        @"strokeInversionColor": _strokeInversionColor,
        @"strokeOpacity": @(_strokeOpacity),
        @"strokeWidth": @(_strokeWidth),
        @"commentLimit": @(_commentLimit),
        @"scrollSpeed": @(_scrollSpeed),
        @"danmakuTimeOffsetSec": @(_offset),
        @"danmakuFontFamily": _fontFamily ?: @"",
        @"danmakuFontWeight": _fontWeight ?: @"400",
        @"fixedCombo": @(_dedupeEnabled),
        @"nakaDedupeWindow": _dedupeEnabled ? @300 : @0,
        @"danmakuBlockEnabled": @(_blockEnabled),
        @"danmakuBlockWords": _blockWords ?: @"",
        @"danmakuBlockExact": @(_blockExact),
        @"danmakuFilterRepeat": @(_filterRepeat),
        @"danmakuDedupe": @(_dedupeEnabled),
    };
    NSString *payloadJSON = ane_json(payload);

    if (_ready) {
        [self emit:@"load-danmaku" json:payloadJSON];
    } else {
        _pendingJSON = payloadJSON;      // 页面还没起，等 overlay-ready 再补
    }

    NSString *t = title.length ? title : @"弹幕";
    [self reportStatus:[NSString stringWithFormat:@"%@ · %lu 条",
                        t, (unsigned long)comments.count]];
}

/// 弹弹play 的 {p: "时间,模式,颜色,uid", m: "内容"} → overlay 需要的格式
- (NSArray *)convertComments:(NSArray *)raw
{
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSDictionary *c in raw) {
        if (![c isKindOfClass:NSDictionary.class]) continue;
        NSString *p = c[@"p"], *text = c[@"m"];
        if (![p isKindOfClass:NSString.class] || ![text isKindOfClass:NSString.class]) continue;

        NSArray *parts = [p componentsSeparatedByString:@","];
        if (parts.count < 3) continue;

        double timeSec = [parts[0] doubleValue];
        int mode = [parts[1] intValue];
        long long colorDec = [parts[2] longLongValue];
        if (mode < 1 || mode > 6) continue;
        if (colorDec < 0) colorDec &= 0xFFFFFF;

        NSMutableArray *cmds = [NSMutableArray array];
        if (mode == 4)      [cmds addObject:@"shita"];
        else if (mode == 5) [cmds addObject:@"ue"];
        else                [cmds addObject:@"naka"];
        [cmds addObject:[NSString stringWithFormat:@"#%06llx", colorDec]];

        NSInteger uid = parts.count > 3 ? [parts[3] integerValue] : 0;

        [out addObject:@{
            @"t": @((long long)llround(timeSec * 100)),   // vpos，单位 1/100 秒
            @"text": text,
            @"_isOwner": @NO,
            @"_commands": cmds,
            @"_userId": @(llabs(uid)),
            @"_dateSec": @1767196800,
        }];
    }
    return out;
}

// ── 手动搜索 ────────────────────────────────────────────────────────────────

- (void)searchAnime:(NSString *)keyword completion:(void (^)(NSArray<NSDictionary *> *))done
{
    if (!keyword.length) { if (done) done(@[]); return; }
    NSDictionary *q = @{ @"keyword": keyword };
    [self request:@"GET" path:@"/api/v2/search/anime" query:q body:nil completion:^(id json) {
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        NSArray *animes = ([json isKindOfClass:NSDictionary.class] &&
                           [json[@"animes"] isKindOfClass:NSArray.class]) ? json[@"animes"] : @[];
        for (NSDictionary *a in animes) {
            if (![a isKindOfClass:NSDictionary.class]) continue;
            NSMutableString *sub = [NSMutableString string];
            if ([a[@"typeDescription"] isKindOfClass:NSString.class])
                [sub appendString:a[@"typeDescription"]];
            NSString *date = a[@"startDate"];
            if ([date isKindOfClass:NSString.class] && date.length >= 4)
                [sub appendFormat:@"%@%@年", sub.length ? @" · " : @"", [date substringToIndex:4]];
            [out addObject:@{ @"id": a[@"animeId"] ?: @0,
                              @"title": a[@"animeTitle"] ?: @"",
                              @"sub": sub }];
        }
        NSLog(@"[Danmaku] 搜索「%@」→ %lu 部", keyword, (unsigned long)out.count);
        if (done) done(out);
    }];
}

- (void)fetchEpisodes:(NSNumber *)animeId completion:(void (^)(NSArray<NSDictionary *> *))done
{
    NSString *path = [NSString stringWithFormat:@"/api/v2/bangumi/%@", animeId ?: @0];
    [self request:@"GET" path:path query:nil body:nil completion:^(id json) {
        NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
        NSDictionary *b = ([json isKindOfClass:NSDictionary.class] &&
                           [json[@"bangumi"] isKindOfClass:NSDictionary.class]) ? json[@"bangumi"] : nil;
        NSArray *eps = [b[@"episodes"] isKindOfClass:NSArray.class] ? b[@"episodes"] : @[];
        for (NSDictionary *e in eps) {
            if (![e isKindOfClass:NSDictionary.class]) continue;
            [out addObject:@{ @"id": e[@"episodeId"] ?: @0,
                              @"title": e[@"episodeTitle"] ?: @"" }];
        }
        NSLog(@"[Danmaku] 剧集 %lu 集", (unsigned long)out.count);
        if (done) done(out);
    }];
}

- (void)loadEpisode:(NSNumber *)episodeId title:(NSString *)title
{
    if (!episodeId) return;
    NSString *path = [NSString stringWithFormat:@"/api/v2/comment/%@", episodeId];
    NSDictionary *q = @{ @"withRelated": _withRelated ? @"true" : @"false",
                         @"chConvert": [NSString stringWithFormat:@"%.0f", _chConvert] };
    NSString *videoPath = _currentPath;
    [self request:@"GET" path:path query:q body:nil completion:^(id json) {
        NSArray *raw = ([json isKindOfClass:NSDictionary.class] &&
                        [json[@"comments"] isKindOfClass:NSArray.class]) ? json[@"comments"] : @[];
        NSArray *list = [self convertComments:raw];
        NSString *cache = nil;
        if (videoPath.length) {
            cache = [ane_cacheDir() stringByAppendingPathComponent:
                     [ane_cacheKey(videoPath) stringByAppendingPathExtension:@"json"]];
        }
        [self deliver:list title:title cacheTo:cache];
    }];
}

// ── HTTP ────────────────────────────────────────────────────────────────────

- (void)request:(NSString *)method
           path:(NSString *)path
          query:(NSDictionary *)query
           body:(NSDictionary *)body
     completion:(void (^)(id json))done
{
    NSURLComponents *comp = [NSURLComponents componentsWithString:
                             [kDDPBase stringByAppendingString:path]];
    if (query.count) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *k in query) {
            [items addObject:[NSURLQueryItem queryItemWithName:k value:query[k]]];
        }
        comp.queryItems = items;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:comp.URL];
    req.HTTPMethod = method;
    [req setValue:_appId forHTTPHeaderField:@"X-AppId"];
    [req setValue:_appSecret forHTTPHeaderField:@"X-AppSecret"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"ANEPlayer/1.0" forHTTPHeaderField:@"User-Agent"];
    if (body) {
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }

    [[_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp,
                                                           NSError *err) {
        id json = nil;
        if (data.length) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (err) NSLog(@"[Danmaku] %@ %@ 失败: %@", method, path, err.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(json); });
    }] resume];
}

- (void)reportStatus:(NSString *)text
{
    NSLog(@"[Danmaku] %@", text);
    void (^h)(NSString *) = _statusHandler;
    if (!h) return;
    dispatch_async(dispatch_get_main_queue(), ^{ h(text); });
}

@end
