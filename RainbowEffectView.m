#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
#import "RKNeonPress.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "RKPreferences.h"
#import "RKThemeEngine.h"
#import "RKAdaptivePerformance.h"
static NSDictionary *RKReadPreferences(void) {
    return RKThemeMergedPreferences(RKReadEffectivePreferences());
}

@class RainbowEffectView;
static void RKEffectPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    RainbowEffectView *view = (__bridge RainbowEffectView *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view) [view reloadConfiguration];
    });
}
// P1-3: 每个键位的波纹几何（frame/路径）只依赖键位矩形与 rimWidth 两档，
// 预构建后每次按键直接复用，避免逐键重建 path 与坐标变换。
@interface RKKeyWaveGeometry : NSObject
@property(nonatomic) CGRect edgeFrame;
@property(nonatomic, strong) UIBezierPath *outline; // 已平移到 edgeFrame 坐标系
@property(nonatomic, strong) UIBezierPath *outer;   // 圆角外框 ∪ outline（EvenOdd 环带）
@end
@implementation RKKeyWaveGeometry
@end

// ---- 层驱逐按「效果分组」进行（2.3.26）------------------------------------------
// 键底光效（波纹/扩散/流光）与轻弹（键帽上色）都往 self.layer 上挂自己的层，而此前
// 两者的驱逐写的是同一句话：`while (sublayers.count >= limit) [firstObject removeFromSuperlayer]`。
// 计数池共用，于是叠加时每按一次键净增两层，池子更快触顶 —— 后按下的轻弹会把仍在
// 扩散途中的波纹层一并踢掉，表现为「开着轻弹，波纹扩到一半就停住」。
// 现在按层名归类：各自只数自己那一类，超限只驱逐同类里最早的一层，两组互不干扰。
// 语义与原来一致：添加前保证「同类层数 < limit」。
static void RKEvictLayersByName(NSArray<CALayer *> *sublayers,
                                NSSet<NSString *> *names, NSUInteger limit) {
    if (!limit || !sublayers.count) return;
    NSMutableArray<CALayer *> *owned = [NSMutableArray array];
    for (CALayer *layer in sublayers) {
        NSString *name = layer.name;
        if (name && [names containsObject:name]) [owned addObject:layer];
    }
    while (owned.count >= limit) {
        [owned.firstObject removeFromSuperlayer];
        [owned removeObjectAtIndex:0];
    }
}
// 键底光效组：波纹 / 扩散 / 原生扩散 / 流光底韵四种风格共用一个预算。
static NSSet<NSString *> *RKBedEffectLayerNames(void) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"RKBedRipples", @"RKBedSpread",
                                      @"RKNativeWeTypeSpread", @"RKExpandingUnderlight"]];
    });
    return names;
}
// 轻弹组：neonKeyPress 为现用名，RKFastInputFeedback 是旧版遗留，一并纳入以便清理。
static NSSet<NSString *> *RKKeycapFeedbackLayerNames(void) {
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithArray:@[@"neonKeyPress", @"RKFastInputFeedback"]];
    });
    return names;
}

@interface RainbowEffectView ()
@property(nonatomic,strong) NSDictionary *config;
@property(nonatomic,strong) UIImage *underlightMaskImage;
@property(nonatomic) CGRect underlightMaskBounds;
@property(nonatomic) BOOL underlightMaskIncludesNativeFaces;
@property(nonatomic) CGFloat hue;
@property(nonatomic) CGFloat pressHue;
@property(nonatomic) NSInteger lastStyle;
@property(nonatomic,strong) NSArray<UIBezierPath *> *cachedFacePaths;
@property(nonatomic,strong) NSArray<NSValue *> *cachedCenters;
@property(nonatomic,strong) NSArray<RKKeyWaveGeometry *> *cachedWaveGeometries;
// 键位表的副产品（随 keyFrames 一起重建，见 setKeyFrames:）：
// 整表包围盒，喂键床遮罩/床底几何（绘制必需，与命中无关 —— 命中只看微信的 touch.view）。
@property(nonatomic) CGRect keyBedBounds;
// 原生键缝遮罩的合并路径缓存：只依赖「键区包围盒 + 本视图 bounds + 键面路径集合」，
// 三者任一变化才重建；setKeyFrames: 会主动置空（bounds 相同但键面不同的场景，如
// 全键盘 ↔ 数字键盘切换，光看 bounds 是判不出来的）。
@property(nonatomic,strong) UIBezierPath *cachedGutterMaskPath;
@property(nonatomic) CGRect cachedGutterMaskPathBounds;
// 命中解析的记忆化（一拍一算）：同一次按键会经「键底光效」与「轻弹」两条路各解析一次，
// 两者的落点与微信快照完全相同 ⇒ 第二次直接复用，不重复解析。
// key = (微信快照矩形, 落点)：这两者相同则结果必然相同（解析是纯函数）。
// 快照为空时不参与缓存 —— 那种情况要走 sourceView 兜底，结果还依赖 sourceView，key 不完整。
@property(nonatomic) CGRect cachedResolveTouchRect;
@property(nonatomic) CGPoint cachedResolvePoint;
@property(nonatomic) CGRect cachedResolveResult;
@end

// ---- 微信自己的命中结果（2.3.28 起；2.3.32 起成为唯一主路径）----------------------
// 「按了键，光却落在别的键上」这种问题，第一嫌疑永远是**我们自己的命中判定**，
// 而不是采集规则。2.3.24~2.3.31 追了好几版的真凶就是索引化优化丢掉的不变量：
// 覆盖支只做「行 bounds 的 y 粗筛 + 只看 x 找键」，漏了「落点也在该键 y 范围内」，
// 末行落点被上一行那把被撑大的行 bounds 放行，只比 x 就命中了同列的 7/8/9。
// （⛔ 期间两版怀疑过「空格条没进键位表 / 太大被 0.9×宿主宽杀掉」——**都是错的**，
//   2.3.31 实机探针证明空格一直在表里：`R=139,171 153x50`，宽 153pt 仅占宿主宽 37%。）
//
// 微信自己一直握着正确答案：touch.view 是它重写过的 hitTest 选中的那个视图，
// 即「微信认为这一下打在了哪个按钮上」。轻弹那条路本来就在用它 —— RKShowNeonKeyPress
// 的 sourceView 入参就是靠它渲染键帽字形，说明它在微信输入法下确实是键视图。
// 这里把同一份信息用在命中判定上：沿 touch.view 的祖先链取最近的一个「尺寸像一块键」
// 的视图，直接用它的矩形。
// 只取最近（最靠内）的一个：再往上就是键行 / 键区容器，整行宽会被下面的上限挡掉。
// 实机 130 条样本：这条路 100% 给出答案（含一例落点在表矩形外 2pt、表给不出而它给对的）。
static CGRect RKKeyRectFromSourceView(UIView *source, UIView *host, CGPoint point) {
    if (!source || !host) return CGRectNull;
    CGRect bounds = host.bounds;
    CGFloat maxHeight = MIN(160, bounds.size.height * .8);
    UIView *rowContainer = nil;
    for (UIView *view = source; view && view != host; view = view.superview) {
        // 撞到排除类说明这条链已经不是键了（正常情况下 host 判定已挡掉，这里再兜一道）。
        if (RKKeyboardExcludedView(view)) break;
        // 键帽内部的文字 / 图标子视图：它们的 frame 只是字形，不是键。
        if ([view isKindOfClass:UILabel.class] || [view isKindOfClass:UIImageView.class]) continue;
        CGRect rect = [view convertRect:view.bounds toView:host];
        if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
            !isfinite(rect.size.width) || !isfinite(rect.size.height)) continue;
        // 判据刻意比采集规则（RKValidKeyRect）**宽松**：这里要的是「微信认定的可点区域」，
        // 不是「本插件采集到的键帽视觉矩形」，所以不套 ≤ 宿主宽 × 0.9 那条闸。
        if (rect.size.width < 10 || rect.size.height < 14) continue;
        // 比一行还高 ⇒ 已经是键区/键盘容器，再往上只会更大，收工。
        if (rect.size.height > maxHeight) break;
        // 占满整行 ⇒ 这是「键行容器」而非键（微信九宫格末行把空格等并进一条行视图）。
        // 不能采信行矩形，改为在这一条行视图内部找「包含落点的最小视图」。
        if (rect.size.width >= bounds.size.width * .97) { rowContainer = view; break; }
        if (!CGRectContainsRect(CGRectInset(bounds, -1, -1), rect)) continue;
        return rect;
    }
    if (rowContainer) {
        UIView *best = nil;
        CGFloat bestArea = CGFLOAT_MAX;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:rowContainer];
        NSUInteger guard = 0;
        while (stack.count && guard++ < 200) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if (view != rowContainer && (view.hidden || view.alpha < .01)) continue;
            if (view != rowContainer && [view isKindOfClass:UILabel.class]) continue;
            CGRect rect = [view convertRect:view.bounds toView:host];
            if (view != rowContainer && rect.size.width >= 10 && rect.size.height >= 14 &&
                rect.size.height <= maxHeight && CGRectContainsPoint(rect, point)) {
                CGFloat area = rect.size.width * rect.size.height;
                if (area < bestArea) { bestArea = area; best = view; }
            }
            for (UIView *sub in view.subviews) [stack addObject:sub];
        }
        if (best) return [best convertRect:best.bounds toView:host];
    }
    return CGRectNull;
}

// 2.3.30：给 Tweak.xm 在「触摸刚发生」那一刻调用的导出包装。
// 那时 touch.view 一定有效；错过那一刻，九宫格末行这类运行时合并出来的键视图
// 就可能已经被重建（UITouch.view 与我们的 pending 都持不住它）。
CGRect RKKeyRectForTouchView(UIView *sourceView, UIView *host, CGPoint point) {
    return RKKeyRectFromSourceView(sourceView, host, point);
}

@implementation RainbowEffectView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        _touchKeyRect = CGRectNull;
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadConfiguration) name:UIApplicationDidBecomeActiveNotification object:nil];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self),
            RKEffectPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        [self reloadConfiguration];
    }
    return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)(self),
        CFSTR("com.minis.rainbowkeyboard.changed"), NULL);
}
- (void)reloadConfiguration {
    NSDictionary *newConfig = RKReadPreferences();
    if (!newConfig) newConfig = @{};
    self.config = newConfig;
    RKAdaptiveSetEnabled(!newConfig[@"SmartPerformance"] || [newConfig[@"SmartPerformance"] boolValue]);
    // 装饰关闭时立刻自清：扔掉自己的图层并隐藏，不在键盘上留一个空叠加层
    //（重新打开时再显示，视图树位置不动，无需跨文件清理 Tweak.xm 的关联对象）。
    BOOL on = [self flag:@"Enabled"] && [self flag:@"RippleEnabled"] &&
        [self flag:RKKeyboardBundleIsWeType() ? @"WeChatKeyboard" : @"NativeKeyboard"];
    if (!on) for (CALayer *layer in self.layer.sublayers.copy) [layer removeFromSuperlayer];
    self.hidden = !on;
}
- (CGFloat)number:(NSString *)key fallback:(CGFloat)fallback low:(CGFloat)low high:(CGFloat)high {
    id x = self.config[key];
    CGFloat v = [x respondsToSelector:@selector(doubleValue)] ? [x doubleValue] : fallback;
    CGFloat result = isfinite(v) ? MIN(high,MAX(low,v)) : fallback;
    NSInteger level = RKAdaptiveLevel();
    if (level) {
        if ([key isEqualToString:@"MaxEffects"]) result = MIN(result, level == 1 ? 2 : 1);
        if ([key isEqualToString:@"Duration"] || [key isEqualToString:@"BackgroundDuration"])
            result = MIN(result, level == 1 ? 0.35 : 0.22);
        if ([key isEqualToString:@"BackgroundRadius"]) result = MIN(result, 110);
    }
    return result;
}
- (BOOL)flag:(NSString *)key {
    if (RKAdaptiveLevel() && ([key isEqualToString:@"AmbientGlow"] || [key isEqualToString:@"BackgroundFeedback"])) return NO;
    return !self.config[key] || [self.config[key] boolValue];
}
- (CGFloat)neonSaturation:(CGFloat)base {
    return base * [self number:@"NeonSaturation" fallback:.72 low:0 high:1];
}
// 有效轻弹 = 轻弹开关 合成「跟随系统深浅色」。
// 读序按开销从低到高：存储的轻弹开关为关就直接返回（跟随关闭时零额外开销，
// 与 2.3.26 的判据逐位等价）；开了才继续看跟随开关，跟随时才读 traitCollection。
- (BOOL)effectiveLightPop {
    if (![self.config[@"LightPop"] boolValue]) return NO;
    if (![self.config[@"LightPopFollowAppearance"] boolValue]) return YES;
    // 深色模式自动关掉键帽上色，只留键底光效；浅色模式按用户的轻弹设置走。
    // 只改本拍的渲染判据，不写偏好 —— 系统外观切回来即自动恢复。
    return self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleDark;
}
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection.userInterfaceStyle == self.traitCollection.userInterfaceStyle) return;
    // 系统深浅色切换（键盘窗口还开着时立刻生效，不用等下一次按键）：
    // 深色下必须主动撤掉已渲染的键帽上色层 —— 长动画层走完不会自己离开 sublayers，
    // 只能靠显式清理或驱逐。风格戳同步对齐到新组合，免得下一拍再整体清一遍
    // 正在扩散的键底光效。
    NSInteger style = (NSInteger)[self number:@"EffectStyle" fallback:0 low:0 high:3];
    if (style == 2) style = 1;
    BOOL lightPop = [self effectiveLightPop];
    self.lastStyle = style * 2 + (lightPop ? 1 : 0);
    if (!lightPop) [self clearLegacyKeycapFeedback];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // Old animations must not float over a new keyboard after rotation/resizing.
    for (CALayer *pulse in self.layer.sublayers.copy) {
        if (!CGRectEqualToRect(pulse.frame, self.bounds)) [pulse removeFromSuperlayer];
    }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) for (CALayer *pulse in self.layer.sublayers.copy) [pulse removeFromSuperlayer];
}
- (void)setKeyFrames:(NSArray<NSValue *> *)keyFrames {
    if ([_keyFrames isEqualToArray:keyFrames]) return;
    _keyFrames = [keyFrames copy];
    self.underlightMaskImage = nil;
    // 键面集合变了，键缝遮罩的合并路径必须重建（bounds 可能没变，判不出来）。
    self.cachedGutterMaskPath = nil;
    NSMutableArray *faces = [NSMutableArray arrayWithCapacity:_keyFrames.count];
    NSMutableArray *centers = [NSMutableArray arrayWithCapacity:_keyFrames.count];
    NSMutableArray *geometries = [NSMutableArray arrayWithCapacity:_keyFrames.count * 2];
    for (NSValue *value in _keyFrames) {
        CGRect rect = value.CGRectValue;
        [faces addObject:RKKeyboardKeyFacePath(rect)];
        [centers addObject:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect))]];
        UIBezierPath *facePath = RKKeyboardKeyFacePath(rect);
        CGRect face = facePath.bounds;
        // 两档 rimWidth：普通 2.6（偶数下标）、按压 3.0（奇数下标）。
        for (NSUInteger i = 0; i < 2; i++) {
            CGFloat rim = i == 1 ? 3.0 : 2.6;
            RKKeyWaveGeometry *geometry = [RKKeyWaveGeometry new];
            CGRect edgeFrame = CGRectInset(face, -rim, -rim);
            UIBezierPath *outline = [facePath copy];
            [outline applyTransform:CGAffineTransformMakeTranslation(-edgeFrame.origin.x, -edgeFrame.origin.y)];
            CGFloat corner = MIN(5, MIN(face.size.width, face.size.height) * .16);
            UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:edgeFrame cornerRadius:corner + rim];
            [outer appendPath:outline];
            geometry.edgeFrame = edgeFrame;
            geometry.outline = outline;
            geometry.outer = outer;
            [geometries addObject:geometry];
        }
    }
    self.cachedFacePaths = faces;
    self.cachedCenters = centers;
    self.cachedWaveGeometries = geometries;
    // 键床包围盒与键位表同生命周期：布局一变就重建，按键路径只读不建。
    CGRect bed = CGRectNull;
    for (NSValue *value in _keyFrames) bed = CGRectUnion(bed, value.CGRectValue);
    self.keyBedBounds = bed;
    for (CALayer *pulse in self.layer.sublayers.copy) [pulse removeFromSuperlayer];
}
// 注：原 addAmbientGlowToPulse:（背景光晕/背景扩散）于 2.3.17 删除 ——
// 该方法全项目零调用，与之配套的「背景光晕」「背景扩散」两个开关是死开关，
// 已一并从高级设置移除；它当时独占的 keyGutterMask 方法与同名路径缓存同批删掉。
// 2.3.26 给「原生键缝遮罩」另加了路径缓存，属性名取 cachedGutterMaskPath 以作区分。
// Only positively identified native layouts may illuminate key faces.
// WeType keeps its existing cut-out mask, even if a native-looking view exists.
- (BOOL)usesNativeKeycapGlow {
    if (RKKeyboardBundleIsWeType()) return NO;
    for (UIView *v = self.superview; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if (RKClassFeatures(v.class) & RKFeatureLayoutStar) return YES;
    }
    return NO;
}

// Conservative native nine-key detection: never change WeType's mask.
- (BOOL)usesNativeNineKeyBed {
    if (RKKeyboardBundleIsWeType()) return NO;
    BOOL native = NO;
    for (UIView *v = self.superview; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if (RKClassFeatures(v.class) & RKFeatureLayoutStar) { native = YES; break; }
    }
    if (!native || self.keyFrames.count < 9 || self.keyFrames.count > 25) return NO;
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return NO;
    NSUInteger broadKeys = 0;
    for (NSValue *value in self.keyFrames) {
        CGRect r = value.CGRectValue;
        if (r.size.width >= width*.14 && r.size.width <= width*.30 &&
            r.size.height >= 25 && r.size.height <= 85) broadKeys++;
    }
    return broadKeys >= 8;
}

// Native keys need a separate luminous bed: a full-bed mask alone makes the
// much larger key faces dominate the thin seams, especially on nine-key.
// Keep this inside the existing pulse so both regions share its fade/limits.
- (CALayer *)nativeGutterMask {
    if (!self.keyFrames.count) return nil;
    // 键区包围盒随键位表缓存（见 setKeyFrames:），此处不再逐键求并集。
    CGRect bed = self.keyBedBounds;
    CGRect area = CGRectIntersection(CGRectInset(bed,-3,-4),self.bounds);
    if (CGRectIsNull(area) || CGRectIsEmpty(area)) return nil;
    // 合并路径（整块键区 ∪ 全部键面，EvenOdd 取缝）只依赖键位表与 bounds，与按哪个键无关，
    // 因此可以跨按键复用。此前每次按键都要把 26 条键面路径 append 进一条新路径、再把
    // UIBezierPath 扁平化成 CGPath —— 现在这笔开销只在布局变化时付一次。
    // mask 层本身仍每次新建：它是被 bed.mask 持有的，不与其它 pulse 共用同一个层对象。
    if (!self.cachedGutterMaskPath || !CGRectEqualToRect(self.cachedGutterMaskPathBounds, self.bounds)) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRect:area];
        for (UIBezierPath *face in self.cachedFacePaths) [path appendPath:face];
        self.cachedGutterMaskPath = path;
        self.cachedGutterMaskPathBounds = self.bounds;
    }
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = self.bounds;
    mask.path = self.cachedGutterMaskPath.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    return mask;
}

- (void)addNativeBedSpreadToPulse:(CALayer *)pulse origin:(CGPoint)origin
                           reach:(CGFloat)reach color:(UIColor *)color
                        duration:(CGFloat)duration reduce:(BOOL)reduce {
    if (![self usesNativeKeycapGlow]) return;
    CALayer *mask = [self nativeGutterMask];
    if (!mask) return;
    CALayer *bed = [CALayer layer];
    bed.frame = self.bounds;
    bed.mask = mask;
    [pulse addSublayer:bed];
    CAGradientLayer *wash = [CAGradientLayer layer];
    wash.type = kCAGradientLayerRadial;
    wash.frame = CGRectMake(origin.x-reach, origin.y-reach, reach*2, reach*2);
    wash.startPoint = CGPointMake(.5,.5);
    wash.endPoint = CGPointMake(1,1);
    wash.colors = @[(id)[color colorWithAlphaComponent:.9].CGColor,
                    (id)[color colorWithAlphaComponent:.85].CGColor,
                    (id)[color colorWithAlphaComponent:.58].CGColor,
                    (id)[color colorWithAlphaComponent:0].CGColor];
    wash.locations = @[@0,@.3,@.72,@1];
    [bed addSublayer:wash];
    if (!reduce) {
        CABasicAnimation *spread = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        spread.fromValue = @.06;
        spread.toValue = @1;
        spread.duration = duration;
        spread.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [wash addAnimation:spread forKey:@"nativeBedExpansion"];
    }
}

// Rebuild the 1.1.8 native "keyWave" outline on top of the new spreading
// pool. The deb ships only a compiled dylib; it cannot supply verbatim source.
// Each nearby key lights up as the expanding front arrives. WeType never enters.
- (void)addNativeKeyWavesToPulse:(CALayer *)pulse origin:(CGPoint)origin
                           reach:(CGFloat)reach color:(UIColor *)color
                        duration:(CGFloat)duration reduce:(BOOL)reduce {
    if (![self usesNativeKeycapGlow] || !self.cachedWaveGeometries.count) return;
    CGFloat maxDistance = MAX(1,reach);
    NSMutableArray<NSNumber *> *nearby = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.cachedCenters.count; i++) {
        CGPoint center = self.cachedCenters[i].CGPointValue;
        CGFloat distance = hypot(center.x-origin.x,center.y-origin.y);
        if (distance <= maxDistance + 14) [nearby addObject:@(i)];
    }
    [nearby sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        CGPoint ca = self.cachedCenters[a.unsignedIntegerValue].CGPointValue;
        CGPoint cb = self.cachedCenters[b.unsignedIntegerValue].CGPointValue;
        CGFloat da = hypot(ca.x-origin.x,ca.y-origin.y);
        CGFloat db = hypot(cb.x-origin.x,cb.y-origin.y);
        return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
    }];
    // Bound the layer cost even on a 26-key layout / rapid typing.
    NSUInteger count = MIN((NSUInteger)18,nearby.count);
    for (NSUInteger j = 0; j < count; j++) {
        NSUInteger index = nearby[j].unsignedIntegerValue;
        CGPoint center = self.cachedCenters[index].CGPointValue;
        CGFloat distance = hypot(center.x-origin.x,center.y-origin.y);
        RKKeyWaveGeometry *geometry = self.cachedWaveGeometries[index*2];
        CAShapeLayer *wave = [CAShapeLayer layer];
        wave.name = @"keyWave";
        wave.frame = geometry.edgeFrame;
        wave.path = geometry.outer.CGPath;
        wave.fillRule = kCAFillRuleEvenOdd;
        wave.fillColor = [color colorWithAlphaComponent:.85].CGColor;
        wave.opacity = 0;
        wave.contentsScale = self.window.screen.scale;
        [pulse addSublayer:wave];
        CFTimeInterval start = reduce ? 0 : duration*.38*MIN(1,distance/maxDistance);
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[@0,@.9,@.65,@0];
        fade.keyTimes = @[@0,@.18,@.55,@1];
        fade.beginTime = start;
        fade.duration = MAX(.14,duration*.48);
        [wave addAnimation:fade forKey:@"waveFade"];
        if (!reduce) {
            CABasicAnimation *grow = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            grow.fromValue = @.82;
            grow.toValue = @1.06;
            grow.beginTime = start;
            grow.duration = fade.duration;
            grow.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [wave addAnimation:grow forKey:@"keyWaveExpansion"];
        }
    }
}

- (CALayer *)waveUnderCapMask {
    CGFloat screenScale = self.window.screen.scale;
    if (screenScale <= 0) screenScale = 2;
    // Native: let the existing wave illuminate both the bed and key faces.
    // WeType/unknown: retain the original face cut-outs and all animation values.
    BOOL nativeFaces = [self usesNativeKeycapGlow];
    if (!self.underlightMaskImage || self.underlightMaskIncludesNativeFaces != nativeFaces ||
        !CGRectEqualToRect(self.underlightMaskBounds,self.bounds) ||
        self.underlightMaskImage.scale != screenScale) {
        UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, screenScale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) { UIGraphicsEndImageContext(); return nil; }
        CGContextTranslateCTM(context,-self.bounds.origin.x,-self.bounds.origin.y);
        // 键区包围盒随键位表缓存（见 setKeyFrames:），此处不再逐键求并集。
        CGRect bed = self.keyBedBounds;
        [[UIColor whiteColor] setFill];
        UIRectFill(CGRectIntersection(CGRectInset(bed,-3,-4),self.bounds));
        CGContextSetBlendMode(context,kCGBlendModeClear);
        // 2.3.34：切出「真实的圆角键帽形状」，而不是矩形 hit-test frame。
        // 矩形挖孔会在底光扩散时于每个键帽四角漏出方形/三角阴影。
        // 上游 mowang7426/jianpan 提交 57e23d3 同款修复。
        if (!nativeFaces) for (NSValue *value in self.keyFrames) {
            UIBezierPath *face = RKKeyboardKeyFacePath(value.CGRectValue);
            CGContextAddPath(context,face.CGPath);
            CGContextFillPath(context);
        }
        self.underlightMaskImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        self.underlightMaskBounds = self.bounds;
        self.underlightMaskIncludesNativeFaces = nativeFaces;
    }
    if (!self.underlightMaskImage) return nil;
    CALayer *mask = [CALayer layer];
    mask.frame = self.bounds;
    mask.contentsScale = screenScale;
    mask.contents = (__bridge id)self.underlightMaskImage.CGImage;
    return mask;
}
// 落点 → 生效按键。唯一判据 = **微信自己的命中**：
//   touch.view 就是微信 hitTest 为这个点选中的视图，即「微信认为这一下打在哪个键上」，
//   这是第一手结论，比我们自己的任何几何启发式都可信。
//   沿它的祖先链取最近的一个「尺寸像一块键」的视图（RKKeyRectFromSourceView），用它的矩形。
//
// 2.3.33 定稿：删去原先的「键位表覆盖」与「最近键吸附」两条兜底。依据 = 2.3.32 实机探针
// 400 条样本（含 74 次九宫格空格）：
//   · 微信判定 400/400 全部指向正确键。唯一 2 条 W=0 **不是它失败**，而是我们自己那道
//     2pt 容差圈把它的答案拒了（落点压在键边缘上 2~3pt），而兜底算出来的答案和微信给的
//     **一模一样**。⇒ 兜底从未提供过微信给不出的信息，是纯冗余。
//   · 九宫格空格 74/74 命中 `139,171 153x50`（老 bug 已由 2.3.31 的 y 复查根除）。
// 容差由 2pt 放宽到 6pt：键缝与行距都是 6pt，落点掉进缝里最多偏离最近键 3pt，
// 2pt 会把这类边缘按压误判成「微信没答案」而丢光效；6pt 让微信的答案稳稳接住它们，
// 又不会越到隔壁键（缝总共只有 6pt 宽）。
// 成本：主路径只有「取一个存好的 CGRect + 一次含点判断」，无分配、无循环、无字符串。
// ⛔ 若将来微信输入法升级后出现「整键无光」，说明它的视图结构变了、上面这条拾取启发式
//    不再成立 —— 恢复办法见 docs/hit-fallback.md（内含被删掉的兜底源码原文与恢复步骤）。
- (CGRect)resolvePressedKeyFrameAtPoint:(CGPoint)point sourceView:(UIView *)sourceView {
    // 微信快照：整个解析里唯一一次属性取值（Tweak.xm 已在触摸那一刻写进值类型）。
    CGRect snapshot = self.touchKeyRect;
    // 一拍内复用（见 cachedResolveResult 的注释）：主路径下快照必定非空，
    // 于是同一拍的第二次调用在这里就返回了 —— 不重复做含点判断。
    if (!CGRectIsNull(snapshot) && !CGRectIsEmpty(snapshot) &&
        CGRectEqualToRect(_cachedResolveTouchRect, snapshot) &&
        CGPointEqualToPoint(_cachedResolvePoint, point)) {
        return _cachedResolveResult;
    }
    // 唯一判据 = 微信的答案；快照缺失时才回头问一次 sourceView（原生键盘等场景用得到）。
    CGRect button = snapshot;
    if (CGRectIsNull(button) || CGRectIsEmpty(button)) {
        button = sourceView ? RKKeyRectFromSourceView(sourceView, self.superview, point) : CGRectNull;
    }
    // 命中矩形必须真的含落点（容差 6pt 覆盖键缝，理由见上）。
    CGRect result = CGRectNull;
    if (!CGRectIsNull(button) && CGRectContainsPoint(CGRectInset(button, -6, -6), point)) result = button;
    _cachedResolveTouchRect = snapshot;
    _cachedResolvePoint = point;
    _cachedResolveResult = result;
    return result;
}
// Both effects live in the exposed keyboard bed. Neither outlines keycaps.
// hue 由调用方统一推进（一拍一次），键底光效与轻弹因此共用同一色相。
- (void)showBedEffectAtPoint:(CGPoint)point sourceView:(UIView *)sourceView
                       style:(NSInteger)style hue:(CGFloat)hue {
    // 生效按键由 resolvePressedKeyFrameAtPoint: 给出（微信自己的命中，见其注释）。
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point sourceView:sourceView];
    if (CGRectIsNull(pressed) || CGRectIsEmpty(self.bounds)) return;
    CALayer *mask = [self waveUnderCapMask];
    if (!mask) return;
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat alpha = [self number:@"Opacity" fallback:.65 low:0 high:1];
    if (brightness <= 0 || alpha <= 0) return;
    BOOL fast = RKAdaptiveFastInput() || RKAdaptiveLevel() >= 2;
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    NSUInteger limit = style == 0 ? 3 : (fast ? 1 : 2);
    // 只驱逐本组（波纹/扩散/流光）的旧层：轻弹层再多也不会把在飞的波纹踢停。
    RKEvictLayersByName(self.layer.sublayers, RKBedEffectLayerNames(), limit);
    UIColor *color = [UIColor colorWithHue:hue saturation:[self neonSaturation:1] brightness:brightness alpha:1];
    CGFloat reach = MIN(210,MAX(100,[self number:@"BackgroundRadius" fallback:180 low:60 high:360]));
    CGFloat duration = MIN(.75,MAX(.42,[self number:@"Duration" fallback:.55 low:.15 high:1.2]));
    if (fast) { duration = .38; reach = MIN(reach,145); }
    if (style == 0) {
        // Broad ocean swells: wider reach, but slower than the small ripples.
        // Keep the same bounded pulse count and skip the trailing front when busy.
        reach = MIN(165,MAX(125,pressed.size.width*1.4));
        duration = 1.35;
    }
    if (reduce) reach = 32;
    CGPoint origin = CGPointMake(CGRectGetMidX(pressed),CGRectGetMaxY(pressed)+1);
    // Ripples originate just below the key so their first crest is visible immediately.
    CALayer *pulse = [CALayer layer];
    pulse.name = style == 0 ? @"RKBedRipples" : @"RKBedSpread";
    pulse.frame = self.bounds;
    pulse.bounds = self.bounds;
    pulse.opacity = 0;
    pulse.mask = mask;
    [self.layer addSublayer:pulse];
    [self addNativeBedSpreadToPulse:pulse origin:origin reach:reach color:color
                          duration:duration reduce:reduce];
    [self addNativeKeyWavesToPulse:pulse origin:origin reach:reach color:color
                         duration:duration reduce:reduce];
    CFTimeInterval now = [pulse convertTime:CACurrentMediaTime() fromLayer:nil];
    if (style == 0) {
        // A broad body, bright shoulder and crisp foam crest, followed by a weaker swell.
        NSUInteger fronts = fast || reduce ? 1 : 2;
        for (NSUInteger i = 0; i < fronts; i++) {
            for (NSUInteger pass = 0; pass < 3; pass++) {
                CAShapeLayer *ring = [CAShapeLayer layer];
                ring.frame = self.bounds;
                ring.bounds = self.bounds;
                ring.contentsScale = self.window.screen.scale;
                ring.fillColor = UIColor.clearColor.CGColor;
                UIColor *crest = [UIColor colorWithHue:hue
                    saturation:[self neonSaturation:.35] brightness:brightness alpha:1];
                UIColor *tint = pass == 2 ? crest : color;
                CGFloat layerAlpha = pass == 0 ? .38 : (pass == 1 ? .9 : 1);
                ring.strokeColor = [tint colorWithAlphaComponent:layerAlpha*(i ? .8 : 1)].CGColor;
                ring.lineWidth = pass == 0 ? 28 : (pass == 1 ? 14 : 3.5);
                ring.opacity = 0;
                CGFloat initial = reduce ? 26 : 8;
                UIBezierPath *start = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(origin.x-initial,origin.y-initial,initial*2,initial*2)];
                UIBezierPath *end = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(origin.x-reach,origin.y-reach,reach*2,reach*2)];
                ring.path = end.CGPath;
                [pulse addSublayer:ring];
                CFTimeInterval begin = now + i*duration*.25;
                if (!reduce) {
                    CABasicAnimation *expand = [CABasicAnimation animationWithKeyPath:@"path"];
                    expand.fromValue = (__bridge id)start.CGPath;
                    expand.toValue = (__bridge id)end.CGPath;
                    expand.beginTime = begin;
                    expand.duration = duration*.75;
                    expand.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
                    [ring addAnimation:expand forKey:@"roundWaveTravel"];
                }
                CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
                fade.values = @[@0,@1,@1,@0]; fade.keyTimes = @[@0,@.03,@.8,@1];
                fade.beginTime = begin; fade.duration = duration*.75;
                [ring addAnimation:fade forKey:@"roundWaveFade"];
            }
        }
    } else {
        // A compact, expanding pool with a defined edge, clipped to gaps.
        // No central flash, per-key outline, shadow, or key-face fill.
        CAGradientLayer *pool = [CAGradientLayer layer];
        pool.type = kCAGradientLayerRadial;
        pool.frame = CGRectMake(origin.x-reach,origin.y-reach,reach*2,reach*2);
        pool.startPoint = CGPointMake(.5,.5);
        pool.endPoint = CGPointMake(1,1);
        pool.colors = @[(id)[color colorWithAlphaComponent:.38].CGColor,
            (id)[color colorWithAlphaComponent:.75].CGColor,
            (id)color.CGColor, (id)[color colorWithAlphaComponent:0].CGColor];
        pool.locations = @[@0,@.4,@.72,@1];
        [pulse addSublayer:pool];
        if (!reduce) {
            CABasicAnimation *spread = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
            spread.fromValue = @.06; spread.toValue = @1;
            spread.duration = duration;
            spread.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [pool addAnimation:spread forKey:@"bedSpreadTravel"];
        }
    }
    CAKeyframeAnimation *life = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    CGFloat peak = MIN(1,alpha*(style == 0 ? 1.55 : 1.35));
    life.values = @[@0,@(peak),@(peak),@0];
    life.keyTimes = @[@0,@.06,@.65,@1];
    life.duration = duration;
    [pulse addAnimation:life forKey:@"bedEffectLifetime"];
    // Transparent when finished; bounded pulses (three for ripples), no timer queue.
}

// Native-only variant of WeType's spread. Keep showBedEffectAtPoint unchanged.
- (void)showNativeWeTypeSpreadAtPoint:(CGPoint)point sourceView:(UIView *)sourceView hue:(CGFloat)hue {
    if (![self usesNativeKeycapGlow]) return;
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point sourceView:sourceView];
    if (CGRectIsNull(pressed) || CGRectIsEmpty(self.bounds)) return;
    // Native hit cells may tile the whole keyboard. Cut out inset faces,
    // not full hit cells, to preserve the seams on both 9/26-key layouts.
    CALayer *mask = [self nativeGutterMask];
    if (!mask) return;
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat alpha = [self number:@"Opacity" fallback:.65 low:0 high:1];
    if (brightness <= 0 || alpha <= 0) return;
    BOOL fast = RKAdaptiveFastInput() || RKAdaptiveLevel() >= 2;
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    NSUInteger limit = fast ? 1 : 2;
    RKEvictLayersByName(self.layer.sublayers, RKBedEffectLayerNames(), limit);
    UIColor *color = [UIColor colorWithHue:hue saturation:[self neonSaturation:1] brightness:brightness alpha:1];
    CGFloat reach = MIN(210,MAX(100,[self number:@"BackgroundRadius" fallback:180 low:60 high:360]));
    CGFloat duration = MIN(.75,MAX(.42,[self number:@"Duration" fallback:.55 low:.15 high:1.2]));
    if (fast) { duration = .38; reach = MIN(reach,145); }
    if (reduce) reach = 32;
    CGPoint origin = CGPointMake(CGRectGetMidX(pressed),CGRectGetMaxY(pressed)+1);
    CALayer *pulse = [CALayer layer];
    pulse.name = @"RKNativeWeTypeSpread";
    pulse.frame = self.bounds;
    pulse.bounds = self.bounds;
    pulse.opacity = 0;
    [self.layer addSublayer:pulse];
    CALayer *bed = [CALayer layer];
    bed.frame = self.bounds;
    bed.bounds = self.bounds;
    bed.mask = mask;
    [pulse addSublayer:bed];
    // This pool uses the same colors, stops, origin and animation as WeType.
    CAGradientLayer *pool = [CAGradientLayer layer];
    pool.type = kCAGradientLayerRadial;
    pool.frame = CGRectMake(origin.x-reach,origin.y-reach,reach*2,reach*2);
    pool.startPoint = CGPointMake(.5,.5);
    pool.endPoint = CGPointMake(1,1);
    pool.colors = @[(id)[color colorWithAlphaComponent:.38].CGColor,
        (id)[color colorWithAlphaComponent:.75].CGColor,
        (id)color.CGColor, (id)[color colorWithAlphaComponent:0].CGColor];
    pool.locations = @[@0,@.4,@.72,@1];
    [bed addSublayer:pool];
    // Only the tapped key gets an additional face-local expansion.
    UIBezierPath *facePath = RKKeyboardKeyFacePath(pressed);
    CGRect face = facePath.bounds;
    CAShapeLayer *capMask = [CAShapeLayer layer];
    capMask.frame = self.bounds;
    capMask.path = facePath.CGPath;
    CALayer *cap = [CALayer layer];
    cap.frame = self.bounds;
    cap.bounds = self.bounds;
    cap.mask = capMask;
    [pulse addSublayer:cap];
    CGPoint center = CGPointMake(CGRectGetMidX(face),CGRectGetMidY(face));
    CGFloat capReach = MAX(1,hypot(face.size.width,face.size.height)*.6);
    CAGradientLayer *capPool = [CAGradientLayer layer];
    capPool.type = pool.type;
    capPool.frame = CGRectMake(center.x-capReach,center.y-capReach,capReach*2,capReach*2);
    capPool.startPoint = pool.startPoint;
    capPool.endPoint = pool.endPoint;
    capPool.colors = pool.colors;
    capPool.locations = pool.locations;
    [cap addSublayer:capPool];
    if (!reduce) {
        CABasicAnimation *spread = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        spread.fromValue = @.06; spread.toValue = @1;
        spread.duration = duration;
        spread.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [pool addAnimation:spread forKey:@"bedSpreadTravel"];
        [capPool addAnimation:spread forKey:@"pressedCapSpreadTravel"];
    }
    CAKeyframeAnimation *life = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    CGFloat peak = MIN(1,alpha*1.35);
    life.values = @[@0,@(peak),@(peak),@0];
    life.keyTimes = @[@0,@.06,@.65,@1];
    life.duration = duration;
    [pulse addAnimation:life forKey:@"bedEffectLifetime"];
    // Shared lifetime and eviction: no timers, snapshots or per-neighbor waves.
}

// 轻弹：给「实际按下的那个键」的键帽面上色，并让它轻轻弹一下。
// 2.3.24 起它是独立开关（LightPop），与光效风格叠加共存 —— 不再占用 EffectStyle 的
// 一个选项，因此也不再有「开了扩散就不能开轻弹」的限制。
// 命中复用索引化的精准解析：按在键帽缝隙里的那一下，同样会落到真正生效的那个键上。
// 配色默认与键底光效同色（LightPopMatchColor），可切回轻弹自己的取色。
- (void)showKeycapFeedbackAtPoint:(CGPoint)point sourceView:(UIView *)sourceView hue:(CGFloat)hue {
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point sourceView:sourceView];
    if (CGRectIsNull(pressed)) return;
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat duration = [self number:@"Duration" fallback:.55 low:.15 high:1.2];
    NSUInteger limit = (NSUInteger)[self number:@"MaxEffects" fallback:4 low:1 high:8];
    // 轻弹只在自己的层组里做上限控制，不去挤键底光效的计数池。
    RKEvictLayersByName(self.layer.sublayers, RKKeycapFeedbackLayerNames(), limit);
    // 轻弹自己的色相照常推进：关掉「与光效同色」后接着用，行为与旧版一致。
    self.pressHue = fmod(self.pressHue + .38196601125, 1);
    BOOL single = [self number:@"PressColorMode" fallback:0 low:0 high:1] == 1;
    // 默认同色（键缺失即同色）：直接用本拍键底光效的色相，两种效果对上色；
    // 亮度仍由「键帽灯光亮度」单独决定，所以键帽会比键底暗一档。
    BOOL matchGlow = !self.config[@"LightPopMatchColor"] ||
        [self.config[@"LightPopMatchColor"] boolValue];
    UIColor *color = matchGlow ?
        [UIColor colorWithHue:hue saturation:[self neonSaturation:1] brightness:1 alpha:1] :
        (single ? RKKeyboardColor(self.config, @"PressColor") :
            [UIColor colorWithHue:self.pressHue saturation:1 brightness:1 alpha:1]);
    // 2.3.24：键帽上色的默认亮度由 1.0 降到 0.6（原值在键帽上过亮），
    // 具体数值可在高级设置「键帽灯光亮度」里调整。
    CGFloat pressBrightness = [self number:@"PressBrightness" fallback:.6 low:0 high:1];
    NSInteger theme = [self.config[@"Theme"] integerValue];
    if (theme >= 1 && theme <= 9) {
        // Preset themes take priority; Custom retains independent press colors.
        color = [UIColor colorWithHue:hue saturation:[self neonSaturation:1]
                           brightness:1 alpha:1];
        pressBrightness = brightness;
    }
    RKShowNeonKeyPress(self, pressed, color, pressBrightness, duration,
        UIAccessibilityIsReduceMotionEnabled() || [self flag:@"SmartPerformance"], sourceView);
}

- (void)showRippleAtPoint:(CGPoint)point {
    [self showRippleAtPoint:point sourceView:nil];
}

- (void)clearLegacyKeycapFeedback {
    for (CALayer *layer in self.layer.sublayers.copy) {
        NSString *name = layer.name ?: @"";
        if ([name isEqualToString:@"neonKeyPress"] || [name isEqualToString:@"RKFastInputFeedback"]) {
            [layer removeAllAnimations];
            [layer removeFromSuperlayer];
        }
    }
}
- (void)showCrispUnderlightAtPoint:(CGPoint)point sourceView:(UIView *)sourceView hue:(CGFloat)hue {
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point sourceView:sourceView];
    if (CGRectIsNull(pressed) || CGRectIsEmpty(self.bounds)) return;
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat opacity = [self number:@"Opacity" fallback:.65 low:0 high:1];
    if (brightness <= 0 || opacity <= 0) return;
    CGFloat screenScale = self.window.screen.scale;
    if (screenScale <= 0) screenScale = 2;
    // Native: let the existing wave illuminate both the bed and key faces.
    // WeType/unknown: retain the original face cut-outs and all animation values.
    BOOL nativeFaces = [self usesNativeKeycapGlow];
    if (!self.underlightMaskImage || self.underlightMaskIncludesNativeFaces != nativeFaces ||
        !CGRectEqualToRect(self.underlightMaskBounds,self.bounds) ||
        self.underlightMaskImage.scale != screenScale) {
        UIGraphicsBeginImageContextWithOptions(self.bounds.size, NO, screenScale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if (!context) { UIGraphicsEndImageContext(); return; }
        CGContextTranslateCTM(context,-self.bounds.origin.x,-self.bounds.origin.y);
        // 键区包围盒随键位表缓存（见 setKeyFrames:），此处不再逐键求并集。
        CGRect bed = self.keyBedBounds;
        [[UIColor whiteColor] setFill];
        UIRectFill(CGRectIntersection(CGRectInset(bed,-3,-4),self.bounds));
        CGContextSetBlendMode(context,kCGBlendModeClear);
        // 2.3.34：切出「真实的圆角键帽形状」，而不是矩形 hit-test frame。
        // 矩形挖孔会在底光扩散时于每个键帽四角漏出方形/三角阴影。
        // 上游 mowang7426/jianpan 提交 57e23d3 同款修复。
        if (!nativeFaces) for (NSValue *value in self.keyFrames) {
            UIBezierPath *face = RKKeyboardKeyFacePath(value.CGRectValue);
            CGContextAddPath(context,face.CGPath);
            CGContextFillPath(context);
        }
        self.underlightMaskImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        self.underlightMaskBounds = self.bounds;
        self.underlightMaskIncludesNativeFaces = nativeFaces;
    }
    if (!self.underlightMaskImage) return;
    BOOL fast = RKAdaptiveFastInput() || RKAdaptiveLevel() >= 2;
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    NSUInteger limit = fast ? 1 : 2;
    RKEvictLayersByName(self.layer.sublayers, RKBedEffectLayerNames(), limit);
    UIColor *color = [UIColor colorWithHue:hue saturation:[self neonSaturation:1] brightness:brightness alpha:1];
    CALayer *pulse = [CALayer layer];
    pulse.name = @"RKExpandingUnderlight";
    pulse.frame = self.bounds;
    pulse.bounds = self.bounds;
    pulse.opacity = 0;
    CALayer *mask = [CALayer layer];
    mask.frame = self.bounds;
    mask.contentsScale = screenScale;
    mask.contents = (__bridge id)self.underlightMaskImage.CGImage;
    pulse.mask = mask;
    [self.layer addSublayer:pulse];
    // Launch from just underneath the pressed key, rather than its letter.
    CGPoint origin = CGPointMake(CGRectGetMidX(pressed),CGRectGetMaxY(pressed)+1);
    CGFloat reach = MIN(210,MAX(105,[self number:@"BackgroundRadius" fallback:180 low:60 high:360]));
    CGFloat duration = MIN(.65,MAX(.38,[self number:@"Duration" fallback:.55 low:.15 high:1.2]));
    if (fast) { reach = MIN(reach,145); duration = .38; }
    CGFloat initial = reduce ? 26 : 5;
    CGFloat finalRadius = reduce ? initial : reach;
    [self addNativeBedSpreadToPulse:pulse origin:origin reach:reach color:color
                          duration:duration reduce:reduce];
    [self addNativeKeyWavesToPulse:pulse origin:origin reach:reach color:color
                         duration:duration reduce:reduce];
    UIBezierPath *start = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(origin.x-initial,origin.y-initial,initial*2,initial*2)];
    UIBezierPath *end = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(origin.x-finalRadius,origin.y-finalRadius,finalRadius*2,finalRadius*2)];
    // A 20pt moving band with an 8pt bright core. No Gaussian blur or
    // whole-keyboard color wash. Both layers are clipped to the same gaps.
    for (NSUInteger pass = 0; pass < 2; pass++) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        ring.frame = self.bounds;
        ring.bounds = self.bounds;
        ring.contentsScale = screenScale;
        ring.fillColor = UIColor.clearColor.CGColor;
        ring.strokeColor = [color colorWithAlphaComponent:pass ? 1 : .28].CGColor;
        ring.lineWidth = pass ? 8 : 20;
        ring.path = end.CGPath;
        [pulse addSublayer:ring];
        if (!reduce) {
            CABasicAnimation *expand = [CABasicAnimation animationWithKeyPath:@"path"];
            expand.fromValue = (__bridge id)start.CGPath;
            expand.toValue = (__bridge id)end.CGPath;
            expand.duration = duration;
            expand.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            [ring addAnimation:expand forKey:@"underlightExpansion"];
        }
    }
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    CGFloat peak = MIN(1,opacity*1.35);
    fade.values = @[@0,@(peak),@(peak),@0];
    fade.keyTimes = @[@0,@.06,@.62,@1];
    fade.duration = duration;
    [pulse addAnimation:fade forKey:@"underlightLifetime"];
    // Transparent after expiration; the next press evicts old layers (max two).
}

- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView {
    // Configuration is cached and invalidated by the settings Darwin notification.
    // Do not perform preference/transport checks on every key press.
    // Input activity is recorded once in sendEvent, before decoration coalescing.
    // 宿主判定走进程级缓存（dispatch_once 内解析一次）；此前每次按键都要
    // NSBundle.mainBundle.bundleIdentifier + lowercaseString，两次 NSString 分配。
    BOOL weType = RKKeyboardBundleIsWeType();
    if (![self flag:@"Enabled"] || ![self flag:@"RippleEnabled"] || ![self flag:weType ? @"WeChatKeyboard" : @"NativeKeyboard"]) {
        for (CALayer *l in self.layer.sublayers.copy) [l removeFromSuperlayer];
        return;
    }
    if (!self.window || self.hidden) return;
    // 光效风格：0 波纹 / 1 扩散 / 3 流光底韵。轻弹自 2.3.24 起是独立开关（可与任一风格
    // 叠加），旧档遗留的 2 在常态归一化里已折成 1，这里再兜一道底。
    NSInteger style = (NSInteger)[self number:@"EffectStyle" fallback:0 low:0 high:3];
    if (style == 2) style = 1;
    // 2.3.27：轻弹可跟随系统深浅色（深色自动关），判据统一走 effectiveLightPop。
    BOOL lightPop = [self effectiveLightPop];
    // 关掉轻弹时清掉上一拍留下的键帽图层；风格或轻弹任一变化则整体重来，
    // 避免两套效果跨配置互相叠加残留。深色压制也走这条 —— 切到深色后下一拍
    // 就把残留的键帽上色层撤掉。
    if (!lightPop) [self clearLegacyKeycapFeedback];
    NSInteger stamp = style * 2 + (lightPop ? 1 : 0);
    if (stamp != self.lastStyle) {
        for (CALayer *layer in self.layer.sublayers.copy) [layer removeFromSuperlayer];
        self.lastStyle = stamp;
    }
    // 一拍只推进一次色相，键底光效与轻弹共用它 —— 「与光效同色」能对上色的前提。
    self.hue = fmod(self.hue + .137, 1);
    NSInteger colorMode = (NSInteger)[self number:@"ColorMode" fallback:0 low:0 high:2];
    CGFloat hue = colorMode == 1 ? [self number:@"Hue" fallback:.55 low:0 high:1] :
        (colorMode == 2 ? point.x / MAX(1, self.bounds.size.width) : self.hue);
    // 键底光效（风格）：先铺底，再叠轻弹 —— 两者互不排斥。
    if (style == 1 && !weType && [self usesNativeKeycapGlow]) {
        [self showNativeWeTypeSpreadAtPoint:point sourceView:sourceView hue:hue];
    } else if (style == 3) {
        [self showCrispUnderlightAtPoint:point sourceView:sourceView hue:hue];
    } else {
        [self showBedEffectAtPoint:point sourceView:sourceView style:style hue:hue];
    }
    if (lightPop) [self showKeycapFeedbackAtPoint:point sourceView:sourceView hue:hue];
}
@end
