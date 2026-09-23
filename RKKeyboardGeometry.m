#import "RKKeyboardGeometry.h"
#import "RainbowEffectView.h"
#import <math.h>
#import <objc/runtime.h>
#import <string.h>

// ---------------------------------------------------------------------------
// Runtime registries
//
// Every lookup below used to recurse the view tree (exclusion mask, key frames,
// keycap hit-test) or walk the superview chain with a class-name match on each
// ancestor. Both are gone: RKKeyboardHooks.xm hooks the exact keyboard classes
// and registers their live instances here, so the input path and the draw path
// only ever touch a handful of known objects.
//
// All registration and lookup happens on the main thread (layout, drawing and
// event delivery are all main-thread), so no lock is required.
// ---------------------------------------------------------------------------
static __weak UIView *RKKeyboardHostWeak;                        // WBKeyboardView / UIKeyboardLayoutStar
static NSHashTable<UIView *> *RKKeyViewRegistry;                 // WBKeyView / UIKBKeyView
static NSHashTable<UIView *> *RKCandidateContainerRegistry;      // WBTopBar / TUICandidateView / ...
static uint64_t RKLayoutStamp = 1;                               // bumped on every host layout pass

// The stamp answers exactly one question: "may the cached key-frame table still be reused?"
//
// It is bumped on *every* host layout pass, and 1.2.0 proved that has to stay unconditional.
// That version narrowed it to "the host's bounds changed, or a keycap registered that the
// registry had not seen before", on the theory that a relayout moving nothing must not
// invalidate the table. On the WeType keyboard that narrowed pair goes stale while the keys
// really do change: both key sets' keycaps are registered, and switching back to the nine-key
// layout reuses the already-registered ones -- so nothing new registers and the registered
// count does not move either. Symptom on device, reported as 17.9 coming back: nine-key ->
// English -> back to nine-key, and the ripple keeps the *English* key geometry.
//
// A host layout pass is the one event present for every swap, so nothing else is needed
// here. Whether this relayout actually moved anything is deliberately not asked: it cannot
// be answered without collecting the table, which is exactly the cost the gate exists to
// avoid.
void RKRegisterKeyboardHost(UIView *host) {
    if (!host) return;
    RKLayoutStamp++;
    // A keyboard that keeps a second, hidden host instance for the other layout must
    // not take the pointer over from the one that is actually on screen.
    if (!host.window || host.hidden || host.alpha < .01) return;
    RKKeyboardHostWeak = host;
}

uint64_t RKKeyboardLayoutStamp(void) { return RKLayoutStamp; }

NSUInteger RKRegisteredKeyCount(void) { return RKKeyViewRegistry.count; }

void RKRegisterKeyView(UIView *keyView) {
    if (!keyView) return;
    if (!RKKeyViewRegistry) RKKeyViewRegistry = [NSHashTable weakObjectsHashTable];
    [RKKeyViewRegistry addObject:keyView];
}

void RKRegisterCandidateContainer(UIView *container) {
    if (!container) return;
    if (!RKCandidateContainerRegistry) RKCandidateContainerRegistry = [NSHashTable weakObjectsHashTable];
    [RKCandidateContainerRegistry addObject:container];
}

BOOL RKIsInCandidateContainer(UIView *view) {
    // Zero cost while no candidate bar is on screen (the common case for every
    // other process the tweak is injected into).
    if (!RKCandidateContainerRegistry.count || !view) return NO;
    // Enumerating the table directly, never -allObjects: that helper allocates a fresh
    // array of the whole registry on every call.
    for (UIView *container in RKCandidateContainerRegistry) {
        if (container.window && [view isDescendantOfView:container]) return YES;
    }
    return NO;
}

// The keyboard host is registered by the exact-class hook on layout/appearance.
// Callers still validate the touch point against host.bounds, so no ancestor walk
// is needed to confirm ownership.
UIView *RKKeyboardEffectHost(UIView *view) {
    UIView *host = RKKeyboardHostWeak;
    if (!host || !host.window || host.hidden || host.alpha < .01) return nil;
    return host;
}

UIBezierPath *RKKeyboardKeyFacePath(CGRect keyFrame) {
    CGRect face = CGRectInset(keyFrame, MIN(2.5, keyFrame.size.width * .065), 2);
    CGFloat corner = MIN(5, MIN(face.size.width, face.size.height) * .16);
    return [UIBezierPath bezierPathWithRoundedRect:face cornerRadius:corner];
}

// Native keyboards still expose their key model through -keyplane.keys, which is a
// property read rather than a subtree walk, so that path stays for them.
typedef id (*RKIdGetter)(id, SEL);
typedef BOOL (*RKBoolGetter)(id, SEL);
typedef CGRect (*RKRectGetter)(id, SEL);
enum { RKGetterId = 'i', RKGetterRect = 'r', RKGetterBool = 'b' };

static struct { Class cls; SEL selector; IMP imp; char kind; } RKGetterCache[24];
static size_t RKGetterCount;

// Returns a validated IMP for object's selector, or NULL when it is missing or its
// signature does not match the expected convention. Validating keeps this as safe as
// the old respondsToSelector + NSMethodSignature checks.
static IMP RKGetterIMP(id object, SEL selector, char kind) {
    if (!object || !selector) return NULL;
    const char *type = kind == RKGetterId ? @encode(id)
        : (kind == RKGetterRect ? @encode(CGRect) : @encode(BOOL));
    Class cls = object_getClass(object);
    for (size_t i = 0; i < RKGetterCount; i++) {
        if (RKGetterCache[i].cls != cls || RKGetterCache[i].selector != selector) continue;
        return RKGetterCache[i].kind == kind ? RKGetterCache[i].imp : NULL;
    }
    IMP imp = NULL;
    if ([object respondsToSelector:selector]) {
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        if (signature.numberOfArguments == 2 && !strcmp(signature.methodReturnType, type))
            imp = [object methodForSelector:selector];
    }
    if (RKGetterCount < sizeof(RKGetterCache) / sizeof(RKGetterCache[0])) {
        RKGetterCache[RKGetterCount].cls = cls;
        RKGetterCache[RKGetterCount].selector = selector;
        RKGetterCache[RKGetterCount].imp = imp;
        RKGetterCache[RKGetterCount].kind = kind;
        RKGetterCount++;
    }
    return imp;
}
static id RKCallObject(id object, SEL selector) {
    RKIdGetter getter = (RKIdGetter)RKGetterIMP(object, selector, RKGetterId);
    return getter ? getter(object, selector) : nil;
}
static BOOL RKCallBool(id object, SEL selector, BOOL fallback) {
    RKBoolGetter getter = (RKBoolGetter)RKGetterIMP(object, selector, RKGetterBool);
    return getter ? getter(object, selector) : fallback;
}
static CGRect RKCallRect(id object, SEL selector) {
    RKRectGetter getter = (RKRectGetter)RKGetterIMP(object, selector, RKGetterRect);
    return getter ? getter(object, selector) : CGRectZero;
}

static BOOL RKValidKeyRect(CGRect rect, CGRect bounds) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
        isfinite(rect.size.width) && isfinite(rect.size.height) &&
        rect.size.width >= 10 && rect.size.height >= 14 &&
        rect.size.width <= bounds.size.width * .9 &&
        rect.size.height <= MIN(120, bounds.size.height * .6) &&
        CGRectContainsRect(CGRectInset(bounds, -1, -1), rect);
}

static void RKAddKey(NSMutableArray<NSValue *> *frames, CGRect rect, CGRect bounds) {
    if (!RKValidKeyRect(rect, bounds)) return;
    for (NSValue *value in frames) {
        CGRect other = value.CGRectValue;
        if (fabs(other.origin.x - rect.origin.x) < 1 && fabs(other.origin.y - rect.origin.y) < 1 &&
            fabs(other.size.width - rect.size.width) < 1 && fabs(other.size.height - rect.size.height) < 1) return;
    }
    if (frames.count < 100) [frames addObject:[NSValue valueWithCGRect:rect]];
}

// A keycap only counts while it belongs to the key set that is on screen. WeType
// installs the new layout in place and keeps the outgoing one alive inside a
// container it hides, so retired keycaps keep hidden == NO and alpha == 1 on
// themselves: a self-only check let their stale frames keep feeding the geometry.
// Walking the short chain up to the host (2-3 levels, fixed depth -- no recursion,
// no class-name matching) catches the hidden container.
static BOOL RKKeyViewIsLive(UIView *keyView, UIView *host) {
    // Window equality also rejects keycaps parked in a preload window, whose frames
    // would otherwise convert into perfectly plausible host coordinates.
    if (!keyView || !host || keyView.window != host.window) return NO;
    if (keyView.hidden || keyView.alpha < .01) return NO;
    UIView *node = keyView.superview;
    for (NSUInteger depth = 0; node && node != host && depth < 16; depth++) {
        if (node.hidden || node.alpha < .01) return NO;
        node = node.superview;
    }
    return YES;
}

// Keycaps registered by the exact-class hooks. Linear over the registered keys only
// (tens of objects), never over the view hierarchy. requireLive selects the strict
// test above; the loose pass keeps the original self-only test and is used only when
// the strict one would leave the effect with no keys at all.
//
// The table is enumerated directly: -allObjects allocates a fresh array of the whole
// registry on every call, and this runs once per key-frame collection.
static void RKAddRegisteredKeys(UIView *host, NSMutableArray<NSValue *> *frames,
                                BOOL requireLive) {
    for (UIView *keyView in RKKeyViewRegistry) {
        if (requireLive) {
            if (!RKKeyViewIsLive(keyView, host)) continue;
        } else if (!keyView.window || keyView.hidden || keyView.alpha < .01) continue;
        RKAddKey(frames, [keyView convertRect:keyView.bounds toView:host], host.bounds);
    }
}

NSArray<NSValue *> *RKKeyboardKeyFrames(UIView *host) {
    NSMutableArray *frames = [NSMutableArray array];
    // Native keyboards expose their key model directly, so their proven path stays
    // exactly as before: two property reads, no subtree walk.
    SEL selKeyplane = NSSelectorFromString(@"keyplane"), selKeys = NSSelectorFromString(@"keys");
    SEL selGhost = NSSelectorFromString(@"ghost"), selVisible = NSSelectorFromString(@"visible");
    SEL selDisplayFrame = NSSelectorFromString(@"displayFrame"), selFrame = NSSelectorFromString(@"frame");
    id plane = RKCallObject(host, selKeyplane);
    id keys = RKCallObject(plane, selKeys);
    if ([keys isKindOfClass:NSArray.class] || [keys isKindOfClass:NSSet.class]) {
        for (id key in keys) {
            // A missing getter keeps the previous defaults: ghost NO, visible YES.
            if (RKCallBool(key, selGhost, NO)) continue;
            if (!RKCallBool(key, selVisible, YES)) continue;
            CGRect rect = RKCallRect(key, selDisplayFrame);
            if (!RKValidKeyRect(rect, host.bounds)) rect = RKCallRect(key, selFrame);
            RKAddKey(frames, rect, host.bounds);
        }
    }
    if (frames.count >= 3) return frames;
    // WeType has no keyplane model: use the keycaps registered by the exact-class
    // hook on WBKeyView (linear over registered keycaps only).
    [frames removeAllObjects];
    RKAddRegisteredKeys(host, frames, YES);
    if (frames.count < 3) {
        // The strict pass can come up empty when the keyboard hides a container on the
        // path down to its keys. Losing every key would kill the effect outright, which
        // is worse than the stale-frame problem that pass exists to fix, so fall back to
        // the loose test and let the frame validation above do what it can.
        [frames removeAllObjects];
        RKAddRegisteredKeys(host, frames, NO);
    }
    return frames;
}

// The largest candidate container currently on screen. Several of the hooked classes nest
// (on WeType WBTopBar holds WBCandidateView, which holds prediction cells), so size picks
// the outer bar rather than one of its children. The same liveness test the keycaps get is
// applied, so a bar left behind by a retired layout cannot win on size.
static UIView *RKLiveCandidateBar(void) {
    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIView *container in RKCandidateContainerRegistry) {
        if (!container.window || container.hidden || container.alpha < .01) continue;
        CGRect bounds = container.bounds;
        CGFloat area = bounds.size.width * bounds.size.height;
        if (!isfinite(area) || area <= bestArea) continue;
        bestArea = area;
        best = container;
    }
    return best;
}

// The deepest view that is an ancestor of both. The shorter chain goes into a set first, so
// the cost is the depth of the keyboard's view tree -- single digits -- and this only runs
// when the key-frame table is being rebuilt, never per keystroke.
static UIView *RKCommonAncestorView(UIView *a, UIView *b) {
    if (!a || !b || a.window != b.window) return nil;
    NSMutableSet<UIView *> *chain = [NSMutableSet setWithCapacity:8];
    for (UIView *node = a; node; node = node.superview) [chain addObject:node];
    for (UIView *node = b; node; node = node.superview)
        if ([chain containsObject:node]) return node;
    return nil;
}

UIView *RKKeyboardOverlayHost(UIView *host, CGRect *outFrame) {
    if (outFrame) *outFrame = host ? host.bounds : CGRectZero;
    if (!host) return nil;
    UIView *bar = RKLiveCandidateBar();
    if (!bar || !host.superview) return host;
    UIView *ancestor = RKCommonAncestorView(host, bar);
    // Sharing the window as an ancestor is not an ownership signal. Attaching the overlay
    // at the window would let it cover unrelated UI, so that case keeps the key area.
    if (!ancestor || ancestor == ancestor.window || ancestor.hidden || ancestor.alpha < .01)
        return host;
    CGRect keys = [host convertRect:host.bounds toView:ancestor];
    CGRect candidates = [bar convertRect:bar.bounds toView:ancestor];
    if (CGRectIsEmpty(keys) || CGRectIsEmpty(candidates)) return host;
    // The bar has to read as the keyboard's own candidate row: above the keys, and spanning
    // them. A floating prediction bubble, or a bar parked in a corner, fails both tests.
    BOOL above = CGRectGetMaxY(candidates) <= CGRectGetMinY(keys) + 4;
    BOOL spans = CGRectGetMinX(candidates) <= CGRectGetMinX(keys) + 24 &&
                 CGRectGetMaxX(candidates) >= CGRectGetMaxX(keys) - 24;
    if (!above || !spans) return host;
    // A container caught mid-layout can report bounds that would stretch the glow across
    // most of the screen; refusing those keeps a bad measurement from becoming a bad overlay.
    if (candidates.size.width > keys.size.width * 1.5 ||
        candidates.size.height > keys.size.height + 200) return host;
    CGRect merged = CGRectUnion(keys, candidates);
    if (merged.size.height > keys.size.height * 2) return host;
    if (outFrame) *outFrame = merged;
    return ancestor;
}

// Replaces the old recursive subview search: match the pressed key frame against the
// registered keycaps. Returns nil when nothing is close enough.
UIView *RKKeyboardKeyViewAtFrame(UIView *host, CGRect keyFrame) {
    if (!host || CGRectIsEmpty(keyFrame)) return nil;
    UIView *best = nil;
    CGFloat bestDelta = 5;
    for (UIView *keyView in RKKeyViewRegistry) {
        if (!RKKeyViewIsLive(keyView, host)) continue;
        CGRect rect = [keyView convertRect:keyView.bounds toView:host];
        CGFloat delta = MAX(MAX(fabs(rect.origin.x - keyFrame.origin.x),
                               fabs(rect.origin.y - keyFrame.origin.y)),
                           MAX(fabs(rect.size.width - keyFrame.size.width),
                               fabs(rect.size.height - keyFrame.size.height)));
        if (delta < bestDelta) { bestDelta = delta; best = keyView; }
    }
    return best;
}
