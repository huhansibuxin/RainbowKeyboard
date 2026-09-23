#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
// The overlay host is the key area itself (WBKeyboardView / UIKeyboardLayoutStar), so there
// is no candidate bar or toolbar inside it to carve out: the recursive exclusion-mask pass
// that used to run here is gone.
//
// Nothing about the layout-switch fix lives on this path. A switch driven by the 中英 / 123
// / #+= buttons is picked up by RKKeyboardHostDidSwapKeySet from the host's layoutSubviews,
// because it replaces the key set while producing no touch of its own. This hook turns a
// normal touch into a pulse exactly as it did before, and does no extra work while typing.
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    // Keycaps registered before the keyboard sees this touch. A 中英 / 123 / #+= press swaps
    // the whole key set inside %orig, so for those three the count has already moved by the
    // time we look again -- which is how the switch keys are recognised without naming any
    // class. Two O(1) reads per touch.
    NSUInteger keysBefore = RKRegisteredKeyCount();
    %orig;
    if (event.type != UIEventTypeTouches) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseBegan) continue;
        UIView *host = RKKeyboardEffectHost(touch.view);
        if (!host) continue;
        CGPoint point = [touch locationInView:host];
        if (!CGRectContainsPoint(host.bounds, point)) continue;
        RainbowEffectView *effect = RKKeyboardEffectOverlay(host);
        // Kept in case the swap for this touch lands a frame later instead of inside %orig;
        // only ever read back when the key set really did swap right after.
        [effect noteSwitchCandidateTouchAtPoint:[touch locationInView:effect]];
        // The three switch keys must not light up the layout they are leaving: their one
        // pulse belongs to the layout they switch to, and RKKeyboardHostDidSwapKeySet fires
        // it as soon as the new key set is in place.
        if (RKRegisteredKeyCount() != keysBefore) continue;
        if ([effect updateKeyFramesForHost:host]) {
            // A fresh layout can sit above the overlay; put it back on top. Kept as a
            // safety net -- the overlay's zPosition already holds it above any keycap
            // installed later.
            [host bringSubviewToFront:effect];
        }
        [effect showRippleAtPoint:[touch locationInView:effect] sourceView:touch.view];
    }
}
%end
