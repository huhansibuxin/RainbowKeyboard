#import <UIKit/UIKit.h>
@interface RainbowEffectView : UIView
@property(nonatomic,copy) NSArray<NSValue *> *keyFrames;
// Re-collects keyFrames from host, but only when the key layout actually changed.
// Returns YES when it did (callers use that to bring the overlay back to the front,
// which a fresh layout can otherwise cover).
//
// Callers used to gate this on host.bounds alone, which silently failed on a
// nine-key <-> full-layout switch: the keyboard swaps the whole key set while its
// bounds stay identical, so the effect kept spreading from the retired key centres.
// The gate is now the layout stamp plus the registered keycap count (both O(1)).
- (BOOL)updateKeyFramesForHost:(UIView *)host;
// The bottom function row of the current key layout, in overlay coordinates. A switch key
// (中英 / 123 / #+=) always lives there and a letter key never does, so the touch path rules
// out every ordinary keystroke with one rectangle test and nothing else.
- (BOOL)pointIsInFunctionRow:(CGPoint)point;
// Remembers a switch key's press without drawing anything. Two stores, no allocation. The
// light belongs to the layout the key switches to, and RKKeyboardHostDidSwapKeySet draws it
// there once the new key set is in place.
- (void)armSwitchKeyPulseAtPoint:(CGPoint)point;
- (void)reloadConfiguration;
- (void)showRippleAtPoint:(CGPoint)point;
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView;
@end

// The light overlay belonging to one keyboard host, created on first use -- from the
// touch path, which is the only place that knows the user has actually typed on it. A
// keyboard nobody has touched never grows a view.
FOUNDATION_EXPORT RainbowEffectView *RKKeyboardEffectOverlay(UIView *host);

// Called from the keyboard host's layoutSubviews on every layout pass.
//
// This is the only place that can notice a 中英 / 123 / #+= switch. Those keys replace the
// whole key set while host.bounds stays identical, and the swap produces no touch of its
// own, so the touch path can neither see it nor keep up with it. The three switch keys are
// handled across both: the touch path drops the light they would have drawn on the layout
// they are leaving, and this hook draws one pulse on the new layout instead.
//
// The gate is the registered keycap count, which moves when the key set is swapped and
// stays put while typing -- so an ordinary keystroke costs two O(1) reads and returns.
FOUNDATION_EXPORT void RKKeyboardHostDidSwapKeySet(UIView *host);
