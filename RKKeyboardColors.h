#import <UIKit/UIKit.h>
#import <notify.h>
#include <math.h>

static inline NSArray<NSNumber *> *RKKeyboardRGB(id value) {
    if (![value isKindOfClass:NSArray.class] || [value count] != 3) return @[@0, @0, @0];
    NSMutableArray *rgb = [NSMutableArray arrayWithCapacity:3];
    for (id component in value) {
        double v = [component isKindOfClass:NSNumber.class] ? [component doubleValue] : 0;
        [rgb addObject:@(isfinite(v) ? MIN(1, MAX(0, v)) : 0)];
    }
    return rgb;
}

static inline UIColor *RKKeyboardColor(NSDictionary *prefs, NSString *key) {
    id value = prefs[key];
    if (!value && [key isEqual:@"PressColor"]) value = @[@0, @.8, @1];
    NSArray *rgb = RKKeyboardRGB(value);
    if ([rgb[0] isEqual:rgb[1]] && [rgb[1] isEqual:rgb[2]])
        return [UIColor colorWithWhite:[rgb[0] doubleValue] alpha:1];
    return [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue]
        blue:[rgb[2] doubleValue] alpha:1];
}

// A separate channel keeps existing candidate-gradient clients compatible.
static inline int RKKeyboardPaletteToken(void) {
    static int token = -1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int t = -1;
        if (notify_register_check("com.minis.rainbowkeyboard.palette.v1", &t) == NOTIFY_STATUS_OK) token = t;
    });
    return token;
}

static inline uint64_t RKKeyboardPaletteState(NSDictionary *prefs) {
    uint64_t state = UINT64_C(0xC1) << 56;
    NSArray *keys = @[@"KeyboardBackgroundColor", @"KeycapColor"];
    for (NSUInteger c = 0; c < keys.count; c++) {
        NSArray *rgb = RKKeyboardRGB(prefs[keys[c]]);
        for (NSUInteger j = 0; j < 3; j++)
            state |= (uint64_t)lround([rgb[j] doubleValue] * 255) << ((c * 3 + j) * 8);
    }
    return state;
}

static inline NSDictionary *RKDecodeKeyboardPalette(uint64_t state) {
    if ((state >> 56) != 0xC1) return nil;
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    NSArray *keys = @[@"KeyboardBackgroundColor", @"KeycapColor"];
    for (NSUInteger c = 0; c < keys.count; c++) {
        NSMutableArray *rgb = [NSMutableArray array];
        for (NSUInteger j = 0; j < 3; j++)
            [rgb addObject:@(((state >> ((c * 3 + j) * 8)) & 255) / 255.0)];
        prefs[keys[c]] = rgb;
    }
    return prefs;
}

static inline BOOL RKPublishKeyboardPalette(NSDictionary *prefs) {
    int token = RKKeyboardPaletteToken();
    uint64_t state = RKKeyboardPaletteState(prefs), check = 0;
    return token >= 0 && notify_set_state(token, state) == NOTIFY_STATUS_OK &&
        notify_get_state(token, &check) == NOTIFY_STATUS_OK && check == state;
}

static inline NSDictionary *RKReceiveKeyboardPalette(void) {
    int token = RKKeyboardPaletteToken();
    uint64_t state = 0;
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK) return nil;
    return RKDecodeKeyboardPalette(state);
}
