// RKVoiceToolbarWiden.xm — 微信输入法(WeType) 工具栏「语音按钮」加宽并显示「点击说话」
//
// == 为什么只能 hook ==
// wxkb_plugin 里 WBFunctionToolBar / WBToolBarButton 都没有任何宽度属性（全量 1830 类
// ivar 反查确认），配置键也只有「显示什么 / 显示几个 / 开不开」的语义，宽度是
// -sizeThatFits: 内部现算出来的局部值，既不落盘、也没有 setter。配置文件这条路是死的。
//
// == 原生布局规律（2.3.4/2.3.5 实机日志 + 截图逐像素测量）==
// 1) 工具栏宽度 = 各按钮 sizeThatFits 之和 + 间距 + 左右各 12pt 内边距，右边缘钉在屏幕
//    右侧；某个按钮变宽时父视图把工具栏整体向左扩（占候选栏的空间）——这正是
//    「最近使用」宽胶囊(91.33pt)能存在的原因。
//        5 个方钮(34) + 4×间距(12) + 24 = 242.0     实测
//        语音按钮宽 102 后              = 310.0     实测，与算式一致
// 2) 工具栏尺寸不读 frame，只认各按钮的 sizeThatFits。-layoutForAnimated: 会按新宽度
//    重排全部按钮，所以只加宽语音按钮这一处即可，其余按钮尺寸/位置全由微信自己算
//    （2.3.4 曾改 frame 硬推兄弟按钮，因为容器没跟着变宽，把右侧 3 个按钮挤出了可视区）。
// 3) 截图逐像素量：方钮 102px、间距 138px、胶囊 310px，1pt = 3px ⇒ 胶囊 ≈ 3.04 个方钮宽。
//
// == 语音按钮的识别（精确，无模糊猜测）==
// func == 1。依据：实机日志里工具栏顺序 (28,1,23,8,7,5) 与截图
// 「最近使用胶囊 → 麦克风 → 剪贴板 → 立方体 → …」逐位对应；focusedFunc=1；
// 2.3.5 日志「识别到语音按钮: 图标匹配 func=1」——图标比对 icon_bar_voice_24 命中的
// 也正是 func=1。若微信日后改枚举，同步改 RKVoiceFunc 即可。
// （2.3.4 曾用「取最左按钮」兜底，误伤了 func=37 的文件传输邀请按钮，已废弃。）
//
// == 「图标 + 文字」用原生能力 ==
// WBToolBarButton 自带描述文字：_showDesc(B) / _desc(NSString) / _descLabel(WBLabel)，
// 配套有 imageSizeWithDescLabel、imageHorInsetWithDescLabel、imageRightInsetWithDescLabel、
// descLabelHeight 等专用布局方法（imageRightInset = 图标右侧给文字留位 ⇒ 图标在左、
// 文字在右，正是目标形态）。所以只需 setShowDesc: + setDesc:，排布交给它自己的
// -layoutSubviews，不干预字体/颜色/间距。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import "RKPreferences.h"

@interface WBToolBarButton : UIView
- (unsigned long long)func;
- (void)setShowDesc:(BOOL)showDesc;
- (void)setDesc:(NSString *)desc;
- (id)descLabel;
@end

#pragma mark - 开关

// 缺省即开：键盘扩展沙盒读不到偏好文件时，固化表(RKPresetSelfUseTable)会把
// WidenVoiceButton 兜底成 1，所以任何情况下默认都是打开状态。
static BOOL RKVoiceWidenEnabled(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id value = prefs[@"WidenVoiceButton"];
    return value ? [value boolValue] : YES;
}

#pragma mark - 语音按钮识别

// 实测精确值：func 枚举 1 = 语音（麦克风）。依据见文件头。
static unsigned long long const RKVoiceFunc = 1;

static BOOL RKVoiceIsVoiceButton(UIView *button) {
    if (![button respondsToSelector:@selector(func)]) return NO;
    return [(WBToolBarButton *)button func] == RKVoiceFunc;
}

#pragma mark - 描述文字（图标在左，文字跟在右侧）

static NSString * const RKVoiceDescText = @"点击说话";
static char RKVoiceDescAppliedKey;

static void RKVoiceApplyDescIfNeeded(WBToolBarButton *button) {
    if (objc_getAssociatedObject(button, &RKVoiceDescAppliedKey)) return;
    objc_setAssociatedObject(button, &RKVoiceDescAppliedKey, @YES,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [button setShowDesc:YES];
    [button setDesc:RKVoiceDescText];
    // setShowDesc: 若没顺手建出 label，这里补一次（方法不存在就跳过）。
    if (![button descLabel] && [button respondsToSelector:@selector(initDescLabelIfNeeded)])
        ((void (*)(id, SEL))objc_msgSend)(button, @selector(initDescLabelIfNeeded));
}

#pragma mark - 目标宽度

// 方钮是正方形 ⇒「一格」= 它的高（也是它的自然宽），实测 34pt。
// 目标 = 3.5 格：3 格 = 与「最近使用」胶囊等长，再宽半格（用户要求）。
// 「一格」从同排方钮实测采样，换机型/字号自动跟随；采不到时用实测的 34pt 兜底。
static CGFloat const RKVoiceTargetUnits = 3.5;
static CGFloat RKVoiceUnitWidth = 0;

#pragma mark - Hook

%group RKVoiceButtonGroup
%hook WBToolBarButton

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize natural = %orig;
    if (!RKVoiceWidenEnabled()) return natural;

    if (!RKVoiceIsVoiceButton(self)) {
        // 顺手采样「一个方钮」的宽度。上限 80 是为了滤掉「最近使用」胶囊(91.33)
        // 这类非方钮，避免把基准采歪。
        if (natural.width >= 18 && natural.width <= 80) RKVoiceUnitWidth = natural.width;
        return natural;
    }

    RKVoiceApplyDescIfNeeded(self);
    CGFloat unit = RKVoiceUnitWidth > 0 ? RKVoiceUnitWidth : 34;
    return CGSizeMake(ROUND(RKVoiceTargetUnits * unit), natural.height);
}

%end
%end

%ctor {
    // 只在微信输入法扩展里生效；注入到系统键盘(InputUI)时该类不存在，直接跳过。
    if (objc_getClass("WBToolBarButton")) {
        %init(RKVoiceButtonGroup);
    }
}
