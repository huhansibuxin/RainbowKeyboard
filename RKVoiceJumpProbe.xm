// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断 + 免跳实验（2.3.49）
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
// == 2.3.49 做的事：修好「找 pid」+ 加 p_stat 诊断 ==
//   2.3.46~2.3.48 三版日志全是 `[wake] pid=-1 kill(SIGCONT)=-999`，
//   说明 proc_name()/proc_pidpath() 在 PluginKit 扩展沙盒里对别的进程返回 0，
//   每个 pid 都被过滤掉了，SIGCONT 一次都没发出去过 —— 那个开关一直是空转。
//   现在改成直接读 sysctl 返回的 kinfo_proc.kp_proc.p_comm（内核已填好，无跨进程权限需求）。
//   同时打 p_stat：4=SSTOP 才能被 SIGCONT 救；3=SSLEEP 说明是 Mach task_suspend，
//   SIGCONT 内核层就是空操作，得换方案（App 侧保活 / SpringBoard 注入）。
//
// 日志受「记录调试日志」（AIRecorderLog）与总开关（Enabled）双控，默认关。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <signal.h>
#import <errno.h>
#import <unistd.h>
#import <string.h>
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
// ⚠️ 2.3.49 修：2.3.46~2.3.48 的 pid 查找**一次都没成功过**（日志恒为 pid=-1）。
//   原因：原来靠 dlsym 的 proc_name() / proc_pidpath() 去认进程 —— 这两个函数要读
//   目标进程的 task/proc 结构，在 PluginKit 扩展沙盒里对**别的进程**一律返回 0，
//   所以每个 pid 都被 continue 掉了，SIGCONT 从来没发出去。
//   正解：sysctl 返回的 kinfo_proc 里内核已经把 p_comm（进程名）填好了，
//   读它不需要任何跨进程权限 —— 直接比 p_comm 就行，不再调 proc_name/proc_pidpath。
//   p_comm 上限 MAXCOMLEN+1 = 17 字节，主 App 是 "wxkb"、扩展自己是 "wxkb_plugin"，
//   不会撞名；仍然排除 getpid() 双保险。

// 返回值：>0 = 找到的主 App pid；-1 = sysctl 失败；-2 = malloc 失败；-3 = 二次 sysctl 失败；0 = 表里没找到
static pid_t RKVLFindMainAppPID(int *outSysRc, int *outSysErr, int *outCount,
                                char *outHint, size_t hintLen, pid_t *outSelfPid) {
    if (outSysRc) *outSysRc = 0;
    if (outSysErr) *outSysErr = 0;
    if (outCount) *outCount = 0;
    if (outHint && hintLen > 0) outHint[0] = '\0';
    if (outSelfPid) *outSelfPid = getpid();

    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    int rc = sysctl(mib, 4, NULL, &size, NULL, 0);
    int err = errno;
    if (outSysRc) *outSysRc = rc;
    if (outSysErr) *outSysErr = err;
    if (rc != 0 || size == 0) return -1;

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -2;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) { free(procs); return -3; }

    int count = (int)(size / sizeof(struct kinfo_proc));
    if (outCount) *outCount = count;

    pid_t me = getpid();
    pid_t found = 0;
    char firstWxkb[32] = {0};
    for (int i = 0; i < count; i++) {
        pid_t p = procs[i].kp_proc.p_pid;
        if (p <= 1 || p == me) continue;
        char comm[sizeof(procs[i].kp_proc.p_comm) + 1];
        memset(comm, 0, sizeof(comm));
        strlcpy(comm, procs[i].kp_proc.p_comm, sizeof(comm));
        if (strncmp(comm, "wxkb", 4) != 0) continue;
        if (firstWxkb[0] == '\0') strlcpy(firstWxkb, comm, sizeof(firstWxkb));
        if (strcmp(comm, "wxkb") == 0) { found = p; break; }
    }
    free(procs);
    if (outHint && hintLen > 0) strlcpy(outHint, firstWxkb, hintLen);
    return found;
}

// 读单个进程的 p_stat：1=SIDL 2=SRUN 3=SSLEEP 4=SSTOP 5=SZOMB。
// ⭐ 这是判定 SIGCONT 有没有意义的关键诊断：
//   · 主 App 是 SSTOP(4)（job-control 停住）→ SIGCONT 能救；
//   · 是 SSLEEP(3)（iOS 正常挂起 = Mach task_suspend，suspend count 累加）
//     → SIGCONT 在内核里对它是空操作，必须换手段。
static int RKVLProcStat(pid_t pid) {
    if (pid <= 0) return -1;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc kp;
    size_t sz = sizeof(kp);
    memset(&kp, 0, sizeof(kp));
    if (sysctl(mib, 4, &kp, &sz, NULL, 0) != 0) return -2;
    return (int)kp.kp_proc.p_stat;
}

// 唤醒主 App。mode: 0=没发、1=精准 pid、2=kill(-1) 兜底。
// kill(-1, SIGCONT) 的语义：把信号发给**所有同 uid 且我们有权限的进程**；
// POSIX 规定 SIGCONT 对本来就没停的进程无副作用（直接忽略），所以兜底不会打扰跑着的 App。
static pid_t RKVLWakeMainApp(int *outRC, int *outErr, int *outMode, int *outFind,
                             int *outCount, pid_t *outSelfPid, int *outStatB, int *outStatA) {
    int sysRc = 0, sysErr = 0, count = 0;
    char hint[32] = {0};
    pid_t me = 0;
    pid_t p = RKVLFindMainAppPID(&sysRc, &sysErr, &count, hint, sizeof(hint), &me);

    int rc = -999, err = 0, mode = 0;
    int stB = -1, stA = -1;
    if (p > 0) {
        stB = RKVLProcStat(p);
        rc = kill(p, SIGCONT);
        err = errno;
        mode = 1;
        stA = RKVLProcStat(p);
    } else {
        rc = kill(-1, SIGCONT);
        err = errno;
        mode = 2;
    }
    if (outRC) *outRC = rc;
    if (outErr) *outErr = err;
    if (outMode) *outMode = mode;
    if (outFind) *outFind = (int)p;
    if (outCount) *outCount = count;
    if (outSelfPid) *outSelfPid = me;
    if (outStatB) *outStatB = stB;
    if (outStatA) *outStatA = stA;

    RKVLLog(@"[wake] sysctl rc=%d errno=%d count=%d hint=%s self=%d -> find=%d p_stat=%d→%d",
            sysRc, sysErr, count, hint[0] ? hint : "-", (int)me, (int)p, stB, stA);
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
        int rc = 0, err = 0, mode = 0, find = 0, count = 0, stB = -1, stA = -1;
        pid_t selfPid = 0;
        uint32_t before = RKVLProbeMask();
        pid_t pid = RKVLWakeMainApp(&rc, &err, &mode, &find, &count, &selfPid, &stB, &stA);
        RKVLLog(@"[wake] pid=%d mode=%d kill=%d errno=%d stat=%d→%d mask_before=0x%x mic=%d pip=%d appAlive=%d",
                pid, mode, rc, err, stB, stA, before,
                RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(pictureInPictureActive)),
                RKVLProbeFlag(@selector(appAlive)));
        // 分两段睡，能在日志里看出「阻塞期间 mask 有没有被后台更新」——
        // 如果两段都没变化、释放主线程后立刻变化，说明 mask 上报是走主队列的，
        // 那这里再拉长等待也没用，得换非阻塞方案。
        usleep(250 * 1000);
        RKVLLog(@"[wake] +0.25s mask=0x%x mic=%d pip=%d",
                RKVLProbeMask(),
                RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(pictureInPictureActive)));
        usleep(250 * 1000);
        RKVLLog(@"[wake] +0.5s mask=0x%x mic=%d pip=%d",
                RKVLProbeMask(),
                RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(pictureInPictureActive)));
        for (double d = 1.2; d <= 8.1; d += 2.2) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                RKVLLog(@"[wake] +%.1fs mask=0x%x mic=%d pip=%d",
                        d, RKVLProbeMask(),
                        RKVLProbeFlag(@selector(microphoneActive)),
                        RKVLProbeFlag(@selector(pictureInPictureActive)));
            });
        }
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
        RKVLLog(@"==== RKVoiceJumpProbe 2.3.49 loaded path=%@ ====", RKVLLogPath());
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
