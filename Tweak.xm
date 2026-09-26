#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
static char RKOverlayKey;
// The effect is rooted on the key area (WBKeyboardView / UIKeyboardLayoutStar) and, when a
// candidate bar is on screen above it, attached to whatever view the two share so its frame
// can cover both. There is still nothing to carve out: the overlay is transparent and takes
// no touches, so covering the bar costs it nothing.
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type != UIEventTypeTouches) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseBegan) continue;
        UIView *host = RKKeyboardEffectHost(touch.view);
        if (!host) continue;
        CGPoint point = [touch locationInView:host];
        // The touch still has to land on the key area. The overlay's frame reaches up over
        // the candidate bar, but a candidate tap is not a key press and must not light one.
        if (!CGRectContainsPoint(host.bounds, point)) continue;
        RainbowEffectView *effect = objc_getAssociatedObject(host, &RKOverlayKey);
        if (!effect) {
            // Attach the overlay wherever it has to span: the key area alone, unless a
            // candidate bar extends it upward.
            CGRect overlayFrame = host.bounds;
            UIView *owner = RKKeyboardOverlayHost(host, &overlayFrame) ?: host;
            effect = [[RainbowEffectView alloc] initWithFrame:overlayFrame];
            objc_setAssociatedObject(host, &RKOverlayKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [owner addSubview:effect];   // added last, so it starts on top
            [effect updateKeyFramesForHost:host];
        } else if ([effect updateKeyFramesForHost:host]) {
            // The key layout was replaced (nine-key <-> full layout and friends). The fresh
            // layout can sit above the overlay, so put it back on top -- of the view the
            // overlay actually lives in, which stops being the host once a bar is on screen.
            [effect.superview bringSubviewToFront:effect];
        }
        [effect showRippleAtPoint:[touch locationInView:effect] sourceView:touch.view];
    }
}
%end
