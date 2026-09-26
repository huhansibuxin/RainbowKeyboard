#import "RKAdaptivePerformance.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface RKAdaptiveMonitor : NSObject
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic) BOOL enabled;
@property(nonatomic) NSInteger level;
@property(nonatomic) CFTimeInterval lastInput, previous, windowStart;
@property(nonatomic) CFTimeInterval fastUntil;
@property(nonatomic) NSUInteger quickIntervals;
@property(nonatomic) NSUInteger samples, late, badWindows, goodWindows;
+ (instancetype)shared;
- (void)stop;
- (void)tick:(CADisplayLink *)link;
@end
@implementation RKAdaptiveMonitor
+ (instancetype)shared {
    static RKAdaptiveMonitor *monitor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        monitor = [self new];
        monitor.enabled = YES;
        [[NSNotificationCenter defaultCenter] addObserver:monitor selector:@selector(background:)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:monitor selector:@selector(background:)
            name:UIKeyboardDidHideNotification object:nil];
    });
    return monitor;
}
- (void)stop {
    [self.link invalidate];
    self.link = nil;
    self.previous = self.windowStart = 0;
    self.samples = self.late = self.badWindows = self.goodWindows = 0;
}
- (void)background:(NSNotification *)notification {
    [self stop];
    self.level = 0;
    self.lastInput = 0;
    self.fastUntil = 0;
    self.quickIntervals = 0;
}
- (void)tick:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    if (!self.enabled || now - self.lastInput > 6.0) { [self stop]; return; }
    if (!self.previous) { self.previous = self.windowStart = now; return; }
    CFTimeInterval gap = now - self.previous;
    self.previous = now;
    self.samples++;
    // Requested 20 Hz (50 ms): tolerate normal 60/120 Hz quantization.
    if (gap > 0.085) self.late++;
    if (now - self.windowStart < 1.0) return;
    BOOL bad = self.late >= 2 && self.late * 5 >= self.samples;
    BOOL good = self.samples >= 15 && self.late == 0;
    self.badWindows = bad ? self.badWindows + 1 : 0;
    self.goodWindows = good ? self.goodWindows + 1 : 0;
    if (self.badWindows >= 2) {
        self.level = MIN(2, self.level + 1);
        self.badWindows = self.goodWindows = 0;
    } else if (self.goodWindows >= 8) {
        self.level = MAX(0, self.level - 1);
        self.badWindows = self.goodWindows = 0;
    }
    self.windowStart = now;
    self.samples = self.late = 0;
}
@end
void RKAdaptiveSetEnabled(BOOL enabled) {
    RKAdaptiveMonitor *m = [RKAdaptiveMonitor shared];
    m.enabled = enabled;
    if (!enabled) { [m stop]; m.level = 0; m.lastInput = 0; m.fastUntil = 0; m.quickIntervals = 0; }
}
void RKAdaptiveNoteInput(void) {
    RKAdaptiveMonitor *m = [RKAdaptiveMonitor shared];
    if (!m.enabled) return;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval gap = m.lastInput ? now - m.lastInput : 100;
    // Retain the reduced level within this keyboard session. Recovery requires
    // stable samples, keyboard dismissal, backgrounding, or disabling the feature.
    if (!m.link) [m stop];
    m.lastInput = now;
    if (gap > 0 && gap <= .18) m.quickIntervals++;
    else m.quickIntervals = 0;
    if (m.quickIntervals >= 2) m.fastUntil = now + .8;
    if (!m.link) {
        m.link = [CADisplayLink displayLinkWithTarget:m selector:@selector(tick:)];
        m.link.preferredFramesPerSecond = 20;
        [m.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
NSInteger RKAdaptiveLevel(void) {
    RKAdaptiveMonitor *m = [RKAdaptiveMonitor shared];
    return m.enabled ? MAX(m.level, RKAdaptiveFastInput() ? 1 : 0) : 0;
}
BOOL RKAdaptiveFastInput(void) {
    RKAdaptiveMonitor *m = [RKAdaptiveMonitor shared];
    return m.enabled && CACurrentMediaTime() < m.fastUntil;
}
