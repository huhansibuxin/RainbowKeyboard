#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
static char RKOverlayKey;
static char RKOverlayBoundsKey;
// The overlay host is the key area itself (WBKeyboardView / UIKeyboardLayoutStar), so
// there is no candidate bar or toolbar inside it to carve out: the recursive
// exclusion-mask pass that used to run here is gone.
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseBegan) continue;
        UIView *host = RKKeyboardEffectHost(touch.view);
        if (!host) continue;
        CGPoint point = [touch locationInView:host];
        if (!CGRectContainsPoint(host.bounds, point)) continue;
        RainbowEffectView *effect = objc_getAssociatedObject(host, &RKOverlayKey);
        if (!effect) {
            effect = [[RainbowEffectView alloc] initWithFrame:host.bounds];
            objc_setAssociatedObject(host, &RKOverlayKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [host addSubview:effect];
        }
        NSValue *recordedBounds = objc_getAssociatedObject(host, &RKOverlayBoundsKey);
        BOOL geometryChanged = !recordedBounds ||
            !CGRectEqualToRect(recordedBounds.CGRectValue, host.bounds);
        if (geometryChanged) {
            effect.frame = host.bounds;
            [host bringSubviewToFront:effect];
            effect.keyFrames = RKKeyboardKeyFrames(host);
            objc_setAssociatedObject(host, &RKOverlayBoundsKey,
                [NSValue valueWithCGRect:host.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [effect showRippleAtPoint:[touch locationInView:effect] sourceView:touch.view];
    }
}
%end
