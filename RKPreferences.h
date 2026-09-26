#import <Foundation/Foundation.h>
#import "RKCandidateTransport.h"
#import "RKKeyboardColors.h"
#import "RKDisplayTransport.h"

static NSString * const RKPreferencesPath = @"/var/mobile/Library/Preferences/com.minis.rainbowkeyboard.plist";
static CFStringRef const RKPreferencesDomain = CFSTR("com.minis.rainbowkeyboard");

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
        cached = RKReadUncachedEffectivePreferences();
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

static inline NSDictionary *RKPreferencesDiagnostic(void) {
    NSDictionary *stored = RKReadStoredPreferences(), *transport = RKReceiveDisplaySnapshot();
    NSDictionary *effective = RKReadEffectivePreferences();
    return @{@"transportVersion":@2, @"snapshotAvailable":@(transport != nil),
        @"storedRevision":@(RKPreferencesRevision(stored)),
        @"receivedRevision":@(RKPreferencesRevision(transport)),
        @"effectiveRevision":@(RKPreferencesRevision(effective)),
        @"keyboardBackground":RKKeyboardRGB(effective[@"KeyboardBackgroundColor"]),
        @"keycap":RKKeyboardRGB(effective[@"KeycapColor"])};
}

static inline void RKRestorePreferencesRelay(void) {
    NSDictionary *stored = RKReadStoredPreferences();
    // Only a real saved configuration can repopulate the cross-process state.
    if (!RKPreferencesRevision(stored)) return;
    NSDictionary *current = RKReceiveDisplaySnapshot();
    if (RKPreferencesRevision(current) > RKPreferencesRevision(stored)) return;
    uint64_t words[RKDisplayWordCount], currentWords[RKDisplayWordCount];
    RKEncodeDisplaySnapshot(stored, words);
    RKEncodeDisplaySnapshot(current, currentWords);
    if (current && RKDisplayChecksum(words) == RKDisplayChecksum(currentWords)) return;
    RKPublishPreferences(stored);
}
static inline void RKInstallPreferencesRelayObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static int requestToken, changeToken;
        notify_register_dispatch("com.minis.rainbowkeyboard.settings.request.v2", &requestToken,
            dispatch_get_main_queue(), ^(int token) { RKRestorePreferencesRelay(); });
        notify_register_dispatch("com.minis.rainbowkeyboard.changed", &changeToken,
            dispatch_get_main_queue(), ^(int token) { RKRestorePreferencesRelay(); });
        RKRestorePreferencesRelay();
    });
}
static inline void RKStartPreferencesRelay(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"])
        RKInstallPreferencesRelayObservers();
}

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

// ---- 「自用」光效预设（随原版 1.2.1 光效链路一并保留）----
// The owner's live values copied verbatim, trailing digits included: they were read
// straight out of the device plist, and rounding them would change the look this
// preset exists to reproduce.
static inline NSDictionary<NSString *, NSNumber *> *RKPresetSelfUseTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{@"Opacity":@0.6,
            @"Brightness":@0.8033448457717896,
            @"NeonSaturation":@0.7006920576095581,
            @"Duration":@0.2959342300891876,
            @"Spread":@1.5020183324813843,
            @"Softness":@5,
            @"CoreStrength":@0.6,
            @"MaxEffects":@2.99826979637146,
            @"BackgroundStrength":@0.30484429001808167,
            @"BackgroundRadius":@126.26296997070312,
            @"BackgroundBand":@0.29783737659454346,
            @"AmbientStrength":@0.85,
            @"BackgroundDuration":@0.4,
            @"Hue":@0.32814300060272217,
            @"PressBrightness":@0.9013840556144714,
            @"EffectStyle":@0,
            @"ColorMode":@0};
    });
    return table;
}
