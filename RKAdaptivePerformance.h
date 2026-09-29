#pragma once
#import <Foundation/Foundation.h>

// 智能流畅模式（运行时自动降档：降光效数量/时长/半径、降候选栏帧率）已整体移除，
// 光效参数只由设置页里的值决定。因此：
//   RKAdaptiveLevel()      == 0   → number: / flag: 不做任何上限裁剪
//   RKAdaptiveFastInput()  == NO  → 光效/候选渐变不进入快速档
//
// 这两个谓词挂在**每次按键**的配置读取里（RainbowEffectView 的 number:/flag: 各读一次，
// 单次按键合计十余次），而本项目不开 LTO —— 写成跨编译单元的 extern 函数时，
// 每个调用点都是一次真实的 bl。改成头文件里的 static inline 常量后，编译器直接折叠成
// 常量，连 `if (level)` 这类分支一并消除，三个光效链路文件无需各自改动。
// 语义与原 RKAdaptivePerformanceOff.m 的空实现逐位一致。
static inline NSInteger RKAdaptiveLevel(void) { return 0; }
static inline BOOL RKAdaptiveFastInput(void) { return NO; }

// Shared by Objective-C (.m) and Objective-C++ (Logos .xm).
#ifdef __cplusplus
extern "C" {
#endif

// Main-thread only. Session-local state, no text capture or disk writes.
// 这两个入口带副作用（当前为空实现），且只在 %ctor 与每轮按键入口各调一次，
// 保持函数形式即可 —— 它们的调用频率与绘制热路径无关。
void RKAdaptiveSetEnabled(BOOL enabled);
void RKAdaptiveNoteInput(void);

#ifdef __cplusplus
}
#endif
