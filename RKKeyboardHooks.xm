#import <UIKit/UIKit.h>
#import "RKKeyboardGeometry.h"

// Exact-class hooks that populate the runtime registries in RKKeyboardGeometry.m.
//
// These replace three recursive/ancestor-walking lookups that previously ran on the
// typing path and on every draw:
//   * RKKeyboardEffectHost      -> anchored on the registered keyboard host
//   * RKKeyboardKeyFrames       -> anchored on the registered keycaps (WeType)
//   * RKPressKeyView (recursive)-> RKKeyboardKeyViewAtFrame over registered keycaps
//   * candidate region tests    -> RKIsInCandidateContainer over registered containers
//
// Hooking a class that is absent from the current process is a no-op (Logos resolves
// it with objc_getClass and skips when nil), so this file is safe to load into the
// native keyboard and the WeType keyboard extension alike.
//
// %hook only sees each target as a forward class, so `self` is typed as that class and
// has neither the UIView properties nor a UIView* conversion. Casting once here keeps
// every hook body readable and type-correct.
#define RKViewSelf ((UIView *)self)

// ---------------------------------------------------------------------------
// Keyboard host: the key area only (candidate bar and toolbars are separate views).
// ---------------------------------------------------------------------------
%hook WBKeyboardView                 // WeType: key panel container
- (void)layoutSubviews {
    %orig;
    RKRegisterKeyboardHost(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterKeyboardHost(RKViewSelf);
}
%end

%hook UIKeyboardLayoutStar           // Native keyboard: key area
- (void)layoutSubviews {
    %orig;
    RKRegisterKeyboardHost(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterKeyboardHost(RKViewSelf);
}
%end

// ---------------------------------------------------------------------------
// Keycaps. Registered on layout so a tweak loaded after the keyboard already
// exists still discovers them on the next layout pass.
// ---------------------------------------------------------------------------
%hook WBKeyView                      // WeType keycap (also inherited by WBNewlineKeyView,
- (void)layoutSubviews {             // WBReturnKeyView, WBSecKeyboardKeyView, WBRuleKeyView)
    %orig;
    RKRegisterKeyView(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterKeyView(RKViewSelf);
}
%end

%hook UIKBKeyView                    // Native keycap
- (void)layoutSubviews {
    %orig;
    RKRegisterKeyView(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterKeyView(RKViewSelf);
}
%end

// ---------------------------------------------------------------------------
// Candidate containers. Only used to answer "is this label inside the candidate
// bar" for the native UILabel path; WeType labels are matched by their exact class
// (WBTextItemLabel) and need no container test at all.
// ---------------------------------------------------------------------------
%hook WBTopBar                       // WeType top bar (holds WBCandidateView)
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end

%hook WBCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end

%hook WBSplitCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end

%hook TUICandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end

%hook TUIPredictionViewCell
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end

%hook TUIPredictionView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end

%hook UIKBCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end

%hook UIKeyboardCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(RKViewSelf);
}
- (void)didMoveToWindow {
    %orig;
    if (RKViewSelf.window) RKRegisterCandidateContainer(RKViewSelf);
}
%end
