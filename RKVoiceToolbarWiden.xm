// RKVoiceToolbarWiden.xm — 微信输入法(WeType) 工具栏「语音按钮」横向拉宽
//
// 目标：只把工具栏上的语音按钮横向拉到约 3 格（3×钮宽 + 2×间距），
//       其余按钮的尺寸与外观一律不动。
//
// 为什么只能 hook：wxkb_plugin 里 `WBFunctionToolBar` / `WBToolBarButton`
// 没有任何宽度属性（全量 ivar 反查确认），配置键也只有「显示什么/几个」的语义，
// 宽度是 `-layoutForAnimated:animateFinishedBlock:` 内部现算的局部值。
//
// 2.3.4 为诊断版：每次调整都会把工具栏结构写进
//   <扩展容器>/tmp/rk_voicetoolbar.log
// 供取回确认语音按钮的 func 枚举值、真实 frame/间距/对齐方式。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>
#import <math.h>
#import "RKPreferences.h"

@interface WBFunctionToolBar : UIView
- (void)layoutForAnimated:(uintptr_t)animated animateFinishedBlock:(uintptr_t)block;
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
        // 单文件上限 256KB，超出即重开，避免长期驻留无限增长。
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

#pragma mark - 按钮发现

static NSArray<UIView *> *RKVoiceButtons(WBFunctionToolBar *toolbar) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    id stored = nil;
    @try {
        stored = [toolbar valueForKey:@"buttons"];
    } @catch (__unused NSException *exception) {
    }
    if ([stored isKindOfClass:NSOrderedSet.class]) {
        for (id button in (NSOrderedSet *)stored)
            if ([button isKindOfClass:UIView.class]) [buttons addObject:button];
    } else if ([stored isKindOfClass:NSArray.class]) {
        for (id button in (NSArray *)stored)
            if ([button isKindOfClass:UIView.class]) [buttons addObject:button];
    }
    if (buttons.count) return buttons;

    // 兜底：递归找类名像工具栏按钮的视图（_buttons 结构若变更时仍可用）。
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:toolbar];
    while (stack.count) {
        UIView *node = stack.lastObject;
        [stack removeLastObject];
        for (UIView *sub in node.subviews) {
            if ([NSStringFromClass(sub.class).lowercaseString containsString:@"toolbarbutton"])
                [buttons addObject:sub];
            else
                [stack addObject:sub];
        }
    }
    return buttons;
}

static NSString *RKVoiceDescription(UIView *button) {
    NSString *identifier = button.accessibilityIdentifier;
    if (identifier.length) return identifier;
    NSString *label = button.accessibilityLabel;
    return label.length ? label : @"";
}

// 识别语音按钮。返回命中的判据名，便于日志确认。
static UIView *RKVoiceButton(NSArray<UIView *> *buttons, NSString **rule) {
    for (UIView *button in buttons) {
        if ([RKVoiceDescription(button).lowercaseString containsString:@"voice"]) {
            *rule = @"accessibility";
            return button;
        }
    }
    for (UIView *button in buttons) {
        NSString *desc = nil;
        @try {
            desc = [button valueForKey:@"desc"];
        } @catch (__unused NSException *exception) {
        }
        if ([desc isKindOfClass:NSString.class] &&
            ([desc.lowercaseString containsString:@"voice"] || [desc containsString:@"语音"])) {
            *rule = @"desc";
            return button;
        }
    }
    // 暂定判据：同排最靠上、最靠左的按钮（微信默认语音就在工具栏首位）。
    UIView *top = nil;
    for (UIView *button in buttons)
        if (!top || button.frame.origin.y < top.frame.origin.y - 1) top = button;
    if (!top) {
        *rule = @"none";
        return nil;
    }
    UIView *leftmost = nil;
    for (UIView *button in buttons) {
        if (fabs(button.frame.origin.y - top.frame.origin.y) > 1) continue;
        if (!leftmost || button.frame.origin.x < leftmost.frame.origin.x) leftmost = button;
    }
    *rule = leftmost ? @"leftmost" : @"none";
    return leftmost;
}

#pragma mark - 诊断 dump

static void RKVoiceDump(WBFunctionToolBar *toolbar, NSArray<UIView *> *buttons) {
    id funcs = nil, focused = nil, showVoice = nil, scaleFirst = nil;
    @try { funcs = [toolbar valueForKey:@"funcs"]; } @catch (__unused NSException *exception) {}
    @try { focused = [toolbar valueForKey:@"focusedFunc"]; } @catch (__unused NSException *exception) {}
    @try { showVoice = [toolbar valueForKey:@"showVoiceInput"]; } @catch (__unused NSException *exception) {}
    @try { scaleFirst = [toolbar valueForKey:@"scaleFirstItem"]; } @catch (__unused NSException *exception) {}

    RKVoiceLog(@"===== WBFunctionToolBar dump =====");
    RKVoiceLog(@"toolbar frame=%@ bounds=%@ subviews=%lu",
        NSStringFromCGRect(toolbar.frame), NSStringFromCGRect(toolbar.bounds),
        (unsigned long)toolbar.subviews.count);
    RKVoiceLog(@"funcs(count=%lu)=%@ focusedFunc=%@ showVoiceInput=%@ scaleFirstItem=%@",
        (unsigned long)[funcs count], funcs, focused, showVoice, scaleFirst);
    NSUInteger index = 0;
    for (UIView *button in buttons) {
        NSString *funcValue = @"?";
        NSString *desc = @"-";
        id rawFunc = nil, rawDesc = nil;
        @try { rawFunc = [button valueForKey:@"func"]; } @catch (__unused NSException *exception) {}
        @try { rawDesc = [button valueForKey:@"desc"]; } @catch (__unused NSException *exception) {}
        if (rawFunc) funcValue = [rawFunc description];
        if ([rawDesc isKindOfClass:NSString.class] && [rawDesc length]) desc = rawDesc;
        RKVoiceLog(@"button[%lu] %@ func=%@ frame=%@ super=%@ al=%@ cons=%lu acc=<%@/%@> desc=<%@>",
            (unsigned long)index, NSStringFromClass(button.class), funcValue,
            NSStringFromCGRect(button.frame), NSStringFromClass(button.superview.class),
            button.translatesAutoresizingMaskIntoConstraints ? @"ON" : @"OFF",
            (unsigned long)button.constraints.count,
            button.accessibilityIdentifier ?: @"-", button.accessibilityLabel ?: @"-", desc);
        index++;
    }
}

#pragma mark - 拉宽

static char RKVoiceLayoutCountKey;
static BOOL RKVoiceAdjusting;

static void RKVoiceWidenApply(WBFunctionToolBar *toolbar) {
    if (RKVoiceAdjusting) return;
    RKVoiceAdjusting = YES;
    @try {
        NSInteger count = [objc_getAssociatedObject(toolbar, &RKVoiceLayoutCountKey) integerValue] + 1;
        objc_setAssociatedObject(toolbar, &RKVoiceLayoutCountKey, @(count),
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        if (!RKVoiceWidenEnabled()) {
            if (count <= 2) RKVoiceLog(@"layout#%ld 开关关闭，跳过", (long)count);
            return;
        }
        NSArray<UIView *> *buttons = RKVoiceButtons(toolbar);
        BOOL verbose = count <= 3;
        if (verbose) RKVoiceDump(toolbar, buttons);
        if (buttons.count < 2) {
            if (verbose) RKVoiceLog(@"layout#%ld 按钮数不足(%lu)，跳过",
                (long)count, (unsigned long)buttons.count);
            return;
        }

        NSString *rule = @"none";
        UIView *voice = RKVoiceButton(buttons, &rule);
        if (!voice) {
            RKVoiceLog(@"layout#%ld 未识别到语音按钮，跳过", (long)count);
            return;
        }
        // 本版只处理 frame 布局。若按钮由 Auto Layout 托管，改 frame 会被下一次
        // 布局覆盖并可能反复触发布局，故直接跳过并记录，确认后再补约束方案。
        if (!voice.translatesAutoresizingMaskIntoConstraints) {
            RKVoiceLog(@"layout#%ld 语音按钮由 Auto Layout 管理(al=OFF)，本版跳过", (long)count);
            return;
        }

        // 同排参考：取同一父视图、同一行的兄弟按钮，实测钮宽与最小正间距，
        // 因此换机型 / 换字号都自适应，不写死常量。
        UIView *parent = voice.superview;
        CGRect voiceRect = voice.frame;
        NSMutableArray<UIView *> *row = [NSMutableArray array];
        for (UIView *button in buttons) {
            if (button.superview != parent) continue;
            if (fabs(button.frame.origin.y - voiceRect.origin.y) > 1) continue;
            [row addObject:button];
        }
        [row sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            return a.frame.origin.x < b.frame.origin.x ? NSOrderedAscending :
                (a.frame.origin.x > b.frame.origin.x ? NSOrderedDescending : NSOrderedSame);
        }];

        CGFloat reference = 0, gap = 0;
        BOOL gapFound = NO;
        for (UIView *button in row)
            if (button != voice) reference = MAX(reference, button.frame.size.width);
        for (NSUInteger i = 1; i < row.count; i++) {
            CGFloat candidate = row[i].frame.origin.x - CGRectGetMaxX(row[i - 1].frame);
            if (candidate > 0.5 && (!gapFound || candidate < gap)) {
                gap = candidate;
                gapFound = YES;
            }
        }
        if (reference <= 1) reference = voiceRect.size.width;
        if (!gapFound) gap = 6;

        CGFloat target = 3 * reference + 2 * gap;
        CGFloat current = voiceRect.size.width;
        if (fabs(current - target) < 0.5) return;   // 幂等：已达目标即不再改动

        CGFloat delta = target - current;
        CGRect frame = voiceRect;
        CGFloat shifted = 0;
        if (delta > 0) {
            // 优先向左扩展：其余按钮一格不动，最贴合「只放大语音按钮」。
            CGFloat newMinX = MAX(0, frame.origin.x - delta);
            shifted = frame.origin.x - newMinX;
            frame.origin.x = newMinX;
            frame.size.width += shifted;
        } else {
            frame.size.width = target;
        }
        CGFloat shortfall = delta - shifted;
        if (shortfall > 0.5) {
            // 左侧空间不足：把同排右侧按钮整体右移，尺寸保持不变。
            for (UIView *button in row) {
                if (button.frame.origin.x <= voiceRect.origin.x) continue;
                CGRect sibling = button.frame;
                sibling.origin.x += shortfall;
                button.frame = sibling;
            }
        }
        voice.frame = frame;

        RKVoiceLog(@"layout#%ld 命中判据=%@ 类=%@ func=%@ 钮宽=%.1f 间距=%.1f 目标宽=%.1f 左扩=%.1f 右移=%.1f",
            (long)count, rule, NSStringFromClass(voice.class), [voice valueForKey:@"func"] ?: @"?",
            reference, gap, target, shifted, MAX(0, shortfall));
    } @catch (NSException *exception) {
        RKVoiceLog(@"异常: %@", exception.reason);
    } @finally {
        // 必须放 @finally：上面各分支都有提前 return，写在函数尾部会被跳过，
        // 导致重入闸门永久卡在 YES、此后所有调整失效。
        RKVoiceAdjusting = NO;
    }
}

%group RKVoiceToolbarGroup
%hook WBFunctionToolBar

- (void)layoutSubviews {
    %orig;
    RKVoiceWidenApply(self);
}

%end
%end

// 工具栏真正的主布局入口是 -layoutForAnimated:animateFinishedBlock:，
// 通常由 layoutSubviews 内部调用（此路径已被上面的钩子覆盖），但也可能被
// 持有者直接调用，故一并下钩。参数按 uintptr_t 声明 = 位级原样透传，
// 不解释参数类型，避免签名推断错误带来的风险。
%group RKVoiceToolbarAnimatedGroup
%hook WBFunctionToolBar

- (void)layoutForAnimated:(uintptr_t)animated animateFinishedBlock:(uintptr_t)block {
    %orig;
    RKVoiceWidenApply(self);
}

%end
%end

%ctor {
    // 只在微信输入法扩展里生效；注入到系统键盘(InputUI)时该类不存在，直接跳过。
    Class toolbarClass = (Class)objc_getClass("WBFunctionToolBar");
    if (!toolbarClass) return;
    %init(RKVoiceToolbarGroup);
    // 仅在原方法确实存在时才下钩：否则 %orig 会落到空 IMP 上。
    if (class_getInstanceMethod(toolbarClass, @selector(layoutForAnimated:animateFinishedBlock:))) {
        %init(RKVoiceToolbarAnimatedGroup);
    }
}
