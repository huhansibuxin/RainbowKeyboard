#import <UIKit/UIKit.h>
#import "RKBlackKeyboard.h"

// 纯黑键帽引擎（PureBlackKeyboard.xm / RKBlackBitmap / RKBlackProbe）已按老板要求
// 从包内移除（不使用该功能）。上游 1.2.1 的 Tweak.xm 在创建光效覆盖层时会调用
// 这个入口，所以这里保留一个同名空实现：上游的 Tweak.xm / RainbowEffectView.m
// 因此可以逐字不改地使用，不会被我们的裁剪影响。
void RKApplyBlackKeyboardHost(UIView *host) {
    (void)host;
}
