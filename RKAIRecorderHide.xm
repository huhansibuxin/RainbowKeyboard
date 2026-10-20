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
// setRecording: / refreshAppearance，内部是 Lottie），不是面板胶囊，故不再动它。
//
// == 本期做法（2.3.39） ==
// 在 WBVoiceInputInteractionModernView 布局后，递归扫直接子视图，凡「子视图里有
// UILabel 且文本含『录音笔』」的容器就整体 hidden + alpha 0 + 禁交互。
// 不依赖 WBButton 类名（微信改类名也不失效），宽度 <260pt 排除整块容器。
// 「轻触结束」/波形/搜索按钮均不受影响。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 日志（沙盒 tmp，SSH 直接 cat）

static NSString *RKAILogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"rk_ai.log"];
}

static void RKAILog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *fp = fopen(RKAILogPath().UTF8String, "a");
    if (!fp) return;
    fprintf(fp, "%s\n", line.UTF8String);
    fclose(fp);
}

static void RKAIDumpClass(NSString *name) {
    Class cls = NSClassFromString(name);
    if (!cls) {
        RKAILog(@"[dump] %@ NOT FOUND", name);
        return;
    }
    Class sup = class_getSuperclass(cls);
    RKAILog(@"[dump] class %@  super=%@", name, sup ? NSStringFromClass(sup) : @"-");
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        RKAILog(@"    - %s", sel_getName(method_getName(list[i])));
    }
    free(list);
}

#pragma mark - 胶囊定位

static NSInteger RKAICapsuleHitCount = 0;
static NSInteger RKAIPanelDumpCount = 0;

// 返回 YES 表示本层及以下找到并隐藏了胶囊。
static BOOL RKAIHideCapsule(UIView *node, int depth) {
    if (depth > 4) return NO;
    BOOL hit = NO;
    for (UIView *v in node.subviews) {
        BOOL isCapsule = NO;
        for (UIView *s in v.subviews) {
            if ([s isKindOfClass:[UILabel class]] &&
                [((UILabel *)s).text containsString:@"录音笔"]) {
                isCapsule = YES;
                break;
            }
        }
        // 宽度上限排除整块容器，避免误伤；胶囊实测 91pt。
        if (isCapsule && v.bounds.size.width < 260) {
            v.hidden = YES;
            v.alpha = 0.0;
            v.userInteractionEnabled = NO;
            hit = YES;
            if (RKAICapsuleHitCount < 5) {
                RKAICapsuleHitCount++;
                RKAILog(@"[capsule] hidden %@ frame=%@",
                        NSStringFromClass(v.class), NSStringFromCGRect(v.frame));
            }
            continue;
        }
        if (RKAIHideCapsule(v, depth + 1)) hit = YES;
    }
    return hit;
}

%hook WBVoiceInputInteractionModernView

- (void)layoutSubviews {
    %orig;
    UIView *panel = (UIView *)self;
    if (panel.window) RKAIHideCapsule(panel, 0);
}

- (void)didMoveToWindow {
    %orig;
    UIView *panel = (UIView *)self;
    if (!panel.window) return;
    RKAIHideCapsule(panel, 0);
    if (RKAIPanelDumpCount < 2) {
        RKAIPanelDumpCount++;
        RKAILog(@"[panel] modern view #%ld frame=%@",
                (long)RKAIPanelDumpCount, NSStringFromCGRect(panel.frame));
        RKAILog(@"[panel] subviews:");
        for (UIView *v in panel.subviews) {
            RKAILog(@"    %@ frame=%@ hidden=%d",
                    NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.hidden);
        }
    }
}

%end

%ctor {
    @autoreleasepool {
        RKAILog(@"==== RKAIRecorderHide 2.3.39 loaded, bundle=%@ ====",
                [[NSBundle mainBundle] bundleIdentifier]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RKAIDumpClass(@"WBVoiceInputInteractionModernView");
        });
    }
}
