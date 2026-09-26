#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>
#import "RKCandidateTransport.h"

static NSDictionary *RKDReadPreferences(void) {
    NSDictionary *values = RKReceiveColorState();
    if (values) return values;
    return [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.minis.rainbowkeyboard.plist"];
}

static NSArray *RKDInterfaces(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableArray *found = [NSMutableArray array];
    SEL selector = sel_registerName("renderCandidateWord:focusedStyle:atIndex:");
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        Class parent = class_getSuperclass(cls);
        if (parent && class_getInstanceMethod(parent, selector) == method) continue;
        const char *types = method_getTypeEncoding(method);
        const char *image = class_getImageName(cls);
        [found addObject:@{
            @"class": NSStringFromClass(cls),
            @"encoding": types ? [NSString stringWithUTF8String:types] : @"unknown",
            @"image": image ? [[NSString stringWithUTF8String:image] lastPathComponent] : @"unknown"
        }];
    }
    free(classes);
    return found;
}

static void RKDWriteProbe(void) {
    NSDictionary *prefs = RKDReadPreferences() ?: @{};
    BOOL hasState = RKReceiveColorState() != nil;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier ?: @"unknown";
    NSString *file = [NSString stringWithFormat:@"RainbowKeyboard-native-probe-%@.plist", bundle];
    NSDictionary *report = @{
        @"version": @8,
        @"probe": @"selector-only",
        @"processBundle": bundle,
        @"executable": NSProcessInfo.processInfo.arguments.firstObject ?: @"unknown",
        @"pid": @(getpid()),
        @"candidateInterfaces": RKDInterfaces(),
        @"preferenceSource": hasState ? @"notify-state" : @"file",
        @"flags": @{
            @"CandidateGradient": prefs[@"CandidateGradient"] ?: @"unset",
            @"CandidateNative": prefs[@"CandidateNative"] ?: @"unset",
            @"CandidateWeType": prefs[@"CandidateWeType"] ?: @"unset"
        }
    };
    NSString *path = [@"/var/mobile/Library/Preferences" stringByAppendingPathComponent:file];
    if (![report writeToFile:path atomically:YES])
        [report writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:file] atomically:YES];
}

%ctor {
    @autoreleasepool {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RKDWriteProbe(); });
    }
}
