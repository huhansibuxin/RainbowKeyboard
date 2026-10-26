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
// 2.3.61：建 pip 的**回执**通道（主 App -> 键盘侧）。
// 为什么必须要它：键盘侧的 `pictureInPictureActive` 是主 App 通过 IPC **懒上报**的状态位，
// 主 App 本地 pip 已经 active，键盘侧仍可能十几秒都是 0（2.3.60 实测：主 App +0.16s
// isActive=1，键盘侧直到 +9.25s 才看到 pip=1，中间 3.0s 就被兜底误判「pip 没建起来」）。
// ⇒ 谁真的建起来了，谁就直接喊一声，键盘侧不必猜。
static const char *const kPipOkName  = "com.huhansibuxin.rk.pipok";

static int            gReqToken = 0;
static int            gOkToken  = 0;
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

#pragma mark - 回执：告诉键盘侧「pip 真的活了」

// 只在 pip 确实 active 时发。键盘侧收到就当 pip=1，直接免跳、不做任何回跳。
static void RKWPostOk(NSString *why) {
    if (!gOkToken) {
        if (notify_register_check(kPipOkName, &gOkToken) != NOTIFY_STATUS_OK || !gOkToken) return;
    }
    uint64_t ts = (uint64_t)time(NULL);
    notify_set_state(gOkToken, ts);
    notify_post(kPipOkName);
    RKWLog(@"回执 pip 已建 -> 键盘侧（%@）", why);
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

// ⭐⭐ 2.3.62 核心修正：`isActive` 是**不可信**的。
// 实测（rkwetype_2361.log）：原生在冷启动建成功一次之后，`isActive` 从 1793037564 起
// 恒为 1，直到进程结束；而键盘侧的 `pictureInPictureActive` 同期全是 0 —— 说明它记的是
// 「待机 pip 通道开过」而不是「pip 此刻真的在显示」。用它的后果是：
//   ① 每次都判"已经活着"⇒ 一次都不重建 ⇒ 键盘侧永远 pip=0 ⇒ 每次点语音都要跳；
//   ② 还往键盘侧发假回执，把键盘侧也骗成"免跳"，连安全网都不走。
// 真判据只能是 pipController 的 AVKit 原生属性（只有它反映真实显示态）。
static id RKWPipController(id mgr) {
    if (!mgr) return nil;
    SEL s = sel_registerName("pipController");
    if (![mgr respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(mgr, s);
}

static BOOL RKWRealPipActive(id mgr) {
    id ctl = RKWPipController(mgr);
    if (ctl) {
        SEL s = sel_registerName("isPictureInPictureActive");
        if ([ctl respondsToSelector:s])
            return ((BOOL (*)(id, SEL))objc_msgSend)(ctl, s);
    }
    return NO;   // 取不到真实状态就一律当作「没有」⇒ 允许重建，绝不静默跳过
}

#pragma mark - 通用取值助手（全部先 respondsToSelector 再调，防崩）

static BOOL RKWMsgBool(id obj, const char *name) {
    if (!obj) return NO;
    SEL s = sel_registerName(name);
    if (![obj respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, s);
}

// ⭐ 2.3.63：pip 生命周期里的灰度状态。
// 2.3.62 实测：主 App `realPip=1` 持续 100 秒，键盘侧 `pictureInPictureActive` 却一直是 0
// ⇒ 说明 pipController 说"active"并不等于"键盘侧该认为可用"。AVKit 的 `isPictureInPictureActive`
// 在 pip 被系统收起（stashed）时**仍为 YES**，而微信自己的上报会看 `isStashedOrUnderLock` /
// `visiblePiPModeActive` 再决定要不要报 1。所以必须把这三个位一起打出来，才能分清
// 「没建成」和「建成了但被收起」——这两者的修法完全不同。
static void RKWLogDeep(NSString *tag) {
    id mgr = RKWPipManager();
    id ctl = RKWPipController(mgr);
    BOOL sysSupp = NO;
    Class avc = objc_getClass("AVPictureInPictureController");
    if (avc) {
        SEL s = sel_registerName("isPictureInPictureSupported");
        if ([avc respondsToSelector:s]) sysSupp = ((BOOL (*)(Class, SEL))objc_msgSend)(avc, s);
    }
    RKWLog(@"%@ ctlActive=%d ctlPossible=%d mgrVisible=%d stashed=%d appState=%ld sysSupp=%d",
           tag,
           RKWMsgBool(ctl, "isPictureInPictureActive"),
           RKWMsgBool(ctl, "isPictureInPicturePossible"),
           RKWMsgBool(mgr, "visiblePiPModeActive"),
           RKWMsgBool(mgr, "isStashedOrUnderLock"),
           (long)[[UIApplication sharedApplication] applicationState],
           (int)sysSupp);
}

// 建 pip 前的现场快照：一次看清 start 到底卡在哪（scene 不 active / setup 没做 / 窗口没就绪）。
static void RKWLogState(NSString *tag) {
    id mgr = RKWPipManager();
    BOOL vSetup = NO, vSupp = NO;
    if (mgr) {
        SEL s1 = sel_registerName("isSetup"), s2 = sel_registerName("isSupported");
        if ([mgr respondsToSelector:s1]) vSetup = ((BOOL (*)(id, SEL))objc_msgSend)(mgr, s1);
        if ([mgr respondsToSelector:s2]) vSupp  = ((BOOL (*)(id, SEL))objc_msgSend)(mgr, s2);
    }
    NSInteger appSt = (NSInteger)[[UIApplication sharedApplication] applicationState];
    NSInteger sceneSt = -1;
    for (UIScene *sc in [[UIApplication sharedApplication] connectedScenes].allObjects) {
        // 取真实值（gFakeForeground 可能正在伪装）
        sceneSt = (NSInteger)sc.activationState;
        if (sceneSt != UISceneActivationStateUnattached) break;
    }
    RKWLog(@"%@ 状态: isActive=%d realPip=%d isSetup=%d isSupported=%d pipCtl=%d appState=%ld scene=%ld fake=%d",
           tag, (int)RKWPipIsActive(mgr), (int)RKWRealPipActive(mgr), (int)vSetup, (int)vSupp,
           RKWPipController(mgr) != nil, (long)appSt, (long)sceneSt, (int)gFakeForeground);
}

// 一次性 dump PIPManager 的方法表 —— 主 App 二进制 FairPlay 加密、静态看不到，
// 靠这里拿到「有没有 stop/teardown/reset」这类能把脏状态掰回来的选择子。
static void RKWLogMethods(Class c, const char *name) {
    if (!c) return;
    unsigned int n = 0;
    Method *ms = class_copyMethodList(c, &n);
    NSMutableString *s = [NSMutableString string];
    for (unsigned int i = 0; i < n; i++) {
        [s appendFormat:@"%s ", sel_getName(method_getName(ms[i]))];
    }
    free(ms);
    RKWLog(@"%s 方法(%u): %@", name, n, s);
}

// 2.3.63：把几个关键选择子的**类型编码**打出来。
// 起因：`startWithCompletionHandler:` 的回调 ok 一直打出 -1327811635 这种垃圾值，
// 说明我们按 ^(BOOL) 去读参数读错了（真实很可能是 ^(NSError*) 或 ^(NSInteger code)）。
// 编码是运行时事实，比自己猜签名可靠：`v24@0:8@?16` 里的 @? = block，后面跟 block 的签名。
static void RKWLogEncodings(Class c, const char *name) {
    if (!c) return;
    const char *sels[] = {
        "startWithCompletionHandler:",
        "startWithPlaybackMode:completionHandler:",
        "activateVisiblePiPModeWithReason:",
        "prepareVisiblePiPContent",
        "preparePictureInPictureForVoiceCapture",
        "preparePictureInPictureForStandby",
        "pictureInPictureController:failedToStartPictureInPictureWithError:",
        "handleInternalVisibilityStateChanged:reason:",
        "updatePublishedPiPActiveStateWithSource:",
        "enterStoppingStateFromSource:",
        "isStashedOrUnderLock",
        "visiblePiPModeActive",
        NULL
    };
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; sels[i]; i++) {
        Method m = class_getInstanceMethod(c, sel_registerName(sels[i]));
        [s appendFormat:@"%s=%s ", sels[i], m ? method_getTypeEncoding(m) : "(无)"];
    }
    RKWLog(@"%s 编码: %@", name, s);
}

#pragma mark - pip 生命周期埋点（2.3.63）

// 只 hook 参数签名确定是 id 的几个 delegate（其余选择子签名未知，盲传会崩，
// 先靠 RKWLogEncodings 把编码打出来再决定下一版要不要接）。
static void RKWInstallLifecycleHooks(void) {
    Class cls = objc_getClass("WBVoiceInputPIPManager");
    if (!cls) return;

    {
        SEL sel = sel_registerName("pictureInPictureControllerWillStartPictureInPicture:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^(id me, id ctl) {
                RKWLog(@"◆ willStart");
                ((void (*)(id, SEL, id))o)(me, sel, ctl);
            }));
        }
    }
    {
        SEL sel = sel_registerName("pictureInPictureControllerDidStartPictureInPicture:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^(id me, id ctl) {
                RKWLog(@"◆★ didStart（真的起来了）");
                ((void (*)(id, SEL, id))o)(me, sel, ctl);
                RKWLogDeep(@"didStart 后");
            }));
        }
    }
    {
        SEL sel = sel_registerName("pictureInPictureController:failedToStartPictureInPictureWithError:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^(id me, id ctl, id err) {
                RKWLog(@"◆✗ failedToStart err=%@", err);
                ((void (*)(id, SEL, id, id))o)(me, sel, ctl, err);
            }));
        }
    }
    {
        SEL sel = sel_registerName("pictureInPictureControllerWillStopPictureInPicture:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^(id me, id ctl) {
                RKWLog(@"◆ willStop");
                ((void (*)(id, SEL, id))o)(me, sel, ctl);
                RKWLogDeep(@"willStop 后");
            }));
        }
    }
    {
        SEL sel = sel_registerName("pictureInPictureControllerDidStopPictureInPicture:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            IMP o = method_getImplementation(m);
            method_setImplementation(m, imp_implementationWithBlock(^(id me, id ctl) {
                RKWLog(@"◆✗ didStop");
                ((void (*)(id, SEL, id))o)(me, sel, ctl);
                RKWLogDeep(@"didStop 后");
            }));
        }
    }
    RKWLog(@"pip 生命周期埋点已安装");
}

// 建完之后的灰度轨迹：pip 若"起来了又被收起"，会在这里露出 stashed=1 / mgrVisible=0。
static void RKWStartTrace(id mgr) {
    for (NSNumber *secs in @[@(0.4), @(0.9), @(1.5), @(2.2), @(3.0), @(4.5), @(6.5), @(9.0), @(12.0)]) {
        double d = [secs doubleValue];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RKWLogDeep([NSString stringWithFormat:@"[trace +%.1fs]", d]);
        });
    }
}

#pragma mark - 内部链路观察器（2.3.64）

// 只观察、不改行为。参数一律按 uintptr_t 接（Objective-C 对象指针和 NSInteger 在
// arm64 上是同一个 x 寄存器宽度，所以**无论真实签名是 id 还是整数都安全**），
// 并且只在返回类型是 void 时才挂 —— 否则替换掉一个返回 BOOL 的 IMP，调用方会读到垃圾返回值。
static int gRKWOBS = 0;

static void RKWObserve(Class cls, const char *name, int nargs) {
    if (!cls) return;
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { RKWLog(@"观察点缺失 %s", name); return; }
    const char *enc = method_getTypeEncoding(m);
    if (enc[0] != 'v') { RKWLog(@"观察点跳过 %s（返回非 void：%s）", name, enc); return; }
    IMP o = method_getImplementation(m);
    IMP nw = NULL;
    if (nargs == 0) {
        nw = imp_implementationWithBlock(^(id me) {
            RKWLog(@"⇒ %s", name);
            ((void (*)(id, SEL))o)(me, sel);
        });
    } else if (nargs == 1) {
        nw = imp_implementationWithBlock(^(id me, uintptr_t a) {
            RKWLog(@"⇒ %s(a=%lld / %p)", name, (long long)a, (void *)a);
            ((void (*)(id, SEL, uintptr_t))o)(me, sel, a);
        });
    } else if (nargs == 2) {
        nw = imp_implementationWithBlock(^(id me, uintptr_t a, uintptr_t b) {
            RKWLog(@"⇒ %s(a=%lld, b=%lld)", name, (long long)a, (long long)b);
            ((void (*)(id, SEL, uintptr_t, uintptr_t))o)(me, sel, a, b);
        });
    } else {
        RKWLog(@"观察点跳过 %s（参数过多）", name);
        return;
    }
    method_setImplementation(m, nw);
    gRKWOBS++;
}

static void RKWInstallObservers(void) {
    Class c = objc_getClass("WBVoiceInputPIPManager");
    if (!c) return;
    // 谁在何时把 pip 拉起来/停掉/改可见模式 —— 2.3.63 里我们 4 次 start 一个回调都没等到，
    // 只能从这里看它内部到底走到哪一步。
    RKWObserve(c, "startWithPlaybackMode:completionHandler:", 2);
    RKWObserve(c, "activateVisiblePiPModeWithReason:", 1);
    RKWObserve(c, "enterStoppingStateFromSource:", 1);
    RKWObserve(c, "updatePublishedPiPActiveStateWithSource:", 1);
    RKWObserve(c, "handleInternalVisibilityStateChanged:reason:", 2);
    RKWObserve(c, "prepareVisiblePiPContent", 0);
    RKWObserve(c, "startVisibleAnimationIfNeeded", 0);
    RKWObserve(c, "stopVisibleAnimation", 0);
    RKWObserve(c, "performForceStartAndConsumePendingHandlerWithToken:", 1);
    RKWObserve(c, "scheduleStartConfirmRetryWithToken:deadline:", 2);
    RKWObserve(c, "consumePendingStartConfirmFromSource:", 1);
    RKWObserve(c, "logForegroundPiPStartStateWithReason:", 1);
    RKWObserve(c, "beginAutomaticStashProtectionIfNeeded", 0);
    RKWObserve(c, "notifyDelegateDidFailToStart", 0);
    RKWLog(@"内部链路观察器已装 %d 个", gRKWOBS);
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

    // ⭐ 2.3.64 实验：先激活「可见 pip 模式」再 start。
    // 依据（2.3.63 实测）：start 发出后**一个 delegate 回调都没有** —— 连 willStart 都没有，
    // 3 秒后超时返回失败；而同一时刻 mgr 的 visiblePiPModeActive 全程是 0。
    // 这不是「被拒绝」（被拒绝会立刻走 failedToStart），而是「被挂着等」。
    // 内容层不进可见模式，AVKit 就没有东西可抓 ⇒ 只能挂。所以先把可见模式点起来。
    if (attempt == 0) {
        SEL act = sel_registerName("activateVisiblePiPModeWithReason:");
        if ([mgr respondsToSelector:act]) {
            @try {
                ((void (*)(id, SEL, uintptr_t))objc_msgSend)(mgr, act, (uintptr_t)0);
                RKWLog(@"#%d activateVisiblePiPModeWithReason(0) 已调用", attempt);
            } @catch (NSException *e) {
                RKWLog(@"#%d activate 抛异常 %@", attempt, e);
            }
        } else {
            RKWLog(@"#%d 没有 activateVisiblePiPModeWithReason:", attempt);
        }
    }

    if (![mgr respondsToSelector:startSel]) {
        RKWLog(@"#%d 没有 startWithCompletionHandler:", attempt);
        return;
    }
    // 回调体不读入参（防真实签名是 ^(void) 时崩），只在里面再核一次**真实**状态。
    // ⚠️ 实测入参不可信：ok 打出来是 -1327811635 这种垃圾（签名大概是 ^(NSError*) 而非 ^(BOOL)），
    //    所以判据一律用 pipController.isPictureInPictureActive，绝不看 ok。
    void (^completion)(BOOL) = ^(BOOL ok) {
        BOOL real = RKWRealPipActive(mgr);
        RKWLog(@"#%d start 回调 ok=%d realPip=%d isActive=%d",
               attempt, (int)ok, (int)real, (int)RKWPipIsActive(mgr));
        if (real) RKWPostOk(@"start 回调");
    };
    ((void (*)(id, SEL, id))objc_msgSend)(mgr, startSel, completion);
    RKWLog(@"#%d startWithCompletionHandler: 已发出", attempt);
}

#pragma mark - 触发

static void RKWTrigger(NSString *why, double delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (!RKWTakeRequest()) {
                RKWLog(@"%@ -> 无 pip 请求，跳过（不打扰）", why);
                return;
            }
            id mgr = RKWPipManager();
            if (!mgr) { RKWLog(@"%@ -> WBVoiceInputPIPManager 不可用", why); return; }

            RKWLogState([why stringByAppendingString:@" 建前"]);

            // ⭐ 2.3.62：只有 pipController 真实显示中才算"已经活着"。
            //   2.3.61 用 mgr.isActive 判，那个位在原生建过一次之后恒 1（实测 12 分钟不落），
            //   导致我们一次都不重建、还发假回执 ⇒ 键盘侧永远 pip=0 ⇒ 每次都跳。
            if (RKWRealPipActive(mgr)) {
                RKWLog(@"%@ -> pip 真的在显示，回执给键盘侧", why);
                RKWPostOk(@"真的 active");
                return;
            }
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            // 1.2s 冷却：becomeActive 与 darwin 两个入口会同时到达，别一轮里重复 start
            // （wcvoicekeep 注释留过教训：一次激活里连发 4 次 start 会把 pipController 搞乱）。
            if (now - gLastEngage < 1.2) {
                RKWLog(@"%@ -> 冷却中（%.1fs），跳过", why, now - gLastEngage);
                return;
            }
            gLastEngage = now;

            RKWLog(@"%@ -> 开始建 pip（isActive=%d 但 realPip=0 ⇒ 视为脏状态，重建）",
                   why, (int)RKWPipIsActive(mgr));
            gFakeForeground = YES;
            RKWInstallSceneHook();
            RKWStartTrace(mgr);
            RKWEngageOnce(mgr, 0);

            // ⛔ 2.3.64：重试从 4 次砍到 1 次。
            //   2.3.63 实测：4 次 start 全部在 pipController 里排队，3 秒后一起超时失败，
            //   一个 delegate 回调都没触发 —— 说明重试**不会**增加成功率，只会把状态机搅乱。
            //   留着这 1 次是为了覆盖「首拍 window 还没就绪」的冷启动现场。
            for (NSNumber *secs in @[@(0.7)]) {
                double d = [secs doubleValue];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (RKWRealPipActive(mgr)) {
                        RKWLog(@"t=%.1fs 真的 active -> 回执", d);
                        RKWPostOk(@"retry 前已成");
                        return;
                    }
                    RKWLog(@"t=%.1fs 仍未 active（isActive=%d）-> 重试",
                           d, (int)RKWPipIsActive(mgr));
                    RKWEngageOnce(mgr, (int)(d * 10));
                });
            }
            // 伪装窗口 3.0s 后关闭（够 AVKit 异步检查完）；此时若成了再补一次回执。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                gFakeForeground = NO;
                BOOL real = RKWRealPipActive(mgr);
                RKWLog(@"伪装窗口关闭（realPip=%d isActive=%d）", (int)real, (int)RKWPipIsActive(mgr));
                if (real) RKWPostOk(@"窗口关闭时已活");
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
        uint32_t st2 = notify_register_check(kPipOkName, &gOkToken);
        RKWLog(@"notify 注册 reqToken=%d st=%u okToken=%d st=%u",
               gReqToken, st, gOkToken, st2);
        RKWLog(@"类探测 PIPManager=%d VoiceInputManager=%d",
               objc_getClass("WBVoiceInputPIPManager") != nil,
               objc_getClass("WBVoiceInputManager") != nil);
        // 主 App 二进制加密、静态分析看不到方法表 ⇒ 运行时 dump 一次（找 stop/reset/teardown）
        RKWLogMethods(objc_getClass("WBVoiceInputPIPManager"), "WBVoiceInputPIPManager");
        RKWLogMethods(objc_getClass("WBVoiceInputManager"), "WBVoiceInputManager");
        RKWLogEncodings(objc_getClass("WBVoiceInputPIPManager"), "WBVoiceInputPIPManager");
        RKWInstallLifecycleHooks();
        RKWInstallObservers();
        RKWLogDeep(@"载入时");

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            RKWLog(@"EVT DidBecomeActive");
            // ⭐ 2.3.62：延 0.5s 再建 —— 激活通知到达时 window/scene 还没完全就绪，
            //   立刻 start 会把 pipController 绑到一个无效 sourceView 上（实测三次全 isActive=0）。
            //   0.5s 后小窗/前台已稳定，AVKit 的 scene 检查也能过。
            RKWTrigger(@"becomeActive", 0.5);
        }];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            // ⛔ 2.3.62 明确**不在** DidFinishLaunching 建 pip：
            //   那时 App 界面还没起来，start 必失败（实测 477.907 三次全 isActive=0），
            //   而且会把请求提前消费掉，等真正的 DidBecomeActive 就"无请求"了 —— 白瞎一轮。
            RKWLog(@"EVT DidFinishLaunching（不建 pip，等 DidBecomeActive）");
        }];

        // 前台时能直接收到 post（挂起时收不到，靠上面 get_state 兜）
        int tok = 0;
        notify_register_dispatch(kPipReqName, &tok, dispatch_get_main_queue(), ^(int t) {
            RKWLog(@"EVT darwin pipreq");
            RKWTrigger(@"darwin", 0.2);
        });

        RKWLog(@"初始化完成");
    }
}
