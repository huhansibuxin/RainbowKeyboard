// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断 + 免跳实验（2.3.45）
//
// == 已经被日志坐实的部分（2.3.42 / 2.3.44） ==
//   半注销后每次点语音：mic -> 0 → [entry] launchWBRecorder → [reason] new_native_launch
//   → [JUMP] allowBT=0 pipFallback=0 → launching=1 reason=launch_app_from_background
//   → +0.8s mic -> 1（主 App 被拉到前台）→ recorder_active_check → session_stopped
//   ⇒ requireJumpToMainAppForRecording 等价于 !microphoneActive（39/45 行零例外），
//     pictureInPictureActive 全程 0（连 PiP 兜底都不试）。
//   ⇒ 录音一停主 App 就退出会话，键盘侧 mic 立刻归 0，下一次必跳。
//
// == 2.3.45 做的事：A 方案（强行免跳的最小实验） ==
//   设置页「语音免跳转（实验）」打开时，让 requireJumpToMainAppForRecording 恒返回 NO，
//   看 mic=0 时键盘能否在自身进程内直接起录音。
//   配套观测：currentMask（状态位图，变化才记）、进入录音待机（RecorderStandby）。
//   开关关闭 = 完全原行为，只是照常记 gate 日志。
//
// == 返回类型核对（capstone 看 ret 出口） ==
//   requireJumpToMainAppForRecording : eor w0,w0,#1                → BOOL
//   microphoneActive                 : and w0,w0,#1                → BOOL
//   pictureInPictureActive           : ubfx w0,w0,#1,#1            → BOOL
//   currentMask                      : ldar w0,[x8]                → uint32_t（32 位！）
//   _transitionNativeViewStateToRecorderStandby : 尾部 b 尾调用/无 w0  → void
//   updateLaunchingRecorderApp:reason: 尾部为 b（尾调用）            → void
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
// 2.3.45：语音免跳转实验开关。开 = requireJumpToMainAppForRecording 强制返回 NO。
static BOOL RKVLNoJumpTrial = NO;

static void RKVLLogRefresh(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    BOOL master = (!enabled || [enabled boolValue]);
    RKVLLogEnabled = master && [prefs[@"AIRecorderLog"] boolValue];
    RKVLNoJumpTrial = master && [prefs[@"VoiceNoJumpTrial"] boolValue];
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

static unsigned int RKVLProbeMask(void) {
    id probe = gRKVLProbe;
    if (!probe) return 0;
    if (![probe respondsToSelector:@selector(currentMask)]) return 0;
    return ((uint32_t (*)(id, SEL))objc_msgSend)(probe, @selector(currentMask));
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

// 2.3.45：原始状态位图。mic/pip 只是它的两个派生视图，看原值能判断
// 「主 App 到底报了哪些能力」——如果强制免跳后 mask 压根不变，说明对端没起来。
- (uint32_t)currentMask {
    uint32_t m = %orig;
    static uint32_t last; static dispatch_once_t once;
    dispatch_once(&once, ^{ last = ~m; });
    if (m != last) {
        last = m;
        RKVLLog(@"[mask] 0x%x (appAlive=%d mic=%d pip=%d)", m,
                RKVLProbeFlag(@selector(appAlive)),
                RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(pictureInPictureActive)));
    }
    return m;
}

%end

%hook WBVoiceInputService

// 总闸：返回值直接决定「键盘内重启录音」还是「跳主 App」。
// 2.3.45 实验：开关打开时强制返回 NO，观察 mic=0 时能否在键盘进程内起录音。
- (BOOL)requireJumpToMainAppForRecording {
    BOOL jump = %orig;
    int alive = RKVLProbeFlag(@selector(appAlive));
    int mic = RKVLProbeFlag(@selector(microphoneActive));
    int pip = RKVLProbeFlag(@selector(pictureInPictureActive));
    if (RKVLNoJumpTrial) {
        RKVLLog(@"[trial] requireJump %d -> 0 (appAlive=%d mic=%d pip=%d mask=0x%x)",
                jump, alive, mic, pip, RKVLProbeMask());
        return NO;
    }
    RKVLLog(@"[gate] requireJump=%d (appAlive=%d mic=%d pip=%d)", jump, alive, mic, pip);
    return jump;
}

// 真正的入口（2.3.42 里 hook 的 launchWcVoiceWithContext: 全程零命中）。
- (void)launchWBRecorderWithContext:(id)context finishedBlock:(id)block {
    RKVLLog(@"[entry] launchWBRecorder ctx=%p trial=%d mask=0x%x", context, RKVLNoJumpTrial,
            RKVLProbeMask());
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

// 2.3.45：强制免跳后最想看到的一行 —— 有没有进入「录音待机」（把 mic 位留住）。
- (void)_transitionNativeViewStateToRecorderStandby {
    RKVLLog(@"[standby] -> RecorderStandby trial=%d mask=0x%x", RKVLNoJumpTrial, RKVLProbeMask());
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
        RKVLLog(@"==== RKVoiceJumpProbe 2.3.45 loaded path=%@ ====", RKVLLogPath());
        NSDictionary *p = RKReadEffectivePreferences();
        RKVLLog(@"[cfg] logEnabled=%d trial=%d Enabled=%@ AIRecorderLog=%@ VoiceNoJumpTrial=%@ rev=%@ bundle=%@",
                RKVLLogEnabled, RKVLNoJumpTrial, p[@"Enabled"], p[@"AIRecorderLog"],
                p[@"VoiceNoJumpTrial"], p[@"RKSettingsRevision"],
                [[NSBundle mainBundle] bundleIdentifier]);
    }
}
