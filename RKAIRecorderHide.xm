// RKAIRecorderHide.xm — 移除微信输入法「AI 录音笔」入口（图标 + 胶囊标识 + 点击入口）
//
// == 背景（2026-10-20） ==
// 用户 10-20 升级微信输入法后，点开语音按钮，语音面板左上角出现「AI 录音笔」胶囊
// （Lottie 图标 + 文案），右上「轻触结束」，中间波形，底部「发送」。
// 旧版（9-23 dump）里没有这些字符串 ⇒ 本次升级新增的「录音笔 / Recap」体系。
//
// == 静态定位结果（wxkb_plugin_1020，md5 e60a9378b4e34af1dcf59c54eba1cf97）==
// 新增类：WBVoiceRecorderIconView（Swift，7 个实例方法，含 $__lazy_storage_$_animationUrls /
//         $__lazy_storage_$_fullAnimationKeypath / iconImage / cornerIconSize / cancelIconView）
//         WBRecordingSummaryMetadata/Reporter/ReportContext、WBVoiceDictPreferences、
//         RecapItemView、WtVoiceRecapRoot、ListRecapSession/QueryRecap/DeleteRecapSession
// 新增文案：AI 录音笔 / 试试 AI 录音笔，生成可分享的内容 / AI录音笔（工具栏项）/
//           正在使用 AI 录音笔 / 内容清晰，无需整理 / 已自动开启文字整理
// 新增选择子：setRecorderIcon:（属性类型 WBVoiceRecorderIconView）、iconVisible、
//             openRecorderButton、handleOpenRecorderButtonAction:、_openRecorderBlock、
//             _openRecorderMaskView、checkCanOpenRecorderDirectly、
//             _transitionNativeViewStateToRecorderStandby、handedOffToRecorder、
//             _launchWBRecorderAfterAuthorizationWithContext:、voiceRecorderItem
//
// == 本期做法（探针 + 保守隐藏）==
// 1) 不删视图、不改父类容器，只把 WBVoiceRecorderIconView 强制 hidden + alpha 0 + 禁交互。
//    理由：它在 Swift 里是 lazy 属性，置 nil 可能触发隐式解包崩溃；hidden 足够达到"看不见"。
// 2) setHidden:/setAlpha: 一并钳死，防止父类在状态切换时把它重新显示出来。
// 3) 同时落探针日志：方法表、superview 链、语音面板视图树 —— 用于确认它到底挂在哪、
//    以及工具栏「AI录音笔」固定项是否还有第二个入口。
// 4) 点击入口 handleOpenRecorderButtonAction: 在确认宿主类后再做精确拦截（本期先只记录）。

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
    NSString *path = RKAILogPath();
    FILE *fp = fopen(path.UTF8String, "a");
    if (!fp) return;
    fprintf(fp, "%s\n", line.UTF8String);
    fclose(fp);
}

#pragma mark - 运行时枚举工具

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
        RKAILog(@"    - %s  types=%s", sel_getName(method_getName(list[i])),
                method_getTypeEncoding(list[i]));
    }
    free(list);
    n = 0;
    list = class_copyMethodList(object_getClass(cls), &n);
    for (unsigned int i = 0; i < n; i++) {
        RKAILog(@"    + %s", sel_getName(method_getName(list[i])));
    }
    free(list);
    n = 0;
    Ivar *ivars = class_copyIvarList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        RKAILog(@"    ivar %s  %s", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]));
    }
    free(ivars);
}

// 找出所有"自己实现"了某选择子的类（排除纯继承），用于定位 setRecorderIcon: 的宿主。
static void RKAIFindImplementors(const char *selName) {
    SEL sel = sel_registerName(selName);
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(classes, count);
    for (int i = 0; i < count; i++) {
        Class c = classes[i];
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        for (unsigned int j = 0; j < n; j++) {
            if (method_getName(list[j]) == sel) {
                RKAILog(@"[impl] -%s  by %@", selName, NSStringFromClass(c));
                break;
            }
        }
        free(list);
    }
    free(classes);
}

static void RKAIDumpViewChain(UIView *view, NSString *tag) {
    RKAILog(@"[chain] %@", tag);
    int depth = 0;
    for (UIView *v = view; v && depth < 12; v = v.superview, depth++) {
        RKAILog(@"    %@  frame=(%.1f,%.1f %.1fx%.1f) hidden=%d alpha=%.2f",
                NSStringFromClass(v.class),
                v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
                v.hidden, v.alpha);
    }
}

#pragma mark - 隐藏 + 探针

static NSInteger RKAIPanelDumpCount = 0;

%hook WBVoiceRecorderIconView

- (void)didMoveToWindow {
    %orig;
    // Logos 只给 hook 类做前置声明，self 的静态类型不是 UIView，必须先强转。
    UIView *icon = (UIView *)self;
    // 出现即隐藏（不 removeFromSuperview，避免 Swift 侧持有关系被破坏）。
    icon.hidden = YES;
    icon.alpha = 0.0;
    icon.userInteractionEnabled = NO;
    RKAIDumpViewChain(icon, @"WBVoiceRecorderIconView didMoveToWindow");
    // 「AI 录音笔」胶囊 = 图标视图 + 文案，外层通常是一个 UIControl。若图标外面就套着
    // 一个窄的 UIControl（<220pt，排除整条顶部栏），连它一起隐藏，避免只剩文字。
    UIView *sv = icon.superview;
    if (sv && [sv isKindOfClass:UIControl.class] && sv.bounds.size.width < 220) {
        sv.hidden = YES;
        sv.alpha = 0.0;
        RKAILog(@"[icon] capsule superview hidden: %@ %@",
                NSStringFromClass(sv.class), NSStringFromCGRect(sv.bounds));
    }
    RKAILog(@"[icon] superview=%@  bounds=%@  self=%@",
            NSStringFromClass(sv.class), sv ? NSStringFromCGRect(sv.bounds) : @"-",
            NSStringFromCGRect(icon.bounds));
}

- (void)setHidden:(BOOL)hidden {
    %orig(YES);
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(0.0);
}

%end

// 语音面板主视图：只在第一次布局时 dump 一次整棵子树，确认录制界面的组成。
%hook WBVoiceInputInteractionModernView

- (void)didMoveToWindow {
    %orig;
    UIView *panel = (UIView *)self;
    if (panel.window && RKAIPanelDumpCount < 3) {
        RKAIPanelDumpCount++;
        RKAILog(@"[panel] WBVoiceInputInteractionModernView #%ld frame=%@",
                (long)RKAIPanelDumpCount, NSStringFromCGRect(panel.frame));
        RKAIDumpViewChain(panel, @"panel chain");
        RKAILog(@"[panel] recursiveDescription BEGIN");
        RKAILog(@"%@", [panel performSelector:@selector(recursiveDescription)]);
        RKAILog(@"[panel] recursiveDescription END");
    }
}

%end

%ctor {
    @autoreleasepool {
        // 仅微信键盘扩展进程需要（InputUI 是宿主 App 的输入 UI，本功能在插件里）。
        NSString *bundle = [[NSBundle mainBundle] bundleIdentifier];
        RKAILog(@"==== RKAIRecorderHide loaded, bundle=%@ ====", bundle);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RKAIDumpClass(@"WBVoiceRecorderIconView");
            RKAIDumpClass(@"WBVoiceInputInteractionModernView");
            RKAIFindImplementors("setRecorderIcon:");
            RKAIFindImplementors("handleOpenRecorderButtonAction:");
            RKAIFindImplementors("setIconVisible:");
        });
    }
}
