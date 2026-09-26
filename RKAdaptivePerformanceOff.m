#import "RKAdaptivePerformance.h"

// 智能流畅模式（20Hz 帧间隔采样 → 自动降低光效数量/时长/半径）已按老板要求整体移除：
// 光效参数只由设置页里的值决定，不再有运行时自动降档。
//
// 上游 1.2.1 的光效链路文件（Tweak.xm / RainbowEffectView.m / CandidateGradient.xm）
// 会调用下面四个函数，因此这里保留同名空实现——上游那三个文件可以逐字不改地使用。
// 语义等价于「自适应关闭且档位恒为 0」：
//   RKAdaptiveLevel()      == 0 → number:/flag: 不做任何上限裁剪
//   RKAdaptiveFastInput()  == NO → 光效/候选渐变不进入快速档
//   RKAdaptiveNoteInput()      → 不再安装 CADisplayLink（零轮询）

void RKAdaptiveSetEnabled(BOOL enabled) {
    (void)enabled;
}

void RKAdaptiveNoteInput(void) {
}

NSInteger RKAdaptiveLevel(void) {
    return 0;
}

BOOL RKAdaptiveFastInput(void) {
    return NO;
}
