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

// 进程守卫（2.3.17）：本插件只服务「系统键盘(InputUI)」与「微信输入法(wxkb_plugin)」，
// 正常由注入过滤（Filter/Executables）保证。但越狱环境里过滤器未必总被尊重
//（本项目已出现过 Choicy 选择性注入在 ElleKit 下失效的先例），所以再兜一层**黑名单**：
// 一旦被注入到 SpringBoard / backboardd 这类系统 UI 进程，所有钩子一律放行。
// 采用「只黑名单、不白名单」是为避免判据过严反而把功能挡掉（误伤的代价更大）。
// 结果 dispatch_once 缓存：进程身份在生命周期内不变。
FOUNDATION_EXPORT BOOL RKKeyboardProcessIsSystemUI(void);

// 「当前进程是不是微信输入法」：bundle 判断做一次性缓存（原来是每次调用都做
// mainBundle 取值 + lowercaseString + containsString，位于按键/绘制热路径上）。
FOUNDATION_EXPORT BOOL RKKeyboardBundleIsWeType(void);
