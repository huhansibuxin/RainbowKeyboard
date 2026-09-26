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
@interface RainbowEffectView ()
@property(nonatomic,strong) NSDictionary *config;
@property(nonatomic,strong) UIImage *underlightMaskImage;
@property(nonatomic) CGRect underlightMaskBounds;
@property(nonatomic) BOOL underlightMaskIncludesNativeFaces;
@property(nonatomic) CGFloat hue;
@property(nonatomic) CGFloat pressHue;
@property(nonatomic,strong) CALayer *fastFeedback;
@property(nonatomic) NSInteger lastStyle;
@property(nonatomic,strong) UIBezierPath *cachedGutterPath;
@property(nonatomic,strong) NSArray<UIBezierPath *> *cachedFacePaths;
@property(nonatomic,strong) NSArray<NSValue *> *cachedCenters;
@property(nonatomic,strong) NSArray<RKKeyWaveGeometry *> *cachedWaveGeometries;
@property(nonatomic) CGRect cachedGeometryBounds;
@end
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
- (BOOL)preservesBlackFaces {
    return [self flag:@"PureBlackKeyboard"];
}
- (CAShapeLayer *)keyGutterMask {
    if (!self.cachedGutterPath || !CGRectEqualToRect(self.cachedGeometryBounds, self.bounds)) {
        UIBezierPath *gaps = [UIBezierPath bezierPathWithRect:self.bounds];
        for (UIBezierPath *face in self.cachedFacePaths) [gaps appendPath:face];
        self.cachedGutterPath = gaps;
        self.cachedGeometryBounds = self.bounds;
    }
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = self.bounds;
    mask.path = self.cachedGutterPath.CGPath;
    mask.fillRule = kCAFillRuleEvenOdd;
    return mask;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGRectEqualToRect(self.cachedGeometryBounds, self.bounds)) {
        self.cachedGutterPath = nil;
        self.cachedGeometryBounds = CGRectNull;
    }
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
    self.cachedGutterPath = nil;
    self.cachedGeometryBounds = CGRectNull;
    for (CALayer *pulse in self.layer.sublayers.copy) [pulse removeFromSuperlayer];
}
- (void)addAmbientGlowToPulse:(CALayer *)pulse origin:(CGPoint)origin radius:(CGFloat)radius
                         hue:(CGFloat)hue mode:(NSInteger)mode duration:(CGFloat)duration {
    if (![self flag:@"AmbientGlow"] || ![self flag:@"BackgroundFeedback"]) return;
    CGFloat strength = [self number:@"AmbientStrength" fallback:.85 low:0 high:1];
    CGFloat alpha = [self number:@"Opacity" fallback:.65 low:0 high:1] * strength;
    if (alpha <= 0) return;
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CALayer *ambient = [CALayer layer];
    ambient.name = @"keyboardAmbientGlow";
    ambient.frame = self.bounds;
    [pulse addSublayer:ambient];

    // Solid black mode has backlighting only; the optional wash belongs to other themes.
    for (NSUInteger pass = [self preservesBlackFaces] ? 1 : 0; pass < 2; pass++) {
        CALayer *field = [CALayer layer];
        field.name = pass ? @"gutterLight" : @"keyFaceWash";
        field.frame = self.bounds;
        [ambient addSublayer:field];
        if (pass) field.mask = [self keyGutterMask];
        CAGradientLayer *bloom = [CAGradientLayer layer];
        bloom.type = kCAGradientLayerRadial;
        bloom.frame = CGRectMake(origin.x - radius, origin.y - radius, radius * 2, radius * 2);
        bloom.startPoint = CGPointMake(.5, .5);
        bloom.endPoint = CGPointMake(1, 1);
        CGFloat level = alpha * (pass ? 1 : .24);
        UIColor *inner = [UIColor colorWithHue:hue saturation:[self neonSaturation:.82] brightness:brightness alpha:1];
        UIColor *middle = [UIColor colorWithHue:mode == 1 ? hue : fmod(hue + .13, 1)
                                    saturation:[self neonSaturation:.75] brightness:brightness alpha:1];
        UIColor *outer = [UIColor colorWithHue:mode == 1 ? hue : fmod(hue + .25, 1)
                                   saturation:[self neonSaturation:.9] brightness:brightness alpha:1];
        bloom.colors = @[(id)[inner colorWithAlphaComponent:level * .22].CGColor,
            (id)[inner colorWithAlphaComponent:level * .6].CGColor,
            (id)[middle colorWithAlphaComponent:level].CGColor,
            (id)[outer colorWithAlphaComponent:level * .5].CGColor,
            (id)[outer colorWithAlphaComponent:0].CGColor];
        bloom.locations = @[@0, @.22, @.52, @.78, @1];
        bloom.opacity = 0;
        [field addSublayer:bloom];
        CAKeyframeAnimation *spread = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        spread.values = @[@.04, @.64, @1, @1.08];
        spread.keyTimes = @[@0, @.32, @.7, @1];
        spread.duration = duration;
        [bloom addAnimation:spread forKey:@"ambientExpansion"];
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[@0, @1, @.9, @0];
        fade.keyTimes = @[@0, @.08, @.52, @1];
        fade.duration = duration;
        [bloom addAnimation:fade forKey:@"ambientFade"];
    }
}
// Only positively identified native layouts may illuminate key faces.
// WeType keeps its existing cut-out mask, even if a native-looking view exists.
- (BOOL)usesNativeKeycapGlow {
    if ([NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"]) return NO;
    for (UIView *v = self.superview; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if (RKClassFeatures(v.class) & RKFeatureLayoutStar) return YES;
    }
    return NO;
}

// Conservative native nine-key detection: never change WeType's mask.
- (BOOL)usesNativeNineKeyBed {
    if ([NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"]) return NO;
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
    CGRect bed = CGRectNull;
    for (NSValue *value in self.keyFrames) bed = CGRectUnion(bed,value.CGRectValue);
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
        CGRect bed = CGRectNull;
        for (NSValue *value in self.keyFrames) bed = CGRectUnion(bed,value.CGRectValue);
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
// Both effects live in the exposed keyboard bed. Neither outlines keycaps.
- (void)showBedEffectAtPoint:(CGPoint)point style:(NSInteger)style {
    CGRect pressed = CGRectNull;
    for (NSValue *value in self.keyFrames) {
        CGRect rect = value.CGRectValue;
        if (CGRectContainsPoint(rect, point) && (CGRectIsNull(pressed) ||
            rect.size.width*rect.size.height < pressed.size.width*pressed.size.height)) pressed = rect;
    }
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
    NSInteger mode = (NSInteger)[self number:@"ColorMode" fallback:0 low:0 high:2];
    self.hue = fmod(self.hue+.137,1);
    CGFloat hue = mode == 1 ? [self number:@"Hue" fallback:.55 low:0 high:1] :
        (mode == 2 ? point.x/MAX(1,self.bounds.size.width) : self.hue);
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
- (void)showNativeWeTypeSpreadAtPoint:(CGPoint)point {
    if (![self usesNativeKeycapGlow]) return;
    CGRect pressed = CGRectNull;
    for (NSValue *value in self.keyFrames) {
        CGRect rect = value.CGRectValue;
        if (CGRectContainsPoint(rect, point) && (CGRectIsNull(pressed) ||
            rect.size.width*rect.size.height < pressed.size.width*pressed.size.height)) pressed = rect;
    }
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
    NSInteger mode = (NSInteger)[self number:@"ColorMode" fallback:0 low:0 high:2];
    self.hue = fmod(self.hue+.137,1);
    CGFloat hue = mode == 1 ? [self number:@"Hue" fallback:.55 low:0 high:1] :
        (mode == 2 ? point.x/MAX(1,self.bounds.size.width) : self.hue);
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
- (void)showCrispUnderlightAtPoint:(CGPoint)point {
    CGRect pressed = CGRectNull;
    for (NSValue *value in self.keyFrames) {
        CGRect r = value.CGRectValue;
        if (CGRectContainsPoint(r, point) &&
            (CGRectIsNull(pressed) || r.size.width*r.size.height < pressed.size.width*pressed.size.height)) pressed = r;
    }
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
        CGRect bed = CGRectNull;
        for (NSValue *value in self.keyFrames) bed = CGRectUnion(bed,value.CGRectValue);
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
    NSInteger mode = (NSInteger)[self number:@"ColorMode" fallback:0 low:0 high:2];
    self.hue = fmod(self.hue + .137,1);
    CGFloat hue = mode == 1 ? [self number:@"Hue" fallback:.55 low:0 high:1] :
        (mode == 2 ? point.x/MAX(1,self.bounds.size.width) : self.hue);
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
    NSString *bid = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
    BOOL weType = [bid containsString:@"wetype"];
    if (![self flag:@"Enabled"] || ![self flag:@"RippleEnabled"] || ![self flag:weType ? @"WeChatKeyboard" : @"NativeKeyboard"]) {
        for (CALayer *l in self.layer.sublayers.copy) [l removeFromSuperlayer];
        return;
    }
    if (!self.window || self.hidden) return;
    NSInteger style = (NSInteger)[self number:@"EffectStyle" fallback:0 low:0 high:3];
    // Bed-only styles must not coexist with a captured keycap feedback layer.
    if (style == 0 || style == 1 || style == 3) [self clearLegacyKeycapFeedback];
    // Keep the user's original configured style; adaptive mode only reduces work.
    if (style != self.lastStyle) {
        for (CALayer *layer in self.layer.sublayers.copy) [layer removeFromSuperlayer];
        self.lastStyle = style;
    }
    // 轻弹（键帽发光）独立开关：默认关；开启后叠加在任意样式上，
    // 行为与「轻弹」样式一致——只改变按下的那一颗键帽的颜色。
    id lightPopValue = self.config[@"LightPop"];
    BOOL lightPop = lightPopValue ? [lightPopValue boolValue] : NO;
    BOOL doLightPop = lightPop || style == 2;
    if (style == 1 && !weType && [self usesNativeKeycapGlow]) {
        [self showNativeWeTypeSpreadAtPoint:point];
        return;
    }
    if (style == 1 && !weType && [self usesNativeKeycapGlow]) {
        if (doLightPop) [self showNeonPressAtPoint:point sourceView:sourceView evictAll:NO];
        [self showNativeWeTypeSpreadAtPoint:point];
        return;
    }
    if (style == 3) {
        if (doLightPop) [self showNeonPressAtPoint:point sourceView:sourceView evictAll:NO];
        [self showCrispUnderlightAtPoint:point];
        return;
    }
    if (style == 0 || style == 1) {
        if (doLightPop) [self showNeonPressAtPoint:point sourceView:sourceView evictAll:NO];
        [self showBedEffectAtPoint:point style:style];
        return;
    }
    if (style == 2) [self showNeonPressAtPoint:point sourceView:sourceView evictAll:YES];
}

// 「轻弹」原版行为：只改变按下的那一颗键帽的颜色（单色自选或逐次换色），
// 无渐变、高光或外围扩散。由 EffectStyle==2 触发，或由独立开关 LightPop
// 叠加到其他样式上。evictAll=样式本身是轻弹时沿用原有通用逐出；作为叠加层时
// 不逐出主样式的脉冲（旧键帽发光层已由 clearLegacyKeycapFeedback 清理）。
- (void)showNeonPressAtPoint:(CGPoint)point sourceView:(UIView *)sourceView evictAll:(BOOL)evictAll {
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat duration = [self number:@"Duration" fallback:.55 low:.15 high:1.2];
    if (evictAll) {
        NSUInteger limit = (NSUInteger)[self number:@"MaxEffects" fallback:4 low:1 high:8];
        while (self.layer.sublayers.count >= limit) [self.layer.sublayers.firstObject removeFromSuperlayer];
    }
    NSInteger mode = (NSInteger)[self number:@"ColorMode" fallback:0 low:0 high:2];
    self.hue = fmod(self.hue + .137, 1);
    CGFloat hue = mode == 1 ? [self number:@"Hue" fallback:.55 low:0 high:1] : (mode == 2 ? point.x / MAX(1,self.bounds.size.width) : self.hue);
    for (NSValue *value in self.keyFrames) {
        if (!CGRectContainsPoint(value.CGRectValue, point)) continue;
        self.pressHue = fmod(self.pressHue + .38196601125, 1);
        BOOL single = [self number:@"PressColorMode" fallback:0 low:0 high:1] == 1;
        UIColor *color = single ? RKKeyboardColor(self.config, @"PressColor") :
            [UIColor colorWithHue:self.pressHue saturation:1 brightness:1 alpha:1];
        CGFloat pressBrightness = [self number:@"PressBrightness" fallback:1 low:0 high:1];
        NSInteger theme = [self.config[@"Theme"] integerValue];
        if (theme >= 1 && theme <= 9) {
            // Preset themes take priority; Custom retains independent press colors.
            color = [UIColor colorWithHue:hue saturation:[self neonSaturation:1]
                                   brightness:1 alpha:1];
            pressBrightness = brightness;
        }
        RKShowNeonKeyPress(self, value.CGRectValue, color,
            pressBrightness,
            duration, UIAccessibilityIsReduceMotionEnabled() || [self flag:@"SmartPerformance"], sourceView);
        break;
    }
}
@end
