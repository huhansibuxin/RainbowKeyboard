#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
static char RKOverlayKey;
static char RKOverlayBoundsKey;
static char RKPendingPressKey;
static char RKGeometryTimeKey;
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
    if (event.type != UIEventTypeTouches) return;
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
    for (UITouch *touch in event.allTouches) {
        if (touch.phase != UITouchPhaseBegan) continue;
        UIView *host = RKKeyboardEffectHost(touch.view);
        if (!host || !host.window) continue;
        CGPoint point = [touch locationInView:host];
        if (!CGRectContainsPoint(host.bounds, point)) continue;
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
            CGPoint touchPoint = pending.point;
            UIView *sourceView = pending.source;
            RainbowEffectView *effect = objc_getAssociatedObject(liveHost, &RKOverlayKey);
            if (!effect) {
                effect = [[RainbowEffectView alloc] initWithFrame:liveHost.bounds];
                objc_setAssociatedObject(liveHost, &RKOverlayKey, effect, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [liveHost addSubview:effect];
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
    // UIKeyboardLayoutStar 仅有前置声明（@class），编译器不知道其继承 UIView，
    // 显式转 UIView 才能访问 window 属性；运行时类型安全（本类即 UIView 子类）。
    RKKeyboardSessionSetActive([(UIView *)self window] != nil);
}
%end
