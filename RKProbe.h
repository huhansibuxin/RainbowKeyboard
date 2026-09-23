//
//  RKProbe.h
//  RainbowKeyboard -- performance probe. Diagnostic build only.
//
//  It exists to answer one question with numbers instead of reasoning: does reusing the
//  wave layers actually take work off the keystroke path, and how much?
//
//  Every press is classified as cold or warm. A cold press is one that had to build at
//  least one key group, so it paid the old per-press cost (layers, bezier paths, shape
//  layers); a warm press drew entirely from layers that were already built. The two are
//  averaged separately and written to one line, so a single line carries both sides of
//  the comparison: warm layers=0 with a small arm time, next to the cold arm time.
//
//  Written to rkperf.log inside this keyboard extension's own container:
//      find /rootfs/var/mobile/Containers/Data/PluginKitPlugin -name rkperf.log
//
//  Timing only covers work this tweak does synchronously. The file write happens after
//  the clock is read and is not charged to anything.
//
//  Set RK_PROBE_ENABLED to 0 to take it out: the types stay (call sites name them) but
//  every macro becomes a no-op, so the probe emits nothing and costs nothing. It is
//  header-only on purpose, so enabling and disabling is a one-line change with no
//  Makefile edit. Include it from exactly one translation unit -- the state below is
//  file-static.
//

#ifndef RK_PROBE_ENABLED
#define RK_PROBE_ENABLED 1
#endif

// Counters filled in by whichever code path draws a press.
typedef struct {
    unsigned keys;          // key groups armed by this press
    unsigned groupsNew;     // groups built from scratch (layer + path allocation)
    unsigned groupsReused;  // groups that were already built
    unsigned layersNew;     // layers created
    unsigned pathsNew;      // bezier paths built
} RKProbeCounts;

#if RK_PROBE_ENABLED

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>

typedef struct {
    unsigned index;
    BOOL cold;
    unsigned keys, groupsNew, groupsReused, layersNew, pathsNew;
    double armSec;      // layer arming only
    double pressSec;    // the whole press path
    double gateSec;     // layout gate
    const char *note;   // why this press had to build, when that is known
} RKProbePress;

// Per-press detail is buffered and flushed, so the file write is not one syscall per
// keystroke. The first presses flush immediately: they are the ones looked at first.
#define RK_PROBE_RING 8
#define RK_PROBE_EAGER 24
#define RK_PROBE_MAX_BYTES (4u * 1024u * 1024u)

static RKProbePress RKProbeRing[RK_PROBE_RING];
static unsigned RKProbeRingCount;
static unsigned RKProbeIndex;
static unsigned RKProbeWarmN, RKProbeColdN;
static double RKProbeWarmArm, RKProbeWarmPress, RKProbeColdArm, RKProbeColdPress;
static double RKProbeMaxPress;
static unsigned RKProbeLayersTotal, RKProbePathsTotal;
static double RKProbeGateSec;
static const char *RKProbePendingNote;
static unsigned long RKProbeBytesWritten;

static inline const char *RKProbePath(void) {
    static char path[1024];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *tmp = NSTemporaryDirectory();
        snprintf(path, sizeof(path), "%s/rkperf.log", tmp.UTF8String ?: "/tmp");
    });
    return path;
}

// Wall clock used for the measurements. Cheaper than CFAbsoluteTimeGetCurrent and
// monotonic, so a clock adjustment cannot produce a negative interval.
static inline double RKProbeTic(void) { return CACurrentMediaTime(); }

static inline void RKProbeNoteGate(double sec) { RKProbeGateSec = sec; }
static inline void RKProbeNoteNote(const char *note) { RKProbePendingNote = note; }

static inline void RKProbeFlush(void) {
    const char *path = RKProbePath();
    FILE *f = fopen(path, "a");
    if (!f) return;
    if (RKProbeBytesWritten > RK_PROBE_MAX_BYTES) {
        // Rotation without losing the name the user is told to look for.
        fclose(f);
        f = fopen(path, "w");
        RKProbeBytesWritten = 0;
        if (!f) return;
        fprintf(f, "RKPERF rotated (previous file exceeded %u bytes)\n", RK_PROBE_MAX_BYTES);
    }
    unsigned n = RKProbeWarmN + RKProbeColdN;
    fprintf(f, "RKPERF sum n=%u warm=%u arm=%.1fus press=%.1fus | cold=%u arm=%.1fus press=%.1fus | peak=%.1fus layers=%u paths=%u\n",
            n, RKProbeWarmN,
            RKProbeWarmN ? RKProbeWarmArm / RKProbeWarmN : 0.0,
            RKProbeWarmN ? RKProbeWarmPress / RKProbeWarmN : 0.0,
            RKProbeColdN,
            RKProbeColdN ? RKProbeColdArm / RKProbeColdN : 0.0,
            RKProbeColdN ? RKProbeColdPress / RKProbeColdN : 0.0,
            RKProbeMaxPress, RKProbeLayersTotal, RKProbePathsTotal);
    for (unsigned i = 0; i < RKProbeRingCount; i++) {
        RKProbePress *p = &RKProbeRing[i];
        fprintf(f, "RKPERF press#%u %s keys=%u new=%u reuse=%u layers=%u paths=%u arm=%.1fus press=%.1fus gate=%.2fus%s%s\n",
                p->index, p->cold ? "cold" : "warm", p->keys, p->groupsNew, p->groupsReused,
                p->layersNew, p->pathsNew, p->armSec * 1e6, p->pressSec * 1e6, p->gateSec * 1e6,
                p->note ? " note=" : "", p->note ? p->note : "");
        RKProbeBytesWritten += 160;
    }
    fclose(f);
    RKProbeRingCount = 0;
    RKProbePendingNote = NULL;
}

static inline void RKProbeRecordWave(NSInteger style, double armSec, double pressSec, RKProbeCounts c) {
    RKProbePress *p = &RKProbeRing[RKProbeRingCount++];
    p->index = ++RKProbeIndex;
    p->cold = c.groupsNew > 0;
    p->keys = c.keys;
    p->groupsNew = c.groupsNew;
    p->groupsReused = c.groupsReused;
    p->layersNew = c.layersNew;
    p->pathsNew = c.pathsNew;
    p->armSec = armSec;
    p->pressSec = pressSec;
    p->gateSec = RKProbeGateSec;
    RKProbeGateSec = 0;
    p->note = RKProbePendingNote;
    RKProbePendingNote = NULL;
    if (p->cold) { RKProbeColdN++;  RKProbeColdArm  += armSec; RKProbeColdPress  += pressSec; }
    else         { RKProbeWarmN++;  RKProbeWarmArm  += armSec; RKProbeWarmPress  += pressSec; }
    if (pressSec > RKProbeMaxPress) RKProbeMaxPress = pressSec;
    RKProbeLayersTotal += c.layersNew;
    RKProbePathsTotal += c.pathsNew;
    if (RKProbeRingCount >= RK_PROBE_RING || (RKProbeWarmN + RKProbeColdN) <= RK_PROBE_EAGER)
        RKProbeFlush();
}

#define RKProbeCount(_counts, _field, _n) do { (_counts)->_field += (unsigned)(_n); } while (0)

#else  // RK_PROBE_ENABLED

#define RKProbeTic() 0.0
#define RKProbeNoteGate(_sec) do { } while (0)
#define RKProbeNoteNote(_note) do { } while (0)
#define RKProbeRecordWave(_style, _arm, _press, _counts) do { } while (0)
// Still touches the struct, so a disabled build cannot warn about it being unused.
#define RKProbeCount(_counts, _field, _n) do { (_counts)->_field += 0u; } while (0)

#endif // RK_PROBE_ENABLED
