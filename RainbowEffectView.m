#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
#import "RKNeonPress.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import "RKPreferences.h"
static NSDictionary *RKReadPreferences(void) {
    return RKReadEffectivePreferences();
}
// showRippleAtPoint: runs on every key press and the bundle identifier cannot change
// at runtime, so the keyboard type is resolved once instead of lowercasing the
// identifier (two string allocations) on every keystroke.
static BOOL RKIsWeTypeProcess(void) {
    static BOOL weType;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        weType = [NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"];
    });
    return weType;
}
// Animation values, keyTimes and gradient locations are constants, yet the old code
// rebuilt these arrays -- and every NSNumber inside them -- on every keystroke: 10
// arrays plus 42 numbers per press for the ambient pass alone, then 1 array plus 4
// numbers per animated key for its fade keyTimes. They are immutable and Core
// Animation only reads them, so a single shared copy is safe and produces the same
// animation.
enum { RKConstAmbientLocations, RKConstSpreadValues, RKConstSpreadKeyTimes,
       RKConstAmbientFadeValues, RKConstAmbientFadeKeyTimes, RKConstKeyFadeKeyTimes,
       RKConstCount };
static NSArray *RKAnimConstant(NSUInteger index) {
    static NSArray *table[RKConstCount];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table[RKConstAmbientLocations]    = @[@0, @.22, @.52, @.78, @1];
        table[RKConstSpreadValues]        = @[@.04, @.64, @1, @1.08];
        table[RKConstSpreadKeyTimes]      = @[@0, @.32, @.7, @1];
        table[RKConstAmbientFadeValues]   = @[@0, @1, @.9, @0];
        table[RKConstAmbientFadeKeyTimes] = @[@0, @.08, @.52, @1];
        table[RKConstKeyFadeKeyTimes]     = @[@0, @.12, @.38, @1];
    });
    return index < RKConstCount ? table[index] : nil;
}
@interface RainbowEffectView ()
@property(nonatomic,strong) NSDictionary *config;
@property(nonatomic) CGFloat hue;
@property(nonatomic) CGFloat pressHue;
@property(nonatomic) NSInteger lastStyle;
@end
@implementation RainbowEffectView {
    // Cached compound "gaps" path for the gutter light. It depends only on bounds and
    // the key frames, yet the old code rebuilt all of them (one rounded-rect bezier
    // path per key) on every single keystroke.
    CGPathRef _gutterPath;
    CGRect _gutterPathBounds;
    BOOL _gutterPathValid;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadConfiguration) name:UIApplicationDidBecomeActiveNotification object:nil];
        [self reloadConfiguration];
    }
    return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_gutterPath) CGPathRelease(_gutterPath);
}
- (void)reloadConfiguration { self.config = RKReadPreferences(); }
- (CGFloat)number:(NSString *)key fallback:(CGFloat)fallback low:(CGFloat)low high:(CGFloat)high {
    id x = self.config[key];
    CGFloat v = [x respondsToSelector:@selector(doubleValue)] ? [x doubleValue] : fallback;
    return isfinite(v) ? MIN(high,MAX(low,v)) : fallback;
}
- (BOOL)flag:(NSString *)key { return !self.config[key] || [self.config[key] boolValue]; }
- (CGFloat)neonSaturation:(CGFloat)base {
    return base * [self number:@"NeonSaturation" fallback:.72 low:0 high:1];
}
- (BOOL)preservesBlackFaces {
    // 自定义键帽与底色已移除，键帽一律使用系统原生配色，不再保留黑色键面。
    return NO;
}
// The compound path (keyboard rect + even-odd key faces) is a pure function of
// self.bounds and self.keyFrames. Rebuild it only when one of those changes.
- (CGPathRef)keyGutterPath {
    if (_gutterPathValid && CGRectEqualToRect(_gutterPathBounds, self.bounds)) return _gutterPath;
    UIBezierPath *gaps = [UIBezierPath bezierPathWithRect:self.bounds];
    for (NSValue *value in self.keyFrames) [gaps appendPath:RKKeyboardKeyFacePath(value.CGRectValue)];
    CGPathRef built = CGPathCreateCopy(gaps.CGPath);
    if (_gutterPath) CGPathRelease(_gutterPath);
    _gutterPath = built;
    _gutterPathBounds = self.bounds;
    _gutterPathValid = (built != NULL);
    return _gutterPath;
}
- (CAShapeLayer *)keyGutterMask {
    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = self.bounds;
    mask.path = [self keyGutterPath];
    mask.fillRule = kCAFillRuleEvenOdd;
    return mask;
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
    _gutterPathValid = NO;
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
        bloom.locations = RKAnimConstant(RKConstAmbientLocations);
        bloom.opacity = 0;
        [field addSublayer:bloom];
        CAKeyframeAnimation *spread = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        spread.values = RKAnimConstant(RKConstSpreadValues);
        spread.keyTimes = RKAnimConstant(RKConstSpreadKeyTimes);
        spread.duration = duration;
        [bloom addAnimation:spread forKey:@"ambientExpansion"];
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = RKAnimConstant(RKConstAmbientFadeValues);
        fade.keyTimes = RKAnimConstant(RKConstAmbientFadeKeyTimes);
        fade.duration = duration;
        [bloom addAnimation:fade forKey:@"ambientFade"];
    }
}
- (void)showKeyWaveAtPoint:(CGPoint)point hue:(CGFloat)hue mode:(NSInteger)mode {
    if (!self.keyFrames.count) return;
    CGFloat alpha = [self number:@"Opacity" fallback:.65 low:0 high:1];
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat duration = [self number:@"Duration" fallback:.55 low:.15 high:1.2];
    CGFloat travel = [self number:@"BackgroundDuration" fallback:.4 low:.1 high:1.5];
    CGFloat spread = [self number:@"Spread" fallback:2 low:.5 high:3];
    CGFloat reach = [self number:@"BackgroundRadius" fallback:180 low:60 high:360] * spread / 2;
    CGFloat softness = [self number:@"Softness" fallback:8 low:0 high:24];
    CGFloat band = [self number:@"BackgroundBand" fallback:.55 low:.2 high:.85];
    CGFloat strength = [self number:@"BackgroundStrength" fallback:.18 low:0 high:.6];
    CGFloat core = [self number:@"CoreStrength" fallback:.5 low:0 high:1];
    BOOL propagate = [self flag:@"BackgroundFeedback"];
    CGRect pressed = CGRectNull;
    CGFloat nearest = CGFLOAT_MAX;
    for (NSValue *value in self.keyFrames) {
        CGRect rect = value.CGRectValue;
        CGFloat dx = MAX(MAX(CGRectGetMinX(rect) - point.x, 0), point.x - CGRectGetMaxX(rect));
        CGFloat dy = MAX(MAX(CGRectGetMinY(rect) - point.y, 0), point.y - CGRectGetMaxY(rect));
        CGFloat distance = hypot(dx, dy);
        if (distance < nearest) { nearest = distance; pressed = rect; }
    }
    // Ignore touches in padding / language-switch strips outside the actual keys.
    if (CGRectIsNull(pressed) || nearest > 14) return;
    CGPoint origin = CGPointMake(CGRectGetMidX(pressed), CGRectGetMidY(pressed));
    CALayer *pulse = [CALayer layer];
    pulse.frame = self.bounds;
    // Clip the entire wave, including blurred shadows and overlapping presses,
    // so no colored pixels bleed through an opaque key face.
    if ([self preservesBlackFaces]) pulse.mask = [self keyGutterMask];
    [self.layer addSublayer:pulse];
    CFTimeInterval now = [pulse convertTime:CACurrentMediaTime() fromLayer:nil];
    CGFloat tail = duration * (.45 + band);
    [self addAmbientGlowToPulse:pulse origin:origin radius:reach hue:hue mode:mode duration:travel + tail];
    for (NSValue *value in self.keyFrames) {
        CGRect rect = value.CGRectValue;
        BOOL touched = CGRectEqualToRect(rect, pressed);
        CGFloat distance = hypot(CGRectGetMidX(rect) - origin.x, CGRectGetMidY(rect) - origin.y);
        if ((!propagate && !touched) || distance > reach) continue;
        CGFloat progress = MIN(1, distance / reach);
        CGFloat keyHue = mode == 1 ? hue : fmod(hue + progress * .24, 1);
        UIColor *first = [UIColor colorWithHue:keyHue saturation:[self neonSaturation:.78] brightness:brightness alpha:1];
        UIColor *last = [UIColor colorWithHue:mode == 1 ? hue : fmod(keyHue + .12, 1)
                                 saturation:[self neonSaturation:.9] brightness:brightness alpha:1];
        UIBezierPath *outline = RKKeyboardKeyFacePath(rect);
        CGRect face = outline.bounds;
        CGFloat rimWidth = touched ? 3.0 : 2.6;
        CGRect edgeFrame = CGRectInset(face, -rimWidth, -rimWidth);
        [outline applyTransform:CGAffineTransformMakeTranslation(-edgeFrame.origin.x, -edgeFrame.origin.y)];
        CALayer *key = [CALayer layer];
        key.name = @"keyWave";
        key.frame = edgeFrame;
        key.opacity = 0;
        [pulse addSublayer:key];

        CGFloat corner = MIN(5, MIN(face.size.width, face.size.height) * .16);
        UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:key.bounds cornerRadius:corner + rimWidth];
        [outer appendPath:outline];
        CAShapeLayer *halo = [CAShapeLayer layer];
        halo.frame = key.bounds;
        halo.path = outline.CGPath;
        halo.fillColor = [self preservesBlackFaces] ? UIColor.clearColor.CGColor :
            [first colorWithAlphaComponent:touched ? core * .45 : strength * .12].CGColor;
        halo.strokeColor = [first colorWithAlphaComponent:.7].CGColor;
        halo.lineWidth = rimWidth * 2;
        halo.shadowColor = first.CGColor;
        halo.shadowOffset = CGSizeZero;
        halo.shadowRadius = softness * .6;
        halo.shadowOpacity = .8;
        [key addSublayer:halo];

        CAGradientLayer *edge = [CAGradientLayer layer];
        edge.frame = key.bounds;
        edge.colors = @[(id)first.CGColor, (id)last.CGColor];
        edge.startPoint = CGPointZero;
        edge.endPoint = CGPointMake(1, 1);
        CAShapeLayer *rim = [CAShapeLayer layer];
        rim.frame = key.bounds;
        // A filled outer ring keeps its full visible width after the black-face
        // exclusion mask; a centered stroke would lose its inner half.
        rim.path = outer.CGPath;
        rim.fillRule = kCAFillRuleEvenOdd;
        rim.fillColor = UIColor.whiteColor.CGColor;
        edge.mask = rim;
        [key addSublayer:edge];

        CGFloat peak = alpha * (1 - progress * .42);
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[@0, @(peak), @(peak * .72), @0];
        fade.keyTimes = RKAnimConstant(RKConstKeyFadeKeyTimes);
        fade.duration = tail;
        fade.beginTime = now + progress * travel;
        [key addAnimation:fade forKey:@"keyWave"];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((travel + tail + .05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [pulse removeFromSuperlayer]; });
}
- (void)showRippleAtPoint:(CGPoint)point {
    [self showRippleAtPoint:point sourceView:nil];
}
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView {
    [self reloadConfiguration];
    BOOL weType = RKIsWeTypeProcess();
    if (![self flag:@"Enabled"] || ![self flag:@"RippleEnabled"] || ![self flag:weType ? @"WeChatKeyboard" : @"NativeKeyboard"]) {
        for (CALayer *l in self.layer.sublayers.copy) [l removeFromSuperlayer];
        return;
    }
    NSInteger style = (NSInteger)[self number:@"EffectStyle" fallback:0 low:0 high:2];
    if (style != self.lastStyle) {
        for (CALayer *layer in self.layer.sublayers.copy) [layer removeFromSuperlayer];
        self.lastStyle = style;
    }
    CGFloat alpha = [self number:@"Opacity" fallback:.65 low:0 high:1];
    CGFloat brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    CGFloat duration = [self number:@"Duration" fallback:.55 low:.15 high:1.2];
    CGFloat spread = [self number:@"Spread" fallback:2 low:.5 high:3];
    CGFloat softness = [self number:@"Softness" fallback:8 low:0 high:24];
    CGFloat core = [self number:@"CoreStrength" fallback:.5 low:0 high:1];
    NSUInteger limit = (NSUInteger)[self number:@"MaxEffects" fallback:4 low:1 high:8];
    while (self.layer.sublayers.count >= limit) [self.layer.sublayers.firstObject removeFromSuperlayer];
    NSInteger mode = (NSInteger)[self number:@"ColorMode" fallback:0 low:0 high:2];
    self.hue = fmod(self.hue + .137, 1);
    CGFloat hue = mode == 1 ? [self number:@"Hue" fallback:.55 low:0 high:1] : (mode == 2 ? point.x / MAX(1,self.bounds.size.width) : self.hue);
    if (style == 2) {
        for (NSValue *value in self.keyFrames) {
            if (!CGRectContainsPoint(value.CGRectValue, point)) continue;
            self.pressHue = fmod(self.pressHue + .38196601125, 1);
            // 「亮色模式」（彩色/单色）已移除：轻弹固定使用逐次换色的鲜艳纯色。
            UIColor *color = [UIColor colorWithHue:self.pressHue saturation:1 brightness:1 alpha:1];
            RKShowNeonKeyPress(self, value.CGRectValue, color,
                [self number:@"PressBrightness" fallback:1 low:0 high:1],
                duration, UIAccessibilityIsReduceMotionEnabled(), sourceView);
            break;
        }
        return;
    }
    if (style == 0) {
        [self showKeyWaveAtPoint:point hue:hue mode:mode];
        return;
    }
    CGFloat radius = MIN(160, MAX(24, self.bounds.size.width / 10.0 * spread));
    CALayer *pulse = [CALayer layer];
    pulse.frame = self.bounds;
    pulse.opacity = 1; // Child layers own their final transparent states.
    [self.layer addSublayer:pulse];
    // A wide radial band travels outward from this touch. It shares the
    // keyboard exclusion mask and has no whole-keyboard solid background.
    CGFloat waveTime = duration;
    if ([self flag:@"BackgroundFeedback"]) {
        CGFloat reach = [self number:@"BackgroundRadius" fallback:180 low:60 high:360];
        CGFloat width = [self number:@"BackgroundBand" fallback:.55 low:.2 high:.85];
        CGFloat strength = [self number:@"BackgroundStrength" fallback:.28 low:0 high:.6];
        waveTime = [self number:@"BackgroundDuration" fallback:.65 low:.1 high:1.5];
        CAGradientLayer *wave = [CAGradientLayer layer];
        wave.type = kCAGradientLayerRadial;
        wave.frame = CGRectMake(point.x-reach,point.y-reach,reach*2,reach*2);
        wave.startPoint = CGPointMake(.5,.5);
        wave.endPoint = CGPointMake(1,1); // Nonzero radial extent on both axes.
        UIColor *c = [UIColor colorWithHue:hue saturation:[self neonSaturation:.8] brightness:brightness alpha:1];
        UIColor *edge = mode == 1 ? c : [UIColor colorWithHue:fmod(hue+.14,1)
            saturation:[self neonSaturation:.85] brightness:brightness alpha:1];
        wave.colors = @[(id)[c colorWithAlphaComponent:0].CGColor,
                        (id)[c colorWithAlphaComponent:0].CGColor,
                        (id)[c colorWithAlphaComponent:strength].CGColor,
                        (id)[edge colorWithAlphaComponent:strength*.5].CGColor,
                        (id)[edge colorWithAlphaComponent:0].CGColor];
        wave.locations = @[@0,@(1-width),@(1-width*.55),@(1-width*.2),@1];
        wave.opacity = 0;
        [pulse addSublayer:wave];
        CABasicAnimation *travel = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        travel.fromValue = @.025; travel.toValue = @1; travel.duration = waveTime;
        travel.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [wave addAnimation:travel forKey:@"travelFromTouch"];
        CAKeyframeAnimation *waveFade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        waveFade.values = @[@0,@1,@.85,@0]; waveFade.keyTimes = @[@0,@.06,@.65,@1];
        waveFade.duration = waveTime;
        [wave addAnimation:waveFade forKey:@"waveFade"];
    }
    NSMutableArray *colors = [NSMutableArray array];
    for (NSInteger i=0;i<5;i++) {
        CGFloat h = mode == 1 ? hue : fmod(hue + i * .12, 1);
        [colors addObject:(id)[UIColor colorWithHue:h saturation:[self neonSaturation:.85] brightness:brightness alpha:1].CGColor];
    }
    CAGradientLayer *rainbow = [CAGradientLayer layer];
    rainbow.frame = self.bounds;
    rainbow.colors = colors;
    rainbow.startPoint = CGPointMake(0,0);
    rainbow.endPoint = CGPointMake(1,1);
    [pulse addSublayer:rainbow];
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = self.bounds;
    ring.fillColor = UIColor.clearColor.CGColor;
    ring.strokeColor = UIColor.whiteColor.CGColor;
    ring.lineWidth = 4 + softness * .4;
    ring.shadowColor = UIColor.whiteColor.CGColor;
    ring.shadowOpacity = .8;
    ring.shadowRadius = softness;
    ring.shadowOffset = CGSizeZero;
    UIBezierPath *start = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(point.x-3,point.y-3,6,6)];
    UIBezierPath *end = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(point.x-radius,point.y-radius,2*radius,2*radius)];
    ring.path = end.CGPath;
    rainbow.mask = ring;
    CABasicAnimation *expand = [CABasicAnimation animationWithKeyPath:@"path"];
    expand.fromValue = (__bridge id)start.CGPath;
    expand.toValue = (__bridge id)end.CGPath;
    expand.duration = duration;
    expand.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [ring addAnimation:expand forKey:@"expand"];
    CALayer *flash = [CALayer layer];
    flash.frame = CGRectMake(point.x-9,point.y-9,18,18);
    flash.cornerRadius = 9;
    UIColor *tint = [UIColor colorWithHue:hue saturation:[self neonSaturation:.5] brightness:brightness alpha:1];
    flash.backgroundColor = tint.CGColor;
    flash.shadowColor = tint.CGColor;
    flash.shadowRadius = softness;
    flash.shadowOpacity = .8;
    flash.shadowOffset = CGSizeZero;
    flash.opacity = 0;
    [pulse addSublayer:flash];
    CABasicAnimation *flashFade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    flashFade.fromValue = @(core); flashFade.toValue = @0; flashFade.duration = MIN(.2,duration*.5);
    [flash addAnimation:flashFade forKey:@"flash"];
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[@0,@(alpha),@(alpha*.6),@0];
    fade.keyTimes = @[@0,@.08,@.45,@1];
    fade.duration = duration;
    rainbow.opacity = 0;
    [rainbow addAnimation:fade forKey:@"fade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((MAX(duration,waveTime)+.05)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [pulse removeFromSuperlayer]; });
}
@end
