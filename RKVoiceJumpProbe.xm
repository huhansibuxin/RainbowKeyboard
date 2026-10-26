// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断 + 免跳实验（2.3.57）
//
// == 2.3.55 做的事：回跳时机改成「pip 一立住就回」+ 宿主持久化 ==
//   用户实测 2.3.54：能跳回去了，但 (a) 半注销后**第一次**点语音不回来，
//   (b) 回来之后语音面板没了（要重新点「点击说话」），而微信输入法原生回来后面板还在。
//   (a) 根因：宿主要靠「WeType 报给我们」才有，半注销后第一拍扩展进程是新的、
//       ctx/内存缓存都空 ⇒ host=nil ⇒ 回跳被跳过。⇒ 宿主**落盘**，下个进程启动先读回来。
//   (b) 根因：旧判据是「pip=1 且 mic=0」= 等录音**结束**才回，回来时语音会话已收尾，
//       面板自然收掉。原生是「待机一建立（pip=1）就立刻回」，面板还在 ⇒ 直接能接着录。
//       ⇒ 判据改成「只要 pip=1 就回」，不再要求先见过 mic。
//   另外：宿主未知时**不拉起**（拉得起、回不来 = 把人扔在输入法里），老实交给原生跳转。
//
// == 2.3.56 做的事：回跳时机按原生节奏（录音一起就回，不等 pip）+ 日志不再看开关 ==
//   2.3.55 实测（pid 87733）第一次按压的完整时间线：
//     565.885 launch ok=1 → 566.532 [JUMP] → 567.048 mic=1（录音起）
//     → **575.934 pip=1** → 575.950 回跳 → 576.4 standby → session_stopped
//   ⇒ 宿主拿到的是对的（`[back] host=com.tencent.xin via=WeType.hostBundleID(缓存)`），
//     **问题不在「拿不到回跳目标」，而在「等 pip 等到 7~10 秒」**：pip 只在
//     「录音结束进待机」那一刻才出现，等它 = 让用户在主 App 里干等一整句话的时间，
//     观感就是「不会跳回来」。
//   ⇒ 改成：见到 mic=1 后再给 1.0s 稳定期就回（不等 pip），回来之后继续盯 5 秒，
//     看 pip 有没有自己在后台长出来、mic 有没有被掐死（`[back] after +X.Xs`）。
//   另：`RKVLLog` 改成**永远写**。用户「开关一直开着但它不写」的根因是开关值要靠
//     跨进程快照/固化表兜底，扩展在注销后读不到 Preferences 就回落成 0，整条诊断链静默。
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
// 2.3.57（本版）：只做减法，**零行为变更**。
//   2.3.56 跑通之后，把过程里堆的诊断全部清掉（都已判死或已答完）：
//     · kill(-1,SIGCONT)        rc=0 errno=2，对 Mach 挂起无效，每点一次白跑一次 syscall
//     · [wake] +2/4/6/8s        拉起后 pip 成立时刻已确定（固定 ~866ms），4 个定时器纯浪费
//     · RKVLPostReturnProbe     回跳后 pip 会在 0.5~1.0s 自己长回来（三轮实证），不必再盯
//     · [gate] 全量 → 变化才记 一拍内被调 7 次，一轮语音几十行日志
//     · currentMask 日志 hook   信息已被 [gate] 覆盖，白多三次探针调用
//     · [standby] / [reason] / [ipc] 三个纯观测 hook
//     · ctor 里的三组死探测（SBS 无头 / SBFrontmost / PIPStartTimeoutFallback）
//     · RKVLLogEnabled 死变量（RKVLLog 已不看开关）
//   判据、宿主链路、回跳状态机一行未动。

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

// ⛔ 2.3.57 删：`RKVLLogEnabled`。2.3.56 起 RKVLLog 已改为无条件写，
//   这个变量再没有任何读者，留着只会让人以为「关掉开关能少写日志」。
// 2.3.45：语音免跳转实验开关。开 = requireJumpToMainAppForRecording 强制返回 NO。
static BOOL RKVLNoJumpTrial = NO;
// 2.3.46：拉起/回跳总开关。开 = 点语音时主动把主 App 提起来并自动回跳。
static BOOL RKVLVoiceWake = NO;

static void RKVLLogRefresh(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    BOOL master = (!enabled || [enabled boolValue]);
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
    // ⚠️ 2.3.56：这里**不再看开关**。
    //   用户反馈「日志开关一直是开的，但它不写」—— 根因是开关值要靠跨进程快照/固化表兜底，
    //   而键盘扩展在注销后读不到 /var/mobile/Library/Preferences，回落固化表就是 0，
    //   于是开关读成 0，整条诊断链静默。诊断期的日志比开关重要：
    //   这个文件只由「语音诊断」相关代码写，本来就只在我们自己调试时看。
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

// 2.3.57：与 RKVLLog 行为已完全一致（都是无条件写），唯一区别是行首多一个 `(强制) ` 标记，
// 方便 `grep 强制` 一眼挑出「判据命中/回跳结果」这类关键行。当时加它是因为 2.3.52 崩溃那轮
// 日志被开关吞掉、白崩一次；开关现在是死的，但这种「关键行一定要落地」的取舍仍然成立。
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

// ⛔ 2.3.57 删：`kill(-1, SIGCONT)`。
//   实测 rc=0 errno=2(ESRCH) 恒成立 —— 同 uid 下根本没有可送达的目标，对 Mach task_suspend
//   本就是空操作（2.3.49 已判死）。留着只是每点一次语音白跑一次 syscall + 一行日志。
//   真正把主 App 叫起来的是后面的 openApplicationWithBundleID:（有头）。

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
// 2.3.54：WeType 自己报出来的宿主 bundle id（靠 hook 它的 hostBundleID 属性拿到）
static NSString *gRKVLHostFromWeType = nil;
// 2.3.54：缓存 WBInputViewContext 实例，拉起时主动问一次 hostBundleID（不依赖 getter 被调用）
static __unsafe_unretained id gRKVLInputCtx = nil;

static void RKVLNoteHostBundle(id v, const char *via);   // 前置声明（定义在 %hook 区）

// == 2.3.55：宿主 bundle id 落盘 ==
// 起因：半注销后**第一次**点语音不回来 —— 那一刻扩展进程是新的（或刚被系统回收过），
// ctx / 内存缓存都还空，宿主取不到 ⇒ 回跳被跳过。
// 落盘在扩展自己的沙盒 Library/Preferences 下（tmp 会被系统清、重装 deb 也会清），
// 下次进程起来第一件事就是把它读回来当兜底。
#define RKVL_HOST_STORE @"com.minis.rainbowkeyboard.host.plist"

static NSString *RKVLHostStorePath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *lib = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
        [[NSFileManager defaultManager] createDirectoryAtPath:lib
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        p = [lib stringByAppendingPathComponent:RKVL_HOST_STORE];
    });
    return p;
}

static BOOL RKVLHostLooksValid(NSString *bid) {
    if (![bid isKindOfClass:[NSString class]] || bid.length < 5) return NO;
    if ([bid containsString:@"wetype"]) return NO;                   // 自己（wxkb / wxkb_plugin）
    if ([bid isEqualToString:@"com.apple.springboard"]) return NO;    // 桌面
    if ([bid hasPrefix:@"com.apple.Preferences"]) return NO;          // 在设置里试键盘
    return YES;
}

static NSString *RKVLHostLoad(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RKVLHostStorePath()];
    NSString *h = d[@"host"];
    return RKVLHostLooksValid(h) ? h : nil;
}

static void RKVLHostSave(NSString *bid) {
    if (!RKVLHostLooksValid(bid)) return;
    @try {
        [@{@"host": bid, @"ts": @([NSDate date].timeIntervalSince1970)}
            writeToFile:RKVLHostStorePath() atomically:YES];
    } @catch (__unused NSException *e) {}
}

// 从缓存的 WBInputViewContext 主动读宿主。全部走 respondsToSelector + isKindOfClass，
// 读不到就 nil，绝不猜。
static NSString *RKVLHostFromCachedCtx(void) {
    id ctx = gRKVLInputCtx;
    if (!ctx) return nil;
    SEL s = sel_registerName("hostBundleID");
    if (![ctx respondsToSelector:s]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(ctx, s);
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 4) {
        return [(NSString *)v copy];
    }
    return nil;
}

static NSString *RKVLFrontmostBundleID(NSString **outVia) {
    if (outVia) *outVia = @"none";

    // ⭐ 2.3.54：WeType 自己知道宿主，优先用它 —— 系统侧（LS/SB）在 iOS16 问不出来。
    // 顺序讲究：**先主动读 ctx（当下最新的宿主）**，再退回 hook 到的缓存值
    // （缓存可能是上一次键盘会话的宿主，比如刚从设置切回来）。
    NSString *fromCtx = RKVLHostFromCachedCtx();
    if (RKVLHostLooksValid(fromCtx)) {
        RKVLNoteHostBundle(fromCtx, "ctx.active");
        if (outVia) *outVia = @"WeType.ctx(主动)";
        return fromCtx;
    }
    if (RKVLHostLooksValid(gRKVLHostFromWeType)) {
        if (outVia) *outVia = @"WeType.hostBundleID(缓存)";
        return gRKVLHostFromWeType;
    }
    // 2.3.55：进程是新起的（半注销后第一次点语音就是这种），内存里啥都没有 ⇒ 读上次落盘的
    NSString *fromDisk = RKVLHostLoad();
    if (fromDisk.length) {
        if (outVia) *outVia = @"落盘(上次宿主)";
        return fromDisk;
    }

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

// 回宿主的轮询状态机（2.3.55 按「原生行为」重写）。
//
// ⭐ 为什么这一版把判据从「pip=1 且 mic=0」改成「只要 pip=1」：
//   用户实测的原生形态是 —— 跳过去 → **立刻**回来（还没开始说话）→ 语音面板还挂着，
//   接着点「点击说话」就能直接录，不用再跳。
//   而我们上一版是等 session_stopped（录音结束）才回来，回来时语音会话已经收尾，
//   面板自然没了 ⇒ 用户要重新点语音，于是又跳一次。
//   pip=1 就是「主 App 已进录音待机」的凭证，待机建立的那一刻回来，语音面板还在。
static BOOL gRKVLReturnPending = NO;
static int  gRKVLReturnTicks = 0;
static int  gRKVLReturnTries = 0;
static BOOL gRKVLReturnSawMic = NO;
static double gRKVLFirstMicT = 0;   // 首次见到 mic=1 的那一拍（单位秒）

// ⛔ 2.3.57 删：回来之后盯 5 秒的 `RKVLPostReturnProbe`（+0.5/1/2/4s 四步）。
//   它要验的问题已经在 2.3.56 那轮日志里答完了 —— 回跳成功后 pip 会在 0.5~1.0s 内自己长回来
//   （三轮回跳全部 `after +1.0s mask=0x3`）。留着只是每次回跳多挂 4 个定时器。

static void RKVLReturnTick(void);

static void RKVLReturnToHost(NSString *why) {
    NSString *bid = gRKVLHostBundle;
    if (!bid.length) {
        RKVLLogForce(@"[back] (%@) 没有宿主 bundle，放弃回跳", why);
        return;
    }
    int ok = 0;
    BOOL r = RKVLActivateBundle(bid, &ok);
    RKVLLogForce(@"[back] (%@) -> %@ ok=%@(%d) mask=0x%x mic=%d pip=%d",
                 why, bid, r ? @"YES" : @"NO", ok, RKVLProbeMask(),
                 RKVLProbeFlag(@selector(microphoneActive)),
                 RKVLProbeFlag(@selector(pictureInPictureActive)));
    if (!r && gRKVLReturnTries < 2) {
        // 半注销刚醒的第一拍偶尔会被系统拒一次（前台切换还没就绪），重试一次
        gRKVLReturnTries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            int ok2 = 0;
            BOOL r2 = RKVLActivateBundle(bid, &ok2);
            RKVLLogForce(@"[back] retry#%d -> ok=%d(%d)", gRKVLReturnTries, r2 ? 1 : 0, ok2);
        });
    } else if (r) {
        RKVLHostSave(bid);   // 回跳成功 ⇒ 这个宿主是可信的，存下来给下次进程启动用
    }
}

static void RKVLReturnTick(void) {
    if (!gRKVLReturnPending) return;
    gRKVLReturnTicks++;
    int mic = RKVLProbeFlag(@selector(microphoneActive));
    int pip = RKVLProbeFlag(@selector(pictureInPictureActive));
    double t = gRKVLReturnTicks * 0.25;
    if (mic == 1) {
        if (!gRKVLReturnSawMic) {
            gRKVLReturnSawMic = YES;
            gRKVLFirstMicT = t;
            RKVLLog(@"[back] 见到 mic=1（录音已建立）t=%.2fs pip=%d", t, pip);
        } else if (t - gRKVLFirstMicT >= 1.0) {
            // ⭐ 2.3.56 核心：录音一起就把人送回去，**不等 pip**。
            //   依据（2.3.55 实测）：pip 只在「录音结束进待机」时才出现（+7.25s），
            //   等它等于让用户在主 App 里干等 7~10 秒，用户观感就是「不回来」。
            //   微信输入法原生就是这个节奏：跳过去 → 录音一起 → 立刻回。
            //   留 1.0s 稳定期：录音刚起就切走，容易把采集掐掉（「录音失败」）。
            gRKVLReturnPending = NO;
            RKVLLog(@"[back] 录音已起 t=%.2fs（mic=1 +1.0s 稳定）pip=%d -> 回宿主", t, pip);
            RKVLReturnToHost(@"mic_started");
            return;
        }
    }
    // ① 主 App 一进录音待机（pip=1）就立刻回
    if (pip == 1) {
        gRKVLReturnPending = NO;
        RKVLLog(@"[back] pip 已立住 t=%.2fs mic=%d -> 回宿主", t, mic);
        RKVLReturnToHost(@"pip_ready");
        return;
    }
    // ② 15s 还没 pip、且不在录音 ⇒ 兜底回（宁可回微信，也不把人扔在输入法里）
    if (gRKVLReturnTicks >= 60 && mic == 0) {
        gRKVLReturnPending = NO;
        RKVLLogForce(@"[back] timeout t=%.1fs pip=0 mic=0 sawMic=%d -> 兜底回宿主",
                     t, gRKVLReturnSawMic);
        RKVLReturnToHost(@"timeout");
        return;
    }
    // ③ 40s 硬兜底（录音卡住也要回去）
    if (gRKVLReturnTicks >= 160) {
        gRKVLReturnPending = NO;
        RKVLLogForce(@"[back] hard-timeout t=%.1fs pip=%d mic=%d -> 强制回宿主", t, pip, mic);
        RKVLReturnToHost(@"hard_timeout");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RKVLReturnTick(); });
}

static void RKVLStartReturnWatch(void) {
    if (gRKVLReturnPending) return;
    gRKVLReturnPending = YES;
    gRKVLReturnTicks = 0;
    gRKVLReturnTries = 0;
    gRKVLReturnSawMic = NO;
    gRKVLFirstMicT = 0;
    RKVLLogForce(@"[back] watch start host=%@", gRKVLHostBundle ?: @"-");
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
    if (v != last) { last = v; RKVLLogForce(@"[probe] mic -> %d", v); }
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
            RKVLLogForce(@"[pip] 1→0 距上次session_stopped=%.1fs mic=%d appAlive=%d",
                    gRKVLLastSessionStop > 0 ? now - gRKVLLastSessionStop : -1.0,
                    RKVLProbeFlag(@selector(microphoneActive)),
                    RKVLProbeFlag(@selector(appAlive)));
        } else {
            RKVLLogForce(@"[probe] pip -> %d", v);
        }
        last = v;
    }
    return v;
}

// ⛔ 2.3.57 删：`- (uint32_t)currentMask` 的日志 hook。
//   它原本用来确认「主 App 到底报了哪些能力位」，这个信息现在 `[gate]` 那行（变化时记）已完全覆盖；
//   掩码变化一次它就要额外三次 RKVLProbeFlag 调用 + 一次 fopen，纯属重复取样。
//   `RKVLProbeMask()` 是直接向实例发 currentMask，不依赖这个 hook，删掉不影响任何判据。

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
    // 2.3.57：这个 getter 一拍内会被调好几次（一轮语音实测 7 次），
    // 全量记就是日志噪音。只记「四个位里有任何一位翻转」的那一次。
    static int lastKey = -1;
    int key = (jump ? 1 : 0) | (alive == 1 ? 2 : 0) | (mic == 1 ? 4 : 0) | (pip == 1 ? 8 : 0);
    if (key != lastKey) {
        lastKey = key;
        RKVLLog(@"[gate] requireJump=%d (appAlive=%d mic=%d pip=%d)", jump, alive, mic, pip);
    }
    return jump;
}

// 真正的入口（2.3.42 里 hook 的 launchWcVoiceWithContext: 全程零命中）。
// 2.3.46：开关打开时，先让挂起的主 App 回到 RUNNING，再让它去处理随后的 PIPStart。
- (void)launchWBRecorderWithContext:(id)context finishedBlock:(id)block {
    RKVLLogForce(@"[entry] launchWBRecorder ctx=%p trial=%d wake=%d mask=0x%x",
            context, RKVLNoJumpTrial, RKVLVoiceWake, RKVLProbeMask());
    if (RKVLVoiceWake) {
        uint32_t before = RKVLProbeMask();
        int micB = RKVLProbeFlag(@selector(microphoneActive));
        int pipB = RKVLProbeFlag(@selector(pictureInPictureActive));
        int lok = 0;
        // ⭐ 必须赶在拉起之前问：此刻前台 App 就是我们要回来的宿主。
        //   拉起之后前台就变成 wxkb 了，再问只会拿到自己。
        NSString *via = nil;
        gRKVLHostBundle = RKVLFrontmostBundleID(&via);
        RKVLLogForce(@"[back] host=%@ via=%@", gRKVLHostBundle ?: @"(nil)", via);
        // 只有 pip/mic 都没有时才需要拉起：pip=1 时本来就能免跳，别去打扰 App。
        BOOL launched = NO;
        // ⭐ 必须有宿主才拉起：拉得起、回不来 = 把用户扔在输入法里。宿主取不到就老实走原生跳转。
        if (gRKVLHostBundle.length && pipB != 1 && micB != 1) {
            launched = RKVLForegroundLaunchApp(&lok);
        } else if (!gRKVLHostBundle.length) {
            RKVLLogForce(@"[launch] 宿主未知 -> 不拉起（交给微信输入法原生跳转）");
        } else {
            RKVLLog(@"[launch] skip（已有 pip/mic 无需拉起）mic=%d pip=%d", micB, pipB);
        }
        RKVLLogForce(@"[launch] result ok=%d(k=%d) mask_before=0x%x mic=%d pip=%d appAlive=%d",
                launched, lok, before, micB, pipB,
                RKVLProbeFlag(@selector(appAlive)));
        if (launched) {
            // 有头拉起后给 App 600ms 把界面/录音待机拉起来再交给 %orig
            usleep(600 * 1000);
            // 拉起成功就开始盯着 pip，一旦立住立刻把宿主拉回前台
            RKVLStartReturnWatch();
        }
        // ⛔ 2.3.57 删：`[wake] +2/+4/+6/+8s` 那一组定时器日志。
        //   它们是 2.3.51 查「拉起后 pip 多久才成立」用的，结论已经拿到（固定 ~866ms），
        //   现在只会在每点一次语音时白挂 4 个 dispatch_after。
    }
    %orig;
}

// reason 就是二进制里那套枚举：app_background_without_audio / app_killed /
// pip_start_timeout_url_fallback / launch_app_from_background …
// 2.3.57：只留「记下 session_stopped 时刻」的用途（供 `[pip] 1→0` 算 pip 活了多久），
//   不再每轮打 `[reason]` 全量日志 —— 它一轮要打好几次，信息价值已经耗尽。
- (void)updateLaunchingRecorderApp:(BOOL)launching reason:(id)reason {
    if ([reason isKindOfClass:[NSString class]] &&
        [(NSString *)reason containsString:@"session_stopped"]) {
        gRKVLLastSessionStop = [NSDate date].timeIntervalSince1970;
    }
    %orig;
}

// 这行是「到底有没有真的跳」的唯一凭证 → 必须留。
- (void)launchAppFromBackgroundWithAllowBluetooth:(BOOL)allow pipTimeoutFallback:(BOOL)fallback {
    RKVLLog(@"[JUMP] launchAppFromBackground allowBT=%d pipFallback=%d", allow, fallback);
    %orig;
}

// ⛔ 2.3.57 删：`[standby] -> RecorderStandby`。它当初是为了确认「强制免跳后会不会进待机」，
//   结论早已确定；而且它每轮都打，还顺带把 RKVLProbeMask 算一遍，纯噪音。

%end

// ⛔ 2.3.57 删：`WBVoiceCommandChannel` / `WBVoiceEventChannel` 的 `-ipcChannel` 探针。
//   当初是想从 IPC 通道摸 PIPStart 超时，两条通道最后一条都没用上：
//   `[ipc] commandChannel=%p` 只在一轮里打过两次指针，之后的 180KB 日志里再没出现过它。
//   而且这两个 hook 只读不写、也不参与任何判据 —— 纯死重，删了行为完全一致。

#pragma mark - 2.3.54 向 WeType 要宿主 bundle id

// ⭐ 为什么改这条：2.3.53 实测 `[cfg] frontmost SBFrontmost=1(不用) LSfront=0`
//   —— iOS 16 的 LSApplicationWorkspace **没有** -frontmostApplication，
//   SBFrontmostApplicationDisplayIdentifier 又返回垃圾（会崩）。系统侧问不出来。
//
// ✅ 但 WeType 自己一定知道宿主：静态实证（wxkb_plugin 方法表）
//   `WBInputViewController -inputViewContext` → `WBInputViewContext -hostBundleID`
//   `WBRootViewManager    -hostBundleID` / `-refreshHostBundleID` / `-hostBundleIDDidChange`
//   `WBVoicePendingClose  -hostBundleId` / `-setHostBundleId:`
//   `WBVoiceReportContext -hostBundleId` / `-setHostBundleId:`
//   `WBVoiceInputService  -currentVoiceHostPid`
//   还有一条日志格式串：`<WBInputViewController: %p>, host = %@, %@`
//   ⇒ 借 WeType 自己的答案，比猜私有系统 API 可靠得多（也不会有崩的风险）。
//
// 做法：getter 和 setter 都挂，谁先给我们算谁。全部只是「读一份返回值 / 抄一份入参」，
// 不改任何行为。

static void RKVLNoteHostBundle(id v, const char *via) {
    if (!v || ![v isKindOfClass:[NSString class]]) return;
    NSString *s = (NSString *)v;
    if (s.length < 5 || ![s containsString:@"."]) return;          // 不像 bundle id
    if ([s hasPrefix:@"com.tencent.wetype"]) return;               // 自己，没用
    if (s.length > 128) return;
    if (gRKVLHostFromWeType && [gRKVLHostFromWeType isEqualToString:s]) return;
    gRKVLHostFromWeType = [s copy];
    RKVLHostSave(s);   // 2.3.55：学到的宿主立刻落盘（进程被回收后仍能回跳）
    RKVLLogForce(@"[host] WeType 报宿主 = %@ (via %s)", s, via);
}

%group RKHostProbe
%hook WBInputViewContext
- (id)hostBundleID {
    id v = %orig;
    RKVLNoteHostBundle(v, "WBInputViewContext.get");
    return v;
}
%end

// 键盘主 VC 一定会在初始化时访问 inputViewContext —— 顺手把 context 实例缓存下来，
// 这样即使 hostBundleID 的 getter 一直没人调，我们也能在拉起那一刻主动去读。
%hook WBInputViewController
- (id)inputViewContext {
    id c = %orig;
    if (c) {
        if (c != gRKVLInputCtx) {
            gRKVLInputCtx = c;
            RKVLLogForce(@"[host] 缓存 inputViewContext=%p", c);
        }
        SEL s = sel_registerName("hostBundleID");
        if ([c respondsToSelector:s]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(c, s);
            RKVLNoteHostBundle(v, "WBInputViewController.ctx");
        }
    }
    return c;
}
%end

%hook WBRootViewManager
- (id)hostBundleID {
    id v = %orig;
    RKVLNoteHostBundle(v, "WBRootViewManager.get");
    return v;
}
%end
%end

// setter 这两个类单独一组：它们只是「锦上添花的捕获点」，
// 缺了也不影响主路径，所以不能跟上面那组绑在一起（绑一起会让整组 init 崩）。
%group RKHostProbe2
%hook WBVoicePendingClose
- (void)setHostBundleId:(id)v {
    RKVLNoteHostBundle(v, "WBVoicePendingClose.set");
    %orig;
}
%end

%hook WBVoiceReportContext
- (void)setHostBundleId:(id)v {
    RKVLNoteHostBundle(v, "WBVoiceReportContext.set");
    %orig;
}
%end
%end

%ctor {
    @autoreleasepool {
        RKVLLogRefresh();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RKVLPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        RKVLLogForce(@"==== RKVoiceJumpProbe 2.3.57 loaded path=%@ ====", RKVLLogPath());
        // 2.3.55：落盘的宿主（半注销后第一次点语音能靠它回跳）
        {
            NSString *mem = RKVLHostLoad();
            RKVLLogForce(@"[cfg] hostMemory=%@", mem ?: @"(none)");
        }
        // 只留一行生存性检查：拉起/回跳全靠它，缺了整个功能就是空转。
        // ⛔ 2.3.57 删掉的死探测（结论都已确定，别再挂回来）：
        //   SBSLaunchApplicationWithIdentifier / SBSOpts → 无头拉起 rc=9 判死（2.3.50）
        //   SBFrontmostApplicationDisplayIdentifier     → 返回值是垃圾、调用即崩（2.3.52）
        //   _fallbackToURLSchemeForPIPStart*            → 只查不 hook，无后续动作
        {
            Class wc = objc_getClass("LSApplicationWorkspace");
            id w = wc ? ((id (*)(id, SEL))objc_msgSend)((id)wc, sel_registerName("defaultWorkspace")) : nil;
            BOOL canOpen = w && [w respondsToSelector:sel_registerName("openApplicationWithBundleID:")];
            RKVLLogForce(@"[cfg] canOpenApp=%d", canOpen);
        }
        NSDictionary *p = RKReadEffectivePreferences();
        RKVLLogForce(@"[cfg] trial=%d wake=%d bundle=%@",
                RKVLNoJumpTrial, RKVLVoiceWake, [[NSBundle mainBundle] bundleIdentifier]);

        // ⚠️ Logos 硬规则：文件里一旦出现 %group，原来那些「不在 group 里」的 hook
        //   就归到 _ungrouped 组，**必须显式 %init(_ungrouped)**，否则编译直接报
        //   `error: non-initialized hook group: _ungrouped`（2.3.54 首次构建就栽在这）。
        %init(_ungrouped);

        // 2.3.54：装「向 WeType 要宿主」的 hook。类缺一个就整组不装，避免 hook 到不存在的类。
        BOOL h1 = objc_getClass("WBInputViewContext") != NULL;
        BOOL h2 = objc_getClass("WBRootViewManager") != NULL;
        BOOL h3 = objc_getClass("WBVoicePendingClose") != NULL;
        BOOL h4 = objc_getClass("WBVoiceReportContext") != NULL;
        BOOL h5 = objc_getClass("WBInputViewController") != NULL;
        RKVLLogForce(@"[cfg] hostprobe classes ctx=%d rvm=%d pending=%d report=%d vc=%d",
                     h1, h2, h3, h4, h5);
        if (h1 && h2 && h5) {
            %init(RKHostProbe);
            RKVLLogForce(@"[cfg] hostprobe installed");
        } else {
            RKVLLogForce(@"[cfg] hostprobe 未装（关键类缺失）");
        }
        if (h3 && h4) {
            %init(RKHostProbe2);
            RKVLLogForce(@"[cfg] hostprobe2 installed");
        }
    }
}
