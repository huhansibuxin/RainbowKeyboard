#import <UIKit/UIKit.h>
@interface RainbowEffectView : UIView
@property(nonatomic,copy) NSArray<NSValue *> *keyFrames;
- (void)reloadConfiguration;
- (void)showRippleAtPoint:(CGPoint)point;
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView;
@end
// 2.3.29 临时诊断入口（验完随下一版删除）：加载时在容器 tmp 落一条标记，
// 用于区分「没走到诊断分支」与「写盘通道不可用」。
void RKHitLogMarkLoaded(void);
