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
    NSArray *rgb = RKKeyboardRGB(value);
    if ([rgb[0] isEqual:rgb[1]] && [rgb[1] isEqual:rgb[2]])
        return [UIColor colorWithWhite:[rgb[0] doubleValue] alpha:1];
    return [UIColor colorWithRed:[rgb[0] doubleValue] green:[rgb[1] doubleValue]
        blue:[rgb[2] doubleValue] alpha:1];
}
