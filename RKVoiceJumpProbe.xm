// RKVoiceJumpProbe.xm — 语音按钮「连续右跳」免跳兜底（2.5.0 纯净版）
//
// == 2.5.0：移除全部调试日志代码 ==
//   删除 RKVLLog* / RKVLGateTrace / RKVLDbg* / RKVLPostReturnProbe 所有写盘、门控、落盘与纯诊断代码。
//   「记录调试日志」(AIRecorderLog) 设置开关与 RKDisplayTransport 的传输位**保留不动**
//   （设置页 specifier + words[5] 位6/7 都留着），方便以后要调试时从 tag v2.4.6-with-logs
//   把日志代码加回来，无需改动设置页与传输层。
//   本文件只剩下「功能」：连续右跳兜底、回跳移出主线程、宿主识别与落盘、坏待机判据。
//
// == 这一版的「精准命中 + 不耗 CPU」怎么做的 ==
//   1) 免跳路径零开销：入口只要 `pip==1 || mic==1` 就立刻 return，不拉起、不起定时器、
//      不轮询。真正免跳时插件一行活都不干。
//   2) 只在需要时才动：拉起失败 / 宿主未知时，一行拉起都不做，直接交给原生。
//   3) 单一定时器链、4 拍/秒（0.05s/拍，最长 6 秒）：旧的 0.25s × 40 拍（10s）砍到 0.4s × 15 拍，
//      每拍只读两个 BOOL（objc_msgSend ×2，亚微秒级），且一有结论立刻停机。
//   4) 事件驱动优先：pip / mic 的 hook 里只要检测到「待机刚立住」，立刻推一次状态机，
//      不必等下一拍 —— 回跳能早 0.4s 完成。
//   5) 判据精准：
//      · pip==1                     → 立即回（待机建立那一刻面板还在，原生就是这么快）
//      · mic==1 且稳定 0.45s        → 回（切太早会把采集掐掉 = 用户看到的「录制失败」）
//      · 2.0s 仍无 mic/pip 且原生没跳 → 再拉一次（连续右跳，最多 2 次）
//      · 6.0s 还没起来              → 仍然回跳，绝不把人扔在输入法里
//
// == 参数选择（都有实测依据，别随手改）==
//   · 0.05s/拍：pip 从待机建立到 mask 上报的最短间隔约 0.4s，再密没有收益。
//   · mic 稳定 0.45s：实测「录音刚起就切走」会把采集掐掉 = 用户看到的「录制失败」。
//   · 2.0s 再拉一次：主 App 冷启到能建待机约 0.8~1.5s，2.0s 还没 mic/pip 说明这次没拉起来。
//   · 6.0s 保底回跳：绝不能让用户被扔在输入法里。
//
// == 回跳的同步 XPC 移出主线程 ==
//   激活请求（openApplicationWithBundleID:）是同步 XPC，会阻塞调用线程直到 SpringBoard 回话。
//   实测 pip 路径阻塞约 390ms、mic 路径约 44ms，差的 350ms 是 WeType 前台切换动画排队。
//   它压在键盘主线程上时，键盘自己的重建也被一起挡掉。⇒ 一律走串行后台队列：
//   前台切换的时间系统照收，但键盘能立刻开始重建（不卡主线程）。
//
// == 返回类型核对（capstone 看 ret 出口）==
//   microphoneActive                 : and w0,w0,#1                → BOOL
//   pictureInPictureActive           : ubfx w0,w0,#1,#1            → BOOL
//   currentMask                      : ldar w0,[x8]                → uint32_t（32 位！）
//   launchWBRecorderWithContext:finishedBlock: 结尾 add sp/ret，无 w0 写入 → void

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <unistd.h>
#import <string.h>
#import <time.h>
#import "RKPreferences.h"

#pragma mark - 设置刷新（免跳总闸）

// 2.3.66：连续右跳兜底总闸。开 = 点语音时主动把主 App 拉起来建待机（默认开）。
//   关掉就完全等于原生行为（每次点语音都会跳，且跳过去不回来）。
static BOOL RKVLVoiceWake = YES;

// 免跳总闸的值来源：设置页的 VoiceWakeApp（受 Enabled 总开关门控）。
// 键盘扩展读不到 plist 时回落固化表（RKReadEffectivePreferences 已处理）。
static void RKVLRefreshSettings(void) {
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    BOOL master = (!enabled || [enabled boolValue]);
    RKVLVoiceWake = master && [prefs[@"VoiceWakeApp"] boolValue];
}

// 语音轮次入口的懒刷新（1 秒节流，一次点语音最多一次 prefs 读）：让「设置页改了 VoiceWakeApp」
// 能尽快生效，不依赖 darwin 通知在键盘挂起时是否丢。
static void RKVLRefreshIfStale(void) {
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 1.0) return;
    last = now;
    RKVLRefreshSettings();
}

static void RKVLPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ RKVLRefreshSettings(); });
}

#pragma mark - 状态读取（WeType 自己的 WBVoiceStateProbe）

// 从 WBVoiceStateProbe 的实例里取状态。用 __weak 缓存实例：不额外 retain（避免循环），
// 且实例被微信释放时自动置 nil，杜绝 use-after-free 野指针。
// ⚠️ 原来用 __unsafe_unretained：ARC 把弱指针赋给 strong 局部时会 objc_retain 已释放对象
//    ⇒ 偶发 EXC_BAD_ACCESS（见 wxkb_plugin 崩溃 IPS，崩溃帧 objc_msgSend + retain）。
static __weak id gRKVLProbe = nil;

static int RKVLProbeFlag(SEL sel) {
    id probe = gRKVLProbe;
    if (!probe) {
        // 类查一次就缓存（旧写法每拍都 objc_getClass，虽然快但没意义）
        static Class probeCls;
        if (!probeCls) probeCls = objc_getClass("WBVoiceStateProbe");
        Class c = probeCls;
        if (c && [c respondsToSelector:@selector(sharedInstance)])
            probe = [c performSelector:@selector(sharedInstance)];
    }
    if (!probe || ![probe respondsToSelector:sel]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(probe, sel) ? 1 : 0;
}

#pragma mark - 有头拉起主 App（= 一次右跳）

// ⛔ 无头拉起全灭（别再试）：SBSLaunchApplicationWithIdentifier 缺 entitlement，重签会破坏签名。
// ✅ 有头拉起：LSApplicationWorkspace 单参 openApplicationWithBundleID:
//   这个 WeType 自己在用，一定存在、一定有权限。代价是切一次前台（= 右跳），
//   跳完 App 会进录音待机（pip=1），而 pip=1 期间 requireJump 恒 0 ⇒ 长期免跳。
static BOOL RKVLForegroundLaunchApp(int *outOK) {
    if (outOK) *outOK = 0;
    Class wsCls = objc_getClass("LSApplicationWorkspace");
    if (!wsCls) return NO;
    id ws = ((id (*)(id, SEL))objc_msgSend)((id)wsCls, sel_registerName("defaultWorkspace"));
    SEL s = sel_registerName("openApplicationWithBundleID:");
    if (!ws || ![ws respondsToSelector:s]) return NO;
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, @"com.tencent.wetype");
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
// ⛔ 踩过的坑（IPS 已证实，别再试）：`SBFrontmostApplicationDisplayIdentifier`
//   虽然 dlsym 能取到非空地址，但调用返回值是垃圾（0x10000003），当 CFString 发 copy ⇒ EXC_BAD_ACCESS。
//   ⇒ 签名没验证过的私有 C 函数绝对不能直接调。
//
// ✅ 可行路径（按优先级）：
//   ① WeType 自己的 WBInputViewContext.hostBundleID（最可靠，静态实证有这两个方法）
//   ② WeType 报给我们并缓存下来的值
//   ③ 上次落盘的宿主（半注销后进程是新起的，内存空 ⇒ 靠它）
//   ④ LSApplicationWorkspace -frontmostApplication（iOS16 上多半取不到，兜底而已）

static NSString *gRKVLHostBundle = nil;   // 本轮的宿主（回跳目标）
static NSString *gRKVLHostFromWeType = nil;
// 缓存 WBInputViewContext 实例：用 __weak，实例被微信释放时自动置 nil，
// 避免 unsafe_unretained 的 use-after-free（RKVLHostFromCachedCtx 读它时 ARC 会 retain 野指针 ⇒ 崩溃）。
static __weak id gRKVLInputCtx = nil;

// 宿主 bundle id 落盘：半注销后第一次点语音不回来 —— 那一刻扩展进程是新的（或刚被系统回收过），
// ctx / 内存缓存都还空，宿主取不到 ⇒ 回跳被跳过。落盘在扩展自己的沙盒 Library/Preferences 下。

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

// 从缓存的 WBInputViewContext 主动读宿主。全部走 respondsToSelector + isKindOfClass，读不到就 nil。
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

    // 顺序讲究：先主动读 ctx（当下最新的宿主），再退回 hook 到的缓存值（可能是上一次会话的宿主）。
    NSString *fromCtx = RKVLHostFromCachedCtx();
    if (RKVLHostLooksValid(fromCtx)) {
        if (outVia) *outVia = @"WeType.ctx(主动)";
        return fromCtx;
    }
    if (RKVLHostLooksValid(gRKVLHostFromWeType)) {
        if (outVia) *outVia = @"WeType.hostBundleID(缓存)";
        return gRKVLHostFromWeType;
    }
    // 进程是新起的（半注销后第一次点语音就是这种），内存里啥都没有 ⇒ 读上次落盘的
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

// 单一定时器链（0.05s/拍，最长 6s）。与原生的差别只在「顺序」：
//   原生：点语音 → pip 超时 3s → 跳主 App → 停在那里不回来（用户被带走）
//   我们：点语音 → 立刻跳主 App → 等它进待机/开录音 → 自动送回宿主 → 下一轮 pip 立着 ⇒ 免跳
static BOOL   gRKVLReturnPending = NO;   // 本轮状态机是否在跑（唯一的停机开关）
static int    gRKVLReturnTicks   = 0;    // 已推进的拍数
static int    gRKVLReturnTries   = 0;    // 已经拉起过几次（含首拉，上限 2）
static BOOL   gRKVLReturnSawMic  = NO;
static double gRKVLFirstMicT     = 0;    // 首次见到 mic=1 的那一刻（相对本轮起点）
// pip 也要「稳一下再回」：pip 刚变 1 就回跳 ⇒ 那次同步 XPC 阻塞 ~400ms（SpringBoard 还在做
// wetype 的前台/pip 转场，把我们的激活请求排在后面）；mic 路径已稳定 0.45s 再回 ⇒ 同一支 API
// 只阻塞 ~11ms。⇒ pip 也等 0.15s 再回，拿 0.15s 换掉 400ms 的排队时间。
static BOOL   gRKVLReturnSawPip  = NO;
static double gRKVLFirstPipT     = 0;
static BOOL   gRKVLFallbackLaunched = NO; // 我们主动拉起过 ⇒ 必须回跳
static BOOL   gRKVLJumped        = NO;    // 原生是否已发生 JUMP
static BOOL   gRKVLReturned      = NO;    // 本轮已回跳（防重复）
static NSTimeInterval gRKVLStartAt = 0;  // 本轮起点（CFAbsoluteTime，亚微秒开销）
// 「录制失败」恢复判据：10 秒内出现过 session_start_failed 且 pip 报着 1 ⇒ 这个待机是坏的，
// 当成「未待机」处理，主动拉起一次把主 App 真正带到前台重建待机（随后自动回跳）。
static int            gRKVLStartFailCount = 0;
static NSTimeInterval gRKVLStartFailAt = 0;
// 本轮是「坏待机」重建：pip=1 不能当成立即回跳的依据（那个 pip 是旧的），必须看到 mic 真起来。
static BOOL           gRKVLNeedRealRecorder = NO;

// 单一定时器链的「代际」。nudge 要插队时把代际 +1，已排队的那一拍发现代际不符就自己退出，
// 所以任何时刻只有一条链在跑（旧版没这层，nudge 会让链翻倍、tick 越跑越多）。
static uint32_t gRKVLGen = 0;
static BOOL     gRKVLInTick = NO;        // 防 hook 重入（tick 里读 mic/pip 会再次进 hook）

static double RKVLNow(void) { return CFAbsoluteTimeGetCurrent(); }

// 回跳请求走串行后台队列：前台切换的时间系统照收，但键盘能立刻开始重建（不卡主线程）。
static dispatch_queue_t RKVLActQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.minis.rainbowkeyboard.activate", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static void RKVLReturnToHost(NSString *why) {
    if (gRKVLReturned) return;
    gRKVLReturned = YES;
    gRKVLReturnPending = NO;
    NSString *bid = gRKVLHostBundle;
    if (!bid.length) {
        return;     // 没有宿主 bundle，放弃回跳
    }
    dispatch_async(RKVLActQueue(), ^{
        int ok = 0;
        BOOL r = RKVLActivateBundle(bid, &ok);
        if (!r) {
            // 半注销刚醒的第一拍偶尔会被系统拒一次（前台切换还没就绪），重试一次
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           RKVLActQueue(), ^{
                int ok2 = 0;
                RKVLActivateBundle(bid, &ok2);
            });
        } else {
            RKVLHostSave(bid);   // 回跳成功 ⇒ 这个宿主是可信的，存下来给下次进程启动用
        }
    });
}

// 拉起一次（连续右跳的每一跳）。调用方负责计数与判据。
static BOOL RKVLJumpOnce(const char *why) {
    int ok = 0;
    BOOL r = RKVLForegroundLaunchApp(&ok);
    gRKVLReturnTries++;
    if (r) gRKVLFallbackLaunched = YES;
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
    //   ⚠️ 例外 gRKVLNeedRealRecorder（本轮是「坏待机」重建）：此时 pip 是之前就有的，
    //     不能当依据 —— 必须等 mic 真起来（走 ②），否则会立刻回跳、录音又没起。
    if (pip == 1 && !gRKVLNeedRealRecorder) {
        if (!gRKVLFallbackLaunched) {
            gRKVLReturnPending = NO;
            return NO;
        }
        // 等 pip 连续稳住 0.15s 再回跳（避开转场排队）。
        if (!gRKVLReturnSawPip) {
            gRKVLReturnSawPip = YES;
            gRKVLFirstPipT = t;
            return YES;
        }
        if (t - gRKVLFirstPipT >= 0.15) {
            RKVLReturnToHost(@"pip_ready");
            return NO;
        }
        return YES;
    }
    // pip 掉了 ⇒ 稳定计时作废（下一轮重新计）
    if (pip == 0) gRKVLReturnSawPip = NO;

    // ② 录音已起、连续稳定 0.45s 再回。刚起就切会把音频采集掐断（=「录制失败」）。
    if (gRKVLFallbackLaunched && mic == 1) {
        if (!gRKVLReturnSawMic) {
            gRKVLReturnSawMic = YES;
            gRKVLFirstMicT = t;
        } else if (t - gRKVLFirstMicT >= 0.45) {
            RKVLReturnToHost(@"mic_started");
            return NO;
        }
    } else if (mic == 0 && gRKVLReturnSawMic) {
        // 录音掉了（半注销首拍常见）⇒ 稳定计时作废，等它真正稳住
        gRKVLReturnSawMic = NO;
        gRKVLFirstMicT = 0;
    }

    // ③ 连续右跳：1.5s 还没 mic/pip，且原生也没跳 ⇒ 这一跳没落地，再拉一次（最多 2 次）。
    //   判 `gRKVLJumped` 是为了「精准命中」：原生已经跳了就别叠第二次。
    if (gRKVLReturnTries < 2 && !gRKVLJumped && mic == 0 && pip == 0 && t >= 1.5) {
        RKVLJumpOnce("retry");
    }

    // ④ 6.0s 保底：拉起过但始终没起来 ⇒ 仍然回跳，绝不把人扔在输入法里。
    if (gRKVLFallbackLaunched && t >= 6.0) {
        RKVLReturnToHost(@"timeout");
        return NO;
    }

    // ⑤ 我们没拉起过（拉起失败），但原生跳了 ⇒ 只回跳不重开，别把人困住。
    if (!gRKVLFallbackLaunched && gRKVLJumped && t >= 4.0) {
        gRKVLReturned = YES;
        gRKVLReturnPending = NO;
        NSString *bid = gRKVLHostBundle;
        if (bid.length) {
            int ok = 0;
            RKVLActivateBundle(bid, &ok);
        }
        return NO;
    }

    // ⑥ 收工：没拉起过也没原生跳 ⇒ 这一拍压根没走跳转路径，停掉观察。
    if (!gRKVLFallbackLaunched && !gRKVLJumped && t >= 2.0) {
        gRKVLReturnPending = NO;
        return NO;
    }
    return YES;
}

static void RKVLScheduleTick(void);

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

static void RKVLScheduleTick(void) {
    double delay = (RKVLNow() - gRKVLStartAt < 3.0) ? 0.05 : 0.30;
    uint32_t g = ++gRKVLGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g != gRKVLGen) return;      // 已被更新的一拍取代
        RKVLReturnTick();
    });
}

static void RKVLBeginRound(void) {
    gRKVLReturnPending = NO;          // 上一轮还在跑就以本轮为准（连点两次语音不会两个状态机抢同一个 host）
    gRKVLReturnPending = YES;
    gRKVLReturnTicks = 0;
    gRKVLReturnTries = 0;
    gRKVLReturnSawMic = NO;
    gRKVLFirstMicT = 0;
    gRKVLReturnSawPip = NO;
    gRKVLFirstPipT = 0;
    gRKVLFallbackLaunched = NO;
    gRKVLJumped = NO;
    gRKVLReturned = NO;
    gRKVLNeedRealRecorder = NO;
    gRKVLStartAt = RKVLNow();
}

#pragma mark - 探针

%hook WBVoiceStateProbe

- (BOOL)appAlive {
    gRKVLProbe = self;
    return %orig;
}

// standby 的两根支柱：麦克风与画中画。半注销后这俩大概率都是 0，那才是「必须跳」的根因。
- (BOOL)microphoneActive {
    BOOL v = %orig;
    static BOOL last; static dispatch_once_t once;
    dispatch_once(&once, ^{ last = !v; });
    if (v != last) {
        last = v;
        if (v) RKVLNudge();
    }
    return v;
}

- (BOOL)pictureInPictureActive {
    BOOL v = %orig;
    static BOOL last; static dispatch_once_t once;
    dispatch_once(&once, ^{ last = !v; });
    if (v != last) {
        // 先把 last 更新掉再 nudge：nudge 里的状态机会再读一次 pip，
        // 如果这时候 last 还是旧值就会重入本 hook ⇒ 递归。
        last = v;
        if (v) RKVLNudge();
    }
    return v;
}

%end

%hook WBVoiceInputService

// 真正的入口（launchWcVoiceWithContext: 全程零命中）。
//
// ⭐ 唯一路径：
//   pip/mic 已立 ⇒ 立刻返回，一行活都不干（真免跳，零开销）
//   否则         ⇒ 主动有头拉起主 App（一次右跳），起状态机；等它进待机就自动回跳
- (void)launchWBRecorderWithContext:(id)context finishedBlock:(id)block {
    // 入口先刷新一次设置（免跳总闸 VoiceWakeApp），1s 节流。
    RKVLRefreshIfStale();
    int micB = RKVLProbeFlag(@selector(microphoneActive));
    int pipB = RKVLProbeFlag(@selector(pictureInPictureActive));

    // ① 已经待机/录音 ⇒ 本来就免跳，别去打扰 App（这才是「一次都不跳」的常态）。
    //
    // ⚠️ 但 pip=1 有个坑：半注销后键盘进程刚起来时，probe 可能报的是
    //   **上一轮残留的 pip=1**（那一刻主 App 才刚载入、realPip=0，键盘侧 mask 却已经是 0x3）。
    //   这种假值会让 WeType 自己误判「免跳」⇒ 不跳转、也不录音 ⇒ 用户看到的就是
    //   「半注销后头几次点语音全是录制失败」。
    //   判据：pip=1 但 appAlive=0 ⇒ pip 不可能真实存在（pip 由主 App 提供）⇒ 按未待机处理。
    int aliveB = RKVLProbeFlag(@selector(appAlive));
    BOOL stalePip = (pipB == 1 && aliveB == 0);
    // ⭐ 10 秒内刚发生过 session_start_failed ⇒ 这个 pip 是「坏待机」，同样不可信。
    NSTimeInterval nowTs = [NSDate date].timeIntervalSince1970;
    BOOL brokenStandby = (gRKVLStartFailCount > 0 && nowTs - gRKVLStartFailAt <= 10.0 && micB == 0);
    if (((pipB == 1 && !stalePip) || micB == 1) && !brokenStandby) {
        %orig;
        return;
    }

    // ② 宿主：必须趁现在问（此刻前台 App 就是宿主；一旦拉起，前台就变成 wxkb 了）。
    NSString *via = nil;
    NSString *hostNow = RKVLFrontmostBundleID(&via);
    if (hostNow.length) gRKVLHostBundle = hostNow;

    // ③ 宿主未知 ⇒ 不拉起（拉得起来、回不去 = 把人扔在输入法里），老实交给原生。
    if (!gRKVLHostBundle.length || !RKVLVoiceWake) {
        %orig;
        return;
    }

    // ④ 主动右跳 + 起状态机。
    //   拉起失败也要起状态机：原生随后一定会跳（WeType 自己的 3s PIPStart 超时兜底），
    //   那时状态机走 ⑤ 只做回跳（rescue），照样不会把人困在输入法里。
    RKVLBeginRound();
    gRKVLNeedRealRecorder = brokenStandby;   // 坏待机：只认 mic 起来，不认旧 pip
    RKVLJumpOnce("entry");
    RKVLReturnTick();
    %orig;
}

// reason 就是二进制里那套枚举：app_background_without_audio / app_killed /
// pip_start_timeout_url_fallback / launch_app_from_background / session_start_failed …
// 计数「session_start_failed」用于「录制失败恢复」判据（功能），其余 reason 只作观察（已随日志移除）。
- (void)updateLaunchingRecorderApp:(BOOL)launching reason:(id)reason {
    if ([reason isKindOfClass:[NSString class]]) {
        NSString *r = (NSString *)reason;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if ([r containsString:@"session_start_failed"]) {
            if (now - gRKVLStartFailAt > 10.0) gRKVLStartFailCount = 0;  // 隔太久重新计数
            gRKVLStartFailCount++;
            gRKVLStartFailAt = now;
        } else if ([r containsString:@"launch_app_from_background"] ||
                   [r containsString:@"session_stopped"]) {
            gRKVLStartFailCount = 0;   // 正常跳转/正常结束 ⇒ 状态已恢复
        }
    }
    %orig;
}

// 原生自己的跳转入口 —— 唯一作用是给状态机记一笔「原生已经跳了」，
// 避免我们再叠一次拉起（= 精准命中的关键）。
- (void)launchAppFromBackgroundWithAllowBluetooth:(BOOL)allow pipTimeoutFallback:(BOOL)fallback {
    gRKVLJumped = YES;
    %orig;
}

%end

#pragma mark - 向 WeType 要宿主 bundle id

// 为什么用这条：iOS 16 的 LSApplicationWorkspace 没有 -frontmostApplication，
// SBFrontmostApplicationDisplayIdentifier 又返回垃圾（会崩）。系统侧问不出来。
//
// ✅ 但 WeType 自己一定知道宿主：静态实证（wxkb_plugin 方法表）
//   WBInputViewController -inputViewContext → WBInputViewContext -hostBundleID
//   WBRootViewManager    -hostBundleID / -refreshHostBundleID / -hostBundleIDDidChange
//   WBVoicePendingClose  -hostBundleId / -setHostBundleId:
//   WBVoiceReportContext -hostBundleId / -setHostBundleId:
//   做法：getter 和 setter 都挂，谁先给我们算谁。全部只是「读一份返回值 / 抄一份入参」，不改任何行为。

static void RKVLNoteHostBundle(id v, const char *via) {
    if (!v || ![v isKindOfClass:[NSString class]]) return;
    NSString *s = (NSString *)v;
    if (s.length < 5 || ![s containsString:@"."]) return;          // 不像 bundle id
    if ([s hasPrefix:@"com.tencent.wetype"]) return;               // 自己，没用
    if (s.length > 128) return;
    if (gRKVLHostFromWeType && [gRKVLHostFromWeType isEqualToString:s]) return;
    gRKVLHostFromWeType = [s copy];
    RKVLHostSave(s);   // 学到的宿主立刻落盘（进程被回收后仍能回跳）
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
        RKVLRefreshSettings();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RKVLPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // ⚠️ Logos 硬规则：文件里一旦出现 %group，原来那些「不在 group 里」的 hook
        //   就归到 _ungrouped 组，必须显式 %init(_ungrouped)，否则编译报
        //   `error: non-initialized hook group: _ungrouped`。
        %init(_ungrouped);

        // 装「向 WeType 要宿主」的 hook。类缺一个就整组不装，避免 hook 到不存在的类。
        BOOL h1 = objc_getClass("WBInputViewContext") != NULL;
        BOOL h2 = objc_getClass("WBRootViewManager") != NULL;
        BOOL h3 = objc_getClass("WBVoicePendingClose") != NULL;
        BOOL h4 = objc_getClass("WBVoiceReportContext") != NULL;
        BOOL h5 = objc_getClass("WBInputViewController") != NULL;
        if (h1 && h2 && h5) {
            %init(RKHostProbe);
        }
        if (h3 && h4) {
            %init(RKHostProbe2);
        }
    }
}
