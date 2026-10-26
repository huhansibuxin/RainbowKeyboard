// RKVoiceJumpProbe.xm — 语音按钮「跳主 App」诊断探针（2.3.41，第一阶段：只观测不动行为）
//
// == 目的 ==
// 半注销（只杀 SpringBoard、保留后台 App）之后，点键盘语音按钮每次都跳微信输入法主 App。
// 完整注销后只要 1~2 次就稳定不跳。2.3.41 先把「为什么判成要跳」的现场录下来，
// 拿到证据后再改成「先试 App-owned IPC，失败再跳」。
//
// == 判据出处（wxkb_plugin 静态挖出，均在键盘扩展进程内） ==
//   免跳路径日志： restart record via App-owned IPC (mic=%d pip=%d hostIsMainApp=%d)
//   跳转路径日志： force jump main app (appAlive=%d standby=%d) reason=%@
//                 reason ∈ app_background_without_audio / app_killed /
//                          pip_start_timeout_url_fallback / launch_app_from_background
//   待机体系：     recordingStandbyMode / standbyDuration / shouldUsePIPStandbyMode /
//                  isMainAppVoiceStandbyActive / transitionToRecorderStandby /
//                  VoiceSessionEvent EnteredStandby / standby_expired
//   ⇒ 免跳的前提是「主 App 活着 **且** 处于 recording standby」；只有 appAlive 不够。
//
// == 本次 hook 的四个点（返回类型都静态核对过，避免改坏调用约定） ==
//   WBVoiceStateProbe   -appAlive                       → BOOL（cset w0, ne）
//   WBVoiceInputService -canUseWcVoiceByConfig          → BOOL（ldrb w0,[x0,#0x8b]）
//   WBVoiceInputService -launchWcVoiceWithContext:finishedBlock:        → void
//   WBVoiceInputService -launchAppFromBackgroundWithAllowBluetooth:pipTimeoutFallback: → void
//     （单参版本 -launchAppFromBackgroundWithAllowBluetooth: 只有 8 字节，是跳板，不用 hook）
//   WBVoiceCommandChannel / WBVoiceEventChannel -ipcChannel → id（IPC 通道是否存在）
//
// 日志受「记录调试日志」开关（AIRecorderLog）与总开关（Enabled）双控，默认关；
// 关闭时 RKVL 第一行就 return，不做格式化、不 fopen。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
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

#pragma mark - 探针

%hook WBVoiceStateProbe

- (BOOL)appAlive {
    BOOL alive = %orig;
    RKVLLog(@"[probe] appAlive=%d thread=%@", alive,
            [NSThread isMainThread] ? @"main" : @"bg");
    return alive;
}

%end

%hook WBVoiceInputService

- (BOOL)canUseWcVoiceByConfig {
    BOOL ok = %orig;
    RKVLLog(@"[gate] canUseWcVoiceByConfig=%d", ok);
    return ok;
}

- (void)launchWcVoiceWithContext:(id)context finishedBlock:(id)block {
    RKVLLog(@"[entry] launchWcVoiceWithContext ctx=%p block=%p", context, block);
    %orig;
}

- (void)launchAppFromBackgroundWithAllowBluetooth:(BOOL)allow pipTimeoutFallback:(BOOL)fallback {
    // 走到这里 = 已经决定「跳主 App」。记下来，用来确认半注销现场是不是每次必跳。
    RKVLLog(@"[JUMP] launchAppFromBackground allowBT=%d pipFallback=%d", allow, fallback);
    %orig;
}

%end

%hook WBVoiceCommandChannel

- (id)ipcChannel {
    id ch = %orig;
    if (ch) RKVLLog(@"[ipc] commandChannel=%p", ch);
    return ch;
}

%end

%hook WBVoiceEventChannel

- (id)ipcChannel {
    id ch = %orig;
    if (ch) RKVLLog(@"[ipc] eventChannel=%p", ch);
    return ch;
}

%end

%ctor {
    @autoreleasepool {
        RKVLLogRefresh();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            RKVLPreferencesChanged, CFSTR("com.minis.rainbowkeyboard.changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        RKVLLog(@"==== RKVoiceJumpProbe 2.3.42 loaded path=%@ ====", RKVLLogPath());
        NSDictionary *p = RKReadEffectivePreferences();
        RKVLLog(@"[cfg] logEnabled=%d Enabled=%@ AIRecorderLog=%@ Widen=%@ rev=%@ bundle=%@",
                RKVLLogEnabled, p[@"Enabled"], p[@"AIRecorderLog"], p[@"WidenVoiceButton"],
                p[@"RKSettingsRevision"], [[NSBundle mainBundle] bundleIdentifier]);
    }
}
