#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
static char RKOverlayKey;
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
            [host addSubview:effect];   // added last, so it starts on top
            [effect updateKeyFramesForHost:host];
        } else if ([effect updateKeyFramesForHost:host]) {
            // The key layout was replaced (nine-key <-> full layout and friends). The
            // fresh layout can sit above the overlay, so put it back on top.
            [host bringSubviewToFront:effect];
        }
        [effect showRippleAtPoint:[touch locationInView:effect] sourceView:touch.view];
    }
}
%end
