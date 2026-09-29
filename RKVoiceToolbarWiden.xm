// RKVoiceToolbarWiden.xm — 微信输入法(WeType) 工具栏「语音按钮」加宽 + 「图标/文字」散开占满
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
//
// == 语音按钮的识别（精确，无模糊猜测）==
// func == 1。依据：实机日志里工具栏顺序 (28,1,23,8,7,5) 与截图
// 「最近使用胶囊 → 麦克风 → 剪贴板 → 立方体 → …」逐位对应；focusedFunc=1；
// 2.3.5 日志「识别到语音按钮: 图标匹配 func=1」——图标比对 icon_bar_voice_24 命中的
// 也正是 func=1。若微信日后改枚举，同步改 RKVoiceFunc 即可。
// （2.3.4 曾用「取最左按钮」兜底，误伤了 func=37 的文件传输邀请按钮，已废弃。）
//
// == 「图标重叠文字」的原生根因（反汇编 WBToolBarButton -layoutSubviews 得到）==
// 微信显示描述文字时的排布是这么算的（desc 分支，0x1001ced54 起）：
//      imgW   = [self imageSizeWithDescLabel]      // = imageView.image.size
//      inset  = [self imageHorInsetWithDescLabel]  // 常量 12
//      right  = [self imageRightInsetWithDescLabel]// 常量 4
//      labelS = [descLabel sizeThatFits:(DBL_MAX, 3)]
//      descLabel.frame = (12 + imgW + 4, 居中, width-(2*12+imgW+4), labelS.height)
//      [self setContentEdgeInsets:(4, -4, 4, labelS.width)]
// 即：文字固定在 x≈40，而图标并没有放在 12 处 —— 它由 UIButton 按 contentEdgeInsets
// 在剩余空间里**居中**。按钮一宽（2.3.7 时 4.5 格 = 153pt），居中位置 ~42pt，正好压到
// x=40 的文字上 —— 这就是截图里「麦克风压住"点"字」的成因；而 right=4 使得间距只有 4pt，
// 看着挤成一片。这套算法本来就是给窄按钮写的，加宽后它算不对。
// => 结论：加宽后必须由我们接管 imageView 与 descLabel 两个 frame，不再依赖原生 desc 排布。
//    只改 frame（在 %orig 之后），字体/颜色/间距参数一律不碰。
//
// == 2.3.13 新增：整排居中 + 语音按钮底色 ==
// 截图逐像素实测（1pt = 3px）：语音胶囊 118pt(161.3→279.3)，三个方钮各 32.7pt，间距各
// 12.7pt，整排右边缘钉在 417.7pt（右留白 12.3pt），左边却空着 163pt —— 微信原生是**右对齐**。
// 1) 居中：刻意**不用**「加宽语音按钮」（要左留白=右留白 12.3 需语音宽 269pt = 7.9 格）
//    也**不用**「拉大间距」（3 个间隔要从 12.7 → 63pt 才撑得满，且间距是微信内部布局
//    算的、没有 setter，只能接管整个重排 = 2.3.4 的坑）。正解 = 宽度/间距/兄弟按钮 frame
//    一个都不动，只把**整排沿 x 平移**，直到语音按钮中心落在屏幕中心：
//        dx = 屏幕中心 − 语音按钮中心（都在工具栏坐标系里算）  实测 ≈ −5.3pt
//    2.3.13 先是用容器的 transform 做平移 —— 实机不成立（见下）。
//
// == 2.3.14 修正：平移的对象从「容器的 transform」换成「容器内部的滚动视图」 ==
// 2.3.13 的 transform 表现为「键盘刚弹出时左偏一下、随即弹回右原位」，且某些 App 里
// 调键盘发卡。两个原因同源：
//   1) transform 位移守不住。只要宿主再 setFrame: 一次，UIKit 就按「新 frame 的中点 →
//      center」反算，center 回到原位 ⇒ 视觉整条弹回。宿主每轮布局都会重设容器 frame，
//      所以位移必然被抹。
//   2) 每轮无条件写一次 transform（即使本来就是单位阵）＝ 每次布局都刷一遍图层几何属性；
//      而 transform 会让 frame 的 getter 返回值跟着变，宿主若按子视图 frame 反推布局
//      就会被反复触发，形成布局连锁 —— 这就是「卡」。
// 改法：容器把全部按钮放在内部那颗 UIScrollView（ivar `_scrollView`）里，而
// -layoutForAnimated: 给这颗滚动视图设的 frame **就是容器自己的 bounds**（反汇编
// 0x100066d6c 段：取 self->_scrollView，用 [self bounds] 直接 setFrame:），原点恒等于
// 容器 bounds 原点。我们在宿主算完之后只改这颗滚动视图的 origin.x：尺寸不动、不产生
// 任何布局连锁、之后也没有任何人再算它 ⇒ 位移留得住。容器不裁剪到为负的一侧（那侧本来
// 就是空白），所以左移 5pt 完全没有副作用。
// 2) 底色：暗色 #505050（= 用户指定的「常用语」那一档；现在的 #5B5B5B 偏亮发闷），
//    亮色 #F3F3F5（按暗色那档相对键盘底的对比度同比推算：亮色键盘底 #DFE0E4、按钮
//    #FAFAFB 太扎眼）。微信自己的底色来自 -backgroundColorForCurrentFunc 经
//    wb_colorWithBackendColor:frontColor: 混合后 setBackgroundColor:，我们在布局后直接
//    写最终值绕开那层混合，只作用于 func==1 这一个按钮，别的按钮一概不碰。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import "RKPreferences.h"

// 实测该类真身是 UIButton 子类（WBToolBarButton -> WBButton -> UIButton）：
// layoutSubviews 里调用了 imageForState: / imageView / setContentEdgeInsets:。
@interface WBToolBarButton : UIButton
- (unsigned long long)func;
- (void)setShowDesc:(BOOL)showDesc;
- (BOOL)showDesc;
- (void)setDesc:(NSString *)desc;
- (UILabel *)descLabel;
@end

// 工具栏容器（携带全部功能按钮，右对齐；见文件头「原生布局规律」）。
@interface WBFunctionToolBar : UIView
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

#pragma mark - 描述文字

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
    [button setNeedsLayout];
}

#pragma mark - 图标 / 文字排布（两者靠拢成一组，整组在按钮里居中）

// 2.3.8 用的是「图标贴左、文字贴右、富余全给中间」，实机看着是「左边一坨、右边一坨、
// 中间一大块空」；2.3.9 改成成组居中；2.3.10 修掉成组居中的左右 1pt 偏差（右边缘镜像）。
static CGFloat const RKVoiceGroupGap = 10.0;      // 图标与文字之间的目标间距

// 身份与开关由调用方 RKVoiceApplyAll 统一判定（每轮布局只读一次偏好），这里只管排布。
static void RKVoiceArrangeContent(WBToolBarButton *button) {
    if (![button showDesc]) return;

    UIImageView *icon = button.imageView;     // UIButton 的图标视图（麦克风）
    UILabel *label = [button descLabel];      // 「点击说话」
    if (!icon || !label) return;

    CGRect bounds = button.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    // 图标尺寸优先取 imageView 的图（原生 imageSizeWithDescLabel 也是这么取的），
    // 退一步取按钮自身的 normal 图；都拿不到就保持原样（fail-safe，不乱摆）。
    UIImage *iconImage = icon.image ?: [button imageForState:UIControlStateNormal];
    CGSize iconSize = iconImage.size;
    if (iconSize.width <= 0 || iconSize.height <= 0) iconSize = icon.frame.size;

    CGSize labelSize = label.intrinsicContentSize;
    if (labelSize.width <= 0 || labelSize.height <= 0)
        labelSize = [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];

    if (iconSize.width <= 0 || iconSize.height <= 0) return;
    if (labelSize.width <= 0 || labelSize.height <= 0) return;

    // 成组居中：free = 格宽 - 图标宽 - 文字宽（图标与文字的间距也包含在 free 里）。
    // 左留白取整（图标位图落在整点上，不会被拉糊）；右留白**由右边缘镜像左留白反推**：
    //     labelX = 格宽 - 左留白 - 文字宽   ⇒  右留白 == 左留白（数值上完全相等）
    // free 是奇数/小数时多出来的那 1pt 全部由中间间距吸收（间距 9~10pt，肉眼分不出），
    // 不会再偏到任何一侧。
    // —— 2.3.9 的错法：左留白取整后，右侧顺着 icon+gap 累加，于是「宽」和「文字宽」的
    //    零头全砸在右留白上，左右最多差 ~1pt（3x 屏约 3px），观感就是
    //    「左边留白略大、右边留白略小」。所以这里**故意不再对 labelX 取整**：
    //    一取整又会把差值搬回来。文字用亚像素定位是 iOS 常态，不会有观感问题。
    CGFloat free = bounds.size.width - iconSize.width - labelSize.width;
    CGFloat left = free >= RKVoiceGroupGap ? round((free - RKVoiceGroupGap) * 0.5) : 0.0;
    CGFloat labelX = bounds.size.width - left - labelSize.width;
    if (labelX < left + iconSize.width)                 // 极端窄(换机型/超大字号)：绝不重叠
        labelX = left + iconSize.width;

    icon.frame = CGRectMake(left,
        round((bounds.size.height - iconSize.height) * 0.5),
        iconSize.width, iconSize.height);
    label.frame = CGRectMake(labelX,
        round((bounds.size.height - labelSize.height) * 0.5),
        labelSize.width, labelSize.height);
}

#pragma mark - 目标宽度

// 方钮是正方形 ⇒「一格」= 它的高（也是它的自然宽），实测 34pt。
// 目标 = 3.5 格（119pt）：3 格（102pt）实机排版偏紧（左右各仅剩 ~8pt，图标+文字
// 几乎顶格），3.5 格留白舒展且仍与同排其他按钮齐平；再长（4 格以上）就会明显出挑。
// 「一格」从同排方钮实测采样，换机型/字号自动跟随；采不到时用实测的 34pt 兜底。
static CGFloat const RKVoiceTargetUnits = 3.5;
static CGFloat RKVoiceUnitWidth = 0;

#pragma mark - 整排居中（让语音按钮落在屏幕正中）

// 递归找语音按钮。**判据仍是唯一的 func == 1**：找不到就说明这不是键盘工具栏
// （例如「剪贴板/常用语」那个面板的工具栏里没有 func=1），此时一个像素都不动。
static WBToolBarButton *RKVoiceFindVoiceButton(UIView *root) {
    if (RKVoiceIsVoiceButton(root)) return (WBToolBarButton *)root;
    for (UIView *sub in root.subviews) {
        WBToolBarButton *hit = RKVoiceFindVoiceButton(sub);
        if (hit) return hit;
    }
    return nil;
}

// 容器内部那颗滚动视图（按钮全在里面）。ivar 名已从二进制确认（_scrollView, UIScrollView）。
// 用 object_getIvar 而不是 KVC：没有字符串查找、不会抛异常，第一次解析出 ivar 后复用。
static Ivar RKVoiceScrollerIvar;

static UIScrollView *RKVoiceInternalScrollView(UIView *bar) {
    if (!RKVoiceScrollerIvar) {
        RKVoiceScrollerIvar = class_getInstanceVariable(object_getClass(bar), "_scrollView");
        if (!RKVoiceScrollerIvar) return nil;
    }
    id view = object_getIvar(bar, RKVoiceScrollerIvar);
    return [view isKindOfClass:[UIScrollView class]] ? (UIScrollView *)view : nil;
}

// 基准 origin.x：第一次记下后固定使用。宿主给这颗滚动视图设的 frame 就是容器的 bounds
//（见文件头反汇编依据），原点恒等于容器 bounds 原点，所以这个基准不会随按钮增减变化。
static char RKVoiceScrollerBaseXKey;

static void RKVoiceCenterInScreen(UIView *bar) {
    if (!RKVoiceWidenEnabled()) return;

    UIScrollView *scroller = RKVoiceInternalScrollView(bar);
    if (!scroller) return;                    // 拿不到内容容器就一个像素都不动（fail-safe）

    CGRect frame = scroller.frame;
    if (frame.size.width <= 0 || frame.size.height <= 0) return;   // 宿主还没办过布局

    NSNumber *baseValue = objc_getAssociatedObject(scroller, &RKVoiceScrollerBaseXKey);
    CGFloat baseX;
    if (baseValue) {
        baseX = (CGFloat)baseValue.doubleValue;
    } else {
        baseX = CGRectGetMinX(frame);
        objc_setAssociatedObject(scroller, &RKVoiceScrollerBaseXKey,
            @(baseX), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 先把上一轮的位移摆回去再测量：否则同一轮里第二次调用量到的中心已含位移，越移越偏。
    if (fabs(frame.origin.x - baseX) > 0.01) {
        frame.origin.x = baseX;
        scroller.frame = frame;
    }

    WBToolBarButton *voice = RKVoiceFindVoiceButton(bar);   // 判据只有 func == 1，见上
    if (!voice) return;                                     // 面板里没有语音按钮 ⇒ 一点都不动

    // 自检：语音按钮必须真的在这颗滚动视图里，平移它才有意义。反汇编确认所有功能按钮
    // 都是 [self->_scrollView addSubview:] 挂进去的；万一微信日后改了层级，这里就不动。
    BOOL insideScroller = NO;
    for (UIView *holder = voice; holder && holder != bar; holder = holder.superview) {
        if (holder == (UIView *)scroller) { insideScroller = YES; break; }
    }
    if (!insideScroller) return;

    // 屏幕宽度取窗口；窗口尚未挂上时退回 UIScreen（同一台设备两者一致）。
    UIWindow *win = bar.window;
    CGFloat screenW = win ? win.bounds.size.width : UIScreen.mainScreen.bounds.size.width;
    if (screenW <= 0) return;

    // 屏幕中心与本按钮中心都换算到容器坐标系再相减（跨坐标系直接比 origin 是 2.3.4 的坑）。
    CGPoint screenMidInBar = [bar convertPoint:CGPointMake(screenW * 0.5, 0) fromView:nil];
    CGPoint voiceMidInBar = [voice convertPoint:CGPointMake(CGRectGetMidX(voice.bounds), 0)
                                         toView:bar];
    CGFloat dx = screenMidInBar.x - voiceMidInBar.x;

    // 已经居中就别写 frame：少一次无谓的图层几何更新（也就是少一分卡顿）。
    if (fabs(dx) < 0.5) return;

    frame = scroller.frame;
    frame.origin.x = baseX + dx;              // origin 增大 ⇒ 内容右移，故直接加 dx
    scroller.frame = frame;
}

#pragma mark - 语音按钮底色

// 最终像素值（三张截图扫描所得）：
//   暗色 #505050 = 用户点名的「常用语那一档」（现在语音胶囊是 #5B5B5B，偏亮、发闷）；
//   亮色 #F3F3F5 = 按「暗色那档相对键盘底 #323232 的对比度」同比推出的亮色对应值
//                 （亮色键盘底 #DFE0E4、按钮实测 #FAFAFB，大色块看着发白）。
static UIColor *RKVoiceBackgroundColor(BOOL dark) {
    if (dark) return [UIColor colorWithRed:0.31373 green:0.31373 blue:0.31373 alpha:1.0];
    return [UIColor colorWithRed:0.95294 green:0.95294 blue:0.96078 alpha:1.0];
}

#pragma mark - 每轮布局的唯一入口

// 一次身份判断 + 一次偏好读取，然后分发到「底色」与「排布」两件事。
static void RKVoiceApplyAll(WBToolBarButton *button) {
    if (!RKVoiceIsVoiceButton(button)) return;   // 零开销判身份，非语音按钮立即返回
    if (!RKVoiceWidenEnabled()) return;          // 偏好入口要拿锁，每轮只读这一次

    BOOL dark = (button.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIColor *bg = RKVoiceBackgroundColor(dark);
    // 颜色没变就不写，避免每次布局都触发一轮重绘。
    if (![button.backgroundColor isEqual:bg]) button.backgroundColor = bg;

    RKVoiceArrangeContent(button);
}

#pragma mark - Hook

%group RKVoiceGroup
%hook WBToolBarButton

- (CGSize)sizeThatFits:(CGSize)size {
    CGSize natural = %orig;

    // 顺序同上：先判身份(零开销)再读偏好。采样只写一个 static 浮点、零分配，
    // 关掉开关时这个值也不会被任何分支用到，所以放在身份判断之后更省。
    if (!RKVoiceIsVoiceButton(self)) {
        // 顺手采样「一个方钮」的宽度。上限 80 是为了滤掉「最近使用」胶囊(91.33)
        // 这类非方钮，避免把基准采歪。
        if (natural.width >= 18 && natural.width <= 80) RKVoiceUnitWidth = natural.width;
        return natural;
    }
    if (!RKVoiceWidenEnabled()) return natural;

    RKVoiceApplyDescIfNeeded(self);
    CGFloat unit = RKVoiceUnitWidth > 0 ? RKVoiceUnitWidth : 34;
    return CGSizeMake(round(RKVoiceTargetUnits * unit), natural.height);
}

// 微信原生的 desc 排布在加宽后会把图标与文字摆重叠（见文件头），所以在它算完之后
// 接管这两个 frame —— 这是唯一被我们改动的原生布局点。底色也在这里落（同一轮、同一判据）。
- (void)layoutSubviews {
    %orig;
    RKVoiceApplyAll(self);
}

%end

%hook WBFunctionToolBar

// 这里才是微信真正摆按钮的地方（-layoutSubviews 内部就是调它）。挂在 %orig 之后，
// 保证「按钮位置已经定下来」再平移；入参与回调原样透传（%orig 转发全部参数），
// 不改它任何行为，也不碰容器的 transform / frame。
- (void)layoutForAnimated:(BOOL)animated animateFinishedBlock:(void (^)(void))block {
    %orig;
    RKVoiceCenterInScreen(self);
}

// 兜底：-layoutSubviews 的后半段还有「语音聚焦」收尾逻辑，可能再动一次布局，
// 所以最后再对齐一次（函数本身幂等，且值没变不会写 frame）。
- (void)layoutSubviews {
    %orig;
    RKVoiceCenterInScreen(self);
}

%end
%end

%ctor {
    // 只在微信输入法扩展里生效；注入到系统键盘(InputUI)时这些类不存在，直接跳过。
    if (objc_getClass("WBToolBarButton")) {
        %init(RKVoiceGroup);
    }
}
