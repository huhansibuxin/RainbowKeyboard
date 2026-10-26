// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断 + 免跳实验（2.3.46）
//
// == 已经被日志坐实的部分 ==
//   2.3.42/2.3.44：半注销后每次点语音 → mic 0 → [entry] → [JUMP] pipFallback=0
//     → +0.8s mic 1（主 App 到前台才录上）→ session_stopped。
//   2.3.45：真凶是 3.04 秒的 PIPStart 超时 → _fallbackToURLSchemeForPIPStartCommandTimeout
//     → 跳 URL。pip=1 时 requireJump 本来就是 0，所以「强行 requireJump=NO」这条路是空的。
//     standy 的载体是 PiP；SpringBoard 一重启，PiP 凭证失效，App 挂起收不到 PIPStart。
//
// == 2.3.46 做的事：mach/信号唤醒 ==
//   静态确认 wxkb_plugin 里没有 CFMessagePort / xpc_connection_create_mach_service /
//   bootstrap_look_up；设备 launchctl 里 wetype 相关 mach service 只有键盘扩展自己的三个，
//   主 App 没注册任何 mach service ⇒ 「给主 App 发 mach 消息」没有端口可用，
//   而且 mach 消息对被挂起的 task 只会排队、不会让它 resume。
//   所以改用 SIGCONT（同 uid 即可，键盘进程有权限）：发 PIPStart 之前先把主 App
//   从 STOPPED 拉回 RUNNING，让它有机会处理随后的 PIPStart。
//   开关「点语音前唤醒主 App（实验）」默认关，关闭时与原行为完全一致。
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
#import <sys/sysctl.h>
#import <libproc.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>
#import <string.h>
#import <sys/syslimits.h>
#import "RKPreferences.h"

#pragma mark - 日志

static BOOL RKVLLogEnabled = NO;
// 2.3.45：语音免跳转实验开关。开 = requireJumpToMainAppForRecording 强制返回 NO。
static BOOL RKVLNoJumpTrial = NO;
// 2.3.46：mach/信号唤醒实验。开 = 发 PIPStart 前先把挂起的主 App 恢复执行。
static BOOL RKVLVoiceWake = NO;

static void RKVLLogRefresh(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    BOOL master = (!enabled || [enabled boolValue]);
    RKVLLogEnabled = master && [prefs[@"AIRecorderLog"] boolValue];
    RKVLNoJumpTrial = master && [prefs[@"VoiceNoJumpTrial"] boolValue];
    RKVLVoiceWake = master && [prefs[@"VoiceWakeApp"] boolValue];
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

#pragma mark - 2.3.46 唤醒挂起的主 App

// ⚠️ 前提（静态挖过、也查过设备 launchctl）：
//   wxkb_plugin 里没有任何 CFMessagePort / xpc_connection_create_mach_service /
//   bootstrap_look_up 的使用；设备上 user/501 域里 wetype 相关 mach service 只有键盘自己的
//   （com.tencent.wetype.keyboard / .viewservice / .apple-extension-service），
//   主 App（UIKitApplication:com.tencent.wetype）一个都没注册。
//   ⇒ 「键盘发 mach 消息把主 App 叫醒」这条路在 WeType 里没有现成端口可用。
//   mach 消息对被挂起的 task 只是排队，内核不会因此 resume 它 —— 真正能让它从
//   STOPPED 状态回到 RUNNING 的、且键盘进程有权限做的只有 SIGCONT（同 uid 即可）。
//   所以这里做的是「信号唤醒」，语义上等价于我们想要的「mach 唤醒」，只是不依赖 service。
static pid_t RKVLFindMainAppPID(NSString **outPath) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return -1; }

    pid_t found = -1;
    int count = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        pid_t p = procs[i].kp_proc.p_pid;
        if (p <= 1 || p == getpid()) continue;
        char name[64] = {0};
        if (proc_name(p, name, sizeof(name)) <= 0) continue;
        if (strcmp(name, "wxkb") != 0) continue;
        char path[PATH_MAX] = {0};
        if (proc_pidpath(p, path, sizeof(path)) <= 0) continue;
        NSString *ps = @(path);
        if (![ps containsString:@"/wxkb.app/"]) continue;
        found = p;
        if (outPath) *outPath = ps;
        break;
    }
    free(procs);
    return found;
}

// 找到主 App 并发 SIGCONT，返回 (pid, rc, errno)。找不到返回 pid=-1。
static pid_t RKVLWakeMainApp(int *outRC, int *outErrno) {
    NSString *path = nil;
    pid_t p = RKVLFindMainAppPID(&path);
    int rc = -999, err = 0;
    if (p > 0) {
        rc = kill(p, SIGCONT);
        err = errno;
        if (rc != 0) RKVLLog(@"[wake] main app path=%@", path);
    }
    if (outRC) *outRC = rc;
    if (outErrno) *outErrno = err;
    return p;
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
// 2.3.46：开关打开时，先让挂起的主 App 回到 RUNNING，再让它去处理随后的 PIPStart。
- (void)launchWBRecorderWithContext:(id)context finishedBlock:(id)block {
    RKVLLog(@"[entry] launchWBRecorder ctx=%p trial=%d wake=%d mask=0x%x",
            context, RKVLNoJumpTrial, RKVLVoiceWake, RKVLProbeMask());
    if (RKVLVoiceWake) {
        int rc = 0, err = 0;
        uint32_t before = RKVLProbeMask();
        pid_t pid = RKVLWakeMainApp(&rc, &err);
        RKVLLog(@"[wake] pid=%d kill(SIGCONT)=%d errno=%d mask_before=0x%x mic=%d pip=%d",
                pid, rc, err, before,
                RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(pictureInPictureActive)));
        usleep(200 * 1000);
        RKVLLog(@"[wake] +200ms mask=0x%x mic=%d pip=%d",
                RKVLProbeMask(),
                RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(pictureInPictureActive)));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RKVLLog(@"[wake] +3.4s mask=0x%x mic=%d pip=%d",
                    RKVLProbeMask(),
                    RKVLProbeFlag(@selector(microphoneActive)),
                    RKVLProbeFlag(@selector(pictureInPictureActive)));
        });
    }
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
        RKVLLog(@"==== RKVoiceJumpProbe 2.3.46 loaded path=%@ ====", RKVLLogPath());
        NSDictionary *p = RKReadEffectivePreferences();
        RKVLLog(@"[cfg] logEnabled=%d trial=%d wake=%d Enabled=%@ AIRecorderLog=%@ VoiceNoJumpTrial=%@ VoiceWakeApp=%@ rev=%@ bundle=%@",
                RKVLLogEnabled, RKVLNoJumpTrial, RKVLVoiceWake, p[@"Enabled"], p[@"AIRecorderLog"],
                p[@"VoiceNoJumpTrial"], p[@"VoiceWakeApp"], p[@"RKSettingsRevision"],
                [[NSBundle mainBundle] bundleIdentifier]);
        // 顺手确认超时兜底方法在当前版本存在（只查不 hook，避免猜错签名改坏调用约定）。
        Class svc = objc_getClass("WBVoiceInputService");
        BOOL hasFallback = svc &&
            class_getInstanceMethod(svc, @selector(_fallbackToURLSchemeForPIPStartCommandTimeoutWithSessionId:)) != NULL;
        RKVLLog(@"[cfg] PIPStartTimeoutFallback method=%d", hasFallback);
    }
}
