// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断 + 免跳实验（2.3.53）
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
// == 2.3.51 做的事：无头 → 有头拉起 + pip 掉落的精确取证 ==
//   2.3.50 实测无头全灭：SBSLaunchApplicationWithIdentifier(suspended) rc=9（无 entitlement），
//   LSApplicationWorkspace 在 iOS16 已没有 openApplicationWithBundleID:withOptions:。
//   改回 WeType 自己在用的单参 openApplicationWithBundleID:（有头，一定存在/有权限）。
//   同时新增 `[pip] 1→0 距上次session_stopped=?.?s` —— pip 能活多久决定「最多跳几次」。
//   日志已证明 pip=1 期间 requireJump 恒 0、零 JUMP（1793027166/1793027182 两轮连打两次都不跳）。
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

// 2.3.53：诊断期的「必写」日志，绕过调试开关。
// 起因：2.3.52 崩溃那轮日志一行没写（开关当时是关的），
// 结果连「宿主能不能认出来」都不知道，白崩一次。
// 每次进程启动只写几行（loaded / cfg / host），不吵；高频路径一律仍走 RKVLLog。
static void RKVLLogForce(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%.3f [%d] (强制) %@",
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

// ⛔ 2.3.50 结果（无头拉起全灭，别再试）：
//   [cfg] launchable SBS=1 SBSOpts=1 LSWS=0
//   ① SBSLaunchApplicationWithIdentifier(suspended=1)              rc=9
//   ② SBSLaunchApplicationWithIdentifierAndLaunchOptions(...,YES)  rc=9
//   ③ LSApplicationWorkspace 没有 openApplicationWithBundleID:withOptions:（iOS16 已移除）
//   rc=9 = SpringBoardServices 的「无权限」错误码（缺 com.apple.springboard.launchapplications
//   entitlement，重签微信输入法的 appex 会破坏签名，不可行）。
//   ⇒ 从键盘 appex 里「无头拉起主 App」这条路彻底封死。
//
// == 2.3.51 改「有头拉起」==
//   用户判断：无头拉起没用，要有头拉起才行。有头 = LSApplicationWorkspace 的单参
//   `openApplicationWithBundleID:` —— 这个 WeType 自己在用，所以一定存在、一定有权限。
//   代价是它会切前台（= 一次跳转），但跳完之后 App 会进入录音待机（pip=1），
//   而 pip=1 期间日志已证明 100% 免跳（1793027166 / 1793027182 两轮 requireJump=0，零 JUMP）。
//   所以目标是「用有头拉起把 pip 点亮一次，然后靠 pip 长期免跳」。
//
// ⭐ 同时记录 pip 1→0 的精确上下文（这是「最多跳几次」的唯一决定因素）：
//   pip 掉的那一刻距上次 session_stopped 多少秒、appAlive 还在不在。
//   如果 pip 能活很久 ⇒ 「跳一次就长期免跳」成立；如果几秒就掉 ⇒ 得在 pip 掉前主动补。

// 上一次会话结束（reason=session_stopped）的时间戳，用来量 pip 掉之前活了多久
static NSTimeInterval gRKVLLastSessionStop = 0;

// 有头拉起主 App：LSApplicationWorkspace 单参 openApplicationWithBundleID:
// 返回 YES = 请求被受理（App 会被带到前台，等价于一次跳转）
static BOOL RKVLForegroundLaunchApp(int *outOK) {
    if (outOK) *outOK = 0;
    Class wsCls = objc_getClass("LSApplicationWorkspace");
    if (!wsCls) {
        RKVLLog(@"[launch] LSApplicationWorkspace class missing");
        return NO;
    }
    id ws = ((id (*)(id, SEL))objc_msgSend)((id)wsCls, sel_registerName("defaultWorkspace"));
    SEL s = sel_registerName("openApplicationWithBundleID:");
    if (!ws || ![ws respondsToSelector:s]) {
        RKVLLog(@"[launch] defaultWorkspace=%p / openApplicationWithBundleID: 不可用", ws);
        return NO;
    }
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, @"com.tencent.wetype");
    RKVLLog(@"[launch] openApplicationWithBundleID: (有头) ok=%d", ok);
    if (outOK) *outOK = ok ? 1 : 0;
    return ok;
}

// 保留 kill(-1, SIGCONT)：对 Mach 挂起无效，但对 job-control 停住的进程有效，成本为零。
static int RKVLSignalAllCont(void) {
    int rc = kill(-1, SIGCONT);
    RKVLLog(@"[wake] kill(-1,SIGCONT) rc=%d errno=%d", rc, errno);
    return rc;
}

#pragma mark - 2.3.52 跳过去之后自动回宿主 App

// ⭐ 用户观测（2026-10-26）：
//   原生跳转 = 「跳过去 → 自动回来」，但那个回来动作正好在 pip 建立之前，
//   把 pip 掐死了 ⇒ 免跳永远站不住。
//   我们 2.3.51 的有头拉起 = 「跳过去 → 不回来」⇒ pip 反而活了、能免跳，
//   代价是用户得手动切回微信。
//   ⇒ 正解 = 「跳过去 → 等 pip 起来 → 再自动回来」。
//     顺序换了，回来这一下就掐不掉已经建好的 pip（pip 本来就是给后台用的）。
//
// 宿主是谁？WeType 自己完全不记（wxkb_plugin 里零 host bundle 符号），
// 只能在**跳转之前**问系统：此刻前台那个 App 就是宿主。
//
// ⛔ 2.3.52 踩过的坑（IPS 已证实，别再试）：`SBFrontmostApplicationDisplayIdentifier`
//   虽然 dlsym 能取到非空地址，但**调用返回值是垃圾**（0x10000003），
//   我们把它当 CFString 发 copy ⇒ EXC_BAD_ACCESS at 0x10000003，键盘扩展每点一次语音崩一次。
//   x0=0x10000003 / x1="copy" / pc=objc_msgSend，调用点 = RainbowKeyboard.dylib +132116。
//   ⇒ 结论：**签名没验证过的私有 C 函数绝对不能直接调**。C 函数没有 respondsToSelector 保护，
//     参数/返回类型猜错就是静默返回垃圾，比 ObjC 危险得多。
//
// 现在只走一条：LSApplicationWorkspace -frontmostApplication（真 ObjC 方法，
// respondsToSelector 先行 + nil 安全 + isKindOfClass 兜底，取不到就老实放弃）。

static NSString *gRKVLHostBundle = nil;   // 跳转前的前台 App（= 要回来的目标）

static NSString *RKVLFrontmostBundleID(NSString **outVia) {
    if (outVia) *outVia = @"none";

    Class wsCls = objc_getClass("LSApplicationWorkspace");
    if (!wsCls) {
        if (outVia) *outVia = @"no LSApplicationWorkspace class";
        return nil;
    }
    id ws = ((id (*)(id, SEL))objc_msgSend)((id)wsCls, sel_registerName("defaultWorkspace"));
    if (!ws) {
        if (outVia) *outVia = @"no defaultWorkspace";
        return nil;
    }
    SEL s = sel_registerName("frontmostApplication");
    if (![ws respondsToSelector:s]) {
        if (outVia) *outVia = @"LSWorkspace(no frontmostApplication)";
        return nil;
    }
    id app = ((id (*)(id, SEL))objc_msgSend)(ws, s);
    if (!app) {
        if (outVia) *outVia = @"LSWorkspace.frontmost(nil)";
        return nil;
    }
    SEL bs = sel_registerName("bundleIdentifier");
    if (![app respondsToSelector:bs]) {
        if (outVia) *outVia = @"frontmost(no bundleIdentifier)";
        return nil;
    }
    id bid = ((id (*)(id, SEL))objc_msgSend)(app, bs);
    if (![bid isKindOfClass:[NSString class]] || [(NSString *)bid length] == 0) {
        if (outVia) *outVia = @"frontmost(bad bid)";
        return nil;
    }
    if (outVia) *outVia = @"LSWorkspace.frontmost";
    return [(NSString *)bid copy];
}

// 用 LSApplicationWorkspace 单参接口把指定 App 提到前台（有头）。
// 这是 WeType 自己在用的那条，权限一定够。
static BOOL RKVLActivateBundle(NSString *bid, int *outOK) {
    if (outOK) *outOK = 0;
    if (!bid.length) return NO;
    Class wsCls = objc_getClass("LSApplicationWorkspace");
    if (!wsCls) return NO;
    id ws = ((id (*)(id, SEL))objc_msgSend)((id)wsCls, sel_registerName("defaultWorkspace"));
    SEL s = sel_registerName("openApplicationWithBundleID:");
    if (!ws || ![ws respondsToSelector:s]) return NO;
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, bid);
    if (outOK) *outOK = ok ? 1 : 0;
    return ok;
}

// 回宿主的轮询状态机。
// 条件：pip=1 且 mic=0 —— 说明主 App 已经进「录音待机」（pip 立住了），
// 这时候切回微信，pip 是后台播放语义，掐不掉。
// 15s 还没等到 pip 就兜底硬回：宁可回到微信（至少用户能继续用微信），
// 也不要把他扔在输入法里；日志会记 timeout，下一次据此调策略。
static BOOL gRKVLReturnPending = NO;
static int  gRKVLReturnTicks = 0;
// ⚠️ 必须「先见过 mic=1」才允许靠 pip 回跳。
//   否则 App 一被拉起就进待机 pip=1、录音还没开始，我们 0.3s 就把它拽回来，
//   用户等于一个字都没说上。先录上（mic=1）再谈回跳。
static BOOL gRKVLReturnSawMic = NO;

static void RKVLReturnTick(void);

static void RKVLReturnToHost(NSString *why) {
    NSString *bid = gRKVLHostBundle;
    if (!bid.length) {
        RKVLLog(@"[back] (%@) 没有宿主 bundle，放弃回跳", why);
        return;
    }
    int ok = 0;
    BOOL r = RKVLActivateBundle(bid, &ok);
    RKVLLog(@"[back] (%@) -> %@ ok=%d(%d) 之后 mask=0x%x mic=%d pip=%d",
            why, bid, r, ok, RKVLProbeMask(),
            RKVLProbeFlag(@selector(microphoneActive)),
            RKVLProbeFlag(@selector(pictureInPictureActive)));
}

static void RKVLReturnTick(void) {
    if (!gRKVLReturnPending) return;
    gRKVLReturnTicks++;
    int mic = RKVLProbeFlag(@selector(microphoneActive));
    int pip = RKVLProbeFlag(@selector(pictureInPictureActive));
    if (mic == 1 && !gRKVLReturnSawMic) {
        gRKVLReturnSawMic = YES;
        RKVLLog(@"[back] 见到 mic=1（录音已建立）t=%.1fs", gRKVLReturnTicks * 0.3);
    }
    if (gRKVLReturnSawMic && pip == 1 && mic == 0) {
        gRKVLReturnPending = NO;
        RKVLLog(@"[back] pip 已立住 t=%.1fs -> 回宿主", gRKVLReturnTicks * 0.3);
        RKVLReturnToHost(@"pip_ready");
        return;
    }
    if (gRKVLReturnTicks >= 50) {   // 15s
        gRKVLReturnPending = NO;
        RKVLLog(@"[back] timeout t=15s pip=%d mic=%d sawMic=%d -> 兜底回宿主",
                pip, mic, gRKVLReturnSawMic);
        RKVLReturnToHost(@"timeout");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RKVLReturnTick(); });
}

static void RKVLStartReturnWatch(void) {
    if (gRKVLReturnPending) return;
    gRKVLReturnPending = YES;
    gRKVLReturnTicks = 0;
    gRKVLReturnSawMic = NO;
    RKVLLog(@"[back] watch start host=%@", gRKVLHostBundle ?: @"-");
    RKVLReturnTick();
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
    if (v != last) {
        if (last && !v) {
            // ⭐ pip 掉的那一刻是「能不能长期免跳」的唯一分水岭，记全上下文
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            RKVLLog(@"[pip] 1→0 距上次session_stopped=%.1fs mic=%d appAlive=%d",
                    gRKVLLastSessionStop > 0 ? now - gRKVLLastSessionStop : -1.0,
                    RKVLProbeFlag(@selector(microphoneActive)),
                    RKVLProbeFlag(@selector(appAlive)));
        } else {
            RKVLLog(@"[probe] pictureInPictureActive -> %d", v);
        }
        last = v;
    }
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
        uint32_t before = RKVLProbeMask();
        int micB = RKVLProbeFlag(@selector(microphoneActive));
        int pipB = RKVLProbeFlag(@selector(pictureInPictureActive));
        int sigRc = RKVLSignalAllCont();
        int lok = 0;
        // 只有 pip/mic 都没有时才需要拉起：pip=1 时本来就能免跳，别去打扰 App。
        BOOL launched = NO;
        if (pipB != 1 && micB != 1) {
            // ⭐ 必须赶在拉起之前问：此刻前台 App 就是我们要回来的宿主。
            //   拉起之后前台就变成 wxkb 了，再问只会拿到自己。
            NSString *via = nil;
            gRKVLHostBundle = RKVLFrontmostBundleID(&via);
            RKVLLogForce(@"[back] host=%@ via=%@", gRKVLHostBundle ?: @"(nil)", via);
            launched = RKVLForegroundLaunchApp(&lok);
        } else {
            RKVLLog(@"[launch] skip（已有 pip/mic 无需拉起）mic=%d pip=%d", micB, pipB);
        }
        RKVLLog(@"[launch] result ok=%d(k=%d) sigRc=%d mask_before=0x%x mic=%d pip=%d appAlive=%d",
                launched, lok, sigRc, before, micB, pipB,
                RKVLProbeFlag(@selector(appAlive)));
        if (launched) {
            // 有头拉起后给 App 600ms 把界面/录音待机拉起来再交给 %orig
            usleep(600 * 1000);
            RKVLLog(@"[wake] +0.6s mask=0x%x mic=%d pip=%d",
                    RKVLProbeMask(),
                    RKVLProbeFlag(@selector(microphoneActive)),
                    RKVLProbeFlag(@selector(pictureInPictureActive)));
            // 拉起成功就开始盯着 pip，一旦立住立刻把宿主拉回前台
            RKVLStartReturnWatch();
        }
        for (double d = 2.0; d <= 8.1; d += 2.0) {
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
    if ([reason isKindOfClass:[NSString class]] &&
        [(NSString *)reason containsString:@"session_stopped"]) {
        gRKVLLastSessionStop = [NSDate date].timeIntervalSince1970;
    }
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
        RKVLLogForce(@"==== RKVoiceJumpProbe 2.3.53 loaded path=%@ ====", RKVLLogPath());
        // 一次性探测：后台拉起要用的三个符号在不在（决定 ①② 有没有机会）。
        {
            void *sb = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
            BOOL s1 = sb && dlsym(sb, "SBSLaunchApplicationWithIdentifier");
            BOOL s2 = sb && dlsym(sb, "SBSLaunchApplicationWithIdentifierAndLaunchOptions");
            Class wc = objc_getClass("LSApplicationWorkspace");
            id w = wc ? ((id (*)(id, SEL))objc_msgSend)((id)wc, sel_registerName("defaultWorkspace")) : nil;
            BOOL s3 = w && [w respondsToSelector:sel_registerName("openApplicationWithBundleID:")];
            RKVLLogForce(@"[cfg] launchable SBS=%d SBSOpts=%d LSWS_single=%d", s1, s2, s3);
            // 2.3.52：回跳要用「谁是前台 App」。只查 ObjC 那条；
            // SBFrontmostApplicationDisplayIdentifier 虽然符号在，但调用返回值是垃圾
            // （2.3.52 崩溃根因），只记存在性、绝不调用。
            BOOL s4 = sb && dlsym(sb, "SBFrontmostApplicationDisplayIdentifier");
            BOOL s5 = w && [w respondsToSelector:sel_registerName("frontmostApplication")];
            RKVLLogForce(@"[cfg] frontmost SBsym=%d(不用) LSfront=%d", s4, s5);
        }
        NSDictionary *p = RKReadEffectivePreferences();
        RKVLLogForce(@"[cfg] logEnabled=%d trial=%d wake=%d Enabled=%@ AIRecorderLog=%@ VoiceNoJumpTrial=%@ VoiceWakeApp=%@ rev=%@ bundle=%@",
                RKVLLogEnabled, RKVLNoJumpTrial, RKVLVoiceWake, p[@"Enabled"], p[@"AIRecorderLog"],
                p[@"VoiceNoJumpTrial"], p[@"VoiceWakeApp"], p[@"RKSettingsRevision"],
                [[NSBundle mainBundle] bundleIdentifier]);
        // 顺手确认超时兜底方法在当前版本存在（只查不 hook，避免猜错签名改坏调用约定）。
        Class svc = objc_getClass("WBVoiceInputService");
        BOOL hasFallback = svc &&
            class_getInstanceMethod(svc, @selector(_fallbackToURLSchemeForPIPStartCommandTimeoutWithSessionId:)) != NULL;
        RKVLLogForce(@"[cfg] PIPStartTimeoutFallback method=%d", hasFallback);
    }
}
