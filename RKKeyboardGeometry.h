#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSArray<NSValue *> *RKKeyboardKeyFrames(UIView *host);
FOUNDATION_EXPORT UIBezierPath *RKKeyboardKeyFacePath(CGRect keyFrame);
FOUNDATION_EXPORT BOOL RKKeyboardExcludedView(UIView *view);
FOUNDATION_EXPORT UIView *RKKeyboardEffectHost(UIView *view);

// ---- 性能优化（视觉零变化）----

// 类名特征位掩码：对每个 Class 只做一次字符串分析，之后查表复用。
// 覆盖键盘排除区、宿主查找、键位递归识别等全部调用点。
typedef NS_OPTIONS(NSUInteger, RKClassNameFeatures) {
    RKFeatureNone           = 0,
    RKFeatureKeycap         = 1 << 0, // 类名含 "keycap"
    RKFeatureKeyview        = 1 << 1, // 类名含 "keyview"
    RKFeatureKeybutton      = 1 << 2, // 类名含 "keybutton"
    RKFeatureSuffixKey      = 1 << 3, // 类名以 "key" 结尾
    RKFeatureExcluded       = 1 << 4, // 候选/预测/建议/工具条/配件/剪贴板/快捷/弹出/编辑条等排除区
    RKFeatureLayoutStar     = 1 << 5, // 类名含 "keyboardlayoutstar"
    RKFeatureInputContainer = 1 << 6, // inputset/itemcontainer/trackingwindow/placeholder/compatinput
    RKFeatureKeyboardish    = 1 << 7, // 类名含 "keyboard" 或 "keyplane"
    RKFeatureCandidateUI    = 1 << 8, // 原生候选/预测视图（UIKB*/TUI*/_UIKeyboardCandidate 前缀族）
    RKFeatureCandidateArea  = 1 << 9, // 仅 candidate/prediction/suggestion 子串（候选文字区域，不含工具条）
};
FOUNDATION_EXPORT NSUInteger RKClassFeatures(Class cls);

// 键盘布局是否发生变化：keyplane / keys 指针或 host.bounds 任一变化返回 YES。
// 布局未变时调用方应复用既有 keyFrames，避免定时全量扫描。
FOUNDATION_EXPORT BOOL RKKeyboardLayoutChanged(UIView *host);

// 键盘会话状态：WillShow 置 YES，DidHide / 退后台置 NO。
// 供全局 UIKit 钩子做快速短路，键盘未显示时不承担装饰开销。
FOUNDATION_EXPORT void RKKeyboardSessionSetActive(BOOL active);
FOUNDATION_EXPORT BOOL RKKeyboardSessionActive(void);

// ---- 精确命中注册表（2.0.0）----
// RKKeyboardHooks.xm 对微信键盘（WBKeyboardView / WBKeyView 及其子类）与原生键盘
// （UIKeyboardLayoutStar / UIKBKeyView）按确切类注册宿主与键帽。命中注册表时
// 宿主查找与键位收集零遍历；未注册的键盘走原有类名特征扫描兜底。
FOUNDATION_EXPORT void RKRegisterKeyboardHost(UIView *host);
FOUNDATION_EXPORT void RKRegisterKeyboardBody(UIView *body);
FOUNDATION_EXPORT void RKRegisterKeyView(UIView *keyView);
FOUNDATION_EXPORT void RKRegisterCandidateContainer(UIView *container);

// ---- 布局代际戳（2.1.4，回归上游 1.2.1 机制）----
// WeType 键盘切换布局（九键 ↔ 全键盘 / 中英）时两套键帽的视图都保持注册，切换只是
// 复用已注册键帽——没有新注册事件、注册数不动、keyplane/keys 指针与 bounds 也常常
// 不变（上游 1.2.0 的 17.9 教训）。host 的 layout pass 是每次布局切换必然出现的唯一
// 事件：RKRegisterKeyboardHost 在宿主布局钩子里递增 stamp，调用方发现 stamp 变化即
// 强制重收键位帧，不依赖任何"看起来变了"的启发式判定。
FOUNDATION_EXPORT uint64_t RKKeyboardLayoutStamp(void);
FOUNDATION_EXPORT NSUInteger RKRegisteredKeyCount(void);

// 注册表键帽查帧：在已登记键帽（弱引用集）里找与 hostFrame 匹配的键视图，
// 容差与 RKNeonPress 的递归兜底一致（origin ±3pt、尺寸 ±4pt）。零递归。
FOUNDATION_EXPORT UIView *RKKeyboardRegisteredKeyViewAtFrame(UIView *host, CGRect frameInHost);
