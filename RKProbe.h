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
//  Written to rkperf.log inside the keyboard extension's own sandbox. The container UUID
//  is not stable, and a keyboard extension may be given only its own container, so the
//  location is resolved at runtime rather than hard-coded: TMPDIR first, then the home
//  container's Documents / Library/Caches / tmp, then /tmp as a last resort. Every candidate
//  is opened for append until one succeeds; the winner is recorded in the first line.
//
//      find /rootfs/var/mobile/Containers/Data/PluginKitPlugin -name rkperf.log
//      grep RKPERF "$(find /rootfs/var/mobile/Containers/Data/PluginKitPlugin -name rkperf.log | head -1)"
//
//  The file opens with a "boot" line carrying the pid and the resolved path. That line is
//  written when the dylib loads, before any keystroke, so its presence answers a question
//  the press lines cannot: whether this code is in the process at all. No boot line means
//  the dylib never loaded (stale keyboard process, or an inject filter that did not match);
//  a boot line with no press lines means it loaded but the press path never ran.
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
    double colorSec;        // of armSec, the part spent building/assigning colours
    double animSec;         // of armSec, the part spent submitting animations
} RKProbeCounts;

#if RK_PROBE_ENABLED

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct {
    unsigned index;
    BOOL cold;
    unsigned keys, groupsNew, groupsReused, layersNew, pathsNew;
    double armSec;      // layer arming only
    double pressSec;    // the whole press path
    double gateSec;     // layout gate
    double colorSec;    // of armSec, colours
    double animSec;     // of armSec, animation submission
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
static int RKProbeBootWritten;

// Resolves once, then costs a pointer compare on every later call. Candidates are tried in
// order and the first that opens for append wins; that path is reused for the whole run so
// the presses all land in one file. Nothing is written here -- this only decides where.
static inline const char *RKProbePath(void) {
    static char path[1024];
    static int resolved;
    if (resolved) return path;
    resolved = 1;
    const char *tmp = getenv("TMPDIR");
    const char *home = getenv("HOME");
    char cand[6][1024];
    const char *list[6];
    unsigned n = 0;
    if (tmp && tmp[0]) {
        snprintf(cand[n], sizeof(cand[0]), "%s/rkperf.log", tmp);
        list[n] = cand[n]; n++;
    }
    if (home && home[0]) {
        snprintf(cand[n], sizeof(cand[0]), "%s/Documents/rkperf.log", home);
        list[n] = cand[n]; n++;
        snprintf(cand[n], sizeof(cand[0]), "%s/Library/Caches/rkperf.log", home);
        list[n] = cand[n]; n++;
        snprintf(cand[n], sizeof(cand[0]), "%s/tmp/rkperf.log", home);
        list[n] = cand[n]; n++;
    }
    snprintf(cand[n], sizeof(cand[0]), "/tmp/rkperf.log");
    list[n] = cand[n]; n++;
    for (unsigned i = 0; i < n; i++) {
        FILE *probe = fopen(list[i], "a");
        if (probe) {
            fclose(probe);
            snprintf(path, sizeof(path), "%s", list[i]);
            return path;
        }
    }
    // Nothing was writable. Keep the first candidate so the failure is still nameable.
    snprintf(path, sizeof(path), "%s", list[0]);
    return path;
}

// One line that proves the dylib is in this process, written at load time -- that is the
// point of it. A press line can only appear after a keystroke reaches the wave path, so on
// its own it cannot distinguish "not injected" from "injected but idle".
static inline void RKProbeWriteBoot(FILE *f) {
    fprintf(f, "RKPERF boot pid=%d home=%s tmp=%s log=%s\n",
            (int)getpid(),
            (getenv("HOME") && getenv("HOME")[0]) ? getenv("HOME") : "?",
            (getenv("TMPDIR") && getenv("TMPDIR")[0]) ? getenv("TMPDIR") : "?",
            RKProbePath());
    RKProbeBootWritten = 1;
}

__attribute__((constructor)) static void RKProbeOnLoad(void) {
    FILE *f = fopen(RKProbePath(), "a");
    if (!f) return;   // Sandbox may not be live this early; the first flush retries.
    RKProbeWriteBoot(f);
    fclose(f);
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
        RKProbeBootWritten = 0;   // the truncation dropped the load record; it goes back in below
        if (!f) return;
        fprintf(f, "RKPERF rotated (previous file exceeded %u bytes)\n", RK_PROBE_MAX_BYTES);
    }
    if (!RKProbeBootWritten) RKProbeWriteBoot(f);
    unsigned n = RKProbeWarmN + RKProbeColdN;
    // The totals are seconds and the field is microseconds -- the factor has to be here,
    // otherwise every average prints as 0.0.
    fprintf(f, "RKPERF sum n=%u warm=%u arm=%.1fus press=%.1fus | cold=%u arm=%.1fus press=%.1fus | peak=%.1fus layers=%u paths=%u\n",
            n, RKProbeWarmN,
            RKProbeWarmN ? RKProbeWarmArm / RKProbeWarmN * 1e6 : 0.0,
            RKProbeWarmN ? RKProbeWarmPress / RKProbeWarmN * 1e6 : 0.0,
            RKProbeColdN,
            RKProbeColdN ? RKProbeColdArm / RKProbeColdN * 1e6 : 0.0,
            RKProbeColdN ? RKProbeColdPress / RKProbeColdN * 1e6 : 0.0,
            RKProbeMaxPress * 1e6, RKProbeLayersTotal, RKProbePathsTotal);
    for (unsigned i = 0; i < RKProbeRingCount; i++) {
        RKProbePress *p = &RKProbeRing[i];
        fprintf(f, "RKPERF press#%u %s keys=%u new=%u reuse=%u layers=%u paths=%u arm=%.1fus press=%.1fus gate=%.2fus col=%.1fus anim=%.1fus%s%s\n",
                p->index, p->cold ? "cold" : "warm", p->keys, p->groupsNew, p->groupsReused,
                p->layersNew, p->pathsNew, p->armSec * 1e6, p->pressSec * 1e6, p->gateSec * 1e6,
                p->colorSec * 1e6, p->animSec * 1e6,
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
    p->colorSec = c.colorSec;
    p->animSec = c.animSec;
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
