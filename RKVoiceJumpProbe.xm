// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断 + 免跳实验（2.3.60）
//
// == 2.3.60（本版）：主 App 侧主动建 pip + 键盘侧连续右跳保底 ==
//   老板实测（2026-10-27，装 2.3.58 + 唤醒开关关 + TrollOpen 生效）：
//   "先打开 open 的小窗，然后往右跳我们又打开了，相当于两个都打开了"。
//   日志实证（pid 93105）：
//     1793034128.962 mic=1（录音已起 = TrollOpen 小窗已接管）
//     1793034129.815 我们兜底拉起（因为只看 pip=0，等了 1.8s）
//     1793034131.960 pip 才来（2.1s，比正常路径的 0.5s 慢得多）
//   ⇒ 1.8s 只等 pip 是错判据：**mic=1 就说明有人把录音拉起来了**，此时再拉起 = 第二个窗口。
//   新判据：必须 `mic==0 && pip==0 && 本轮从未见过录音` + JUMP 后 3.0s 才兜底。
//   一旦见过 mic/pip 就锁死「已被接管」（gRKVLSeenRecorder），本轮永不兜底。
//   顺带把观察窗从 6s 放宽到 10s（要看清「mic 起来了但 pip 迟到」这种慢路径）。
//   ➕ 新增 RKLaunchProbe：抓 WeType 自己的 URL 收敛路径（wetype://），
//     为「兜底也走 TrollOpen 小窗」取证（TrollOpen 的判定认 URL，不认 lsd XPC）。
//
// == 2.3.58：不再抢先拉起 —— 把「一次都不跳」的形态让给分屏插件 ==
//   老板实测（2026-10-27）：关掉「点语音前唤醒主 App」后，TrollOpen 就能用**悬浮窗**
//   打开微信输入法主 App，pip 建立后自己收进后台（不杀）= 一次都不跳。
//   根因：我们的 openApplicationWithBundleID: 从 appex 直接发 lsd XPC，
//   **绕过 SpringBoard 上的 TrollOpen 分屏路由**，把 wxkb 全屏激活 ⇒ 小窗出不来；
//   等 WeType 自己的 launch 到达时目标已在前台，shouldSplit 落空。
//   日志实证（wake=0 那轮）：[JUMP] 3416.417 → 3417.148（+731ms）appAlive/mic/pip 全 1，
//   比我们自己拉起还快（866ms），且全程 requireJump=0。
//   ⇒ 新策略：entry 不拉起，只起 watch；**JUMP 后 1.8s 仍 pip=0** 才判定「没人接这一跳」，
//     再兜底拉起 + 回跳（老形态）。有分屏插件时一次不跳，没有时照样能用。
//   开关默认值同步改成「关」（两份 defaults + 固化表 + specifier default + 自检脚本）。
//   ⚠️ 探针全部保留（老板要求）：等 TrollOpen 这条线彻底定稿后再统一清理。
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
#import <notify.h>
#import <time.h>
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
    // ⚠️ 2.3.56：这里**不再看开关**。
    //   用户反馈「日志开关一直是开的，但它不写」—— 根因是开关值要靠跨进程快照/固化表兜底，
    //   而键盘扩展在注销后读不到 /var/mobile/Library/Preferences，回落固化表就是 0，
    //   于是 RKVLLogEnabled=0，整条诊断链静默。诊断期的日志比开关重要：
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

#pragma mark - 2.3.60 请主 App 侧主动建 pip（解决半注销 pip 建不出来）

// 为什么用 notify 的 state 而不是普通 post：
//   主 App 挂着（suspended）时收不到 darwin post。但 `notify_set_state` 写的是
//   notify 守护进程里的**持久状态**，主 App 下次被 TrollOpen 小窗/拉起激活时
//   `notify_get_state` 一读就有 ⇒ 不依赖「通知能不能送达挂起进程」。
// 主 App 侧（RKWetypePipBuild.xm）读到后立刻调 WBVoiceInputPIPManager 建 pip，
// 并把这状态清零（一次性消费）。
static const char *const kRKVLPipReqName = "com.huhansibuxin.rk.pipreq";

static void RKVLPipRequestPost(void) {
    static int tok = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        notify_register_check(kRKVLPipReqName, &tok);
    });
    uint64_t ts = (uint64_t)time(NULL);
    uint32_t sst = notify_set_state(tok, ts);
    uint32_t pst = notify_post(kRKVLPipReqName);
    RKVLLogForce(@"[pipreq] 请求主 App 建 pip ts=%llu setState=%u post=%u",
                 (unsigned long long)ts, sst, pst);
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

// == 2.3.58：把「无条件抢先拉起」改成「先让分屏插件赢，失败才兜底」==
//
// ⭐ 老板实测（2026-10-27）：关掉「点语音前唤醒主 App」后，TrollOpen 就能用**悬浮窗**
//   把微信输入法主 App 打开，pip 建立后自己把小窗收进后台（不杀）= 一次都不跳。这是最终形态。
//   开着开关时小窗出不来：我们那条 openApplicationWithBundleID: 是从 appex 直接发 lsd XPC，
//   **绕过 SpringBoard 上的 TrollOpen 分屏路由**，把 wxkb 全屏激活；等 WeType 自己的 launch
//   到达时目标已在前台 ⇒ shouldSplit 落空。
//
// 日志实证（wake=0 那轮，pid 90019）：
//   3416.411 pip 1→0 / appAlive=0
//   3416.417 [JUMP] launchAppFromBackground      ← 原生跳（被 TrollOpen 接走 = 分屏小窗）
//   3417.148 appAlive=1 + mic=1 + pip=1          ← JUMP 后 **731ms** 全齐，全程 requireJump=0
//   ⇒ 分屏路径比我们自己拉起还快（我们拉起是 866ms）。
static BOOL gRKVLJumped = NO;            // 本轮是否已发生原生 JUMP（在 launchAppFromBackground hook 里置位）
static NSTimeInterval gRKVLJumpAt = 0;   // JUMP 时刻
static BOOL gRKVLFallbackLaunched = NO;  // 我们主动拉起过 ⇒ 必须回跳（否则用户被扔在输入法里）
// ⭐ 2.3.59：只要本轮见过 mic=1 或 pip=1，就说明**有人已经把录音拉起来了**
//   （有 TrollOpen = 悬浮小窗；没装 = 微信输入法自己全屏跳）。之后绝不许再兜底拉起，
//   否则就是「小窗已经开了，我们往右又开一次」= 老板实测的双窗口。
static BOOL gRKVLSeenRecorder = NO;

// 2.3.56：回来之后继续盯 5 秒 —— 要看清「回来那一刻 pip 有没有自己长出来、mic 有没有被掐死」。
//   日志实证（2.3.55）：等到 pip 才回，pip 是**录音结束进待机**时才出现的（+7.25s），
//   所以「等 pip」这条路等于让用户在主 App 里干等 7~10 秒 ⇒ 用户判定「不会跳回来」。
static void RKVLPostReturnProbe(int step) {
    static const double delays[] = {0.5, 1.0, 2.0, 4.0};
    if (step < 0 || step >= 4) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[step] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RKVLLogForce(@"[back] after +%.1fs mask=0x%x mic=%d pip=%d",
                     delays[step], RKVLProbeMask(),
                     RKVLProbeFlag(@selector(microphoneActive)),
                     RKVLProbeFlag(@selector(pictureInPictureActive)));
        RKVLPostReturnProbe(step + 1);
    });
}

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

    // 2.3.60：只作日志用，不再当兜底开关（兜底改看 pip 本身）
    if ((mic == 1 || pip == 1) && !gRKVLSeenRecorder) {
        gRKVLSeenRecorder = YES;
        RKVLLogForce(@"[back] 首次见到录音/待机（mic=%d pip=%d）t=%.2fs", mic, pip, t);
    }

    // ⭐ 2.3.60 ① pip 立住 —— 免跳成立。
    //   有 TrollOpen = 悬浮小窗；没有 = 主 App 侧主动建成功。两种情况用户都没被拉走。
    if (pip == 1) {
        gRKVLReturnPending = NO;
        if (gRKVLFallbackLaunched) {
            RKVLLogForce(@"[back] 兜底拉起后 pip 立住 t=%.2fs mic=%d -> 回宿主", t, mic);
            RKVLReturnToHost(@"pip_ready");
        } else {
            RKVLLogForce(@"[back] pip 已立住 t=%.2fs mic=%d -> 免跳（不做任何事）", t, mic);
        }
        RKVLPostReturnProbe(0);
        return;
    }

    // ⭐ 2.3.60 ② 连续右跳兜底 —— 老板定案：
    //   「open 能建起 pip 就一次都不跳；建不起来就用我们自己连续右跳的办法保底」。
    //   2.3.59 的判据（见过 mic 就锁死）在 pip 建不起来时会永远不兜底 ⇒ 下一轮还得跳，
    //   用户白等。现在改成「pip 仍为 0 且已等 3.0s」就拉起：
    //   3.0s 够主 App 侧走完 setup→prepare→start 三次尝试（0.6s/1.4s 重试）。
    if (!gRKVLFallbackLaunched && pip == 0 && t >= 3.0) {
        int ok = 0;
        BOOL r = RKVLForegroundLaunchApp(&ok);
        gRKVLFallbackLaunched = YES;
        RKVLLogForce(@"[back] pip 未建立（t=%.1fs mic=%d jump=%d）-> 连续右跳兜底 ok=%d(k=%d)",
                     t, mic, gRKVLJumped, r, ok);
        // 不 usleep 阻塞主线程：后面每 250ms 一拍自然能看到 pip
    }

    // ③ 只有「我们把人拉走过」才需要送回 —— 录音一起就给 1.0s 稳定期再回。
    if (gRKVLFallbackLaunched && mic == 1) {
        if (!gRKVLReturnSawMic) {
            gRKVLReturnSawMic = YES;
            gRKVLFirstMicT = t;
            RKVLLog(@"[back] 见到 mic=1（录音已建立）t=%.2fs pip=%d", t, pip);
        } else if (t - gRKVLFirstMicT >= 1.0) {
            // 录音刚起就切走容易把采集掐掉（「录音失败」）⇒ 留 1.0s 稳定期。
            gRKVLReturnPending = NO;
            RKVLLogForce(@"[back] 录音已起 t=%.2fs（mic=1 +1.0s 稳定）pip=%d -> 回宿主", t, pip);
            RKVLReturnToHost(@"mic_started");
            RKVLPostReturnProbe(0);
            return;
        }
    }
    // ④ 拉起过、又一直没 pip/mic ⇒ 15s 兜底送回，不能把人扔在输入法里
    if (gRKVLFallbackLaunched && gRKVLReturnTicks >= 60) {
        gRKVLReturnPending = NO;
        RKVLLogForce(@"[back] timeout t=%.1fs pip=%d mic=%d sawMic=%d -> 兜底回宿主",
                     t, pip, mic, gRKVLReturnSawMic);
        RKVLReturnToHost(@"timeout");
        return;
    }
    // ⑤ 分屏路径迟迟没动静（既没 pip 也没 JUMP）⇒ 收工，交给原生，不再管
    //   2.3.59：观察窗从 6s 放宽到 10s，够看清「mic 起来了但 pip 迟到」这种慢路径。
    if (!gRKVLFallbackLaunched && gRKVLReturnTicks >= 40) {
        gRKVLReturnPending = NO;
        RKVLLogForce(@"[back] 10s 内无 pip/JUMP t=%.1fs -> 停止观察（不跳）", t);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RKVLReturnTick(); });
}

static void RKVLStartReturnWatch(void) {
    // 上一轮还没结束就作废、以本轮为准（连点两次语音不会两个状态机抢同一个 host）
    gRKVLReturnPending = NO;
    gRKVLReturnPending = YES;
    gRKVLReturnTicks = 0;
    gRKVLReturnTries = 0;
    gRKVLReturnSawMic = NO;
    gRKVLFirstMicT = 0;
    RKVLLogForce(@"[back] watch start host=%@ jump=%d fallback=%d",
                 gRKVLHostBundle ?: @"-", gRKVLJumped, gRKVLFallbackLaunched);
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
    int micB = RKVLProbeFlag(@selector(microphoneActive));
    int pipB = RKVLProbeFlag(@selector(pictureInPictureActive));
    RKVLLogForce(@"[entry] launchWBRecorder ctx=%p trial=%d forceWake=%d mask=0x%x mic=%d pip=%d",
            context, RKVLNoJumpTrial, RKVLVoiceWake, RKVLProbeMask(), micB, pipB);
    // ⭐ 每次都问，且必须趁现在问：此刻前台 App 就是宿主。一旦拉起，前台就变成 wxkb 了。
    //   （不能只在缓存为空时问 —— 用户可能已经换 App，旧宿主会让回跳跳错地方）
    NSString *via = nil;
    NSString *hostNow = RKVLFrontmostBundleID(&via);
    if (hostNow.length) gRKVLHostBundle = hostNow;
    RKVLLogForce(@"[back] host=%@ via=%@", gRKVLHostBundle ?: @"(nil)", via);

    // ⭐ 2.3.60：pip 还没建立就立刻请主 App 侧主动建。
    //   半注销后微信输入法自己不会建 pip（它只在录音结束进待机时建一次、且同进程只建一次），
    //   我们注入进主 App 的 RKWetypePipBuild 收到这条请求就自己调 WBVoiceInputPIPManager。
    //   主 App 被 TrollOpen 小窗激活的那一刻读得到（notify state 是持久跨进程的）。
    if (pipB != 1) RKVLPipRequestPost();

    if (pipB == 1 || micB == 1) {
        // 已经有待机/录音 ⇒ 本来就免跳，别去打扰 App（TrollOpen 的分屏小窗也正在用）
        RKVLLog(@"[launch] 已有 pip/mic -> 不介入 mic=%d pip=%d", micB, pipB);
    } else if (gRKVLHostBundle.length) {
        gRKVLJumped = NO;
        gRKVLJumpAt = 0;
        gRKVLFallbackLaunched = NO;
        gRKVLSeenRecorder = NO;   // 新一轮开始：还没任何录音迹象
        // ⛔ 2.3.58：默认**不拉起**。抢跑会绕过 TrollOpen 的分屏路由，把小窗挤成全屏跳转。
        //   只有开关「点语音前抢先唤醒主 App」被手动打开时才强抢先（调试后门，正常别开）。
        if (RKVLVoiceWake) {
            uint32_t before = RKVLProbeMask();
            int sigRc = RKVLSignalAllCont();
            int lok = 0;
            BOOL launched = RKVLForegroundLaunchApp(&lok);
            gRKVLFallbackLaunched = launched;
            RKVLLogForce(@"[launch] 强制抢先拉起 ok=%d(k=%d) sigRc=%d mask_before=0x%x mic=%d pip=%d appAlive=%d",
                    launched, lok, sigRc, before, micB, pipB,
                    RKVLProbeFlag(@selector(appAlive)));
            if (launched) usleep(600 * 1000);   // 给 App 600ms 把待机拉起来
        } else {
            RKVLLog(@"[launch] 不拉起 -> 交给原生 launch（分屏插件可接管）");
        }
        // 不拉起也要起 watch：靠它观察 pip 有没有立住、以及 1.8s 后要不要兜底
        RKVLStartReturnWatch();
        for (double d = 2.0; d <= 8.1; d += 2.0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                RKVLLog(@"[wake] +%.1fs mask=0x%x mic=%d pip=%d",
                        d, RKVLProbeMask(),
                        RKVLProbeFlag(@selector(microphoneActive)),
                        RKVLProbeFlag(@selector(pictureInPictureActive)));
            });
        }
    } else {
        RKVLLogForce(@"[launch] 宿主未知 -> 交给微信输入法原生跳转");
    }
    %orig;
}

// reason 就是二进制里那套枚举：app_background_without_audio / app_killed /
// pip_start_timeout_url_fallback / launch_app_from_background …
- (void)updateLaunchingRecorderApp:(BOOL)launching reason:(id)reason {
    RKVLLogForce(@"[reason] launching=%d reason=%@", launching, reason);
    if ([reason isKindOfClass:[NSString class]] &&
        [(NSString *)reason containsString:@"session_stopped"]) {
        gRKVLLastSessionStop = [NSDate date].timeIntervalSince1970;
    }
    %orig;
}

- (void)launchAppFromBackgroundWithAllowBluetooth:(BOOL)allow pipTimeoutFallback:(BOOL)fallback {
    // 2.3.58：兜底判据的起点 —— 「原生这一跳到底有没有人接」从这里开始计时
    gRKVLJumped = YES;
    gRKVLJumpAt = [NSDate date].timeIntervalSince1970;
    RKVLLog(@"[JUMP] launchAppFromBackground allowBT=%d pipFallback=%d", allow, fallback);
    %orig;
}

// 2.3.45：强制免跳后最想看到的一行 —— 有没有进入「录音待机」（把 mic 位留住）。
- (void)_transitionNativeViewStateToRecorderStandby {
    RKVLLogForce(@"[standby] -> RecorderStandby trial=%d mask=0x%x", RKVLNoJumpTrial, RKVLProbeMask());
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

// == 2.3.59：抓「微信输入法自己是怎么拉起自己的」==
//
// 为什么抓：我们的兜底拉起用 `openApplicationWithBundleID:`（appex → lsd 的 XPC），
//   TrollOpen 把它判成全屏；而 WeType 自己的 pip 超时兜底走的是 **URL scheme**
//   （主 App Info.plist 里登记了 `wetype://`）。TrollOpenJB 的判定日志格式串是
//   `url=… origin=… source=… target=… shouldSplit=… forceNow=…` ⇒ 它认的是 URL。
//   ⇒ 只要抄到 WeType 那条 URL，兜底路径也能落进分屏小窗，而不是全屏再跳回来。
%group RKLaunchProbe

%hook WBVoiceInputService
- (void)_fallbackToURLSchemeForPIPStartCommandTimeoutWithSessionId:(id)sid {
    RKVLLogForce(@"[urlfb] pip 超时 -> 走 URL 兜底 sessionId=%@", sid);
    %orig;
}
%end

%hook LSApplicationWorkspace
- (BOOL)openURL:(id)url withOptions:(id)options error:(id *)err {
    RKVLLogForce(@"[urlfb] openURL %@ options=%@", url, options);
    BOOL r = %orig;
    RKVLLogForce(@"[urlfb] openURL -> %d", r);
    return r;
}
- (BOOL)openApplicationWithBundleID:(id)bid {
    RKVLLogForce(@"[urlfb] openApplicationWithBundleID %@", bid);
    return %orig;
}
%end

%end

%ctor {
    @autoreleasepool {
        RKVLLogRefresh();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RKVLPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        RKVLLogForce(@"==== RKVoiceJumpProbe 2.3.60 loaded path=%@ ====", RKVLLogPath());
        // 2.3.55：落盘的宿主（半注销后第一次点语音能靠它回跳）
        {
            NSString *mem = RKVLHostLoad();
            RKVLLogForce(@"[cfg] hostMemory=%@", mem ?: @"(none)");
        }
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

        // 2.3.59：抓 WeType 自己的 URL 拉起路径（为「兜底也走小窗」取证）
        BOOL l1 = objc_getClass("LSApplicationWorkspace") != NULL;
        RKVLLogForce(@"[cfg] launchprobe LSWS=%d svcFallback=%d", l1, hasFallback);
        if (l1 && hasFallback) {
            %init(RKLaunchProbe);
            RKVLLogForce(@"[cfg] launchprobe installed");
        }
    }
}
