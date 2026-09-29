// RKVoiceToolbarWiden.xm — 微信输入法(WeType) 工具栏「语音按钮」横向加宽
//
// 目标：只把工具栏上的语音按钮加宽到「最近使用」胶囊那种长度（≈3 个方钮宽），
//       其余按钮尺寸/外观不变、不消失。
//
// == 为什么只能 hook ==
// wxkb_plugin 里 WBFunctionToolBar / WBToolBarButton 都没有任何宽度属性
// （全量 1830 类 ivar 反查确认），配置键也只有「显示什么/几个」的语义，
// 宽度是 -sizeThatFits: 内部现算出来的局部值，不落盘、没有 setter。
//
// == 实测到的原生布局规律（2.3.4 诊断日志 + 用户截图逐像素测量）==
// 1) 工具栏宽度 = 各按钮宽度打包 + 间距 + 左右各 12pt 内边距，右边缘钉在屏幕右侧：
//      5 项(34pt×5, gap 12)              -> 242.0
//      6 项(多一个 func=28 宽胶囊 91.33) -> 345.33 （差 103.33 = 12 + 91.33）
//    => 工具栏宽度由「各按钮 sizeThatFits 之和」决定，父视图会为宽按钮把
//       工具栏整体向左扩（拿候选栏的空间），这正是「最近使用」胶囊能变宽的原因。
// 2) 2.3.4 里本插件改过按钮 frame（把某个按钮推到 12pt、另一个推到 46pt），
//    但工具栏宽度始终只有 242 / 345.33 两种 —— 证明工具栏尺寸**不读 frame**，
//    只读各按钮的 sizeThatFits。所以改 frame 只会把按钮挤出可视区（就是上一版
//    「右边 3 个按钮消失」的原因）。正确做法是改 sizeThatFits。
// 3) 用户截图逐像素量：方钮直径 102px、间距 138px、胶囊 310px，1pt = 3px，
//    即胶囊 = 方钮的 3.04 倍 => 目标宽 = 3 × 方钮宽 = 102pt，与胶囊等长。
//
// == 做法 ==
// 只 hook WBToolBarButton 的 -sizeThatFits:，让语音按钮多报 2 个方钮宽。
// 微信自己的链路会完成剩下的事：工具栏 width 随之变大 -> 父视图把工具栏向左扩
// -> -layoutForAnimated: 按新宽度排布所有按钮。全程不碰别人的 frame，
// 因此不可能出现按钮被挤出可视区的情况。
//
// == 语音按钮的识别 ==
// 主：func == 1（实测工具栏顺序 (28,1,23,8,7,5) 与用户截图的
//     「最近使用胶囊 -> 麦克风 -> …」逐一对应，且 focusedFunc=1）。
// 备：按钮图标 == icon_bar_voice_24（指针 / imageAsset / PNG 字节比对），
//     命中后把 func 学进静态变量，之后只比 func，零额外开销。
// 兜底：都不中则原样返回（fail-safe：宁可不生效，也不乱动别的按钮）。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <math.h>
#import "RKPreferences.h"

@interface WBFunctionToolBar : UIView
- (void)layoutForAnimated:(uintptr_t)animated animateFinishedBlock:(uintptr_t)block;
@end

@interface WBToolBarButton : UIView
- (unsigned long long)func;
@end

#pragma mark - 诊断日志（PluginKit 扩展沙盒只能写自己容器内的目录）

static NSArray<NSString *> *RKVoiceLogPaths(void) {
    return @[[NSTemporaryDirectory() stringByAppendingPathComponent:@"rk_voicetoolbar.log"],
             [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/rk_voicetoolbar.log"]];
}

static void RKVoiceLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSData *data = [[NSString stringWithFormat:@"%.3f %@\n", CFAbsoluteTimeGetCurrent(), message]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *path in RKVoiceLogPaths()) {
        if (![manager fileExistsAtPath:path.stringByDeletingLastPathComponent]) continue;
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
        if ([attributes fileSize] > 256 * 1024) [manager removeItemAtPath:path error:NULL];
        if (![manager fileExistsAtPath:path]) {
            if ([data writeToFile:path atomically:YES]) return;
            continue;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!handle) continue;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
        } @catch (__unused NSException *exception) {
            [handle closeFile];
            continue;
        }
        [handle closeFile];
        return;
    }
}

#pragma mark - 开关

// 缺省即开：键盘扩展沙盒读不到偏好文件时，固化表(RKPresetSelfUseTable)
// 会把 WidenVoiceButton 兜底成 1，所以任何情况下默认都是打开状态。
static BOOL RKVoiceWidenEnabled(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id value = prefs[@"WidenVoiceButton"];
    return value ? [value boolValue] : YES;
}

#pragma mark - 语音按钮识别

// 实测：function 枚举 1 = 语音（麦克风）。命中一次后记下来，之后只比 func。
static unsigned long long RKVoiceLearnedFunc = 0;
static BOOL RKVoiceFuncKnown = NO;
static __weak UIView *RKVoiceCachedButton = nil;
static CGFloat RKVoiceUnitSeen = 0;     // 已知的一个「方钮宽」
static char RKVoiceSizedKey;            // 每个按钮只记一次日志

static unsigned long long RKFuncOf(UIView *button) {
    if (![button respondsToSelector:@selector(func)]) return 0;
    return [(WBToolBarButton *)button func];
}

static void RKVoiceLearn(UIView *button, NSString *rule) {
    RKVoiceLearnedFunc = RKFuncOf(button);
    RKVoiceFuncKnown = YES;
    RKVoiceCachedButton = button;
    RKVoiceLog(@"识别到语音按钮: %@ func=%llu", rule, RKVoiceLearnedFunc);
}

// 图标比对：优先指针，再 imageAsset 名，最后 PNG 字节。命中一次即缓存 func。
static BOOL RKButtonIconIsVoice(UIView *button) {
    UIImage *reference = [UIImage imageNamed:@"icon_bar_voice_24"];
    if (!reference) return NO;

    UIImage *image = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:button];
    while (stack.count && !image) {
        UIView *node = stack.lastObject;
        [stack removeLastObject];
        if ([node isKindOfClass:UIImageView.class] && ((UIImageView *)node).image) {
            image = ((UIImageView *)node).image;
            break;
        }
        if ([node isKindOfClass:UIButton.class] && ((UIButton *)node).currentImage) {
            image = ((UIButton *)node).currentImage;
            break;
        }
        [stack addObjectsFromArray:node.subviews];
    }
    if (!image) return NO;
    if (image == reference) return YES;

    NSString *name = image.imageAsset.assetName;
    if ([name isKindOfClass:NSString.class] && [name containsString:@"voice"]) return YES;

    if (CGSizeEqualToSize(image.size, reference.size)) {
        NSData *a = UIImagePNGRepresentation(image);
        NSData *b = UIImagePNGRepresentation(reference);
        if (a && b && [a isEqualToData:b]) return YES;
    }
    return NO;
}

// 单个按钮判定：先缓存，再已知 func，再图标，最后实测枚举 1。
static BOOL RKVoiceIsVoiceButton(UIView *button) {
    if (RKVoiceCachedButton == button) return YES;
    if (RKVoiceFuncKnown) return RKFuncOf(button) == RKVoiceLearnedFunc;
    if (RKButtonIconIsVoice(button)) { RKVoiceLearn(button, @"图标匹配"); return YES; }
    if (RKFuncOf(button) == 1) { RKVoiceLearn(button, @"兜底"); return YES; }
    return NO;
}

#pragma mark - 按钮收集

// 递归收集工具栏按钮（含承载按钮的 UIScrollView 内的），类名含 ToolBarButton。
static NSArray<UIView *> *RKVoiceButtonsIn(UIView *root) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *node = stack.lastObject;
        [stack removeLastObject];
        for (UIView *sub in node.subviews) {
            NSString *name = NSStringFromClass(sub.class);
            if ([name containsString:@"ToolBarButton"] || [name containsString:@"ToolbarButton"])
                [buttons addObject:sub];
            else
                [stack addObject:sub];
        }
    }
    return buttons;
}

#pragma mark - 目标宽度
//
// 方钮是正方形，所以「一个格」的宽度 = 它的高（也是它的自然宽）。
// 目标 = 3 格 = 3 × 34 = 102pt，与「最近使用」胶囊(实测 103.33pt)等长。

static CGFloat RKVoiceTargetFromUnit(CGFloat unit) {
    if (unit < 18 || unit > 80) unit = RKVoiceUnitSeen > 0 ? RKVoiceUnitSeen : 34;
    return 3 * unit;
}

#pragma mark - Hooks

%group RKVoiceButtonSizeGroup
%hook WBToolBarButton

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize natural = %orig;
    if (natural.width < 18 || natural.width > 80) return natural;   // 只处理方钮
    if (!RKVoiceWidenEnabled()) return natural;
    if (!RKVoiceIsVoiceButton(self)) return natural;

    RKVoiceUnitSeen = natural.width;
    CGFloat target = RKVoiceTargetFromUnit(natural.width);
    if (target <= natural.width + 0.5) return natural;

    if (!objc_getAssociatedObject(self, &RKVoiceSizedKey)) {
        objc_setAssociatedObject(self, &RKVoiceSizedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RKVoiceLog(@"加宽语音按钮: 自然宽=%.1f -> 目标=%.1f (3 格) func=%llu",
            natural.width, target, RKFuncOf(self));
    }
    return CGSizeMake(target, natural.height);
}

%end
%end

// 兜底保险（正常情况下上面那条 hook 就让微信自己排好了，这里会直接幂等返回）：
// 万一微信的布局没采用按钮的 sizeThatFits 宽度，则布局后自行加宽并顺移同排右侧
// 按钮。此时工具栏已按 sizeThatFits 变宽，顺移后仍完整落在可视区内。
static char RKVoiceLayoutCountKey;
static char RKVoiceSafetyDoneKey;

static void RKVoiceSafetyLayout(WBFunctionToolBar *toolbar) {
    NSInteger count = [objc_getAssociatedObject(toolbar, &RKVoiceLayoutCountKey) integerValue] + 1;
    objc_setAssociatedObject(toolbar, &RKVoiceLayoutCountKey, @(count),
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (objc_getAssociatedObject(toolbar, &RKVoiceSafetyDoneKey)) return;
    if (!RKVoiceWidenEnabled()) return;

    NSArray<UIView *> *buttons = RKVoiceButtonsIn(toolbar);
    if (buttons.count < 2) return;

    UIView *voice = nil;
    for (UIView *button in buttons) {
        if (RKVoiceIsVoiceButton(button)) { voice = button; break; }
    }
    if (!voice) {
        if (count <= 3) RKVoiceLog(@"layout#%ld 未识别到语音按钮(buttons=%lu)，不改动",
            (long)count, (unsigned long)buttons.count);
        return;
    }

    CGFloat unit = CGRectGetHeight(voice.bounds);
    CGFloat target = RKVoiceTargetFromUnit(unit);
    CGFloat current = CGRectGetWidth(voice.bounds);
    if (current >= target - 1) {                 // 微信自己排好了 -> 收工
        objc_setAssociatedObject(toolbar, &RKVoiceSafetyDoneKey, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        RKVoiceLog(@"layout#%ld 微信已按 sizeThatFits 生效 宽=%.1f 工具栏宽=%.1f",
            (long)count, current, CGRectGetWidth(toolbar.bounds));
        return;
    }

    CGFloat delta = target - current;
    CGRect voiceOnBar = [voice.superview convertRect:voice.frame toView:toolbar];
    NSInteger moved = 0;
    for (UIView *button in buttons) {
        if (button == voice) continue;
        CGRect rect = [button.superview convertRect:button.frame toView:toolbar];
        if (rect.origin.x <= voiceOnBar.origin.x + 0.5) continue;   // 只动右侧
        CGRect frame = button.frame;
        frame.origin.x += delta;
        button.frame = frame;
        moved++;
    }
    CGRect frame = voice.frame;
    frame.size.width = target;
    voice.frame = frame;

    if ([voice.superview isKindOfClass:UIScrollView.class]) {
        UIScrollView *scroll = (UIScrollView *)voice.superview;
        CGFloat need = 0;
        for (UIView *button in buttons)
            if (button.superview == scroll) need = MAX(need, CGRectGetMaxX(button.frame));
        if (need > 0 && scroll.contentSize.width < need + 12)
            scroll.contentSize = CGSizeMake(need + 12, scroll.contentSize.height);
    }

    objc_setAssociatedObject(toolbar, &RKVoiceSafetyDoneKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    RKVoiceLog(@"layout#%ld 兜底加宽 方钮=%.1f 目标=%.1f 顺移=%.1f 个=%ld 工具栏宽=%.1f",
        (long)count, unit, target, delta, (long)moved, CGRectGetWidth(toolbar.bounds));
}

%group RKVoiceLayoutGroup
%hook WBFunctionToolBar

- (void)layoutSubviews {
    %orig;
    RKVoiceSafetyLayout(self);
}

%end
%end

// 工具栏真正的主布局入口是 -layoutForAnimated:animateFinishedBlock:，
// 通常由 layoutSubviews 内部调用（此路径已被上面的钩子覆盖），但也可能被
// 持有者直接调用，故一并下钩。参数按 uintptr_t 声明 = 位级原样透传，
// 不解释参数类型，避免签名推断错误带来的风险。
%group RKVoiceAnimatedGroup
%hook WBFunctionToolBar

- (void)layoutForAnimated:(uintptr_t)animated animateFinishedBlock:(uintptr_t)block {
    %orig;
    RKVoiceSafetyLayout(self);
}

%end
%end

%ctor {
    // 只在微信输入法扩展里生效；注入到系统键盘(InputUI)时该类不存在，直接跳过。
    Class toolbarClass = (Class)objc_getClass("WBFunctionToolBar");
    if (!toolbarClass) return;
    // 仅在原方法确实存在时才下钩：否则 %orig 会落到空 IMP 上。
    if (class_getInstanceMethod(toolbarClass, @selector(layoutForAnimated:animateFinishedBlock:))) {
        %init(RKVoiceAnimatedGroup);
    }
    if (objc_getClass("WBToolBarButton")) {
        %init(RKVoiceButtonSizeGroup);
    }
    %init(RKVoiceLayoutGroup);
}
