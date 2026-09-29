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
// 命中索引的一「行」：键位表按行的顶边分桶，行内按键的 x 升序排列。
// 有了它，落点判定不必每次把整张键位表扫一遍 —— 先按 y 定位候选行（键盘只有
// 三到五行），再在行内二分定位键，比较次数从「键数」降到「行数 + log 列数」。
@interface RKKeyRow : NSObject
@property(nonatomic) CGRect bounds;                 // 该行的联合包围盒
@property(nonatomic,strong) NSArray<NSValue *> *keys; // 行内键，按 minX 升序
@end
@implementation RKKeyRow
@end
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
// 命中索引（随 keyFrames 一起重建，见 setKeyFrames:）：行分桶 + 整表包围盒。
@property(nonatomic,strong) NSArray<RKKeyRow *> *keyHitRows;
@property(nonatomic) CGRect keyBedBounds;
@end

// 落点 → 按压键解析（扩散/波纹、原生扩散、轻弹三处共用同一套判据）。
// 原生键盘的 displayFrame 就是命中单元，落点基本总落在某个键内；
// WeType 收集到的是键帽视觉 frame（圆角 + 间距），按进键缝时落点处于几何空洞，
// 而微信自身按更大的命中单元仍会上屏字符 —— 于是出现「出了字却没有光效」。
// 这里对空洞落点做「最近键吸附」，还原微信的命中判定，让光效跟着实际生效的键走。
// 约束一：落点须落在键区包围盒外扩 8pt 内，挡住候选栏 / 工具条误触发。
// 约束二：吸附距离须 ≤ clamp(最近键高 × 0.6, 8, 26)pt，键缝实际仅 2~6pt，余量充足。
// 返回 CGRectNull 表示此落点不算有效按键，调用方保持原样放弃。
//
// 2.3.24：判定改走「行索引 + 行内二分」。此前每按一次键都要把整张键位表
// （全键盘约五十个键）扫一到两遍；现在先按 y 落到候选行（键盘只有三到五行），
// 再在行内二分定位键 —— 候选集与全表遍历等价、结果逐位相同，但不再遍历全表。
// 索引随键位表在 setKeyFrames: 重建，按键路径只读不建。

// 键位表 → 行索引：按行的顶边分桶（容差取行高的半数），行按 y 升序、行内按 x 升序。
static NSArray<RKKeyRow *> *RKBuildKeyHitRows(NSArray<NSValue *> *keyFrames) {
    if (!keyFrames.count) return @[];
    NSArray<NSValue *> *sorted = [keyFrames sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGRect ra = a.CGRectValue, rb = b.CGRectValue;
        if (ra.origin.y != rb.origin.y) return ra.origin.y < rb.origin.y ? NSOrderedAscending : NSOrderedDescending;
        if (ra.origin.x != rb.origin.x) return ra.origin.x < rb.origin.x ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<RKKeyRow *> *rows = [NSMutableArray array];
    for (NSValue *value in sorted) {
        CGRect rect = value.CGRectValue;
        RKKeyRow *row = rows.lastObject;
        if (row) {
            CGFloat tolerance = MAX(2.0, row.bounds.size.height * .5);
            if (fabs(rect.origin.y - CGRectGetMinY(row.bounds)) > tolerance) row = nil;
        }
        if (!row) {
            row = [RKKeyRow new];
            row.bounds = rect;
            row.keys = [NSMutableArray array];
            [rows addObject:row];
        }
        row.bounds = CGRectUnion(row.bounds, rect);
        // 输入已按 y 再 x 排序，同一行内追加即天然有序（构建期临时用可变数组）。
        [(NSMutableArray *)row.keys addObject:value];
    }
    return rows;
}

// 行内按 x 定位「盖住落点」的键。键互不重叠，命中即返回；NSNotFound = 本行没有。
static NSInteger RKKeyRowIndexCoveringX(RKKeyRow *row, CGFloat x) {
    NSArray<NSValue *> *keys = row.keys;
    NSUInteger lo = 0, hi = keys.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        CGRect rect = keys[mid].CGRectValue;
        if (x < CGRectGetMinX(rect)) hi = mid;
        // 半开区间，与 CGRectContainsPoint 的右边界语义保持一致。
        else if (x >= CGRectGetMaxX(rect)) lo = mid + 1;
        else return (NSInteger)mid;
    }
    return NSNotFound;
}

// 行内按 x 找水平距离最近的键：二分出落点两侧相邻的两个键，取距离小者。
static NSInteger RKKeyRowNearestIndexAtX(RKKeyRow *row, CGFloat x) {
    NSArray<NSValue *> *keys = row.keys;
    if (!keys.count) return NSNotFound;
    NSUInteger lo = 0, hi = keys.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (x < CGRectGetMinX(keys[mid].CGRectValue)) hi = mid;
        else lo = mid + 1;
    }
    NSInteger candidates[2] = {
        lo > 0 ? (NSInteger)(lo - 1) : NSNotFound,
        lo < keys.count ? (NSInteger)lo : NSNotFound,
    };
    NSInteger best = NSNotFound;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < 2; i++) {
        NSInteger index = candidates[i];
        if (index == NSNotFound) continue;
        CGRect rect = keys[index].CGRectValue;
        CGFloat dx = 0;
        if (x < CGRectGetMinX(rect)) dx = CGRectGetMinX(rect) - x;
        else if (x > CGRectGetMaxX(rect)) dx = x - CGRectGetMaxX(rect);
        if (dx < bestDistance) { bestDistance = dx; best = index; }
    }
    return best;
}

@implementation RainbowEffectView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
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
    // 命中索引与键位表同生命周期：布局一变就重建，按键路径只读不建。
    self.keyHitRows = RKBuildKeyHitRows(_keyFrames);
    CGRect bed = CGRectNull;
    for (NSValue *value in _keyFrames) bed = CGRectUnion(bed, value.CGRectValue);
    self.keyBedBounds = bed;
    for (CALayer *pulse in self.layer.sublayers.copy) [pulse removeFromSuperlayer];
}
// 注：原 addAmbientGlowToPulse:（背景光晕/背景扩散）于 2.3.17 删除 ——
// 该方法全项目零调用，与之配套的「背景光晕」「背景扩散」两个开关是死开关，
// 已一并从高级设置移除。keyGutterMask / cachedGutterPath 为其独占依赖，同批删除。
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
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:area];
    for (UIBezierPath *face in self.cachedFacePaths) [path appendPath:face];
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = self.bounds;
    mask.path = path.CGPath;
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
        BOOL nativeNine = [self usesNativeNineKeyBed];
        if (!nativeFaces) for (NSValue *value in self.keyFrames) {
            if (nativeNine) {
                // Native hit cells can tile the whole bed, including gutters.
                // Use the project's inset key-face model (2pt vertical,
                // up to 2.5pt horizontal), keeping the central face opaque.
                UIBezierPath *face = RKKeyboardKeyFacePath(value.CGRectValue);
                CGContextAddPath(context,face.CGPath);
                CGContextFillPath(context);
            } else {
                CGContextFillRect(context,value.CGRectValue);
            }
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
// 落点 → 生效按键。候选集与「全表遍历」等价：先按 y 取覆盖落点的行（精准命中），
// 落进键缝时再取 y 距离不超过吸附上限的行（最近键吸附），都不遍历整张键位表。
- (CGRect)resolvePressedKeyFrameAtPoint:(CGPoint)point {
    NSArray<RKKeyRow *> *rows = self.keyHitRows;
    if (!rows.count) return CGRectNull;
    // 一、落点盖在键帽内：取面积最小的那个键（与旧实现同为「面积优先」）。
    CGRect pressed = CGRectNull;
    CGFloat pressedArea = CGFLOAT_MAX;
    for (RKKeyRow *row in rows) {
        if (point.y < CGRectGetMinY(row.bounds) || point.y > CGRectGetMaxY(row.bounds)) continue;
        NSInteger index = RKKeyRowIndexCoveringX(row, point.x);
        if (index == NSNotFound) continue;
        CGRect rect = row.keys[index].CGRectValue;
        CGFloat area = rect.size.width * rect.size.height;
        if (area < pressedArea) { pressedArea = area; pressed = rect; }
    }
    if (!CGRectIsNull(pressed)) return pressed;
    // 二、落点在键缝里：仍须落在键区包围盒外扩 8pt 内，否则视为候选栏/工具条的误触发。
    if (CGRectIsNull(self.keyBedBounds) ||
        !CGRectContainsPoint(CGRectInset(self.keyBedBounds, -8, -8), point)) return CGRectNull;
    CGRect nearest = CGRectNull;
    CGFloat nearestDistance = CGFLOAT_MAX;
    for (RKKeyRow *row in rows) {
        CGFloat dy = 0;
        if (point.y < CGRectGetMinY(row.bounds)) dy = CGRectGetMinY(row.bounds) - point.y;
        else if (point.y > CGRectGetMaxY(row.bounds)) dy = point.y - CGRectGetMaxY(row.bounds);
        // 吸附上限最松也只有 26pt：y 距离已经超出的行不可能产生更近的键，跳过整行。
        if (dy > 26.0) continue;
        NSInteger index = RKKeyRowNearestIndexAtX(row, point.x);
        if (index == NSNotFound) continue;
        CGRect rect = row.keys[index].CGRectValue;
        CGFloat dx = 0;
        if (point.x < CGRectGetMinX(rect)) dx = CGRectGetMinX(rect) - point.x;
        else if (point.x > CGRectGetMaxX(rect)) dx = point.x - CGRectGetMaxX(rect);
        CGFloat distance = hypot(dx, dy);
        if (distance < nearestDistance) { nearestDistance = distance; nearest = rect; }
    }
    if (CGRectIsNull(nearest)) return CGRectNull;
    CGFloat maxSnap = MIN(26.0, MAX(8.0, nearest.size.height * .6));
    if (nearestDistance > maxSnap) return CGRectNull;
    return nearest;
}
// Both effects live in the exposed keyboard bed. Neither outlines keycaps.
// hue 由调用方统一推进（一拍一次），键底光效与轻弹因此共用同一色相。
- (void)showBedEffectAtPoint:(CGPoint)point style:(NSInteger)style hue:(CGFloat)hue {
    // 键缝落点吸附：原「落点必须落在键帽矩形内」的判据会让 WeType 全键盘的
    // 宽键缝整段丢光效（微信仍会上屏字符）。改用命中索引还原命中判定；
    // 包含落点的场景逐位等同原逻辑，观感零变化。
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point];
    if (CGRectIsNull(pressed) || CGRectIsEmpty(self.bounds)) return;
    CALayer *mask = [self waveUnderCapMask];
    if (!mask) return;
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat alpha = [self number:@"Opacity" fallback:.65 low:0 high:1];
    if (brightness <= 0 || alpha <= 0) return;
    BOOL fast = RKAdaptiveFastInput() || RKAdaptiveLevel() >= 2;
    BOOL reduce = UIAccessibilityIsReduceMotionEnabled();
    NSUInteger limit = style == 0 ? 3 : (fast ? 1 : 2);
    while (self.layer.sublayers.count >= limit) [self.layer.sublayers.firstObject removeFromSuperlayer];
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
- (void)showNativeWeTypeSpreadAtPoint:(CGPoint)point hue:(CGFloat)hue {
    if (![self usesNativeKeycapGlow]) return;
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point];
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
    while (self.layer.sublayers.count >= limit) [self.layer.sublayers.firstObject removeFromSuperlayer];
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
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point];
    if (CGRectIsNull(pressed)) return;
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat duration = [self number:@"Duration" fallback:.55 low:.15 high:1.2];
    NSUInteger limit = (NSUInteger)[self number:@"MaxEffects" fallback:4 low:1 high:8];
    while (self.layer.sublayers.count >= limit) [self.layer.sublayers.firstObject removeFromSuperlayer];
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
- (void)showCrispUnderlightAtPoint:(CGPoint)point hue:(CGFloat)hue {
    CGRect pressed = [self resolvePressedKeyFrameAtPoint:point];
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
        BOOL nativeNine = [self usesNativeNineKeyBed];
        if (!nativeFaces) for (NSValue *value in self.keyFrames) {
            if (nativeNine) {
                // Native hit cells can tile the whole bed, including gutters.
                // Use the project's inset key-face model (2pt vertical,
                // up to 2.5pt horizontal), keeping the central face opaque.
                UIBezierPath *face = RKKeyboardKeyFacePath(value.CGRectValue);
                CGContextAddPath(context,face.CGPath);
                CGContextFillPath(context);
            } else {
                CGContextFillRect(context,value.CGRectValue);
            }
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
    while (self.layer.sublayers.count >= limit) [self.layer.sublayers.firstObject removeFromSuperlayer];
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
    BOOL lightPop = [self.config[@"LightPop"] boolValue];
    // 关掉轻弹时清掉上一拍留下的键帽图层；风格或轻弹任一变化则整体重来，
    // 避免两套效果跨配置互相叠加残留。
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
        [self showNativeWeTypeSpreadAtPoint:point hue:hue];
    } else if (style == 3) {
        [self showCrispUnderlightAtPoint:point hue:hue];
    } else {
        [self showBedEffectAtPoint:point style:style hue:hue];
    }
    if (lightPop) [self showKeycapFeedbackAtPoint:point sourceView:sourceView hue:hue];
}
@end
