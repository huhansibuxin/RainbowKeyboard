#import <UIKit/UIKit.h>
#import "../RKPreferences.h"

static NSDictionary *RKProbeValues(void) {
    return @{@"KeycapColor":@[@.17,@.63,@.28], @"KeyboardBackgroundColor":@[@.08,@.03,@.13],
        @"Opacity":@.42, @"Softness":@13, @"Duration":@.77, @"Spread":@2.7,
        @"CandidateGradient":@NO, @"CandidateNative":@NO, @"AmbientGlow":@YES,
        @"NeonSaturation":@.31, @"PureBlackKeyboard":@YES,
        @"PressColorMode":@1, @"PressColor":@[@.9,@.15,@.4], @"PressBrightness":@.83};
}
static BOOL RKProbeMatches(NSDictionary *values) {
    if (!values || !values[@"CandidateGradient"] || [values[@"CandidateGradient"] boolValue]) return NO;
    if ([values[@"PressColorMode"] integerValue] != 1) return NO;
    for (NSString *key in @[@"Opacity", @"Softness", @"Duration", @"Spread", @"NeonSaturation", @"PressBrightness"])
        if (fabs([values[key] doubleValue] - [RKProbeValues()[key] doubleValue]) > .00002) return NO;
    for (NSString *key in @[@"KeycapColor", @"KeyboardBackgroundColor", @"PressColor"]) {
        NSArray *rgb = values[key], *expected = RKProbeValues()[key];
        if (rgb.count != 3) return NO;
        for (NSUInteger i = 0; i < 3; i++) if (fabs([rgb[i] doubleValue] - [expected[i] doubleValue]) > .00002) return NO;
    }
    return YES;
}
static void RKProbeWrite(NSDictionary *values, NSString *file) {
    [[NSJSONSerialization dataWithJSONObject:values options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:[@"Documents/" stringByAppendingString:file]]
        atomically:YES];
}
@interface RKRelayProbe : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) NSMutableDictionary *report;
@property(nonatomic) UIBackgroundTaskIdentifier task;
@end
@implementation RKRelayProbe
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];
    self.report = [NSMutableDictionary dictionary];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--writer"]) {
        BOOL saved = RKSavePreferences([RKProbeValues() mutableCopy]);
        RKProbeWrite(@{@"saved":@(saved)}, @"writer.json");
    } else if ([NSProcessInfo.processInfo.arguments containsObject:@"--relay"]) {
        self.task = [application beginBackgroundTaskWithExpirationHandler:^{}];
        RKInstallPreferencesRelayObservers();
        RKProbeWrite(@{@"restoredSaved":@(RKProbeMatches(RKReadStoredPreferences())),
            @"restoredTransport":@(RKProbeMatches(RKReceiveDisplaySnapshot()))}, @"relay.json");
    } else {
        RKRequestPreferencesRelay();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSDictionary *snapshot = RKReceiveDisplaySnapshot();
            self.report[@"differentProcessRead"] = @(RKProbeMatches(snapshot));
            self.report[@"noFileAccessResolution"] = @(RKProbeMatches(RKMergeDisplaySnapshot(@{}, snapshot)));
            self.report[@"storedMatches"] = @(RKProbeMatches(RKReadStoredPreferences()));
            self.report[@"effectiveMatches"] = @(RKProbeMatches(RKReadEffectivePreferences()));
            notify_set_state(RKDisplayToken(RKDisplayWordCount), UINT64_MAX);
            self.report[@"interruptedWriteKeepsPrevious"] = @(RKReceiveDisplaySnapshot() == nil &&
                RKProbeMatches(RKReadEffectivePreferences()));
            for (NSUInteger i = 0; i <= RKDisplayWordCount; i++) notify_set_state(RKDisplayToken(i), 0);
            notify_post("com.minis.rainbowkeyboard.settings.request.v2");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                self.report[@"recoveredAfterStateLoss"] = @(RKProbeMatches(RKReceiveDisplaySnapshot()));
                self.report[@"passed"] = @([self.report[@"differentProcessRead"] boolValue] &&
                    [self.report[@"noFileAccessResolution"] boolValue] && [self.report[@"effectiveMatches"] boolValue] &&
                    [self.report[@"interruptedWriteKeepsPrevious"] boolValue] &&
                    [self.report[@"recoveredAfterStateLoss"] boolValue]);
                RKProbeWrite(self.report, @"reader.json");
            });
        });
    }
    return YES;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RKRelayProbe.class)); }
}
