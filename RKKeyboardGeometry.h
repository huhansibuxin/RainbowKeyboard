#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSArray<NSValue *> *RKKeyboardKeyFrames(UIView *host);
FOUNDATION_EXPORT UIBezierPath *RKKeyboardKeyFacePath(CGRect keyFrame);
FOUNDATION_EXPORT UIView *RKKeyboardEffectHost(UIView *view);

// The view the effect should be attached to, and the rect it should occupy inside that
// view. Normally this is the key area itself (the host, at host.bounds). When a candidate
// bar is on screen and sits directly above the key area, the two share an ancestor, and
// the effect is attached there instead with a frame covering both -- so the ambient glow
// reaches the candidate row, which is where the eye is while typing, rather than stopping
// at the top edge of the key area. Anything that does not read as that bar (wrong side,
// wrong width, an implausible size, a different window) leaves the pair untouched.
FOUNDATION_EXPORT UIView *RKKeyboardOverlayHost(UIView *host, CGRect *outFrame);
FOUNDATION_EXPORT UIView *RKKeyboardKeyViewAtFrame(UIView *host, CGRect keyFrame);

// Runtime registries. Exact-class hooks (RKKeyboardHooks.xm) register the live
// keyboard host, keycaps and candidate containers once per instance, so the input
// and draw paths can look them up directly instead of recursing the view tree or
// walking the superview chain on every keystroke / every draw.
FOUNDATION_EXPORT void RKRegisterKeyboardHost(UIView *host);
FOUNDATION_EXPORT void RKRegisterKeyView(UIView *keyView);
FOUNDATION_EXPORT void RKRegisterCandidateContainer(UIView *container);
FOUNDATION_EXPORT BOOL RKIsInCandidateContainer(UIView *view);

// Cheap fingerprint of the *current* key layout. A keyboard host keeps the same
// bounds when it swaps between nine-key and full layouts, so bounds alone cannot
// tell that the key set changed. The layout stamp is therefore bumped by the host
// hook on every layout pass, and the registered keycap count moves whenever a
// different key set is installed. Both reads are O(1) with no allocation, so callers
// can validate the cached key-frame array on every keystroke without re-collecting it.
//
// Do not narrow the stamp to "bounds changed or an unseen keycap registered". 1.2.0 tried
// that and it reproduced the 17.9 failure on the WeType keyboard: both key sets' keycaps
// stay registered across a switch, so returning to the nine-key layout registers nothing
// new and leaves the count unchanged -- both narrowed signals hold still while the keys
// change, and the ripple keeps the retired layout's geometry (nine-key -> English -> back
// to nine-key). The stamp must stay unconditional; the gate is what keeps typing cheap.
FOUNDATION_EXPORT uint64_t RKKeyboardLayoutStamp(void);
FOUNDATION_EXPORT NSUInteger RKRegisteredKeyCount(void);
