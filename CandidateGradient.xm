#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import "RKPreferences.h"
#import "RKAdaptivePerformance.h"
#import "RKKeyboardGeometry.h"

static NSDictionary *RKCandidatePrefs;
// 开关缓存（2.3.19）：把设置开关摊平成裸 BOOL，专供绘制钩子的**第一道闸**使用。
// 关闭「候选栏渐变」时必须真的零开销 —— 只有裸内存读能保证这一点，
// 走 RKCandidatePrefs[key] 是两次字典查（objectForKey + boolValue 消息）。
// 取值统一在 RKCandidateRefreshSwitches() 里刷新，不在任何热路径上。
static BOOL RKCandidateGradientEnabled;
static BOOL RKCandidateNativeEnabled;
static BOOL RKCandidateWeTypeEnabled;

// 总闸：所有绘制钩子的第一行。键盘没弹出、或渐变总开关关闭、或 native/wetype
// 两个子开关全关时，成本仅为「一次 volatile 读 + 一次 BOOL 读 + 一条分支」，
// 随即 %orig 原样放行 —— 不做链遍历、不插表、不开绘制作用域。
static inline BOOL RKCandidateActive(void) {
    return RKKeyboardSessionActive() && RKCandidateGradientEnabled &&
           (RKCandidateNativeEnabled || RKCandidateWeTypeEnabled);
}
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
    if (!RKCandidateActive() || RKCandidateViews.count == 0) {
        [link invalidate];
        RKCandidateDisplayLink = nil;
        return;
    }
    static NSInteger previousLevel;
    NSInteger level = RKAdaptiveLevel();
    BOOL levelChanged = level != previousLevel;
    previousLevel = level;
    link.preferredFramesPerSecond = level ? 10 : 20;
    // One redraw on transition removes/restores existing gradient pixels.
    // During pressure only natural candidate updates draw after this.
    if (level && !levelChanged) return;
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
    if (!RKCandidateGradientEnabled || RKCandidateViews.count == 0) return;
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
static BOOL RKCandidateFlag(NSString *key) {
    return !RKCandidatePrefs[key] || [RKCandidatePrefs[key] boolValue];
}
// 从偏好字典刷新三个缓存开关。仅在 RKCandidateReload()（Darwin 通知 / 键盘弹出 / 前台激活）
// 里调用，不在任何绘制路径上。
// 语义刻意不对称：总开关「缺失即关」（候选栏渐变默认关闭，缺键时绝不意外开启、绝不留开销），
// 两个子开关「缺失即开」（它们是"应用到哪种输入法"的细分，默认全开才符合直觉，也避免
// 用户打开总开关后因子开关兜底为关而看不到任何效果）。
static void RKCandidateRefreshSwitches(void) {
    RKCandidateGradientEnabled = [RKCandidatePrefs[@"CandidateGradient"] boolValue];
    RKCandidateNativeEnabled   = RKCandidateFlag(@"CandidateNative");
    RKCandidateWeTypeEnabled   = RKCandidateFlag(@"CandidateWeType");
}
static BOOL RKCandidateIsWeType(UIView *view) {
    if (RKKeyboardBundleIsWeType()) return YES;
    // 只在解析成功时缓存：WBTextItemLabel 所属框架可能在 %ctor 之后才被 dyld 载入，
    // 若用 dispatch_once 把 nil 固化，微信输入法的检测会永久失效。
    static Class labelClass;
    if (!labelClass) labelClass = NSClassFromString(@"WBTextItemLabel");
    if (!labelClass) return NO;
    for (UIView *parent = view; parent; parent = parent.superview)
        if ([parent isKindOfClass:labelClass]) return YES;
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
    RKCandidateRefreshSwitches();
    if (RKCandidateCachedGradient) {
        CGGradientRelease(RKCandidateCachedGradient);
        RKCandidateCachedGradient = NULL;
    }
    RKCandidatePhaseStart = CACurrentMediaTime();
    if (!RKCandidateGradientEnabled) RKCandidateStopAnimation();
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
    if (RKAdaptiveLevel() >= 2) { original(); return; }
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
    CGFloat phase = RKCandidateAnimationPhase();
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
    // 子开关判定提到区域判定之前：该宿主对应的开关关闭时，不再做 superview 链遍历、
    // 不再把 view 插进重绘表。depth 包装保留，语义同原实现（防 %orig 重入）。
    if (!(native ? RKCandidateNativeEnabled : RKCandidateWeTypeEnabled)) {
        RKCandidateDrawingDepth++;
        @try { original(); } @finally { RKCandidateDrawingDepth--; }
        return;
    }
    BOOL region = native ? RKNativeCandidateRegion(label) : RKCandidateRegion(label);
    if (!region || RKCandidateDrawingDepth) { original(); return; }
    [RKCandidateViews addObject:label];
    RKCandidateStartAnimationIfNeeded();
    if (native) RKNativeLabelDraws++;
    objc_setAssociatedObject(label, &RKCandidateRenderedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGRect textRect = [label textRectForBounds:rect limitedToNumberOfLines:label.numberOfLines];
    RKDrawGradientText(rect, textRect, original);
}
static BOOL RKNativeTextDrawingEnabled(void) {
    // 调用方已过 RKCandidateActive() 总闸（会话 + 总开关 + 至少一个子开关成立）。
    // 这里只需按宿主选具体子开关 —— 读缓存 BOOL，省掉字典查与 NSClassFromString(nil) 探测。
    if (!RKNativeDrawingScope || RKCandidateDrawingDepth) return NO;
    return RKKeyboardBundleIsWeType() ? RKCandidateWeTypeEnabled : RKCandidateNativeEnabled;
}

// TUICandidateLabel draws CoreText directly. Capture just its drawRect glyphs, not
// its background, and use their ink bounds so short words get both endpoint colors.
static void RKDrawNativeGlyphView(UIView *view, CGRect dirtyRect, void (^original)(void)) {
    if (RKAdaptiveLevel() >= 2 || !RKCandidateActive()) { original(); return; }
    CGRect bounds = view.bounds;
    if (!(RKCandidateIsWeType(view) ? RKCandidateWeTypeEnabled : RKCandidateNativeEnabled) ||
        RKCandidateDrawingDepth || !UIGraphicsGetCurrentContext() || CGRectIsEmpty(bounds) ||
        bounds.size.width > 2048 || bounds.size.height > 512) { original(); return; }
    // 登记推迟到确实要绘制之后：关闭开关时不再往重绘表里塞无关 view。
    [RKCandidateViews addObject:view];
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
    if (RKCandidateGradientEnabled && RKCandidateNativeEnabled) return NO;
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
// 原 RKWriteNativeDiagnostic：把「本进程看到哪些候选类 / 命中几次」写成 plist 落到
// /var/mobile/Library/Preferences（写失败再落 tmp）。它挂在 UIKeyboardDidShow 上 ⇒
// **每次键盘弹出后 1 秒都要写一次盘**，是纯粹的诊断残留（验证期产物）。
// 2.3.17 整体移除：诊断早已验完，键盘弹出路径不该有任何文件 IO。

%hook UILabel
- (void)drawTextInRect:(CGRect)rect {
    if (!RKCandidateActive()) {
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
    // 总闸在前：关闭渐变时本钩子只付一次内存读，不做 superview 链遍历、
    // 不插重绘表、不开 RKNativeDrawingScope（后者会连带唤醒下方 6 个文本钩子）。
    if (!RKCandidateActive()) {
        %orig(layer, context);
        return;
    }
    BOOL candidate = RKNativeCandidateRegion(self);
    if (!candidate) { 
        %orig;
 return; }
    [RKCandidateViews addObject:self];
    RKCandidateStartAnimationIfNeeded();
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
    if (!RKCandidateActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGSize size = [(NSString *)self boundingRectWithSize:rect.size options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:attributes context:nil].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{ 
        %orig;
 });
}
- (void)drawAtPoint:(CGPoint)point withAttributes:(NSDictionary *)attributes {
    if (!RKCandidateActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGRect rect = {point, [(NSString *)self sizeWithAttributes:attributes]};
    RKDrawGradientText(rect, rect, ^{ 
        %orig;
 });
}
- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options attributes:(NSDictionary *)attributes context:(NSStringDrawingContext *)context {
    if (!RKCandidateActive() || !RKNativeTextDrawingEnabled()) { 
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
    if (!RKCandidateActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGSize size = [(NSAttributedString *)self boundingRectWithSize:rect.size
        options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{ 
        %orig;
 });
}
- (void)drawAtPoint:(CGPoint)point {
    if (!RKCandidateActive() || !RKNativeTextDrawingEnabled()) { 
        %orig;
 return; }
    CGRect rect = {point, [(NSAttributedString *)self size]};
    RKDrawGradientText(rect, rect, ^{ 
        %orig;
 });
}
- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options context:(NSStringDrawingContext *)context {
    if (!RKCandidateActive() || !RKNativeTextDrawingEnabled()) { 
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
    // 本类重写了 drawTextInRect:，UILabel 的钩子拦不到，必须单独装钩；
    // 也正因如此，它此前是唯一没有会话/开关保护的绘制入口，此处补齐总闸。
    if (!RKCandidateActive()) {
        %orig;
        return;
    }
    RKDrawCandidate((UILabel *)self, rect, NO, ^{ 
        %orig;
 });
}
%end
%ctor {
    @autoreleasepool {
        // 进程守卫：本文件装的是 %hook UILabel / %hook NSString / %hook NSAttributedString /
        // %hook UIView -drawLayer: 这类**全进程级**文本与图层绘制钩子 —— 一旦宿主是系统 UI
        // 进程，锁屏上的文本绘制也会走进候选栏判定（表现为锁屏字体被染成渐变）。
        // 在安装任何钩子之前先挡住：系统 UI 进程里一个钩子都不装，零副作用。
        if (RKKeyboardProcessIsSystemUI()) return;
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
        }];
    }
}
