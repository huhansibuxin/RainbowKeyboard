// RKAIRecorderHide.xm — 移除微信输入法「AI 录音笔」入口（图标 + 胶囊标识）
//
// == 背景（2026-10-20） ==
// 用户 10-20 升级微信输入法后，点「点击说话」进入语音面板，左上角出现「AI 录音笔」胶囊。
//
// == 2.3.38 探针实测（关键纠正） ==
// 该胶囊**不是** WBVoiceRecorderIconView。语音面板视图树（2.3.38 实测）：
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
//
// == 2.5.1：移除全部调试日志（RKAILog / RKAILogRefresh / %ctor 注册通知）==
//    功能本身不依赖任何开关或日志，仅保留视图树扫描 + 隐藏。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - 胶囊定位（缓存 + 回退重扫）

static const void *RKAICapsuleKey = &RKAICapsuleKey;

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
}

%end
