// RKWetypePipBuild.xm — 注入微信输入法主 App（com.tencent.wetype）
//
// == 这个文件解决什么 ==
// 半注销后主 App 挂在后台时，微信输入法自己**不会**建 PiP（它只在「录音结束进待机」那一刻
// 懒懒地建一次，而且同一进程内建过就不再建）⇒ 键盘侧 pip 永远是 0 ⇒ 每次点语音都得跳。
// 但 `WBVoiceInputPIPManager` 有公开选择子，我们完全可以自己叫它建 —— 调用链抄自
// wcvoicekeep（当年实机验证通过，唯一缺点是它靠 daemon 前台拉起会闪一下屏）。
//
// == 为什么现在不闪屏 ==
// 当年是 daemon `SBSLaunchApplicationForDebugging` 全屏拉起 → 闪。现在激活由 TrollOpen
// 的分屏小窗完成（主 App 出现在用户本来就要看的小窗里）⇒ 我们只在「被激活的那一瞬」建 pip，
// 绝不自己切前台、也绝不 AutoBackground（小窗收起交给 TrollOpen）。
//
// == 触发方式（不依赖挂起进程能收通知）==
// Darwin notify 的 state 存在 notify 守护进程里，是**跨进程持久**的：
//   键盘侧 `notify_set_state(req, now)` + `notify_post`  ⇒ 主 App 下次被激活时读得到
//   （挂起期间收不到 post 没关系，`notify_get_state` 一读就有）
//
// == 铁律 ==
// 1) 只处理「键盘侧 60 秒内请求过」的激活；用户自己打开主 App 不建 pip（不打扰）。
// 2) 请求是一次性的：读完立刻清 0，避免后续无关激活又建一次。
// 3) AVKit 的 startPictureInPicture 会查 UIScene.activationState 必须 ForegroundActive，
//    否则直接 -1001。只在「建 pip 的 2.5 秒窗口」内伪装，其它时间一律返回真实值。
//    ⛔ hook 里**绝不调任何 UIKit API**（wcvoicekeep v1.9.28 在 block 里读 applicationState
//      造成递归栈溢出崩溃过），只读静态变量。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

static const char *const kPipReqName = "com.huhansibuxin.rk.pipreq";

static int            gReqToken = 0;
static BOOL           gFakeForeground = NO;   // 只在建 pip 窗口期内为 YES
static NSTimeInterval gLastEngage = 0;
static BOOL           gHookInstalled = NO;

#pragma mark - 日志（写在 App 自己沙盒 Documents，SSH 可取）

static NSString *gLogPath = nil;

static void RKWLog(NSString *fmt, ...) {
    if (!gLogPath) {
        gLogPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/rkwetype.log"];
    }
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%.3f] %@\n",
                      [NSDate date].timeIntervalSince1970, msg];
    @autoreleasepool {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:gLogPath error:nil];
        if ([attr[NSFileSize] unsignedLongLongValue] > 2ull * 1024 * 1024) {
            [[NSData data] writeToFile:gLogPath atomically:YES];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
        if (!fh) {
            [line writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

#pragma mark - 请求判读

// 键盘侧写的是「请求时刻」的 Unix 秒。60 秒内的请求都算本轮（TrollOpen 拉起偶尔要等 1~2s）。
// 读完即清，保证一次请求只服务一次激活。
static BOOL RKWTakeRequest(void) {
    if (!gReqToken) return NO;
    uint64_t v = 0;
    if (notify_get_state(gReqToken, &v) != NOTIFY_STATUS_OK || v == 0) return NO;
    int64_t now = (int64_t)time(NULL);
    int64_t req = (int64_t)v;
    if (req > now + 5) return NO;            // 时钟乱跳，当作无请求
    if (now - req > 60) {                    // 过期请求：清掉
        notify_set_state(gReqToken, 0);
        return NO;
    }
    notify_set_state(gReqToken, 0);          // 一次性消费
    RKWLog(@"取到 pip 请求（%.0fs 前）", (double)(now - req));
    return YES;
}

#pragma mark - UIScene.activationState 伪装（只在建 pip 窗口期）

static void RKWInstallSceneHook(void) {
    if (gHookInstalled) return;
    Class cls = objc_getClass("UIScene");
    if (!cls) { RKWLog(@"UIScene 不存在，跳过伪装"); return; }
    SEL sel = sel_registerName("activationState");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { RKWLog(@"UIScene 无 activationState"); return; }
    IMP orig = method_getImplementation(m);
    IMP newImp = imp_implementationWithBlock(^NSInteger(id self) {
        // ⛔ 只读静态变量 + 调原实现，禁止任何 UIKit 调用（防递归崩溃）
        NSInteger v = ((NSInteger (*)(id, SEL))orig)(self, sel);
        if (gFakeForeground && v != UISceneActivationStateForegroundActive) {
            return (NSInteger)UISceneActivationStateForegroundActive;
        }
        return v;
    });
    method_setImplementation(m, newImp);
    gHookInstalled = YES;
    RKWLog(@"已安装 UIScene.activationState 伪装（窗口期内生效）");
}

#pragma mark - 真正建 PiP（调用链来自 wcvoicekeep，已实机验证）

static id RKWPipManager(void) {
    Class c = objc_getClass("WBVoiceInputPIPManager");
    if (!c) return nil;
    SEL s = sel_registerName("sharedInstance");
    if (![c respondsToSelector:s]) return nil;
    return ((id (*)(Class, SEL))objc_msgSend)(c, s);
}

static BOOL RKWPipIsActive(id mgr) {
    SEL s = sel_registerName("isActive");
    if (!mgr || ![mgr respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, s);
}

// 门控开关在 WBVoiceInputManager 上（不在 Policy 上）——wcvoicekeep 最早死在这里
static void RKWOpenGate(void) {
    Class c = objc_getClass("WBVoiceInputManager");
    if (!c) { RKWLog(@"WBVoiceInputManager 不存在（门控无法打开）"); return; }
    SEL shared = sel_registerName("sharedInstance");
    if (![c respondsToSelector:shared]) return;
    id vm = ((id (*)(Class, SEL))objc_msgSend)(c, shared);
    if (!vm) return;
    SEL setMode = sel_registerName("setRecordingStandbyMode:");
    SEL updMode = sel_registerName("updateRecordingStandbyMode:");
    if ([vm respondsToSelector:setMode])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(vm, setMode, 1);
    if ([vm respondsToSelector:updMode])
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(vm, updMode, 1);
}

static void RKWEngageOnce(id mgr, int attempt) {
    RKWOpenGate();

    SEL isSetup  = sel_registerName("isSetup");
    SEL setup    = sel_registerName("setup");
    SEL setStandby = sel_registerName("setStandbyPlaybackStateEnabled:");
    SEL prepare  = sel_registerName("preparePictureInPictureForStandby");
    SEL startSel = sel_registerName("startWithCompletionHandler:");

    BOOL vSetup = [mgr respondsToSelector:isSetup]
                    ? ((BOOL (*)(id, SEL))objc_msgSend)(mgr, isSetup) : NO;
    if (!vSetup && [mgr respondsToSelector:setup]) {
        RKWLog(@"#%d 调 setup（建 pipController/sourceView/contentVC）", attempt);
        ((void (*)(id, SEL))objc_msgSend)(mgr, setup);
    }
    if ([mgr respondsToSelector:setStandby])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(mgr, setStandby, YES);

    if (![mgr respondsToSelector:prepare]) {
        RKWLog(@"#%d 没有 preparePictureInPictureForStandby", attempt);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(mgr, prepare);
    RKWLog(@"#%d prepare 已调用", attempt);

    if (![mgr respondsToSelector:startSel]) {
        RKWLog(@"#%d 没有 startWithCompletionHandler:", attempt);
        return;
    }
    // 回调体不读入参（防真实签名是 ^(void) 时崩），只在里面再核一次 isActive
    void (^completion)(BOOL) = ^(BOOL ok) {
        RKWLog(@"#%d start 回调 ok=%d isActive=%d（窗口期内）",
               attempt, (int)ok, (int)RKWPipIsActive(mgr));
    };
    ((void (*)(id, SEL, id))objc_msgSend)(mgr, startSel, completion);
    RKWLog(@"#%d startWithCompletionHandler: 已发出", attempt);
}

#pragma mark - 触发

static void RKWTrigger(NSString *why) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (!RKWTakeRequest()) {
                RKWLog(@"%@ -> 无 pip 请求，跳过（不打扰）", why);
                return;
            }
            id mgr = RKWPipManager();
            if (!mgr) { RKWLog(@"%@ -> WBVoiceInputPIPManager 不可用", why); return; }
            if (RKWPipIsActive(mgr)) {
                RKWLog(@"%@ -> pip 已经活着，跳过", why);
                return;
            }
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            if (now - gLastEngage < 1.5) {
                RKWLog(@"%@ -> 冷却中（%.1fs），跳过", why, now - gLastEngage);
                return;
            }
            gLastEngage = now;

            RKWLog(@"%@ -> 开始建 pip", why);
            gFakeForeground = YES;
            RKWInstallSceneHook();
            RKWEngageOnce(mgr, 0);

            // 重试：冷启动首拍偶发失败（wcvoicekeep 实测），0.6s / 1.4s 各补一次
            for (NSNumber *secs in @[@(0.6), @(1.4)]) {
                double d = [secs doubleValue];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (RKWPipIsActive(mgr)) return;
                    RKWLog(@"t=%.1fs 仍未 active -> 重试", d);
                    RKWEngageOnce(mgr, (int)(d * 10));
                });
            }
            // 伪装窗口 2.5s 后关闭（够 AVKit 异步检查完）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                gFakeForeground = NO;
                RKWLog(@"伪装窗口关闭（isActive=%d）", (int)RKWPipIsActive(mgr));
            });
        }
    });
}

#pragma mark - 初始化

__attribute__((constructor)) static void RKWetypeHostInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.tencent.wetype"]) return;

        RKWLog(@"==== RKWetypePipBuild 载入 bid=%@ home=%@", bid, NSHomeDirectory());
        uint32_t st = notify_register_check(kPipReqName, &gReqToken);
        RKWLog(@"notify 注册 token=%d st=%u", gReqToken, st);
        RKWLog(@"类探测 PIPManager=%d VoiceInputManager=%d",
               objc_getClass("WBVoiceInputPIPManager") != nil,
               objc_getClass("WBVoiceInputManager") != nil);

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            RKWLog(@"EVT DidBecomeActive");
            RKWTrigger(@"becomeActive");
        }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            RKWLog(@"EVT DidFinishLaunching");
            RKWTrigger(@"didFinishLaunching");
        }];

        // 前台时能直接收到 post（挂起时收不到，靠上面 get_state 兜）
        int tok = 0;
        notify_register_dispatch(kPipReqName, &tok, dispatch_get_main_queue(), ^(int t) {
            RKWLog(@"EVT darwin pipreq");
            RKWTrigger(@"darwin");
        });

        RKWLog(@"初始化完成");
    }
}
