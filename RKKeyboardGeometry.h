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
