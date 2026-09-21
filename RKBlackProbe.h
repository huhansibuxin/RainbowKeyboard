#import <Foundation/Foundation.h>
#import <notify.h>

// Only hook flags and saturated counters cross process boundaries, never input.
static inline int RKBlackProbeToken(BOOL weType) {
    static int tokens[2] = {-1, -1};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.minis.rainbowkeyboard.black.native.v9", &tokens[0]);
        notify_register_check("com.minis.rainbowkeyboard.black.wetype.v8", &tokens[1]);
    });
    return tokens[weType ? 1 : 0];
}

static inline uint64_t RKBlackProbeState(uint8_t flags, NSUInteger backgrounds, NSUInteger atlases,
                                        NSUInteger keyImages, NSUInteger weTypeKeys) {
    uint64_t state = (UINT64_C(0xB8) << 56) | flags;
    state |= (uint64_t)MIN(backgrounds, 255u) << 8;
    state |= (uint64_t)MIN(atlases, 255u) << 16;
    state |= (uint64_t)MIN(keyImages, 255u) << 24;
    state |= (uint64_t)MIN(weTypeKeys, 255u) << 32;
    state |= ((uint64_t)(NSDate.date.timeIntervalSince1970 / 60) & 0xffff) << 40;
    return state;
}

static inline NSDictionary *RKDecodeBlackProbe(uint64_t state) {
    if ((state >> 56) != 0xB8) return @{@"available":@NO};
    uint64_t now = (uint64_t)(NSDate.date.timeIntervalSince1970 / 60);
    return @{@"available":@YES, @"version":@"samsung8",
        @"enabled":@((state & 1) != 0), @"keyplaneHook":@((state & 2) != 0),
        @"splitImageHook":@((state & 4) != 0), @"keyViewHook":@((state & 8) != 0),
        @"configHook":@((state & 16) != 0),
        @"backgroundOperations":@((state >> 8) & 255),
        @"atlasImages":@((state >> 16) & 255), @"keyImages":@((state >> 24) & 255),
        @"weTypeKeyVisits":@((state >> 32) & 255),
        @"minutesSinceReport":@((now - ((state >> 40) & 0xffff)) & 0xffff)};
}

static inline int RKBlackSurfaceProbeToken(BOOL weType) {
    static int tokens[2] = {-1, -1};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.minis.rainbowkeyboard.surfaces.native.v9", &tokens[0]);
        notify_register_check("com.minis.rainbowkeyboard.surfaces.wetype.v8", &tokens[1]);
    });
    return tokens[weType ? 1 : 0];
}
static inline void RKPublishBlackSurfaceProbe(BOOL weType, NSUInteger draws, NSUInteger converted,
                                             NSUInteger suppressed, NSUInteger shapes, NSUInteger keyViews) {
    uint64_t state = UINT64_C(0xB8) << 56;
    state |= (uint64_t)MIN(draws, 65535u);
    state |= (uint64_t)MIN(converted, 65535u) << 16;
    state |= (uint64_t)MIN(suppressed, 255u) << 32;
    state |= (uint64_t)MIN(shapes, 255u) << 40;
    state |= (uint64_t)MIN(keyViews, 255u) << 48;
    int token = RKBlackSurfaceProbeToken(weType);
    if (token >= 0) notify_set_state(token, state);
}

static inline int RKNativeStateProbeToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check("com.minis.rainbowkeyboard.native-state.v9", &token);
    });
    return token;
}

static inline void RKPublishNativeStateProbe(uint8_t flags, NSUInteger traits, NSUInteger states,
                                              NSUInteger multiply, NSUInteger stretch) {
    uint64_t state = (UINT64_C(0xC9) << 56) | flags;
    state |= (uint64_t)MIN(traits, 65535u) << 8;
    state |= (uint64_t)MIN(states, 65535u) << 24;
    state |= (uint64_t)MIN(multiply, 255u) << 40;
    state |= (uint64_t)MIN(stretch, 255u) << 48;
    int token = RKNativeStateProbeToken();
    if (token >= 0) notify_set_state(token, state);
}

static inline NSDictionary *RKReadBlackProbe(BOOL weType) {
    int token = RKBlackProbeToken(weType);
    uint64_t state = 0;
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return @{@"available":@NO};
    NSMutableDictionary *report = [RKDecodeBlackProbe(state) mutableCopy];
    if (!weType && [report[@"available"] boolValue]) {
        report[@"version"] = @"samsung9";
        uint64_t native = 0;
        int nativeToken = RKNativeStateProbeToken();
        if (nativeToken >= 0 && notify_get_state(nativeToken, &native) == NOTIFY_STATUS_OK && (native >> 56) == 0xC9) {
            report[@"nativeStateHooks"] = @((native & 1) != 0);
            report[@"nativeTraitsHook"] = @((native & 2) != 0);
            report[@"nativeMultiplyHook"] = @((native & 4) != 0);
            report[@"nativeTraitsRecolored"] = @((native >> 8) & 65535);
            report[@"nativeStateRefreshes"] = @((native >> 24) & 65535);
            report[@"nativeMultiplyChanges"] = @((native >> 40) & 255);
            report[@"nativeStretchImages"] = @((native >> 48) & 255);
        }
    }
    uint64_t surfaces = 0;
    int surfaceToken = RKBlackSurfaceProbeToken(weType);
    if (surfaceToken >= 0 && notify_get_state(surfaceToken, &surfaces) == NOTIFY_STATUS_OK &&
        (surfaces >> 56) == 0xB8) {
        report[@"directDraws"] = @(surfaces & 65535);
        report[@"directConversions"] = @((surfaces >> 16) & 65535);
        report[@"suppressedBackgrounds"] = @((surfaces >> 32) & 255);
        report[@"shapeFaces"] = @((surfaces >> 40) & 255);
        report[@"observedKeyViews"] = @((surfaces >> 48) & 255);
    }
    return report;
}
