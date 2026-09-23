#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
// The overlay host is the key area itself (WBKeyboardView / UIKeyboardLayoutStar), so there
// is no candidate bar or toolbar inside it to carve out: the recursive exclusion-mask pass
// that used to run here is gone.
//
// Nothing about the layout-switch fix runs before %orig. The three keys that swap the whole
// key set (中英 / 123 / #+=) are recognised by class, and only touches inside the bottom
// function row are ever examined, so an ordinary keystroke walks the same path it always did
// plus one rectangle test.
//
// Those three keys are the only WBKeyView subclass left once the typing keys are accounted
// for: WBKeyView's other subclasses are WBNewlineKeyView, WBReturnKeyView and WBRuleKeyView.
// Recognising them by class is therefore exact, and the name is resolved once. The class is
// absent from the native keyboard process, where this test simply never matches.
static BOOL RKIsSwitchKeyTouch(UITouch *touch) {
    static Class switchKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ switchKey = NSClassFromString(@"WBSecKeyboardKeyView"); });
    if (!switchKey) return NO;
    // The touch can land on a subview of the keycap rather than on the keycap itself.
    UIView *view = touch.view;
    for (int level = 0; level < 3 && view; level++, view = view.superview) {
        if ([view isKindOfClass:switchKey]) return YES;
    }
    return NO;
}
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
        RainbowEffectView *effect = RKKeyboardEffectOverlay(host);
        if ([effect updateKeyFramesForHost:host]) {
            // A fresh layout can sit above the overlay; put it back on top. Kept as a
            // safety net -- the overlay's zPosition already holds it above any keycap
            // installed later.
            [host bringSubviewToFront:effect];
        }
        CGPoint local = [touch locationInView:effect];
        // The switch keys sit in the bottom function row and nowhere else, so every letter
        // key is ruled out by a single rectangle test: no class lookup, no call, no store.
        if ([effect pointIsInFunctionRow:local] && RKIsSwitchKeyTouch(touch)) {
            // Their light belongs to the layout they switch to, so nothing is drawn on the
            // layout they are leaving. The host's layout hook draws it once the new key set
            // is in place.
            [effect armSwitchKeyPulseAtPoint:local];
            continue;
        }
        [effect showRippleAtPoint:local sourceView:touch.view];
    }
}
%end
