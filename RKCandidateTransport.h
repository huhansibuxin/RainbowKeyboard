#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <math.h>
// Only non-sensitive display preferences are transmitted. Not a secure IPC channel.
static int RKColorStateToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int t = -1;
        if (notify_register_check("com.minis.rainbowkeyboard.colorstate.v1", &t) == NOTIFY_STATUS_OK) token = t;
    });
    return token;
}
static inline BOOL RKPublishColorState(NSDictionary *prefs) {
    uint64_t state = UINT64_C(0xA8) << 56;
    NSArray *keys = @[@"CandidateStart", @"CandidateEnd"];
    NSArray *defaults = @[@[@0, @0.65, @1], @[@0.85, @0.15, @1]];
    for (NSUInteger c = 0; c < 2; c++) {
        id rgb = prefs[keys[c]];
        if (![rgb isKindOfClass:NSArray.class] || [rgb count] != 3) rgb = defaults[c];
        for (NSUInteger j = 0; j < 3; j++) {
            id component = rgb[j];
            double value = [component isKindOfClass:NSNumber.class] ? [component doubleValue] : 0;
            if (!isfinite(value)) value = [defaults[c][j] doubleValue];
            uint64_t byte = (uint64_t)(MIN(1.0, MAX(0.0, value)) * 255.0 + 0.5);
            state |= byte << ((c * 3 + j) * 8);
        }
    }
    if (!prefs[@"CandidateGradient"] || [prefs[@"CandidateGradient"] boolValue]) state |= UINT64_C(1) << 48;
    if (!prefs[@"CandidateNative"] || [prefs[@"CandidateNative"] boolValue]) state |= UINT64_C(1) << 49;
    if (!prefs[@"CandidateWeType"] || [prefs[@"CandidateWeType"] boolValue]) state |= UINT64_C(1) << 50;
    if (!prefs[@"PureBlackKeyboard"] || [prefs[@"PureBlackKeyboard"] boolValue]) state |= UINT64_C(1) << 51;
    state |= UINT64_C(1) << 52; // Presence bit keeps older color-only messages compatible.
    if (!prefs[@"Enabled"] || [prefs[@"Enabled"] boolValue]) state |= UINT64_C(1) << 53;
    if (!prefs[@"NativeKeyboard"] || [prefs[@"NativeKeyboard"] boolValue]) state |= UINT64_C(1) << 54;
    if (!prefs[@"WeChatKeyboard"] || [prefs[@"WeChatKeyboard"] boolValue]) state |= UINT64_C(1) << 55;
    int token = RKColorStateToken();
    if (token < 0 || notify_set_state(token, state) != NOTIFY_STATUS_OK) return NO;
    uint64_t check = 0;
    if (notify_get_state(token, &check) != NOTIFY_STATUS_OK || check != state) return NO;
    notify_post("com.minis.rainbowkeyboard.changed");
    return YES;
}
static inline NSDictionary *RKDecodeColorState(uint64_t state) {
    if ((state >> 56) != 0xA7 && (state >> 56) != 0xA8) return nil;
    NSMutableArray *colors = [NSMutableArray array];
    for (NSUInteger c = 0; c < 2; c++) {
        NSMutableArray *rgb = [NSMutableArray array];
        for (NSUInteger j = 0; j < 3; j++) [rgb addObject:@(((state >> ((c * 3 + j) * 8)) & 255) / 255.0)];
        [colors addObject:rgb];
    }
    NSMutableDictionary *prefs = [@{@"CandidateGradient":@((state >> 48) & 1),
        @"CandidateNative":@((state >> 49) & 1), @"CandidateWeType":@((state >> 50) & 1),
        @"CandidateStart":colors[0], @"CandidateEnd":colors[1]} mutableCopy];
    if ((state >> 52) & 1) {
        prefs[@"PureBlackKeyboard"] = @((state >> 51) & 1);
        prefs[@"Enabled"] = @((state >> 53) & 1);
        prefs[@"NativeKeyboard"] = @((state >> 54) & 1);
        if ((state >> 56) == 0xA8) prefs[@"WeChatKeyboard"] = @((state >> 55) & 1);
    }
    return prefs;
}
static inline NSDictionary *RKReceiveColorState(void) {
    uint64_t state = 0;
    int token = RKColorStateToken();
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return nil;
    return RKDecodeColorState(state);
}
