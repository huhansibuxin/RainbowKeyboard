#import "RKThemeEngine.h"
static NSDictionary *RKTheme(NSString *name, CGFloat sat, CGFloat bright, CGFloat opacity, CGFloat spread, CGFloat softness, CGFloat core, CGFloat bgStrength, CGFloat bgRadius, CGFloat bgBand, NSInteger colorMode, CGFloat hue) {
    return @{@"name":name, @"NeonSaturation":@(sat), @"Brightness":@(bright), @"Opacity":@(opacity),
             @"Spread":@(spread), @"Softness":@(softness), @"CoreStrength":@(core), @"BackgroundStrength":@(bgStrength),
             @"BackgroundRadius":@(bgRadius), @"BackgroundBand":@(bgBand), @"ColorMode":@(colorMode), @"Hue":@(hue)};
}
NSDictionary *RKThemeDefinition(NSInteger theme) {
    switch (theme) {
        case 1: return RKTheme(@"深空", .88,.95,.68,2.0,8,.50,.18,180,.55,1,.63);
        case 2: return RKTheme(@"极夜紫", .92,1,.68,2.0,8,.52,.20,185,.55,1,.78);
        case 3: return RKTheme(@"赛博蓝", .90,1,.70,1.9,7,.55,.20,180,.50,1,.55);
        case 4: return RKTheme(@"赤焰", .94,1,.72,1.8,7,.58,.20,175,.52,1,.03);
        case 5: return RKTheme(@"极光", .90,1,.66,2.1,9,.50,.18,190,.58,1,.42);
        case 6: return RKTheme(@"Rainbow", 1,1,.68,2.2,8,.55,.20,195,.58,0,.0);
        case 7: return RKTheme(@"冰晶", .48,1,.62,1.8,10,.46,.16,175,.50,1,.52);
        case 8: return RKTheme(@"Neon", 1,1,.72,2.2,7,.62,.22,195,.60,1,.82);
        case 9: return RKTheme(@"Cyberpunk", 1,1,.74,2.3,6,.62,.23,200,.62,1,.90);
        default: return @{@"name":@"自定义"};
    }
}
NSString *RKThemeDisplayName(NSInteger theme) { return RKThemeDefinition(theme)[@"name"] ?: @"自定义"; }
NSDictionary *RKThemeMergedPreferences(NSDictionary *preferences) {
    NSInteger theme = [preferences[@"Theme"] integerValue];
    if (theme <= 0) return preferences ?: @{};
    NSMutableDictionary *merged = [preferences mutableCopy] ?: [NSMutableDictionary dictionary];
    NSDictionary *definition = RKThemeDefinition(theme);
    [definition enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (![key isEqualToString:@"name"]) merged[key] = value;
    }];
    return merged;
}
