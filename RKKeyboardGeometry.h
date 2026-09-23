#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSArray<NSValue *> *RKKeyboardKeyFrames(UIView *host);
FOUNDATION_EXPORT UIBezierPath *RKKeyboardKeyFacePath(CGRect keyFrame);
FOUNDATION_EXPORT UIView *RKKeyboardEffectHost(UIView *view);
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
// tell that the key set changed. The layout stamp is bumped by exactly two events --
// the host's bounds changing, and a keycap registering that the registry had not seen
// before (installing a different key set creates new keycaps) -- while the registered
// keycap count moves whenever a different key set is installed. Both reads are O(1)
// with no allocation, so callers can validate the cached key-frame array on every
// keystroke without re-collecting it.
//
// Note the stamp is deliberately *not* bumped by an arbitrary host layout pass: a
// relayout that moves nothing must not force the key-frame table to be rebuilt on the
// next keystroke. If a key set ever changes without either signal, that is the
// nine-key <-> full-layout failure of 17.9 coming back, and it looks like the ripple
// spreading from the retired layout's key centres (or being hidden by the new keycaps,
// because the table is also what re-raises the overlay).
FOUNDATION_EXPORT uint64_t RKKeyboardLayoutStamp(void);
FOUNDATION_EXPORT NSUInteger RKRegisteredKeyCount(void);
