#import <Foundation/Foundation.h>
#import "RKCandidateTransport.h"
#import "RKKeyboardColors.h"
#import "RKDisplayTransport.h"

static NSString * const RKPreferencesPath = @"/var/mobile/Library/Preferences/com.minis.rainbowkeyboard.plist";
static CFStringRef const RKPreferencesDomain = CFSTR("com.minis.rainbowkeyboard");

// 自用固化表：注销/重启后 notifyd 状态清空，键盘进程(InputUI/wxkb_plugin, 沙盒)又读不到
// /var/mobile/Library/Preferences 下的 plist，此时用它兜底，使回落值 = 用户当前配置
// （光效风格=扩散 / 候选栏渐变=关 / 全部高级参数），而非出厂回落值。
// 单一入口：键盘渲染层(RainbowEffectView)与候选渐变层(CandidateGradient)都经
// RKReadEffectivePreferences() 取值，故只需在这一个点兜底即可全覆盖。
// 取值 = 设备 plist 2026-09-28 实时值，逐项照抄不做取整。
static inline NSDictionary *RKPresetSelfUseTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"Opacity": @(0.7991349101066589),
            @"Brightness": @(1.0),
            @"NeonSaturation": @(0.7006920576095581),
            @"Duration": @(0.45),
            @"Spread": @(2.25),
            @"Softness": @(7.0),
            @"CoreStrength": @(0.62),
            @"MaxEffects": @(6.0),
            @"AmbientStrength": @(0.85),
            @"BackgroundStrength": @(0.24),
            @"BackgroundDuration": @(0.4),
            @"BackgroundRadius": @(100.65743255615234),
            @"BackgroundBand": @(0.29783737659454346),
            @"ColorMode": @(0.0),
            @"Hue": @(0.32814300060272217),
            @"EffectStyle": @(1.0),
            @"Preset": @(-1.0),
            @"CandidateGradient": @(0),
            // 子开关「缺失即开」（2026-09-30 由 0 修正为 1）：总闸判据是
            // `总开关 && (原生 || WeType)`。此处若兜底为 0，用户打开总开关后
            // 两个子开关仍取到 0 → 总闸恒不成立 → 表现为"开了完全没效果"。
            @"CandidateNative": @(1),
            @"CandidateWeType": @(1),
            // 纯黑键帽引擎（RKBlackKeyboardHost 已为空实现）已移除：此键无设置入口、
            // 无渲染消费方，仅作为跨进程位协议字段保留，勿删（位序对齐）。
            @"PureBlackKeyboard": @(0),
            @"Enabled": @(1),
            @"NativeKeyboard": @(0),
            @"WeChatKeyboard": @(1),
            @"RippleEnabled": @(1),
            // 轻弹（键帽上色）自 2.3.24 起是独立开关，可与光效风格同时开；默认关，
            // 与 1.6.0 的 LightPop 一致（键帽快照有额外开销，由用户显式开启）。
            @"LightPop": @(0),
            // 轻弹配色是否跟随键底光效（默认跟随，两种效果同色；关掉则用轻弹自己的取色）。
            @"LightPopMatchColor": @(1),
            // 跟随系统深浅色（2.3.27 新增，默认关）：开启后浅色模式用轻弹、深色模式自动关掉
            // 轻弹只留键底光效。深色下的关闭是渲染时合成的，不改动 LightPop 的存储值，
            // 因此切回浅色会自动恢复用户原来的轻弹设置。
            @"LightPopFollowAppearance": @(0),
            @"PressColorMode": @(0),
            // 键帽上色亮度：2.3.24 由 0.9013840556144714（1.6.0 时代留下的默认）降到 0.6，
            // 原值在键帽上过亮。历史值由 RKNormalizeLegacyPreferences 一并折算。
            @"PressBrightness": @(0.6),
            @"SmartPerformance": @(0),
            @"Theme": @(0),
            @"CandidateStart": @[@(0.6627452373504639), @(0.40784311294555664), @(0.0)],
            @"CandidateEnd": @[@(0.803921639919281), @(0.9098039269447327), @(0.7098039984703064)],
            @"KeyboardBackgroundColor": @[@(0.7960782647132874), @(0.9411764740943909), @(0.9999999403953552)],
            @"KeycapColor": @[@(0.6941176056861877), @(0.5490196347236633), @(0.9960784316062927)],
            @"PressColor": @[@(0.4745098948478699), @(0.10196084529161453), @(0.2392156720161438)],
            // 2.3.4 新增功能开关，默认开（非设备快照项，是功能默认值）。
            // 键盘扩展沙盒读不到偏好文件时即由此兜底 → 默认生效。
            @"WidenVoiceButton": @(1),
        };
    });
    return table;
}

// 用固化表补齐缺失键：已解析出的值优先，缺失键回落到固化表。
// 注销后 stored/transport 皆空 → 全部键由固化表提供，键盘即按用户配置渲染。
static inline NSDictionary *RKApplySelfUseFallback(NSDictionary *values) {
    NSDictionary *table = RKPresetSelfUseTable();
    if (!table.count) return values ?: @{};
    NSMutableDictionary *merged = [table mutableCopy];
    if (values.count) [merged addEntriesFromDictionary:values];
    return merged;
}

// 2.3.24 旧档归一化：读时迁移、幂等、不写盘（键盘扩展沙盒写不了偏好文件；
// 设置页那边改动任意一项时，会把归一化后的字典自然落盘）。
//   一、「光效风格 = 轻弹」已废弃：轻弹拆成独立开关 LightPop，可与扩散/波纹/流光叠加。
//       旧档（EffectStyle == 2）迁移为「扩散(1) + 轻弹开」，升级前后观感一致。
//   二、键帽上色亮度：历史固化默认 0.9013840556144714 视为「从未自定义」，
//       折到新的 0.6；用户手动调过的其它值原样保留。
static inline NSDictionary *RKNormalizeLegacyPreferences(NSDictionary *values) {
    if (!values.count) return values ?: @{};
    id style = values[@"EffectStyle"];
    id pop = values[@"LightPop"];
    id press = values[@"PressBrightness"];
    BOOL legacyPop = [style isKindOfClass:NSNumber.class] && [style integerValue] == 2;
    BOOL legacyPress = [press isKindOfClass:NSNumber.class] &&
        fabs([press doubleValue] - 0.9013840556144714) < 1e-9;
    if (!legacyPop && !legacyPress) return values;
    NSMutableDictionary *migrated = [values mutableCopy];
    if (legacyPop) {
        migrated[@"EffectStyle"] = @(1);
        // 只在键缺失时补开：用户若已在新版本里显式关掉轻弹，尊重其选择。
        if (!pop) migrated[@"LightPop"] = @(1);
    }
    if (legacyPress) migrated[@"PressBrightness"] = @(0.6);
    return migrated;
}

static inline void RKRequestPreferencesRelay(void) {
    static NSLock *lock;
    static CFAbsoluteTime last;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    [lock lock];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    BOOL request = now - last > 1;
    if (request) last = now;
    [lock unlock];
    if (request) notify_post("com.minis.rainbowkeyboard.settings.request.v2");
}

static inline uint64_t RKPreferencesRevision(NSDictionary *values) {
    id revision = values[@"RKSettingsRevision"];
    return [revision isKindOfClass:NSNumber.class] ? [revision unsignedLongLongValue] : 0;
}

static inline NSDictionary *RKNewestPreferences(NSDictionary *file, NSDictionary *domain) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSDictionary *older = domain, *newer = file;
    if (RKPreferencesRevision(domain) > RKPreferencesRevision(file)) { older = file; newer = domain; }
    if (older) [result addEntriesFromDictionary:older];
    if (newer) [result addEntriesFromDictionary:newer];
    return result;
}

static NSUInteger RKStoredPreferenceReads;
static inline NSDictionary *RKReadStoredPreferences(void) {
    __atomic_add_fetch(&RKStoredPreferenceReads, 1, __ATOMIC_RELAXED);
    CFPreferencesAppSynchronize(RKPreferencesDomain);
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:RKPreferencesPath];
    NSDictionary *domain = CFBridgingRelease(CFPreferencesCopyMultiple(NULL, RKPreferencesDomain,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    return RKNewestPreferences(file, domain);
}

static inline int RKSettingsRevisionToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int t = -1;
        if (notify_register_check("com.minis.rainbowkeyboard.settings.revision.v1", &t) == NOTIFY_STATUS_OK) token = t;
    });
    return token;
}

static inline NSDictionary *RKResolvePreferences(NSDictionary *stored, NSDictionary *transport) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    if (RKPreferencesRevision(transport) > RKPreferencesRevision(stored)) {
        if (stored) [result addEntriesFromDictionary:stored];
        if (transport) [result addEntriesFromDictionary:transport];
    } else {
        if (transport) [result addEntriesFromDictionary:transport];
        if (stored) [result addEntriesFromDictionary:stored];
    }
    return result;
}

static inline NSDictionary *RKResolvePreferencesSnapshot(NSDictionary *stored, NSDictionary *transport,
                                                         uint64_t before, uint64_t after) {
    if (before != after || before == UINT64_MAX) {
        NSMutableDictionary *result = [stored mutableCopy] ?: [NSMutableDictionary dictionary];
        // Sandboxed keyboards may have no file access. Do not default gradients on mid-write.
        if (!result[@"CandidateGradient"]) result[@"CandidateGradient"] = @NO;
        return result;
    }
    NSMutableDictionary *committed = [transport mutableCopy] ?: [NSMutableDictionary dictionary];
    committed[@"RKSettingsRevision"] = @(before);
    return RKResolvePreferences(stored, committed);
}

static inline NSDictionary *RKReadUncachedEffectivePreferences(void) {
    NSDictionary *stored = RKReadStoredPreferences();
    static NSLock *lock;
    static NSDictionary *lastSnapshot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    NSDictionary *snapshot = RKReceiveDisplaySnapshot();
    [lock lock];
    if (snapshot && RKPreferencesRevision(snapshot) >= RKPreferencesRevision(lastSnapshot)) lastSnapshot = snapshot;
    NSDictionary *valid = lastSnapshot;
    [lock unlock];
    if (!snapshot) RKRequestPreferencesRelay();
    if (valid) return RKMergeDisplaySnapshot(stored, valid);
    int token = RKSettingsRevisionToken();
    uint64_t before = 0, after = 0;
    if (token >= 0) notify_get_state(token, &before);
    NSMutableDictionary *transport = [RKReceiveColorState() mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *palette = RKReceiveKeyboardPalette();
    if (palette) [transport addEntriesFromDictionary:palette];
    if (token >= 0) notify_get_state(token, &after);
    return RKResolvePreferencesSnapshot(stored, transport, before, after);
}

static inline NSDictionary *RKReadEffectivePreferences(void) {
    static NSLock *lock;
    static NSDictionary *cached;
    static uint64_t lastCommit;
    static CFAbsoluteTime lastRead;
    static int changedToken = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
        notify_register_check("com.minis.rainbowkeyboard.changed", &changedToken);
    });
    [lock lock];
    uint64_t commit = 0;
    int token = RKDisplayToken(RKDisplayWordCount), changed = 0;
    BOOL readable = token >= 0 && notify_get_state(token, &commit) == NOTIFY_STATUS_OK;
    if (changedToken >= 0) notify_check(changedToken, &changed);
    BOOL complete = readable && commit && commit != UINT64_MAX;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // Commit checks keep same-process saves immediate, even before Darwin callbacks.
    // Missing transport is retried at a bounded rate, never once per keystroke.
    if (!cached || changed || commit != lastCommit || (!complete && now - lastRead > 2)) {
        // 固化表补齐之后再过一遍旧档归一化：EffectStyle==2 与历史亮度默认值都在这里折算。
        cached = RKNormalizeLegacyPreferences(RKApplySelfUseFallback(RKReadUncachedEffectivePreferences()));
        lastRead = now;
        lastCommit = commit;
    }
    NSDictionary *result = cached;
    [lock unlock];
    if (!complete) RKRequestPreferencesRelay();
    return result;
}

static inline BOOL RKPublishPreferences(NSDictionary *values) {
    BOOL full = RKPublishDisplaySnapshot(values);
    int token = RKSettingsRevisionToken();
    if (token < 0 || notify_set_state(token, UINT64_MAX) != NOTIFY_STATUS_OK) {
        notify_post("com.minis.rainbowkeyboard.changed");
        return full;
    }
    BOOL colors = RKPublishColorState(values);
    BOOL palette = RKPublishKeyboardPalette(values);
    BOOL committed = colors && palette &&
        notify_set_state(token, RKPreferencesRevision(values)) == NOTIFY_STATUS_OK;
    if (!committed) notify_set_state(token, 0);
    notify_post("com.minis.rainbowkeyboard.changed");
    return full && committed;
}

// 2.3.17 删除一条**零调用链**与一个零调用诊断函数：
//   RKStartPreferencesRelay → RKInstallPreferencesRelayObservers → RKRestorePreferencesRelay
// 这组中继只对 SpringBoard 注册（`bundleIdentifier == com.apple.springboard`），而 2.3.0 起
// 注入范围已收窄为 InputUI / wxkb_plugin（不含 SpringBoard），因此从未被执行过。
// 一并删除零调用的 RKPreferencesDiagnostic（及其对 springboard 的字符串判断）。

static inline BOOL RKSavePreferences(NSMutableDictionary *values) {
    uint64_t revision = MAX(RKPreferencesRevision(values) + 1,
        (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000000));
    values[@"RKSettingsRevision"] = @(revision);
    for (NSString *key in values)
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)values[key], RKPreferencesDomain);
    BOOL domainSaved = CFPreferencesAppSynchronize(RKPreferencesDomain);
    BOOL fileSaved = [values writeToFile:RKPreferencesPath atomically:YES];
    if (!fileSaved && !domainSaved) return NO;
    // Never publish defaults or stale readback before persistence has completed.
    RKPublishPreferences(values);
    return YES;
}
