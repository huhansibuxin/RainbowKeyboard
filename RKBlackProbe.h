#import <Foundation/Foundation.h>
#import <notify.h>

// 日志与诊断功能已整体移除（2.0.0）：以下探针一律空操作，
// 不再向 notifyd 发布任何计数，也不保留可读诊断状态。
// 保留函数签名是为了让既有调用点（PureBlackKeyboard.xm）零改动编译通过。
static inline int RKBlackProbeToken(BOOL weType) {
    (void)weType;
    return -1;
}

static inline uint64_t RKBlackProbeState(uint8_t flags, NSUInteger backgrounds, NSUInteger atlases,
                                        NSUInteger keyImages, NSUInteger weTypeKeys) {
    (void)flags; (void)backgrounds; (void)atlases; (void)keyImages; (void)weTypeKeys;
    return 0;
}

static inline NSDictionary *RKDecodeBlackProbe(uint64_t state) {
    (void)state;
    return @{@"available":@NO};
}

static inline int RKBlackSurfaceProbeToken(BOOL weType) {
    (void)weType;
    return -1;
}
static inline void RKPublishBlackSurfaceProbe(BOOL weType, NSUInteger draws, NSUInteger converted,
                                             NSUInteger suppressed, NSUInteger shapes, NSUInteger keyViews) {
    (void)weType; (void)draws; (void)converted; (void)suppressed; (void)shapes; (void)keyViews;
}

static inline int RKNativeStateProbeToken(void) {
    return -1;
}

static inline void RKPublishNativeStateProbe(uint8_t flags, NSUInteger traits, NSUInteger states,
                                              NSUInteger multiply, NSUInteger stretch) {
    (void)flags; (void)traits; (void)states; (void)multiply; (void)stretch;
}

static inline NSDictionary *RKReadBlackProbe(BOOL weType) {
    (void)weType;
    return @{@"available":@NO};
}
