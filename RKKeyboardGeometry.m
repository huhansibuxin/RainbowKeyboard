#import "RKKeyboardGeometry.h"
#import "RainbowEffectView.h"
#import "RKPreferences.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

#pragma mark - 类名特征缓存（P0-1：每个 Class 只做一次字符串分析）

static NSMapTable *RKFeatureCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

NSUInteger RKClassFeatures(Class cls) {
    NSNumber *cached = [RKFeatureCache() objectForKey:cls];
    if (cached) return cached.unsignedIntegerValue;
    NSString *name = NSStringFromClass(cls).lowercaseString;
    NSUInteger features = RKFeatureNone;
    if ([name containsString:@"keycap"]) features |= RKFeatureKeycap;
    if ([name containsString:@"keyview"]) features |= RKFeatureKeyview;
    if ([name containsString:@"keybutton"]) features |= RKFeatureKeybutton;
    if ([name hasSuffix:@"key"]) features |= RKFeatureSuffixKey;
    for (NSString *part in @[@"candidate", @"prediction", @"suggestion", @"toolbar",
                             @"accessory", @"dock", @"clipboard", @"shortcut", @"popup", @"editingbar"])
        if ([name containsString:part]) { features |= RKFeatureExcluded; break; }
    for (NSString *part in @[@"candidate", @"prediction", @"suggestion"])
        if ([name containsString:part]) { features |= RKFeatureCandidateArea; break; }
    if ([name containsString:@"keyboardlayoutstar"]) features |= RKFeatureLayoutStar;
    for (NSString *part in @[@"inputset", @"itemcontainer", @"trackingwindow", @"placeholder", @"compatinput"])
        if ([name containsString:part]) { features |= RKFeatureInputContainer; break; }
    if ([name containsString:@"keyboard"] || [name containsString:@"keyplane"]) features |= RKFeatureKeyboardish;
    if (([name hasPrefix:@"uikb"] && [name containsString:@"candidate"]) ||
        [name hasPrefix:@"uikeyboardcandidate"] || [name hasPrefix:@"tuicandidate"] ||
        [name hasPrefix:@"tuiinlinecandidate"] || [name hasPrefix:@"tuiprediction"] ||
        [name hasPrefix:@"uikeyboardprediction"] || [name hasPrefix:@"_uikeyboardcandidate"])
        features |= RKFeatureCandidateUI;
    [RKFeatureCache() setObject:@(features) forKey:cls];
    return features;
}

#pragma mark - 键盘会话状态（P0-3：全局钩子快速短路开关）

// Always clear decoration session state on hide/background. Retaining this
// flag cannot keep an extension alive or prevent a system termination.
// 2.3.22：去掉 static —— 读取端已移到头文件做成 static inline 直读本变量，
// 避免热路径上每个绘制钩子都付一次跨编译单元函数调用（本项目不开 LTO）。
volatile BOOL RKKeyboardSessionActiveValue;
void RKKeyboardSessionSetActive(BOOL active) {
    RKKeyboardSessionActiveValue = active;
}

// 进程守卫：见头文件说明。只黑名单「系统 UI 进程」，其余一律放行，
// 避免判据过严反而把键盘进程里的功能挡掉（误伤的代价更大）。
BOOL RKKeyboardProcessIsSystemUI(void) {
    static BOOL systemUI;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier.lowercaseString ?: @"";
        NSString *process = NSProcessInfo.processInfo.processName.lowercaseString ?: @"";
        systemUI = [bundle isEqualToString:@"com.apple.springboard"]
            || [bundle isEqualToString:@"com.apple.backboardd"]
            || [process isEqualToString:@"springboard"]
            || [process isEqualToString:@"backboardd"];
    });
    return systemUI;
}

// 「当前进程是不是微信输入法」：进程身份在生命周期内不变，缓存一次。
// 老写法每处调用都要 mainBundle 取值 + lowercaseString + containsString（每次都新建字符串），
// 而它挂在「每次按键」与「每次候选文字绘制」的路径上 —— 属于纯白烧的分配。
BOOL RKKeyboardBundleIsWeType(void) {
    static BOOL weType;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        weType = [NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"];
    });
    return weType;
}

// addObserverForName 返回的 observer token 必须被持有，否则 ARC 下立即释放、
// 通知注册随之失效（iOS 经典坑）。此前的实现丢弃了 token，导致会话开关
// 永远收不到 UIKeyboardWillShow，所有装饰钩子持续短路 —— 键盘无光效。
static id RKKeyboardSessionObserverTokens[3];

__attribute__((constructor))
static void RKKeyboardSessionInstallObservers(void) {
    // 系统 UI 进程（SpringBoard / backboardd）里会话判定毫无意义 —— 那里没有键盘装饰，
    // 锁屏/桌面的任何绘制都不该走进本插件的路径。连观察者都不注册，彻底不参与。
    if (RKKeyboardProcessIsSystemUI()) return;
    RKKeyboardSessionObserverTokens[0] = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIKeyboardWillShowNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        RKKeyboardSessionSetActive(YES);
    }];
    RKKeyboardSessionObserverTokens[1] = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIKeyboardDidHideNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        RKKeyboardSessionSetActive(NO);
    }];
    RKKeyboardSessionObserverTokens[2] = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidEnterBackgroundNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        RKKeyboardSessionSetActive(NO);
    }];
}

#pragma mark - 排除区 / 键盘宿主判定（P0-1 + P1-5 宿主缓存）

BOOL RKKeyboardExcludedView(UIView *view) {
    if ((RKClassFeatures(view.class) & RKFeatureExcluded) != 0) return YES;
    return [view isKindOfClass:RainbowEffectView.class];
}

static char RKHostSuperviewKey;
static NSMapTable *RKHostCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory];
    });
    return cache;
}

static void RKCacheEffectHost(UIView *view, UIView *host) {
    [RKHostCache() setObject:host forKey:view];
    // 只做指针比较用，不 retain；视图存活期间其父视图必然存活。
    objc_setAssociatedObject(view, &RKHostSuperviewKey,
        [NSValue valueWithNonretainedObject:view.superview], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

UIView *RKKeyboardEffectHost(UIView *view) {
    UIView *cached = [RKHostCache() objectForKey:view];
    NSValue *superviewValue = objc_getAssociatedObject(view, &RKHostSuperviewKey);
    if (cached && cached.window && superviewValue &&
        superviewValue.nonretainedObjectValue == view.superview) return cached;

    UIView *fallback = nil;
    for (UIView *parent = view; parent && ![parent isKindOfClass:UIWindow.class]; parent = parent.superview) {
        if (RKKeyboardExcludedView(parent)) return nil;
        NSUInteger features = RKClassFeatures(parent.class);
        if (features & RKFeatureLayoutStar) { RKCacheEffectHost(view, parent); return parent; }
        // Remote input containers also contain the dock, not just key rows.
        if (features & RKFeatureInputContainer) break;
        if (!fallback && (features & RKFeatureKeyboardish) &&
            parent.bounds.size.width > 180 && parent.bounds.size.height > 100 && parent.bounds.size.height < 500)
            fallback = parent;
    }
    if (fallback) RKCacheEffectHost(view, fallback);
    return fallback;
}

#pragma mark - 键帽路径

UIBezierPath *RKKeyboardKeyFacePath(CGRect keyFrame) {
    CGRect face = CGRectInset(keyFrame, MIN(2.5, keyFrame.size.width * .065), 2);
    CGFloat corner = MIN(5, MIN(face.size.width, face.size.height) * .16);
    return [UIBezierPath bezierPathWithRoundedRect:face cornerRadius:corner];
}

#pragma mark - 私有 getter（P1-2：缓存 selector 可用性与签名）

static NSMapTable *RKGetterCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

// 对 (Class, selector) 一次性判定 ABI 兼容性并缓存**选择子**，避免每次调用都要走
// respondsToSelector / methodSignatureForSelector；调用方拿到 SEL 后直接消息发送。
static SEL RKGetterSelector(Class cls, NSString *name, const char *type) {
    NSMutableDictionary *byName = [RKGetterCache() objectForKey:cls];
    if (!byName) {
        byName = [NSMutableDictionary dictionary];
        [RKGetterCache() setObject:byName forKey:cls];
    }
    id cached = byName[name];
    if (cached) return cached == NSNull.null ? NULL : (SEL)[(NSValue *)cached pointerValue];
    SEL selector = NSSelectorFromString(name);
    SEL result = NULL;
    if ([cls instancesRespondToSelector:selector]) {
        NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:selector];
        if (signature && signature.numberOfArguments == 2 && !strcmp(signature.methodReturnType, type))
            result = selector;
    }
    // 缓存的是**选择子**（不兼容记为 NSNull），而不是 NSInvocation —— 见下方说明。
    byName[name] = result ? [NSValue valueWithPointer:(void *)result] : (id)NSNull.null;
    return result;
}

// 私有选择子随系统版本变化，调用前必须校验 ABI（由 RKGetterSelector 缓存判定结果）。
// 校验通过后**直接消息发送**，不再构造 NSInvocation：
// 老写法每次调用都要 new 一个 NSInvocation 并封送参数，而这两条读取在热路径上极频繁 ——
// 每次按键读 2 次（keyplane/keys），每 0.2 秒的全量扫描按「每键 3 次」调用
//（ghost/visible/displayFrame，30 键即 90 次）⇒ 每秒上百个 NSInvocation。
// 这里仍走 objc_msgSend 而不是缓存 IMP 直跳，是为了保留消息转发 / swizzle 语义，
// 只把最贵的「对象分配 + 参数封送」去掉，行为与老实现逐位一致。
static id RKObject(id object, NSString *name) {
    if (!object) return nil;
    // 注意：不能用点语法 object.class —— id 类型上编译器会做属性查找而报错；
    // 消息发送 [object class] 对 id 永远合法且语义一致。
    SEL selector = RKGetterSelector([object class], name, @encode(id));
    return selector ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static CGRect RKRect(id object, NSString *name) {
    if (!object) return CGRectZero;
    SEL selector = RKGetterSelector([object class], name, @encode(CGRect));
    return selector ? ((CGRect (*)(id, SEL))objc_msgSend)(object, selector) : CGRectZero;
}

// fallback 必须显式传入：老实现里 `.ghost` 取不到按 NO、`.visible` 取不到按 YES，
// 语义不同，不能用一个默认值糊过去。
static BOOL RKFlag(id object, NSString *name, BOOL fallback) {
    if (!object) return fallback;
    SEL selector = RKGetterSelector([object class], name, @encode(BOOL));
    return selector ? ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) : fallback;
}

#pragma mark - 键位几何（P1-1：布局变化检测）

static BOOL RKValidKeyRect(CGRect rect, CGRect bounds) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height) &&
        rect.size.width >= 10 && rect.size.height >= 14 &&
        rect.size.width <= bounds.size.width * .9 &&
        rect.size.height <= MIN(120, bounds.size.height * .6) &&
        CGRectContainsRect(CGRectInset(bounds, -1, -1), rect);
}

static void RKAddKey(NSMutableArray<NSValue *> *frames, CGRect rect, CGRect bounds) {
    if (!RKValidKeyRect(rect, bounds)) return;
    for (NSValue *value in frames) {
        CGRect other = value.CGRectValue;
        if (fabs(other.origin.x - rect.origin.x) < 1 && fabs(other.origin.y - rect.origin.y) < 1 &&
            fabs(other.size.width - rect.size.width) < 1 && fabs(other.size.height - rect.size.height) < 1) return;
    }
    if (frames.count < 100) [frames addObject:[NSValue valueWithCGRect:rect]];
}

static void RKViewKeys(UIView *node, UIView *host, NSMutableArray *frames, NSUInteger depth) {
    if (depth > 12 || frames.count >= 100) return;
    for (UIView *view in node.subviews) {
        if (view.hidden || view.alpha < .01 || RKKeyboardExcludedView(view)) continue;
        NSUInteger features = RKClassFeatures(view.class);
        BOOL key = [view isKindOfClass:UIButton.class] ||
            (features & (RKFeatureKeycap | RKFeatureKeyview | RKFeatureKeybutton)) != 0;
        CGRect rect = [view convertRect:view.bounds toView:host];
        if (key && RKValidKeyRect(rect, host.bounds)) RKAddKey(frames, rect, host.bounds);
        else RKViewKeys(view, host, frames, depth + 1);
    }
}

NSArray<NSValue *> *RKKeyboardKeyFrames(UIView *host) {
    NSMutableArray *frames = [NSMutableArray array];
    id plane = RKObject(host, @"keyplane");
    id keys = RKObject(plane, @"keys");
    if ([keys isKindOfClass:NSArray.class] || [keys isKindOfClass:NSSet.class]) {
        for (id key in keys) {
            // 取不到时保持老实现的默认值：ghost 按 NO、visible 按 YES（两种都保留该键）。
            if (RKFlag(key, @"ghost", NO)) continue;
            if (!RKFlag(key, @"visible", YES)) continue;
            CGRect rect = RKRect(key, @"displayFrame");
            UIView *keyplaneView = [plane isKindOfClass:UIView.class] ? plane : nil;
            if (keyplaneView) rect = [keyplaneView convertRect:rect toView:host];
            if (!RKValidKeyRect(rect, host.bounds)) {
                rect = RKRect(key, @"frame");
                if (keyplaneView) rect = [keyplaneView convertRect:rect toView:host];
            }
            RKAddKey(frames, rect, host.bounds);
        }
    }
    if (frames.count < 3) {
        [frames removeAllObjects];
        RKViewKeys(host, host, frames, 0);
    }
    return frames;
}

// keyplane / keys 指针与 bounds 均未变化时返回 NO，调用方直接复用缓存的键位集合。
// 快照用一块「按 host 一次性分配」的裸结构，只存**非持有**指针做相等比较：
//   ① 老实现每次调用都构造 NSDictionary + NSValue 再写关联对象（每按键 4 次堆分配）；
//   ② 那个 NSDictionary 会**强引用** keyplane / keys —— 无谓延长键盘内部对象寿命。
// 现在每次调用只剩两次选择子缓存读取 + 几次指针比较，零分配。
typedef struct {
    __unsafe_unretained id plane;
    __unsafe_unretained id keys;
    CGRect bounds;
} RKKeyboardLayoutSnapshot;

BOOL RKKeyboardLayoutChanged(UIView *host) {
    static char RKLayoutSnapshotKey;
    id plane = RKObject(host, @"keyplane");
    id keys = plane ? RKObject(plane, @"keys") : nil;
    NSValue *boxed = objc_getAssociatedObject(host, &RKLayoutSnapshotKey);
    RKKeyboardLayoutSnapshot *snapshot = boxed ? (RKKeyboardLayoutSnapshot *)boxed.pointerValue : NULL;
    if (!snapshot) {
        snapshot = calloc(1, sizeof(RKKeyboardLayoutSnapshot));
        if (!snapshot) return YES;                 // 极罕见：分配失败就当作「已变化」保守处理
        objc_setAssociatedObject(host, &RKLayoutSnapshotKey, [NSValue valueWithPointer:snapshot],
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        snapshot->plane = plane;
        snapshot->keys = keys;
        snapshot->bounds = host.bounds;
        return YES;
    }
    CGRect bounds = host.bounds;
    BOOL changed = snapshot->plane != plane || snapshot->keys != keys ||
        !CGRectEqualToRect(snapshot->bounds, bounds);
    snapshot->plane = plane;
    snapshot->keys = keys;
    snapshot->bounds = bounds;
    return changed;
}
