#import <Foundation/Foundation.h>
#import <notify.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

// Display preferences only. Darwin state is not an authenticated IPC channel.
enum { RKDisplayWordCount = 15 };
static inline NSArray<NSString *> *RKDisplayNumbers(void) {
    return @[@"Opacity", @"Brightness", @"NeonSaturation", @"Duration", @"Spread", @"Softness",
        @"CoreStrength", @"MaxEffects", @"AmbientStrength", @"BackgroundStrength",
        @"BackgroundDuration", @"BackgroundRadius", @"BackgroundBand", @"ColorMode",
        @"Hue", @"EffectStyle", @"Preset"];
}
// The flag list is a POSITIONAL wire format: the array index is the bit number in
// words[1] (presence 21+i, value 31+i). Never delete or reorder an element. A
// removed setting must leave a tombstone slot behind, otherwise every later flag
// shifts one bit and states left in notifyd by an already-running process get
// decoded as a different flag -- dropping "PureBlackKeyboard" made WeChatKeyboard
// read the old NativeKeyboard bit, which turned the keyboard gate off entirely.
static inline NSArray<NSString *> *RKDisplayFlags(void) {
    return @[@"CandidateGradient", @"CandidateNative", @"CandidateWeType", @"RKLegacySlot3",
        @"Enabled", @"NativeKeyboard", @"WeChatKeyboard", @"RippleEnabled", @"AmbientGlow", @"BackgroundFeedback"];
}
static inline NSArray<NSString *> *RKDisplayColors(void) {
    return @[@"CandidateStart", @"CandidateEnd"];
}
static inline NSArray<NSString *> *RKDisplayKeys(void) {
    return [[[RKDisplayNumbers() arrayByAddingObjectsFromArray:RKDisplayFlags()]
        arrayByAddingObjectsFromArray:RKDisplayColors()]
        arrayByAddingObjectsFromArray:@[@"PressBrightness", @"AmbientGlide"]];
}
static inline void RKEncodeDisplaySnapshot(NSDictionary *prefs, uint64_t words[RKDisplayWordCount]) {
    memset(words, 0, RKDisplayWordCount * sizeof(uint64_t));
    words[0] = [prefs[@"RKSettingsRevision"] unsignedLongLongValue];
    // Snapshot magic doubles as a layout revision. Bumping it makes any state left
    // behind by an older layout unusable, so a format change can never be misread.
    words[1] = UINT64_C(0xD2) << 56;
    NSArray *numbers = RKDisplayNumbers(), *flags = RKDisplayFlags(), *colors = RKDisplayColors();
    for (NSUInteger i = 0; i < numbers.count; i++) {
        id value = prefs[numbers[i]];
        if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) continue;
        float number = [value floatValue];
        if (!isfinite(number)) continue;
        uint32_t bits;
        memcpy(&bits, &number, sizeof(bits));
        words[1] |= UINT64_C(1) << i;
        words[6 + i / 2] |= (uint64_t)bits << ((i % 2) * 32);
    }
    for (NSUInteger i = 0; i < colors.count; i++) {
        id value = prefs[colors[i]];
        if (![value isKindOfClass:NSArray.class] || [value count] != 3) continue;
        BOOL valid = YES;
        uint64_t rgb = 0;
        for (NSUInteger c = 0; c < 3; c++) {
            id component = value[c];
            if (![component isKindOfClass:NSNumber.class] || !isfinite([component doubleValue])) { valid = NO; break; }
            rgb |= (uint64_t)llround(MIN(1, MAX(0, [component doubleValue])) * 65535) << (c * 16);
        }
        if (valid) {
            words[1] |= UINT64_C(1) << (17 + i);
            words[2 + i] = rgb;
        }
    }
    for (NSUInteger i = 0; i < flags.count; i++) {
        id value = prefs[flags[i]];
        if (![value isKindOfClass:NSNumber.class]) continue;
        words[1] |= UINT64_C(1) << (21 + i);
        if ([value boolValue]) words[1] |= UINT64_C(1) << (31 + i);
    }
    // Optional extension in v2's unused bits. Older clients ignore these fields.
    id brightness = prefs[@"PressBrightness"];
    if ([brightness isKindOfClass:NSNumber.class] && isfinite([brightness doubleValue])) {
        float value = MIN(1, MAX(0, [brightness doubleValue]));
        uint32_t bits;
        memcpy(&bits, &value, sizeof(bits));
        words[14] |= (uint64_t)bits << 32;
        words[1] |= UINT64_C(1) << 43;
    }
    // Extended flags. The positional flag block is exactly full -- presence bits 21..30
    // and value bits 31..40 meet -- so an eleventh flag cannot be appended to it without
    // landing on the first flag's value bit. These live in the free gap above
    // PressBrightness (bit 43), allocated as presence/value pairs from the bottom up:
    // AmbientGlide owns 44/45, the next flag added owns 46/47, and so on. Never renumber
    // a pair that has shipped, for the same reason the positional list is append-only.
    id ambientGlide = prefs[@"AmbientGlide"];
    if ([ambientGlide isKindOfClass:NSNumber.class]) {
        words[1] |= UINT64_C(1) << 44;
        if ([ambientGlide boolValue]) words[1] |= UINT64_C(1) << 45;
    }
}
static inline uint64_t RKDisplayChecksum(const uint64_t words[RKDisplayWordCount]) {
    uint64_t hash = UINT64_C(14695981039346656037);
    for (NSUInteger i = 0; i < RKDisplayWordCount; i++)
        for (NSUInteger byte = 0; byte < 8; byte++) {
            hash ^= (words[i] >> (byte * 8)) & 255;
            hash *= UINT64_C(1099511628211);
        }
    // Reserve zero for absent state and UINT64_MAX for an in-progress write.
    return (hash & UINT64_C(0x7FFFFFFFFFFFFFFF)) | 1;
}
static inline NSDictionary *RKDecodeDisplaySnapshot(const uint64_t words[RKDisplayWordCount], uint64_t checksum) {
    if ((words[1] >> 56) != 0xD2 || !checksum || checksum == UINT64_MAX ||
        RKDisplayChecksum(words) != checksum) return nil;
    NSMutableDictionary *result = [@{@"RKSettingsRevision":@(words[0])} mutableCopy];
    NSArray *numbers = RKDisplayNumbers(), *flags = RKDisplayFlags(), *colors = RKDisplayColors();
    for (NSUInteger i = 0; i < numbers.count; i++) {
        if (!(words[1] & (UINT64_C(1) << i))) continue;
        uint32_t bits = (uint32_t)(words[6 + i / 2] >> ((i % 2) * 32));
        float value;
        memcpy(&value, &bits, sizeof(value));
        if (!isfinite(value)) return nil;
        result[numbers[i]] = @(value);
    }
    for (NSUInteger i = 0; i < colors.count; i++) {
        if (!(words[1] & (UINT64_C(1) << (17 + i)))) continue;
        NSMutableArray *rgb = [NSMutableArray array];
        for (NSUInteger c = 0; c < 3; c++) [rgb addObject:@(((words[2 + i] >> (c * 16)) & 65535) / 65535.0)];
        result[colors[i]] = rgb;
    }
    for (NSUInteger i = 0; i < flags.count; i++)
        if (words[1] & (UINT64_C(1) << (21 + i))) result[flags[i]] = @((words[1] >> (31 + i)) & 1);
    if (words[1] & (UINT64_C(1) << 43)) {
        uint32_t bits = (uint32_t)(words[14] >> 32);
        float value;
        memcpy(&value, &bits, sizeof(value));
        if (!isfinite(value) || value < 0 || value > 1) return nil;
        result[@"PressBrightness"] = @(value);
    }
    // Extended flags: see the encoder. An absent bit means "no saved value", which the
    // renderer treats as its own default -- so a snapshot written before this key existed
    // simply leaves the behaviour alone instead of forcing it off.
    if (words[1] & (UINT64_C(1) << 44))
        result[@"AmbientGlide"] = @((words[1] >> 45) & 1);
    return result;
}
static inline int RKDisplayToken(NSUInteger index) {
    static int tokens[RKDisplayWordCount + 1];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSUInteger i = 0; i <= RKDisplayWordCount; i++) {
            tokens[i] = -1;
            NSString *name = [NSString stringWithFormat:@"com.minis.rainbowkeyboard.snapshot.v3.%lu", (unsigned long)i];
            int token = -1;
            if (notify_register_check(name.UTF8String, &token) == NOTIFY_STATUS_OK) tokens[i] = token;
        }
    });
    return tokens[index];
}
static inline BOOL RKPublishDisplaySnapshot(NSDictionary *prefs) {
    uint64_t words[RKDisplayWordCount];
    RKEncodeDisplaySnapshot(prefs, words);
    int commit = RKDisplayToken(RKDisplayWordCount);
    if (commit < 0 || notify_set_state(commit, UINT64_MAX) != NOTIFY_STATUS_OK) return NO;
    BOOL valid = YES;
    for (NSUInteger i = 0; i < RKDisplayWordCount; i++) {
        int token = RKDisplayToken(i);
        uint64_t check = 0;
        valid &= token >= 0 && notify_set_state(token, words[i]) == NOTIFY_STATUS_OK &&
            notify_get_state(token, &check) == NOTIFY_STATUS_OK && check == words[i];
    }
    uint64_t hash = RKDisplayChecksum(words), check = 0;
    return valid && notify_set_state(commit, hash) == NOTIFY_STATUS_OK &&
        notify_get_state(commit, &check) == NOTIFY_STATUS_OK && check == hash;
}
static inline NSDictionary *RKReceiveDisplaySnapshot(void) {
    int commit = RKDisplayToken(RKDisplayWordCount);
    uint64_t before = 0, after = 0, words[RKDisplayWordCount] = {};
    if (commit < 0 || notify_get_state(commit, &before) != NOTIFY_STATUS_OK ||
        !before || before == UINT64_MAX) return nil;
    for (NSUInteger i = 0; i < RKDisplayWordCount; i++) {
        int token = RKDisplayToken(i);
        if (token < 0 || notify_get_state(token, &words[i]) != NOTIFY_STATUS_OK) return nil;
    }
    if (notify_get_state(commit, &after) != NOTIFY_STATUS_OK || before != after) return nil;
    return RKDecodeDisplaySnapshot(words, before);
}
static inline NSDictionary *RKMergeDisplaySnapshot(NSDictionary *stored, NSDictionary *snapshot) {
    if (!snapshot || [stored[@"RKSettingsRevision"] unsignedLongLongValue] >
        [snapshot[@"RKSettingsRevision"] unsignedLongLongValue]) return stored ?: @{};
    NSMutableDictionary *result = [stored mutableCopy] ?: [NSMutableDictionary dictionary];
    // Absence means use the renderer's existing default, not an older saved value.
    [result removeObjectsForKeys:RKDisplayKeys()];
    [result addEntriesFromDictionary:snapshot];
    return result;
}
