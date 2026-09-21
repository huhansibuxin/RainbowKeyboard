#import <UIKit/UIKit.h>
@interface RainbowEffectView : UIView
@property(nonatomic,copy) NSArray<NSValue *> *keyFrames;
- (void)reloadConfiguration;
- (void)showRippleAtPoint:(CGPoint)point;
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView;
@end
