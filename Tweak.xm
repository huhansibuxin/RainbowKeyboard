#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
static char RKOverlayKey;
static char RKOverlayBoundsKey;
static void RKCollectExclusions(UIView *node, UIView *host, UIBezierPath *path, NSUInteger depth) {
    if (depth > 8) return;
    for (UIView *v in node.subviews) {
        if ([v isKindOfClass:RainbowEffectView.class] || v.hidden || v.alpha < .01) continue;
        if (RKKeyboardExcludedView(v)) {
            CGRect r = CGRectIntersection(host.bounds, [v convertRect:v.bounds toView:host]);
            if (!CGRectIsNull(r) && !CGRectIsEmpty(r)) [path appendPath:[UIBezierPath bezierPathWithRect:r]];
        } else RKCollectExclusions(v, host, path, depth + 1);
    }
}
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseBegan) continue;
        UIView *host = RKKeyboardEffectHost(touch.view);
        if (!host || !host.window) continue;
        CGPoint point = [touch locationInView:host];
        if (!CGRectContainsPoint(host.bounds, point)) continue;
        RainbowEffectView *effect = objc_getAssociatedObject(host, &RKOverlayKey);
        if (!effect) {
            effect = [[RainbowEffectView alloc] initWithFrame:host.bounds];
            objc_setAssociatedObject(host, &RKOverlayKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [host addSubview:effect];
        }
        BOOL geometryChanged = ![objc_getAssociatedObject(host, &RKOverlayBoundsKey)
            CGRectValue].size.width ||
            !CGRectEqualToRect([objc_getAssociatedObject(host, &RKOverlayBoundsKey) CGRectValue], host.bounds);
        if (geometryChanged) {
            effect.frame = host.bounds;
            [host bringSubviewToFront:effect];
            UIBezierPath *visible = [UIBezierPath bezierPathWithRect:effect.bounds];
            RKCollectExclusions(host, host, visible, 0);
            CAShapeLayer *mask = [CAShapeLayer layer];
            mask.frame = effect.bounds;
            mask.path = visible.CGPath;
            mask.fillRule = kCAFillRuleEvenOdd;
            effect.layer.mask = mask;
            effect.keyFrames = RKKeyboardKeyFrames(host);
            objc_setAssociatedObject(host, &RKOverlayBoundsKey,
                [NSValue valueWithCGRect:host.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [effect showRippleAtPoint:[touch locationInView:effect] sourceView:touch.view];
    }
}
%end
