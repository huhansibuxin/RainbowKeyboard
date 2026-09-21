#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import "RKPreferences.h"

static NSDictionary *RKCandidatePrefs;
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

static NSDictionary *RKCandidateReadPreferences(void) {
    return RKReadEffectivePreferences();
}

static BOOL RKCandidateRegion(UIView *view) {
    for (UIView *p = view; p; p = p.superview) {
        NSString *name = NSStringFromClass(p.class).lowercaseString;
        if ([name containsString:@"candidate"] || [name containsString:@"prediction"] || [name containsString:@"suggestion"]) return YES;
        if ([p isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}
static BOOL RKNativeCandidateRegion(UIView *view) {
    for (UIView *parent = view; parent; parent = parent.superview) {
        NSString *name = NSStringFromClass(parent.class);
        if (([name hasPrefix:@"UIKB"] && [name containsString:@"Candidate"]) ||
            [name hasPrefix:@"UIKeyboardCandidate"] || [name hasPrefix:@"TUICandidate"] ||
            [name hasPrefix:@"TUIInlineCandidate"] || [name hasPrefix:@"TUIPrediction"] ||
            [name hasPrefix:@"UIKeyboardPrediction"] || [name hasPrefix:@"_UIKeyboardCandidate"]) return YES;
        if ([parent isKindOfClass:UIWindow.class]) break;
    }
    return NO;
}
static BOOL RKCandidateFlag(NSString *key) {
    return !RKCandidatePrefs[key] || [RKCandidatePrefs[key] boolValue];
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
    UIColor *first = RKCandidateColor(RKCandidatePrefs[@"CandidateStart"], [UIColor colorWithRed:0 green:.65 blue:1 alpha:1]);
    UIColor *last = RKCandidateColor(RKCandidatePrefs[@"CandidateEnd"], [UIColor colorWithRed:.85 green:.15 blue:1 alpha:1]);
    NSArray *colors = @[(id)first.CGColor,(id)last.CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGColorSpaceRelease(space);
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
            CGPointMake(CGRectGetMinX(textRect), CGRectGetMidY(textRect)),
            CGPointMake(CGRectGetMaxX(textRect), CGRectGetMidY(textRect)),
            kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    } @finally {
        RKCandidateDrawingDepth--;
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
        CGGradientRelease(gradient);
    }
}
static void RKDrawCandidate(UILabel *label, CGRect rect, BOOL native, void (^original)(void)) {
    if (RKCandidateIsWeType(label)) native = NO;
    BOOL region = native ? RKNativeCandidateRegion(label) : RKCandidateRegion(label);
    if (!region || RKCandidateDrawingDepth) { original(); return; }
    [RKCandidateViews addObject:label];
    if (!RKCandidateFlag(@"CandidateGradient") ||
        !RKCandidateFlag(native ? @"CandidateNative" : @"CandidateWeType")) {
        RKCandidateDrawingDepth++;
        @try { original(); } @finally { RKCandidateDrawingDepth--; }
        return;
    }
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
    return %orig;
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
    RKDrawCandidate(self, rect, YES, ^{
        %orig;
    });
}
%end

// Scope custom string drawing to native candidate views. Never tint their backgrounds.
%hook UIView
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context {
    BOOL candidate = RKNativeCandidateRegion(self);
    if (!candidate) {
        %orig;
        return;
    }
    [RKCandidateViews addObject:self];
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
    if (!RKNativeTextDrawingEnabled()) {
        %orig;
        return;
    }
    CGSize size = [(NSString *)self boundingRectWithSize:rect.size options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:attributes context:nil].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{
        %orig;
    });
}
- (void)drawAtPoint:(CGPoint)point withAttributes:(NSDictionary *)attributes {
    if (!RKNativeTextDrawingEnabled()) {
        %orig;
        return;
    }
    CGRect rect = {point, [(NSString *)self sizeWithAttributes:attributes]};
    RKDrawGradientText(rect, rect, ^{
        %orig;
    });
}
- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options attributes:(NSDictionary *)attributes context:(NSStringDrawingContext *)context {
    if (!RKNativeTextDrawingEnabled()) {
        %orig;
        return;
    }
    CGSize size = [(NSString *)self boundingRectWithSize:rect.size options:options attributes:attributes context:context].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{
        %orig;
    });
}
%end

%hook NSAttributedString
- (void)drawInRect:(CGRect)rect {
    if (!RKNativeTextDrawingEnabled()) {
        %orig;
        return;
    }
    CGSize size = [(NSAttributedString *)self boundingRectWithSize:rect.size
        options:NSStringDrawingUsesLineFragmentOrigin context:nil].size;
    RKDrawGradientText(rect, (CGRect){rect.origin, size}, ^{
        %orig;
    });
}
- (void)drawAtPoint:(CGPoint)point {
    if (!RKNativeTextDrawingEnabled()) {
        %orig;
        return;
    }
    CGRect rect = {point, [(NSAttributedString *)self size]};
    RKDrawGradientText(rect, rect, ^{
        %orig;
    });
}
- (void)drawWithRect:(CGRect)rect options:(NSStringDrawingOptions)options context:(NSStringDrawingContext *)context {
    if (!RKNativeTextDrawingEnabled()) {
        %orig;
        return;
    }
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
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { RKCandidateReload(); }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            RKCandidateReload();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                RKWriteNativeDiagnostic();
            });
        }];
    }
}
