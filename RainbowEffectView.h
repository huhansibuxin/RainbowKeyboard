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
//
// For the same reason the stamp must not be bumped by an arbitrary host layout pass:
// invalidating on a relayout that moved nothing would make the next keystroke re-collect
// every key for no reason. If a key set ever does change without moving either the stamp
// or the count, the symptom is the 17.9 failure returning -- see RKKeyboardLayoutStamp().
- (BOOL)updateKeyFramesForHost:(UIView *)host;
// Re-resolves everything the drawing path needs into flat storage. Called when the
// settings-changed notification arrives, and at most once a second as the fallback for a
// notification missed while this keyboard extension was suspended -- it is no longer
// called once per keystroke.
- (void)reloadConfiguration;
- (void)showRippleAtPoint:(CGPoint)point;
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView;
@end
