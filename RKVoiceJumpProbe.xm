// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断探针（2.3.43，第二阶段：锁死判据）
//
// == 背景 ==
// 2.3.42 的日志已经证明：半注销后每次点语音都走
//   [JUMP] launchAppFromBackground allowBT=0 pipFallback=0
// 且此时 appAlive=1（主 App 进程活着）。也就是说不是 app_killed，
// 而是「活着但不能免跳」——对应 force jump 日志里的 app_background_without_audio。
//
// == 2.3.43 补齐的观测点 ==
//   WBVoiceInputService -requireJumpToMainAppForRecording        → BOOL（决定跳不跳的总闸）
//     静态反汇编确认：`eor w0, w0, #1` 收尾，是纯 BOOL。
//     内部逻辑 ≈「两个前置开关都为假时，返回 !某内部判据」= requireJump 即 !canReuse。
//   WBVoiceInputService -updateLaunchingRecorderApp:reason:      → void（reason 是原因枚举）
//   WBVoiceInputService -launchWBRecorderWithContext:finishedBlock: → void（真正入口；
//     2.3.42 hook 的 launchWcVoiceWithContext: 全程零命中，说明它不是实际入口）
//   WBVoiceStateProbe -microphoneActive / -pictureInPictureActive → BOOL
//     （standby 的两根支柱还在不在，直接决定能不能免跳）
//
// == 返回类型核对（capstone 看 ret 出口） ==
//   requireJumpToMainAppForRecording : eor w0,w0,#1        → BOOL
//   microphoneActive                 : and w0,w0,#1        → BOOL
//   pictureInPictureActive           : ubfx w0,w0,#1,#1    → BOOL
//   updateLaunchingRecorderApp:reason: 尾部为 b（尾调用）  → void
//   launchWBRecorderWithContext:finishedBlock: 结尾 add sp/ret，无 w0 写入 → void
//   isMainAppVoiceStandbyActive 不 hook：尾部 `mov x0,x20` 且另有 `mov w20,#1` 分支，
//   返回类型不唯一（id / BOOL 混用），hook 有改坏调用约定的风险。
//
// 日志受「记录调试日志」（AIRecorderLog）与总开关（Enabled）双控，默认关。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "RKPreferences.h"

#pragma mark - 日志

static BOOL RKVLLogEnabled = NO;

static void RKVLLogRefresh(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    RKVLLogEnabled = (!enabled || [enabled boolValue])
        && [prefs[@"AIRecorderLog"] boolValue];
}

static void RKVLPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ RKVLLogRefresh(); });
}

static NSString *RKVLLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"rk_voice.log"];
}

static void RKVLLog(NSString *fmt, ...) {
    if (!RKVLLogEnabled) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.3f [%d] %@",
                      [NSDate date].timeIntervalSince1970, getpid(), body];
    FILE *fp = fopen(RKVLLogPath().UTF8String, "a");
    if (!fp) return;
    fprintf(fp, "%s\n", line.UTF8String);
    fclose(fp);
}

// 从 WBVoiceStateProbe 的实例里取状态。用 unsafe_unretained 缓存实例（该类是长生命单例），
// 不额外 retain，避免在插件里制造循环。
static __unsafe_unretained id gRKVLProbe = nil;

static int RKVLProbeFlag(SEL sel) {
    id probe = gRKVLProbe;
    if (!probe) {
        Class c = objc_getClass("WBVoiceStateProbe");
        if (c && [c respondsToSelector:@selector(sharedInstance)])
            probe = [c performSelector:@selector(sharedInstance)];
    }
    if (!probe || ![probe respondsToSelector:sel]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(probe, sel) ? 1 : 0;
}

#pragma mark - 探针

%hook WBVoiceStateProbe

// appAlive 会被高频轮询（2.3.42 一轮 7 次语音写了 197 行），只在变化时记。
- (BOOL)appAlive {
    gRKVLProbe = self;
    BOOL alive = %orig;
    static BOOL lastAlive;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lastAlive = !alive; });
    if (alive != lastAlive) {
        lastAlive = alive;
        RKVLLog(@"[probe] appAlive -> %d", alive);
    }
    return alive;
}

// standby 的两根支柱：麦克风与画中画。半注销后这俩大概率都是 0，
// 那才是「必须跳」的根因（而不是 appAlive）。
- (BOOL)microphoneActive {
    BOOL v = %orig;
    static BOOL last; static dispatch_once_t once;
    dispatch_once(&once, ^{ last = !v; });
    if (v != last) { last = v; RKVLLog(@"[probe] microphoneActive -> %d", v); }
    return v;
}

- (BOOL)pictureInPictureActive {
    BOOL v = %orig;
    static BOOL last; static dispatch_once_t once;
    dispatch_once(&once, ^{ last = !v; });
    if (v != last) { last = v; RKVLLog(@"[probe] pictureInPictureActive -> %d", v); }
    return v;
}

%end

%hook WBVoiceInputService

// 总闸：返回值直接决定「键盘内重启录音」还是「跳主 App」。
- (BOOL)requireJumpToMainAppForRecording {
    BOOL jump = %orig;
    RKVLLog(@"[gate] requireJump=%d (appAlive=%d mic=%d pip=%d)", jump,
            RKVLProbeFlag(@selector(appAlive)),
            RKVLProbeFlag(@selector(microphoneActive)),
            RKVLProbeFlag(@selector(pictureInPictureActive)));
    return jump;
}

// 真正的入口（2.3.42 里 hook 的 launchWcVoiceWithContext: 全程零命中）。
- (void)launchWBRecorderWithContext:(id)context finishedBlock:(id)block {
    RKVLLog(@"[entry] launchWBRecorder ctx=%p", context);
    %orig;
}

// reason 就是二进制里那套枚举：app_background_without_audio / app_killed /
// pip_start_timeout_url_fallback / launch_app_from_background …
- (void)updateLaunchingRecorderApp:(BOOL)launching reason:(id)reason {
    RKVLLog(@"[reason] launching=%d reason=%@", launching, reason);
    %orig;
}

- (void)launchAppFromBackgroundWithAllowBluetooth:(BOOL)allow pipTimeoutFallback:(BOOL)fallback {
    RKVLLog(@"[JUMP] launchAppFromBackground allowBT=%d pipFallback=%d", allow, fallback);
    %orig;
}

%end

%hook WBVoiceCommandChannel
- (id)ipcChannel {
    id ch = %orig;
    static __unsafe_unretained id last;
    if (ch != last) { last = ch; RKVLLog(@"[ipc] commandChannel=%p", ch); }
    return ch;
}
%end

%hook WBVoiceEventChannel
- (id)ipcChannel {
    id ch = %orig;
    static __unsafe_unretained id last;
    if (ch != last) { last = ch; RKVLLog(@"[ipc] eventChannel=%p", ch); }
    return ch;
}
%end

%ctor {
    @autoreleasepool {
        RKVLLogRefresh();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RKVLPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        RKVLLog(@"==== RKVoiceJumpProbe 2.3.43 loaded path=%@ ====", RKVLLogPath());
        NSDictionary *p = RKReadEffectivePreferences();
        RKVLLog(@"[cfg] logEnabled=%d Enabled=%@ AIRecorderLog=%@ rev=%@ bundle=%@",
                RKVLLogEnabled, p[@"Enabled"], p[@"AIRecorderLog"],
                p[@"RKSettingsRevision"], [[NSBundle mainBundle] bundleIdentifier]);
    }
}
