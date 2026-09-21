#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <os/lock.h>
#import "RKPreferences.h"
#import "RKKeyboardGeometry.h"
#import "RKBlackBitmap.h"
#import "RKBlackKeyboard.h"
#import "RKBlackProbe.h"
#import "RKKeyboardColors.h"

static NSDictionary *RKBlackPrefs;
static NSHashTable<UIView *> *RKBlackViews;
static char RKBlackSurfaceKey;
static char RKBlackKeycapsKey;
static char RKBlackGeometryKey;
static BOOL RKBlackConfigHooksInstalled;
static BOOL RKBlackActionHookInstalled;
static char RKBlackActionImageKey;
static BOOL RKBlackLayerHookInstalled;
static char RKBlackUpdatingImageKey;
static NSHashTable<CALayer *> *RKBlackImageLayers;
static NSUInteger RKBlackGrayImages, RKBlackBlueImages, RKBlackUnchangedImages;
static os_unfair_lock RKBlackHookLock = OS_UNFAIR_LOCK_INIT;
static BOOL RKBlackHookQueued;
static char RKBlackImageRoleKey, RKBlackLayerColorKey, RKBlackShapeColorKey;
static BOOL RKBlackKeyplaneHookInstalled, RKBlackSplitHookInstalled;
static NSUInteger RKBlackAtlasImages, RKBlackBackgroundImages, RKBlackWeTypeKeys;
static NSHashTable<UIView *> *RKBlackWeTypeHosts;
static NSHashTable<UIImageView *> *RKBlackManagedImages;
static NSHashTable<UILabel *> *RKBlackManagedLabels;
static char RKBlackUIImageRoleKey, RKBlackUIImageCacheKey, RKBlackUIImageUpdatingKey;
static char RKBlackLabelManagedKey, RKBlackLabelColorKey, RKBlackLabelTextKey, RKBlackLabelUpdatingKey;
static char RKBlackManagedLayerKey, RKBlackUpdatingColorKey;
static NSUInteger RKBlackBackgroundColors;
static char RKBlackScopeKey;
static char RKBlackDrawRoleKey, RKBlackHiddenKey, RKBlackHidingKey;
static char RKBlackFaceStyleKey, RKBlackGradientColorsKey, RKBlackGradientUpdatingKey;
static NSHashTable<CALayer *> *RKBlackBackgroundLayers;
static NSUInteger RKBlackDirectDraws, RKBlackDirectConversions, RKBlackSuppressedBackgrounds;
static NSUInteger RKBlackShapeFaces;
static NSHashTable<UIView *> *RKBlackObservedKeys;
static char RKBlackKeyRootKey, RKBlackRefreshKey, RKBlackHighlightedImageCacheKey;
static char RKBlackGeometryQueuedKey;
static NSUInteger RKBlackGeometryRequests;
static NSUInteger RKBlackStateRefreshes;
static char RKBlackFaceBitmapKey, RKBlackButtonImagesKey, RKBlackButtonUpdatingKey;
static NSHashTable<UIButton *> *RKBlackButtons;
static char RKNativeKeyOwnerKey, RKNativeCompositingKey, RKNativeFilterUpdatingKey, RKNativeBackdropOwnerKey;
static NSHashTable<CALayer *> *RKNativeFilteredLayers;
static NSUInteger RKNativeStateRefreshes, RKNativeStretchImages, RKNativeFilterChanges;
static __thread NSUInteger RKNativeStateTransitionDepth;
static NSMutableSet<UIView *> *RKNativePendingKeys;
static NSUInteger RKNativeStateBatches, RKNativeStateLookups;
static BOOL RKNativeStateHooksInstalled;
static BOOL RKNativeTraitsHookInstalled;
static BOOL RKNativeGradientHookInstalled;
static char RKNativeGradientColorKey;
static NSUInteger RKNativeTraitsRecolored;
static char RKNativeBackgroundLayerKey, RKNativeMultiplyKey, RKNativeMultiplyUpdatingKey;
static __thread void *RKNativeBackgroundContext;
static BOOL RKNativeMultiplyHookInstalled;
static NSUInteger RKNativeMultiplyChanges;
static NSHashTable<CALayer *> *RKNativeBackgrounds;
static BOOL RKQQAppearanceHookInstalled;
static NSUInteger RKQQAppearanceOverrides;

static UIColor *RKKeycapColor(void) {
    return RKKeyboardColor(RKBlackPrefs, @"KeycapColor");
}

static CGImageRef RKCreateKeycapImage(CGImageRef image, BOOL backgroundOnly) {
    NSArray *rgb = RKKeyboardRGB(RKBlackPrefs[@"KeycapColor"]);
    return RKCreateColoredKeyboardAtlas(image, backgroundOnly, [rgb[0] doubleValue],
        [rgb[1] doubleValue], [rgb[2] doubleValue]);
}
static CGImageRef RKCreateFullKeyFace(CGImageRef image) {
    NSArray *rgb = RKKeyboardRGB(RKBlackPrefs[@"KeycapColor"]);
    return RKCreateColoredKeyboardFace(image, [rgb[0] doubleValue], [rgb[1] doubleValue], [rgb[2] doubleValue]);
}

@interface RKBlackScope : NSObject
@property(nonatomic,weak) CALayer *root;
@end
@implementation RKBlackScope
@end

static void RKMarkBlackScope(CALayer *layer, CALayer *root) {
    RKBlackScope *scope = objc_getAssociatedObject(layer, &RKBlackScopeKey);
    if (scope.root == root) return;
    scope = [RKBlackScope new];
    scope.root = root;
    objc_setAssociatedObject(layer, &RKBlackScopeKey, scope, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL RKBlackInScope(CALayer *layer) {
    RKBlackScope *scope = objc_getAssociatedObject(layer, &RKBlackScopeKey);
    if (!scope) return YES;
    CALayer *root = scope.root;
    if (!root) return NO;
    for (CALayer *parent = layer; parent; parent = parent.superlayer)
        if (parent == root) return YES;
    return NO;
}

static void RKUpdateBlackActionImage(CALayer *layer, BOOL enabled);
static void RKUpdateBlackLayerColor(CALayer *layer, BOOL enabled, BOOL shape);
static void RKUpdateBlackUIImage(UIImageView *view, BOOL enabled);
static void RKUpdateBlackLabel(UILabel *label, BOOL enabled);
static void RKPublishBlackDiagnostic(void);
static void RKUpdateBlackBackgroundVisibility(CALayer *layer, BOOL enabled);
static void RKUpdateBlackGradient(CAGradientLayer *layer, BOOL enabled);
static void RKUpdateBlackSurface(UIView *view, BOOL coverBackdrop);
static void RKUpdateBlackKeycaps(UIView *view);
static void RKUpdateBlackActionKey(UIView *view);
static void RKUpdateBlackButton(UIButton *button, BOOL enabled);
static BOOL RKBlackEnabled(void);
static BOOL RKNativeKeyView(UIView *view);
static CGImageRef RKNativeStretchFace(CALayer *layer, CGImageRef image);
static void RKRefreshNativeKey(UIView *view);
static void RKUpdateNativeCompositing(CALayer *layer);
static void RKUpdateNativeBackdrop(UIView *view);
static void RKUpdateNativeMultiply(CALayer *layer);

static void RKQueueKeyboardFaces(UIView *view) {
    RKBlackGeometryRequests++;
    Class layout = NSClassFromString(@"UIKeyboardLayoutStar");
    for (UIView *host = view; host; host = host.superview) {
        if (![host isKindOfClass:layout]) continue;
        if (objc_getAssociatedObject(host, &RKBlackGeometryQueuedKey)) return;
        objc_setAssociatedObject(host, &RKBlackGeometryQueuedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIView *weakHost = host;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *live = weakHost;
            if (!live) return;
            objc_setAssociatedObject(live, &RKBlackGeometryQueuedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RKUpdateBlackKeycaps(live);
        });
        return;
    }
}

static CAAnimation *RKKeyColorAnimation(CALayer *layer, CAAnimation *animation) {
    if (!RKBlackEnabled() || !RKBlackInScope(layer)) return animation;
    BOOL managed = [objc_getAssociatedObject(layer, &RKBlackManagedLayerKey) boolValue];
    BOOL face = [objc_getAssociatedObject(layer, &RKBlackFaceStyleKey) boolValue];
    if ([animation isKindOfClass:CAPropertyAnimation.class]) {
        NSString *path = ((CAPropertyAnimation *)animation).keyPath;
        if ((managed && [@[@"backgroundColor", @"contents"] containsObject:path]) ||
            (face && [@[@"fillColor", @"colors"] containsObject:path])) return nil;
    } else if ([animation isKindOfClass:CAAnimationGroup.class]) {
        CAAnimationGroup *group = (CAAnimationGroup *)animation;
        NSMutableArray *kept = [NSMutableArray array];
        BOOL changed = NO;
        for (CAAnimation *child in group.animations) {
            CAAnimation *filtered = RKKeyColorAnimation(layer, child);
            if (filtered) [kept addObject:filtered];
            changed |= filtered != child;
        }
        if (!changed) return animation;
        if (!kept.count) return nil;
        CAAnimationGroup *copy = [group copy];
        copy.animations = kept;
        return copy;
    }
    return animation;
}

static BOOL __attribute__((unused)) RKBlackEnabledForBundle(NSString *bundle) {
    NSString *keyboard = [bundle.lowercaseString containsString:@"wetype"] ? @"WeChatKeyboard" : @"NativeKeyboard";
    for (NSString *key in @[@"Enabled", keyboard, @"PureBlackKeyboard"]) {
        if (RKBlackPrefs[key] && ![RKBlackPrefs[key] boolValue]) return NO;
    }
    return YES;
}

static BOOL RKBlackEnabled(void) {
    static NSString *keyboard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keyboard = [NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"] ?
            @"WeChatKeyboard" : @"NativeKeyboard";
    });
    return (!RKBlackPrefs[@"Enabled"] || [RKBlackPrefs[@"Enabled"] boolValue]) &&
        (!RKBlackPrefs[keyboard] || [RKBlackPrefs[keyboard] boolValue]) &&
        (!RKBlackPrefs[@"PureBlackKeyboard"] || [RKBlackPrefs[@"PureBlackKeyboard"] boolValue]);
}

static void RKBlackReload(void) {
    NSDictionary *preferences = RKReadEffectivePreferences();
    if ([RKBlackPrefs isEqual:preferences]) return;
    RKBlackPrefs = preferences;
    for (UIView *view in RKBlackViews.allObjects) {
        [view setNeedsLayout];
        [view setNeedsDisplay];
        CALayer *surface = objc_getAssociatedObject(view, &RKBlackSurfaceKey);
        if (surface) RKUpdateBlackSurface(view, surface.zPosition > 0);
        if (objc_getAssociatedObject(view, &RKNativeBackdropOwnerKey)) RKUpdateNativeBackdrop(view);
        if (objc_getAssociatedObject(view, &RKBlackKeycapsKey)) RKUpdateBlackKeycaps(view);
    }
    for (CALayer *layer in RKBlackBackgroundLayers.allObjects)
        RKUpdateBlackBackgroundVisibility(layer, RKBlackEnabled());
    for (CALayer *layer in RKBlackImageLayers.allObjects) {
        RKUpdateBlackActionImage(layer, RKBlackEnabled());
        RKUpdateBlackLayerColor(layer, RKBlackEnabled(), NO);
        if ([layer isKindOfClass:CAShapeLayer.class])
            RKUpdateBlackLayerColor(layer, RKBlackEnabled() &&
                ([objc_getAssociatedObject(layer, &RKBlackImageRoleKey) integerValue] == 1 ||
                 [objc_getAssociatedObject(layer, &RKBlackFaceStyleKey) boolValue]), YES);
        if ([layer isKindOfClass:CAGradientLayer.class])
            RKUpdateBlackGradient((CAGradientLayer *)layer, RKBlackEnabled());
    }
    for (UIImageView *view in RKBlackManagedImages.allObjects) RKUpdateBlackUIImage(view, RKBlackEnabled());
    for (UILabel *label in RKBlackManagedLabels.allObjects) RKUpdateBlackLabel(label, RKBlackEnabled());
    for (UIButton *button in RKBlackButtons.allObjects) RKUpdateBlackButton(button, RKBlackEnabled());
    for (UIView *host in RKBlackWeTypeHosts.allObjects) RKApplyBlackKeyboardHost(host);
    for (CALayer *layer in RKNativeFilteredLayers.allObjects) RKUpdateNativeCompositing(layer);
    for (CALayer *layer in RKNativeBackgrounds.allObjects) RKUpdateNativeMultiply(layer);
}

static BOOL RKQQKeyboardBundle(NSString *bundle) {
    return [bundle isEqualToString:@"com.tencent.mqq"];
}

static NSInteger RKQQKeyboardAppearance(NSInteger appearance) {
    static BOOL qq;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ qq = RKQQKeyboardBundle(NSBundle.mainBundle.bundleIdentifier); });
    if (!qq || !RKBlackEnabled()) return appearance;
    if (appearance != UIKeyboardAppearanceDark) RKQQAppearanceOverrides++;
    return UIKeyboardAppearanceDark;
}

static void RKUpdateBlackSurface(UIView *view, BOOL coverBackdrop) {
    [RKBlackViews addObject:view];
    CALayer *surface = objc_getAssociatedObject(view, &RKBlackSurfaceKey);
    if (!RKBlackEnabled()) {
        surface.hidden = YES;
        return;
    }
    if (!surface) {
        surface = [CALayer layer];
        surface.name = @"RKPureBlackSurface";
        objc_setAssociatedObject(view, &RKBlackSurfaceKey, surface, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view.layer addSublayer:surface];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    surface.hidden = NO;
    surface.frame = view.bounds;
    surface.backgroundColor = RKKeyboardColor(RKBlackPrefs, @"KeyboardBackgroundColor").CGColor;
    surface.opacity = 1;
    surface.cornerRadius = view.layer.cornerRadius;
    // Only backdrop-only views get a cover. Layouts and docks keep all glyphs above it.
    surface.zPosition = coverBackdrop ? 1000 : -1000;
    [CATransaction commit];
}

static void RKUpdateBlackKeycaps(UIView *view) {
    CAShapeLayer *keycaps = objc_getAssociatedObject(view, &RKBlackKeycapsKey);
    if (!RKBlackEnabled()) {
        keycaps.hidden = YES;
        return;
    }
    NSArray<NSValue *> *frames = RKKeyboardKeyFrames(view);
    if (!keycaps) {
        keycaps = [CAShapeLayer layer];
        keycaps.name = @"RKPureBlackKeycaps";
        // Opaque faces stay below system legends, above the black base.
        keycaps.zPosition = -999;
        [view.layer addSublayer:keycaps];
        objc_setAssociatedObject(view, &RKBlackKeycapsKey, keycaps, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    keycaps.hidden = frames.count == 0;
    keycaps.fillColor = RKKeycapColor().CGColor;
    keycaps.frame = view.bounds;
    if (![frames isEqual:objc_getAssociatedObject(view, &RKBlackGeometryKey)]) {
        UIBezierPath *faces = [UIBezierPath bezierPath];
        for (NSValue *value in frames) [faces appendPath:RKKeyboardKeyFacePath(value.CGRectValue)];
        keycaps.path = faces.CGPath;
        objc_setAssociatedObject(view, &RKBlackGeometryKey, frames, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    [CATransaction commit];
}

static void RKBlackSetImage(CALayer *layer, id contents) {
    objc_setAssociatedObject(layer, &RKBlackUpdatingImageKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.contents = contents;
    [CATransaction commit];
    objc_setAssociatedObject(layer, &RKBlackUpdatingImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL RKBlackFullFaceImage(CALayer *layer) {
    RKBlackScope *scope = objc_getAssociatedObject(layer, &RKBlackScopeKey);
    CALayer *root = scope.root;
    if (!root || !RKBlackInScope(layer) || !objc_getAssociatedObject(root, &RKBlackKeyRootKey)) return NO;
    CGRect frame = [layer convertRect:layer.bounds toLayer:root];
    return !CGRectIsEmpty(root.bounds) && CGRectContainsRect(CGRectInset(root.bounds, -1, -1), frame) &&
        frame.size.width >= root.bounds.size.width * .7 && frame.size.height >= root.bounds.size.height * .7;
}

// Only keyboard key-image layers reach this routine, never app images or text.
static void RKUpdateBlackActionImage(CALayer *layer, BOOL enabled) {
    enabled &= RKBlackInScope(layer);
    [RKBlackImageLayers addObject:layer];
    NSDictionary *cached = objc_getAssociatedObject(layer, &RKBlackActionImageKey);
    id current = layer.contents;
    if (!enabled) {
        if (cached && current == cached[@"black"]) RKBlackSetImage(layer, cached[@"source"]);
        objc_setAssociatedObject(layer, &RKBlackActionImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    UIColor *theme = RKKeycapColor();
    BOOL sameTheme = [theme isEqual:cached[@"theme"]];
    if (!current || (current == cached[@"black"] && sameTheme)) return;
    if (current == cached[@"source"] && sameTheme) { RKBlackSetImage(layer, cached[@"black"]); return; }
    if (current == cached[@"black"]) current = cached[@"source"];
    if (CFGetTypeID((__bridge CFTypeRef)current) != CGImageGetTypeID()) return;
    CGImageRef image = (__bridge CGImageRef)current;
    NSInteger role = [objc_getAssociatedObject(layer, &RKBlackImageRoleKey) integerValue];
    id result = CFBridgingRelease(RKCreateKeycapImage(image, role == 1));
    if (!result && role != 1 && (RKBlackFullFaceImage(layer) ||
        [objc_getAssociatedObject(layer, &RKBlackFaceBitmapKey) boolValue]))
        result = CFBridgingRelease(RKCreateFullKeyFace(image));
    if (!result) result = CFBridgingRelease(RKNativeStretchFace(layer, image));
    result = result ?: current;
    objc_setAssociatedObject(layer, &RKBlackActionImageKey, @{@"source":current, @"black":result, @"theme":theme},
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (result != current) {
        if (role == 1) RKBlackBackgroundImages++;
        else if (role == 2) RKBlackAtlasImages++;
        else RKBlackGrayImages++;
    } else RKBlackUnchangedImages++;
    if (layer.contents != result) RKBlackSetImage(layer, result);
}

static void RKUpdateBlackLayerColor(CALayer *layer, BOOL enabled, BOOL shape) {
    enabled &= RKBlackInScope(layer);
    const void *key = shape ? &RKBlackShapeColorKey : &RKBlackLayerColorKey;
    NSDictionary *cached = objc_getAssociatedObject(layer, key);
    CGColorRef current = shape ? ((CAShapeLayer *)layer).fillColor : layer.backgroundColor;
    CGColorRef replacement = NULL;
    if (!enabled) {
        if (cached && current == (__bridge CGColorRef)cached[@"black"])
            replacement = (__bridge CGColorRef)cached[@"source"];
        else {
            objc_setAssociatedObject(layer, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
    } else {
        UIColor *theme = RKKeycapColor();
        if (!current || CGColorGetAlpha(current) == 0) return;
        if (current == (__bridge CGColorRef)cached[@"black"]) {
            if ([theme isEqual:cached[@"theme"]]) return;
            current = (__bridge CGColorRef)cached[@"source"];
        }
        UIColor *black = [theme colorWithAlphaComponent:CGColorGetAlpha(current)];
        replacement = black.CGColor;
        objc_setAssociatedObject(layer, key, @{@"source":(__bridge id)current,
            @"black":(__bridge id)replacement, @"theme":theme},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RKBlackBackgroundColors++;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    objc_setAssociatedObject(layer, &RKBlackUpdatingColorKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (shape) ((CAShapeLayer *)layer).fillColor = replacement; else layer.backgroundColor = replacement;
    objc_setAssociatedObject(layer, &RKBlackUpdatingColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction commit];
    if (!enabled) objc_setAssociatedObject(layer, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL RKBlackLayerCoversFace(CALayer *layer, CALayer *root) {
    CGRect frame = [layer convertRect:layer.bounds toLayer:root];
    CGRect bounds = root.bounds;
    if (CGRectIsEmpty(bounds) || !CGRectContainsRect(CGRectInset(bounds, -1, -1), frame)) return NO;
    if (frame.size.width < bounds.size.width * .72 || frame.size.height < bounds.size.height * .72) return NO;
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        if (!shape.fillColor || CGColorGetAlpha(shape.fillColor) == 0 || !shape.path) return NO;
        for (NSUInteger x = 0; x < 3; x++)
            for (NSUInteger y = 0; y < 3; y++) {
                CGPoint sample = CGPointMake(layer.bounds.origin.x + layer.bounds.size.width * (.2 + .3 * x),
                    layer.bounds.origin.y + layer.bounds.size.height * (.2 + .3 * y));
                if (!CGPathContainsPoint(shape.path, NULL, sample, [shape.fillRule isEqual:kCAFillRuleEvenOdd])) return NO;
            }
        return YES;
    }
    return [layer isKindOfClass:CAGradientLayer.class] && !layer.mask;
}

static void RKUpdateBlackGradient(CAGradientLayer *layer, BOOL enabled) {
    if (objc_getAssociatedObject(layer, &RKBlackGradientUpdatingKey)) return;
    enabled &= RKBlackInScope(layer) && [objc_getAssociatedObject(layer, &RKBlackFaceStyleKey) boolValue];
    NSDictionary *cached = objc_getAssociatedObject(layer, &RKBlackGradientColorsKey);
    NSArray *current = layer.colors, *result = nil;
    if (!enabled) {
        if ([current isEqual:cached[@"black"]]) result = cached[@"source"];
        objc_setAssociatedObject(layer, &RKBlackGradientColorsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        UIColor *theme = RKKeycapColor();
        if (!current.count) return;
        if ([current isEqual:cached[@"black"]]) {
            if ([theme isEqual:cached[@"theme"]]) return;
            current = cached[@"source"];
        }
        NSMutableArray *black = [NSMutableArray array];
        for (id color in current) {
            if (CFGetTypeID((__bridge CFTypeRef)color) != CGColorGetTypeID()) return;
            [black addObject:(id)[theme colorWithAlphaComponent:
                CGColorGetAlpha((__bridge CGColorRef)color)].CGColor];
        }
        result = black;
        objc_setAssociatedObject(layer, &RKBlackGradientColorsKey, @{@"source":current, @"black":result, @"theme":theme},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!result) return;
    objc_setAssociatedObject(layer, &RKBlackGradientUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    layer.colors = result;
    [CATransaction commit];
    objc_setAssociatedObject(layer, &RKBlackGradientUpdatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RKUpdateBlackKeyLayers(CALayer *layer, BOOL enabled, NSUInteger depth, CALayer *root) {
    if (depth > 6) return;
    RKMarkBlackScope(layer, root);
    objc_setAssociatedObject(layer, &RKBlackManagedLayerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RKUpdateBlackActionImage(layer, enabled);
    RKUpdateBlackLayerColor(layer, enabled, NO);
    BOOL face = RKBlackLayerCoversFace(layer, root);
    if (face && ![objc_getAssociatedObject(layer, &RKBlackFaceStyleKey) boolValue]) RKBlackShapeFaces++;
    objc_setAssociatedObject(layer, &RKBlackFaceStyleKey, @(face), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([layer isKindOfClass:CAShapeLayer.class]) RKUpdateBlackLayerColor(layer, enabled && face, YES);
    if ([layer isKindOfClass:CAGradientLayer.class]) RKUpdateBlackGradient((CAGradientLayer *)layer, enabled);
    if (enabled) {
        for (NSString *key in layer.animationKeys) {
            CAAnimation *original = [layer animationForKey:key];
            CAAnimation *filtered = RKKeyColorAnimation(layer, original);
            if (filtered == original) continue;
            [layer removeAnimationForKey:key];
            if (filtered) [layer addAnimation:filtered forKey:key];
        }
    }
    for (CALayer *child in layer.sublayers) RKUpdateBlackKeyLayers(child, enabled, depth + 1, root);
}

static void RKUpdateBlackActionKey(UIView *view) {
    [RKBlackViews addObject:view];
    [RKBlackObservedKeys addObject:view];
    objc_setAssociatedObject(view.layer, &RKBlackKeyRootKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!objc_getAssociatedObject(view.layer, &RKBlackDrawRoleKey)) {
        objc_setAssociatedObject(view.layer, &RKBlackDrawRoleKey, @2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view setNeedsDisplay];
    }
    RKUpdateBlackKeyLayers(view.layer, RKBlackEnabled(), 0, view.layer);
    // Native key state changes do not alter key geometry. Recalculating every
    // key frame here makes continuous typing pay for a whole-keyboard walk.
    // WeType still queues its geometry refresh through this path.
    if (!RKNativeKeyView(view)) RKQueueKeyboardFaces(view);
}

static void RKUpdateBlackBackgroundVisibility(CALayer *layer, BOOL enabled) {
    enabled &= RKBlackInScope(layer);
    NSNumber *original = objc_getAssociatedObject(layer, &RKBlackHiddenKey);
    if (enabled && !original) {
        original = @(layer.hidden);
        objc_setAssociatedObject(layer, &RKBlackHiddenKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RKBlackSuppressedBackgrounds++;
    }
    if (!original) return;
    objc_setAssociatedObject(layer, &RKBlackHidingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.hidden = enabled ? YES : original.boolValue;
    [CATransaction commit];
    objc_setAssociatedObject(layer, &RKBlackHidingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!enabled) objc_setAssociatedObject(layer, &RKBlackHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RKDrawBlackKeyLayer(UIView *view, CALayer *layer, CGContextRef target,
                                void (^original)(CGContextRef)) {
    NSNumber *role = objc_getAssociatedObject(layer, &RKBlackDrawRoleKey);
    if (!role || !RKBlackEnabled() || !RKBlackInScope(layer) || !NSThread.isMainThread) {
        original(target);
        return;
    }
    CGRect bounds = layer.bounds;
    CGFloat scale = MAX(1, layer.contentsScale);
    CGFloat pixels = bounds.size.width * scale * bounds.size.height * scale;
    if (!isfinite(pixels) || pixels <= 0 || pixels > 2097152 ||
        bounds.size.width * scale > 4096 || bounds.size.height * scale > 2048) {
        original(target);
        return;
    }
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) { UIGraphicsEndImageContext(); original(target); return; }
    CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);
    original(context);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!image.CGImage) { original(target); return; }
    RKBlackDirectDraws++;
    CGImageRef converted = RKCreateKeycapImage(image.CGImage, role.integerValue == 1);
    if (!converted && role.integerValue != 1 && RKBlackFullFaceImage(layer))
        converted = RKCreateFullKeyFace(image.CGImage);
    UIImage *result = converted ? [UIImage imageWithCGImage:converted scale:scale orientation:UIImageOrientationUp] : image;
    if (converted) {
        RKBlackDirectConversions++;
        CGImageRelease(converted);
    }
    UIGraphicsPushContext(target);
    [result drawInRect:bounds];
    UIGraphicsPopContext();
}

static void RKUpdateBlackUIImage(UIImageView *view, BOOL enabled) {
    enabled &= RKBlackInScope(view.layer);
    if (objc_getAssociatedObject(view, &RKBlackUIImageUpdatingKey)) return;
    objc_setAssociatedObject(view, &RKBlackUIImageUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (NSUInteger slot = 0; slot < 2; slot++) {
    const void *cacheKey = slot ? &RKBlackHighlightedImageCacheKey : &RKBlackUIImageCacheKey;
    NSDictionary *cached = objc_getAssociatedObject(view, cacheKey);
    UIImage *current = slot ? view.highlightedImage : view.image, *result = nil;
    if (!enabled) {
        if (cached && current == cached[@"black"]) result = cached[@"source"];
        objc_setAssociatedObject(view, cacheKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        UIColor *theme = RKKeycapColor();
        BOOL sameTheme = [theme isEqual:cached[@"theme"]];
        if (!current || (current == cached[@"black"] && sameTheme)) continue;
        if (current == cached[@"black"]) current = cached[@"source"];
        if (current == cached[@"source"] && sameTheme) result = cached[@"black"];
        else if (current.CGImage) {
            CALayer *temporary = [CALayer layer];
            temporary.contents = (__bridge id)current.CGImage;
            NSNumber *role = objc_getAssociatedObject(view, &RKBlackUIImageRoleKey);
            objc_setAssociatedObject(temporary, &RKBlackImageRoleKey, role, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(temporary, &RKBlackFaceBitmapKey, @(RKBlackFullFaceImage(view.layer)),
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            RKUpdateBlackActionImage(temporary, YES);
            if (temporary.contents != (__bridge id)current.CGImage) {
                result = [UIImage imageWithCGImage:(__bridge CGImageRef)temporary.contents
                    scale:current.scale orientation:current.imageOrientation];
                result = [[result resizableImageWithCapInsets:current.capInsets resizingMode:current.resizingMode]
                    imageWithAlignmentRectInsets:current.alignmentRectInsets];
                result = [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            } else result = current;
            objc_setAssociatedObject(view, cacheKey, @{@"source":current, @"black":result, @"theme":theme},
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (!result) continue;
    if (slot) {
        if (view.highlightedImage != result) view.highlightedImage = result;
    } else if (view.image != result) view.image = result;
    }
    objc_setAssociatedObject(view, &RKBlackUIImageUpdatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RKUpdateBlackButton(UIButton *button, BOOL enabled) {
    if (objc_getAssociatedObject(button, &RKBlackButtonUpdatingKey)) return;
    enabled &= RKBlackInScope(button.layer);
    objc_setAssociatedObject(button, &RKBlackButtonUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableDictionary *cache = objc_getAssociatedObject(button, &RKBlackButtonImagesKey);
    if (!cache) {
        cache = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(button, &RKBlackButtonImagesKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (NSUInteger state = 0; state < 8; state++) {
        NSNumber *key = @(state);
        NSDictionary *entry = cache[key];
        UIImage *current = [button backgroundImageForState:state], *result = nil;
        BOOL inherited = NO;
        if (enabled && state && !entry && current) {
            // UIKit can return the processed normal/highlighted image as a
            // fallback. Do not materialize that fallback as an explicit state.
            for (NSNumber *other in cache)
                if (current == cache[other][@"result"]) { inherited = YES; break; }
        }
        if (inherited) continue;
        if (!enabled) {
            if (entry && current == entry[@"result"]) result = entry[@"source"];
            [cache removeObjectForKey:key];
        } else if (current) {
            UIColor *theme = RKKeycapColor();
            if (current == entry[@"result"] && [theme isEqual:entry[@"theme"]]) continue;
            if (current == entry[@"result"]) current = entry[@"source"];
            CGImageRef image = current.CGImage ? RKCreateKeycapImage(current.CGImage, NO) : NULL;
            if (!image && current.CGImage) image = RKCreateFullKeyFace(current.CGImage);
            result = image ? [UIImage imageWithCGImage:image scale:current.scale orientation:current.imageOrientation] : current;
            if (image) {
                CGImageRelease(image);
                result = [[[result resizableImageWithCapInsets:current.capInsets resizingMode:current.resizingMode]
                    imageWithAlignmentRectInsets:current.alignmentRectInsets] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            }
            cache[key] = @{@"source":current, @"result":result, @"theme":theme};
        } else [cache removeObjectForKey:key];
        if (result && result != [button backgroundImageForState:state]) [button setBackgroundImage:result forState:state];
    }
    objc_setAssociatedObject(button, &RKBlackButtonUpdatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RKUpdateBlackLabel(UILabel *label, BOOL enabled) {
    enabled &= RKBlackInScope(label.layer);
    if (objc_getAssociatedObject(label, &RKBlackLabelUpdatingKey)) return;
    objc_setAssociatedObject(label, &RKBlackLabelUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSDictionary *texts = objc_getAssociatedObject(label, &RKBlackLabelTextKey);
    NSAttributedString *current = label.attributedText;
    BOOL isWhiteText = current && [current isEqualToAttributedString:texts[@"white"]];
    NSDictionary *colors = objc_getAssociatedObject(label, &RKBlackLabelColorKey);
    if (enabled) {
        if (![label.textColor isEqual:colors[@"black"]]) {
            objc_setAssociatedObject(label, &RKBlackLabelColorKey,
                @{@"source":label.textColor ?: UIColor.blackColor, @"black":UIColor.whiteColor},
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            label.textColor = UIColor.whiteColor;
        }
    } else {
        if ([label.textColor isEqual:colors[@"black"]]) label.textColor = colors[@"source"];
        objc_setAssociatedObject(label, &RKBlackLabelColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (enabled && current && !isWhiteText) {
        NSMutableAttributedString *white = [current mutableCopy];
        [white addAttribute:NSForegroundColorAttributeName value:UIColor.whiteColor
            range:NSMakeRange(0, white.length)];
        objc_setAssociatedObject(label, &RKBlackLabelTextKey, @{@"source":current, @"white":white},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        label.attributedText = white;
    } else if (!enabled) {
        if (isWhiteText) label.attributedText = texts[@"source"];
        objc_setAssociatedObject(label, &RKBlackLabelTextKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(label, &RKBlackLabelUpdatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RKUpdateBlackImageViews(UIView *view, NSInteger role, BOOL keyLabels, NSUInteger depth, CALayer *root) {
    if (depth > 8) return;
    if (RKKeyboardExcludedView(view)) return;
    RKMarkBlackScope(view.layer, root);
    if ([view isKindOfClass:UIButton.class]) {
        [RKBlackButtons addObject:(UIButton *)view];
        RKUpdateBlackButton((UIButton *)view, RKBlackEnabled());
    }
    if (![view isKindOfClass:UILabel.class] && !objc_getAssociatedObject(view.layer, &RKBlackDrawRoleKey)) {
        objc_setAssociatedObject(view.layer, &RKBlackDrawRoleKey, @(role == 1 ? 1 : 2),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [RKBlackViews addObject:view];
        [view setNeedsDisplay];
    }
    if ([view isKindOfClass:UIImageView.class]) {
        NSNumber *previous = objc_getAssociatedObject(view, &RKBlackUIImageRoleKey);
        if (previous && previous.integerValue != role) RKUpdateBlackUIImage((UIImageView *)view, NO);
        objc_setAssociatedObject(view, &RKBlackUIImageRoleKey, @(role), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [RKBlackManagedImages addObject:(UIImageView *)view];
        RKUpdateBlackUIImage((UIImageView *)view, RKBlackEnabled());
    }
    if (keyLabels && [view isKindOfClass:UILabel.class]) {
        objc_setAssociatedObject(view, &RKBlackLabelManagedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [RKBlackManagedLabels addObject:(UILabel *)view];
        RKUpdateBlackLabel((UILabel *)view, RKBlackEnabled());
    }
    for (UIView *child in view.subviews) RKUpdateBlackImageViews(child, role, keyLabels, depth + 1, root);
}

static CALayer *RKBlackKeyRoot(CALayer *layer) {
    for (NSUInteger depth = 0; layer && depth < 16; layer = layer.superlayer, depth++) {
        if ([layer.name hasPrefix:@"RK"]) return nil;
        if ([objc_getAssociatedObject(layer, &RKBlackKeyRootKey) boolValue]) return layer;
        id delegate = layer.delegate;
        if ([delegate isKindOfClass:UIView.class] && RKKeyboardExcludedView(delegate)) return nil;
    }
    return nil;
}

static void RKRefreshBlackKeyState(UIView *view) {
    if (!NSThread.isMainThread || objc_getAssociatedObject(view, &RKBlackRefreshKey)) return;
    objc_setAssociatedObject(view, &RKBlackRefreshKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RKUpdateBlackActionKey(view);
    RKUpdateBlackImageViews(view, 0, YES, 0, view.layer);
    objc_setAssociatedObject(view, &RKBlackRefreshKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RKBlackStateRefreshes++;
}

static void RKPrepareAttachedKeyLayer(CALayer *layer) {
    if (!NSThread.isMainThread) return;
    CALayer *root = RKBlackKeyRoot(layer);
    if (!root) return;
    RKUpdateBlackKeyLayers(layer, RKBlackEnabled(), 0, root);
    id delegate = layer.delegate;
    if ([delegate isKindOfClass:UIView.class])
        RKUpdateBlackImageViews(delegate, 0, YES, 0, root);
}

static void RKRefreshBlackFaceGeometry(CALayer *layer) {
    if (!NSThread.isMainThread || objc_getAssociatedObject(layer, &RKBlackUpdatingColorKey) ||
        objc_getAssociatedObject(layer, &RKBlackGradientUpdatingKey)) return;
    if (!objc_getAssociatedObject(layer, &RKBlackManagedLayerKey) || !RKBlackInScope(layer)) return;
    RKBlackScope *scope = objc_getAssociatedObject(layer, &RKBlackScopeKey);
    CALayer *root = scope.root;
    if (!root || !objc_getAssociatedObject(root, &RKBlackKeyRootKey)) return;
    BOOL face = RKBlackLayerCoversFace(layer, root);
    objc_setAssociatedObject(layer, &RKBlackFaceStyleKey, @(face), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([layer isKindOfClass:CAShapeLayer.class]) RKUpdateBlackLayerColor(layer, RKBlackEnabled() && face, YES);
    if ([layer isKindOfClass:CAGradientLayer.class]) RKUpdateBlackGradient((CAGradientLayer *)layer, RKBlackEnabled());
}

static id RKBlackObjectIvar(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable([object class], name);
    if (!ivar || ivar_getTypeEncoding(ivar)[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

// Native-only ownership prevents this compatibility path from touching WeType.
static BOOL RKNativeKeyboardProcess(NSString *bundle) {
    return ![bundle.lowercaseString containsString:@"wetype"];
}

static BOOL RKNativeKeyView(UIView *view) {
    if (!RKNativeKeyboardProcess(NSBundle.mainBundle.bundleIdentifier)) return NO;
    Class key = NSClassFromString(@"UIKBKeyView");
    if (!key || ![view isKindOfClass:key]) return NO;
    for (UIView *parent = view; parent; parent = parent.superview)
        if (RKKeyboardExcludedView(parent)) return NO;
    return YES;
}

static CALayer *RKNativeLayerRoot(CALayer *layer) {
    RKBlackScope *owner = objc_getAssociatedObject(layer, &RKNativeKeyOwnerKey);
    CALayer *root = owner.root;
    if (!root || ![root.delegate isKindOfClass:UIView.class] || !RKNativeKeyView((UIView *)root.delegate)) return nil;
    for (CALayer *parent = layer; parent; parent = parent.superlayer)
        if (parent == root) return root;
    return nil;
}

static BOOL RKNativeLayerCoversKey(CALayer *layer, CALayer *root) {
    if (!root || CGRectIsEmpty(root.bounds)) return NO;
    CGRect frame = [layer convertRect:layer.bounds toLayer:root];
    return CGRectContainsRect(CGRectInset(root.bounds, -1, -1), frame) &&
        frame.size.width >= root.bounds.size.width * .7 &&
        frame.size.height >= root.bounds.size.height * .7;
}

static CGImageRef RKNativeStretchFace(CALayer *layer, CGImageRef image) {
    if (!RKNativeLayerCoversKey(layer, RKNativeLayerRoot(layer)) || CGImageIsMask(image)) return NULL;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    // Tiny stretched solid assets are not glyph atlases. Require uniform, opaque
    // non-white pixels as well as full-key destination geometry.
    if (!width || !height || width > 16 || height > 16) return NULL;
    uint8_t pixels[16 * 16 * 4] = {};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    BOOL solid = pixels[3] >= 250 && MAX(pixels[0], MAX(pixels[1], pixels[2])) < 246;
    for (size_t i = 0; i < width * height && solid; i++)
        for (NSUInteger c = 0; c < 4; c++) solid &= abs(pixels[i * 4 + c] - pixels[c]) <= 2;
    CGImageRef result = NULL;
    if (solid) {
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextSetFillColorWithColor(context, RKKeycapColor().CGColor);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        result = CGBitmapContextCreateImage(context);
        RKNativeStretchImages++;
    }
    CGContextRelease(context);
    return result;
}

static void RKUpdateNativeCompositing(CALayer *layer) {
    if (!NSThread.isMainThread || objc_getAssociatedObject(layer, &RKNativeFilterUpdatingKey)) return;
    CALayer *root = RKNativeLayerRoot(layer);
    BOOL enabled = RKBlackEnabled() && root &&
        [objc_getAssociatedObject(layer, &RKNativeBackgroundLayerKey) boolValue];
    NSDictionary *cache = objc_getAssociatedObject(layer, &RKNativeCompositingKey);
    id current = layer.compositingFilter;
    id result = current;
    if (enabled && current) {
        // Blend modes operate after the recolored pixels; an active-key blend
        // can otherwise turn the chosen face color gray again.
        objc_setAssociatedObject(layer, &RKNativeCompositingKey, @{@"source":current},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [RKNativeFilteredLayers addObject:layer];
        result = nil;
        RKNativeFilterChanges++;
    } else if (!enabled && cache) {
        if (!current) result = cache[@"source"] == NSNull.null ? nil : cache[@"source"];
        objc_setAssociatedObject(layer, &RKNativeCompositingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (result == current) return;
    objc_setAssociatedObject(layer, &RKNativeFilterUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.compositingFilter = result;
    [CATransaction commit];
    objc_setAssociatedObject(layer, &RKNativeFilterUpdatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RKMarkNativeKeyLayers(CALayer *layer, CALayer *root, NSUInteger depth) {
    if (depth > 8 || [layer.name hasPrefix:@"RK"]) return;
    id delegate = layer.delegate;
    if ([delegate isKindOfClass:UIView.class] && RKKeyboardExcludedView(delegate)) return;
    RKBlackScope *owner = objc_getAssociatedObject(layer, &RKNativeKeyOwnerKey);
    if (owner.root != root) {
        owner = [RKBlackScope new];
        owner.root = root;
        objc_setAssociatedObject(layer, &RKNativeKeyOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // A cached "unchanged" tiny image must be reconsidered after native ownership is known.
        NSDictionary *cache = objc_getAssociatedObject(layer, &RKBlackActionImageKey);
        if (cache[@"source"] == cache[@"black"])
            objc_setAssociatedObject(layer, &RKBlackActionImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    RKUpdateNativeCompositing(layer);
    if (objc_getAssociatedObject(layer, &RKNativeBackgroundLayerKey)) RKUpdateNativeMultiply(layer);
    for (CALayer *child in layer.sublayers) RKMarkNativeKeyLayers(child, root, depth + 1);
}

static void RKRefreshNativeKey(UIView *view) {
    if (!NSThread.isMainThread || !RKNativeKeyView(view)) return;
    if (RKNativeStateTransitionDepth && RKNativePendingKeys) {
        [RKNativePendingKeys addObject:view];
        return;
    }
    if (objc_getAssociatedObject(view, &RKBlackRefreshKey)) return;
    RKMarkNativeKeyLayers(view.layer, view.layer, 0);
    RKRefreshBlackKeyState(view);
    RKNativeStateRefreshes++;
}

static BOOL RKBeginNativeStateTransition(void) {
    if (!NSThread.isMainThread || !RKNativeKeyboardProcess(NSBundle.mainBundle.bundleIdentifier)) return NO;
    if (RKNativeStateTransitionDepth++ == 0) RKNativePendingKeys = [NSMutableSet set];
    return YES;
}

static void RKEndNativeStateTransition(void) {
    if (--RKNativeStateTransitionDepth) return;
    NSSet *pending = RKNativePendingKeys;
    RKNativePendingKeys = nil;
    for (UIView *view in pending) RKRefreshNativeKey(view);
    RKNativeStateBatches++;
}

static UIView *RKNativeStateView(UIView *plane, id key, int state) {
    if (!plane || !key) return nil;
    SEL selector = NSSelectorFromString(@"viewForKey:state:");
    NSMethodSignature *signature = [plane methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 4 ||
        strcmp(signature.methodReturnType, @encode(id)) ||
        strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) ||
        strcmp([signature getArgumentTypeAtIndex:3], @encode(int))) return nil;
    id view;
    NSUInteger previousDepth = RKNativeStateTransitionDepth;
    RKNativeStateTransitionDepth++;
    @try {
        RKNativeStateLookups++;
        view = ((id (*)(id, SEL, id, int))objc_msgSend)(plane, selector, key, state);
    } @finally {
        RKNativeStateTransitionDepth = previousDepth;
    }
    return [view isKindOfClass:UIView.class] ? view : nil;
}

static void RKQueueNativeStateKey(UIView *plane, id key, int state) {
    if (!NSThread.isMainThread || !RKNativeKeyboardProcess(NSBundle.mainBundle.bundleIdentifier)) return;
    UIView *view = RKNativeStateView(plane, key, state);
    if (!view) return;
    if (RKNativeStateTransitionDepth && RKNativePendingKeys)
        [RKNativePendingKeys addObject:view];
    else RKRefreshNativeKey(view);
}

static void RKRefreshSystemKey(UIView *view) {
    if (RKNativeKeyView(view)) RKRefreshNativeKey(view);
    else RKRefreshBlackKeyState(view);
}

static void RKUpdateNativeBackdrop(UIView *view) {
    RKBlackScope *owner = objc_getAssociatedObject(view, &RKNativeBackdropOwnerKey);
    CALayer *root = owner.root;
    if (!root || !RKNativeKeyView((UIView *)root.delegate)) return;
    BOOL attached = NO;
    for (CALayer *layer = view.layer; layer; layer = layer.superlayer)
        if (layer == root) { attached = YES; break; }
    if (!attached) return;
    RKUpdateBlackSurface(view, YES);
    CALayer *surface = objc_getAssociatedObject(view, &RKBlackSurfaceKey);
    if (surface && RKBlackEnabled()) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        surface.backgroundColor = RKKeycapColor().CGColor;
        [CATransaction commit];
    }
}

static void RKPrepareNativeAttachedLayer(CALayer *layer) {
    if (!NSThread.isMainThread) return;
    CALayer *root = RKBlackKeyRoot(layer);
    if (!root || !RKNativeKeyView((UIView *)root.delegate)) return;
    RKMarkNativeKeyLayers(layer, root, 0);
    RKUpdateBlackKeyLayers(layer, RKBlackEnabled(), 0, root);
}

static CAAnimation *RKNativeBlendAnimation(CALayer *layer, CAAnimation *animation) {
    if (!RKBlackEnabled() || !RKNativeLayerRoot(layer) ||
        ![objc_getAssociatedObject(layer, &RKNativeBackgroundLayerKey) boolValue]) return animation;
    if ([animation isKindOfClass:CAPropertyAnimation.class]) {
        NSString *path = ((CAPropertyAnimation *)animation).keyPath;
        if ([path isEqual:@"contentsMultiplyColor"] || [path isEqual:@"compositingFilter"] ||
            [path hasPrefix:@"compositingFilter."]) return nil;
    } else if ([animation isKindOfClass:CAAnimationGroup.class]) {
        CAAnimationGroup *group = (CAAnimationGroup *)animation;
        NSMutableArray *kept = [NSMutableArray array];
        BOOL changed = NO;
        for (CAAnimation *child in group.animations) {
            CAAnimation *filtered = RKNativeBlendAnimation(layer, child);
            if (filtered) [kept addObject:filtered];
            changed |= filtered != child;
        }
        if (!changed) return animation;
        if (!kept.count) return nil;
        CAAnimationGroup *copy = [group copy];
        copy.animations = kept;
        return copy;
    }
    return animation;
}

static void RKUpdateNativeMultiply(CALayer *layer) {
    if (!RKNativeMultiplyHookInstalled || !NSThread.isMainThread ||
        objc_getAssociatedObject(layer, &RKNativeMultiplyUpdatingKey)) return;
    BOOL enabled = RKBlackEnabled() && RKNativeLayerRoot(layer) &&
        [objc_getAssociatedObject(layer, &RKNativeBackgroundLayerKey) boolValue];
    CGColorRef current = ((CGColorRef (*)(id,SEL))objc_msgSend)(layer, NSSelectorFromString(@"contentsMultiplyColor"));
    NSDictionary *cache = objc_getAssociatedObject(layer, &RKNativeMultiplyKey);
    CGColorRef result = current;
    if (enabled) {
        id source = cache && current == (__bridge CGColorRef)cache[@"result"] ?
            cache[@"source"] : (current ? (__bridge id)current : NSNull.null);
        id image = layer.contents;
        BOOL bitmap = image && CFGetTypeID((__bridge CFTypeRef)image) == CGImageGetTypeID();
        // Accessible background-only bitmaps were already recolored. GPU/mask
        // assets instead receive their color here at the compositor.
        result = (bitmap ? UIColor.whiteColor : RKKeycapColor()).CGColor;
        if (cache && current == (__bridge CGColorRef)cache[@"result"] &&
            CGColorEqualToColor(current, result)) return;
        objc_setAssociatedObject(layer, &RKNativeMultiplyKey, @{@"source":source, @"result":(__bridge id)result},
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RKNativeMultiplyChanges++;
    } else if (cache) {
        if (current == (__bridge CGColorRef)cache[@"result"])
            result = cache[@"source"] == NSNull.null ? NULL : (__bridge CGColorRef)cache[@"source"];
        objc_setAssociatedObject(layer, &RKNativeMultiplyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (current == result) return;
    objc_setAssociatedObject(layer, &RKNativeMultiplyUpdatingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ((void (*)(id,SEL,CGColorRef))objc_msgSend)(layer, NSSelectorFromString(@"setContentsMultiplyColor:"), result);
    [CATransaction commit];
    objc_setAssociatedObject(layer, &RKNativeMultiplyUpdatingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void RKMarkNativeBackground(UIView *key, CALayer *layer) {
    if (!RKNativeKeyView(key) || !layer) return;
    RKBlackScope *owner = [RKBlackScope new]; owner.root = key.layer;
    objc_setAssociatedObject(layer, &RKNativeKeyOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (![objc_getAssociatedObject(layer, &RKNativeBackgroundLayerKey) boolValue]) {
        objc_setAssociatedObject(layer, &RKNativeBackgroundLayerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [RKNativeBackgrounds addObject:layer];
    }
    // A state-selected layer can contain a combined face + emoji/legend image.
    // Keep its existing image role and glyph-preserving converter.
    RKMarkBlackScope(layer, key.layer);
    RKUpdateBlackActionImage(layer, RKBlackEnabled());
    RKUpdateNativeMultiply(layer);
    RKUpdateNativeCompositing(layer);
    for (NSString *name in layer.animationKeys) {
        CAAnimation *original = [layer animationForKey:name];
        CAAnimation *filtered = RKNativeBlendAnimation(layer, original);
        if (original == filtered) continue;
        [layer removeAnimationForKey:name];
        if (filtered) [layer addAnimation:filtered forKey:name];
    }
}

static id RKNativeObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, @encode(id))) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL RKNativeSetObject(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 3 || strcmp(signature.methodReturnType, @encode(void)) ||
        strcmp([signature getArgumentTypeAtIndex:2], @encode(id))) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    return YES;
}

static id RKNativeSolidGradient(void) {
    if (!RKNativeGradientHookInstalled) return nil;
    Class cls = NSClassFromString(@"UIKBGradient");
    SEL selector = NSSelectorFromString(@"gradientWithColors:middleLocations:");
    NSMethodSignature *signature = [cls methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 4 || strcmp(signature.methodReturnType, @encode(id)) ||
        strcmp([signature getArgumentTypeAtIndex:2], @encode(id)) ||
        strcmp([signature getArgumentTypeAtIndex:3], @encode(id))) return nil;
    NSArray *rgb = RKKeyboardRGB(RKBlackPrefs[@"KeycapColor"]);
    NSString *color = [NSString stringWithFormat:@"RKNativeRGB-%.6f-%.6f-%.6f",
        [rgb[0] doubleValue], [rgb[1] doubleValue], [rgb[2] doubleValue]];
    id gradient = ((id (*)(id, SEL, id, id))objc_msgSend)(cls, selector, @[color, color], @[]);
    objc_setAssociatedObject(gradient, &RKNativeGradientColorKey, RKKeycapColor(), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return gradient;
}

static id RKNativeCopyKeyTraits(id original, NSMapTable *copies, NSUInteger depth) {
    if (!original || depth > 4 ||
        ![original isKindOfClass:NSClassFromString(@"UIKBRenderTraits")]) return original;
    id existing = [copies objectForKey:original];
    if (existing) return existing;
    id copy = [original copy];
    [copies setObject:copy forKey:original];
    // UIKit's copy omits geometry; retain it for image-backed symbols.
    for (NSArray *property in @[@[@"geometry", @"setGeometry:"],
                                @[@"variantGeometries", @"setVariantGeometries:"]])
        RKNativeSetObject(copy, property[1], RKNativeObject(original, property[0]));
    for (NSArray *property in @[@[@"backgroundGradient", @"setBackgroundGradient:"],
                                @[@"layeredBackgroundGradient", @"setLayeredBackgroundGradient:"]]) {
        if (!RKNativeObject(original, property[0])) continue;
        id gradient = RKNativeSolidGradient();
        if (gradient && RKNativeSetObject(copy, property[1], gradient)) RKNativeTraitsRecolored++;
    }
    // The highlighted getter synthesizes an overlay. Copy its stored traits,
    // not that temporary result, preserving shared normal/highlight variants.
    for (NSArray *property in @[@[@"_variantTraits", @"setVariantTraits:"],
                                @[@"_highlightedVariantTraits", @"setHighlightedVariantTraits:"]]) {
        id child = RKBlackObjectIvar(original, [property[0] UTF8String]);
        if (child) RKNativeSetObject(copy, property[1], RKNativeCopyKeyTraits(child, copies, depth + 1));
    }
    id hash = RKNativeObject(original, @"hashString");
    if ([hash isKindOfClass:NSString.class]) {
        NSArray *rgb = RKKeyboardRGB(RKBlackPrefs[@"KeycapColor"]);
        RKNativeSetObject(copy, @"setHashString:", [hash stringByAppendingFormat:@"-rk9-%.6f-%.6f-%.6f",
            [rgb[0] doubleValue], [rgb[1] doubleValue], [rgb[2] doubleValue]]);
    }
    return copy;
}

static id RKNativeKeyTraits(id original, id key, id plane) {
    if (!RKBlackEnabled() || !RKNativeKeyboardProcess(NSBundle.mainBundle.bundleIdentifier)) return original;
    id keys = RKNativeObject(plane, @"keys");
    if ((![keys isKindOfClass:NSArray.class] && ![keys isKindOfClass:NSSet.class]) || ![keys containsObject:key])
        return original;
    NSMapTable *copies = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory |
        NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
    return RKNativeCopyKeyTraits(original, copies, 0);
}

static void RKUpdateBlackAtlasLayers(CALayer *layer, NSInteger role, NSUInteger depth, CALayer *root) {
    if (depth > 8) return;
    RKMarkBlackScope(layer, root);
    objc_setAssociatedObject(layer, &RKBlackManagedLayerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *previous = objc_getAssociatedObject(layer, &RKBlackImageRoleKey);
    if (previous.integerValue != role) {
        RKUpdateBlackActionImage(layer, NO);
        objc_setAssociatedObject(layer, &RKBlackImageRoleKey, @(role), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    RKUpdateBlackActionImage(layer, RKBlackEnabled());
    RKUpdateBlackLayerColor(layer, RKBlackEnabled(), NO);
    if (role == 1 && [layer isKindOfClass:CAShapeLayer.class])
        RKUpdateBlackLayerColor(layer, RKBlackEnabled(), YES);
    for (CALayer *child in layer.sublayers) RKUpdateBlackAtlasLayers(child, role, depth + 1, root);
}

static void RKUpdateBlackKeyplane(UIView *view) {
    [RKBlackViews addObject:view];
    if (!objc_getAssociatedObject(view.layer, &RKBlackDrawRoleKey)) {
        objc_setAssociatedObject(view.layer, &RKBlackDrawRoleKey, @2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view setNeedsDisplay];
    }
    for (NSString *name in @[@"_keyBackgrounds", @"_keyBorders", @"_keyCaps"]) {
        id surface = RKBlackObjectIvar(view, name.UTF8String);
        if ([surface isKindOfClass:UIView.class]) {
            NSInteger role = [name isEqual:@"_keyCaps"] ? 2 : 1;
            RKUpdateBlackImageViews(surface, role, NO, 0, view.layer);
            RKUpdateBlackAtlasLayers(((UIView *)surface).layer, role, 0, view.layer);
            if (role == 1) {
                // Semantic background-only ivars, never _keyCaps (legends).
                CALayer *background = ((UIView *)surface).layer;
                [RKBlackBackgroundLayers addObject:background];
                RKUpdateBlackBackgroundVisibility(background, RKBlackEnabled());
            }
        }
    }
    // Some render flags place the combined atlas on the keyplane itself.
    objc_setAssociatedObject(view.layer, &RKBlackImageRoleKey, @2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RKUpdateBlackActionImage(view.layer, RKBlackEnabled());
    RKPublishBlackDiagnostic();
}

static void RKUpdateBlackSplitView(UIView *view) {
    Class plane = NSClassFromString(@"UIKBKeyplaneView");
    for (UIView *parent = view; parent; parent = parent.superview) {
        if (plane && [parent isKindOfClass:plane]) {
            RKUpdateBlackKeyplane(parent);
            break;
        }
    }
}

static BOOL RKBlackExcludedView(UIView *view) {
    return RKKeyboardExcludedView(view);
}

static void RKScanWeTypeKeys(UIView *node, UIView *host, NSUInteger depth) {
    if (depth > 12) return;
    for (UIView *view in node.subviews) {
        if (RKBlackExcludedView(view)) continue;
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        BOOL key = [view isKindOfClass:UIButton.class] || [name containsString:@"keyview"] ||
            [name containsString:@"keybutton"] || [name containsString:@"keycap"] || [name hasSuffix:@"key"];
        BOOL sized = view.bounds.size.width >= 10 && view.bounds.size.width <= host.bounds.size.width * .92 &&
            view.bounds.size.height >= 14 && view.bounds.size.height <= 120;
        if (key && sized) {
            RKBlackWeTypeKeys++;
            RKRefreshBlackKeyState(view);
        } else RKScanWeTypeKeys(view, host, depth + 1);
    }
}

void RKApplyBlackKeyboardHost(UIView *host) {
    if (!host) return;
    if ([NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"]) {
        [RKBlackWeTypeHosts addObject:host];
        RKUpdateBlackSurface(host, NO);
        RKUpdateBlackKeycaps(host);
        RKScanWeTypeKeys(host, host, 0);
    } else {
        Class plane = NSClassFromString(@"UIKBKeyplaneView");
        Class key = NSClassFromString(@"UIKBKeyView");
        NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:host];
        NSUInteger visited = 0;
        while (pending.count && visited++ < 512) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if (plane && [view isKindOfClass:plane]) RKUpdateBlackKeyplane(view);
            if (key && [view isKindOfClass:key]) RKRefreshBlackKeyState(view);
            if (!RKBlackExcludedView(view)) [pending addObjectsFromArray:view.subviews];
        }
    }
    RKPublishBlackDiagnostic();
}

%group RKBlackKeyplane
%hook UIKBKeyplaneView
- (void)layoutSubviews {
    %orig;
    RKUpdateBlackKeyplane((UIView *)self);
}
%end
%end
%group RKBlackKeyplaneDisplay
%hook UIKBKeyplaneView
- (void)displayLayer:(CALayer *)layer {
    %orig;
    RKUpdateBlackKeyplane((UIView *)self);
}
%end
%end
%group RKBlackKeyplaneRender
%hook UIKBKeyplaneView
- (void)drawContentsOfRenderers:(id)renderers {
    %orig;
    RKUpdateBlackKeyplane((UIView *)self);
}
%end
%end
%group RKBlackSplitLayout
%hook UIKBSplitImageView
- (void)layoutSubviews {
    %orig;
    RKUpdateBlackSplitView((UIView *)self);
}
%end
%end
%group RKBlackSplitImage
%hook UIKBSplitImageView
- (void)setImage:(id)image cachedWidth:(CGFloat)width keyplane:(id)plane {
    %orig;
    RKUpdateBlackSplitView((UIView *)self);
}
%end
%end
%group RKBlackSplitImages
%hook UIKBSplitImageView
- (void)setImage:(id)image splitLeft:(id)left splitRight:(id)right keyplane:(id)plane {
    %orig;
    RKUpdateBlackSplitView((UIView *)self);
}
%end
%end

%group RKBlackPublicViews
%hook CAShapeLayer
- (void)setPath:(CGPathRef)path {
    %orig;
    RKRefreshBlackFaceGeometry((CALayer *)self);
}
- (void)setFillColor:(CGColorRef)color {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackUpdatingColorKey) || !NSThread.isMainThread) return;
    RKRefreshBlackFaceGeometry((CALayer *)self);
    if ([objc_getAssociatedObject(self, &RKBlackFaceStyleKey) boolValue])
        RKUpdateBlackLayerColor((CALayer *)self, RKBlackEnabled(), YES);
}
%end
%hook CAGradientLayer
- (void)setColors:(NSArray *)colors {
    %orig;
    if ([objc_getAssociatedObject(self, &RKBlackFaceStyleKey) boolValue] && NSThread.isMainThread)
        RKUpdateBlackGradient((CAGradientLayer *)self, RKBlackEnabled());
}
%end
%hook UIView
- (void)didAddSubview:(UIView *)subview {
    %orig;
    RKPrepareAttachedKeyLayer(subview.layer);
}
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)context {
    RKDrawBlackKeyLayer((UIView *)self, layer, context, ^(CGContextRef drawing) {
        %orig(layer, drawing);
    });
}
%end
%hook UIInputViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if ([NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"])
        RKApplyBlackKeyboardHost(((UIViewController *)self).view);
}
%end

%hook UIControl
- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    CALayer *root = RKBlackKeyRoot(((UIView *)self).layer);
    if ([root.delegate isKindOfClass:UIView.class]) RKRefreshBlackKeyState((UIView *)root.delegate);
}
- (void)setSelected:(BOOL)selected {
    %orig;
    CALayer *root = RKBlackKeyRoot(((UIView *)self).layer);
    if ([root.delegate isKindOfClass:UIView.class]) RKRefreshBlackKeyState((UIView *)root.delegate);
}
%end
%hook UIButton
- (void)setBackgroundImage:(UIImage *)image forState:(UIControlState)state {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackButtonImagesKey) && NSThread.isMainThread)
        RKUpdateBlackButton((UIButton *)self, RKBlackEnabled());
}
%end
%hook UIImageView
- (void)setImage:(UIImage *)image {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackUIImageRoleKey))
        RKUpdateBlackUIImage((UIImageView *)self, RKBlackEnabled());
}
- (void)setHighlightedImage:(UIImage *)image {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackUIImageRoleKey))
        RKUpdateBlackUIImage((UIImageView *)self, RKBlackEnabled());
}
- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackUIImageRoleKey))
        RKUpdateBlackUIImage((UIImageView *)self, RKBlackEnabled());
}
%end
%hook UILabel
- (void)setTextColor:(UIColor *)color {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackLabelManagedKey))
        RKUpdateBlackLabel((UILabel *)self, RKBlackEnabled());
}
- (void)setAttributedText:(NSAttributedString *)text {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackLabelManagedKey))
        RKUpdateBlackLabel((UILabel *)self, RKBlackEnabled());
}
%end

%hook CALayer
- (void)setBounds:(CGRect)bounds {
    %orig;
    if ([self isKindOfClass:CAShapeLayer.class] || [self isKindOfClass:CAGradientLayer.class])
        RKRefreshBlackFaceGeometry((CALayer *)self);
}
- (void)addSublayer:(CALayer *)layer {
    %orig;
    RKPrepareAttachedKeyLayer(layer);
}
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)index {
    %orig;
    RKPrepareAttachedKeyLayer(layer);
}
- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    %orig;
    RKPrepareAttachedKeyLayer(layer);
}
- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    %orig;
    RKPrepareAttachedKeyLayer(layer);
}
- (void)replaceSublayer:(CALayer *)oldLayer with:(CALayer *)newLayer {
    %orig;
    RKPrepareAttachedKeyLayer(newLayer);
}
- (void)setSublayers:(NSArray *)layers {
    %orig;
    for (CALayer *layer in layers) RKPrepareAttachedKeyLayer(layer);
}
- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
    if (RKBlackKeyRoot((CALayer *)self)) {
        CAAnimation *filtered = RKKeyColorAnimation((CALayer *)self, animation);
        if (!filtered) return;
        %orig(filtered, key);
        return;
    }
    %orig;
}
- (void)setHidden:(BOOL)hidden {
    if (objc_getAssociatedObject(self, &RKBlackHidingKey)) {
        %orig;
        return;
    }
    NSNumber *original = objc_getAssociatedObject(self, &RKBlackHiddenKey);
    if (original) {
        objc_setAssociatedObject(self, &RKBlackHiddenKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (RKBlackEnabled() && RKBlackInScope((CALayer *)self)) {
            %orig(YES);
            return;
        }
        objc_setAssociatedObject(self, &RKBlackHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}
- (void)setContents:(id)contents {
    %orig;
    if (!objc_getAssociatedObject(self, &RKBlackManagedLayerKey) ||
        objc_getAssociatedObject(self, &RKBlackUpdatingImageKey)) return;
    if (NSThread.isMainThread) RKUpdateBlackActionImage((CALayer *)self, RKBlackEnabled());
    else {
        __weak CALayer *weakLayer = (CALayer *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CALayer *layer = weakLayer;
            if (layer) RKUpdateBlackActionImage(layer, RKBlackEnabled());
        });
    }
}
- (void)setBackgroundColor:(CGColorRef)color {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackManagedLayerKey) &&
        !objc_getAssociatedObject(self, &RKBlackUpdatingColorKey) && NSThread.isMainThread)
        RKUpdateBlackLayerColor((CALayer *)self, RKBlackEnabled(), NO);
}
%end
%end

%group RKBlackRenderConfig
%hook UIKBRenderConfig
- (CGFloat)keycapOpacity {
    return RKBlackEnabled() ? 0 : %orig;
}
- (CGFloat)lightKeycapOpacity {
    return RKBlackEnabled() ? 0 : %orig;
}
- (BOOL)lightKeyboard {
    return RKBlackEnabled() ? NO : %orig;
}
- (BOOL)whiteText {
    return RKBlackEnabled() ? YES : %orig;
}
%end
%end

%group RKQQRenderAppearance
%hook UIKBRenderConfig
+ (id)configForAppearance:(NSInteger)appearance inputMode:(id)mode {
    return %orig(RKQQKeyboardAppearance(appearance), mode);
}
%end
%end

%group RKQQRenderTraitsAppearance
%hook UIKBRenderConfig
+ (id)configForAppearance:(NSInteger)appearance inputMode:(id)mode traitEnvironment:(id)environment {
    return %orig(RKQQKeyboardAppearance(appearance), mode, environment);
}
%end
%end

%group RKBlackActionKey
%hook UIKBKeyView
- (void)layoutSubviews {
    %orig;
    RKRefreshSystemKey((UIView *)self);
}
%end
%end

%group RKBlackActiveKey
%hook UIKBKeyView
- (void)changeBackgroundToActiveIfNecessary {
    void *previous = RKNativeBackgroundContext;
    if (RKNativeKeyView((UIView *)self)) RKNativeBackgroundContext = (__bridge void *)self;
    @try {
        %orig;
    } @finally {
        RKNativeBackgroundContext = previous;
    }
    RKRefreshSystemKey((UIView *)self);
}
%end
%end
%group RKBlackEnabledKey
%hook UIKBKeyView
- (void)changeBackgroundToEnabled {
    void *previous = RKNativeBackgroundContext;
    if (RKNativeKeyView((UIView *)self)) RKNativeBackgroundContext = (__bridge void *)self;
    @try {
        %orig;
    } @finally {
        RKNativeBackgroundContext = previous;
    }
    RKRefreshSystemKey((UIView *)self);
}
%end
%end
%group RKBlackPrepareKey
%hook UIKBKeyView
- (void)prepareForDisplay {
    %orig;
    RKRefreshSystemKey((UIView *)self);
}
%end
%end

%group RKBlackPopulateKey
%hook UIKBKeyView
- (void)_populateLayer:(CALayer *)layer withContents:(id)contents {
    %orig;
    if (RKNativeKeyView((UIView *)self)) RKRefreshNativeKey((UIView *)self);
    else {
        RKUpdateBlackKeyLayers(layer, RKBlackEnabled(), 0, ((UIView *)self).layer);
        RKUpdateBlackActionKey((UIView *)self);
    }
}
%end
%end

%group RKBlackDisplayKey
%hook UIKBKeyView
- (void)displayLayer:(CALayer *)layer {
    %orig;
    if (RKNativeKeyView((UIView *)self)) RKRefreshNativeKey((UIView *)self);
    else RKUpdateBlackActionKey((UIView *)self);
}
%end
%end

%group RKBlackCachedLayer
%hook _UIKBKeyViewLayer
- (void)setContents:(id)contents {
    %orig;
    if (objc_getAssociatedObject(self, &RKBlackUpdatingImageKey)) return;
    if (NSThread.isMainThread) {
        RKUpdateBlackActionImage((CALayer *)self, RKBlackEnabled());
    } else {
        __weak CALayer *weakLayer = (CALayer *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            CALayer *layer = weakLayer;
            if (layer) RKUpdateBlackActionImage(layer, RKBlackEnabled());
        });
    }
}
%end
%end

%group RKNativeRenderKey
%hook UIKBKeyView
- (void)drawContentsOfRenderers:(id)renderers {
    %orig;
    RKRefreshNativeKey((UIView *)self);
}
%end
%end
%group RKNativeBackgroundSelection
%hook UIKBKeyView
- (id)layerForRenderFlags:(long long)flags {
    id layer = %orig;
    if (RKNativeBackgroundContext == (__bridge void *)self && [layer isKindOfClass:CALayer.class])
        RKMarkNativeBackground((UIView *)self, layer);
    return layer;
}
%end
%end
%group RKNativeMultiplyLayer
%hook CALayer
- (void)setContentsMultiplyColor:(CGColorRef)color {
    if (objc_getAssociatedObject(self, &RKNativeMultiplyUpdatingKey)) {
        %orig;
        return;
    }
    NSDictionary *cache = objc_getAssociatedObject(self, &RKNativeMultiplyKey);
    if (cache) {
        NSMutableDictionary *updated = [cache mutableCopy];
        updated[@"source"] = color ? (__bridge id)color : NSNull.null;
        objc_setAssociatedObject(self, &RKNativeMultiplyKey, updated, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
    if (objc_getAssociatedObject(self, &RKNativeBackgroundLayerKey)) RKUpdateNativeMultiply((CALayer *)self);
}
- (void)setContents:(id)contents {
    %orig;
    if (objc_getAssociatedObject(self, &RKNativeBackgroundLayerKey)) RKUpdateNativeMultiply((CALayer *)self);
}
%end
%end
%group RKNativeRenderTraits
%hook UIKBRenderFactory
- (id)traitsForKey:(id)key onKeyplane:(id)plane {
    id traits = %orig;
    return RKNativeKeyTraits(traits, key, plane);
}
%end
%end
%group RKNativeBackgroundGradient
%hook UIKBGradient
- (CGGradientRef)CGGradient {
    UIColor *color = objc_getAssociatedObject(self, &RKNativeGradientColorKey);
    if (!color) return %orig;
    CGFloat opacity = ((CGFloat (*)(id, SEL))objc_msgSend)(self, @selector(opacity));
    color = [color colorWithAlphaComponent:isfinite(opacity) ? MIN(1, MAX(0, opacity)) : 1];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(__bridge id)color.CGColor, (__bridge id)color.CGColor];
    // UIKBGradient's CGGradient selector returns +1, despite its getter name.
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
    CGColorSpaceRelease(space);
    return gradient;
}
- (BOOL)usesRGBColors {
    return objc_getAssociatedObject(self, &RKNativeGradientColorKey) ? YES : %orig;
}
- (id)copyWithZone:(NSZone *)zone {
    id copy = %orig;
    UIColor *color = objc_getAssociatedObject(self, &RKNativeGradientColorKey);
    if (color) objc_setAssociatedObject(copy, &RKNativeGradientColorKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return copy;
}
%end
%end
%group RKNativeBackdropKey
%hook UIKBKeyView
- (void)configureBackdropView:(id)backdrop forRenderConfig:(id)config {
    %orig;
    if (!RKNativeKeyView((UIView *)self) || ![backdrop isKindOfClass:NSClassFromString(@"UIKBBackdropView")]) return;
    RKBlackScope *owner = [RKBlackScope new];
    owner.root = ((UIView *)self).layer;
    objc_setAssociatedObject(backdrop, &RKNativeBackdropOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RKUpdateNativeBackdrop(backdrop);
    RKRefreshNativeKey((UIView *)self);
}
%end
%end
%group RKNativePlaneState
%hook UIKBKeyplaneView
- (void)setState:(int)state forKey:(id)key {
    RKBeginNativeStateTransition();
    @try {
        %orig;
        RKQueueNativeStateKey((UIView *)self, key, state);
    } @finally {
        if (RKNativeStateTransitionDepth) RKEndNativeStateTransition();
    }
}
%end
%end
%group RKNativePlaneStateReason
%hook UIKBKeyplaneView
- (void)setState:(int)state forKey:(id)key withReason:(id)reason force:(BOOL)force {
    RKBeginNativeStateTransition();
    @try {
        %orig;
        RKQueueNativeStateKey((UIView *)self, key, state);
    } @finally {
        if (RKNativeStateTransitionDepth) RKEndNativeStateTransition();
    }
}
%end
%end
%group RKNativePlaneKeyView
%hook UIKBKeyplaneView
- (id)viewForKey:(id)key state:(int)state {
    id view = %orig;
    if ([view isKindOfClass:UIView.class]) RKRefreshNativeKey(view);
    return view;
}
%end
%end
%group RKNativeLayerState
%hook UIKBBackdropView
- (void)layoutSubviews {
    %orig;
    RKUpdateNativeBackdrop((UIView *)self);
}
%end
%hook CALayer
- (void)setCompositingFilter:(id)filter {
    if (objc_getAssociatedObject(self, &RKNativeFilterUpdatingKey)) {
        %orig;
        return;
    }
    if (objc_getAssociatedObject(self, &RKNativeCompositingKey))
        objc_setAssociatedObject(self, &RKNativeCompositingKey,
            @{@"source":filter ?: NSNull.null}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
    if (objc_getAssociatedObject(self, &RKNativeKeyOwnerKey)) RKUpdateNativeCompositing((CALayer *)self);
}
- (void)setBounds:(CGRect)bounds {
    %orig;
    if (objc_getAssociatedObject(self, &RKNativeKeyOwnerKey)) RKUpdateNativeCompositing((CALayer *)self);
}
- (void)addSublayer:(CALayer *)layer {
    %orig;
    RKPrepareNativeAttachedLayer(layer);
}
- (void)insertSublayer:(CALayer *)layer atIndex:(unsigned int)index {
    %orig;
    RKPrepareNativeAttachedLayer(layer);
}
- (void)insertSublayer:(CALayer *)layer below:(CALayer *)sibling {
    %orig;
    RKPrepareNativeAttachedLayer(layer);
}
- (void)insertSublayer:(CALayer *)layer above:(CALayer *)sibling {
    %orig;
    RKPrepareNativeAttachedLayer(layer);
}
- (void)replaceSublayer:(CALayer *)oldLayer with:(CALayer *)newLayer {
    %orig;
    RKPrepareNativeAttachedLayer(newLayer);
}
- (void)setSublayers:(NSArray *)layers {
    %orig;
    for (CALayer *layer in layers) RKPrepareNativeAttachedLayer(layer);
}
- (void)addAnimation:(CAAnimation *)animation forKey:(NSString *)key {
    CAAnimation *filtered = RKNativeBlendAnimation((CALayer *)self, animation);
    if (filtered) %orig(filtered, key);
}
%end
%end

%hook UIKBBackdropView
- (void)layoutSubviews {
    %orig;
    RKUpdateBlackSurface((UIView *)self, YES);
}
%end
%hook UIKeyboardLayoutStar
- (void)layoutSubviews {
    %orig;
    RKUpdateBlackSurface((UIView *)self, NO);
    RKUpdateBlackKeycaps((UIView *)self);
    RKQueueKeyboardFaces((UIView *)self);
}
%end
%hook UIKeyboardDockView
- (void)layoutSubviews {
    %orig;
    RKUpdateBlackSurface((UIView *)self, NO);
}
%end

static void RKBlackChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                           const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ RKBlackReload(); });
}

static BOOL RKBlackVoidMethod(Class cls, NSString *name, NSUInteger count) {
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:NSSelectorFromString(name)];
    if (!signature || signature.numberOfArguments != count ||
        strcmp(signature.methodReturnType, @encode(void))) return NO;
    for (NSUInteger i = 2; i < count; i++)
        if (strcmp([signature getArgumentTypeAtIndex:i], @encode(id))) return NO;
    return YES;
}

static BOOL RKNativeMethod(Class cls, NSString *name, const char *result, NSArray<NSString *> *arguments) {
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:NSSelectorFromString(name)];
    if (!signature || strcmp(signature.methodReturnType, result) ||
        signature.numberOfArguments != arguments.count + 2) return NO;
    for (NSUInteger i = 0; i < arguments.count; i++)
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String)) return NO;
    return YES;
}

static void RKInstallNativeStateHooks(void) {
    if (!RKNativeKeyboardProcess(NSBundle.mainBundle.bundleIdentifier)) return;
    Class key = NSClassFromString(@"UIKBKeyView"), plane = NSClassFromString(@"UIKBKeyplaneView");
    static BOOL render, backdrop, state, reason, view, layers, backgroundSelection;
    if (!RKNativeMultiplyHookInstalled &&
        RKNativeMethod(CALayer.class, @"contentsMultiplyColor", @encode(CGColorRef), @[]) &&
        RKNativeMethod(CALayer.class, @"setContentsMultiplyColor:", @encode(void), @[@(@encode(CGColorRef))])) {
        %init(RKNativeMultiplyLayer);
        RKNativeMultiplyHookInstalled = YES;
    }
    if (!backgroundSelection && RKNativeMethod(key, @"layerForRenderFlags:", @encode(id), @[@(@encode(long long))])) {
        %init(RKNativeBackgroundSelection);
        backgroundSelection = YES;
    }
    Class gradient = NSClassFromString(@"UIKBGradient");
    if (!RKNativeGradientHookInstalled &&
        RKNativeMethod(gradient, @"CGGradient", @encode(CGGradientRef), @[]) &&
        RKNativeMethod(gradient, @"usesRGBColors", @encode(BOOL), @[]) &&
        RKNativeMethod(gradient, @"opacity", @encode(CGFloat), @[]) &&
        RKNativeMethod(gradient, @"copyWithZone:", @encode(id), @[@(@encode(NSZone *))])) {
        %init(RKNativeBackgroundGradient);
        RKNativeGradientHookInstalled = YES;
    }
    Class factory = NSClassFromString(@"UIKBRenderFactory");
    if (RKNativeGradientHookInstalled && !RKNativeTraitsHookInstalled && RKNativeMethod(factory, @"traitsForKey:onKeyplane:", @encode(id),
        @[@(@encode(id)), @(@encode(id))])) {
        %init(RKNativeRenderTraits);
        RKNativeTraitsHookInstalled = YES;
    }
    if (!render && RKBlackVoidMethod(key, @"drawContentsOfRenderers:", 3)) {
        %init(RKNativeRenderKey); render = YES;
    }
    if (!backdrop && RKBlackVoidMethod(key, @"configureBackdropView:forRenderConfig:", 4)) {
        %init(RKNativeBackdropKey); backdrop = YES;
    }
    if (!state && RKNativeMethod(plane, @"setState:forKey:", @encode(void), @[@(@encode(int)), @(@encode(id))])) {
        %init(RKNativePlaneState); state = YES;
    }
    if (!reason && RKNativeMethod(plane, @"setState:forKey:withReason:force:", @encode(void),
        @[@(@encode(int)), @(@encode(id)), @(@encode(id)), @(@encode(BOOL))])) {
        %init(RKNativePlaneStateReason); reason = YES;
    }
    if (!view && RKNativeMethod(plane, @"viewForKey:state:", @encode(id), @[@(@encode(id)), @(@encode(int))])) {
        %init(RKNativePlaneKeyView); view = YES;
    }
    if (!layers && NSClassFromString(@"UIKBBackdropView")) {
        %init(RKNativeLayerState); layers = YES;
    }
    RKNativeStateHooksInstalled = state && reason && view;
}

static void RKInstallBlackHooks(void) {
    static BOOL qqLegacyAppearance, qqTraitsAppearance;
    if (!qqLegacyAppearance && RKQQKeyboardBundle(NSBundle.mainBundle.bundleIdentifier) &&
        RKNativeMethod(object_getClass(NSClassFromString(@"UIKBRenderConfig")),
            @"configForAppearance:inputMode:", @encode(id), @[@(@encode(NSInteger)), @(@encode(id))])) {
        %init(RKQQRenderAppearance);
        qqLegacyAppearance = YES;
    }
    if (!qqTraitsAppearance && RKQQKeyboardBundle(NSBundle.mainBundle.bundleIdentifier) &&
        RKNativeMethod(object_getClass(NSClassFromString(@"UIKBRenderConfig")),
            @"configForAppearance:inputMode:traitEnvironment:", @encode(id),
            @[@(@encode(NSInteger)), @(@encode(id)), @(@encode(id))])) {
        %init(RKQQRenderTraitsAppearance);
        qqTraitsAppearance = YES;
    }
    RKQQAppearanceHookInstalled = qqLegacyAppearance || qqTraitsAppearance;
    Class plane = NSClassFromString(@"UIKBKeyplaneView");
    if (!RKBlackKeyplaneHookInstalled && [plane isSubclassOfClass:UIView.class] &&
        RKBlackVoidMethod(plane, @"layoutSubviews", 2)) {
        %init(RKBlackKeyplane);
        RKBlackKeyplaneHookInstalled = YES;
    }
    static BOOL planeDisplay, planeRender, splitImage, splitImages;
    if (!planeDisplay && RKBlackVoidMethod(plane, @"displayLayer:", 3)) {
        %init(RKBlackKeyplaneDisplay);
        planeDisplay = YES;
    }
    if (!planeRender && RKBlackVoidMethod(plane, @"drawContentsOfRenderers:", 3)) {
        %init(RKBlackKeyplaneRender);
        planeRender = YES;
    }
    Class split = NSClassFromString(@"UIKBSplitImageView");
    if (!RKBlackSplitHookInstalled && [split isSubclassOfClass:UIView.class] &&
        RKBlackVoidMethod(split, @"layoutSubviews", 2)) {
        %init(RKBlackSplitLayout);
        RKBlackSplitHookInstalled = YES;
    }
    NSMethodSignature *imageSignature = [split instanceMethodSignatureForSelector:
        NSSelectorFromString(@"setImage:cachedWidth:keyplane:")];
    if (!splitImage && imageSignature.numberOfArguments == 5 &&
        !strcmp(imageSignature.methodReturnType, @encode(void)) &&
        !strcmp([imageSignature getArgumentTypeAtIndex:2], @encode(id)) &&
        !strcmp([imageSignature getArgumentTypeAtIndex:3], @encode(CGFloat)) &&
        !strcmp([imageSignature getArgumentTypeAtIndex:4], @encode(id))) {
        %init(RKBlackSplitImage);
        splitImage = YES;
    }
    if (!splitImages && RKBlackVoidMethod(split, @"setImage:splitLeft:splitRight:keyplane:", 6)) {
        %init(RKBlackSplitImages);
        splitImages = YES;
    }
    if (!RKBlackConfigHooksInstalled) {
        Class config = NSClassFromString(@"UIKBRenderConfig");
        BOOL compatible = config != Nil;
        for (NSString *name in @[@"keycapOpacity", @"lightKeycapOpacity", @"lightKeyboard", @"whiteText"]) {
            NSMethodSignature *signature = [config instanceMethodSignatureForSelector:NSSelectorFromString(name)];
            const char *type = [name hasSuffix:@"Opacity"] ? @encode(CGFloat) : @encode(BOOL);
            if (!signature || signature.numberOfArguments != 2 ||
                strcmp(signature.methodReturnType, type)) compatible = NO;
        }
        if (compatible) {
            %init(RKBlackRenderConfig);
            RKBlackConfigHooksInstalled = YES;
        }
    }
    Class keyView = NSClassFromString(@"UIKBKeyView");
    if (!RKBlackActionHookInstalled && [keyView isSubclassOfClass:UIView.class] &&
        RKBlackVoidMethod(keyView, @"layoutSubviews", 2)) {
        %init(RKBlackActionKey);
        RKBlackActionHookInstalled = YES;
    }
    static BOOL populateInstalled, displayInstalled;
    static BOOL activeInstalled, enabledInstalled, prepareInstalled;
    if (!activeInstalled && RKBlackVoidMethod(keyView, @"changeBackgroundToActiveIfNecessary", 2)) {
        %init(RKBlackActiveKey);
        activeInstalled = YES;
    }
    if (!enabledInstalled && RKBlackVoidMethod(keyView, @"changeBackgroundToEnabled", 2)) {
        %init(RKBlackEnabledKey);
        enabledInstalled = YES;
    }
    if (!prepareInstalled && RKBlackVoidMethod(keyView, @"prepareForDisplay", 2)) {
        %init(RKBlackPrepareKey);
        prepareInstalled = YES;
    }
    if (!populateInstalled && RKBlackVoidMethod(keyView, @"_populateLayer:withContents:", 4)) {
        %init(RKBlackPopulateKey);
        populateInstalled = YES;
    }
    if (!displayInstalled && RKBlackVoidMethod(keyView, @"displayLayer:", 3)) {
        %init(RKBlackDisplayKey);
        displayInstalled = YES;
    }
    Class layer = NSClassFromString(@"_UIKBKeyViewLayer");
    if (!RKBlackLayerHookInstalled && [layer isSubclassOfClass:CALayer.class] &&
        RKBlackVoidMethod(layer, @"setContents:", 3)) {
        %init(RKBlackCachedLayer);
        RKBlackLayerHookInstalled = YES;
    }
}

static void RKBlackImageLoaded(const struct mach_header *header, intptr_t slide) {
    os_unfair_lock_lock(&RKBlackHookLock);
    BOOL enqueue = !RKBlackHookQueued;
    RKBlackHookQueued = YES;
    os_unfair_lock_unlock(&RKBlackHookLock);
    if (!enqueue) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&RKBlackHookLock);
        RKBlackHookQueued = NO;
        os_unfair_lock_unlock(&RKBlackHookLock);
        RKInstallBlackHooks();
        RKInstallNativeStateHooks();
    });
}

static void RKPublishBlackDiagnostic(void) {
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < .5) return;
    last = now;
    uint8_t flags = (RKBlackEnabled() ? 1 : 0) | (RKBlackKeyplaneHookInstalled ? 2 : 0) |
        (RKBlackSplitHookInstalled ? 4 : 0) | (RKBlackActionHookInstalled ? 8 : 0) |
        (RKBlackConfigHooksInstalled ? 16 : 0);
    BOOL weType = [NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"];
    int token = RKBlackProbeToken(weType);
    if (token >= 0) notify_set_state(token, RKBlackProbeState(flags,
        RKBlackBackgroundColors + RKBlackBackgroundImages, RKBlackAtlasImages,
        RKBlackGrayImages + RKBlackBlueImages, RKBlackWeTypeKeys));
    RKPublishBlackSurfaceProbe(weType, RKBlackDirectDraws, RKBlackDirectConversions,
        RKBlackSuppressedBackgrounds, RKBlackShapeFaces, RKBlackObservedKeys.count);
    if (!weType) RKPublishNativeStateProbe((RKNativeStateHooksInstalled ? 1 : 0) |
        (RKNativeTraitsHookInstalled ? 2 : 0) | (RKNativeMultiplyHookInstalled ? 4 : 0),
        RKNativeTraitsRecolored, RKNativeStateRefreshes, RKNativeMultiplyChanges, RKNativeStretchImages);
}

static void RKWriteBlackDiagnostic(void) {
    RKInstallBlackHooks();
    RKPublishBlackDiagnostic();
    NSMutableSet *views = [NSMutableSet set], *layers = [NSMutableSet set];
    for (UIView *view in RKBlackViews) [views addObject:NSStringFromClass(view.class)];
    for (CALayer *layer in RKBlackImageLayers) [layers addObject:NSStringFromClass(layer.class)];
    NSDictionary *report = @{@"version":@"samsung17",
        @"systemVersion":UIDevice.currentDevice.systemVersion, @"preferenceSync":RKPreferencesDiagnostic(),
        @"processBundle":NSBundle.mainBundle.bundleIdentifier ?: @"unknown",
        @"enabled":@(RKBlackEnabled()), @"configHook":@(RKBlackConfigHooksInstalled),
        @"qqAppearanceHook":@(RKQQAppearanceHookInstalled), @"qqAppearanceOverrides":@(RKQQAppearanceOverrides),
        @"storedPreferenceReads":@(RKStoredPreferenceReads),
        @"keyViewHook":@(RKBlackActionHookInstalled), @"imageLayerHook":@(RKBlackLayerHookInstalled),
        @"keyplaneHook":@(RKBlackKeyplaneHookInstalled),
        @"splitImageHook":@(RKBlackSplitHookInstalled),
        @"atlasImagesConverted":@(RKBlackAtlasImages), @"backgroundImagesConverted":@(RKBlackBackgroundImages),
        @"weTypeKeyVisits":@(RKBlackWeTypeKeys),
        @"backgroundColorsChanged":@(RKBlackBackgroundColors),
        @"directDraws":@(RKBlackDirectDraws), @"directConversions":@(RKBlackDirectConversions),
        @"stateRefreshes":@(RKBlackStateRefreshes),
        @"nativeStateHooks":@(RKNativeStateHooksInstalled), @"nativeStateRefreshes":@(RKNativeStateRefreshes),
        @"nativeStateBatches":@(RKNativeStateBatches), @"nativeStateLookups":@(RKNativeStateLookups),
        @"geometryRequests":@(RKBlackGeometryRequests),
        @"nativeStretchImages":@(RKNativeStretchImages), @"nativeFilterChanges":@(RKNativeFilterChanges),
        @"nativeTraitsHook":@(RKNativeTraitsHookInstalled), @"nativeTraitsRecolored":@(RKNativeTraitsRecolored),
        @"nativeMultiplyHook":@(RKNativeMultiplyHookInstalled), @"nativeMultiplyChanges":@(RKNativeMultiplyChanges),
        @"suppressedBackgrounds":@(RKBlackSuppressedBackgrounds), @"shapeFaces":@(RKBlackShapeFaces),
        @"grayImagesConverted":@(RKBlackGrayImages), @"blueImagesConverted":@(RKBlackBlueImages),
        @"unchangedImages":@(RKBlackUnchangedImages),
        @"observedViewClasses":views.allObjects, @"observedLayerClasses":layers.allObjects};
    NSString *file = [NSString stringWithFormat:@"RainbowKeyboard-black-probe-%@.plist",
        NSBundle.mainBundle.bundleIdentifier ?: @"unknown"];
    NSString *path = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
    if (![report writeToFile:path atomically:YES])
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:file] atomically:YES];
}

%ctor {
    @autoreleasepool {
        RKBlackViews = [NSHashTable weakObjectsHashTable];
        RKBlackImageLayers = [NSHashTable weakObjectsHashTable];
        RKBlackWeTypeHosts = [NSHashTable weakObjectsHashTable];
        RKBlackManagedImages = [NSHashTable weakObjectsHashTable];
        RKBlackManagedLabels = [NSHashTable weakObjectsHashTable];
        RKBlackBackgroundLayers = [NSHashTable weakObjectsHashTable];
        RKBlackObservedKeys = [NSHashTable weakObjectsHashTable];
        RKBlackButtons = [NSHashTable weakObjectsHashTable];
        RKNativeFilteredLayers = [NSHashTable weakObjectsHashTable];
        RKNativeBackgrounds = [NSHashTable weakObjectsHashTable];
        RKStartPreferencesRelay();
        RKRequestPreferencesRelay();
        RKBlackReload();
        RKInstallBlackHooks();
        _dyld_register_func_for_add_image(RKBlackImageLoaded);
        %init(RKBlackPublicViews);
        %init;
        RKInstallNativeStateHooks();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, RKBlackChanged,
            CFSTR("com.minis.rainbowkeyboard.changed"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                RKRequestPreferencesRelay();
                RKBlackReload();
            }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardWillShowNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                RKRequestPreferencesRelay();
                RKBlackReload();
            }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIKeyboardDidShowNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    RKWriteBlackDiagnostic();
                });
            }];
    }
}
