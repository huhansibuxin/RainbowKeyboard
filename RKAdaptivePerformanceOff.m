#import "RKAdaptivePerformance.h"

// 智能流畅模式（20Hz 帧间隔采样 → 自动降低光效数量/时长/半径）已按老板要求整体移除：
// 光效参数只由设置页里的值决定，不再有运行时自动降档。
//
// RKAdaptiveLevel / RKAdaptiveFastInput 已改为 RKAdaptivePerformance.h 里的
// static inline 常量（恒 0 / 恒 NO）—— 它们挂在每次按键的配置读取上，做成跨编译单元
// 函数时每个调用点都要付一次真实 bl，内联后直接被编译器折叠掉。
// 本文件因此只保留两个带副作用的入口，语义与原来的空实现一致：
//   RKAdaptiveSetEnabled()  → 空操作
//   RKAdaptiveNoteInput()   → 不再安装 CADisplayLink（零轮询）
//
// 上游 1.2.1 的光效链路文件（Tweak.xm / RainbowEffectView.m / CandidateGradient.xm）
// 会调用这几个入口，这里保留同名实现，使那三个文件可以逐字不改地使用。

void RKAdaptiveSetEnabled(BOOL enabled) {
    (void)enabled;
}

void RKAdaptiveNoteInput(void) {
}
