// RKVoiceJumpProbe.xm — 语音按钮「连续右跳」免跳兜底（2.4.3）
//
// == 2.4.3：再提速一档 + 日志门控改成固定优先级 ==
//   · 日志门控：2.4.2 实测「03:18:53 关掉、03:18:54 起照样写」。根因是取值规则
//     「按 revision 取新的一方」——只要某一路给出**过期但 revision 更新**的值就永远关不掉。
//     改成固定优先级：plist 文件直读（无缓存）> 设置页位域快照 > CFPreferences 域 > 自己落盘值。
//     另加独立门控追踪 tmp/rk_gate.log（≤2KB，只在门控翻转时写一行），
//     以后「关了还写」一眼就能看出是哪一路赢的。
//   · 提速 ①：采样 0.10s → **0.05s**（真正的发现延迟来自稳定计时粒度，采样只决定量得准不准）
//   · 提速 ②：录音稳定窗 0.70s → **0.45s**（实测这轮 mic 一起就是稳的，0.7s 白等 0.25s）
//   · 提速 ③：**回跳的同步 XPC 移出主线程**。实测 pip 路径阻塞 390ms、mic 路径只要 44ms，
//     差的 350ms 是 SpringBoard 排队等 WeType 的前台切换动画。它压在主线程时，
//     键盘自己的重建也被一起挡住 ⇒ 放到串行后台队列，前台切换照收，键盘立刻开始重建。
//   · 计时日志：`[jump] ... 耗时Xms` / `[back] ... 阻塞Xms`，再优化直接看这两个数。
//
// == 2.4.2：日志门控再加一道「写之前先看一眼」==
//   2.4.1 实机：日志打开能写（说明快照来源通了），但**关掉之后还在写**。
//   设备证据：03:12:18 关掉（plist AIRecorderLog=0、revision 1793041938700203），
//     键盘进程一路写到 03:13；dbg.plist mtime 停在 03:11 ⇒ RKVLLogRefresh 一次没被调。
//   原因：翻设置页时键盘扩展基本挂起，libnotify 的 darwin 通知对挂起进程是丢的。
//   ⇒ 不再依赖通知时机：语音轮次入口 `launchWBRecorderWithContext:` 第一行懒刷新（1s 节流）。
//
// == 2.4.1：回跳提速 + 日志门控第三来源 ==
//   实测（2.4.0 设备日志）一轮跳转从「点语音」到「回到宿主」约 2.4~2.6s，拆开是：
//     跳过去 → mic 在 1.3~1.5s 起来 → 再等「稳定 1.0s」→ 回跳。
//   两处纯等待，都不影响正确性，可以砍：
//     ① 采样 0.4s → 前 3 秒 0.10s（发现 mic 平均早 0.2s，最坏早 0.3s）
//     ② 稳定窗 1.0s → **连续** 0.7s（密采样能看见 mic 抖动，掉了就重计时，更安全也更快）
//     ③ 补跳阈值 2.0s → 1.5s
//   ⇒ 理论省 0.5~0.7s，一轮约 1.7~1.9s 就回到宿主。
//   ⚠️ 别把 0.7s 再往下降到「一拍就回」：录音刚起就切走会把采集掐断（= 录制失败）。
//   · 日志门控：键盘扩展沙盒读不到偏好时，改从**设置页位域快照**取开关值
//     （2.4.0 只读文件 + 落盘值，而落盘值只在能读文件时才写 ⇒ 门永远关着，开不起来）。
//
// == 2.4.0（正式版）：日志真正受门控 + 删掉「语音免跳转实验」开关 ==
//   · 日志：全项目只有一个写盘口 RKVLLogWrite，**唯一门控 = RKVLLogEnabled**。
//     之前 RKVLLog（受控）与 RKVLLogForce（无视开关强行写）两套并存，正式版关着日志
//     每次点语音仍写十几行。现在两者同一个门控；关 ⇒ 连字符串格式化都不做。
//     · 门控值落盘（Library/Preferences/com.minis.rainbowkeyboard.dbg.plist）——
//       键盘扩展注销后读不到 /var/mobile/Library/Preferences，靠落盘值才不静默。
//     · 512KB 上限，每 128 行查一次大小，超了整体重来（长期开着也不会写爆 tmp）。
//   · 删探针：`currentMask` / `_transitionNativeViewStateToRecorderStandby` 两个纯日志
//     hook 整体删除；reason 与 JUMP 两个保留（诊断「为什么弹小窗/录制失败」的唯一来源）。
//     [gate] 日志改成「状态变化才写」，不再每拍刷。
//   · 删实验开关 VoiceNoJumpTrial（强制 requireJump=NO 那条，实测无用且会让人以为是它在起作用）。
//
// == 2.3.66：小窗路线全部删除，只保留连续右跳兜底 ==
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
// 日志受「记录调试日志」（AIRecorderLog）与总开关（Enabled）双控，**默认关**。
// 关着时：所有 RKVLLog / RKVLLogForce 都只做一次 BOOL 判断就返回 —— 不格式化、不 fopen、不写盘。

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
// 2.3.66：连续右跳兜底总闸。开 = 点语音时主动把主 App 拉起来建待机（默认开）。
//   关掉就完全等于原生行为（每次点语音都会跳，且跳过去不回来）。
static BOOL RKVLVoiceWake = YES;

static NSString *RKVLLogPath(void);

// == 2.4.0：日志门控 ==
// 正式版默认**不写盘**（「记录调试日志」关着就一行都不写，fopen 都不发生）。
// 之前的 RKVLLogForce 是「无视开关强行写」，正式版必须去掉 —— 它每次点语音要写十几行。
//
// ⚠️ 但门控值本身有个坑（2.3.56 踩过）：键盘扩展在注销后读不到
//   /var/mobile/Library/Preferences，RKReadEffectivePreferences 会回落固化表，
//   固化表里没有 AIRecorderLog ⇒ 读到 nil ⇒ 日志静默，用户以为「开关不管用」。
//   ⇒ 把最终门控结果落盘到扩展自己的沙盒（Library/Preferences），
//     读不到 prefs 时用落盘值。注销后日志照样能写。
#define RKVL_DBG_STORE @"com.minis.rainbowkeyboard.dbg.plist"

static NSString *RKVLStoreDir(void) {
    NSString *lib = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    return lib;
}

static NSString *RKVLDbgStorePath(void) {
    return [RKVLStoreDir() stringByAppendingPathComponent:RKVL_DBG_STORE];
}

static BOOL RKVLDbgFlagLoad(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:RKVLDbgStorePath()];
    return [d[@"on"] boolValue];
}

static void RKVLDbgFlagSave(BOOL on) {
    static int last = -1;
    if (last == (int)on) return;      // 只在变化时落盘，避免每次 refresh 都写文件
    last = (int)on;
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:RKVLStoreDir()
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        [@{@"on": @(on)} writeToFile:RKVLDbgStorePath() atomically:YES];
    } @catch (__unused NSException *e) {}
}

// 门控追踪：**独立于主日志**的一条极短记录（每个进程最多几行，1KB 上限，环形覆盖）。
// 为什么必须有它：门控本身出问题时主日志正好不写，没有它就只能靠猜。
// 只在「每次懒刷新」写一行，一次点语音最多一行，开销可忽略。
static void RKVLGateTrace(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"rk_gate.log"];
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if ([a[NSFileSize] unsignedLongLongValue] > 2048) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    NSString *line = [NSString stringWithFormat:@"%.3f [%d] %@",
                      [NSDate date].timeIntervalSince1970, getpid(), body];
    FILE *fp = fopen(path.UTF8String, "a");
    if (!fp) return;
    fprintf(fp, "%s\n", line.UTF8String);
    fclose(fp);
}

static void RKVLLogRefresh(void) {
    // ⚠️ 日志开关必须读「裸值」（RKReadStoredPreferences，**不含**固化表兜底）：
    //   固化表里 AIRecorderLog = 0，若用生效值判断，注销后永远是 0 ⇒ 落盘值机制失效。
    //
    // ⭐ 2.4.1 修：键盘扩展沙盒**读不到** /var/mobile/Library/Preferences 时，
    //   2.4.0 只剩「落盘值」一条路 —— 而落盘值只有在「读得到」时才写，于是死锁。
    //   第三来源 = 设置页发过来的位域快照（和光效开关同一条通道，已在跑）。
    //
    // ⭐⭐ 2.4.3 修「关掉日志还在写」：
    //   2.4.2 实测（03:18:53 关掉、03:18:54 起照样写）说明「按 revision 取新的一方」不可靠：
    //   只要某一路给了个**过期但 revision 更新**的值，关就永远关不掉。
    //   改成**固定优先级、单一路取值**，并把「谁赢的」写进门控追踪，下次一眼定位：
    //     ① plist 文件直读（无进程内缓存，最准）
    //     ② 设置页位域快照（notify 状态，挂起进程也读得到）
    //     ③ CFPreferences 域（cfprefsd 有进程内缓存，最容易读到旧值 ⇒ 放在最后）
    //     ④ 三路都读不到才用自己落盘的值（注销后沙盒读不到外部的极端情况）
    NSDictionary *stored = RKReadStoredPreferences();
    NSDictionary *snapshot = RKReceiveDisplaySnapshot();
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:RKPreferencesPath];
    id lg = nil, en = nil;
    NSString *src = @"none";
    if (file[@"AIRecorderLog"]) {
        lg = file[@"AIRecorderLog"]; en = file[@"Enabled"]; src = @"file";
    } else if (snapshot[@"AIRecorderLog"]) {
        lg = snapshot[@"AIRecorderLog"]; en = snapshot[@"Enabled"]; src = @"snapshot";
    } else if (stored[@"AIRecorderLog"]) {
        lg = stored[@"AIRecorderLog"]; en = stored[@"Enabled"]; src = @"cfprefs";
    }
    BOOL on;
    if (lg) {
        BOOL master = (!en || [en boolValue]);
        on = master && [lg boolValue];
    } else {
        on = RKVLDbgFlagLoad();
        src = @"fallback(落盘)";
    }
    if (on != RKVLLogEnabled) {
        RKVLGateTrace(@"gate %d -> %d  来源=%@ file=%@ snap=%@ cfp=%@",
                      (int)RKVLLogEnabled, (int)on, src, file[@"AIRecorderLog"] ?: @"-",
                      snapshot[@"AIRecorderLog"] ?: @"-", stored[@"AIRecorderLog"] ?: @"-");
    }
    RKVLLogEnabled = on;
    RKVLDbgFlagSave(RKVLLogEnabled);          // 供「注销后三路都读不到」时使用
    // 兜底总闸：走生效值（含固化表），注销后仍按「开」回落。
    NSDictionary *prefs = RKReadEffectivePreferences();
    id enabled = prefs[@"Enabled"];
    BOOL master = (!enabled || [enabled boolValue]);
    RKVLVoiceWake = master && [prefs[@"VoiceWakeApp"] boolValue];
}

static void RKVLPreferencesChanged(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ RKVLLogRefresh(); });
}

// ⭐ 2.4.2 实测：darwin 通知在键盘扩展里**不可靠**。
//   老板 03:12:18 关掉日志（设备 plist 已经是 AIRecorderLog=0、revision 1793041938700203），
//   键盘进程照样继续写日志到 03:13 —— dbg.plist 的 mtime 一直停在 03:11，说明
//   RKVLLogRefresh 一次都没被回调。原因：翻设置页时键盘扩展基本处于挂起，
//   libnotify 的 darwin 通知对挂起进程是**丢**的，回到微信后也不会补投。
//   ⇒ 不能在“什么时候改的”这条路上等通知，改成“要写之前先看一眼”：
//   每个语音轮次入口懒刷新一次（1 秒节流，一次点语音最多一次 prefs 读）。
static void RKVLLogRefreshIfStale(void) {
    static CFAbsoluteTime last;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 1.0) return;
    last = now;
    RKVLLogRefresh();
}

static NSString *RKVLLogPath(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"rk_voice.log"];
}

// 统一的写盘点：**唯一入口，唯一门控**。
//   · RKVLLogEnabled == NO  ⇒ 立即返回，不做字符串格式化、不做 fopen（正式版常态）
//   · 512KB 上限：每 128 行查一次大小，超了整体重来（长期开着也不会把 tmp 写爆）
//   · 只有 1 次 fopen/fprintf/fclose，没有 NSLog（NSLog 会走 asl，代价高得多）
#define RKVL_LOG_MAX_BYTES (512 * 1024)
static void RKVLLogWrite(NSString *body, BOOL forced) {
    if (!RKVLLogEnabled) return;
    NSString *path = RKVLLogPath();
    static unsigned int lines = 0;
    if ((++lines & 0x7F) == 0) {
        NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if ([a[NSFileSize] unsignedLongLongValue] > RKVL_LOG_MAX_BYTES) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
    }
    NSString *line = [NSString stringWithFormat:@"%.3f [%d] %@%@",
                      [NSDate date].timeIntervalSince1970, getpid(),
                      forced ? @"(关键) " : @"", body];
    FILE *fp = fopen(path.UTF8String, "a");
    if (!fp) return;
    fprintf(fp, "%s\n", line.UTF8String);
    fclose(fp);
}

static void RKVLLog(NSString *fmt, ...) {
    if (!RKVLLogEnabled) return;          // 先判门控，省掉格式化开销
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    RKVLLogWrite(body, NO);
}

// 「关键节点」= 入口 / 拉起 / 回跳 / pip 掉落。同一门控，只是行首多一个标记方便 grep。
// ⚠️ 2.4.0 起它**不再**无视开关强行写：正式版关着日志就是零写盘。
static void RKVLLogForce(NSString *fmt, ...) {
    if (!RKVLLogEnabled) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    RKVLLogWrite(body, YES);
}

#pragma mark - 状态读取（WeType 自己的 WBVoiceStateProbe）

// 从 WBVoiceStateProbe 的实例里取状态。用 unsafe_unretained 缓存实例（长生命单例），
// 不额外 retain，避免在插件里制造循环。
static __unsafe_unretained id gRKVLProbe = nil;

static int RKVLProbeFlag(SEL sel) {
    id probe = gRKVLProbe;
    if (!probe) {
        // 2.4.1：类查一次就缓存（旧写法每拍都 objc_getClass，虽然快但没意义）
        static Class probeCls;
        if (!probeCls) probeCls = objc_getClass("WBVoiceStateProbe");
        Class c = probeCls;
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
// 2.4.0：「录制失败」恢复判据。
//   2.3.66 实测日志（1793040365/368/370）反复出现：
//     mic -> 1 后 51ms 掉  ⇒  reason=session_start_failed（连发 3 次）⇒ mask 停在 0x2(mic=0 pip=1)
//     ⇒ 我们看「已有 pip，不介入」⇒ 只能等微信自己 3s PIPStart 超时 → 跳转 → 用户被带走。
//   也就是老板说的「注销后开头点三四次都是录制失败」。
//   判据：10 秒内出现过 session_start_failed 且 pip 报着 1 ⇒ 这个待机是坏的，
//   当成「未待机」处理，主动拉起一次把主 App 真正带到前台重建待机（随后自动回跳）。
static int            gRKVLStartFailCount = 0;
static NSTimeInterval gRKVLStartFailAt = 0;
// 本轮是「坏待机」重建：pip=1 不能当成立刻回跳的依据（那个 pip 是旧的），必须看到 mic 真起来。
static BOOL           gRKVLNeedRealRecorder = NO;

// 单一定时器链的「代际」。nudge 要插队时把代际 +1，已排队的那一拍发现代际不符就自己退出，
// 所以任何时刻**只有一条链**在跑（旧版没这层，nudge 会让链翻倍、tick 越跑越多）。
static uint32_t gRKVLGen = 0;
static BOOL     gRKVLInTick = NO;        // 防 hook 重入（tick 里读 mic/pip 会再次进 hook）

static double RKVLNow(void) { return CFAbsoluteTimeGetCurrent(); }

// 回跳后的两点确认：pip 有没有在后台长出来（决定下一轮能不能免跳）。
// 2.4.0：**纯诊断**，日志关着时连定时器都不排（正式版不占任何定时器）。
static void RKVLPostReturnProbe(int step) {
    if (!RKVLLogEnabled) return;
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
//
// ⭐ 2.4.1 提速：前 3 秒 **0.10s** 一拍，之后 0.30s。
// ⭐ 2.4.3：**0.05s**。实测发现真正的发现延迟来自「稳定计时」的粒度而不是采样本身
//   （mic/pip 一变化 probe 的 hook 就会 nudge，那一刻是毫秒级的），所以采样只影响
//   「连续稳定」到底量准了多少：0.10s 采样 ⇒ 稳定窗最坏多算 0.10s。
//   0.05s 一拍 = 20 次/秒，每拍 2 次 BOOL 的 objc_msgSend（亚微秒）⇒ CPU 可忽略。
static void RKVLScheduleTick(void) {
    double delay = (RKVLNow() - gRKVLStartAt < 3.0) ? 0.05 : 0.30;
    uint32_t g = ++gRKVLGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g != gRKVLGen) return;      // 已被更新的一拍取代
        RKVLReturnTick();
    });
}

// 激活请求（openApplicationWithBundleID:）是**同步 XPC**，会阻塞调用线程直到
// SpringBoard 回话。实测 pip 路径上它阻塞 390ms、mic 路径只要 44ms —— 差的 350ms 是
// 「WeType 还在做前台切换动画，SpringBoard 把我们的请求排在它后面」。
// 它压在键盘主线程上时，键盘自己的重建（keyboard_will_appear）也被一起挡掉 390ms。
// ⇒ 一律走这条串行后台队列：前台切换的时间系统照收，但键盘能立刻开始重建。
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
        RKVLLogForce(@"[back] (%@) 没有宿主 bundle，放弃回跳", why);
        return;
    }
    // 主线程上先抓一次现场（probe 是 WeType 的对象，只在主线程读）
    RKVLLogForce(@"[back] (%@) 发起回跳 -> %@ mask=0x%x mic=%d pip=%d",
                 why, bid, RKVLProbeMask(),
                 RKVLProbeFlag(@selector(microphoneActive)),
                 RKVLProbeFlag(@selector(pictureInPictureActive)));
    dispatch_async(RKVLActQueue(), ^{
        NSTimeInterval t0 = RKVLNow();
        int ok = 0;
        BOOL r = RKVLActivateBundle(bid, &ok);
        NSTimeInterval cost = (RKVLNow() - t0) * 1000.0;
        RKVLLogForce(@"[back] (%@) 完成 -> ok=%@(%d) 阻塞%.0fms", why, r ? @"YES" : @"NO", ok, cost);
        if (!r) {
            // 半注销刚醒的第一拍偶尔会被系统拒一次（前台切换还没就绪），重试一次
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           RKVLActQueue(), ^{
                NSTimeInterval t1 = RKVLNow();
                int ok2 = 0;
                BOOL r2 = RKVLActivateBundle(bid, &ok2);
                RKVLLogForce(@"[back] retry -> ok=%d(%d) 阻塞%.0fms",
                             r2 ? 1 : 0, ok2, (RKVLNow() - t1) * 1000.0);
            });
        } else {
            RKVLHostSave(bid);   // 回跳成功 ⇒ 这个宿主是可信的，存下来给下次进程启动用
        }
        RKVLPostReturnProbe(0);
    });
}

// 拉起一次（连续右跳的每一跳）。调用方负责计数与判据。
static BOOL RKVLJumpOnce(const char *why) {
    int ok = 0;
    NSTimeInterval t0 = RKVLNow();
    BOOL r = RKVLForegroundLaunchApp(&ok);
    NSTimeInterval cost = (RKVLNow() - t0) * 1000.0;
    gRKVLReturnTries++;
    if (r) gRKVLFallbackLaunched = YES;
    RKVLLogForce(@"[jump] #%d(%s) -> %@ ok=%d 耗时%.0fms 待机前状态 mask=0x%x mic=%d pip=%d",
                 gRKVLReturnTries, why, r ? @"YES" : @"NO", ok, cost, RKVLProbeMask(),
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
    //   ⚠️ 例外 gRKVLNeedRealRecorder（本轮是「坏待机」重建）：此时 pip 是之前就有的，
    //     不能当依据 —— 必须等 mic 真起来（走 ②），否则会立刻回跳、录音又没起。
    if (pip == 1 && !gRKVLNeedRealRecorder) {
        RKVLLogForce(@"[back] pip 已立住 t=%.1fs mic=%d -> %@", t, mic,
                     gRKVLFallbackLaunched ? @"回宿主" : @"免跳(未拉起过)");
        if (gRKVLFallbackLaunched) RKVLReturnToHost(@"pip_ready");
        else { gRKVLReturnPending = NO; RKVLPostReturnProbe(0); }
        return NO;
    }

    // ② 录音已起、连续稳定 0.45s 再回。刚起就切会把音频采集掐断（=「录制失败」）。
    //   2.4.1：采样从 0.4s 改成 0.1s 后，这里从「等 1.0s」改成「**连续** 0.7s 不掉」——
    //   密采样能看见抖动，一旦 mic 掉了计时就重来，所以比旧的「粗采样 1.0s」更安全也更快。
    //   2.4.3：0.7 → **0.45s**。实测这轮里 mic 一起就是稳的（日志 1886.485→1889.407、
    //   2312.898→2316.795 都是稳到录音结束才掉），0.7s 是白等 0.25s。
    //   保留 0.45s 而不是「一拍就回」：mic 掉到 0 会立刻重来（下面那个 else），
    //   所以最坏情况只是多等一拍，不会切在抖动上。
    if (gRKVLFallbackLaunched && mic == 1) {
        if (!gRKVLReturnSawMic) {
            gRKVLReturnSawMic = YES;
            gRKVLFirstMicT = t;
            RKVLLogForce(@"[back] 录音已起 t=%.1fs pip=0 -> 等 0.45s 稳定", t);
        } else if (t - gRKVLFirstMicT >= 0.45) {
            RKVLLogForce(@"[back] 录音稳定 t=%.1fs（mic=1 连续 +0.45s）-> 回宿主", t);
            RKVLReturnToHost(@"mic_started");
            return NO;
        }
    } else if (mic == 0 && gRKVLReturnSawMic) {
        // 录音掉了（半注销首拍常见）⇒ 稳定计时作废，等它真正稳住
        gRKVLReturnSawMic = NO;
        gRKVLFirstMicT = 0;
        RKVLLogForce(@"[back] ⚠️ 录音掉了 t=%.1fs -> 稳定计时重来（不提前回跳）", t);
    }

    // ③ 连续右跳：1.5s 还没 mic/pip，且原生也没跳 ⇒ 这一跳没落地，再拉一次（最多 2 次）。
    //   判 `gRKVLJumped` 是为了「精准命中」：原生已经跳了就别叠第二次。
    //   2.4.1：阈值 2.0 → 1.5s（冷启到能建待机实测 0.8~1.5s，再等就是白等）。
    if (gRKVLReturnTries < 2 && !gRKVLJumped && mic == 0 && pip == 0 && t >= 1.5) {
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
    gRKVLNeedRealRecorder = NO;
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
        RKVLLogForce(@"[pip] -> %d mic=%d appAlive=%d", v,
                RKVLProbeFlag(@selector(microphoneActive)),
                RKVLProbeFlag(@selector(appAlive)));
        // ⚠️ 先把 last 更新掉再 nudge：nudge 里的状态机会再读一次 pip，
        //   如果这时候 last 还是旧值就会重入本 hook ⇒ 递归。
        last = v;
        if (v) RKVLNudge();
    }
    return v;
}

%end

%hook WBVoiceInputService

// 总闸：返回值直接决定「键盘内重启录音」还是「跳主 App」。
// 2.4.0：这里**只观察不改行为**（老的「语音免跳转实验」强制返回 NO 已删）。
// 正式版日志关着 ⇒ 整个 hook 只多一次 BOOL 判断就返回，零额外 objc_msgSend。
- (BOOL)requireJumpToMainAppForRecording {
    BOOL jump = %orig;
    if (!RKVLLogEnabled) return jump;
    int alive = RKVLProbeFlag(@selector(appAlive));
    int mic = RKVLProbeFlag(@selector(microphoneActive));
    int pip = RKVLProbeFlag(@selector(pictureInPictureActive));
    // 只在状态发生变化时写一行（原来每次调用都写，一次点语音能刷十几行）
    static int lastSig = -1;
    int sig = (jump ? 1 : 0) | (alive << 1) | (mic << 2) | (pip << 3);
    if (sig != lastSig) {
        lastSig = sig;
        RKVLLog(@"[gate] requireJump=%d (appAlive=%d mic=%d pip=%d)", jump, alive, mic, pip);
    }
    return jump;
}

// 真正的入口（2.3.42 里 hook 的 launchWcVoiceWithContext: 全程零命中）。
//
// ⭐ 2.3.66 唯一路径：
//   pip/mic 已立 ⇒ 立刻返回，一行活都不干（真免跳，零开销）
//   否则         ⇒ 主动有头拉起主 App（一次右跳），起状态机；等它进待机就自动回跳
- (void)launchWBRecorderWithContext:(id)context finishedBlock:(id)block {
    // ⭐ 2.4.2：先懒刷新一次门控（见 RKVLLogRefreshIfStale 的说明）——
    //   必须在第一行日志之前，否则“刚关掉日志的那一次点语音”还会写一整轮。
    RKVLLogRefreshIfStale();
    int micB = RKVLProbeFlag(@selector(microphoneActive));
    int pipB = RKVLProbeFlag(@selector(pictureInPictureActive));
    RKVLLogForce(@"[entry] launchWBRecorder ctx=%p 兜底=%d mask=0x%x mic=%d pip=%d",
            context, RKVLVoiceWake, RKVLProbeMask(), micB, pipB);

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
    // ⭐ 2.4.0：10 秒内刚发生过 session_start_failed ⇒ 这个 pip 是「坏待机」，同样不可信。
    //   （日志 1793040365：mic 起 51ms 就掉，mask 停在 0x2，WeType 既不录也不跳，
    //    要等它自己 3s 超时才跳转 —— 老板说的「头几次录制失败」就是这个。）
    NSTimeInterval nowTs = [NSDate date].timeIntervalSince1970;
    BOOL brokenStandby = (gRKVLStartFailCount > 0 && nowTs - gRKVLStartFailAt <= 10.0 && micB == 0);
    if (brokenStandby && pipB == 1) {
        RKVLLogForce(@"[entry] ⚠️ 10s 内 session_start_failed×%d ⇒ 待机不可信，按未待机处理",
                     gRKVLStartFailCount);
    }
    if (((pipB == 1 && !stalePip) || micB == 1) && !brokenStandby) {
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
    gRKVLNeedRealRecorder = brokenStandby;   // 坏待机：只认 mic 起来，不认旧 pip
    RKVLJumpOnce("entry");
    RKVLReturnTick();
    %orig;
}

// reason 就是二进制里那套枚举：app_background_without_audio / app_killed /
// pip_start_timeout_url_fallback / launch_app_from_background / session_start_failed …
// 2.4.0：只留日志（诊断「为什么又弹小窗」「为什么录制失败」全靠这一行），
//        门控关着时就是一次函数调用 + 一次 BOOL 判断。
- (void)updateLaunchingRecorderApp:(BOOL)launching reason:(id)reason {
    // 计数必须在门控之前做：它是「录制失败恢复」的功能判据，不是日志。
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
    RKVLLogForce(@"[reason] launching=%d reason=%@ (fail=%d)", launching, reason, gRKVLStartFailCount);
    %orig;
}

// 原生自己的跳转入口 —— 唯一作用是给状态机记一笔「原生已经跳了」，
// 避免我们再叠一次拉起（= 精准命中的关键）。
- (void)launchAppFromBackgroundWithAllowBluetooth:(BOOL)allow pipTimeoutFallback:(BOOL)fallback {
    gRKVLJumped = YES;
    RKVLLogForce(@"[JUMP] 原生 launchAppFromBackground allowBT=%d pipFallback=%d", allow, fallback);
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
        RKVLLogForce(@"==== RKVoiceJumpProbe 2.4.3 loaded path=%@ ====", RKVLLogPath());
        RKVLLogForce(@"[cfg] 兜底=%d log=%d（唯一路径：连续右跳）",
                     (int)RKVLVoiceWake, (int)RKVLLogEnabled);
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
        RKVLLogForce(@"[cfg] Enabled=%@ AIRecorderLog=%@ VoiceWakeApp=%@ rev=%@ bundle=%@",
                p[@"Enabled"], p[@"AIRecorderLog"],
                p[@"VoiceWakeApp"], p[@"RKSettingsRevision"],
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
