#import "RKKeyboardGeometry.h"
#import "RainbowEffectView.h"
#import "RKPreferences.h"
#import <objc/runtime.h>
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
static BOOL RKKeyboardSessionActiveValue;
void RKKeyboardSessionSetActive(BOOL active) {
    RKKeyboardSessionActiveValue = active;
}
BOOL RKKeyboardSessionActive(void) { return RKKeyboardSessionActiveValue; }

// addObserverForName 返回的 observer token 必须被持有，否则 ARC 下立即释放、
// 通知注册随之失效（iOS 经典坑）。此前的实现丢弃了 token，导致会话开关
// 永远收不到 UIKeyboardWillShow，所有装饰钩子持续短路 —— 键盘无光效。
static id RKKeyboardSessionObserverTokens[3];

__attribute__((constructor))
static void RKKeyboardSessionInstallObservers(void) {
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

static NSMapTable *RKGetterSignatureCache(void) {
    static NSMapTable *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality | NSPointerFunctionsWeakMemory
                                      valueOptions:NSPointerFunctionsStrongMemory];
    });
    return cache;
}

// 对 (Class, selector) 一次性判定 ABI 兼容性并缓存签名，避免每次调用重复
// respondsToSelector / methodSignatureForSelector 的运行时查找。
static NSMethodSignature *RKGetterSignature(Class cls, NSString *name, const char *type) {
    NSMutableDictionary *byName = [RKGetterSignatureCache() objectForKey:cls];
    if (!byName) {
        byName = [NSMutableDictionary dictionary];
        [RKGetterSignatureCache() setObject:byName forKey:cls];
    }
    id signature = byName[name];
    if (signature) return signature == NSNull.null ? nil : signature;
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *candidate = nil;
    if ([cls instancesRespondToSelector:selector]) {
        candidate = [cls instanceMethodSignatureForSelector:selector];
        if (candidate && (candidate.numberOfArguments != 2 || strcmp(candidate.methodReturnType, type)))
            candidate = nil;
    }
    byName[name] = candidate ?: NSNull.null;
    return candidate;
}

// Private selectors vary by OS release. Validate their ABI before invoking them.
static NSInvocation *RKGetter(id object, NSString *name, const char *type) {
    // 注意：不能用点语法 object.class —— id 类型上编译器会做属性查找而报错；
    // 消息发送 [object class] 对 id 永远合法且语义一致。
    NSMethodSignature *signature = RKGetterSignature([object class], name, type);
    if (!signature) return nil;
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = object;
    call.selector = NSSelectorFromString(name);
    [call invoke];
    return call;
}

static id RKObject(id object, NSString *name) {
    NSInvocation *call = RKGetter(object, name, @encode(id));
    __unsafe_unretained id result = nil;
    [call getReturnValue:&result];
    return result;
}

static CGRect RKRect(id object, NSString *name) {
    NSInvocation *call = RKGetter(object, name, @encode(CGRect));
    CGRect result = CGRectZero;
    [call getReturnValue:&result];
    return result;
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
            BOOL ghost = NO;
            NSInvocation *visibility = RKGetter(key, @"ghost", @encode(BOOL));
            [visibility getReturnValue:&ghost];
            if (ghost) continue;
            BOOL visible = YES;
            NSInvocation *visibleGetter = RKGetter(key, @"visible", @encode(BOOL));
            [visibleGetter getReturnValue:&visible];
            if (!visible) continue;
            CGRect rect = RKRect(key, @"displayFrame");
            if (!RKValidKeyRect(rect, host.bounds)) rect = RKRect(key, @"frame");
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
BOOL RKKeyboardLayoutChanged(UIView *host) {
    id plane = RKObject(host, @"keyplane");
    id keys = nil;
    if (plane) keys = RKObject(plane, @"keys");
    static char RKLayoutObservationKey;
    NSDictionary *current = @{
        @"plane": plane ?: NSNull.null,
        @"keys": keys ?: NSNull.null,
        @"bounds": [NSValue valueWithCGRect:host.bounds],
    };
    NSDictionary *previous = objc_getAssociatedObject(host, &RKLayoutObservationKey);
    BOOL changed = !previous ||
        previous[@"plane"] != current[@"plane"] ||
        previous[@"keys"] != current[@"keys"] ||
        !CGRectEqualToRect([previous[@"bounds"] CGRectValue], host.bounds);
    objc_setAssociatedObject(host, &RKLayoutObservationKey, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return changed;
}
