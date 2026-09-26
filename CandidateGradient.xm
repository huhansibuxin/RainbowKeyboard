#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import "RKPreferences.h"
#import "RKKeyboardGeometry.h"

static NSDictionary *RKCandidatePrefs;
static CGGradientRef RKCandidateCachedGradient;
static NSHashTable<UIView *> *RKCandidateViews;
static __thread NSUInteger RKCandidateDrawingDepth;
static __thread NSUInteger RKNativeDrawingScope;
static __thread NSUInteger RKCandidateRenderCount;
static char RKCandidateRenderedKey;
static BOOL RKTUIHookInstalled;
static BOOL RKPredictionHookInstalled;
static NSUInteger RKTUIGlyphDraws;
static NSUInteger RKNativeLabelDraws;
static os_unfair_lock RKHookLock = OS_UNFAIR_LOCK_INIT;
static BOOL RKHookInstallQueued;
static void RKWriteNativeDiagnostic(void);

#pragma mark - Candidate gradient animation

static BOOL RKCandidateFlag(NSString *key);

static CADisplayLink *RKCandidateDisplayLink;
static CFTimeInterval RKCandidatePhaseStart;
static CGFloat RKCandidateAnimationSpeed = 0.14;

@interface RKCandidateAnimatorProxy : NSObject
+ (instancetype)shared;
- (void)tick:(CADisplayLink *)link;
@end

@implementation RKCandidateAnimatorProxy
+ (instancetype)shared {
    static RKCandidateAnimatorProxy *proxy;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ proxy = [self new]; });
    return proxy;
}
- (void)tick:(CADisplayLink *)link {
    if (!RKCandidateDisplayLink) return;
    if (!RKCandidateFlag(@"CandidateGradient") || !RKCandidateAnimatedMode() || RKCandidateViews.count == 0) {
        [link invalidate];
        RKCandidateDisplayLink = nil;
        return;
    }
    link.preferredFramesPerSecond = 20;
    for (UIView *view in RKCandidateViews.allObjects) {
        if (!view.window || view.hidden || view.alpha <= 0.01 || CGRectIsEmpty(view.bounds)) continue;
        BOOL visible = YES;
        for (UIView *parent = view.superview; parent; parent = parent.superview) {
            if (parent.hidden || parent.alpha <= 0.01) { visible = NO; break; }
        }
        if (!visible) continue;
        if (!CGRectIntersectsRect([view convertRect:view.bounds toView:view.window], view.window.bounds)) continue;
        // setNeedsDisplay already invalidates the backing layer.
        [view setNeedsDisplay];
    }
}
@end

static CGFloat RKCandidateAnimationPhase(void) {
    if (!RKCandidatePhaseStart) return 0;

    CFTimeInterval elapsed = CACurrentMediaTime() - RKCandidatePhaseStart;
    CGFloat raw = fmod((CGFloat)(elapsed * RKCandidateAnimationSpeed), 1.0);
    if (raw < 0) raw += 1.0;

    // Smooth periodic motion: velocity is zero at both ends, so the
    // gradient never snaps when the animation loops.
    return 0.5 - 0.5 * cos(raw * M_PI * 2.0);
}

static void RKCandidateStartAnimationIfNeeded(void) {
    if (!RKCandidateFlag(@"CandidateGradient") || !RKCandidateAnimatedMode() || RKCandidateViews.count == 0) return;
    if (RKCandidateDisplayLink) return;

    RKCandidatePhaseStart = CACurrentMediaTime();
    RKCandidateDisplayLink =
        [CADisplayLink displayLinkWithTarget:[RKCandidateAnimatorProxy shared]
                                     selector:@selector(tick:)];
    // Only the decorative gradient is throttled; input and layout are untouched.
    RKCandidateDisplayLink.preferredFramesPerSecond = 20;
    [RKCandidateDisplayLink addToRunLoop:[NSRunLoop mainRunLoop]
                                 forMode:NSRunLoopCommonModes];
}

static void RKCandidateStopAnimation(void) {
    [RKCandidateDisplayLink invalidate];
    RKCandidateDisplayLink = nil;
}

static NSDictionary *RKCandidateReadPreferences(void) {
    return RKReadEffectivePreferences();
}

static BOOL RKCandidateRegion(UIView *view) {
    for (UIView *p = view; p; p = p.superview) {
        if ((RKClassFeatures(p.class) & RKFeatureCandidateArea) != 0) return YES;
        if ([p isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}
static BOOL RKNativeCandidateRegion(UIView *view) {
    for (UIView *parent = view; parent; parent = parent.superview) {
        if ((RKClassFeatures(parent.class) & RKFeatureCandidateUI) != 0) return YES;
        if ([parent isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}
// 区域判定结果按视图缓存（锚点 = 所属 superview，变更即重算）：
// 候选标签复用频繁，链爬结果在布局不变期间不会变，无需每次重画都爬一遍。
static char RKRegionWeTypeResultKey, RKRegionWeTypeAnchorKey;
static char RKRegionNativeResultKey, RKRegionNativeAnchorKey;
static BOOL RKCandidateRegionCached(UIView *view, BOOL native) {
    void *resultKey = native ? &RKRegionNativeResultKey : &RKRegionWeTypeResultKey;
    void *anchorKey = native ? &RKRegionNativeAnchorKey : &RKRegionWeTypeAnchorKey;
    NSNumber *cached = objc_getAssociatedObject(view, resultKey);
    if (cached && objc_getAssociatedObject(view, anchorKey) == view.superview) return cached.boolValue;
    BOOL result = native ? RKNativeCandidateRegion(view) : RKCandidateRegion(view);
    objc_setAssociatedObject(view, resultKey, @(result), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, anchorKey, view.superview, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}
static BOOL RKCandidateFlag(NSString *key) {
    return !RKCandidatePrefs[key] || [RKCandidatePrefs[key] boolValue];
}
// 候选渐变模式：0=关闭 1=静态渐变 2=流动 3=呼吸 4=彩虹 5=跟随输入。
// 只有动画档（2..5）值得起 20fps DisplayLink；静态与关闭一律不轮询，
// 静态只在候选内容变化时随系统重绘画一次（相位固定为 0）。
static NSInteger RKCandidateGradientMode(void) {
    id value = RKCandidatePrefs[@"CandidateGradientMode"];
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 1;
}
static BOOL RKCandidateAnimatedMode(void) {
    NSInteger mode = RKCandidateGradientMode();
    return mode >= 2 && mode <= 5;
}
static BOOL RKCandidateIsWeType(UIView *view) {
    if ([NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"]) return YES;
    Class label = NSClassFromString(@"WBTextItemLabel");
    for (UIView *parent = view; parent; parent = parent.superview)
        if (label && [parent isKindOfClass:label]) return YES;
    return NO;
}
static UIColor *RKCandidateColor(id value, UIColor *fallback) {
    if (![value isKindOfClass:NSArray.class] || [value count] != 3) return fallback;
    for (id component in value) {
        if (![component isKindOfClass:NSNumber.class] || !isfinite([component doubleValue])) return fallback;
    }
    return [UIColor colorWithRed:MIN(1,MAX(0,[value[0] doubleValue]))
                           green:MIN(1,MAX(0,[value[1] doubleValue]))
                            blue:MIN(1,MAX(0,[value[2] doubleValue])) alpha:1];
}
static void RKCandidateReload(void) {
    NSDictionary *preferences = RKCandidateReadPreferences();
    if ([RKCandidatePrefs isEqual:preferences]) return;
    RKCandidatePrefs = preferences;
    if (RKCandidateCachedGradient) {
        CGGradientRelease(RKCandidateCachedGradient);
        RKCandidateCachedGradient = NULL;
    }
    RKCandidatePhaseStart = CACurrentMediaTime();
    if (!RKCandidateFlag(@"CandidateGradient") || !RKCandidateAnimatedMode()) RKCandidateStopAnimation();
    for (UIView *view in RKCandidateViews.allObjects) {
        // Drop our rendered pixels, not the original text, so disabled gradients
        // do not remain in a reused label's backing layer.
        if (objc_getAssociatedObject(view, &RKCandidateRenderedKey)) {
            view.layer.contents = nil;
            objc_setAssociatedObject(view, &RKCandidateRenderedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [view.layer setNeedsDisplay];
        [view setNeedsDisplay];
        [view setNeedsLayout];
        [view.superview setNeedsLayout];
    }
}
static void RKCandidateChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ RKCandidateReload(); });
}
static void RKDrawGradientText(CGRect rect, CGRect textRect, void (^original)(void)) {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (RKCandidateDrawingDepth || !ctx || CGRectIsEmpty(textRect)) { original(); return; }
    if (!RKCandidateCachedGradient) {
        UIColor *first = RKCandidateColor(RKCandidatePrefs[@"CandidateStart"], [UIColor colorWithRed:0 green:.65 blue:1 alpha:1]);
        UIColor *last = RKCandidateColor(RKCandidatePrefs[@"CandidateEnd"], [UIColor colorWithRed:.85 green:.15 blue:1 alpha:1]);
        NSArray *colors = @[(id)first.CGColor,(id)last.CGColor];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        RKCandidateCachedGradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGColorSpaceRelease(space);
    }
    CGGradientRef gradient = RKCandidateCachedGradient ? CGGradientRetain(RKCandidateCachedGradient) : NULL;
    CGFloat phase = RKCandidateAnimatedMode() ? RKCandidateAnimationPhase() : 0;
    CGFloat travel = CGRectGetWidth(textRect) * 0.42 * phase;
    if (!gradient) { original(); return; }
    RKCandidateRenderCount++;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGContextBeginTransparencyLayer(ctx, NULL);
    RKCandidateDrawingDepth++;
    @try {
        original();
        CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
        CGContextDrawLinearGradient(ctx, gradient,
            CGPointMake(CGRectGetMinX(textRect) - travel, CGRectGetMidY(textRect)),
            CGPointMake(CGRectGetMaxX(textRect) - travel, CGRectGetMidY(textRect)),
            kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    } @finally {
        RKCandidateDrawingDepth--;
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
        CGGradientRelease(gradient);
    }
}
static void RKDrawCandidate(UILabel *label, CGRect rect, BOOL native, void (^original)(void)) {
    if (RKCandidateDrawingDepth) { original(); return; }
    if (RKCandidateIsWeType(label)) native = NO;
    BOOL region = RKCandidateRegionCached(label, native);
    if (!region || RKCandidateDrawingDepth) { original(); return; }
    [RKCandidateViews addObject:label];
    if (RKCandidateGradientMode() == 0 || !RKCandidateFlag(@"CandidateGradient") ||
        !RKCandidateFlag(native ? @"CandidateNative" : @"CandidateWeType")) {
        RKCandidateDrawingDepth++;
        @try { original(); } @finally { RKCandidateDrawingDepth--; }
        return;
    }
    RKCandidateStartAnimationIfNeeded();
    if (native) RKNativeLabelDraws++;
    objc_setAssociatedObject(label, &RKCandidateRenderedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGRect textRect = [label textRectForBounds:rect limitedToNumberOfLines:label.numberOfLines];
    RKDrawGradientText(rect, textRect, original);
}
static BOOL RKNativeTextDrawingEnabled(void) {
    return RKNativeDrawingScope && !RKCandidateDrawingDepth &&
        RKCandidateFlag(@"CandidateGradient") &&
        RKCandidateFlag(RKCandidateIsWeType(nil) ? @"CandidateWeType" : @"CandidateNative");
}

// TUICandidateLabel draws CoreText directly. Capture just its drawRect glyphs, not
// its background, and use their ink bounds so short words get both endpoint colors.
static void RKDrawNativeGlyphView(UIView *view, CGRect dirtyRect, void (^original)(void)) {
    [RKCandidateViews addObject:view];
    CGRect bounds = view.bounds;
    if (!RKCandidateFlag(@"CandidateGradient") ||
        !RKCandidateFlag(RKCandidateIsWeType(view) ? @"CandidateWeType" : @"CandidateNative") ||
        RKCandidateDrawingDepth || !UIGraphicsGetCurrentContext() || CGRectIsEmpty(bounds) ||
        bounds.size.width > 2048 || bounds.size.height > 512) { original(); return; }
    RKCandidateStartAnimationIfNeeded();
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    format.scale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    if (bounds.size.width * bounds.size.height * format.scale * format.scale > 2097152) {
        original();
        return;
    }
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format];
    __block UIImage *glyphs;
    RKCandidateDrawingDepth++;
    @try {
        glyphs = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextTranslateCTM(context.CGContext, -bounds.origin.x, -bounds.origin.y);
            original();
        }];
    } @finally { RKCandidateDrawingDepth--; }
    CGImageRef image = glyphs.CGImage;
    if (!image) { original(); return; }
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef scan = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!scan) { original(); return; }
    CGContextDrawImage(scan, CGRectMake(0, 0, width, height), image);
    const uint8_t *bytes = (const uint8_t *)pixels.bytes;
    size_t minX = width, maxX = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (bytes[(y * width + x) * 4 + 3] > 8) { minX = MIN(minX, x); maxX = MAX(maxX, x); }
        }
    }
    CGContextRelease(scan);
    if (minX > maxX) return;
    CGRect ink = CGRectMake(bounds.origin.x + minX / glyphs.scale, bounds.origin.y,
                            (maxX - minX + 1) / glyphs.scale, bounds.size.height);
    RKTUIGlyphDraws++;
    objc_setAssociatedObject(view, &RKCandidateRenderedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (RKTUIGlyphDraws == 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            RKWriteNativeDiagnostic();
        });
    }
    RKDrawGradientText(CGRectIntersection(bounds, dirtyRect), ink, ^{ [glyphs drawInRect:bounds]; });
}

%group RKTUINative
%hook TUICandidateLabel
- (void)drawRect:(CGRect)rect {
    RKDrawNativeGlyphView((UIView *)self, rect, ^{ 
        %orig;
 });
}
%end
%end

%group RKTUIPrediction
%hook TUIPredictionViewCell
- (BOOL)_usesMorphingLabelForCandidate:(id)candidate {
    // UIKit's normal-label path preserves layout and selection, unlike tinting
    // individual cached morphing images (which would restart the gradient per glyph).
    if (RKCandidateFlag(@"CandidateGradient") && RKCandidateFlag(@"CandidateNative")) return NO;
    return 
        %orig;

}
%end
%end

static void RKInstallNativeCandidateHook(void) {
    BOOL changed = NO;
    if (!RKTUIHookInstalled) {
        Class cls = NSClassFromString(@"TUICandidateLabel");
        NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:@selector(drawRect:)];
        if (cls && [cls isSubclassOfClass:UIView.class] && signature.numberOfArguments == 3 &&
            !strcmp(signature.methodReturnType, @encode(void)) &&
            !strcmp([signature getArgumentTypeAtIndex:2], @encode(CGRect))) {
            %init(RKTUINative);
            RKTUIHookInstalled = YES;
            changed = YES;
        }
    }
    if (!RKPredictionHookInstalled) {
        Class cls = NSClassFromString(@"TUIPredictionViewCell");
        NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:
            NSSelectorFromString(@"_usesMorphingLabelForCandidate:")];
        if (cls && [cls isSubclassOfClass:UIView.class] && signature.numberOfArguments == 3 &&
            !strcmp(signature.methodReturnType, @encode(BOOL)) &&
            !strcmp([signature getArgumentTypeAtIndex:2], @encode(id))) {
            %init(RKTUIPrediction);
            RKPredictionHookInstalled = YES;
            changed = YES;
        }
    }
    if (changed) for (UIView *view in RKCandidateViews) [view setNeedsDisplay];
}
static void RKCandidateImageLoaded(const struct mach_header *header, intptr_t slide) {
    os_unfair_lock_lock(&RKHookLock);
    BOOL enqueue = !RKHookInstallQueued;
    RKHookInstallQueued = YES;
    os_unfair_lock_unlock(&RKHookLock);
    if (!enqueue) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&RKHookLock);
        RKHookInstallQueued = NO;
        os_unfair_lock_unlock(&RKHookLock);
        RKInstallNativeCandidateHook();
    });
}
static void RKWriteNativeDiagnostic(void) {
    RKInstallNativeCandidateHook();
    NSMutableSet *classes = [NSMutableSet set];
    for (UIView *view in RKCandidateViews) [classes addObject:NSStringFromClass(view.class)];
    Class cls = NSClassFromString(@"TUICandidateLabel");
    Method draw = cls ? class_getInstanceMethod(cls, @selector(drawRect:)) : NULL;
    NSDictionary *report = @{@"version":@"samsung8",
        @"systemVersion":UIDevice.currentDevice.systemVersion,
        @"processBundle":NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"nativeClassLoaded":@(cls != Nil), @"nativeGlyphHookInstalled":@(RKTUIHookInstalled),
        @"nativePredictionHookInstalled":@(RKPredictionHookInstalled),
        @"nativeLabelDrawCount":@(RKNativeLabelDraws),
        @"nativeGlyphDrawCount":@(RKTUIGlyphDraws),
        @"drawEncoding":draw ? @(method_getTypeEncoding(draw)) : @"missing",
        @"observedViewClasses":classes.allObjects,
        @"CandidateGradient":@(RKCandidateFlag(@"CandidateGradient")),
        @"CandidateNative":@(RKCandidateFlag(@"CandidateNative")),
        @"CandidateWeType":@(RKCandidateFlag(@"CandidateWeType")),
        @"settingsRevision":@(RKPreferencesRevision(RKCandidatePrefs))};
    NSString *file = [NSString stringWithFormat:@"RainbowKeyboard-native-probe-%@.plist",
        NSBundle.mainBundle.bundleIdentifier ?: @"unknown"];
    NSString *path = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
    if (![report writeToFile:path atomically:YES])
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:file] atomically:YES];
}

%hook UILabel
- (void)drawTextInRect:(CGRect)rect {
    if (!RKKeyboardSessionActive()) {
        %orig;
        return;
    }
    RKDrawCandidate(self, rect, YES, ^{ 
        %orig;
 });
}
%end

// Scope custom string drawing to native candidate views. Never tint their backgrounds.
%hook UIView
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context {
    if (!RKKeyboardSessionActive()) {
        %orig(layer, context);
        return;
    }
    BOOL candidate = RKCandidateRegionCached(self, YES);
    if (!candidate) { 
        %orig;
 return; }
    [RKCandidateViews addObject:self];
    if (RKCandidateFlag(@"CandidateGradient")) RKCandidateStartAnimationIfNeeded();
    NSUInteger before = RKCandidateRenderCount;
    RKNativeDrawingScope++;
    @try { 
        %orig;
 } @finally {
        RKNativeDrawingScope--;
        if (RKCandidateRenderCount != before)
            objc_setAssociatedObject(self, &RKCandidateRenderedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
%end

%hook NSString
- (void)drawInRect:(CGRect)rect withAttributes:(NSDictionary *)attributes {
    if (!RKKeyboardSessionActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGSize size = [(NSString *)self boundingRectWithSize:rect.size options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:attributes context:nil].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{ 
        %orig;
 });
}
- (void)drawAtPoint:(CGPoint)point withAttributes:(NSDictionary *)attributes {
    if (!RKKeyboardSessionActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGRect rect = {point, [(NSString *)self sizeWithAttributes:attributes]};
    RKDrawGradientText(rect, rect, ^{ 
        %orig;
 });
}
- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options attributes:(NSDictionary *)attributes context:(NSStringDrawingContext *)context {
    if (!RKKeyboardSessionActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGSize size = [(NSString *)self boundingRectWithSize:rect.size options:options attributes:attributes context:context].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{ 
        %orig;
 });
}
%end

%hook NSAttributedString
- (void)drawInRect:(CGRect)rect {
    if (!RKKeyboardSessionActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGSize size = [(NSAttributedString *)self boundingRectWithSize:rect.size
        options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{ 
        %orig;
 });
}
- (void)drawAtPoint:(CGPoint)point {
    if (!RKKeyboardSessionActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGRect rect = {point, [(NSAttributedString *)self size]};
    RKDrawGradientText(rect, rect, ^{ 
        %orig;
 });
}
- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options context:(NSStringDrawingContext *)context {
    if (!RKKeyboardSessionActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGSize size = [(NSAttributedString *)self boundingRectWithSize:rect.size options:options context:context].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{ 
        %orig;
 });
}
%end

// WeType overrides UILabel drawing; keep its existing concrete hook.
%hook WBTextItemLabel
- (void)drawTextInRect:(CGRect)rect {
    RKDrawCandidate((UILabel *)self, rect, NO, ^{ 
        %orig;
 });
}
%end
%ctor {
    @autoreleasepool {
        RKCandidateViews = [NSHashTable weakObjectsHashTable];
        RKCandidateReload();
        %init;
        RKInstallNativeCandidateHook();
        _dyld_register_func_for_add_image(RKCandidateImageLoaded);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, RKCandidateChanged,
            CFSTR("com.minis.rainbowkeyboard.changed"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        // block observer 的 token 必须持有，否则 ARC 下立即释放导致通知失效。
        static id candidateObserverTokens[2];
        candidateObserverTokens[0] = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { RKCandidateReload(); }];
        candidateObserverTokens[1] = [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            RKCandidateReload();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                RKWriteNativeDiagnostic();
            });
        }];
    }
}
