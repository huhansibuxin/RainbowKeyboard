#pragma once
#import <Foundation/Foundation.h>

// Shared by Objective-C (.m) and Objective-C++ (Logos .xm).
#ifdef __cplusplus
extern "C" {
#endif

// Main-thread only. Session-local state, no text capture or disk writes.
void RKAdaptiveSetEnabled(BOOL enabled);
void RKAdaptiveNoteInput(void);
NSInteger RKAdaptiveLevel(void);
BOOL RKAdaptiveFastInput(void);

#ifdef __cplusplus
}
#endif
