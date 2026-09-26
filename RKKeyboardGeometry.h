#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSArray<NSValue *> *RKKeyboardKeyFrames(UIView *host);
FOUNDATION_EXPORT UIBezierPath *RKKeyboardKeyFacePath(CGRect keyFrame);
FOUNDATION_EXPORT UIView *RKKeyboardEffectHost(UIView *view);

// Where the effect should be attached, and the rect it should occupy there.
//
// WeType offers exactly two candidate hosts, and they are the two its own view tree already
// has: WBKeyboardView (the key panel alone) and WBMainInputView (the keyboard body, which
// holds both the top bar -- the candidate row with its buttons -- and the key panel). The
// body is registered by an exact-class hook like everything else in this file's registry, so
// choosing it costs a weak read and never a walk up the superview chain. With a body
// registered the overlay spans the whole keyboard, which is what lets the ambient glow reach
// the candidate row; with none -- the native keyboard -- it stays on the key area.
//
// The window, the hidden/alpha state and an implausible size ratio are all re-checked here,
// because the weak reference can briefly point at the outgoing body while a layout swap is
// still in flight.
FOUNDATION_EXPORT UIView *RKKeyboardOverlayHost(UIView *host, CGRect *outFrame);

// The keyboard body: the container holding both the candidate bar and the key panel
// (WBMainInputView on WeType). Registered from that class's layout pass, like the host.
FOUNDATION_EXPORT void RKRegisterKeyboardBody(UIView *body);
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
