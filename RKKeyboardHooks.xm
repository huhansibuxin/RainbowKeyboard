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
// native keyboard, WeType and every other injected process alike.

// ---------------------------------------------------------------------------
// Keyboard host: the key area only (candidate bar and toolbars are separate views).
// ---------------------------------------------------------------------------
%hook WBKeyboardView                 // WeType: key panel container
- (void)layoutSubviews {
    %orig;
    RKRegisterKeyboardHost(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterKeyboardHost(self);
}
%end

%hook UIKeyboardLayoutStar           // Native keyboard: key area
- (void)layoutSubviews {
    %orig;
    RKRegisterKeyboardHost(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterKeyboardHost(self);
}
%end

// ---------------------------------------------------------------------------
// Keycaps. Registered on layout so a tweak loaded after the keyboard already
// exists still discovers them on the next layout pass.
// ---------------------------------------------------------------------------
%hook WBKeyView                      // WeType keycap (also inherited by WBNewlineKeyView,
- (void)layoutSubviews {             // WBReturnKeyView, WBSecKeyboardKeyView, WBRuleKeyView)
    %orig;
    RKRegisterKeyView(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterKeyView(self);
}
%end

%hook UIKBKeyView                    // Native keycap
- (void)layoutSubviews {
    %orig;
    RKRegisterKeyView(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterKeyView(self);
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
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end

%hook WBCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end

%hook WBSplitCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end

%hook TUICandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end

%hook TUIPredictionViewCell
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end

%hook TUIPredictionView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end

%hook UIKBCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end

%hook UIKeyboardCandidateView
- (void)layoutSubviews {
    %orig;
    RKRegisterCandidateContainer(self);
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) RKRegisterCandidateContainer(self);
}
%end
