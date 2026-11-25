//
//  ANEDanmaku.h
//  原生弹幕层：透明 WKWebView 承载 niconicomments 渲染器 + 弹弹play 取弹幕
//

#import <Cocoa/Cocoa.h>

@interface ANEDanmaku : NSObject

/// host 一般是 window.contentView；弹幕层会作为它的子视图加进去
- (instancetype)initWithHostView:(NSView *)host;

/// 视频实际显示区域（去掉黑边后的矩形），窗口变化时重算
- (void)setContentRect:(NSRect)rect;
- (void)setDisplayAreaRatio:(double)ratio;

/// 键名沿用插件偏好（danmakuEnabled / danmakuCanvasOpacity / …），传进来即生效
- (void)applySettings:(NSDictionary *)prefs;

/// 换片时调用：清掉旧弹幕，按路径查缓存或联网匹配
- (void)loadForVideo:(NSString *)path duration:(double)duration;

/// 每 0.1s 左右喂一次时间，弹幕靠它对齐
- (void)updateTime:(double)pos duration:(double)dur paused:(BOOL)paused speed:(double)speed;

/// 强制重取（改繁简转换/关联弹幕时用）；purgeCache 会删掉该片的本地缓存
- (void)reloadForVideo:(NSString *)path duration:(double)duration purgeCache:(BOOL)purge;

- (void)clear;

// ── 手动搜索（弹弹play）──────────────────────────────────────────────────
/// 按关键字搜番剧，回调 [{id, title, sub}]
- (void)searchAnime:(NSString *)keyword completion:(void (^)(NSArray<NSDictionary *> *items))done;
/// 拉某部番的剧集列表，回调 [{id, title}]
- (void)fetchEpisodes:(NSNumber *)animeId completion:(void (^)(NSArray<NSDictionary *> *items))done;
/// 手动指定某集，取它的弹幕挂到当前视频上（并写进当前视频的缓存）
- (void)loadEpisode:(NSNumber *)episodeId title:(NSString *)title;

/// 屏蔽词（含这些词的弹幕不渲染）与同文去重
@property (nonatomic) BOOL blockEnabled;
@property (nonatomic, copy) NSString *blockWords;
@property (nonatomic) BOOL dedupeEnabled;
@property (nonatomic) BOOL blockExact;
@property (nonatomic) BOOL filterRepeat;

/// 弹幕层的视图（用来安排 z 序：它只该盖住视频，不能盖住控制条/面板）
@property (nonatomic, readonly) NSView *webView;

/// 用户把文件拖进弹幕层时回调（弹幕层盖住了视频，拖放要在这里接）
@property (nonatomic, copy) void (^filesDroppedHandler)(NSArray<NSString *> *paths);

/// 状态文案（"已匹配：xxx 第1话 · 131 条" / "未匹配到弹幕"），主线程回调
@property (nonatomic, copy) void (^statusHandler)(NSString *text);

@end
