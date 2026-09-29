#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
#import "RKBlackKeyboard.h"
#import "RKAdaptivePerformance.h"
#import "RKPreferences.h"
static char RKOverlayKey;
static char RKOverlayBoundsKey;
static char RKPendingPressKey;
static char RKGeometryTimeKey;

#pragma mark - 装饰总闸（进程级缓存，按键路径只付一次内存读）

// 「启用键盘光效 / 波动扩散 / 原生键盘 / 微信输入法」任一关闭 ⇒ 装饰链路必须零开销：
// 不派发按键任务、不做布局变更检测、不做全量键位扫描（0.2s 节流）、不构造遮罩图层。
// 此前这些工作全部发生在 showRippleAtPoint: 的开关判定**之前**，于是关掉开关每次按键
// 仍要白扫一遍几何并建一层 CAShapeLayer —— 这里把闸提到派发之前。
// 取值为进程级缓存：只在 %ctor / 键盘弹出 / 偏好变更通知时刷新，稳态下按键路径只读一个
// static BOOL（RKDecorationEnabledFlag），不碰偏好字典、不加锁。
static BOOL RKDecorationEnabledFlag;
static BOOL RKDecorationFlagPrimed;

static void RKDecorationRefresh(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    id ripple = prefs[@"RippleEnabled"];
    id layout = prefs[RKKeyboardBundleIsWeType() ? @"WeChatKeyboard" : @"NativeKeyboard"];
    // 与 RainbowEffectView -flag: 同语义：键缺失视为开。
    RKDecorationEnabledFlag = (!enabled || [enabled boolValue])
        && (!ripple || [ripple boolValue])
        && (!layout || [layout boolValue]);
    RKDecorationFlagPrimed = YES;
}

static inline BOOL RKDecorationEnabled(void) {
    // 标志未就绪（进程内第一个触摸事件早于通知）时惰性取一次，之后恒为内存读。
    if (!RKDecorationFlagPrimed) RKDecorationRefresh();
    return RKDecorationEnabledFlag;
}

static void RKDecorationPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                           CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ RKDecorationRefresh(); });
}
@interface RKPendingPress : NSObject
@property(nonatomic) CGPoint point;
@property(nonatomic) CFTimeInterval time, lastRendered;
@property(nonatomic, weak) UIView *source;
@property(nonatomic) BOOL queued;
@end
@implementation RKPendingPress
@end
static void RKClearEffectLayers(RainbowEffectView *effect) {
    for (CALayer *layer in effect.layer.sublayers.copy) {
        [layer removeAllAnimations];
        [layer removeFromSuperlayer];
    }
}

static void RKCollectExclusions(UIView *node, UIView *host, UIBezierPath *path, NSUInteger depth) {
    if (depth > 8) return;
    for (UIView *v in node.subviews) {
        if ([v isKindOfClass:RainbowEffectView.class] || v.hidden || v.alpha < .01) continue;
        if (RKKeyboardExcludedView(v)) {
            CGRect r = CGRectIntersection(host.bounds, [v convertRect:v.bounds toView:host]);
            if (!CGRectIsNull(r) && !CGRectIsEmpty(r)) [path appendPath:[UIBezierPath bezierPathWithRect:r]];
        } else RKCollectExclusions(v, host, path, depth + 1);
    }
}
%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    // 判定按「最廉价且能挡掉最多事件」排序：sendEvent: 是进程内所有事件的唯一入口，
    // 非触摸事件（滚动/遥控/硬件按键）在数量上占多数，先用一次属性读把它们挡掉，
    // 再付进程守卫那次跨编译单元函数调用。两个判断都是 return，交换后语义完全等价。
    if (event.type != UIEventTypeTouches) return;
    // 进程守卫：系统 UI 进程（SpringBoard / backboardd）不参与任何装饰，直接放行。
    if (RKKeyboardProcessIsSystemUI()) return;
    if (!RKKeyboardSessionActive()) {
        // 自愈兜底：触摸能解析出键盘宿主 = 键盘真实在场（通知可能未达），
        // 直接激活会话，保证装饰不依赖通知时序。
        BOOL keyboardTouch = NO;
        for (UITouch *touch in event.allTouches) {
            if (touch.phase != UITouchPhaseBegan) continue;
            if (RKKeyboardEffectHost(touch.view)) { keyboardTouch = YES; break; }
        }
        if (!keyboardTouch) return;
        RKKeyboardSessionSetActive(YES);
    }
    // 装饰总闸：四个功能开关任一关闭即在此止步 —— 不派发按键任务、不碰几何与图层。
    // 上面的会话自愈刻意保留：候选栏渐变独立依赖 RKKeyboardSessionActive()，
    // 不能因为主光效关闭而让会话判定失效。
    if (!RKDecorationEnabled()) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseBegan) continue;
        UIView *host = RKKeyboardEffectHost(touch.view);
        if (!host || !host.window) continue;
        CGPoint point = [touch locationInView:host];
        if (!CGRectContainsPoint(host.bounds, point)) continue;
        RKAdaptiveNoteInput();
        RKPendingPress *pending = objc_getAssociatedObject(host, &RKPendingPressKey);
        if (!pending) {
            pending = [RKPendingPress new];
            objc_setAssociatedObject(host, &RKPendingPressKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        pending.point = point;
        pending.time = CACurrentMediaTime();
        pending.source = touch.view;
        // Coalesce decoration only. Every original input event was already delivered.
        if (pending.queued) continue;
        pending.queued = YES;
        __weak UIView *weakHost = host;
        // Let UIKit finish delivering the touch before building the visual effect.
        // The input event is therefore not held behind path/layer construction.
        dispatch_async(dispatch_get_main_queue(), ^{
            pending.queued = NO;
            UIView *liveHost = weakHost;
            CFTimeInterval now = CACurrentMediaTime();
            if (!liveHost || !liveHost.window || liveHost.hidden || now - pending.time > .080) return;
            // 二道闸：派发与执行之间用户可能刚从设置页关掉开关（Darwin 通知已刷新缓存）。
            // 放在几何工作之前，避免「这一拍仍然白扫一遍键位」。
            if (!RKDecorationEnabled()) return;
            // Throttle decoration before geometry scanning, never UIKit input.
            if ((RKAdaptiveFastInput() || RKAdaptiveLevel() >= 2) && now - pending.lastRendered < .10) return;
            CGPoint touchPoint = pending.point;
            UIView *sourceView = pending.source;
            RainbowEffectView *effect = objc_getAssociatedObject(liveHost, &RKOverlayKey);
            if (!effect) {
                effect = [[RainbowEffectView alloc] initWithFrame:liveHost.bounds];
                objc_setAssociatedObject(liveHost, &RKOverlayKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [liveHost addSubview:effect];
                RKApplyBlackKeyboardHost(liveHost);
            }
            NSValue *oldBoundsValue = objc_getAssociatedObject(liveHost, &RKOverlayBoundsKey);
            BOOL geometryChanged = !oldBoundsValue ||
                !CGRectEqualToRect(oldBoundsValue.CGRectValue, liveHost.bounds);

            // Identity alone misses in-place keyplane changes and view-based keyboards.
            // Always observe identity, and periodically revalidate real key rectangles.
            BOOL layoutChanged = RKKeyboardLayoutChanged(liveHost);
            CFTimeInterval lastScan = [objc_getAssociatedObject(liveHost, &RKGeometryTimeKey) doubleValue];
            BOOL scan = geometryChanged || layoutChanged || !effect.keyFrames.count || now - lastScan >= .2;
            NSArray<NSValue *> *liveKeyFrames = scan ? RKKeyboardKeyFrames(liveHost) : effect.keyFrames;
            if (scan) objc_setAssociatedObject(liveHost, &RKGeometryTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            BOOL keyGeometryChanged = ![effect.keyFrames isEqualToArray:liveKeyFrames];
            if (geometryChanged || keyGeometryChanged) {
                RKClearEffectLayers(effect);
                effect.frame = liveHost.bounds;
                [liveHost bringSubviewToFront:effect];
                {
                    UIBezierPath *visible = [UIBezierPath bezierPathWithRect:effect.bounds];
                    RKCollectExclusions(liveHost, liveHost, visible, 0);
                    CAShapeLayer *mask = [CAShapeLayer layer];
                    mask.frame = effect.bounds;
                    mask.path = visible.CGPath;
                    mask.fillRule = kCAFillRuleEvenOdd;
                    effect.layer.mask = mask;
                }
                effect.keyFrames = liveKeyFrames;
                objc_setAssociatedObject(liveHost, &RKOverlayBoundsKey,
                    [NSValue valueWithCGRect:liveHost.bounds], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            CGPoint effectPoint = [liveHost convertPoint:touchPoint toView:effect];
            if (CACurrentMediaTime() - pending.time > .080) return;
            pending.lastRendered = CACurrentMediaTime();
            [effect showRippleAtPoint:effectPoint sourceView:sourceView];
        });
    }
}
%end

// 兜底：键盘视图挂上/离开 window 即键盘真实在场/离场信号。
// 不依赖 UIKeyboardWillShow 通知（通知可能因时序/形态未达），
// 直接由键盘视图生命周期驱动会话开关，确保装饰钩子不被错误短路。
%hook UIKeyboardLayoutStar
- (void)didMoveToWindow {
    %orig;
    if (RKKeyboardProcessIsSystemUI()) return;
    // UIKeyboardLayoutStar 仅有前置声明（@class），编译器不知道其继承 UIView，
    // 显式转 UIView 才能访问 window 属性；运行时类型安全（本类即 UIView 子类）。
    RKKeyboardSessionSetActive([(UIView *)self window] != nil);
}
%end

%ctor {
    @autoreleasepool {
        // 系统 UI 进程不参与装饰（见 RKKeyboardProcessIsSystemUI），连总闸都不必维护。
        if (RKKeyboardProcessIsSystemUI()) return;
        RKDecorationRefresh();
        // block observer 的 token 必须持有，否则 ARC 下立即释放导致通知静默失效。
        static id decorationObserverTokens[2];
        decorationObserverTokens[0] = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIKeyboardDidShowNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            RKDecorationRefresh();
        }];
        decorationObserverTokens[1] = [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            RKDecorationRefresh();
        }];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RKDecorationPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
