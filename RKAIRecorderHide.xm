// RKAIRecorderHide.xm — 移除微信输入法「AI 录音笔」入口（图标 + 胶囊标识）
//
// == 背景（2026-10-20） ==
// 用户 10-20 升级微信输入法后，点「点击说话」进入语音面板，左上角出现「AI 录音笔」胶囊。
//
// == 2.3.38 探针实测（关键纠正） ==
// 该胶囊**不是** WBVoiceRecorderIconView。语音面板视图树（2.3.38 rk_ai.log）：
//   <WBVoiceInputInteractionModernView: 430x286>
//     <WBButton: frame=(13.76, 18.65; 91, 28)>     ← 胶囊本体
//        <UIImageView: frame=(8, 4; 20, 20)>        ← 图标
//        <UIButtonLabel: text='AI 录音笔'>          ← 文字
//     <UILabel: text='轻触结束'>                    ← 右侧提示（保留）
//     <WBVoiceInputWaveformView: 145x36>            ← 波形（保留）
// WBVoiceRecorderIconView 是另一套东西（super=UIView，方法 initWithResourcePrefix: /
// setRecording: / refreshAppearance，内部是 Lottie），不是面板胶囊。
// ⚠️ 2.3.38 对它的 hook 已在 2.3.39 整段删除，不要再加回来。
//
// == 现行做法（2.3.39 / 2.3.40） ==
// 1) 在 WBVoiceInputInteractionModernView 的 didMoveToWindow + layoutSubviews 后，
//    找「子视图里有 UILabel 且文本含『录音笔』」的容器（实测是 91x28 的 WBButton），
//    整体 hidden + alpha 0 + 禁交互。不依赖 WBButton 类名，宽度 <260pt 防误伤。
// 2) 2.3.40：命中结果缓存到 panel 的 associated object（强引用，panel 持有子树，
//    无循环），后续布局 O(1) 直接写属性，不再每次递归 + 字符串匹配。
//    缓存对象被移出视图树（superview == nil）时自动回退重扫。
// 3) 调试日志受设置项 AIRecorderLog 控制，且受总开关 Enabled 制约：
//    Enabled 关 或 AIRecorderLog 关 ⇒ RKAILog 第一行就 return，不 fopen、不写盘。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "RKPreferences.h"

#pragma mark - 日志开关（受「启用键盘光效」总控）

static BOOL RKAILogEnabledFlag = NO;

static void RKAILogRefresh(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    RKAILogEnabledFlag = (!enabled || [enabled boolValue])
        && [prefs[@"AIRecorderLog"] boolValue];
}

static void RKAILogPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ RKAILogRefresh(); });
}

static NSString *RKAILogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"rk_ai.log"];
}

static void RKAILog(NSString *fmt, ...) {
    // 关闭时连字符串格式化都不做：这是 layoutSubviews 路径上唯一的额外开销。
    if (!RKAILogEnabledFlag) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *fp = fopen(RKAILogPath().UTF8String, "a");
    if (!fp) return;
    fprintf(fp, "%s\n", line.UTF8String);
    fclose(fp);
}

#pragma mark - 胶囊定位（缓存 + 回退重扫）

static const void *RKAICapsuleKey = &RKAICapsuleKey;
static NSInteger RKAICapsuleHitCount = 0;
static NSInteger RKAIPanelDumpCount = 0;

// 只在缓存失效时走这里：深度 <=4，实测胶囊是 panel 的直接子视图。
static UIView *RKAIFindCapsule(UIView *node, int depth) {
    if (depth > 4) return nil;
    for (UIView *v in node.subviews) {
        for (UIView *s in v.subviews) {
            if ([s isKindOfClass:[UILabel class]] &&
                [((UILabel *)s).text containsString:@"录音笔"]) {
                // 宽度上限排除整块容器，避免误伤；胶囊实测 91pt。
                return v.bounds.size.width < 260 ? v : nil;
            }
        }
        UIView *found = RKAIFindCapsule(v, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void RKAIHideCapsule(UIView *panel) {
    UIView *capsule = objc_getAssociatedObject(panel, RKAICapsuleKey);
    if (!capsule || !capsule.superview) {
        capsule = RKAIFindCapsule(panel, 0);
        if (!capsule) return;
        // 强引用：panel 是语音面板根视图，生命周期覆盖胶囊；胶囊不反向持有 panel。
        objc_setAssociatedObject(panel, RKAICapsuleKey, capsule, OBJC_ASSOCIATION_RETAIN);
        if (RKAICapsuleHitCount < 5) {
            RKAICapsuleHitCount++;
            RKAILog(@"[capsule] hidden %@ frame=%@",
                    NSStringFromClass(capsule.class), NSStringFromCGRect(capsule.frame));
        }
    }
    capsule.hidden = YES;
    capsule.alpha = 0.0;
    capsule.userInteractionEnabled = NO;
}

%hook WBVoiceInputInteractionModernView

- (void)layoutSubviews {
    %orig;
    UIView *panel = (UIView *)self;
    if (panel.window) RKAIHideCapsule(panel);
}

- (void)didMoveToWindow {
    %orig;
    UIView *panel = (UIView *)self;
    if (!panel.window) return;
    RKAIHideCapsule(panel);
    if (RKAIPanelDumpCount < 2) {
        RKAIPanelDumpCount++;
        RKAILog(@"[panel] modern view #%ld frame=%@",
                (long)RKAIPanelDumpCount, NSStringFromCGRect(panel.frame));
        for (UIView *v in panel.subviews) {
            RKAILog(@"    %@ frame=%@ hidden=%d",
                    NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.hidden);
        }
    }
}

%end

%ctor {
    @autoreleasepool {
        RKAILogRefresh();
        // 设置页改动（含总开关）后刷新日志总闸；Darwin 通知跨进程，进程内立即可见。
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RKAILogPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        RKAILog(@"==== RKAIRecorderHide 2.3.40 loaded, bundle=%@, logPath=%@ ====",
                [[NSBundle mainBundle] bundleIdentifier], RKAILogPath());
    }
}
