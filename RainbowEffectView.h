#import <UIKit/UIKit.h>
@interface RainbowEffectView : UIView
@property(nonatomic,copy) NSArray<NSValue *> *keyFrames;
// 2.3.30：触摸刚发生时由 Tweak.xm 算好并存进来的「微信命中」矩形（宿主坐标系）。
// 与落点同基准（effect 铺满宿主），CGRectNull 表示微信也没认出来。
@property(nonatomic) CGRect touchKeyRect;
- (void)reloadConfiguration;
- (void)showRippleAtPoint:(CGPoint)point;
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView;
@end
// 2.3.29 临时诊断入口（验完随下一版删除）：加载时在容器 tmp 落一条标记，
// 用于区分「没走到诊断分支」与「写盘通道不可用」。
// 下面两个 C 函数会被 Logos 的 .xm（按 Objective-C++ 编译）调用，必须用 FOUNDATION_EXPORT
// 声明 —— 它在本文件被 C++ 预处理时展开为 extern "C"；否则调用侧会去找 mangled 名，
// 而定义在 .m 里是纯 C 符号，链接直接失败（2.3.29 首次 CI 正是栽在这里）。
FOUNDATION_EXPORT void RKHitLogMarkLoaded(void);
// 2.3.30：在触摸刚发生时（touch.view 一定有效）把「微信命中」算成矩形值类型。
// 沿 touch.view 的祖先链取最近的「尺寸像一块键」的视图；撞到「占满整行」的键行容器时，
// 改为在该容器子树里找包含落点的最小视图。都不成立返回 CGRectNull。
FOUNDATION_EXPORT CGRect RKKeyRectForTouchView(UIView *sourceView, UIView *host, CGPoint point);
