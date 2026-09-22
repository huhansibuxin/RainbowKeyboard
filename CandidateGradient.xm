#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <string.h>
#import "RKPreferences.h"
#import "RKKeyboardGeometry.h"

static NSDictionary *RKCandidatePrefs;
static NSHashTable<UIView *> *RKCandidateViews;
static __thread NSUInteger RKCandidateDrawingDepth;
static char RKCandidateRenderedKey;
static BOOL RKTUIHookInstalled;
static BOOL RKPredictionHookInstalled;
static BOOL RKHookInstallQueued;

static NSDictionary *RKCandidateReadPreferences(void) {
    return RKReadEffectivePreferences();
}

static BOOL RKCandidateFlag(NSString *key) {
    return !RKCandidatePrefs[key] || [RKCandidatePrefs[key] boolValue];
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
// weType labels are identified by their exact class -- the WBTextItemLabel hook below
// is itself the proof -- so no ancestor walk is needed for them. Native labels are
// matched against the registered candidate containers, and that test is skipped
// entirely while no candidate bar is on screen.
static void RKDrawCandidate(UILabel *label, CGRect rect, BOOL weType, void (^original)(void)) {
    if (RKCandidateDrawingDepth || !RKCandidateFlag(@"CandidateGradient")) { original(); return; }
    if (!RKCandidateFlag(weType ? @"CandidateWeType" : @"CandidateNative")) {
        RKCandidateDrawingDepth++;
        @try { original(); } @finally { RKCandidateDrawingDepth--; }
        return;
    }
    if (!weType && !RKIsInCandidateContainer(label)) { original(); return; }
    // Only a view we actually paint needs to stay reachable for later invalidation.
    [RKCandidateViews addObject:label];
    objc_setAssociatedObject(label, &RKCandidateRenderedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGRect textRect = [label textRectForBounds:rect limitedToNumberOfLines:label.numberOfLines];
    RKDrawGradientText(rect, textRect, original);
}

// TUICandidateLabel draws CoreText directly. Capture just its drawRect glyphs, not
// its background, and use their ink bounds so short words get both endpoint colors.
static void RKDrawNativeGlyphView(UIView *view, CGRect dirtyRect, void (^original)(void)) {
    if (RKCandidateDrawingDepth || !RKCandidateFlag(@"CandidateGradient") ||
        !RKCandidateFlag(@"CandidateNative")) { original(); return; }
    CGRect bounds = view.bounds;
    if (!UIGraphicsGetCurrentContext() || CGRectIsEmpty(bounds) ||
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
    // Reached only once an image actually exists, so the invalidation set stays limited
    // to views that own custom pixels.
    [RKCandidateViews addObject:view];
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
    if (RKHookInstallQueued) return;
    RKHookInstallQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        RKHookInstallQueued = NO;
        RKInstallNativeCandidateHook();
    });
}

// Native candidate labels drawn with a plain UILabel live in the registered candidate
// containers; the container test early-outs while no candidate bar exists.
%hook UILabel
- (void)drawTextInRect:(CGRect)rect {
    RKDrawCandidate(self, rect, NO, ^{
        %orig;
    });
}
%end

// WeType overrides UILabel drawing; its label class is the region proof itself.
%hook WBTextItemLabel
- (void)drawTextInRect:(CGRect)rect {
    RKDrawCandidate((UILabel *)self, rect, YES, ^{
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
        }];
    }
}
