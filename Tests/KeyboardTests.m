#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
#import "RKNeonPress.h"
#import "CandidateGradient.generated.mm"
#define _logos_register_hook _logos_register_black_hook
#import "PureBlackKeyboard.generated.mm"
#undef _logos_register_hook

@interface NSObject (RKTestNativeConfig)
+ (id)defaultConfig;
@end

@interface WBTextItemLabel : UILabel
@end
@implementation WBTextItemLabel
- (void)drawTextInRect:(CGRect)rect { [super drawTextInRect:rect]; }
@end

@interface UIKeyboardCandidateRKFixture : UIView
@end
@implementation UIKeyboardCandidateRKFixture
@end
@interface RKWeTypeCandidateFixture : UIView
@end
@implementation RKWeTypeCandidateFixture
@end
@interface WBKeyViewFixture : UIView
@end
@implementation WBKeyViewFixture
@end
@interface WBPressedKeyFixture : UIButton
@property(nonatomic, strong) CALayer *pressedFace;
@end
@implementation WBPressedKeyFixture
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self.pressedFace removeFromSuperlayer];
    self.pressedFace = [CALayer layer];
    self.pressedFace.frame = self.bounds;
    self.pressedFace.backgroundColor = (highlighted ? UIColor.lightGrayColor : UIColor.grayColor).CGColor;
    [self.layer insertSublayer:self.pressedFace atIndex:0];
}
@end
@interface WBPaintedKeyFixture : UIView
@end
@implementation WBPaintedKeyFixture
- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithWhite:76 / 255.0 alpha:1] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:5] fill];
    [UIColor.whiteColor setFill];
    UIRectFill(CGRectMake(36, 8, 5, 23));
}
@end
@interface RKKeyboardDockFixture : UIView
@end
@implementation RKKeyboardDockFixture
@end
@interface RKKeyboardLayoutStarFixture : UIView
@end
@implementation RKKeyboardLayoutStarFixture
@end
@interface RKKeyboardItemContainerFixture : UIView
@end
@implementation RKKeyboardItemContainerFixture
@end
@interface WBCandidateBarFixture : UIView
@end
@implementation WBCandidateBarFixture
@end
@interface RKAtlasPlaneFixture : UIView {
@public
    UIView *_keyBackgrounds;
    UIView *_keyBorders;
    UIView *_keyCaps;
}
@end
@implementation RKAtlasPlaneFixture
@end

@interface RKStatePlaneFixture : UIView
@property(nonatomic) NSUInteger lookups;
@end
@implementation RKStatePlaneFixture
- (id)viewForKey:(id)key state:(int)state {
    self.lookups++;
    return key;
}
@end

@interface UIKeyboardCandidateRKDrawFixture : UIView
@end
@implementation UIKeyboardCandidateRKDrawFixture
- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithWhite:.2 alpha:1] setFill];
    UIRectFill(self.bounds);
    NSDictionary *attributes = @{NSFontAttributeName:[UIFont boldSystemFontOfSize:26],
        NSForegroundColorAttributeName:UIColor.whiteColor};
    [@"Candidate" drawAtPoint:CGPointMake(8, 8) withAttributes:attributes];
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:@"Gradient" attributes:attributes];
    [string drawInRect:CGRectMake(8, 48, 180, 36)];
}
@end

@interface RKFixtureKey : NSObject
@property(nonatomic) CGRect frame;
@property(nonatomic) CGRect displayFrame;
@property(nonatomic) BOOL ghost;
@end
@implementation RKFixtureKey
@end
@interface RKFixturePlane : NSObject
@property(nonatomic,strong) NSArray *keys;
@end
@implementation RKFixturePlane
@end
@interface RKFixtureHost : UIView
@property(nonatomic,strong) RKFixturePlane *keyplane;
@end
@implementation RKFixtureHost
@end
@interface RKWrongABIHost : UIView
- (NSInteger)keyplane;
@end
@implementation RKWrongABIHost
- (NSInteger)keyplane { return 42; }
@end
@interface RKFixtureEffect : RainbowEffectView
@end
@implementation RKFixtureEffect
- (void)reloadConfiguration {}
@end

static id RKTestObjectGetter(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 ||
        strcmp(signature.methodReturnType, @encode(id))) return nil;
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = object;
    call.selector = selector;
    [call invoke];
    __unsafe_unretained id result = nil;
    [call getReturnValue:&result];
    return result;
}

static UIImage *RKLabelImage(UILabel *label) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:label.bounds.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [label drawTextInRect:label.bounds];
    }];
}
static NSDictionary *RKImageMetrics(UIImage *image) {
    size_t width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
    unsigned char *bytes = (unsigned char *)pixels.mutableBytes;
    NSUInteger cyan = 0, pink = 0, colored = 0, opaque = 0, maxChannel = 0, gray = 0;
    for (size_t i = 0; i < width * height; i++) {
        unsigned char *p = bytes + i * 4;
        if (p[3] < 180) continue;
        opaque++;
        maxChannel = MAX(maxChannel, MAX(p[0], MAX(p[1], p[2])));
        if (p[2] > p[0] + 35 && p[1] > p[0] + 20) cyan++;
        if (p[0] > p[1] + 35 && p[2] > p[1] + 35) pink++;
        if (MAX(p[0], MAX(p[1], p[2])) - MIN(p[0], MIN(p[1], p[2])) > 30) colored++;
        if (p[0] >= 8 && p[0] <= 180 && abs(p[0] - p[1]) <= 3 && abs(p[1] - p[2]) <= 3) gray++;
    }
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return @{@"cyan":@(cyan), @"pink":@(pink), @"colored":@(colored),
        @"opaque":@(opaque), @"maxChannel":@(maxChannel), @"pixelCount":@(width * height), @"gray":@(gray)};
}

static NSData *RKTestPixels(CGImageRef image) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels.mutableBytes, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return pixels;
}

static UIImage *RKGrayKeyFixture(NSUInteger shade) {
    const size_t width = 80, height = 40;
    NSMutableData *pixels = [NSMutableData dataWithLength:width * height * 4];
    uint8_t *bytes = (uint8_t *)pixels.mutableBytes;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint8_t *p = bytes + (y * width + x) * 4;
            p[0] = p[1] = p[2] = shade - y / 8;
            p[3] = 255;
            if (x < 3 && y < 3) p[0] = p[1] = p[2] = p[3] = 0;
            else if (x == 3 && y < 3) {
                p[0] = p[1] = p[2] = (p[0] * 128 + 127) / 255;
                p[3] = 128;
            } else if (x >= 35 && x < 40 && y > 8 && y < 31) {
                p[0] = p[1] = p[2] = 255;
            } else if (x == 34 && y > 8 && y < 31) {
                p[0] = p[1] = p[2] = (p[0] + 255) / 2;
            } else if (x > 55 && x < 60 && y > 15 && y < 20) {
                p[0] = 255; p[1] = 100; p[2] = 10;
            }
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef image = CGBitmapContextCreateImage(context);
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return result;
}
static void RKCollectEffectColors(CALayer *layer, NSMutableArray<UIColor *> *colors) {
    if (layer.backgroundColor) [colors addObject:[UIColor colorWithCGColor:layer.backgroundColor]];
    if (layer.shadowColor) [colors addObject:[UIColor colorWithCGColor:layer.shadowColor]];
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (id)layer;
        if (shape.fillColor) [colors addObject:[UIColor colorWithCGColor:shape.fillColor]];
        if (shape.strokeColor) [colors addObject:[UIColor colorWithCGColor:shape.strokeColor]];
    }
    if ([layer isKindOfClass:CAGradientLayer.class]) {
        for (id color in ((CAGradientLayer *)layer).colors)
            [colors addObject:[UIColor colorWithCGColor:(__bridge CGColorRef)color]];
    }
    for (CALayer *child in layer.sublayers) RKCollectEffectColors(child, colors);
}

static UIImage *RKAtlasFixture(void) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(1200, 660) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (NSUInteger row = 0; row < 3; row++) {
            for (NSUInteger column = 0; column < 10; column++) {
                UIColor *color = column == 9 ? [UIColor colorWithRed:0 green:.48 blue:1 alpha:1] :
                    [UIColor colorWithWhite:(column % 2 ? 38 : 76) / 255.0 alpha:1];
                [color setFill];
                CGRect face = CGRectMake(column * 120 + 10, row * 210 + 10, 100, 180);
                [[UIBezierPath bezierPathWithRoundedRect:face cornerRadius:10] fill];
                [UIColor.whiteColor setFill];
                UIRectFill(CGRectMake(column * 120 + 50, row * 210 + 50, 6, 90));
            }
        }
    }];
}

static UIImage *RKDrawViewFixture(UIView *view) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [view drawLayer:view.layer inContext:context.CGContext];
    }];
}
@interface RKTestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) NSMutableArray *results;
@property(nonatomic,strong) RKFixtureEffect *effect;
@property(nonatomic) CGPoint gutterSample;
@end

@implementation RKTestDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];
    NSMutableDictionary *initialPrefs = [@{@"CandidateGradient":@YES, @"CandidateNative":@YES,
        @"CandidateWeType":@YES, @"Enabled":@YES, @"NativeKeyboard":@YES, @"WeChatKeyboard":@YES,
        @"PureBlackKeyboard":@YES, @"KeycapColor":@[@0,@0,@0], @"KeyboardBackgroundColor":@[@0,@0,@0],
        @"CandidateStart":@[@0,@.65,@1], @"CandidateEnd":@[@.85,@.15,@1]} mutableCopy];
    RKSavePreferences(initialPrefs);
    RKCandidateReload();
    RKBlackReload();
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--settings"]) {
        [self runSettingsProbe];
        return YES;
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--wetype-isolation"]) {
        self.results = [NSMutableArray array];
        RKInstallNativeStateHooks();
        [self check:!RKNativeStateHooksInstalled && !RKNativeTraitsHookInstalled &&
            !RKNativeGradientHookInstalled && !RKNativeMultiplyHookInstalled
            name:@"a WeType-identified process installs none of the new native-only hooks"];
        UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0,0,320,216)];
        WBKeyViewFixture *key = [[WBKeyViewFixture alloc] initWithFrame:CGRectMake(10,10,80,40)];
        key.backgroundColor = UIColor.grayColor;
        [host addSubview:key];
        UILabel *label = [[UILabel alloc] initWithFrame:key.bounds];
        label.text = @"A"; label.textColor = UIColor.blackColor;
        [key addSubview:label];
        RKApplyBlackKeyboardHost(host);
        [self check:CGColorEqualToColor(key.layer.backgroundColor, UIColor.blackColor.CGColor) &&
            [label.textColor isEqual:UIColor.whiteColor]
            name:@"existing WeType black keycap and white lettering still apply in its process"];
        key.layer.compositingFilter = @"screenBlendMode";
        RKRefreshNativeKey(key);
        [self check:[key.layer.compositingFilter isEqual:@"screenBlendMode"] &&
            objc_getAssociatedObject(key.layer, &RKNativeKeyOwnerKey) == nil
            name:@"native compatibility never adopts or alters a WeType key"];
        [self check:RKNativeSolidGradient() == nil && RKNativeTraitsRecolored == 0 &&
            RKNativeMultiplyChanges == 0 && RKNativeStateRefreshes == 0
            name:@"no native rendering or multiply-color work runs inside WeType"];
        [[NSJSONSerialization dataWithJSONObject:self.results options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/results.json"] atomically:YES];
        return YES;
    }
    BOOL liveColors = [NSProcessInfo.processInfo.arguments containsObject:@"--native-live-colors"];
    BOOL nativeColors = [NSProcessInfo.processInfo.arguments containsObject:@"--native-colors"] || liveColors ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--qq-light-colors"];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--native-keyboard"] ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--native-neon-press"] ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--native-neon-colors"] ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--native-neon-dim"] || nativeColors) {
        if (nativeColors && !liveColors) {
            initialPrefs[@"KeyboardBackgroundColor"] = @[@.08,@.04,@.12];
            initialPrefs[@"KeycapColor"] = @[@.12,@.32,@.24];
            RKSavePreferences(initialPrefs);
        }
        RKBlackReload();
        [self startNativeKeyboardProbe];
        return YES;
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *interfaces = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            NSString *selector = NSStringFromSelector(method_getName(methods[j]));
            if ([selector containsString:@"renderCandidateWord"] ||
                ([name.lowercaseString containsString:@"candidate"] &&
                 ([selector containsString:@"render"] || [selector containsString:@"draw"]))) {
                [interfaces addObject:@{@"class":name, @"selector":selector,
                    @"encoding":[NSString stringWithUTF8String:method_getTypeEncoding(methods[j])]}];
            }
        }
        free(methods);
    }
    free(classes);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/runtime.json"];
    [[NSJSONSerialization dataWithJSONObject:interfaces options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:path atomically:YES];
    self.results = [NSMutableArray array];
    [self testCandidates];
    [self testPreferenceResolution];
    [self testGeometry];
    [self testPureBlack];
    [self testAtlasAndWeType];
    [self testKeyColorsAndPressedStates];
    [self testAdditionalPressedFaces];
    [self testNativePressedState];
    [self testNativeStatePerformance];
    [self testDirectKeySurfaces];
    [self testDockExclusion];
    [self preview];
    [self testEffects];
    dispatch_async(dispatch_get_main_queue(), ^{ [self testNativeSystemCandidate]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 220 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self savePreview];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1600 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self check:self.effect.layer.sublayers.count == 0 name:@"completed waves release all layers"];
        NSString *result = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/results.json"];
        [[NSJSONSerialization dataWithJSONObject:self.results options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:result atomically:YES];
    });
    return YES;
}
- (void)check:(BOOL)passed name:(NSString *)name {
    [self.results addObject:@{@"test":name, @"passed":@(passed)}];
}
- (void)runSettingsProbe {
    [UIView setAnimationsEnabled:NO];
    NSMutableDictionary *report = [NSMutableDictionary dictionary];
    @try {
        void *framework = dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW | RTLD_GLOBAL);
        report[@"frameworkLoaded"] = @(framework != NULL);
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"SettingsProbe.bundle"];
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        Class listClass = NSClassFromString(@"PSListController");
        id host = [listClass new];
        NSDictionary *entry = [NSDictionary dictionaryWithContentsOfFile:
            [path stringByAppendingPathComponent:@"Entry.plist"]][@"entry"];
        BOOL coldEntry = !bundle.loaded && NSClassFromString(@"RKBRootListController") == Nil;
        report[@"coldEntry"] = @(coldEntry);
        typedef NSArray *(*EntryParser)(NSDictionary *, id, id, NSString *, NSBundle *,
            NSString *__autoreleasing *, NSString *__autoreleasing *, id, NSMutableArray *__autoreleasing *);
        EntryParser parse = (EntryParser)dlsym(framework, "SpecifiersFromPlist");
        if (!parse || !entry) [NSException raise:@"RKMissingEntryParser" format:@"Missing Preferences parser or entry"];
        NSMutableArray *bundleControllers = nil;
        NSArray *entries = parse(@{@"items":@[entry]}, nil, host, @"RainbowKeyboardPrefs", bundle,
            NULL, NULL, host, &bundleControllers);
        id specifier = entries.firstObject;
        if (!specifier) [NSException raise:@"RKMissingEntrySpecifier" format:@"Entry did not produce a specifier"];
        ((void (*)(id, SEL, id, id))objc_msgSend)(specifier,
            NSSelectorFromString(@"setProperty:forKey:"), path, @"lazy-bundle");
        // Use the cold bundle entry, not NSClassFromString(root), which hides principal-class bugs.
        ((void (*)(id, SEL, id))objc_msgSend)(host, NSSelectorFromString(@"lazyLoadBundle:"), specifier);
        report[@"bundleLoaded"] = @(bundle.loaded);
        report[@"principalClass"] = NSStringFromClass(bundle.principalClass) ?: @"";
        Class resolved = ((Class (*)(id, SEL))objc_msgSend)(specifier, NSSelectorFromString(@"detailControllerClass"));
        report[@"entryControllerClass"] = NSStringFromClass(resolved) ?: @"";
        BOOL correctEntry = coldEntry && [NSStringFromClass(resolved) isEqual:@"RKBRootListController"] &&
            bundle.principalClass == resolved &&
            [resolved isSubclassOfClass:listClass];
        report[@"entryIsSettingsController"] = @(correctEntry);
        UIViewController *controller = [resolved new];
        if (controller) ((void (*)(id, SEL, id))objc_msgSend)(controller, NSSelectorFromString(@"setSpecifier:"), specifier);
        if (controller) {
            self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:controller];
            [controller loadViewIfNeeded];
            [self.window layoutIfNeeded];
            [controller.view layoutIfNeeded];
            // Preferences and its loaders can insert/remove specifiers after the first load.
            id loadedSpecifiers = [controller valueForKey:@"specifiers"];
            BOOL mutableList = [loadedSpecifiers isKindOfClass:NSMutableArray.class];
            report[@"mutableSpecifierList"] = @(mutableList);
            NSArray *originalSpecifiers = [loadedSpecifiers copy];
            id temporaryGroup = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"PSSpecifier"),
                NSSelectorFromString(@"emptyGroupSpecifier"));
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller,
                NSSelectorFromString(@"addSpecifier:animated:"), temporaryGroup, NO);
            ((void (*)(id, SEL, id, BOOL))objc_msgSend)(controller,
                NSSelectorFromString(@"removeSpecifier:animated:"), temporaryGroup, NO);
            BOOL listEdits = [[controller valueForKey:@"specifiers"] isEqual:originalSpecifiers];
            report[@"frameworkListEdits"] = @(listEdits);
            for (NSUInteger reload = 0; reload < 3; reload++)
                ((void (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"reloadSpecifiers"));
            report[@"repeatedReloads"] = @YES;
            UITableView *table = nil;
            NSMutableArray *pending = [NSMutableArray arrayWithObject:controller.view];
            while (pending.count) {
                UIView *view = pending.lastObject;
                [pending removeLastObject];
                if ([view isKindOfClass:UITableView.class]) { table = (UITableView *)view; break; }
                [pending addObjectsFromArray:view.subviews];
            }
            NSUInteger cells = 0;
            NSUInteger sliderFooters = 0;
            NSIndexPath *opacityIndex = nil;
            NSMutableArray *actions = [NSMutableArray array];
            id (^property)(id, NSString *) = ^id(id specifier, NSString *key) {
                return ((id (*)(id, SEL, id))objc_msgSend)(specifier, NSSelectorFromString(@"propertyForKey:"), key);
            };
            for (NSInteger section = 0; section < [table.dataSource numberOfSectionsInTableView:table]; section++) {
                for (NSInteger row = 0; row < [table.dataSource tableView:table numberOfRowsInSection:section]; row++) {
                    NSIndexPath *index = [NSIndexPath indexPathForRow:row inSection:section];
                    UITableViewCell *cell = [table.dataSource tableView:table
                        cellForRowAtIndexPath:index];
                    if (cell) cells++;
                    id specifier = ((id (*)(id, SEL, id))objc_msgSend)(controller,
                        NSSelectorFromString(@"specifierAtIndexPath:"), index);
                    NSString *action = property(specifier, @"action");
                    if ([action hasPrefix:@"choose"]) [actions addObject:@{@"action":action, @"index":index}];
                    NSString *key = property(specifier, @"key");
                    if ([@[@"Opacity", @"Brightness", @"NeonSaturation", @"Duration", @"Spread", @"Softness",
                        @"CoreStrength", @"MaxEffects", @"BackgroundStrength", @"BackgroundDuration", @"AmbientStrength",
                        @"BackgroundRadius", @"BackgroundBand", @"Hue", @"PressBrightness"] containsObject:key ?: @""]) {
                        NSString *footer = [table.dataSource tableView:table titleForFooterInSection:section];
                        if (footer.length > 20 && [table.dataSource tableView:table numberOfRowsInSection:section] == 1)
                            sliderFooters++;
                    }
                    if ([key isEqual:@"Opacity"]) opacityIndex = index;
                }
            }
            report[@"cells"] = @(cells);
            report[@"sliderFooters"] = @(sliderFooters);
            report[@"passed"] = @(correctEntry && cells == 36 && sliderFooters == 15 && listEdits && mutableList);
            if (opacityIndex) {
                id specifier = ((id (*)(id, SEL, id))objc_msgSend)(controller,
                    NSSelectorFromString(@"specifierAtIndexPath:"), opacityIndex);
                ((void (*)(id, SEL, id))objc_msgSend)(specifier, NSSelectorFromString(@"performSetterWithValue:"), @.57);
                id readback = ((id (*)(id, SEL))objc_msgSend)(specifier, NSSelectorFromString(@"performGetter"));
                BOOL sliderSaved = fabs([readback doubleValue] - .57) < .0001 &&
                    fabs([RKReadStoredPreferences()[@"Opacity"] doubleValue] - .57) < .0001 &&
                    fabs([RKReceiveDisplaySnapshot()[@"Opacity"] doubleValue] - .57) < .0001;
                report[@"sliderPersistsAndTransmits"] = @(sliderSaved);
                report[@"passed"] = @([report[@"passed"] boolValue] && sliderSaved);
                [table scrollToRowAtIndexPath:opacityIndex atScrollPosition:UITableViewScrollPositionTop animated:NO];
                [table layoutIfNeeded];
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:table.bounds.size];
                UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [table drawViewHierarchyInRect:CGRectMake(0, 0, table.bounds.size.width, table.bounds.size.height)
                        afterScreenUpdates:YES];
                }];
                [UIImagePNGRepresentation(image) writeToFile:[NSHomeDirectory()
                    stringByAppendingPathComponent:@"Documents/slider-help.png"] atomically:YES];
            }
            SEL aboutAction = NSSelectorFromString(@"showPackageInfo");
            if ([controller respondsToSelector:aboutAction]) {
                ((void (*)(id, SEL))objc_msgSend)(controller, aboutAction);
                UIViewController *about = controller.navigationController.topViewController;
                [about loadViewIfNeeded];
                [about.view layoutIfNeeded];
                NSUInteger images = 0;
                BOOL hasName = NO;
                NSMutableArray *pending = [NSMutableArray arrayWithObject:about.view];
                while (pending.count) {
                    UIView *view = pending.lastObject;
                    [pending removeLastObject];
                    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) images++;
                    if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqual:@"彩虹键盘光效"]) hasName = YES;
                    [pending addObjectsFromArray:view.subviews];
                }
                BOOL valid = about != controller && images == 3 && hasName;
                report[@"offlineAbout"] = @(valid);
                report[@"passed"] = @([report[@"passed"] boolValue] && valid);
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:self.window.bounds.size];
                UIImage *preview = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];
                }];
                [UIImagePNGRepresentation(preview) writeToFile:[NSHomeDirectory()
                    stringByAppendingPathComponent:@"Documents/about.png"] atomically:YES];
                [controller.navigationController popViewControllerAnimated:NO];
            } else {
                report[@"offlineAbout"] = @NO;
                report[@"passed"] = @NO;
            }
            NSArray *specifiers = [controller valueForKey:@"specifiers"];
            BOOL pressStyleSaved = NO;
            for (id item in specifiers) {
                if (![property(item, @"key") isEqual:@"EffectStyle"]) continue;
                ((void (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"performSetterWithValue:"), @2);
                pressStyleSaved = [RKReadStoredPreferences()[@"EffectStyle"] integerValue] == 2 &&
                    [RKReceiveDisplaySnapshot()[@"EffectStyle"] integerValue] == 2;
            }
            report[@"newStylePersistsAndTransmits"] = @(pressStyleSaved);
            report[@"passed"] = @([report[@"passed"] boolValue] && pressStyleSaved);
            NSUInteger pressSettings = 0;
            for (id item in specifiers) {
                NSString *key = property(item, @"key");
                if (![@[@"PressColorMode", @"PressBrightness"] containsObject:key ?: @""]) continue;
                NSNumber *expected = [key isEqual:@"PressColorMode"] ? @1 : @.78;
                ((void (*)(id, SEL, id))objc_msgSend)(item, NSSelectorFromString(@"performSetterWithValue:"), expected);
                if (fabs([RKReadStoredPreferences()[key] doubleValue] - expected.doubleValue) < .00001 &&
                    fabs([RKReceiveDisplaySnapshot()[key] doubleValue] - expected.doubleValue) < .00001) pressSettings++;
            }
            report[@"pressControlsPersistAndTransmit"] = @(pressSettings == 2);
            report[@"passed"] = @([report[@"passed"] boolValue] && pressSettings == 2);
            NSUInteger switches = 0;
            for (id specifier in specifiers) {
                NSString *key = property(specifier, @"key");
                if (![@[@"CandidateGradient", @"CandidateNative", @"CandidateWeType"] containsObject:key ?: @""]) continue;
                ((void (*)(id, SEL, id, id))objc_msgSend)(controller, NSSelectorFromString(@"setPreferenceValue:specifier:"),
                    @NO, specifier);
                id value = ((id (*)(id, SEL, id))objc_msgSend)(controller, NSSelectorFromString(@"readPreferenceValue:"), specifier);
                if (value && ![value boolValue]) switches++;
            }
            RKCandidateReload();
            BOOL disabled = !RKCandidateFlag(@"CandidateGradient") && !RKCandidateFlag(@"CandidateNative") &&
                !RKCandidateFlag(@"CandidateWeType");
            report[@"switchesPersisted"] = @(switches);
            report[@"runtimeGradientDisabled"] = @(disabled);
            report[@"passed"] = @([report[@"passed"] boolValue] && switches == 3 && disabled);
            [self waitForSettingsCondition:^BOOL {
                return UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
                    controller.view.window != nil && controller.transitionCoordinator == nil;
            } attempts:100 completion:^(BOOL ready) {
                report[@"passed"] = @([report[@"passed"] boolValue] && ready);
                [self probeSettingsColors:controller table:table actions:actions index:0 report:report];
            }];
            return;
        }
    } @catch (NSException *exception) {
        report[@"exception"] = exception.name;
        report[@"reason"] = exception.reason ?: @"";
        report[@"passed"] = @NO;
    }
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/settings.json"] atomically:YES];
}
- (void)waitForSettingsCondition:(BOOL (^)(void))condition attempts:(NSUInteger)attempts
                     completion:(void (^)(BOOL))completion {
    if (condition()) { completion(YES); return; }
    if (!attempts) { completion(NO); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self waitForSettingsCondition:condition attempts:attempts - 1 completion:completion];
    });
}
- (void)probeSettingsColors:(UIViewController *)controller table:(UITableView *)table
                   actions:(NSArray *)actions index:(NSUInteger)index report:(NSMutableDictionary *)report {
    if (index >= actions.count) {
        RKCandidateReload();
        report[@"disabledAfterColorSave"] = @(!RKCandidateFlag(@"CandidateGradient"));
        report[@"passed"] = @([report[@"passed"] boolValue] && actions.count == 5 && !RKCandidateFlag(@"CandidateGradient"));
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/settings.json"] atomically:YES];
        RKSavePreferences([@{@"CandidateGradient":@YES, @"CandidateNative":@YES, @"CandidateWeType":@YES,
            @"KeycapColor":@[@0,@0,@0], @"KeyboardBackgroundColor":@[@0,@0,@0]} mutableCopy]);
        return;
    }
    @try {
        NSIndexPath *row = actions[index][@"index"];
        [table scrollToRowAtIndexPath:row atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        [table layoutIfNeeded];
        [table.delegate tableView:table didSelectRowAtIndexPath:row];
    } @catch (NSException *exception) {
        report[@"exception"] = exception.name;
        report[@"reason"] = exception.reason ?: @"";
        report[@"passed"] = @NO;
    }
    [self waitForSettingsCondition:^BOOL {
        UIViewController *presented = controller.presentedViewController ?: controller.navigationController.presentedViewController;
        return [presented isKindOfClass:UIColorPickerViewController.class] &&
            presented.viewIfLoaded.window != nil && !presented.isBeingPresented;
    } attempts:100 completion:^(BOOL opened) {
    @try {
        UIColorPickerViewController *picker = (id)(controller.presentedViewController ?:
            controller.navigationController.presentedViewController);
        report[actions[index][@"action"]] = @(opened);
        if (!opened) {
            UITableViewCell *cell = [table cellForRowAtIndexPath:actions[index][@"index"]];
            report[[actions[index][@"action"] stringByAppendingString:@"State"]] =
                @{@"class":NSStringFromClass(cell.class) ?: @"none", @"text":cell.textLabel.text ?: @"",
                  @"interactive":@(cell.userInteractionEnabled), @"editingKey":[controller valueForKey:@"editingColorKey"] ?: @""};
        }
        report[@"passed"] = @([report[@"passed"] boolValue] && opened);
        if (opened) {
            [picker loadViewIfNeeded];
            picker.selectedColor = [UIColor colorWithRed:.1 green:.3 blue:.2 alpha:1];
            ((void (*)(id, SEL, id))objc_msgSend)(controller,
                @selector(colorPickerViewControllerDidFinish:), picker);
        }
    } @catch (NSException *exception) {
        report[@"exception"] = exception.name;
        report[@"reason"] = exception.reason ?: @"";
        report[@"passed"] = @NO;
    }
    [self waitForSettingsCondition:^BOOL {
        return controller.presentedViewController == nil && controller.navigationController.presentedViewController == nil;
    } attempts:100 completion:^(BOOL dismissed) {
        report[@"passed"] = @([report[@"passed"] boolValue] && dismissed);
        NSString *key = @{@"chooseCandidateStart":@"CandidateStart", @"chooseCandidateEnd":@"CandidateEnd",
            @"chooseKeyboardBackground":@"KeyboardBackgroundColor", @"chooseKeycapColor":@"KeycapColor",
            @"choosePressColor":@"PressColor"}[actions[index][@"action"]];
        NSArray *saved = RKReadStoredPreferences()[key];
        BOOL colorSaved = [saved isKindOfClass:NSArray.class] && saved.count == 3 &&
            fabs([saved[0] doubleValue] - .1) < .01 && fabs([saved[1] doubleValue] - .3) < .01 &&
            fabs([saved[2] doubleValue] - .2) < .01;
        if ([key isEqual:@"PressColor"]) {
            NSArray *transport = RKReceiveDisplaySnapshot()[key];
            colorSaved &= transport.count == 3 && fabs([transport[0] doubleValue] - .1) < .00002 &&
                fabs([transport[1] doubleValue] - .3) < .00002 && fabs([transport[2] doubleValue] - .2) < .00002;
        }
        report[[actions[index][@"action"] stringByAppendingString:@"Saved"]] = @(colorSaved);
        report[@"passed"] = @([report[@"passed"] boolValue] && colorSaved);
        [self probeSettingsColors:controller table:table actions:actions index:index + 1 report:report];
    }];
    }];
}
- (NSDictionary *)compositedMetricsForKey:(UIView *)view {
    UIWindow *window = view.window;
    if (!window) return @{};
    CGRect frame = [view convertRect:view.bounds toView:window];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:frame.size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextTranslateCTM(context.CGContext, -frame.origin.x, -frame.origin.y);
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];
    return RKImageMetrics(image);
}
- (void)collectNativeViews:(UIView *)view results:(NSMutableArray *)results depth:(NSUInteger)depth {
    if (depth > 20 || results.count >= 150) return;
    NSString *name = NSStringFromClass(view.class);
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"keyboard"] || [lower containsString:@"uikb"] ||
        [lower containsString:@"candidate"] || [lower containsString:@"prediction"] ||
        [lower containsString:@"suggestion"] || [lower containsString:@"label"]) {
        NSMutableDictionary *entry = [@{@"class":name, @"frame":NSStringFromCGRect(view.frame),
            @"parent":view.superview ? NSStringFromClass(view.superview.class) : @"none",
            @"hidden":@(view.hidden)} mutableCopy];
        if ([lower containsString:@"keyboardlayoutstar"]) {
            NSArray<NSValue *> *frames = RKKeyboardKeyFrames(view);
            entry[@"keyCount"] = @(frames.count);
            if (([NSProcessInfo.processInfo.arguments containsObject:@"--native-colors"] ||
                [NSProcessInfo.processInfo.arguments containsObject:@"--native-live-colors"] ||
                [NSProcessInfo.processInfo.arguments containsObject:@"--qq-light-colors"]) && view.window) {
                UIView *snapshotRoot = view.window;
                UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
                format.scale = 1;
                UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:snapshotRoot.bounds.size format:format];
                UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [snapshotRoot drawViewHierarchyInRect:snapshotRoot.bounds afterScreenUpdates:YES];
                }];
                NSData *data = RKTestPixels(image.CGImage);
                const uint8_t *p = (const uint8_t *)data.bytes;
                size_t width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
                NSArray *rgb = RKKeyboardRGB(RKBlackPrefs[@"KeycapColor"]);
                NSUInteger matches = 0;
                for (NSValue *value in frames) {
                    CGRect frame = [view convertRect:value.CGRectValue toView:snapshotRoot];
                    NSInteger x = lround(CGRectGetMinX(frame) + 8), y = lround(CGRectGetMinY(frame) + 8);
                    if (x < 0 || y < 0 || x >= (NSInteger)width || y >= (NSInteger)height) continue;
                    NSUInteger offset = (y * width + x) * 4;
                    BOOL match = YES;
                    for (NSUInteger c = 0; c < 3; c++)
                        match &= abs(p[offset + c] - (int)lround([rgb[c] doubleValue] * 255)) <= 2;
                    matches += match;
                }
                entry[@"paletteFaceMatches"] = @(matches);
                [UIImagePNGRepresentation(image) writeToFile:[NSHomeDirectory()
                    stringByAppendingPathComponent:@"Documents/native-palette.png"] atomically:YES];
            }
        }
        if ([name isEqualToString:@"UIKBKeyView"] && !CGRectIsEmpty(view.bounds)) {
            entry[@"testKeyName"] = RKTestObjectGetter(RKTestObjectGetter(view, @"key"), @"name") ?: @"unknown";
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
            UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [view.layer renderInContext:context.CGContext];
            }];
            entry[@"keyMetrics"] = RKImageMetrics(image);
            // GPU-backed symbols can live outside the key's own bitmap layers.
            BOOL composite = [entry[@"testKeyName"] isEqual:@"International-Key"];
            if (composite) entry[@"compositedMetrics"] = [self compositedMetricsForKey:view];
            SEL activate = NSSelectorFromString(@"changeBackgroundToActiveIfNecessary");
            SEL release = NSSelectorFromString(@"changeBackgroundToEnabled");
            if (RKBlackVoidMethod(view.class, NSStringFromSelector(activate), 2) &&
                RKBlackVoidMethod(view.class, NSStringFromSelector(release), 2)) {
                ((void (*)(id, SEL))[view methodForSelector:activate])(view, activate);
                UIImage *pressed = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [view.layer renderInContext:context.CGContext];
                }];
                entry[@"pressedKeyMetrics"] = RKImageMetrics(pressed);
                if (composite) entry[@"pressedCompositedMetrics"] = [self compositedMetricsForKey:view];
                ((void (*)(id, SEL))[view methodForSelector:release])(view, release);
                UIImage *released = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                    [view.layer renderInContext:context.CGContext];
                }];
                entry[@"releasedKeyMetrics"] = RKImageMetrics(released);
                if (composite) entry[@"releasedCompositedMetrics"] = [self compositedMetricsForKey:view];
            }
            if ([RKTestObjectGetter(RKTestObjectGetter(view, @"key"), @"name") isEqual:@"Return-Key"]) {
                entry[@"actionKeyMetrics"] = entry[@"keyMetrics"];
                [UIImagePNGRepresentation(image) writeToFile:[NSHomeDirectory()
                    stringByAppendingPathComponent:@"Documents/native-action-key.png"] atomically:YES];
            }
        }
        [results addObject:entry];
    }
    for (UIView *child in view.subviews) [self collectNativeViews:child results:results depth:depth + 1];
}
- (void)startNativeKeyboardProbe {
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    unsigned int configCount = 0;
    Method *configMethods = class_copyMethodList(object_getClass(NSClassFromString(@"UIKBRenderConfig")), &configCount);
    NSMutableArray *configAPI = [NSMutableArray array];
    for (unsigned int i = 0; i < configCount; i++)
        [configAPI addObject:@{@"selector":NSStringFromSelector(method_getName(configMethods[i])),
            @"encoding":@(method_getTypeEncoding(configMethods[i]))}];
    free(configMethods);
    [[NSJSONSerialization dataWithJSONObject:configAPI options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/render-config-api.json"] atomically:YES];
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(20, 100, self.window.bounds.size.width - 40, 48)];
    field.backgroundColor = UIColor.whiteColor;
    field.textColor = UIColor.blackColor;
    field.font = [UIFont systemFontOfSize:22];
    field.keyboardAppearance = UIKeyboardAppearanceLight;
    field.autocorrectionType = UITextAutocorrectionTypeYes;
    field.returnKeyType = UIReturnKeySearch;
    [self.window.rootViewController.view addSubview:field];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [field becomeFirstResponder];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [field insertText:@"hello"];
    });
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--native-live-colors"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            NSMutableDictionary *prefs = [RKReadStoredPreferences() mutableCopy];
            prefs[@"KeyboardBackgroundColor"] = @[@.08,@.04,@.12];
            prefs[@"KeycapColor"] = @[@.12,@.32,@.24];
            RKSavePreferences(prefs);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSMutableArray *views = [NSMutableArray array];
        NSMutableSet *windows = [NSMutableSet setWithObject:self.window];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
        NSMutableArray *blackViews = [NSMutableArray array];
        for (UIView *view in RKBlackViews) {
            if (view.window) [windows addObject:view.window];
            [blackViews addObject:NSStringFromClass(view.class)];
        }
        for (UIWindow *window in windows) [self collectNativeViews:window results:views depth:0];
        NSMutableArray *candidateViews = [NSMutableArray array];
        for (UIView *view in RKCandidateViews) [candidateViews addObject:NSStringFromClass(view.class)];
        NSDictionary *report = @{@"firstResponder":@(field.isFirstResponder), @"views":views,
            @"appLightAppearance":@(self.window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleLight),
            @"qqAppearanceHook":@(RKQQAppearanceHookInstalled), @"qqAppearanceOverrides":@(RKQQAppearanceOverrides),
            @"blackViews":blackViews, @"candidateViews":candidateViews,
            @"pureBlackConfigHook":@(RKBlackConfigHooksInstalled), @"nativeCandidateHook":@(RKTUIHookInstalled),
            @"pureBlackActionHook":@(RKBlackActionHookInstalled),
            @"nativePredictionHook":@(RKPredictionHookInstalled), @"nativeLabelDraws":@(RKNativeLabelDraws),
            @"nativeGlyphDraws":@(RKTUIGlyphDraws),
            @"nativeTraitsRecolored":@(RKNativeTraitsRecolored), @"nativeStateHooks":@(RKNativeStateHooksInstalled),
            @"nativeStateRefreshes":@(RKNativeStateRefreshes), @"nativeMultiplyChanges":@(RKNativeMultiplyChanges)};
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-keyboard.json"] atomically:YES];
        RKWriteNativeDiagnostic();
        for (UIView *view in RKBlackViews.allObjects) {
            if ([NSStringFromClass(view.class) isEqualToString:@"UIKeyboardLayoutStar"] && view.window) {
                [self previewNativeWave:view];
                break;
            }
        }
    });
}
- (void)previewNativeWave:(UIView *)host {
    RKFixtureEffect *effect = [[RKFixtureEffect alloc] initWithFrame:host.bounds];
    effect.keyFrames = RKKeyboardKeyFrames(host);
    if (effect.keyFrames.count < 3) return;
    BOOL colorful = [NSProcessInfo.processInfo.arguments containsObject:@"--native-neon-colors"];
    BOOL dim = [NSProcessInfo.processInfo.arguments containsObject:@"--native-neon-dim"];
    BOOL pressMode = [NSProcessInfo.processInfo.arguments containsObject:@"--native-neon-press"] || colorful || dim;
    [effect setValue:pressMode ? @{@"EffectStyle":@2, @"Duration":@1.2,
        @"PressColorMode":@(colorful ? 0 : 1), @"PressColor":@[@1,@0,@.85], @"PressBrightness":@(dim ? .2 : 1)} :
        @{@"Opacity":@.85} forKey:@"config"];
    [effect setValue:@.55 forKey:@"hue"];
    [host addSubview:effect];
    CGRect key = effect.keyFrames[effect.keyFrames.count / 2].CGRectValue;
    UIImage *(^snapshot)(void) = ^UIImage *{
        UIWindow *window = host.window;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
        return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
        }];
    };
    CGRect keyOnWindow = [host convertRect:key toView:host.window];
    UIImage *before = pressMode ? snapshot() : nil;
    [effect showRippleAtPoint:CGPointMake(CGRectGetMidX(key), CGRectGetMidY(key))];
    if (colorful) {
        for (NSNumber *offset in @[@(-1), @1]) {
            CGRect adjacent = effect.keyFrames[effect.keyFrames.count / 2 + offset.integerValue].CGRectValue;
            [effect showRippleAtPoint:CGPointMake(CGRectGetMidX(adjacent), CGRectGetMidY(adjacent))];
        }
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 220 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        UIWindow *window = host.window;
        if (!window) return;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
        }];
        [UIImagePNGRepresentation(image) writeToFile:[NSHomeDirectory()
            stringByAppendingPathComponent:pressMode ? @"Documents/native-neon-press.png" :
                @"Documents/native-wave.png"] atomically:YES];
        if (pressMode) {
            NSDictionary *plain = [self pressPixelMetrics:before rect:keyOnWindow];
            NSDictionary *lit = [self pressPixelMetrics:image rect:keyOnWindow];
            NSMutableDictionary *pressReport = [@{@"before":plain, @"lit":lit,
                @"mode":colorful ? @"colorful" : @"single", @"brightness":@(dim ? .2 : 1),
                @"keyFrame":NSStringFromCGRect(keyOnWindow),
                @"pulseCount":@(effect.layer.sublayers.count)} mutableCopy];
            BOOL solid = YES;
            NSMutableSet *faceColors = [NSMutableSet set];
            for (CALayer *pulse in effect.layer.sublayers) {
                CALayer *cap = pulse.sublayers.firstObject.sublayers.firstObject;
                CAKeyframeAnimation *fade = (id)[cap animationForKey:@"neonPressFade"];
                solid &= ![cap isKindOfClass:CAGradientLayer.class] && [fade.values.firstObject doubleValue] == 1;
                [faceColors addObject:[UIColor colorWithCGColor:cap.backgroundColor]];
            }
            pressReport[@"fullOpacitySolidFaces"] = @(solid);
            BOOL passed = [lit[@"colored"] integerValue] > 500 &&
                [lit[@"white"] integerValue] >= MAX(20, [plain[@"white"] integerValue] * .6) &&
                [lit[@"dominantColorPixels"] integerValue] > [lit[@"colored"] integerValue] * .8 &&
                effect.layer.sublayers.count == (colorful ? 3 : 1) &&
                faceColors.count == effect.layer.sublayers.count && solid;
            pressReport[@"passed"] = @(passed);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                UIImage *after = snapshot();
                NSDictionary *restored = [self pressPixelMetrics:after rect:keyOnWindow];
                pressReport[@"restored"] = restored;
                pressReport[@"releasedLayers"] = @(effect.layer.sublayers.count == 0);
                pressReport[@"passed"] = @(passed && effect.layer.sublayers.count == 0 &&
                    [restored[@"colored"] integerValue] <= [plain[@"colored"] integerValue] + 10);
                [[NSJSONSerialization dataWithJSONObject:pressReport options:NSJSONWritingPrettyPrinted error:nil]
                    writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-neon-press.json"] atomically:YES];
            });
        }
    });
}
- (NSDictionary *)pressPixelMetrics:(UIImage *)image rect:(CGRect)rect {
    NSData *data = RKTestPixels(image.CGImage);
    const uint8_t *pixels = (const uint8_t *)data.bytes;
    size_t width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
    NSUInteger white = 0, colored = 0;
    NSMutableDictionary<NSNumber *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSUInteger dominant = 0;
    uint32_t dominantRGB = 0;
    for (NSInteger y = MAX(0, floor(CGRectGetMinY(rect) * image.scale));
         y < MIN((NSInteger)height, ceil(CGRectGetMaxY(rect) * image.scale)); y++) {
        for (NSInteger x = MAX(0, floor(CGRectGetMinX(rect) * image.scale));
             x < MIN((NSInteger)width, ceil(CGRectGetMaxX(rect) * image.scale)); x++) {
            const uint8_t *p = pixels + (y * width + x) * 4;
            int lo = MIN(p[0], MIN(p[1], p[2])), hi = MAX(p[0], MAX(p[1], p[2]));
            white += lo > 230;
            if (hi > 8 && hi - lo > 8) {
                colored++;
                uint32_t rgb = (p[0] << 16) | (p[1] << 8) | p[2];
                NSUInteger count = [counts[@(rgb)] unsignedIntegerValue] + 1;
                counts[@(rgb)] = @(count);
                if (count > dominant) { dominant = count; dominantRGB = rgb; }
            }
        }
    }
    return @{@"white":@(white), @"colored":@(colored), @"dominantColorPixels":@(dominant),
        @"dominantRGB":@[@((dominantRGB >> 16) & 255), @((dominantRGB >> 8) & 255), @(dominantRGB & 255)]};
}
- (void)testCandidates {
    RKCandidatePrefs = @{};
    UIView *native = [UIKeyboardCandidateRKFixture new];
    UIView *wetype = [RKWeTypeCandidateFixture new];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 240, 44)];
    UILabel *wx = [[WBTextItemLabel alloc] initWithFrame:label.frame];
    for (UILabel *item in @[label, wx]) {
        item.text = @"Rainbow keyboard";
        item.font = [UIFont boldSystemFontOfSize:24];
        item.textColor = UIColor.whiteColor;
    }
    [native addSubview:label];
    [wetype addSubview:wx];
    UIImage *nativeImage = RKLabelImage(label), *wxImage = RKLabelImage(wx);
    NSDictionary *metrics = RKImageMetrics(nativeImage);
    [self check:[metrics[@"cyan"] integerValue] > 30 && [metrics[@"pink"] integerValue] > 30
        name:@"native candidate glyphs contain both gradient endpoints"];
    [self check:[UIImagePNGRepresentation(nativeImage) isEqual:UIImagePNGRepresentation(wxImage)]
        name:@"native and WeType use identical per-label gradients"];
    [UIImagePNGRepresentation(nativeImage) writeToFile:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents/candidate-gradient.png"] atomically:YES];
    RKCandidatePrefs = @{@"CandidateNative":@NO};
    [self check:[RKImageMetrics(RKLabelImage(label))[@"colored"] integerValue] == 0
        name:@"native switch restores original text"];
    [self check:[RKImageMetrics(RKLabelImage(wx))[@"colored"] integerValue] > 50
        name:@"native switch does not disable WeType"];
    RKCandidatePrefs = @{@"CandidateWeType":@NO};
    [self check:[RKImageMetrics(RKLabelImage(wx))[@"colored"] integerValue] == 0
        name:@"WeType switch restores original text without native double tint"];
    RKCandidatePrefs = @{@"CandidateGradient":@NO};
    [self check:[RKImageMetrics(RKLabelImage(label))[@"colored"] integerValue] == 0
        name:@"gradient master switch restores original text"];
    RKCandidatePrefs = @{};
    [label removeFromSuperview];
    UIView *ordinary = [UIView new];
    [ordinary addSubview:label];
    [self check:[RKImageMetrics(RKLabelImage(label))[@"colored"] integerValue] == 0
        name:@"ordinary application labels are never tinted"];
    [self check:[RKCandidateColor(@[@(NAN), @0, @1], UIColor.whiteColor) isEqual:UIColor.whiteColor]
        name:@"invalid color components use a finite fallback"];
    UIKeyboardCandidateRKDrawFixture *draw = [[UIKeyboardCandidateRKDrawFixture alloc]
        initWithFrame:CGRectMake(0, 0, 200, 90)];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:draw.bounds.size];
    UIImage *custom = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [draw drawLayer:draw.layer inContext:context.CGContext];
    }];
    metrics = RKImageMetrics(custom);
    [self check:[metrics[@"cyan"] integerValue] > 30 && [metrics[@"pink"] integerValue] > 30
        name:@"native custom NSString and attributed drawing receive gradients"];
    [UIImagePNGRepresentation(custom) writeToFile:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents/custom-gradient.png"] atomically:YES];
}
- (void)testNativeSystemCandidate {
    Class cls = NSClassFromString(@"TUICandidateLabel");
    [self check:cls != Nil && RKTUIHookInstalled name:@"real TextInputUI candidate class hooks after framework loads"];
    [self check:RKPredictionHookInstalled name:@"native prediction cells use the normal-label gradient path"];
    if (!cls || ![cls isSubclassOfClass:UIView.class]) return;
    UIView *label = [[cls alloc] initWithFrame:CGRectMake(0, 0, 240, 52)];
    [label setValue:@"原生候选词" forKey:@"text"];
    [label setValue:[UIFont systemFontOfSize:26] forKey:@"font"];
    [label setValue:UIColor.whiteColor forKey:@"textColor"];
    RKCandidatePrefs = @{};
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:label.bounds.size];
    UIImage *gradient = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [label drawRect:label.bounds];
    }];
    NSDictionary *metrics = RKImageMetrics(gradient);
    [self check:[metrics[@"cyan"] integerValue] > 30 && [metrics[@"pink"] integerValue] > 30 &&
        RKTUIGlyphDraws > 0 name:@"real CoreText candidate glyphs contain both gradient endpoint colors"];
    [UIImagePNGRepresentation(gradient) writeToFile:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents/native-system-candidate.png"] atomically:YES];
    RKCandidatePrefs = @{@"CandidateNative":@NO};
    UIImage *original = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [label drawRect:label.bounds];
    }];
    [self check:[RKImageMetrics(original)[@"colored"] integerValue] == 0
        name:@"real CoreText candidate restores original color when disabled"];
    RKCandidatePrefs = @{};
    RKWriteNativeDiagnostic();
}
- (void)testPureBlack {
    [self check:RKQQKeyboardBundle(@"com.tencent.mqq") &&
        !RKQQKeyboardBundle(@"com.tencent.wetype.keyboard") && !RKQQKeyboardBundle(@"com.tencent.xin") &&
        !RKQQKeyboardBundle(@"com.apple.Preferences") && !RKQQAppearanceHookInstalled &&
        RKQQKeyboardAppearance(UIKeyboardAppearanceLight) == UIKeyboardAppearanceLight
        name:@"QQ appearance compatibility never changes WeType or other application keyboards"];
    [self check:RKBlackConfigHooksInstalled name:@"native keyboard render configuration ABI is supported"];
    Class configClass = NSClassFromString(@"UIKBRenderConfig");
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    id config = [configClass defaultConfig];
    NSNumber *originalOpacity = [config valueForKey:@"keycapOpacity"];
    NSNumber *originalLight = [config valueForKey:@"lightKeyboard"];
    RKBlackPrefs = @{};
    [self testActionKeyImage];
    [self testGrayKeyImages];
    UIView *keyHost = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 180, 100)];
    for (NSUInteger i = 0; i < 3; i++) {
        [keyHost addSubview:[[UIButton alloc] initWithFrame:CGRectMake(5 + i * 55, 10, 45, 60)]];
    }
    RKUpdateBlackKeycaps(keyHost);
    CAShapeLayer *keycaps = objc_getAssociatedObject(keyHost, &RKBlackKeycapsKey);
    UIGraphicsImageRenderer *keyRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(8, 8)];
    UIImage *face = [keyRenderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.magentaColor setFill];
        UIRectFill(CGRectMake(0, 0, 8, 8));
        CGContextTranslateCTM(context.CGContext, -20, -20);
        [keycaps renderInContext:context.CGContext];
    }];
    NSDictionary *faceMetrics = RKImageMetrics(face);
    [self check:keycaps && [faceMetrics[@"maxChannel"] integerValue] == 0 &&
        [faceMetrics[@"opaque"] isEqual:faceMetrics[@"pixelCount"]]
        name:@"keycap layer itself is opaque black over a colored background"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKUpdateBlackKeycaps(keyHost);
    [self check:keycaps.hidden name:@"disabling pure black hides the opaque keycap layer"];
    RKBlackPrefs = @{};
    [self check:[[config valueForKey:@"keycapOpacity"] doubleValue] == 0 &&
        [[config valueForKey:@"lightKeycapOpacity"] doubleValue] == 0 &&
        [[config valueForKey:@"whiteText"] boolValue] && ![[config valueForKey:@"lightKeyboard"] boolValue]
        name:@"native gray keycap fill is removed while white legends remain enabled"];
    Class backdropClass = NSClassFromString(@"UIKBBackdropView");
    UIVisualEffectView *backdrop = [[backdropClass alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    backdrop.frame = CGRectMake(0, 0, 100, 50);
    [backdrop setNeedsLayout];
    [backdrop layoutIfNeeded];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:backdrop.bounds.size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [backdrop.layer renderInContext:context.CGContext];
    }];
    NSDictionary *metrics = RKImageMetrics(image);
    [self check:[metrics[@"maxChannel"] integerValue] == 0 &&
        [metrics[@"opaque"] isEqual:metrics[@"pixelCount"]]
        name:@"real keyboard backdrop renders opaque RGB 0,0,0 rather than dark gray"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    [backdrop setNeedsLayout];
    [backdrop layoutIfNeeded];
    CALayer *surface = objc_getAssociatedObject(backdrop, &RKBlackSurfaceKey);
    [self check:surface.hidden && [[config valueForKey:@"keycapOpacity"] isEqual:originalOpacity] &&
        [[config valueForKey:@"lightKeyboard"] isEqual:originalLight]
        name:@"pure black switch restores backdrop visibility and native rendering getters"];
    RKBlackPrefs = @{@"Enabled":@NO};
    [self check:!RKBlackEnabled() name:@"master disable also disables the pure black theme"];
    RKBlackPrefs = @{};
}
- (void)testActionKeyImage {
    [self check:RKBlackActionHookInstalled name:@"native action-key cache hooks have supported signatures"];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(80, 40)];
    UIImage *source = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIColor colorWithRed:0 green:.48 blue:1 alpha:1] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 80, 40) cornerRadius:6] fill];
        [@"Q" drawAtPoint:CGPointMake(30, 6) withAttributes:@{
            NSFontAttributeName:[UIFont systemFontOfSize:24], NSForegroundColorAttributeName:UIColor.whiteColor}];
    }];
    CALayer *layer = [CALayer layer];
    layer.contents = (__bridge id)source.CGImage;
    RKUpdateBlackActionImage(layer, YES);
    id transformed = layer.contents;
    UIImage *black = [UIImage imageWithCGImage:(__bridge CGImageRef)transformed];
    NSDictionary *metrics = RKImageMetrics(black);
    [self check:[metrics[@"colored"] integerValue] == 0 && [metrics[@"maxChannel"] integerValue] == 255 &&
        [metrics[@"opaque"] isEqual:RKImageMetrics(source)[@"opaque"]]
        name:@"blue action-key bitmap becomes black while white glyphs and alpha remain"];
    CGImageRef corner = CGImageCreateWithImageInRect(black.CGImage, CGRectMake(12, 12, 5, 5));
    [self check:[RKImageMetrics([UIImage imageWithCGImage:corner])[@"maxChannel"] integerValue] == 0
        name:@"action-key face pixels are exactly RGB 0,0,0"];
    CGImageRelease(corner);
    RKUpdateBlackActionImage(layer, YES);
    [self check:layer.contents == transformed name:@"action-key bitmap conversion is cached"];
    RKUpdateBlackActionImage(layer, NO);
    [self check:layer.contents == (__bridge id)source.CGImage
        name:@"disabling pure black restores the original action-key image"];
    UIImage *red = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.redColor setFill];
        UIRectFill(CGRectMake(0, 0, 80, 40));
    }];
    layer.contents = (__bridge id)red.CGImage;
    RKUpdateBlackActionImage(layer, YES);
    [self check:layer.contents == (__bridge id)red.CGImage
        name:@"unknown action-key color formats are left unchanged"];
}
- (void)testGrayKeyImages {
    for (NSNumber *shade in @[@76, @38, @120]) {
        UIImage *source = RKGrayKeyFixture(shade.unsignedIntegerValue);
        UIView *key = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 80, 40)];
        CALayer *container = [CALayer layer];
        CALayer *layer = [CALayer layer];
        container.frame = key.bounds;
        layer.frame = key.bounds;
        RKUpdateBlackSurface(key, NO);
        [key.layer addSublayer:container];
        [container addSublayer:layer];
        layer.contents = (__bridge id)source.CGImage;
        RKUpdateBlackActionKey(key);
        NSData *data = RKTestPixels((__bridge CGImageRef)layer.contents);
        const uint8_t *p = (const uint8_t *)data.bytes;
        NSData *original = RKTestPixels(source.CGImage);
        const uint8_t *s = (const uint8_t *)original.bytes;
        BOOL alpha = YES, face = YES;
        for (NSUInteger i = 0; i < 80 * 40; i++) {
            alpha &= p[i * 4 + 3] == s[i * 4 + 3];
            NSUInteger x = i % 80;
            if (x >= 8 && x <= 20) face &= p[i * 4] == 0 && p[i * 4 + 1] == 0 && p[i * 4 + 2] == 0;
        }
        NSUInteger white = (15 * 80 + 37) * 4, antialias = (15 * 80 + 34) * 4;
        NSUInteger color = (18 * 80 + 57) * 4;
        [self check:face && alpha && p[white] == 255 && abs(p[antialias] - 127) <= 2 &&
            p[color] == s[color] && p[color + 1] == s[color + 1] && p[color + 2] == s[color + 2]
            name:[NSString stringWithFormat:@"gray %@ cached key face and vertical gradient become black; white, antialias, color and alpha survive", shade]];
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:key.bounds.size format:format];
        UIImage *composited = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [key.layer renderInContext:context.CGContext];
        }];
        NSData *compositedPixels = RKTestPixels(composited.CGImage);
        const uint8_t *c = (const uint8_t *)compositedPixels.bytes;
        NSUInteger sample = (20 * 80 + 15) * 4;
        [self check:c[sample] == 0 && c[sample + 1] == 0 && c[sample + 2] == 0 && c[sample + 3] == 255
            name:@"gray cached imagery above the black underlay no longer covers it with gray"];
        id result = layer.contents;
        RKUpdateBlackActionKey(key);
        [self check:layer.contents == result name:@"nested ordinary key bitmap reuses its converted cache"];
        RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
        RKUpdateBlackActionKey(key);
        [self check:layer.contents == (__bridge id)source.CGImage
            name:@"ordinary key restores its exact original gray bitmap when disabled"];
        RKBlackPrefs = @{};
        RKUpdateBlackActionKey(key);
        UIImage *replacement = RKGrayKeyFixture(55);
        layer.contents = (__bridge id)replacement.CGImage;
        RKUpdateBlackActionImage(layer, NO);
        [self check:layer.contents == (__bridge id)replacement.CGImage
            name:@"disable restores the newest system image after its automatic recoloring"];
    }
    UIImage *source = RKGrayKeyFixture(76);
    Class layerClass = NSClassFromString(@"_UIKBKeyViewLayer");
    CALayer *native = [layerClass layer];
    native.contents = (__bridge id)source.CGImage;
    [self check:RKBlackLayerHookInstalled && native.contents != (__bridge id)source.CGImage &&
        [RKImageMetrics([UIImage imageWithCGImage:(__bridge CGImageRef)native.contents])[@"gray"] integerValue] < 40
        name:@"real native key-image layer converts gray contents immediately on assignment"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKUpdateBlackActionImage(native, NO);
    [self check:native.contents == (__bridge id)source.CGImage
        name:@"native layer setter does not recurse while restoring the source"];
    RKBlackPrefs = @{};

    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(80, 40)];
    UIImage *glyph = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [@"Q" drawAtPoint:CGPointMake(30, 6) withAttributes:@{
            NSFontAttributeName:[UIFont systemFontOfSize:24], NSForegroundColorAttributeName:UIColor.whiteColor}];
    }];
    CALayer *isolated = [CALayer layer];
    isolated.contents = (__bridge id)glyph.CGImage;
    RKUpdateBlackActionImage(isolated, YES);
    [self check:isolated.contents == (__bridge id)glyph.CGImage
        name:@"standalone antialiased white legend is not mistaken for a gray keycap"];
    RKInstallBlackHooks();
    RKInstallBlackHooks();
    [self check:RKBlackActionHookInstalled && RKBlackLayerHookInstalled
        name:@"repeated late-load hook installation is idempotent"];
    CALayer *backgroundAssigned = [layerClass layer];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        backgroundAssigned.contents = (__bridge id)source.CGImage;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self check:backgroundAssigned.contents != (__bridge id)source.CGImage &&
                [RKImageMetrics([UIImage imageWithCGImage:(__bridge CGImageRef)backgroundAssigned.contents])[@"gray"] integerValue] < 40
                name:@"off-main cached image assignment is converted on the main queue"];
        });
    });
}
- (void)testAtlasAndWeType {
    RKBlackPrefs = @{};
    UIImage *atlas = RKAtlasFixture();
    CGImageRef transformed = RKCreateBlackKeyboardAtlas(atlas.CGImage, NO);
    [self check:transformed != NULL name:@"iOS 17 sized 1200x660 combined atlas is not rejected by per-key size limits"];
    if (transformed) {
        NSData *data = RKTestPixels(transformed), *original = RKTestPixels(atlas.CGImage);
        const uint8_t *p = (const uint8_t *)data.bytes, *s = (const uint8_t *)original.bytes;
        BOOL black = YES, white = YES, alpha = YES;
        for (NSUInteger row = 0; row < 3; row++) {
            for (NSUInteger col = 0; col < 10; col++) {
                NSUInteger face = ((row * 210 + 35) * 1200 + col * 120 + 35) * 4;
                NSUInteger glyph = ((row * 210 + 80) * 1200 + col * 120 + 53) * 4;
                black &= p[face] == 0 && p[face + 1] == 0 && p[face + 2] == 0;
                white &= p[glyph] == 255 && p[glyph + 1] == 255 && p[glyph + 2] == 255;
            }
        }
        for (NSUInteger i = 0; i < data.length / 4; i++) alpha &= p[i * 4 + 3] == s[i * 4 + 3];
        [self check:black && white && alpha
            name:@"mixed gray modifier, letter and blue return bodies in a whole atlas become black without losing legends or alpha"];
        CGImageRelease(transformed);
    }
    RKAtlasPlaneFixture *plane = [[RKAtlasPlaneFixture alloc] initWithFrame:CGRectMake(0, 0, 400, 220)];
    UIImageView *background = [[UIImageView alloc] initWithImage:atlas];
    UIImageView *caps = [[UIImageView alloc] initWithImage:atlas];
    plane->_keyBackgrounds = background;
    plane->_keyCaps = caps;
    [plane addSubview:background];
    [plane addSubview:caps];
    RKUpdateBlackKeyplane(plane);
    [self check:background.layer.hidden && !caps.layer.hidden
        name:@"semantic keyplane background is suppressed without hiding the glyph atlas"];
    background.layer.hidden = NO;
    [self check:background.layer.hidden name:@"native background refresh cannot unhide a suppressed surface"];
    [self check:[RKImageMetrics(background.image)[@"maxChannel"] integerValue] == 0 &&
        [RKImageMetrics(caps.image)[@"maxChannel"] integerValue] == 255 &&
        [RKImageMetrics(caps.image)[@"colored"] integerValue] == 0
        name:@"keyplane background-only and glyph atlas ivars receive distinct treatments"];
    UIImage *cached = caps.image;
    RKUpdateBlackKeyplane(plane);
    [self check:caps.image == cached name:@"whole keyboard atlas is cached across repeated layouts"];
    caps.image = RKAtlasFixture();
    [self check:[RKImageMetrics(caps.image)[@"colored"] integerValue] == 0
        name:@"late UIImageView assignment cannot restore a blue atlas face"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKUpdateBlackKeyplane(plane);
    [self check:!background.layer.hidden name:@"disabling restores the most recent requested background visibility"];
    [self check:background.image == atlas && [RKImageMetrics(caps.image)[@"colored"] integerValue] > 100
        name:@"disabling restores original whole-keyboard images, not the processed copies"];
    RKBlackPrefs = @{};

    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 400, 240)];
    WBKeyViewFixture *key = [[WBKeyViewFixture alloc] initWithFrame:CGRectMake(20, 50, 80, 40)];
    key.backgroundColor = UIColor.darkGrayColor;
    UIImage *source = RKGrayKeyFixture(76);
    UIImageView *image = [[UIImageView alloc] initWithImage:source];
    image.frame = key.bounds;
    UILabel *label = [[UILabel alloc] initWithFrame:key.bounds];
    label.attributedText = [[NSAttributedString alloc] initWithString:@"A"
        attributes:@{NSForegroundColorAttributeName:UIColor.blackColor, NSFontAttributeName:[UIFont systemFontOfSize:20]}];
    [key addSubview:image];
    [key addSubview:label];
    [host addSubview:key];
    WBCandidateBarFixture *candidates = [[WBCandidateBarFixture alloc] initWithFrame:CGRectMake(0, 0, 400, 40)];
    UIButton *candidate = [UIButton buttonWithType:UIButtonTypeCustom];
    candidate.frame = CGRectMake(0, 0, 80, 30);
    candidate.backgroundColor = UIColor.grayColor;
    [candidate setTitle:@"Candidate" forState:UIControlStateNormal];
    [candidates addSubview:candidate];
    [host addSubview:candidates];
    RKScanWeTypeKeys(host, host, 0);
    [self check:CGColorEqualToColor(key.layer.backgroundColor, UIColor.blackColor.CGColor) &&
        [RKImageMetrics(image.image)[@"gray"] integerValue] < 40 &&
        [[label.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] isEqual:UIColor.whiteColor]
        name:@"WeType-style key view receives a black live background, persistent black bitmap and white attributed legend"];
    [self check:CGColorEqualToColor(candidate.layer.backgroundColor, UIColor.grayColor.CGColor) &&
        !objc_getAssociatedObject(candidate.titleLabel, &RKBlackLabelManagedKey)
        name:@"WeType candidate strip is excluded from keycap recoloring"];
    key.backgroundColor = UIColor.lightGrayColor;
    image.image = RKGrayKeyFixture(38);
    label.attributedText = [[NSAttributedString alloc] initWithString:@"B"
        attributes:@{NSForegroundColorAttributeName:UIColor.redColor}];
    [self check:CGColorEqualToColor(key.layer.backgroundColor, UIColor.blackColor.CGColor) &&
        [RKImageMetrics(image.image)[@"gray"] integerValue] < 40 &&
        [[label.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] isEqual:UIColor.whiteColor]
        name:@"later skin refreshes cannot overwrite managed WeType key colors, images or attributed legends"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKScanWeTypeKeys(host, host, 0);
    [self check:CGColorEqualToColor(key.layer.backgroundColor, UIColor.lightGrayColor.CGColor) &&
        [RKImageMetrics(image.image)[@"gray"] integerValue] > 100 &&
        [[label.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] isEqual:UIColor.redColor]
        name:@"WeType theme disable restores the latest skin values"];
    RKBlackPrefs = @{};
    RKScanWeTypeKeys(host, host, 0);
    [candidates addSubview:label];
    [host addSubview:image];
    image.image = source;
    label.attributedText = [[NSAttributedString alloc] initWithString:@"Candidate"
        attributes:@{NSForegroundColorAttributeName:UIColor.redColor}];
    [self check:image.image == source &&
        [[label.attributedText attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] isEqual:UIColor.redColor]
        name:@"reused image and text views stop being themed after leaving their key subtree"];
    RKBlackPrefs = @{@"NativeKeyboard":@NO};
    [self check:RKBlackEnabledForBundle(@"com.tencent.wetype.keyboard") &&
        !RKBlackEnabledForBundle(@"com.apple.test") name:@"WeType pure black no longer depends on the native keyboard toggle"];
    RKBlackPrefs = @{@"WeChatKeyboard":@NO};
    [self check:!RKBlackEnabledForBundle(@"com.tencent.wetype.keyboard") &&
        RKBlackEnabledForBundle(@"com.apple.test") name:@"WeType toggle does not disable native pure black"];
    uint64_t old = (UINT64_C(0xA7) << 56) | (UINT64_C(1) << 52);
    uint64_t newer = (UINT64_C(0xA8) << 56) | (UINT64_C(1) << 52) | (UINT64_C(1) << 55);
    [self check:RKDecodeColorState(old)[@"WeChatKeyboard"] == nil &&
        [RKDecodeColorState(newer)[@"WeChatKeyboard"] boolValue]
        name:@"preference transport adds WeType without treating older messages as an explicit disable"];
    NSDictionary *probe = RKDecodeBlackProbe(RKBlackProbeState(31, 999, 2, 3, 4));
    [self check:[probe[@"available"] boolValue] && [probe[@"enabled"] boolValue] &&
        [probe[@"backgroundOperations"] integerValue] == 255 && [probe[@"atlasImages"] integerValue] == 2 &&
        [probe[@"weTypeKeyVisits"] integerValue] == 4 && [probe[@"minutesSinceReport"] integerValue] <= 1 &&
        ![RKDecodeBlackProbe(0)[@"available"] boolValue]
        name:@"compact diagnostic status handles missing reports and saturates counters without recording input"];
    RKBlackPrefs = @{};
}
- (void)testDirectKeySurfaces {
    RKBlackPrefs = @{};
    WBPaintedKeyFixture *key = [[WBPaintedKeyFixture alloc] initWithFrame:CGRectMake(0, 0, 80, 40)];
    UIImage *before = RKDrawViewFixture(key);
    [self check:[RKImageMetrics(before)[@"gray"] integerValue] > 500
        name:@"unmarked ordinary custom drawing remains gray"];
    RKUpdateBlackActionKey(key);
    UIImage *after = RKDrawViewFixture(key);
    NSDictionary *metrics = RKImageMetrics(after);
    [UIImagePNGRepresentation(after) writeToFile:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents/direct-key.png"] atomically:YES];
    NSDictionary *drawProbe = @{@"metrics":metrics, @"draws":@(RKBlackDirectDraws),
        @"converted":@(RKBlackDirectConversions)};
    [[NSJSONSerialization dataWithJSONObject:drawProbe options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/direct-key.json"] atomically:YES];
    NSData *directPixels = RKTestPixels(after.CGImage);
    const uint8_t *direct = (const uint8_t *)directPixels.bytes;
    NSUInteger facePixel = (20 * 80 + 15) * 4;
    [self check:direct[facePixel] == 0 && direct[facePixel + 1] == 0 &&
        direct[facePixel + 2] == 0 && direct[facePixel + 3] == 255 &&
        [metrics[@"maxChannel"] integerValue] == 255 && RKBlackDirectConversions > 0
        name:@"direct UIView key face is exactly black with its white legend and antialiased edges intact"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    [self check:[RKImageMetrics(RKDrawViewFixture(key))[@"gray"] integerValue] > 500
        name:@"direct drawing bypass restores original gray when disabled"];
    RKBlackPrefs = @{};

    for (NSNumber *opacity in @[@.25, @.5, @.75]) {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(80, 40) format:format];
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[UIColor colorWithWhite:76 / 255.0 alpha:opacity.doubleValue] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 80, 40) cornerRadius:5] fill];
            [UIColor.whiteColor setFill];
            UIRectFill(CGRectMake(36, 8, 5, 23));
        }];
        CALayer *layer = [CALayer layer];
        layer.contents = (__bridge id)image.CGImage;
        RKUpdateBlackActionImage(layer, YES);
        NSData *pixels = RKTestPixels((__bridge CGImageRef)layer.contents);
        NSData *original = RKTestPixels(image.CGImage);
        const uint8_t *p = (const uint8_t *)pixels.bytes, *s = (const uint8_t *)original.bytes;
        NSUInteger face = (20 * 80 + 15) * 4, glyph = (20 * 80 + 38) * 4;
        BOOL alpha = YES;
        for (NSUInteger i = 0; i < 80 * 40; i++) alpha &= p[i * 4 + 3] == s[i * 4 + 3];
        [self check:p[face] <= 1 && p[face + 1] <= 1 && p[face + 2] <= 1 &&
            p[glyph] == 255 && alpha name:[NSString stringWithFormat:
            @"translucent matte %@ turns black without discarding alpha or white characters", opacity]];
    }

    UIView *shapeKey = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 80, 40)];
    CAShapeLayer *face = [CAShapeLayer layer];
    face.frame = shapeKey.bounds;
    face.path = [UIBezierPath bezierPathWithRoundedRect:face.bounds cornerRadius:5].CGPath;
    face.fillColor = UIColor.grayColor.CGColor;
    [shapeKey.layer addSublayer:face];
    CAShapeLayer *glyph = [CAShapeLayer layer];
    glyph.frame = CGRectMake(33, 8, 14, 24);
    glyph.path = [UIBezierPath bezierPathWithRect:glyph.bounds].CGPath;
    glyph.fillColor = UIColor.whiteColor.CGColor;
    [shapeKey.layer addSublayer:glyph];
    RKUpdateBlackActionKey(shapeKey);
    [self check:CGColorEqualToColor(face.fillColor, UIColor.blackColor.CGColor) &&
        CGColorEqualToColor(glyph.fillColor, UIColor.whiteColor.CGColor)
        name:@"large filled shape key face becomes black while the small white glyph shape stays white"];
    face.fillColor = UIColor.lightGrayColor.CGColor;
    [self check:CGColorEqualToColor(face.fillColor, UIColor.blackColor.CGColor)
        name:@"shape redraw cannot replace the black face with gray"];
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = shapeKey.bounds;
    gradient.colors = @[(id)UIColor.grayColor.CGColor, (id)UIColor.darkGrayColor.CGColor];
    [shapeKey.layer insertSublayer:gradient atIndex:0];
    RKUpdateBlackActionKey(shapeKey);
    [self check:CGColorEqualToColor((__bridge CGColorRef)gradient.colors.firstObject, UIColor.blackColor.CGColor) &&
        CGColorEqualToColor((__bridge CGColorRef)gradient.colors.lastObject, UIColor.blackColor.CGColor)
        name:@"full-size gradient key backgrounds become black"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKUpdateBlackActionKey(shapeKey);
    [self check:CGColorEqualToColor(face.fillColor, UIColor.lightGrayColor.CGColor) &&
        CGColorEqualToColor((__bridge CGColorRef)gradient.colors.firstObject, UIColor.grayColor.CGColor)
        name:@"disabling restores latest shape fill and original gradient colors"];
    RKBlackPrefs = @{};
}
- (void)testDockExclusion {
    UIView *container = [[RKKeyboardItemContainerFixture alloc] initWithFrame:CGRectMake(0, 0, 390, 330)];
    UIView *host = [[RKKeyboardLayoutStarFixture alloc] initWithFrame:CGRectMake(0, 0, 390, 240)];
    [container addSubview:host];
    UIButton *letter = nil;
    for (NSUInteger i = 0; i < 3; i++) {
        letter = [[UIButton alloc] initWithFrame:CGRectMake(10 + i * 45, 20, 35, 45)];
        [host addSubview:letter];
    }
    UIView *dock = [[RKKeyboardDockFixture alloc] initWithFrame:CGRectMake(0, 245, 390, 70)];
    UIButton *tool = [[UIButton alloc] initWithFrame:CGRectMake(10, 5, 40, 50)];
    [dock addSubview:tool];
    [container addSubview:dock];
    [self check:RKKeyboardEffectHost(tool) == nil && RKKeyboardEffectHost(letter) == host &&
        RKKeyboardEffectHost(container) == nil name:@"dock tools cannot become a neon host through a remote keyboard container"];
    dock.frame = CGRectMake(0, 150, 390, 60);
    [host addSubview:dock];
    [self check:RKKeyboardKeyFrames(host).count == 3 name:@"dock buttons inside a keyboard are excluded from key geometry"];
    tool.backgroundColor = UIColor.grayColor;
    RKScanWeTypeKeys(host, host, 0);
    [self check:CGColorEqualToColor(tool.layer.backgroundColor, UIColor.grayColor.CGColor)
        name:@"WeType black key traversal uses the same dock exclusions as the effect"];
}
- (void)testKeyColorsAndPressedStates {
    RKBlackPrefs = @{};
    [self check:[RKKeyboardRGB(nil) isEqual:@[@0,@0,@0]] &&
        [RKKeyboardRGB(@[@(NAN), @(-1), @2]) isEqual:@[@0,@0,@1]]
        name:@"keyboard palette defaults to pure black and clamps invalid components"];
    NSDictionary *palette = @{@"KeyboardBackgroundColor":@[@.08,@.16,@.24], @"KeycapColor":@[@.2,@.4,@.6]};
    NSDictionary *decoded = RKDecodeKeyboardPalette(RKKeyboardPaletteState(palette));
    [self check:fabs([decoded[@"KeycapColor"][1] doubleValue] - .4) < .005 &&
        fabs([decoded[@"KeyboardBackgroundColor"][0] doubleValue] - .08) < .005 &&
        !RKDecodeKeyboardPalette(0) name:@"independent base and key colors survive compact extension transport"];
    [self check:RKPublishKeyboardPalette(palette) &&
        [RKReceiveKeyboardPalette() isEqual:decoded] name:@"palette publishes and reads back through Darwin notify"];
    RKPublishKeyboardPalette(@{});
    UIGraphicsImageRenderer *maskRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(80, 40)];
    UIImage *mask = [maskRenderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [@"W" drawAtPoint:CGPointMake(25, 5) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:28],
            NSForegroundColorAttributeName:UIColor.blackColor}];
    }];
    CGImageRef untouched = RKCreateColoredKeyboardAtlas(mask.CGImage, NO, .2, .4, .6);
    [self check:untouched == NULL name:@"black glyph-mask artwork is never treated as a recolorable key body"];
    if (untouched) CGImageRelease(untouched);

    RKBlackPrefs = palette;
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 200)];
    for (NSUInteger i = 0; i < 3; i++)
        [host addSubview:[[UIButton alloc] initWithFrame:CGRectMake(10 + i * 90, 10, 80, 40)]];
    RKUpdateBlackSurface(host, NO);
    RKUpdateBlackKeycaps(host);
    CALayer *base = objc_getAssociatedObject(host, &RKBlackSurfaceKey);
    CAShapeLayer *caps = objc_getAssociatedObject(host, &RKBlackKeycapsKey);
    [self check:CGColorEqualToColor(base.backgroundColor, RKKeyboardColor(palette, @"KeyboardBackgroundColor").CGColor) &&
        CGColorEqualToColor(caps.fillColor, RKKeycapColor().CGColor)
        name:@"background and keycap settings drive separate surface layers"];

    UIImage *source = RKGrayKeyFixture(76);
    CALayer *imageLayer = [CALayer layer];
    imageLayer.contents = (__bridge id)source.CGImage;
    RKUpdateBlackActionImage(imageLayer, YES);
    NSData *pixels = RKTestPixels((__bridge CGImageRef)imageLayer.contents);
    const uint8_t *p = (const uint8_t *)pixels.bytes;
    NSUInteger face = (20 * 80 + 15) * 4, glyph = (15 * 80 + 37) * 4;
    [self check:abs(p[face] - 51) <= 1 && abs(p[face+1] - 102) <= 1 &&
        abs(p[face+2] - 153) <= 1 && p[glyph] == 255
        name:@"cached key imagery uses the selected RGB face while preserving white legends"];
    RKBlackPrefs = @{@"KeycapColor":@[@.6,@.2,@.4]};
    RKUpdateBlackActionImage(imageLayer, YES);
    pixels = RKTestPixels((__bridge CGImageRef)imageLayer.contents);
    p = (const uint8_t *)pixels.bytes;
    [self check:abs(p[face] - 153) <= 1 && abs(p[face+1] - 51) <= 1 && abs(p[face+2] - 102) <= 1
        name:@"changing key color invalidates the image cache and retints from its original"];
    RKUpdateBlackActionImage(imageLayer, NO);
    [self check:imageLayer.contents == (__bridge id)source.CGImage
        name:@"disabling custom color restores the original image after multiple palette edits"];
    RKBlackPrefs = @{};

    UIImage *pressed = RKGrayKeyFixture(220);
    UIImageView *imageView = [[UIImageView alloc] initWithImage:source highlightedImage:pressed];
    imageView.frame = CGRectMake(0, 0, 80, 40);
    UIView *key = [[UIView alloc] initWithFrame:imageView.frame];
    [key addSubview:imageView];
    RKRefreshBlackKeyState(key);
    NSData *highlightPixels = RKTestPixels(imageView.highlightedImage.CGImage);
    const uint8_t *h = (const uint8_t *)highlightPixels.bytes;
    [self check:h[face] == 0 && h[face+1] == 0 && h[face+2] == 0 && h[glyph] == 255
        name:@"light gray pressed artwork above the old matte threshold is recolored before display"];
    BOOL stable = YES;
    for (NSUInteger i = 0; i < 30; i++) {
        imageView.highlighted = i % 2;
        UIImage *visible = imageView.highlighted ? imageView.highlightedImage : imageView.image;
        NSData *data = RKTestPixels(visible.CGImage);
        const uint8_t *v = (const uint8_t *)data.bytes;
        stable &= v[face] == 0 && v[face+1] == 0 && v[face+2] == 0;
    }
    [self check:stable name:@"thirty press and release transitions retain the same pure black image face"];
    UIImage *newPressed = RKGrayKeyFixture(200);
    imageView.highlightedImage = newPressed;
    [self check:imageView.highlightedImage != newPressed
        name:@"late highlighted-image skin updates are also intercepted"];
    RKBlackPrefs = palette;
    RKRefreshBlackKeyState(key);
    pixels = RKTestPixels(imageView.highlightedImage.CGImage);
    p = (const uint8_t *)pixels.bytes;
    [self check:abs(p[face] - 51) <= 1 && abs(p[face+1] - 102) <= 1 && abs(p[face+2] - 153) <= 1
        name:@"palette changes recolor both normal and highlighted image caches"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKRefreshBlackKeyState(key);
    [self check:imageView.image == source && imageView.highlightedImage == newPressed
        name:@"theme disable restores both image slots including the newest pressed artwork"];
    RKBlackPrefs = @{};

    WBPressedKeyFixture *button = [[WBPressedKeyFixture alloc] initWithFrame:CGRectMake(0, 0, 80, 40)];
    RKRefreshBlackKeyState(button);
    button.highlighted = YES;
    [self check:CGColorEqualToColor(button.pressedFace.backgroundColor, UIColor.blackColor.CGColor)
        name:@"new pressed layer attached after UIControl state change is recolored synchronously"];
    button.highlighted = NO;
    [self check:CGColorEqualToColor(button.pressedFace.backgroundColor, UIColor.blackColor.CGColor)
        name:@"new release-state layer stays black without waiting for a layout pass"];
    CABasicAnimation *flash = [CABasicAnimation animationWithKeyPath:@"backgroundColor"];
    flash.fromValue = (id)UIColor.lightGrayColor.CGColor;
    flash.toValue = (id)UIColor.grayColor.CGColor;
    flash.duration = 1;
    [button.pressedFace addAnimation:flash forKey:@"press-flash"];
    [self check:![button.pressedFace animationForKey:@"press-flash"]
        name:@"managed key background color animation cannot flash gray over the selected color"];
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1; scale.toValue = @.97; scale.duration = 1;
    [button.pressedFace addAnimation:scale forKey:@"press-motion"];
    [self check:[button.pressedFace animationForKey:@"press-motion"] != nil
        name:@"non-color press animations are preserved"];
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[flash, scale];
    group.duration = 1;
    [button.pressedFace addAnimation:group forKey:@"group"];
    CAAnimationGroup *kept = (CAAnimationGroup *)[button.pressedFace animationForKey:@"group"];
    [self check:kept.animations.count == 1 &&
        [((CAPropertyAnimation *)kept.animations.firstObject).keyPath isEqual:@"transform.scale"]
        name:@"grouped press animations remove only color changes and retain motion"];
    CALayer *late = [CALayer layer];
    late.frame = button.bounds;
    late.backgroundColor = UIColor.grayColor.CGColor;
    [late addAnimation:flash forKey:@"pre-attached-flash"];
    [button.layer addSublayer:late];
    [self check:![late animationForKey:@"pre-attached-flash"] &&
        CGColorEqualToColor(late.backgroundColor, UIColor.blackColor.CGColor)
        name:@"color animation installed before attachment is removed when the key adopts its layer"];
    CALayer *ordinary = [CALayer layer];
    ordinary.backgroundColor = UIColor.grayColor.CGColor;
    [ordinary addAnimation:flash forKey:@"ordinary"];
    [self check:[ordinary animationForKey:@"ordinary"] != nil &&
        CGColorEqualToColor(ordinary.backgroundColor, UIColor.grayColor.CGColor)
        name:@"ordinary app layers keep their original colors and animations"];
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    button.highlighted = YES;
    [self check:CGColorEqualToColor(button.pressedFace.backgroundColor, UIColor.lightGrayColor.CGColor)
        name:@"disabling custom theme permits the original pressed color"];

    RKBlackPrefs = palette;
    UIView *shapeKey = [[UIView alloc] initWithFrame:CGRectMake(0,0,80,40)];
    shapeKey.backgroundColor = UIColor.grayColor;
    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.frame = shapeKey.bounds;
    shape.path = [UIBezierPath bezierPathWithRect:shape.bounds].CGPath;
    shape.fillColor = UIColor.grayColor.CGColor;
    [shapeKey.layer addSublayer:shape];
    RKRefreshBlackKeyState(shapeKey);
    [self check:CGColorEqualToColor(shape.fillColor, RKKeycapColor().CGColor) &&
        CGColorEqualToColor(shapeKey.layer.backgroundColor, RKKeycapColor().CGColor)
        name:@"shape and solid key backgrounds use the custom key color"];
    RKBlackPrefs = @{};
    RKRefreshBlackKeyState(shapeKey);
    [self check:CGColorEqualToColor(shape.fillColor, UIColor.blackColor.CGColor) &&
        CGColorEqualToColor(shapeKey.layer.backgroundColor, UIColor.blackColor.CGColor)
        name:@"shape and solid color caches update when returning to pure black"];
    NSMutableDictionary *live = [palette mutableCopy];
    live[@"RKSettingsRevision"] = @(RKPreferencesRevision(RKReadStoredPreferences()) + 1);
    RKPublishPreferences(live);
    RKBlackReload();
    [self check:CGColorEqualToColor(base.backgroundColor, RKKeyboardColor(RKBlackPrefs, @"KeyboardBackgroundColor").CGColor) &&
        CGColorEqualToColor(shape.fillColor, RKKeycapColor().CGColor)
        name:@"live preference reload updates existing base and key surfaces safely"];
    RKPublishPreferences(@{@"RKSettingsRevision":@(RKPreferencesRevision(live) + 1)});
    RKBlackReload();
    RKBlackPrefs = @{};
}
- (void)testPreferenceResolution {
    NSMutableDictionary *display = [@{@"RKSettingsRevision":@1234, @"KeycapColor":@[@.2,@.6,@.3],
        @"KeyboardBackgroundColor":@[@.03,@.02,@.01], @"CandidateStart":@[@.2,@.5,@.9],
        @"CandidateEnd":@[@.9,@.4,@.1], @"CandidateGradient":@NO, @"AmbientGlow":@NO,
        @"BackgroundFeedback":@YES, @"RippleEnabled":@YES} mutableCopy];
    for (NSString *key in RKDisplayNumbers()) display[key] = @.37;
    uint64_t words[RKDisplayWordCount];
    RKEncodeDisplaySnapshot(display, words);
    uint64_t digest = RKDisplayChecksum(words);
    NSDictionary *snapshot = RKDecodeDisplaySnapshot(words, digest);
    BOOL scalars = snapshot != nil;
    for (NSString *key in RKDisplayNumbers()) scalars &= fabs([snapshot[key] doubleValue] - .37) < .000001;
    [self check:scalars && ![snapshot[@"AmbientGlow"] boolValue] && ![snapshot[@"CandidateGradient"] boolValue] &&
        fabs([snapshot[@"KeycapColor"][1] doubleValue] - .6) < .00002
        name:@"full display snapshot carries both palettes, every slider and disabled switches"];
    words[5] ^= 1;
    [self check:RKDecodeDisplaySnapshot(words, digest) == nil &&
        RKDecodeDisplaySnapshot(words, UINT64_MAX) == nil
        name:@"mixed or interrupted cross-process writes cannot become a valid settings snapshot"];
    NSDictionary *defaulted = RKMergeDisplaySnapshot(@{@"RKSettingsRevision":@10, @"Opacity":@.1,
        @"CandidateGradient":@YES}, @{@"RKSettingsRevision":@20, @"CandidateGradient":@NO});
    [self check:defaulted[@"Opacity"] == nil && ![defaulted[@"CandidateGradient"] boolValue]
        name:@"complete newer snapshots remove stale values rather than reviving previous settings"];
    [self check:[RKMergeDisplaySnapshot(@{@"RKSettingsRevision":@30, @"Opacity":@.8}, snapshot)[@"Opacity"] doubleValue] != .8 &&
        [RKMergeDisplaySnapshot(@{@"RKSettingsRevision":@2000, @"Opacity":@.8}, snapshot)[@"Opacity"] doubleValue] == .8
        name:@"newer snapshots win in sandboxed apps while newer saved settings remain authoritative"];
    display[@"Opacity"] = @(NAN);
    RKEncodeDisplaySnapshot(display, words);
    [self check:RKDecodeDisplaySnapshot(words, RKDisplayChecksum(words))[@"Opacity"] == nil
        name:@"non-finite display values fall back to existing renderer defaults"];
    display[@"PressColorMode"] = @1;
    display[@"PressBrightness"] = @.83;
    display[@"PressColor"] = @[@.92,@.21,@.7];
    RKEncodeDisplaySnapshot(display, words);
    NSDictionary *pressSnapshot = RKDecodeDisplaySnapshot(words, RKDisplayChecksum(words));
    [self check:[pressSnapshot[@"PressColorMode"] integerValue] == 1 &&
        fabs([pressSnapshot[@"PressBrightness"] doubleValue] - .83) < .00001 &&
        fabs([pressSnapshot[@"PressColor"][0] doubleValue] - .92) < .00002 &&
        fabs([pressSnapshot[@"Preset"] doubleValue] - .37) < .00001 &&
        fabs([pressSnapshot[@"CandidateStart"][1] doubleValue] - .5) < .00002 &&
        fabs([pressSnapshot[@"KeycapColor"][1] doubleValue] - .6) < .00002 &&
        ![pressSnapshot[@"CandidateGradient"] boolValue]
        name:@"press color extension preserves old v2 palette flag and preset fields without overlap"];
    NSDictionary *legacyMerge = RKMergeDisplaySnapshot(pressSnapshot,
        @{@"RKSettingsRevision":@1235, @"CandidateGradient":@NO});
    [self check:legacyMerge[@"PressBrightness"] == nil && legacyMerge[@"PressColor"] == nil &&
        legacyMerge[@"PressColorMode"] == nil
        name:@"older complete snapshots clear stale press options so renderer defaults remain predictable"];
    display[@"PressBrightness"] = @(NAN);
    display[@"PressColor"] = @[@1, NSNull.null, @0];
    RKEncodeDisplaySnapshot(display, words);
    NSDictionary *invalidPress = RKDecodeDisplaySnapshot(words, RKDisplayChecksum(words));
    [self check:invalidPress && !invalidPress[@"PressBrightness"] && !invalidPress[@"PressColor"]
        name:@"invalid press brightness and colors never publish unusable rendering data"];
    NSDictionary *oldOn = @{@"CandidateGradient":@YES};
    NSDictionary *off = @{@"CandidateGradient":@NO};
    [self check:![RKResolvePreferences(off, oldOn)[@"CandidateGradient"] boolValue]
        name:@"legacy transport cannot override an explicitly disabled stored gradient"];
    NSDictionary *newOff = @{@"CandidateGradient":@NO, @"RKSettingsRevision":@20};
    NSDictionary *oldRevision = @{@"CandidateGradient":@YES, @"RKSettingsRevision":@10};
    [self check:![RKResolvePreferences(newOff, oldRevision)[@"CandidateGradient"] boolValue] &&
        ![RKResolvePreferences(oldRevision, newOff)[@"CandidateGradient"] boolValue]
        name:@"newest committed disable wins regardless of file or transport origin"];
    [self check:![RKNewestPreferences(oldRevision, newOff)[@"CandidateGradient"] boolValue] &&
        ![RKNewestPreferences(newOff, oldRevision)[@"CandidateGradient"] boolValue]
        name:@"a stale readable preferences file cannot override a newer saved domain"];
    [self check:[RKResolvePreferences(newOff, @{@"CandidateGradient":@YES, @"RKSettingsRevision":@30})
        [@"CandidateGradient"] boolValue] name:@"a later explicit enable still works after a disable"];
    [self check:![RKResolvePreferencesSnapshot(@{}, oldOn, UINT64_MAX, UINT64_MAX)[@"CandidateGradient"] boolValue] &&
        ![RKResolvePreferencesSnapshot(@{}, oldOn, 10, 20)[@"CandidateGradient"] boolValue]
        name:@"incomplete transport cannot default a sandboxed keyboard gradient back on"];
    [self check:![RKResolvePreferencesSnapshot(newOff, oldOn, UINT64_MAX, UINT64_MAX)[@"CandidateGradient"] boolValue] &&
        [RKResolvePreferencesSnapshot(@{}, oldOn, 30, 30)[@"CandidateGradient"] boolValue]
        name:@"committed snapshots remain usable after a concurrent settings write"];

    UIView *native = [UIKeyboardCandidateRKFixture new];
    UILabel *label = [[WBTextItemLabel alloc] initWithFrame:CGRectMake(0, 0, 240, 44)];
    label.text = @"Rainbow keyboard";
    label.font = [UIFont systemFontOfSize:24];
    label.textColor = UIColor.whiteColor;
    [native addSubview:label];
    RKCandidatePrefs = @{@"CandidateWeType":@NO, @"CandidateNative":@YES};
    NSDictionary *metrics = RKImageMetrics(RKLabelImage(label));
    [self check:[metrics[@"colored"] integerValue] == 0
        name:@"disabled WeType label cannot regain a gradient through the native UILabel hook"];
    RKCandidatePrefs = @{};
    RKLabelImage(label);
    [RKCandidateViews addObject:label];
    label.layer.contents = (__bridge id)RKLabelImage(label).CGImage;
    NSMutableDictionary *prefs = [RKReadStoredPreferences() mutableCopy];
    prefs[@"CandidateGradient"] = @NO;
    RKSavePreferences(prefs);
    RKCandidateReload();
    [self check:label.layer.contents == nil && [RKImageMetrics(RKLabelImage(label))[@"colored"] integerValue] == 0
        name:@"saving disable drops cached gradient pixels and redraws original text"];
    NSDictionary *cached = RKReadEffectivePreferences();
    NSUInteger reads = RKStoredPreferenceReads;
    CFTimeInterval start = CACurrentMediaTime();
    BOOL same = YES;
    for (NSUInteger i = 0; i < 200; i++) same &= RKReadEffectivePreferences() == cached;
    [self check:same && RKStoredPreferenceReads == reads
        name:@"200 unchanged hot-path preference reads perform zero disk synchronizations"];
    NSLog(@"RK preference cache: 200 reads %.3f ms", (CACurrentMediaTime() - start) * 1000);
    notify_set_state(RKDisplayToken(RKDisplayWordCount), UINT64_MAX);
    [self check:![RKReadEffectivePreferences()[@"CandidateGradient"] boolValue]
        name:@"cached disabled gradient remains disabled during an interrupted commit"];
    reads = RKStoredPreferenceReads;
    for (NSUInteger i = 0; i < 200; i++) RKReadEffectivePreferences();
    [self check:RKStoredPreferenceReads == reads
        name:@"missing or incomplete transport does not cause disk reads on every keypress"];
    prefs[@"CandidateGradient"] = @YES;
    RKSavePreferences(prefs);
    [self check:[RKReadEffectivePreferences()[@"CandidateGradient"] boolValue]
        name:@"new saved commits invalidate the hot-path cache immediately"];
    RKCandidateReload();
    RKCandidatePrefs = @{};
}
- (void)testAdditionalPressedFaces {
    RKBlackPrefs = @{};
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(80, 40) format:format];
    UIImage *(^image)(UIColor *, UIColor *) = ^UIImage *(UIColor *face, UIColor *ink) {
        return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [face setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,80,40) cornerRadius:5] fill];
            [ink setFill];
            UIRectFill(CGRectMake(36, 14, 5, 12));
        }];
    };
    NSUInteger facePixel = (20 * 80 + 15) * 4, glyphPixel = (20 * 80 + 38) * 4;
    NSArray *colors = @[UIColor.whiteColor, UIColor.redColor,
        [UIColor colorWithRed:.6 green:.15 blue:.7 alpha:1], [UIColor colorWithWhite:.98 alpha:1]];
    for (UIColor *color in colors) {
        UIImage *source = image(color, [color isEqual:UIColor.whiteColor] ||
            [color isEqual:colors.lastObject] ? UIColor.blackColor : UIColor.whiteColor);
        UIView *key = [[UIView alloc] initWithFrame:CGRectMake(0,0,80,40)];
        RKRefreshBlackKeyState(key);
        UIImageView *view = [[UIImageView alloc] initWithFrame:key.bounds];
        view.highlightedImage = source;
        [key addSubview:view];
        view.highlighted = YES;
        NSData *bytes = RKTestPixels(view.highlightedImage.CGImage);
        const uint8_t *p = (const uint8_t *)bytes.bytes;
        [self check:p[facePixel] == 0 && p[facePixel+1] == 0 && p[facePixel+2] == 0 && p[glyphPixel] == 255
            name:[NSString stringWithFormat:@"non-gray full-face pressed artwork %@ becomes black with visible white ink", color]];
        RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
        RKRefreshBlackKeyState(key);
        [self check:view.highlightedImage == source name:@"unknown-color pressed artwork restores its original image when disabled"];
        RKBlackPrefs = @{};
    }
    UIImage *normal = image(UIColor.grayColor, UIColor.whiteColor);
    UIImage *highlighted = image(UIColor.redColor, UIColor.whiteColor);
    UIImage *selected = image(UIColor.whiteColor, UIColor.blackColor);
    UIButton *button = [[UIButton alloc] initWithFrame:CGRectMake(0,0,80,40)];
    [button setBackgroundImage:normal forState:UIControlStateNormal];
    [button setBackgroundImage:highlighted forState:UIControlStateHighlighted];
    [button setBackgroundImage:selected forState:UIControlStateSelected | UIControlStateHighlighted];
    UIImage *originalDisabled = [button backgroundImageForState:UIControlStateDisabled];
    NSMutableDictionary *debug = [@{@"initialNormal":@([button backgroundImageForState:0] == normal),
        @"initialHighlighted":@([button backgroundImageForState:1] == highlighted),
        @"initialCombined":@([button backgroundImageForState:5] == selected), @"initialDisabledNil":@(originalDisabled == nil)} mutableCopy];
    RKRefreshBlackKeyState(button);
    BOOL black = YES;
    for (NSNumber *state in @[@(UIControlStateNormal), @(UIControlStateHighlighted),
                              @(UIControlStateSelected | UIControlStateHighlighted)]) {
        UIImage *current = [button backgroundImageForState:state.unsignedIntegerValue];
        NSData *bytes = RKTestPixels(current.CGImage);
        const uint8_t *p = (const uint8_t *)bytes.bytes;
        black &= p[facePixel] == 0 && p[facePixel+1] == 0 && p[facePixel+2] == 0 && p[glyphPixel] == 255;
    }
    [self check:black name:@"UIButton normal, highlighted and selected-highlighted backgrounds share the selected key color"];
    UIImage *replacement = image([UIColor colorWithRed:.8 green:.3 blue:.1 alpha:1], UIColor.whiteColor);
    [button setBackgroundImage:replacement forState:UIControlStateHighlighted];
    [self check:[button backgroundImageForState:UIControlStateHighlighted] != replacement
        name:@"later button-state background image updates cannot bypass key coloring"];
    NSMutableDictionary *cacheDebug = [NSMutableDictionary dictionary];
    NSDictionary *cache = objc_getAssociatedObject(button, &RKBlackButtonImagesKey);
    for (NSNumber *state in cache) {
        NSDictionary *entry = cache[state];
        cacheDebug[state.stringValue] = @{@"normal":@(entry[@"source"] == normal), @"highlighted":@(entry[@"source"] == highlighted),
            @"selected":@(entry[@"source"] == selected), @"replacement":@(entry[@"source"] == replacement),
            @"currentIsResult":@([button backgroundImageForState:state.unsignedIntegerValue] == entry[@"result"])};
    }
    debug[@"cache"] = cacheDebug;
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKRefreshBlackKeyState(button);
    [self check:[button backgroundImageForState:UIControlStateNormal] == normal name:@"normal button background restores original"];
    [self check:[button backgroundImageForState:UIControlStateHighlighted] == replacement name:@"highlighted button background restores latest original"];
    [self check:[button backgroundImageForState:UIControlStateSelected | UIControlStateHighlighted] == selected name:@"combined button state background restores original"];
    [self check:[button backgroundImageForState:UIControlStateDisabled] == originalDisabled name:@"absent button state background keeps its original fallback"];
    debug[@"finalNormal"] = @([button backgroundImageForState:0] == normal);
    debug[@"finalHighlighted"] = @([button backgroundImageForState:1] == replacement);
    debug[@"finalCombined"] = @([button backgroundImageForState:5] == selected);
    [[NSJSONSerialization dataWithJSONObject:debug options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/button-state-debug.json"] atomically:YES];
    RKBlackPrefs = @{};

    UIView *key = [[UIView alloc] initWithFrame:CGRectMake(0,0,80,40)];
    RKRefreshBlackKeyState(key);
    CAShapeLayer *shape = [CAShapeLayer layer];
    [key.layer addSublayer:shape];
    shape.frame = key.bounds;
    shape.fillColor = UIColor.redColor.CGColor;
    shape.path = [UIBezierPath bezierPathWithRoundedRect:key.bounds cornerRadius:5].CGPath;
    [self check:CGColorEqualToColor(shape.fillColor, UIColor.blackColor.CGColor)
        name:@"pressed shape filled after attachment and sizing is identified without a layout pass"];
    shape.path = [UIBezierPath bezierPathWithRect:CGRectMake(32,10,10,20)].CGPath;
    [self check:CGColorEqualToColor(shape.fillColor, UIColor.redColor.CGColor)
        name:@"a former face restored to a small glyph is no longer recolored"];
}
- (void)testNativePressedState {
    RKBlackPrefs = @{};
    [self check:RKNativeStateHooksInstalled && RKNativeTraitsHookInstalled && RKNativeMultiplyHookInstalled
        name:@"native state and render-trait hooks have checked runtime signatures"];
    [self check:!RKNativeKeyboardProcess(@"com.tencent.wetype.keyboard") &&
        RKNativeKeyboardProcess(@"com.apple.Preferences")
        name:@"native-only compatibility hooks are excluded from the WeType process"];
    UIView *key = [[NSClassFromString(@"UIKBKeyView") alloc] initWithFrame:CGRectMake(0,0,80,40)];
    [self check:RKNativeKeyView(key) && !RKNativeKeyView([WBKeyViewFixture new])
        name:@"native compatibility requires an actual system key class, never a WeType-style key"];
    RKRefreshNativeKey(key);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(3,3) format:format];
    UIImage *gray = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.grayColor setFill]; UIRectFill(CGRectMake(0,0,3,3));
    }];
    CALayer *face = [CALayer layer];
    face.frame = key.bounds;
    face.contentsCenter = CGRectMake(.33,.33,.34,.34);
    face.contents = (__bridge id)gray.CGImage;
    [key.layer addSublayer:face];
    NSData *pixels = RKTestPixels((__bridge CGImageRef)face.contents);
    [self check:((const uint8_t *)pixels.bytes)[0] == 0 && face.contents != (__bridge id)gray.CGImage
        name:@"native tiny stretchable functional-key backgrounds are recolored on attachment"];
    RKMarkNativeBackground(key, face);
    face.compositingFilter = @"screenBlendMode";
    [self check:face.compositingFilter == nil name:@"native pressed blend cannot brighten a full key face"];
    CALayer *glyph = [CALayer layer];
    glyph.frame = CGRectMake(35,10,10,20);
    [key.layer addSublayer:glyph];
    glyph.compositingFilter = @"screenBlendMode";
    [self check:[glyph.compositingFilter isEqual:@"screenBlendMode"]
        name:@"small native glyph compositing is not removed"];
    CALayer *fullGlyph = [CALayer layer];
    fullGlyph.frame = key.bounds;
    [key.layer addSublayer:fullGlyph];
    fullGlyph.compositingFilter = @"screenBlendMode";
    [self check:[fullGlyph.compositingFilter isEqual:@"screenBlendMode"]
        name:@"full-size native character layers retain their compositing unless identified as a background"];
    BOOL stable = YES;
    for (NSUInteger i = 0; i < 30; i++) {
        face.contents = (__bridge id)gray.CGImage;
        face.compositingFilter = i % 2 ? @"screenBlendMode" : @"plusL";
        RKRefreshNativeKey(key);
        pixels = RKTestPixels((__bridge CGImageRef)face.contents);
        stable &= ((const uint8_t *)pixels.bytes)[0] == 0 && face.compositingFilter == nil;
    }
    [self check:stable name:@"thirty native press/release background and blend changes keep pure black"];
    CABasicAnimation *blend = [CABasicAnimation animationWithKeyPath:@"compositingFilter"];
    blend.toValue = @"screenBlendMode";
    [face addAnimation:blend forKey:@"pressed-blend"];
    [self check:[face animationForKey:@"pressed-blend"] == nil
        name:@"native pressed compositing animation cannot bypass selected colors"];
    CABasicAnimation *motion = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    motion.toValue = @.98;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[blend, motion];
    [face addAnimation:group forKey:@"pressed-group"];
    [self check:((CAAnimationGroup *)[face animationForKey:@"pressed-group"]).animations.count == 1
        name:@"native blend animation filtering retains press motion"];
    RKBlackPrefs = @{@"KeycapColor":@[@.12,@.32,@.24], @"KeyboardBackgroundColor":@[@.1,@.05,@.15]};
    RKRefreshNativeKey(key);
    pixels = RKTestPixels((__bridge CGImageRef)face.contents);
    const uint8_t *p = (const uint8_t *)pixels.bytes;
    [self check:abs(p[0]-31) <= 1 && abs(p[1]-82) <= 1 && abs(p[2]-61) <= 1
        name:@"native stretch backgrounds follow a non-black custom keycap color"];
    CGColorRef (^multiply)(CALayer *) = ^CGColorRef(CALayer *layer) {
        return ((CGColorRef (*)(id,SEL))objc_msgSend)(layer, NSSelectorFromString(@"contentsMultiplyColor"));
    };
    void (^setMultiply)(CALayer *,CGColorRef) = ^(CALayer *layer, CGColorRef color) {
        ((void (*)(id,SEL,CGColorRef))objc_msgSend)(layer, NSSelectorFromString(@"setContentsMultiplyColor:"), color);
    };
    setMultiply(face, UIColor.grayColor.CGColor);
    [self check:CGColorEqualToColor(multiply(face), UIColor.whiteColor.CGColor)
        name:@"native precolored bitmaps use identity multiplication, avoiding double-darkened custom colors"];
    CALayer *combined = [CALayer layer];
    combined.frame = key.bounds;
    combined.contents = (__bridge id)RKGrayKeyFixture(120).CGImage;
    [key.layer addSublayer:combined];
    RKMarkNativeBackground(key, combined);
    NSData *combinedBytes = RKTestPixels((__bridge CGImageRef)combined.contents);
    const uint8_t *mixed = (const uint8_t *)combinedBytes.bytes;
    NSUInteger ink = (20 * 80 + 36) * 4;
    [self check:mixed[ink] == 255 && mixed[ink+1] == 255 && mixed[ink+2] == 255 &&
        CGColorEqualToColor(multiply(combined), UIColor.whiteColor.CGColor)
        name:@"state-selected mixed native background caches retain white emoji and letter pixels"];
    CALayer *maskFace = [CALayer layer];
    maskFace.frame = key.bounds;
    [key.layer addSublayer:maskFace];
    RKMarkNativeBackground(key, maskFace);
    setMultiply(maskFace, UIColor.grayColor.CGColor);
    [self check:CGColorEqualToColor(multiply(maskFace), RKKeycapColor().CGColor)
        name:@"native compositor-only backgrounds take the chosen color on a late multiply-color write"];
    CABasicAnimation *multiplyAnimation = [CABasicAnimation animationWithKeyPath:@"contentsMultiplyColor"];
    multiplyAnimation.toValue = (__bridge id)UIColor.grayColor.CGColor;
    [maskFace addAnimation:multiplyAnimation forKey:@"multiply-press"];
    [self check:[maskFace animationForKey:@"multiply-press"] == nil
        name:@"native multiply-color animations cannot flash gray"];
    UIView *backdrop = [[NSClassFromString(@"UIKBBackdropView") alloc] initWithFrame:key.bounds];
    [key addSubview:backdrop];
    RKBlackScope *owner = [RKBlackScope new]; owner.root = key.layer;
    objc_setAssociatedObject(backdrop, &RKNativeBackdropOwnerKey, owner, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [backdrop layoutSubviews];
    RKUpdateNativeBackdrop(backdrop);
    CALayer *surface = objc_getAssociatedObject(backdrop, &RKBlackSurfaceKey);
    [self check:surface && CGColorEqualToColor(surface.backgroundColor, RKKeycapColor().CGColor)
        name:@"a native per-key backdrop uses keycap color rather than keyboard base color"];
    face.compositingFilter = @"multiplyBlendMode";
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKRefreshNativeKey(key);
    RKUpdateNativeBackdrop(backdrop);
    [self check:face.contents == (__bridge id)gray.CGImage &&
        [face.compositingFilter isEqual:@"multiplyBlendMode"] && surface.hidden
        name:@"native theme disable restores latest original image, blend and backdrop"];
    [self check:CGColorEqualToColor(multiply(face), UIColor.grayColor.CGColor) &&
        CGColorEqualToColor(multiply(maskFace), UIColor.grayColor.CGColor)
        name:@"native multiply colors restore the latest original value on disable"];
    RKBlackPrefs = @{};
    RKRefreshNativeKey(key);
    face.compositingFilter = nil;
    RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
    RKRefreshNativeKey(key);
    [self check:face.compositingFilter == nil name:@"native blend removal is preserved when the original app clears it"];
    RKBlackPrefs = @{};
    UIView *weType = [[WBKeyViewFixture alloc] initWithFrame:key.bounds];
    RKRefreshBlackKeyState(weType);
    CALayer *weTypeFace = [CALayer layer];
    weTypeFace.frame = weType.bounds;
    weTypeFace.contents = (__bridge id)gray.CGImage;
    [weType.layer addSublayer:weTypeFace];
    weTypeFace.compositingFilter = @"screenBlendMode";
    RKRefreshNativeKey(weType);
    [self check:weTypeFace.contents == (__bridge id)gray.CGImage &&
        [weTypeFace.compositingFilter isEqual:@"screenBlendMode"] &&
        objc_getAssociatedObject(weTypeFace, &RKNativeKeyOwnerKey) == nil
        name:@"native fix leaves WeType bitmap and compositing behavior exactly unchanged"];
    @try {
        Class traitsClass = NSClassFromString(@"UIKBRenderTraits");
        id traits = ((id (*)(id,SEL))objc_msgSend)(traitsClass, NSSelectorFromString(@"emptyTraits"));
        RKBlackPrefs = @{@"KeycapColor":@[@.8,@.2,@.1]};
        id originalGradient = RKNativeSolidGradient();
        RKNativeSetObject(traits, @"setBackgroundGradient:", originalGradient);
        RKNativeSetObject(traits, @"setLayeredBackgroundGradient:", originalGradient);
        RKNativeSetObject(traits, @"setHashString:", @"fixture");
        id geometry = [NSClassFromString(@"UIKBRenderGeometry") new];
        RKNativeSetObject(traits, @"setGeometry:", geometry);
        RKNativeSetObject(traits, @"setVariantGeometries:", @[geometry]);
        id highlighted = [traits copy];
        RKNativeSetObject(traits, @"setHighlightedVariantTraits:", highlighted);
        RKNativeSetObject(traits, @"setVariantTraits:", highlighted);
        NSObject *treeKey = [NSObject new];
        RKFixturePlane *plane = [RKFixturePlane new]; plane.keys = @[(id)treeKey];
        RKBlackPrefs = @{@"KeycapColor":@[@.12,@.32,@.24]};
        id colored = RKNativeKeyTraits(traits, treeKey, plane);
        [self check:geometry && RKNativeObject(colored, @"geometry") == geometry &&
            [RKNativeObject(colored, @"variantGeometries") firstObject] == geometry
            name:@"native trait copies retain symbol geometry omitted by UIKit copyWithZone"];
        id coloredGradient = RKNativeObject(colored, @"backgroundGradient");
        CGGradientRef gradient = ((CGGradientRef (*)(id,SEL))objc_msgSend)(coloredGradient, NSSelectorFromString(@"CGGradient"));
        UIGraphicsImageRenderer *gradientRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(4,4) format:format];
        UIImage *gradientImage = [gradientRenderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            if (gradient) CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(4,4), 0);
        }];
        NSData *data = RKTestPixels(gradientImage.CGImage);
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        if (gradient) CGGradientRelease(gradient);
        [self check:colored != traits && abs(bytes[0]-31) <= 1 && abs(bytes[1]-82) <= 1 && abs(bytes[2]-61) <= 1
            name:@"native rendering-source background gradient uses the exact chosen keycap RGB"];
        [self check:RKNativeObject(traits, @"backgroundGradient") == originalGradient &&
            RKNativeObject(RKNativeObject(colored, @"highlightedVariantTraits"), @"backgroundGradient") != originalGradient &&
            [RKNativeObject(colored, @"hashString") containsString:@"rk9"]
            name:@"native highlighted traits are recolored without mutating original traits or reusing old cache identity"];
        [self check:RKBlackObjectIvar(colored, "_variantTraits") == RKBlackObjectIvar(colored, "_highlightedVariantTraits") &&
            [objc_getAssociatedObject(RKNativeObject(RKNativeObject(colored, @"highlightedVariantTraits"), @"backgroundGradient"),
                &RKNativeGradientColorKey) isEqual:RKKeycapColor()]
            name:@"shared normal and highlighted variants reuse the same recolored copy"];
        id copiedGradient = [coloredGradient copy];
        [self check:[objc_getAssociatedObject(copiedGradient, &RKNativeGradientColorKey) isEqual:RKKeycapColor()]
            name:@"native background color survives the system copying a render gradient"];
        [self check:RKNativeKeyTraits(traits, [NSObject new], plane) == traits
            name:@"native render-source recoloring skips non-keyplane content"];
        RKBlackPrefs = @{@"PureBlackKeyboard":@NO};
        [self check:RKNativeKeyTraits(traits, treeKey, plane) == traits
            name:@"disabled native rendering-source hook returns original system traits"];
    } @catch (NSException *exception) {
        [self check:NO name:[@"native gradient construction exception: " stringByAppendingString:exception.reason ?: exception.name]];
    }
    RKBlackPrefs = @{};
    [key removeFromSuperview];
}
- (void)testNativeStatePerformance {
    RKBlackPrefs = @{};
    RKStatePlaneFixture *plane = [[RKStatePlaneFixture alloc] initWithFrame:CGRectMake(0,0,390,240)];
    NSMutableArray<UIView *> *keys = [NSMutableArray array];
    for (NSUInteger i = 0; i < 32; i++) {
        UIView *key = [[NSClassFromString(@"UIKBKeyView") alloc]
            initWithFrame:CGRectMake((i % 10) * 38, (i / 10) * 50, 36, 46)];
        [plane addSubview:key];
        CALayer *face = [CALayer layer];
        face.frame = key.bounds;
        face.backgroundColor = UIColor.grayColor.CGColor;
        [key.layer addSublayer:face];
        RKRefreshNativeKey(key);
        [keys addObject:key];
    }
    NSUInteger before = RKNativeStateRefreshes;
    CFTimeInterval started = CACurrentMediaTime();
    // Retained old traversal for a matched, warmed-up comparison in this fixture.
    for (NSUInteger i = 0; i < 200; i++) {
        NSMutableArray *pending = [NSMutableArray arrayWithObject:plane];
        NSUInteger visited = 0;
        while (pending.count && visited++ < 512) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if (RKKeyboardExcludedView(view)) continue;
            if (RKNativeKeyView(view)) RKRefreshNativeKey(view);
            else [pending addObjectsFromArray:view.subviews];
        }
    }
    CFTimeInterval baseline = CACurrentMediaTime() - started;
    NSUInteger baselineRefreshes = RKNativeStateRefreshes - before;
    before = RKNativeStateRefreshes;
    NSUInteger geometry = RKBlackGeometryRequests, batches = RKNativeStateBatches;
    started = CACurrentMediaTime();
    for (NSUInteger i = 0; i < 200; i++) {
        UIView *key = keys[i % keys.count];
        BOOL outer = RKBeginNativeStateTransition();
        RKRefreshNativeKey(key);
        BOOL inner = RKBeginNativeStateTransition();
        RKQueueNativeStateKey(plane, key, (int)(i % 2));
        RKRefreshNativeKey(key);
        if (inner) RKEndNativeStateTransition();
        RKQueueNativeStateKey(plane, key, (int)(i % 2));
        if (outer) RKEndNativeStateTransition();
    }
    CFTimeInterval targeted = CACurrentMediaTime() - started;
    NSUInteger refreshes = RKNativeStateRefreshes - before;
    [self check:baselineRefreshes == 6400 && refreshes == 200 && RKNativeStateBatches - batches == 200
        name:@"200 nested native transitions refresh one key each instead of all 32 keys"];
    [self check:RKBlackGeometryRequests == geometry
        name:@"native state-only transitions queue no full-keyboard geometry refresh"];
    [self check:RKNativePendingKeys == nil && RKNativeStateTransitionDepth == 0
        name:@"native transition batches release pending views and unwind their depth"];
    before = RKNativeStateRefreshes;
    RKBeginNativeStateTransition();
    RKRefreshNativeKey(keys[0]);
    RKBeginNativeStateTransition();
    RKRefreshNativeKey(keys[1]);
    RKEndNativeStateTransition();
    RKRefreshNativeKey(keys[0]);
    RKEndNativeStateTransition();
    [self check:RKNativeStateRefreshes - before == 2
        name:@"nested native transitions retain both changed keys without refreshing unrelated siblings"];
    before = RKNativeStateRefreshes;
    RKQueueNativeStateKey([UIView new], keys[0], 0);
    RKQueueNativeStateKey(plane, nil, 0);
    [self check:RKNativeStateRefreshes == before
        name:@"unavailable native lookup and nil keys are safely skipped"];
    RKBlackPrefs = @{@"KeycapColor":@[@.12,@.32,@.24]};
    RKBeginNativeStateTransition();
    RKQueueNativeStateKey(plane, keys[0], 1);
    RKEndNativeStateTransition();
    [self check:CGColorEqualToColor(keys[0].layer.sublayers.firstObject.backgroundColor, RKKeycapColor().CGColor)
        name:@"targeted native state refresh applies changed keycap settings before returning"];
    NSDictionary *report = @{@"transitions":@200, @"keys":@32,
        @"baselineRefreshes":@(baselineRefreshes), @"targetedRefreshes":@(refreshes),
        @"baselineMilliseconds":@(baseline * 1000), @"targetedMilliseconds":@(targeted * 1000),
        @"geometryRequests":@(RKBlackGeometryRequests - geometry),
        @"scope":@"Warmed synthetic UIKBKeyView fixture, not iOS 17 device typing latency"};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-performance.json"] atomically:YES];
    RKBlackPrefs = @{};
}
- (void)testGeometry {
    RKFixtureHost *host = [[RKFixtureHost alloc] initWithFrame:CGRectMake(0, 0, 390, 240)];
    RKFixturePlane *plane = [RKFixturePlane new];
    NSMutableArray *keys = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) {
        RKFixtureKey *key = [RKFixtureKey new];
        key.frame = CGRectMake(5 + i * 38, 12, 34, 44);
        key.ghost = i == 3;
        [keys addObject:key];
    }
    [keys addObject:keys.firstObject];
    RKFixtureKey *invalid = [RKFixtureKey new];
    invalid.frame = CGRectMake(NAN, 0, 30, 40);
    [keys addObject:invalid];
    plane.keys = keys;
    host.keyplane = plane;
    [self check:RKKeyboardKeyFrames(host).count == 3
        name:@"native geometry rejects ghosts, duplicates and non-finite frames"];
    RKWrongABIHost *wrong = [[RKWrongABIHost alloc] initWithFrame:host.frame];
    [self check:RKKeyboardKeyFrames(wrong).count == 0
        name:@"changed private getter ABI is safely skipped"];
    UIView *thirdParty = [[UIView alloc] initWithFrame:host.frame];
    for (NSInteger i = 0; i < 4; i++) {
        UIButton *key = [[UIButton alloc] initWithFrame:CGRectMake(5 + i * 38, 70, 34, 44)];
        key.hidden = i == 3;
        [thirdParty addSubview:key];
    }
    UIView *candidates = [[UIKeyboardCandidateRKFixture alloc] initWithFrame:CGRectMake(0, 0, 390, 50)];
    [candidates addSubview:[[UIButton alloc] initWithFrame:CGRectMake(10, 0, 60, 40)]];
    [thirdParty addSubview:candidates];
    [self check:RKKeyboardKeyFrames(thirdParty).count == 3
        name:@"view geometry excludes candidate buttons and hidden keys"];
}
- (void)preview {
    UIView *root = self.window.rootViewController.view;
    CGFloat width = root.bounds.size.width;
    CGFloat top = root.bounds.size.height * .48;
    UIView *board = [[UIView alloc] initWithFrame:CGRectMake(0, top, width, 252)];
    board.backgroundColor = [UIColor colorWithWhite:.025 alpha:1];
    RKUpdateBlackSurface(board, NO);
    [root addSubview:board];
    UIView *candidates = [[UIKeyboardCandidateRKFixture alloc] initWithFrame:CGRectMake(0, top - 56, width, 48)];
    [root addSubview:candidates];
    NSArray *words = @[@"Keyboard", @"Rainbow", @"Gradient"];
    for (NSUInteger i = 0; i < words.count; i++) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(i * width / 3, 0, width / 3, 48)];
        label.text = words[i];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:18];
        label.textColor = UIColor.whiteColor;
        [candidates addSubview:label];
    }
    NSArray *rows = @[@[@"Q",@"W",@"E",@"R",@"T",@"Y",@"U",@"I",@"O",@"P"],
        @[@"A",@"S",@"D",@"F",@"G",@"H",@"J",@"K",@"L"],
        @[@"Z",@"X",@"C",@"V",@"B",@"N",@"M"]];
    CGFloat step = width / 10;
    for (NSUInteger row = 0; row < rows.count; row++) {
        NSArray *letters = rows[row];
        CGFloat start = (width - step * letters.count) / 2;
        for (NSUInteger col = 0; col < letters.count; col++) {
            UIButton *key = [UIButton buttonWithType:UIButtonTypeCustom];
            key.frame = CGRectMake(start + step * col + 2, 8 + row * 58, step - 4, 48);
            key.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
            [key setTitle:letters[col] forState:UIControlStateNormal];
            [key addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchDown];
            [board addSubview:key];
        }
    }
    UIButton *space = [UIButton buttonWithType:UIButtonTypeCustom];
    space.frame = CGRectMake(width * .22, 184, width * .56, 46);
    [space setTitle:@"space" forState:UIControlStateNormal];
    space.titleLabel.font = [UIFont systemFontOfSize:15];
    [space addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchDown];
    [board addSubview:space];
    self.effect = [[RKFixtureEffect alloc] initWithFrame:board.bounds];
    self.effect.keyFrames = RKKeyboardKeyFrames(board);
    RKUpdateBlackKeycaps(board);
    CGRect key = self.effect.keyFrames[15].CGRectValue;
    self.gutterSample = [board convertPoint:CGPointMake(CGRectGetMaxX(key) + 2, CGRectGetMidY(key)) toView:root];
    [board addSubview:self.effect];
}
- (void)tap:(UIButton *)sender {
    [self.effect showRippleAtPoint:[sender convertPoint:CGPointMake(sender.bounds.size.width / 2,
        sender.bounds.size.height / 2) toView:self.effect]];
}
- (void)testEffects {
    NSArray *frames = self.effect.keyFrames;
    CGPoint point = CGPointMake(CGRectGetMidX([frames[15] CGRectValue]), CGRectGetMidY([frames[15] CGRectValue]));
    [self.effect setValue:@{@"MaxEffects":@3} forKey:@"config"];
    for (NSUInteger i = 0; i < 12; i++) [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 3 name:@"rapid typing respects effect limit"];
    [self check:!self.effect.userInteractionEnabled name:@"overlay never intercepts keyboard touches"];
    CALayer *pulse = self.effect.layer.sublayers.lastObject;
    CFTimeInterval earliest = DBL_MAX, latest = 0;
    for (CALayer *key in pulse.sublayers) {
        if (![key.name isEqualToString:@"keyWave"]) continue;
        CAAnimation *animation = [key animationForKey:@"keyWave"];
        earliest = MIN(earliest, animation.beginTime);
        latest = MAX(latest, animation.beginTime);
    }
    [self check:[pulse.sublayers.firstObject.name isEqualToString:@"keyboardAmbientGlow"] &&
        pulse.sublayers.firstObject.sublayers.count == 1 &&
        [pulse.sublayers.firstObject.sublayers.firstObject.name isEqualToString:@"gutterLight"] &&
        pulse.mask != nil
        name:@"black keycaps exclude face wash and mask the entire neon wave"];
    [self check:pulse.sublayers.count > 5 && latest - earliest > .05
        name:@"neighboring keys light at distance-dependent times"];
    BOOL thick = YES;
    for (CALayer *key in pulse.sublayers) {
        if (![key.name isEqualToString:@"keyWave"]) continue;
        CAGradientLayer *edge = (id)key.sublayers.lastObject;
        CAShapeLayer *rim = (id)edge.mask;
        thick &= [rim.fillRule isEqualToString:kCAFillRuleEvenOdd] &&
            CGPathContainsPoint(rim.path, NULL, CGPointMake(1.8, CGRectGetMidY(rim.bounds)), YES) &&
            !CGPathContainsPoint(rim.path, NULL, CGPointMake(CGRectGetMidX(rim.bounds), CGRectGetMidY(rim.bounds)), YES);
    }
    [self check:thick name:@"thick gradient rim retains an outer band wider than 1.8 points and an empty black center"];
    for (NSDictionary *config in @[@{@"AmbientGlow":@NO}, @{@"AmbientStrength":@0}, @{@"Opacity":@0}]) {
        self.effect.keyFrames = @[];
        self.effect.keyFrames = frames;
        [self.effect setValue:config forKey:@"config"];
        [self.effect showRippleAtPoint:point];
        BOOL hasAmbient = NO;
        BOOL invisible = YES;
        for (CALayer *layer in self.effect.layer.sublayers.lastObject.sublayers) {
            if ([layer.name isEqualToString:@"keyboardAmbientGlow"]) hasAmbient = YES;
            CAKeyframeAnimation *fade = (id)[layer animationForKey:@"keyWave"];
            for (NSNumber *value in fade.values) if (value.doubleValue != 0) invisible = NO;
        }
        NSString *key = config.allKeys.firstObject;
        [self check:!hasAmbient && (![key isEqualToString:@"Opacity"] || invisible)
            name:[NSString stringWithFormat:@"%@ off leaves no ambient light%@", key,
                [key isEqualToString:@"Opacity"] ? @" or visible borders" : @""]];
    }
    [self.effect setValue:@{@"Enabled":@NO} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 0 name:@"disabled effect removes active waves"];
    [self.effect setValue:@{} forKey:@"config"];
    self.effect.keyFrames = @[];
    [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 0 name:@"unknown geometry draws no invented key grid"];
    [self.effect setValue:@{@"EffectStyle":@1} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 1 name:@"legacy ring remains available without key geometry"];
    self.effect.keyFrames = frames;
    [self check:self.effect.layer.sublayers.count == 0 name:@"layout changes discard old animations"];
    [self.effect setValue:@{@"BackgroundFeedback":@NO} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.lastObject.sublayers.count == 1
        name:@"propagation switch leaves only the pressed key"];
    self.effect.keyFrames = @[];
    self.effect.keyFrames = frames;
    [self.effect setValue:@{@"ColorMode":@1, @"Hue":@.82, @"Opacity":@.95} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    BOOL fixed = YES;
    for (CALayer *key in self.effect.layer.sublayers.lastObject.sublayers) {
        if (![key.name isEqualToString:@"keyWave"]) continue;
        CAGradientLayer *edge = (id)key.sublayers.lastObject;
        // Fixed mode retains a single hue while varying saturation.
        UIColor *color = [UIColor colorWithCGColor:(__bridge CGColorRef)edge.colors.firstObject];
        CGFloat hue = 0;
        [color getHue:&hue saturation:NULL brightness:NULL alpha:NULL];
        if (fabs(hue - .82) > .001) fixed = NO;
    }
    [self check:fixed name:@"fixed color mode applies to every lit key"];
    [self testNeonConcentration:point];
    [self testNeonPress:point];
    [self.effect setValue:@{@"PureBlackKeyboard":@NO} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    CALayer *unmasked = self.effect.layer.sublayers.lastObject;
    [self check:unmasked.mask == nil && unmasked.sublayers.firstObject.sublayers.count == 2
        name:@"disabling pure black restores the optional face wash"];
    self.effect.keyFrames = @[];
    self.effect.keyFrames = frames;
    [self.effect setValue:@{@"Opacity":@.85} forKey:@"config"];
    [self.effect setValue:@.55 forKey:@"hue"];
    [self.effect showRippleAtPoint:point];
    [self.effect showRippleAtPoint:CGPointMake(point.x + 40, point.y)];
}
- (void)testNeonPress:(CGPoint)point {
    NSArray<NSValue *> *frames = self.effect.keyFrames;
    CGRect pressed = frames[15].CGRectValue;
    [self.effect setValue:@{@"EffectStyle":@2, @"MaxEffects":@3, @"PressColorMode":@1,
        @"PressColor":@[@1,@0,@.8], @"PressBrightness":@1} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    CALayer *pulse = self.effect.layer.sublayers.lastObject;
    CALayer *clip = pulse.sublayers.firstObject;
    CALayer *cap = clip.sublayers.firstObject;
    CGRect clippedFrame = clip.frame;
    BOOL sameFrame = fabs(clippedFrame.origin.x - pressed.origin.x) < .001 &&
        fabs(clippedFrame.origin.y - pressed.origin.y) < .001 &&
        fabs(clippedFrame.size.width - pressed.size.width) < .001 &&
        fabs(clippedFrame.size.height - pressed.size.height) < .001;
    [self check:self.effect.layer.sublayers.count == 1 && [pulse.name isEqual:@"neonKeyPress"] &&
        pulse.sublayers.count == 1 && sameFrame && clip.masksToBounds &&
        [cap.name isEqual:@"neonPressedFace"] && ![cap isKindOfClass:CAGradientLayer.class] &&
        CGColorEqualToColor(cap.backgroundColor, [UIColor colorWithRed:1 green:0 blue:.8 alpha:1].CGColor)
        name:@"neon press fills only the touched key and never propagates"];
    CAKeyframeAnimation *fade = (id)[cap animationForKey:@"neonPressFade"];
    [self check:[fade.values.firstObject doubleValue] > 0 && [fade.values.lastObject doubleValue] == 0 &&
        cap.opacity == 0 && cap.borderWidth == 0 &&
        ![cap.sublayers.firstObject.name isEqual:@"keycapHighlight"]
        name:@"neon press uses one flat solid color without gloss and fades back to the original keycap"];
    [self check:[[cap animationForKey:@"rkNeonPressScale"] isKindOfClass:CASpringAnimation.class] &&
        CATransform3DIsIdentity(cap.transform)
        name:@"neon press spring does not mutate model geometry"];
    for (NSUInteger i = 0; i < 12; i++) [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 1
        name:@"repeated presses replace the same key pulse without accumulating animation layers"];
    for (NSUInteger i = 0; i < 8; i++) {
        CGRect frame = frames[i].CGRectValue;
        [self.effect showRippleAtPoint:CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame))];
    }
    [self check:self.effect.layer.sublayers.count == 3 name:@"neon press honors the existing simultaneous effect limit"];
    UIView *host = self.effect.superview;
    UIView *target = nil;
    for (UIView *view in host.subviews)
        if ([view isKindOfClass:UIButton.class] &&
            CGRectContainsPoint([view convertRect:view.bounds toView:self.effect], point)) target = view;
    CGRect modelFrame = target.frame;
    self.effect.keyFrames = @[];
    self.effect.keyFrames = frames;
    CABasicAnimation *system = [CABasicAnimation animationWithKeyPath:@"opacity"];
    system.duration = 10;
    [target.layer addAnimation:system forKey:@"testSystemAnimation"];
    [self.effect showRippleAtPoint:point];
    [self check:target && [target.layer animationForKey:@"rkNeonPressScale"] != nil &&
        CATransform3DIsIdentity(target.layer.transform) && CGRectEqualToRect(target.frame, modelFrame)
        name:@"matching key view bounces visually without changing its frame or hit area"];
    self.effect.keyFrames = @[];
    [self check:[target.layer animationForKey:@"rkNeonPressScale"] == nil &&
        [target.layer animationForKey:@"testSystemAnimation"] != nil
        name:@"neon press cleanup removes only its own key animations"];
    [target.layer removeAnimationForKey:@"testSystemAnimation"];
    self.effect.keyFrames = frames;
    self.effect.keyFrames = @[];
    self.effect.keyFrames = frames;
    RKShowNeonKeyPress(self.effect, pressed, UIColor.magentaColor, 1, .55, YES, nil);
    cap = (id)self.effect.layer.sublayers.lastObject.sublayers.firstObject.sublayers.firstObject;
    [self check:[cap animationForKey:@"rkNeonPressScale"] == nil &&
        [cap animationForKey:@"rkNeonPressLift"] == nil && [cap animationForKey:@"neonPressFade"] != nil
        name:@"reduced motion keeps the neon flash without bounce"];
    [self.effect setValue:@{@"EffectStyle":@0, @"BackgroundFeedback":@NO} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    BOOL restored = YES;
    for (CALayer *layer in self.effect.layer.sublayers)
        restored &= ![layer.name isEqual:@"neonKeyPress"];
    [self check:restored name:@"switching back to Samsung removes all new-mode pulses"];
    [self.effect setValue:@{@"EffectStyle":@2, @"Enabled":@NO} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 0 name:@"master switch disables neon keycap mode"];
    [self.effect setValue:@{@"EffectStyle":@2} forKey:@"config"];
    [self.effect showRippleAtPoint:CGPointMake(-5, -5)];
    self.effect.keyFrames = @[];
    [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 0 name:@"neon press ignores padding and unavailable key geometry"];
    self.effect.keyFrames = frames;
    [self testSolidPressColors:point];
}
- (void)testSolidPressColors:(CGPoint)point {
    NSMutableDictionary *prefs = [@{@"EffectStyle":@2, @"PressColorMode":@1,
        @"PressColor":@[@.2,@1,@.4], @"PressBrightness":@1,
        @"Opacity":@0, @"Brightness":@0, @"NeonSaturation":@0, @"ColorMode":@1, @"Hue":@0} mutableCopy];
    UIColor *expected = [UIColor colorWithRed:.2 green:1 blue:.4 alpha:1];
    BOOL sameColor = YES;
    for (NSUInteger i = 0; i < 6; i++) {
        [self.effect setValue:prefs forKey:@"config"];
        [self.effect showRippleAtPoint:point];
        CALayer *cap = self.effect.layer.sublayers.lastObject.sublayers.firstObject.sublayers.firstObject;
        sameColor &= CGColorEqualToColor(cap.backgroundColor, expected.CGColor);
    }
    [self check:sameColor name:@"single-color presses retain chosen RGB and ignore old opacity brightness saturation and hue"];
    CGFloat previous = -1;
    BOOL increasing = YES;
    for (NSNumber *level in @[@.1,@.35,@.7,@1]) {
        prefs[@"PressBrightness"] = level;
        [self.effect setValue:prefs forKey:@"config"];
        [self.effect showRippleAtPoint:point];
        CALayer *cap = self.effect.layer.sublayers.lastObject.sublayers.firstObject.sublayers.firstObject;
        CGFloat r=0,g=0,b=0,a=0;
        [[UIColor colorWithCGColor:cap.backgroundColor] getRed:&r green:&g blue:&b alpha:&a];
        increasing &= g > previous && fabs(g - level.doubleValue) < .00001 &&
            fabs(r - .2 * g) < .00001 && fabs(b - .4 * g) < .00001 && a == 1;
        previous = g;
    }
    [self check:increasing name:@"dedicated press brightness ranges from dim to full RGB without changing hue"];
    prefs[@"PressBrightness"] = @0;
    [self.effect setValue:prefs forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    [self check:self.effect.layer.sublayers.count == 0 name:@"zero press brightness removes repeated-key light and creates no new pulse"];
    prefs[@"PressBrightness"] = @1;
    prefs[@"PressColorMode"] = @0;
    NSMutableSet *colors = [NSMutableSet set];
    BOOL saturated = YES;
    for (NSUInteger i = 0; i < 12; i++) {
        [self.effect setValue:prefs forKey:@"config"];
        [self.effect showRippleAtPoint:point];
        CALayer *cap = self.effect.layer.sublayers.lastObject.sublayers.firstObject.sublayers.firstObject;
        UIColor *color = [UIColor colorWithCGColor:cap.backgroundColor];
        CGFloat saturation=0, brightness=0;
        [color getHue:NULL saturation:&saturation brightness:&brightness alpha:NULL];
        saturated &= fabs(saturation - 1) < .00001 && fabs(brightness - 1) < .00001 &&
            ![cap isKindOfClass:CAGradientLayer.class];
        [colors addObject:color];
    }
    [self check:colors.count == 12 && saturated name:@"colorful mode changes pure saturated color on every tap even on the same key"];
    for (NSUInteger i = 0; i < 3; i++) {
        CGRect frame = self.effect.keyFrames[i].CGRectValue;
        [self.effect showRippleAtPoint:CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame))];
    }
    [colors removeAllObjects];
    for (CALayer *pulse in self.effect.layer.sublayers) {
        CALayer *cap = pulse.sublayers.firstObject.sublayers.firstObject;
        [colors addObject:[UIColor colorWithCGColor:cap.backgroundColor]];
    }
    [self check:colors.count == self.effect.layer.sublayers.count && colors.count >= 3
        name:@"simultaneously lit keys retain separate solid colors instead of mixing a rainbow on each key"];
    [self.effect setValue:@{@"EffectStyle":@2, @"Enabled":@NO} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
}
- (void)testNeonConcentration:(CGPoint)point {
    for (NSNumber *style in @[@0, @1]) {
        CGFloat previous = -1;
        BOOL increasing = YES;
        for (NSNumber *level in @[@0, @.25, @1]) {
            [self.effect setValue:@{@"EffectStyle":style, @"NeonSaturation":level,
                @"Brightness":@.93, @"ColorMode":@1, @"Hue":@.82} forKey:@"config"];
            [self.effect showRippleAtPoint:point];
            NSMutableArray *colors = [NSMutableArray array];
            RKCollectEffectColors(self.effect.layer.sublayers.lastObject, colors);
            CGFloat maxSaturation = 0, maxBrightness = 0;
            for (UIColor *color in colors) {
                CGFloat saturation = 0, brightness = 0, alpha = 0;
                [color getHue:NULL saturation:&saturation brightness:&brightness alpha:&alpha];
                if (alpha <= 0) continue;
                maxSaturation = MAX(maxSaturation, saturation);
                maxBrightness = MAX(maxBrightness, brightness);
            }
            increasing &= colors.count > 0 && maxSaturation > previous &&
                fabs(maxBrightness - .93) < .001;
            if (level.doubleValue == 0) increasing &= maxSaturation < .001;
            previous = maxSaturation;
        }
        [self check:increasing name:[NSString stringWithFormat:
            @"style %@ concentration adjusts all neon colors from pale to rich without dimming", style]];
    }
    [self.effect setValue:@{@"NeonSaturation":@(NAN), @"Brightness":@0} forKey:@"config"];
    [self.effect showRippleAtPoint:point];
    NSMutableArray *colors = [NSMutableArray array];
    RKCollectEffectColors(self.effect.layer.sublayers.lastObject, colors);
    BOOL dark = colors.count > 0;
    for (UIColor *color in colors) {
        CGFloat brightness = 0;
        [color getHue:NULL saturation:NULL brightness:&brightness alpha:NULL];
        dark &= isfinite(brightness) && brightness == 0;
    }
    [self check:dark name:@"brightness zero stays dark and invalid concentration is safely handled"];
}
- (void)savePreview {
    UIView *view = self.window.rootViewController.view;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES];
    }];
    [UIImagePNGRepresentation(image) writeToFile:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Documents/key-wave.png"] atomically:YES];
    [self check:[RKImageMetrics(image)[@"colored"] integerValue] > 1000
        name:@"composited preview contains visible colored pixels"];
    CGFloat scale = image.scale;
    CGRect sample = CGRectMake((self.gutterSample.x - 1) * scale, (self.gutterSample.y - 2) * scale,
                               2 * scale, 4 * scale);
    CGImageRef crop = CGImageCreateWithImageInRect(image.CGImage, sample);
    NSDictionary *metrics = RKImageMetrics([UIImage imageWithCGImage:crop]);
    CGImageRelease(crop);
    [self check:[metrics[@"colored"] integerValue] > 3
        name:@"background pixels between keys light up, not only key borders"];
    BOOL blackFaces = YES;
    for (NSValue *value in self.effect.keyFrames) {
        CGRect face = RKKeyboardKeyFacePath(value.CGRectValue).bounds;
        CGPoint local = CGPointMake(CGRectGetMidX(face), CGRectGetMinY(face) + 6);
        CGPoint root = [self.effect convertPoint:local toView:view];
        CGImageRef faceCrop = CGImageCreateWithImageInRect(image.CGImage,
            CGRectMake(root.x * scale, root.y * scale, 2 * scale, 3 * scale));
        NSDictionary *faceMetrics = RKImageMetrics([UIImage imageWithCGImage:faceCrop]);
        CGImageRelease(faceCrop);
        if ([faceMetrics[@"maxChannel"] integerValue] != 0) blackFaces = NO;
    }
    [self check:blackFaces name:@"every key face stays RGB 0,0,0 during overlapping colored waves"];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/TextInputUI.framework/TextInputUI", RTLD_LAZY);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(RKTestDelegate.class));
    }
}
