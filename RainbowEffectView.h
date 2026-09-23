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
- (void)reloadConfiguration;
- (void)showRippleAtPoint:(CGPoint)point;
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView;
@end
