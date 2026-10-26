// RKVoiceJumpProbe.xm — 语音按钮「连续右跳」免跳兜底（2.3.66）
//
// == 2.3.66（本版）：小窗路线全部删除，只保留连续右跳兜底 ==
//
// 老板定案（2026-10-27）：open 的分屏小窗路线调不起 pip，不用了。
//   ⇒ 删掉所有「小窗 + 主 App 主动建 pip」的代码：
//     · 键盘侧 notify 建 pip 请求（com.huhansibuxin.rk.pipreq）
//     · 键盘侧 notify 建 pip 回执（com.huhansibuxin.rk.pipok）
//     · 兜底总闸 gRKVLFallbackOn（测试期用的关闸）—— 兜底就是唯一的路径
//     · 「见过录音就锁死」gRKVLSeenRecorder（那是防小窗双开的，现在不适用）
//     · rescue_no_split 分支（兜底关闭期的安全网，现在不适用）
//     · RKLaunchProbe 组（抓 wetype:// URL 给小窗取证的，已无用）
//     · RKWetypeHost 整套（注入微信输入法主 App，Makefile 里已移除）
//   ⇒ 唯一路径：点语音 → 主 App 还没待机（pip=0/mic=0）就在键盘进程内**主动有头拉起**
//     （= 一次右跳）→ 等主 App 进待机 → **自动回跳宿主 App** → 此后 pip 立着，下一轮免跳。
//
// == ⭐ 这一版的「精准命中 + 不耗 CPU」怎么做的 ==
//   1) **免跳路径零开销**：入口只要 `pip==1 || mic==1` 就立刻 return，不拉起、不起定时器、
//     不轮询。真正免跳时插件一行活都不干。
//   2) **只在需要时才动**：拉起失败 / 宿主未知时，一行拉起都不做，直接交给原生。
//   3) **单一定时器链、4 拍/秒、最长 6 秒**：旧的 0.25s × 40 拍（10s）砍到 0.4s × 15 拍，
//      每拍只读两个 BOOL（objc_msgSend ×2，亚微秒级），且一有结论立刻停机。
//      不再有 `[wake] +2/+4/+6/+8s` 那四个纯日志定时器。
//   4) **事件驱动优先**：pip / mic 的 hook 里只要检测到「待机刚立住」，立刻推一次状态机，
//      不必等下一拍 —— 回跳能早 0.4s 完成。
//   5) **判据精准**：
//      · pip==1                     → 立即回（待机建立那一刻面板还在，原生就是这么快）
//      · mic==1 且稳定 1.0s         → 回（切太早会把采集掐掉 = 用户看到的「录制失败」）
//      · 2.0s 仍无 mic/pip 且原生没跳 → **再拉一次**（连续右跳，最多 2 次）
//      · 6.0s 还没起来              → 仍然回跳，绝不把人扔在输入法里
//
// == 已经被日志坐实的部分（历史，别再重复验证）==
//   · 2.3.42/2.3.44：半注销后每次点语音 → mic 0 → [entry] → [JUMP] pipFallback=0
//     → +0.8s mic 1（主 App 到前台才录上）→ session_stopped。
//   · 2.3.45：真凶是 3.04 秒的 PIPStart 超时 → _fallbackToURLSchemeForPIPStartCommandTimeout
//     → 跳 URL。pip=1 时 requireJump 本来就是 0，所以「强行 requireJump=NO」这条路是空的。
//   · 2.3.51/2.3.56：有头拉起（openApplicationWithBundleID:）→ mic 起 → 回跳宿主，
//     之后 pip 在后台长出来，下一轮 requireJump=0 ⇒ 免跳成立。**这是唯一跑通过的形态。**
//   · 2.3.63/2.3.64（小窗路线，已废）：小窗里 applicationState=Inactive，AVKit 不给 pip
//     启动资格 —— start 被挂起 3 秒超时（连 willStart 都没有）；activateVisiblePiPMode 之后
//     直接 notifyDelegateDidFailToStart。App 内 hook 无解，故整条路线删除。
//
// == 返回类型核对（capstone 看 ret 出口）==
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
// 日志受「记录调试日志」（AIRecorderLog）与总开关（Enabled）双控，默认关；
// 但 [entry]/[back]/[pip] 这类关键节点走 RKVLLogForce，诊断期必写（见下）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <time.h>
#import "RKPreferences.h"

#pragma mark - 日志

static BOOL RKVLLogEnabled = NO;
// 语音免跳转实验开关（2.3.45）。开 = requireJumpToMainAppForRecording 强制返回 NO。
static BOOL RKVLNoJumpTrial = NO;
// 2.3.66：连续右跳兜底总闸。开 = 点语音时主动把主 App 拉起来建待机（默认开）。
//   关掉就完全等于原生行为（每次点语音都会跳，且跳过去不回来）。
static BOOL RKVLVoiceWake = YES;

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
    //   于是 RKVLLogEnabled=0，整条诊断链静默。
    //   ⚠️ 2.3.66：调用点一律在「状态发生变化」的钩子里，不在热路径每拍写，开销可控。
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

// 关键节点必写日志（入口 / 拉起 / 回跳 / pip 掉落）。每次点语音只有几行。
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

#pragma mark - 状态读取（WeType 自己的 WBVoiceStateProbe）

// 从 WBVoiceStateProbe 的实例里取状态。用 unsafe_unretained 缓存实例（长生命单例），
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

#pragma mark - 有头拉起主 App（= 一次右跳）

// ⛔ 2.3.50 结果（无头拉起全灭，别再试）：
//   SBSLaunchApplicationWithIdentifier(suspended=1)              rc=9
//   SBSLaunchApplicationWithIdentifierAndLaunchOptions(...,YES)  rc=9
//   LSApplicationWorkspace 没有 openApplicationWithBundleID:withOptions:（iOS16 已移除）
//   rc=9 = 缺 com.apple.springboard.launchapplications entitlement，重签会破坏签名。
// ✅ 2.3.51 改「有头拉起」：LSApplicationWorkspace 单参 openApplicationWithBundleID:
//   这个 WeType 自己在用，一定存在、一定有权限。代价是切一次前台（= 右跳），
//   跳完 App 会进录音待机（pip=1），而 pip=1 期间 requireJump 恒 0 ⇒ 长期免跳。
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

// 用 LSApplicationWorkspace 单参接口把指定 App 提到前台（回跳用）。
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

#pragma mark - 宿主 App（回跳目标）

// 宿主是谁？WeType 自己完全不记（wxkb_plugin 里零 host bundle 符号），
// 只能在**跳转之前**问系统：此刻前台那个 App 就是宿主。
//
// ⛔ 2.3.52 踩过的坑（IPS 已证实，别再试）：`SBFrontmostApplicationDisplayIdentifier`
//   虽然 dlsym 能取到非空地址，但**调用返回值是垃圾**（0x10000003），
//   我们把它当 CFString 发 copy ⇒ EXC_BAD_ACCESS，键盘扩展每点一次语音崩一次。
//   ⇒ 签名没验证过的私有 C 函数绝对不能直接调。
//
// ✅ 可行路径（按优先级）：
//   ① WeType 自己的 WBInputViewContext.hostBundleID（最可靠，静态实证有这两个方法）
//   ② WeType 报给我们并缓存下来的值
//   ③ 上次落盘的宿主（半注销后进程是新起的，内存空 ⇒ 靠它）
//   ④ LSApplicationWorkspace -frontmostApplication（iOS16 上多半取不到，兜底而已）

static NSString *gRKVLHostBundle = nil;   // 本轮的宿主（回跳目标）
static NSString *gRKVLHostFromWeType = nil;
static __unsafe_unretained id gRKVLInputCtx = nil;

static void RKVLNoteHostBundle(id v, const char *via);   // 前置声明（定义在 %hook 区）

// == 2.3.55：宿主 bundle id 落盘 ==
// 起因：半注销后**第一次**点语音不回来 —— 那一刻扩展进程是新的（或刚被系统回收过），
// ctx / 内存缓存都还空，宿主取不到 ⇒ 回跳被跳过。
// 落盘在扩展自己的沙盒 Library/Preferences 下（tmp 会被系统清、重装 deb 也会清）。
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

#pragma mark - 连续右跳状态机

// == 2.3.66 状态机（单一定时器链，0.4s/拍，最长 6s）==
//
// 与原生的差别只在「顺序」：
//   原生：点语音 → pip 超时 3s → 跳主 App → **停在那里不回来**（用户被带走）
//   我们：点语音 → 立刻跳主 App → 等它进待机/开录音 → **自动送回宿主** → 下一轮 pip 立着 ⇒ 免跳
//
// 参数为什么是这几个数（都有日志支撑，别随手改）：
//   · 0.4s/拍：pip 从待机建立到 mask 上报的最短间隔约 0.4s，再密没有收益。
//   · mic 稳定 1.0s：2.3.55 实测「录音刚起就切走」会把采集掐掉 = 用户看到的「录制失败」。
//   · 2.0s 再拉一次：主 App 冷启到能建待机约 0.8~1.5s，2.0s 还没 mic/pip 说明这次没拉起来。
//   · 6.0s 保底回跳：绝不能让用户被扔在输入法里。
static BOOL   gRKVLReturnPending = NO;   // 本轮状态机是否在跑（唯一的停机开关）
static int    gRKVLReturnTicks   = 0;    // 已推进的拍数（只作日志）
static int    gRKVLReturnTries   = 0;    // 已经拉起过几次（含首拉，上限 2）
static BOOL   gRKVLReturnSawMic  = NO;
static double gRKVLFirstMicT     = 0;    // 首次见到 mic=1 的那一刻（单位秒，相对本轮起点）
static BOOL   gRKVLFallbackLaunched = NO; // 我们主动拉起过 ⇒ 必须回跳
static BOOL   gRKVLJumped        = NO;    // 原生是否已发生 JUMP
static BOOL   gRKVLReturned      = NO;    // 本轮已回跳（防重复）
static NSTimeInterval gRKVLStartAt = 0;  // 本轮起点（CFAbsoluteTime，亚微秒开销）
static NSTimeInterval gRKVLLastSessionStop = 0;  // 上次 reason=session_stopped 时刻（只作日志）

// 单一定时器链的「代际」。nudge 要插队时把代际 +1，已排队的那一拍发现代际不符就自己退出，
// 所以任何时刻**只有一条链**在跑（旧版没这层，nudge 会让链翻倍、tick 越跑越多）。
static uint32_t gRKVLGen = 0;
static BOOL     gRKVLInTick = NO;        // 防 hook 重入（tick 里读 mic/pip 会再次进 hook）

static double RKVLNow(void) { return CFAbsoluteTimeGetCurrent(); }

// 回跳后的两点确认：pip 有没有在后台长出来（决定下一轮能不能免跳）。
// 只有两个定时器，且仅在真的回跳过之后才存在。
static void RKVLPostReturnProbe(int step) {
    static const double delays[] = {1.0, 3.0};
    if (step < 0 || step >= 2) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delays[step] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        RKVLLogForce(@"[back] after +%.1fs mask=0x%x mic=%d pip=%d（下一轮能否免跳看这里）",
                     delays[step], RKVLProbeMask(),
                     RKVLProbeFlag(@selector(microphoneActive)),
                     RKVLProbeFlag(@selector(pictureInPictureActive)));
        RKVLPostReturnProbe(step + 1);
    });
}

static void RKVLReturnTick(void);

// 排下一拍。捕获代际，被 nudge 作废的那一拍什么都不做。
static void RKVLScheduleTick(void) {
    uint32_t g = ++gRKVLGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g != gRKVLGen) return;      // 已被更新的一拍取代
        RKVLReturnTick();
    });
}

static void RKVLReturnToHost(NSString *why) {
    if (gRKVLReturned) return;
    gRKVLReturned = YES;
    gRKVLReturnPending = NO;
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
    if (!r) {
        // 半注销刚醒的第一拍偶尔会被系统拒一次（前台切换还没就绪），重试一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            int ok2 = 0;
            BOOL r2 = RKVLActivateBundle(bid, &ok2);
            RKVLLogForce(@"[back] retry -> ok=%d(%d)", r2 ? 1 : 0, ok2);
        });
    } else {
        RKVLHostSave(bid);   // 回跳成功 ⇒ 这个宿主是可信的，存下来给下次进程启动用
    }
    RKVLPostReturnProbe(0);
}

// 拉起一次（连续右跳的每一跳）。调用方负责计数与判据。
static BOOL RKVLJumpOnce(const char *why) {
    int ok = 0;
    BOOL r = RKVLForegroundLaunchApp(&ok);
    gRKVLReturnTries++;
    if (r) gRKVLFallbackLaunched = YES;
    RKVLLogForce(@"[jump] #%d(%s) -> %@ ok=%d 待机前状态 mask=0x%x mic=%d pip=%d",
                 gRKVLReturnTries, why, r ? @"YES" : @"NO", ok, RKVLProbeMask(),
                 RKVLProbeFlag(@selector(microphoneActive)),
                 RKVLProbeFlag(@selector(pictureInPictureActive)));
    return r;
}

// 一拍的状态判断。返回 YES = 还需要下一拍，NO = 本轮结束。
static BOOL RKVLReturnStep(void) {
    // t 用真实时间，不用「拍数 × 0.4」—— nudge 会插队，拍数不等于时长。
    double t = RKVLNow() - gRKVLStartAt;
    int mic = RKVLProbeFlag(@selector(microphoneActive));
    int pip = RKVLProbeFlag(@selector(pictureInPictureActive));

    // ① pip=1 = 主 App 已进录音待机，此刻语音面板还挂着 ⇒ 立刻回（原生就是这个节奏）。
    //   下一轮点语音 pip 仍然立着 ⇒ requireJump=0 ⇒ 一次都不跳。
    if (pip == 1) {
        RKVLLogForce(@"[back] pip 已立住 t=%.1fs mic=%d -> %@", t, mic,
                     gRKVLFallbackLaunched ? @"回宿主" : @"免跳(未拉起过)");
        if (gRKVLFallbackLaunched) RKVLReturnToHost(@"pip_ready");
        else { gRKVLReturnPending = NO; RKVLPostReturnProbe(0); }
        return NO;
    }

    // ② 录音已起、稳定 1.0s 再回。刚起就切会把音频采集掐断（=「录制失败」）。
    if (gRKVLFallbackLaunched && mic == 1) {
        if (!gRKVLReturnSawMic) {
            gRKVLReturnSawMic = YES;
            gRKVLFirstMicT = t;
            RKVLLogForce(@"[back] 录音已起 t=%.1fs pip=0 -> 等 1.0s 稳定", t);
        } else if (t - gRKVLFirstMicT >= 1.0) {
            RKVLLogForce(@"[back] 录音稳定 t=%.1fs（mic=1 +1.0s）-> 回宿主", t);
            RKVLReturnToHost(@"mic_started");
            return NO;
        }
    }

    // ③ 连续右跳：2.0s 还没 mic/pip，且原生也没跳 ⇒ 这一跳没落地，再拉一次（最多 2 次）。
    //   判 `gRKVLJumped` 是为了「精准命中」：原生已经跳了就别叠第二次。
    if (gRKVLReturnTries < 2 && !gRKVLJumped && mic == 0 && pip == 0 && t >= 2.0) {
        RKVLJumpOnce("retry");
    }

    // ④ 6.0s 保底：拉起过但始终没起来 ⇒ 仍然回跳，绝不把人扔在输入法里。
    if (gRKVLFallbackLaunched && t >= 6.0) {
        RKVLLogForce(@"[back] timeout t=%.1fs mic=%d pip=%d sawMic=%d -> 兜底回宿主",
                     t, mic, pip, gRKVLReturnSawMic);
        RKVLReturnToHost(@"timeout");
        return NO;
    }

    // ⑤ 我们没拉起过（拉起失败），但原生跳了 ⇒ 只回跳不重开，别把人困住。
    if (!gRKVLFallbackLaunched && gRKVLJumped && t >= 4.0) {
        RKVLLogForce(@"[back] 原生已跳 + 4s 无 pip（我们没拉起）-> 只回跳");
        gRKVLReturned = YES;
        gRKVLReturnPending = NO;
        NSString *bid = gRKVLHostBundle;
        if (bid.length) {
            int ok = 0;
            BOOL r = RKVLActivateBundle(bid, &ok);
            RKVLLogForce(@"[back] (rescue) -> %@ ok=%d(%d)", bid, r ? @"YES" : @"NO", ok);
        }
        return NO;
    }

    // ⑥ 收工：没拉起过也没原生跳 ⇒ 这一拍压根没走跳转路径，停掉观察。
    if (!gRKVLFallbackLaunched && !gRKVLJumped && t >= 2.0) {
        gRKVLReturnPending = NO;
        RKVLLogForce(@"[back] t=%.1fs 无 JUMP 无拉起 -> 停止观察（交给原生）", t);
        return NO;
    }
    return YES;
}

static void RKVLReturnTick(void) {
    if (!gRKVLReturnPending) return;
    if (gRKVLInTick) return;            // nudge 从 hook 里进来时会重入，让外层那一拍处理
    gRKVLInTick = YES;
    gRKVLReturnTicks++;
    BOOL cont = RKVLReturnStep();
    gRKVLInTick = NO;
    if (cont && gRKVLReturnPending) RKVLScheduleTick();
}

// pip / mic 的 hook 里检测到「待机刚立住」就立刻推一拍（回跳早 0.4s）。
// 先把已排队的那一拍作废，保证链不会翻倍。
static void RKVLNudge(void) {
    if (!gRKVLReturnPending || gRKVLReturned || gRKVLInTick) return;
    gRKVLGen++;
    RKVLReturnTick();
}

static void RKVLBeginRound(void) {
    gRKVLReturnPending = NO;          // 上一轮还在跑就以本轮为准（连点两次语音不会两个状态机抢同一个 host）
    gRKVLReturnPending = YES;
    gRKVLReturnTicks = 0;
    gRKVLReturnTries = 0;
    gRKVLReturnSawMic = NO;
    gRKVLFirstMicT = 0;
    gRKVLFallbackLaunched = NO;
    gRKVLJumped = NO;
    gRKVLReturned = NO;
    gRKVLStartAt = RKVLNow();
}

#pragma mark - 探针

%hook WBVoiceStateProbe

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
    if (v != last) {
        last = v;
        RKVLLogForce(@"[probe] mic -> %d", v);
        if (v) RKVLNudge();
    }
    return v;
}

- (BOOL)pictureInPictureActive {
    BOOL v = %orig;
    static BOOL last; static dispatch_once_t once;
    dispatch_once(&once, ^{ last = !v; });
    if (v != last) {
        if (last && !v) {
            // pip 掉的那一刻是「能不能长期免跳」的唯一分水岭，记全上下文
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            RKVLLogForce(@"[pip] 1→0 距上次session_stopped=%.1fs mic=%d appAlive=%d",
                    gRKVLLastSessionStop > 0 ? now - gRKVLLastSessionStop : -1.0,
                    RKVLProbeFlag(@selector(microphoneActive)),
                    RKVLProbeFlag(@selector(appAlive)));
        } else {
            RKVLLogForce(@"[probe] pip -> %d", v);
        }
        // ⚠️ 先把 last 更新掉再 nudge：nudge 里的状态机会再读一次 pip，
        //   如果这时候 last 还是旧值就会重入本 hook ⇒ 递归。
        last = v;
        if (v) RKVLNudge();
    }
    return v;
}

// 2.3.45：原始状态位图。mic/pip 只是它的两个派生视图。
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
- (BOOL)requireJumpToMainAppForRecording {
    BOOL jump = %orig;
    if (RKVLNoJumpTrial) {
        RKVLLog(@"[trial] requireJump %d -> 0 (appAlive=%d mic=%d pip=%d mask=0x%x)",
                jump, RKVLProbeFlag(@selector(appAlive)), RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(pictureInPictureActive)), RKVLProbeMask());
        return NO;
    }
    RKVLLog(@"[gate] requireJump=%d (appAlive=%d mic=%d pip=%d)", jump,
            RKVLProbeFlag(@selector(appAlive)), RKVLProbeFlag(@selector(microphoneActive)),
            RKVLProbeFlag(@selector(pictureInPictureActive)));
    return jump;
}

// 真正的入口（2.3.42 里 hook 的 launchWcVoiceWithContext: 全程零命中）。
//
// ⭐ 2.3.66 唯一路径：
//   pip/mic 已立 ⇒ 立刻返回，一行活都不干（真免跳，零开销）
//   否则         ⇒ 主动有头拉起主 App（一次右跳），起状态机；等它进待机就自动回跳
- (void)launchWBRecorderWithContext:(id)context finishedBlock:(id)block {
    int micB = RKVLProbeFlag(@selector(microphoneActive));
    int pipB = RKVLProbeFlag(@selector(pictureInPictureActive));
    RKVLLogForce(@"[entry] launchWBRecorder ctx=%p trial=%d 兜底=%d mask=0x%x mic=%d pip=%d",
            context, RKVLNoJumpTrial, RKVLVoiceWake, RKVLProbeMask(), micB, pipB);

    // ① 已经待机/录音 ⇒ 本来就免跳，别去打扰 App（这才是「一次都不跳」的常态）。
    //
    // ⚠️ 但 pip=1 有个坑（2.3.62 实测坐实）：半注销后键盘进程刚起来时，probe 可能报的是
    //   **上一轮残留的 pip=1**（那一刻主 App 才刚载入、realPip=0，键盘侧 mask 却已经是 0x3）。
    //   这种假值会让 WeType 自己误判「免跳」⇒ 不跳转、也不录音 ⇒ 用户看到的就是
    //   「半注销后头几次点语音全是录制失败」。
    //   判据：pip=1 但 appAlive=0 ⇒ pip 不可能真实存在（pip 由主 App 提供）⇒ 按未待机处理。
    //   这时我们照常右跳、把主 App 真正拉起来，假值就被真实状态覆盖了。
    int aliveB = RKVLProbeFlag(@selector(appAlive));
    BOOL stalePip = (pipB == 1 && aliveB == 0);
    if (stalePip) {
        RKVLLogForce(@"[entry] ⚠️ pip=1 但 appAlive=0 ⇒ 视为残留假值，按未待机处理（mask=0x%x）",
                     RKVLProbeMask());
    }
    if ((pipB == 1 && !stalePip) || micB == 1) {
        RKVLLog(@"[entry] 已有 pip/mic -> 不介入 mic=%d pip=%d", micB, pipB);
        %orig;
        return;
    }

    // ② 宿主：必须趁现在问（此刻前台 App 就是宿主；一旦拉起，前台就变成 wxkb 了）。
    NSString *via = nil;
    NSString *hostNow = RKVLFrontmostBundleID(&via);
    if (hostNow.length) gRKVLHostBundle = hostNow;
    RKVLLogForce(@"[back] host=%@ via=%@", gRKVLHostBundle ?: @"(nil)", via);

    // ③ 宿主未知 ⇒ 不拉起（拉得起来、回不去 = 把人扔在输入法里），老实交给原生。
    if (!gRKVLHostBundle.length || !RKVLVoiceWake) {
        RKVLLogForce(@"[entry] 不拉起（host=%@ 兜底开关=%d）-> 交给原生",
                     gRKVLHostBundle ?: @"(nil)", (int)RKVLVoiceWake);
        %orig;
        return;
    }

    // ④ 主动右跳 + 起状态机。
    //   拉起失败也要起状态机：原生随后一定会跳（WeType 自己的 3s PIPStart 超时兜底），
    //   那时状态机走 ⑤ 只做回跳（rescue），照样不会把人困在输入法里。
    RKVLBeginRound();
    RKVLJumpOnce("entry");
    RKVLReturnTick();
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
    gRKVLJumped = YES;
    RKVLLogForce(@"[JUMP] 原生 launchAppFromBackground allowBT=%d pipFallback=%d", allow, fallback);
    %orig;
}

- (void)_transitionNativeViewStateToRecorderStandby {
    RKVLLogForce(@"[standby] -> RecorderStandby trial=%d mask=0x%x", RKVLNoJumpTrial, RKVLProbeMask());
    %orig;
}

%end

#pragma mark - 向 WeType 要宿主 bundle id

// ⭐ 为什么用这条：2.3.53 实测 `[cfg] frontmost SBFrontmost=1(不用) LSfront=0`
//   —— iOS 16 的 LSApplicationWorkspace **没有** -frontmostApplication，
//   SBFrontmostApplicationDisplayIdentifier 又返回垃圾（会崩）。系统侧问不出来。
//
// ✅ 但 WeType 自己一定知道宿主：静态实证（wxkb_plugin 方法表）
//   `WBInputViewController -inputViewContext` → `WBInputViewContext -hostBundleID`
//   `WBRootViewManager    -hostBundleID` / `-refreshHostBundleID` / `-hostBundleIDDidChange`
//   `WBVoicePendingClose  -hostBundleId` / `-setHostBundleId:`
//   `WBVoiceReportContext -hostBundleId` / `-setHostBundleId:`
//   做法：getter 和 setter 都挂，谁先给我们算谁。全部只是「读一份返回值 / 抄一份入参」，
//   不改任何行为。

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
        RKVLLogForce(@"==== RKVoiceJumpProbe 2.3.66 loaded path=%@ ====", RKVLLogPath());
        RKVLLogForce(@"[cfg] 兜底=%d（唯一路径：连续右跳）", (int)RKVLVoiceWake);
        // 2.3.55：落盘的宿主（半注销后第一次点语音能靠它回跳）
        {
            NSString *mem = RKVLHostLoad();
            RKVLLogForce(@"[cfg] hostMemory=%@", mem ?: @"(none)");
        }
        // 一次性探测：拉起/回跳要用的符号在不在。
        {
            Class wc = objc_getClass("LSApplicationWorkspace");
            id w = wc ? ((id (*)(id, SEL))objc_msgSend)((id)wc, sel_registerName("defaultWorkspace")) : nil;
            BOOL s3 = w && [w respondsToSelector:sel_registerName("openApplicationWithBundleID:")];
            RKVLLogForce(@"[cfg] launchable LSWS_single=%d", s3);
        }
        NSDictionary *p = RKReadEffectivePreferences();
        RKVLLogForce(@"[cfg] logEnabled=%d trial=%d wake=%d Enabled=%@ AIRecorderLog=%@ VoiceNoJumpTrial=%@ VoiceWakeApp=%@ rev=%@ bundle=%@",
                RKVLLogEnabled, RKVLNoJumpTrial, RKVLVoiceWake, p[@"Enabled"], p[@"AIRecorderLog"],
                p[@"VoiceNoJumpTrial"], p[@"VoiceWakeApp"], p[@"RKSettingsRevision"],
                [[NSBundle mainBundle] bundleIdentifier]);

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
