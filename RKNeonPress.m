#import "RKNeonPress.h"
#import "RKKeyboardGeometry.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#include <string.h>

static NSString *const RKPressScale = @"rkNeonPressScale";
static NSString *const RKPressLift = @"rkNeonPressLift";

// ---------------------------------------------------------------------------
// Extracted-glyph cache.
//
// Extraction is the expensive half of a 轻弹 press: the keycap is rendered to a bitmap
// and then every pixel of that bitmap is walked to separate ink from the flat key face.
// The answer depends on nothing but those pixels and their size, so a repeat press of a
// key whose freshly rendered pixels are byte-for-byte identical can reuse the previous
// answer. The comparison is the whole bitmap (~25 KB memcmp), which makes the reuse exact
// rather than a heuristic: identical pixels cannot produce a different foreground.
//
// That exactness is what makes it safe without knowing anything about the key's private
// model. A case change (shift) and a 中/英 switch alter the glyph pixels, and the frame
// changing alters the crop, so none of them can be served a stale glyph.
// ---------------------------------------------------------------------------
static NSMapTable<UIView *, NSDictionary *> *RKPressForegroundCache;
static const NSUInteger RKPressForegroundCacheLimit = 8;

@interface RKNeonPressLayer : CALayer
@property(nonatomic) CGRect keyFrame;
@property(nonatomic, weak) CALayer *animatedKey;
@end

@implementation RKNeonPressLayer
- (void)removeFromSuperlayer {
    // An expired pulse must not remove a newer press animation on the same key.
    if (self.superlayer) {
        [self.animatedKey removeAnimationForKey:RKPressScale];
        [self.animatedKey removeAnimationForKey:RKPressLift];
    }
    [super removeFromSuperlayer];
}
@end

// Keycap lookup is now a linear match over the registered keycaps
// (RKKeyboardKeyViewAtFrame). The previous recursive subview search, which rebuilt a
// lowercased class name for every view it visited, is gone.

static CASpringAnimation *RKPressSpring(NSString *keyPath, CGFloat start, CGFloat end) {
    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:keyPath];
    spring.mass = .55;
    spring.stiffness = 360;
    spring.damping = 14;
    spring.initialVelocity = 0;
    spring.fromValue = @(start);
    spring.toValue = @(end);
    spring.duration = MIN(.65, spring.settlingDuration);
    return spring;
}

static UIImage *RKPressForeground(UIView *overlay, UIView *keyView, CGRect face) {
    UIView *host = overlay.superview;
    if (!host.window) return nil;
    CGRect crop = [overlay convertRect:face toView:host];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = MIN(2, format.scale);
    UIImage *source = nil;
    if (keyView) {
        CGRect keyFrame = [keyView convertRect:keyView.bounds toView:host];
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
            initWithSize:keyView.bounds.size format:format];
        source = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [keyView drawViewHierarchyInRect:keyView.bounds afterScreenUpdates:NO];
        }];
        CGRect local = CGRectOffset(crop, -keyFrame.origin.x, -keyFrame.origin.y);
        CGFloat scale = source.scale;
        CGRect pixelCrop = CGRectMake(local.origin.x * scale, local.origin.y * scale,
            local.size.width * scale, local.size.height * scale);
        CGRect imageBounds = CGRectMake(0, 0, CGImageGetWidth(source.CGImage), CGImageGetHeight(source.CGImage));
        pixelCrop = CGRectIntersection(pixelCrop, imageBounds);
        CGImageRef cropped = CGRectIsEmpty(pixelCrop) ? NULL :
            CGImageCreateWithImageInRect(source.CGImage, pixelCrop);
        if (cropped) {
            source = [UIImage imageWithCGImage:cropped scale:scale orientation:UIImageOrientationUp];
            CGImageRelease(cropped);
        } else source = nil;
    } else {
        // Do not fall back to a full-keyboard hierarchy snapshot on the typing path.
        return nil;
    }
    size_t width = CGImageGetWidth(source.CGImage), height = CGImageGetHeight(source.CGImage);
    if (!width || !height || width * height > 200000) return nil;
    uint8_t *pixels = (uint8_t *)calloc(width * height, 4);
    if (!pixels) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) { free(pixels); return nil; }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), source.CGImage);
    size_t byteCount = width * height * 4;
    NSDictionary *cachedEntry = RKPressForegroundCache ? [RKPressForegroundCache objectForKey:keyView] : nil;
    NSData *cachedBitmap = cachedEntry[@"bitmap"];
    if (cachedBitmap.length == byteCount && memcmp(cachedBitmap.bytes, pixels, byteCount) == 0) {
        // Same key, same pixels, same size: the previous extraction still describes it.
        CGContextRelease(context);
        free(pixels);
        id cachedImage = cachedEntry[@"image"];
        return cachedImage == NSNull.null ? nil : cachedImage;
    }
    // Infer the flat key-face color from four inset corners, not the glyph center.
    CGFloat background[3];
    for (NSUInteger c = 0; c < 3; c++) {
        CGFloat samples[4];
        for (NSUInteger i = 0; i < 4; i++) {
            size_t x = MIN(width - 1, (size_t)(width * ((i & 1) ? .85 : .15)));
            size_t y = MIN(height - 1, (size_t)(height * ((i & 2) ? .85 : .15)));
            samples[i] = pixels[(y * width + x) * 4 + c] / 255.0;
        }
        for (NSUInteger i = 0; i < 4; i++) for (NSUInteger j = i + 1; j < 4; j++)
            if (samples[i] > samples[j]) { CGFloat t = samples[i]; samples[i] = samples[j]; samples[j] = t; }
        background[c] = (samples[1] + samples[2]) / 2;
    }
    BOOL lightInk = (background[0] + background[1] + background[2]) / 3 < .5;
    // The per-pixel pass below visits only the pixels that can carry ink. A pixel whose
    // every channel sits closer to the key face than the .035 cutoff ends up fully
    // transparent with all-zero RGB -- which is exactly what calloc already left in the
    // buffer -- so it is skipped rather than given three divisions and three stores. Most
    // of a keycap is flat key face, so this is where the loop's work used to go. The
    // result is unchanged: a channel below the cutoff contributes a difference under .035,
    // which can neither become the maximum nor survive the cutoff itself.
    CGFloat denominator[3], cutoff[3];
    for (NSUInteger c = 0; c < 3; c++) {
        denominator[c] = MAX(.05, lightInk ? 1 - background[c] : background[c]);
        cutoff[c] = .035 * denominator[c];
    }
    NSUInteger ink = 0;
    for (size_t i = 0; i < width * height; i++) {
        uint8_t *pixel = pixels + i * 4;
        CGFloat alpha = 0;
        for (NSUInteger c = 0; c < 3; c++) {
            CGFloat value = pixel[c] / 255.0;
            CGFloat delta = lightInk ? value - background[c] : background[c] - value;
            if (delta < cutoff[c]) continue;   // never lifts alpha, or pulls it down
            CGFloat difference = delta / denominator[c];
            if (difference > alpha) alpha = difference;
        }
        if (alpha <= 0) continue;
        alpha = MIN(1, alpha);
        if (alpha > .1) ink++;
        for (NSUInteger c = 0; c < 3; c++)
            pixel[c] = (uint8_t)lround(MIN(alpha, MAX(0, pixel[c] / 255.0 - background[c] * (1 - alpha))) * 255);
        pixel[3] = (uint8_t)lround(alpha * 255);
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    UIImage *foreground = image && ink > 0 && ink < width * height * .4 ?
        [UIImage imageWithCGImage:image scale:format.scale orientation:UIImageOrientationUp] : nil;
    if (image) CGImageRelease(image);
    CGContextRelease(context);
    free(pixels);
    // Keep the bitmap that produced this answer, not the answer alone: those bytes are
    // what proves on the next press that the answer is still valid.
    if (!RKPressForegroundCache) RKPressForegroundCache = [NSMapTable weakToStrongObjectsMapTable];
    if (RKPressForegroundCache.count >= RKPressForegroundCacheLimit) [RKPressForegroundCache removeAllObjects];
    [RKPressForegroundCache setObject:@{@"bitmap": [NSData dataWithBytes:pixels length:byteCount],
        @"image": foreground ?: (id)NSNull.null} forKey:keyView];
    return foreground;
}

void RKShowNeonKeyPress(UIView *overlay, CGRect keyFrame, UIColor *color, CGFloat brightness,
                       NSTimeInterval duration, BOOL reduceMotion, UIView *sourceView) {
    if (CGRectIsEmpty(keyFrame) || !CGRectContainsRect(overlay.bounds, keyFrame)) return;
    for (CALayer *layer in overlay.layer.sublayers.copy) {
        if ([layer isKindOfClass:RKNeonPressLayer.class] &&
            CGRectEqualToRect(((RKNeonPressLayer *)layer).keyFrame, keyFrame))
            [layer removeFromSuperlayer];
    }
    brightness = isfinite(brightness) ? MIN(1, MAX(0, brightness)) : 1;
    if (brightness <= 0) return;

    CGRect face = RKKeyboardKeyFacePath(keyFrame).bounds;
    // Keep this tiny, transient glyph image in memory only; never capture/store input text.
    UIView *host = overlay.superview;
    CGRect hostFrame = [overlay convertRect:keyFrame toView:host];
    UIView *key = sourceView;
    if (key && !key.window) key = nil;
    if (key) {
        CGRect sourceFrame = [key convertRect:key.bounds toView:host];
        BOOL matches = fabs(sourceFrame.origin.x - hostFrame.origin.x) <= 4 &&
            fabs(sourceFrame.origin.y - hostFrame.origin.y) <= 4 &&
            fabs(sourceFrame.size.width - hostFrame.size.width) <= 5 &&
            fabs(sourceFrame.size.height - hostFrame.size.height) <= 5;
        if (!matches) key = nil;
    }
    if (!key) key = host ? RKKeyboardKeyViewAtFrame(host, hostFrame) : nil;
    UIImage *foreground = RKPressForeground(overlay, key, face);
    RKNeonPressLayer *pulse = [RKNeonPressLayer layer];
    pulse.name = @"neonKeyPress";
    pulse.frame = overlay.bounds;
    pulse.keyFrame = keyFrame;
    [overlay.layer addSublayer:pulse];

    CALayer *clip = [CALayer layer];
    clip.name = @"pressedKeyClip";
    clip.frame = keyFrame;
    clip.masksToBounds = YES;
    [pulse addSublayer:clip];
    CALayer *cap = [CALayer layer];
    cap.name = @"neonPressedFace";
    cap.frame = CGRectOffset(face, -keyFrame.origin.x, -keyFrame.origin.y);
    cap.cornerRadius = MIN(5, MIN(face.size.width, face.size.height) * .16);
    cap.masksToBounds = YES;
    CGFloat red = 0, green = 0, blue = 0, alpha = 1;
    [color getRed:&red green:&green blue:&blue alpha:&alpha];
    cap.backgroundColor = [UIColor colorWithRed:red * brightness green:green * brightness
        blue:blue * brightness alpha:1].CGColor;
    cap.opacity = 0;
    [clip addSublayer:cap];

    CGFloat peak = 1;
    if (foreground) {
        CALayer *glyph = [CALayer layer];
        glyph.name = @"preservedKeyGlyph";
        glyph.frame = cap.bounds;
        glyph.contents = (__bridge id)foreground.CGImage;
        glyph.contentsScale = foreground.scale;
        [cap addSublayer:glyph];
    } else {
        // Unknown/complex skins remain readable instead of receiving an opaque cover.
        peak = MIN(peak, .48);
    }
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[@(peak), @(peak), @(peak * .65), @0];
    // Constant, so it is shared instead of rebuilt (with its four NSNumbers) per press.
    static NSArray *keyTimes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keyTimes = @[@0, @.35, @.65, @1]; });
    fade.keyTimes = keyTimes;
    fade.duration = duration;
    [cap addAnimation:fade forKey:@"neonPressFade"];

    NSTimeInterval cleanup = duration;
    if (!reduceMotion) {
        CASpringAnimation *scale = RKPressSpring(@"transform.scale", .92, 1);
        CASpringAnimation *lift = RKPressSpring(@"position.y", 1.6, 0);
        lift.additive = YES;
        [cap addAnimation:scale forKey:RKPressScale];
        [cap addAnimation:lift forKey:RKPressLift];
        cleanup = MAX(cleanup, scale.duration);
        // Never animate a shared renderer or override an existing model transform.
        if (key && CATransform3DIsIdentity(key.layer.transform)) {
            pulse.animatedKey = key.layer;
            [key.layer addAnimation:scale forKey:RKPressScale];
            [key.layer addAnimation:lift forKey:RKPressLift];
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((cleanup + .05) * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ [pulse removeFromSuperlayer]; });
}
