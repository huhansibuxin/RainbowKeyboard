#import "RainbowEffectView.h"
#import "RKKeyboardGeometry.h"
#import "RKNeonPress.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#include <string.h>
#include <stdlib.h>
#import "RKPreferences.h"
#import "RKProbe.h"
static NSDictionary *RKReadPreferences(void) {
    return RKReadEffectivePreferences();
}
// showRippleAtPoint: runs on every key press and the bundle identifier cannot change
// at runtime, so the keyboard type is resolved once instead of lowercasing the
// identifier (two string allocations) on every keystroke.
static BOOL RKIsWeTypeProcess(void) {
    static BOOL weType;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        weType = [NSBundle.mainBundle.bundleIdentifier.lowercaseString containsString:@"wetype"];
    });
    return weType;
}
// Animation values, keyTimes and gradient locations are constants, yet the old code
// rebuilt these arrays -- and every NSNumber inside them -- on every keystroke: 10
// arrays plus 42 numbers per press for the ambient pass alone, then 1 array plus 4
// numbers per animated key for its fade keyTimes. They are immutable and Core
// Animation only reads them, so a single shared copy is safe and produces the same
// animation.
enum { RKConstAmbientLocations, RKConstSpreadValues, RKConstSpreadKeyTimes,
       RKConstAmbientFadeValues, RKConstAmbientFadeKeyTimes, RKConstKeyFadeKeyTimes,
       RKConstKeyFadeValues, RKConstCount };
static NSArray *RKAnimConstant(NSUInteger index) {
    static NSArray *table[RKConstCount];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table[RKConstAmbientLocations]    = @[@0, @.22, @.52, @.78, @1];
        table[RKConstSpreadValues]        = @[@.04, @.64, @1, @1.08];
        table[RKConstSpreadKeyTimes]      = @[@0, @.32, @.7, @1];
        table[RKConstAmbientFadeValues]   = @[@0, @1, @.9, @0];
        table[RKConstAmbientFadeKeyTimes] = @[@0, @.08, @.52, @1];
        table[RKConstKeyFadeKeyTimes]     = @[@0, @.12, @.38, @1];
        // The key fade's shape without its peak. The peak depends on the press (the
        // distance from the touch), so it is carried by the layer's own opacity instead
        // and the animation is the same four numbers for every key, every press.
        table[RKConstKeyFadeValues]       = @[@0, @1, @.72, @0];
    });
    return index < RKConstCount ? table[index] : nil;
}
// Core Animation gives every model-value write on a layer that is already in a tree an
// implicit 0.25s animation, built on the spot from the layer's default actions. While the
// effect rebuilt its layers on every press there was nothing to animate *from*, so this
// never showed. The pool keeps its layers in the tree forever, so from 1.3.0 on every
// re-armed value would have started an action: that is where the visible "the glow slides
// from the last key to this one" came from, and it also means dozens of action objects --
// and the transaction bookkeeping that goes with them -- were being created per keystroke
// on layers that were supposed to be free to reuse.
//
// Answering NSNull for a key path means "no action", i.e. the write lands immediately.
// The two animations this effect actually wants (the wave's own fade, and the ambient
// bloom's travel) are added explicitly, so nothing here is lost.
static NSDictionary *RKInstantActions(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{@"position": NSNull.null, @"bounds": NSNull.null, @"frame": NSNull.null,
                @"opacity": NSNull.null, @"contents": NSNull.null,
                @"path": NSNull.null, @"fillColor": NSNull.null, @"strokeColor": NSNull.null,
                @"fillRule": NSNull.null, @"lineWidth": NSNull.null,
                @"shadowColor": NSNull.null, @"shadowOpacity": NSNull.null,
                @"shadowRadius": NSNull.null, @"shadowOffset": NSNull.null,
                @"shadowPath": NSNull.null,
                @"colors": NSNull.null, @"locations": NSNull.null,
                @"startPoint": NSNull.null, @"endPoint": NSNull.null,
                @"cornerRadius": NSNull.null, @"transform": NSNull.null};
    });
    return map;
}
static void RKDisableImplicitAnimations(CALayer *layer) {
    layer.actions = RKInstantActions();
}
// The travel of the ambient bloom from the previous press's centre to this one's. Only
// used when the user has asked for it (「背景霓虹跟随滑行」); the duration and curve match
// what Core Animation's implicit action used to give, so switching it on preserves the
// look the pooled build first produced by accident.
static const CFTimeInterval RKAmbientGlideDuration = .25;
// An opaque +1 CGColor for an HSB triple. Built through UIColor so the colour space stays
// whatever the system picks for a hue -- the wide-gamut space on these devices, which
// hand-rolled sRGB would not reproduce -- but returned as the CGColor alone, so the alpha
// variants downstream are copies rather than a UIColor each.
static CGColorRef RKHueColor(CGFloat hue, CGFloat saturation, CGFloat brightness) {
    CGColorRef color = [UIColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1].CGColor;
    return CGColorRetain(color);
}
// An alpha variant as a +1 CGColor. -copyWithAlpha returns NULL for a colour space that
// carries no alpha, and the result is handed to an array -- which would raise on a nil --
// so a failed copy falls back to the opaque colour rather than to nothing.
static CGColorRef RKCopiedAlpha(CGColorRef base, CGFloat alpha) {
    CGColorRef copy = CGColorCreateCopyWithAlpha(base, alpha);
    return copy ?: CGColorRetain(base);
}
// Everything the drawing path needs, resolved once per configuration change instead of
// being looked up in two dictionaries on every keystroke. The old code spent roughly 42
// resolved reads per keystroke -- each one a lookup in the 自用 table plus a lookup in the
// live configuration, an -isKindOfClass:/respondsToSelector: probe and an unboxing -- on
// values that only move when the user moves a slider. Measured on the drawing path, that
// was the largest purely wasted cost left. Now the drawing path reads plain floats.
//
// Two parameters keep two entries because their call sites disagree on the *literal*
// fallback (used only when the key is absent from the configuration): the wide-band
// pass of the 鲜艳彩虹 style wants a wider, slower band than the key-wave pass.
typedef struct {
    BOOL enabled;
    BOOL rippleEnabled;
    BOOL keyboardEnabled;          // WeChatKeyboard or NativeKeyboard, whichever this process is
    BOOL ambientGlow;
    BOOL backgroundFeedback;
    BOOL ambientGlide;             // let the ambient bloom travel from press to press
    NSInteger style;
    NSInteger colorMode;
    CGFloat opacity;
    CGFloat brightness;
    CGFloat neonSaturation;        // the 0...1 factor the call sites multiply their base by
    CGFloat hue;                   // the fixed hue, used when colorMode == 1
    CGFloat duration;
    CGFloat spread;
    CGFloat softness;
    CGFloat core;
    NSUInteger maxEffects;
    CGFloat pressBrightness;
    CGFloat backgroundRadius;
    CGFloat backgroundBand;
    CGFloat backgroundStrengthKeyWave;   // key-wave pass, literal fallback .18
    CGFloat backgroundDurationKeyWave;   // key-wave pass, literal fallback .4
    CGFloat backgroundStrengthWide;      // wide-band pass, literal fallback .28
    CGFloat backgroundDurationWide;      // wide-band pass, literal fallback .65
    CGFloat ambientStrength;
} RKRenderParams;

// ---------------------------------------------------------------------------
// The key-wave layer pool.
//
// The wave picture is around forty layers per press: one container, an ambient wash of
// two field layers and two radial blooms carrying it, and -- the bulk of it -- four
// layers per lit key (the key itself, its halo outline, its gradient, and the rim mask
// that clips the gradient), each with a bezier path freshly built and then copied into
// two shape layers. All of that was rebuilt from nothing on every press, even though
// none of the geometry depends on the press: a key's outline, its rim and its frames are
// functions of the key's rect, and the keyboard keeps those rects fixed until it changes
// key set. Only the hues, the per-key opacity peak, the ambient's centre and the
// animation start times genuinely vary.
//
// So the geometry is built once per (pulse, key) and kept, and a press only writes the
// varying values on layers the tree already holds -- the animation objects are kept and
// mutated in place as well. Typing then adds nothing to and removes nothing from the
// layer tree, which is the point of the exercise: what is being removed is the per-press
// allocation and the Core Animation commit that came with it, not the arithmetic.
//
// The pool holds as many pulses as the effect limit allows, so overlapping presses still
// look the same as before. When every pulse is still drawing, the one that finishes
// first is the one re-armed -- exactly the pulse the old code would have evicted, except
// it draws again instead of being thrown away.
//
// The pool is dropped whenever what it was built against changes: the key set
// (-setKeyFrames:), the overlay's size (rotation of the device), the style, or while the
// effect is switched off. Those are all user-paced, so a rebuild never lands mid-typing.
// ---------------------------------------------------------------------------
@interface RKKeyWaveGroup : NSObject
@property(nonatomic,strong) CALayer *key;
// The key's opacity is the press's peak for this key; the fade animation lives on this
// layer instead, so the animation is one shared constant curve rather than four freshly
// boxed numbers per key per press.
@property(nonatomic,strong) CALayer *fader;
@property(nonatomic,strong) CAShapeLayer *halo;
@property(nonatomic,strong) CAGradientLayer *edge;
@property(nonatomic,strong) CAShapeLayer *rim;
// Kept and rewritten in place: -colors copies whatever array it is handed, so building a
// new two-element array on every press only adds an allocation.
@property(nonatomic,strong) NSMutableArray *edgeColors;
@property(nonatomic,strong) CAKeyframeAnimation *fade;
// Two geometry variants: the key under the finger is drawn with a 3pt rim instead of
// 2.6pt, which moves its frames and its outline by half a point.
@property(nonatomic,strong) UIBezierPath *outlinePlain, *outerPlain, *outlineWide, *outerWide;
@property(nonatomic) CGRect framePlain, frameWide;
@property(nonatomic) char installedVariant;   // 0 none, 1 plain, 2 wide
@end

@implementation RKKeyWaveGroup
@end

@interface RKWavePulse : NSObject
@property(nonatomic,strong) CALayer *container;
@property(nonatomic,strong) CALayer *ambient;
@property(nonatomic,strong) NSMutableArray<CALayer *> *fields;
@property(nonatomic,strong) NSMutableArray<CAGradientLayer *> *blooms;
// Rewritten in place per press; -colors copies what it is given, so the buffer is only
// there to save the two five-element array allocations a press used to cost.
@property(nonatomic,strong) NSMutableArray *bloomColorBuffer;
@property(nonatomic,strong) NSMutableArray *groups;   // index-aligned with keyFrames; NSNull until lit
@property(nonatomic) CFTimeInterval activeUntil;      // when nothing of this pulse still draws
@end

@implementation RKWavePulse
@end

// Builds both path variants for one key. `faceOutline` is the key face in host
// coordinates; the paths come back in the key layer's own coordinates, which is exactly
// what the per-press code used to produce.
static void RKKeyWaveVariants(UIBezierPath *faceOutline, CGFloat rimWidth,
                              UIBezierPath **outlineOut, UIBezierPath **outerOut,
                              CGRect *frameOut) {
    CGRect face = faceOutline.bounds;
    CGRect edgeFrame = CGRectInset(face, -rimWidth, -rimWidth);
    UIBezierPath *outline = [UIBezierPath bezierPathWithCGPath:faceOutline.CGPath];
    [outline applyTransform:CGAffineTransformMakeTranslation(-edgeFrame.origin.x, -edgeFrame.origin.y)];
    CGFloat corner = MIN(5, MIN(face.size.width, face.size.height) * .16);
    UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:
        CGRectMake(0, 0, edgeFrame.size.width, edgeFrame.size.height) cornerRadius:corner + rimWidth];
    [outer appendPath:outline];
    *outlineOut = outline;
    *outerOut = outer;
    *frameOut = edgeFrame;
}

// Puts a variant on its layers. Frames and paths are only touched when the variant
// actually changes, because re-assigning an identical path makes a shape layer redraw.
// Everything that is a function of the variant - the frames, the outline paths, the rim
// width and the shadow's outline - is written here and nowhere else, so the press path
// never has to.
static void RKInstallKeyWaveVariant(RKKeyWaveGroup *group, char variant) {
    if (group.installedVariant == variant) return;
    BOOL wide = variant == 2;
    group.key.frame = wide ? group.frameWide : group.framePlain;
    group.fader.frame = group.key.bounds;
    group.halo.frame = group.fader.bounds;
    group.edge.frame = group.fader.bounds;
    group.rim.frame = group.fader.bounds;
    group.halo.path = (wide ? group.outlineWide : group.outlinePlain).CGPath;
    // Without a shadow path the halo's shadow has no outline to use, so the layer (and
    // its transparent surroundings) is re-rasterised offscreen on every frame it is
    // visible. The shape is already known, so hand it over: same blur, no per-frame
    // offscreen pass. This is a battery cost, not a main-thread one.
    group.halo.shadowPath = group.halo.path;
    // 2.6pt plain / 3.0pt under the finger, doubled because the halo is a centred stroke.
    group.halo.lineWidth = (wide ? 3.0 : 2.6) * 2;
    group.rim.path = (wide ? group.outerWide : group.outerPlain).CGPath;
    group.installedVariant = variant;
}

// The Settings process posts this whenever anything is saved (RKPreferences.h and
// RKCandidateTransport.h both end in notify_post of this name). Subscribing to it turns
// the per-keystroke "has the configuration changed?" probe -- one lock plus two notify
// round-trips -- into a push that only happens when there is actually something to apply.
static NSString * const RKPreferencesChangedNotification = @"com.minis.rainbowkeyboard.changed";

// A notification can still be missed, because this keyboard extension may be suspended
// while the user is in Settings, and a resumed extension is not re-initialised. So the
// configuration is additionally re-checked on a slow floor. That floor is a "how stale
// may the applied look get" bound, not a poll: at most one check per second, on a path
// that runs around ten times a second.
static const CFTimeInterval RKConfigRefreshFloor = 1;

static void RKPreferencesChangedCallback(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo) {
    // The observer is this view and is not retained by the notification centre; the weak
    // reference makes a callback that races with teardown a no-op instead of a dangling
    // message.
    __weak RainbowEffectView *view = (__bridge RainbowEffectView *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [view reloadConfiguration]; });
}

@interface RainbowEffectView ()
@property(nonatomic,strong) NSDictionary *config;
@property(nonatomic) CGFloat hue;
@property(nonatomic) CGFloat pressHue;
@property(nonatomic) NSInteger lastStyle;
// The pooled wave pulses, in the order they were created. Declared here so the
// invalidation points (key set changed, style changed, resize, switched off) can drop the
// pool without depending on where the pool methods happen to sit in the file.
- (void)discardWavePool;
- (RKWavePulse *)wavePulseForArmingWithLimit:(NSUInteger)limit;
- (void)armAmbientOnPulse:(RKWavePulse *)pulse origin:(CGPoint)origin radius:(CGFloat)radius
                      hue:(CGFloat)hue mode:(NSInteger)mode duration:(CGFloat)duration
                   counts:(RKProbeCounts *)counts;
- (RKKeyWaveGroup *)keyWaveGroupInPulse:(RKWavePulse *)pulse index:(NSUInteger)index
                                   rect:(CGRect)rect counts:(RKProbeCounts *)counts;
- (void)showKeyWaveAtPoint:(CGPoint)point hue:(CGFloat)hue mode:(NSInteger)mode
                 startedAt:(double)startedAt;
@end
@implementation RainbowEffectView {
    // Cached compound "gaps" path for the gutter light. It depends only on bounds and
    // the key frames, yet the old code rebuilt all of them (one rounded-rect bezier
    // path per key) on every single keystroke.
    CGPathRef _gutterPath;
    CGRect _gutterPathBounds;
    BOOL _gutterPathValid;
    // Fingerprint of the layout the current keyFrames were collected from. It has to be
    // more than the bounds: a nine-key to full-layout switch keeps the host bounds
    // identical while replacing every single key, which is how the effect ended up
    // still spreading from the old numeric-key centres.
    BOOL _keyFramesStampValid;
    uint64_t _keyFramesStamp;
    NSUInteger _keyFramesKeyCount;
    CGRect _keyFramesHostBounds;
    // The resolved render parameters, and when they were last resolved (see
    // RKConfigRefreshFloor).
    RKRenderParams _params;
    CFTimeInterval _configResolvedAt;
    // One shared mask layer for the gutter light instead of a new CAShapeLayer per
    // keystroke. The compound path it draws was already cached; the layer was not, so
    // every press allocated a shape layer identical to the one before it.
    CAShapeLayer *_gutterMaskLayer;
    __weak CALayer *_gutterMaskHost;   // the field it is currently attached to as mask
    // The wave layer pool, and the bounds it was built against (a resize invalidates it,
    // since every pooled frame is expressed in this view's coordinates).
    NSMutableArray<RKWavePulse *> *_wavePulses;
    CGRect _poolBounds;
    // self.keyFrames as a flat C array. Both passes over the key table run on the press
    // path, between the touch and the frame being drawn, so unboxing is worth avoiding.
    CGRect *_keyFrameRects;
    NSUInteger _keyFrameRectCount;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _wavePulses = [NSMutableArray arrayWithCapacity:2];
        _poolBounds = frame;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadConfiguration) name:UIApplicationDidBecomeActiveNotification object:nil];
        // Push, not poll: the configuration is re-resolved when Settings says it changed,
        // so a keystroke never has to ask. Delivered immediately and cross-process.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, RKPreferencesChangedCallback,
            (__bridge CFStringRef)RKPreferencesChangedNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        [self reloadConfiguration];
    }
    return self;
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, (__bridge CFStringRef)RKPreferencesChangedNotification, NULL);
    if (_gutterPath) CGPathRelease(_gutterPath);
    if (_keyFrameRects) free(_keyFrameRects);
}
- (void)reloadConfiguration {
    self.config = RKReadPreferences();
    // Resolve everything once, here. Each field is the same value, with the same literal
    // fallback and the same clamp, that its call site used to look up for itself, so this
    // is a move and not a change. Two fields are resolved twice because their call sites
    // disagree on the literal fallback; see RKRenderParams.
    RKRenderParams p = (RKRenderParams){0};
    BOOL weType = RKIsWeTypeProcess();
    p.enabled = [self flag:@"Enabled"];
    p.rippleEnabled = [self flag:@"RippleEnabled"];
    p.keyboardEnabled = [self flag:weType ? @"WeChatKeyboard" : @"NativeKeyboard"];
    p.ambientGlow = [self flag:@"AmbientGlow"];
    p.backgroundFeedback = [self flag:@"BackgroundFeedback"];
    // Absent means on, which is what -flag: already answers, so an install that has never
    // seen the switch keeps the travel the pooled build introduced.
    p.ambientGlide = [self flag:@"AmbientGlide"];
    p.style = (NSInteger)[self number:@"EffectStyle" fallback:0 low:0 high:2];
    p.colorMode = (NSInteger)[self number:@"ColorMode" fallback:0 low:0 high:2];
    p.opacity = [self number:@"Opacity" fallback:.65 low:0 high:1];
    p.brightness = [self number:@"Brightness" fallback:.95 low:0 high:1];
    p.neonSaturation = [self number:@"NeonSaturation" fallback:.72 low:0 high:1];
    p.hue = [self number:@"Hue" fallback:.55 low:0 high:1];
    p.duration = [self number:@"Duration" fallback:.55 low:.15 high:1.2];
    p.spread = [self number:@"Spread" fallback:2 low:.5 high:3];
    p.softness = [self number:@"Softness" fallback:8 low:0 high:24];
    p.core = [self number:@"CoreStrength" fallback:.5 low:0 high:1];
    p.maxEffects = (NSUInteger)[self number:@"MaxEffects" fallback:4 low:1 high:8];
    p.pressBrightness = [self number:@"PressBrightness" fallback:1 low:0 high:1];
    p.backgroundRadius = [self number:@"BackgroundRadius" fallback:180 low:60 high:360];
    p.backgroundBand = [self number:@"BackgroundBand" fallback:.55 low:.2 high:.85];
    p.backgroundStrengthKeyWave = [self number:@"BackgroundStrength" fallback:.18 low:0 high:.6];
    p.backgroundDurationKeyWave = [self number:@"BackgroundDuration" fallback:.4 low:.1 high:1.5];
    p.backgroundStrengthWide = [self number:@"BackgroundStrength" fallback:.28 low:0 high:.6];
    p.backgroundDurationWide = [self number:@"BackgroundDuration" fallback:.65 low:.1 high:1.5];
    p.ambientStrength = [self number:@"AmbientStrength" fallback:.85 low:0 high:1];
    // Only a real change drops the pool. -refreshConfigurationIfStale re-resolves at most
    // once a second, so dropping unconditionally here would make the first press after
    // every second a cold one. Comparing is a few dozen bytes of memcmp once a second.
    if (memcmp(&_params, &p, sizeof(p)) != 0) [self discardWavePool];
    _params = p;
    _configResolvedAt = CFAbsoluteTimeGetCurrent();
}
// Called from the keystroke path, where it almost always just compares one float and
// returns. A real re-resolution happens only when the settings-changed push arrives, or
// at most once a second as the fallback for a push that was missed while suspended.
- (void)refreshConfigurationIfStale {
    if (CFAbsoluteTimeGetCurrent() - _configResolvedAt < RKConfigRefreshFloor) return;
    [self reloadConfiguration];
}
- (CGFloat)number:(NSString *)key fallback:(CGFloat)fallback low:(CGFloat)low high:(CGFloat)high {
    // The literal shipped fallback yields to the frozen 自用 tuning for any key that table
    // defines, so a keyboard process which cannot reach the saved plist -- or a fresh
    // install -- still renders that look instead of a different set of numbers. Keys the
    // table does not define keep the literal, which stays spelled out at each call site.
    NSNumber *selfUse = RKPresetSelfUseTable()[key];
    if (selfUse) fallback = selfUse.doubleValue;
    id x = self.config[key];
    CGFloat v = [x respondsToSelector:@selector(doubleValue)] ? [x doubleValue] : fallback;
    return isfinite(v) ? MIN(high,MAX(low,v)) : fallback;
}
- (BOOL)flag:(NSString *)key { return !self.config[key] || [self.config[key] boolValue]; }
- (CGFloat)neonSaturation:(CGFloat)base {
    // Already resolved: no dictionary lookup left on this path.
    return base * _params.neonSaturation;
}
- (BOOL)preservesBlackFaces {
    // 自定义键帽与底色已移除，键帽一律使用系统原生配色，不再保留黑色键面。
    return NO;
}
// The compound path (keyboard rect + even-odd key faces) is a pure function of
// self.bounds and self.keyFrames. Rebuild it only when one of those changes.
- (CGPathRef)keyGutterPath {
    if (_gutterPathValid && CGRectEqualToRect(_gutterPathBounds, self.bounds)) return _gutterPath;
    UIBezierPath *gaps = [UIBezierPath bezierPathWithRect:self.bounds];
    for (NSValue *value in self.keyFrames) [gaps appendPath:RKKeyboardKeyFacePath(value.CGRectValue)];
    CGPathRef built = CGPathCreateCopy(gaps.CGPath);
    if (_gutterPath) CGPathRelease(_gutterPath);
    _gutterPath = built;
    _gutterPathBounds = self.bounds;
    _gutterPathValid = (built != NULL);
    return _gutterPath;
}
// One shared layer, refitted and re-pathed on each use. The compound path itself is
// already cached by -keyGutterPath; wrapping a brand-new CAShapeLayer around that same
// path on every keystroke was all that remained of the per-press allocation here.
- (CAShapeLayer *)gutterMaskForField:(CALayer *)field {
    if (!_gutterMaskLayer) {
        _gutterMaskLayer = [CAShapeLayer layer];
        _gutterMaskLayer.fillRule = kCAFillRuleEvenOdd;
    }
    // A layer can mask only one layer at a time, so take it off whichever field used it
    // last before handing it to this one.
    if (_gutterMaskHost && _gutterMaskHost != field) _gutterMaskHost.mask = nil;
    _gutterMaskLayer.frame = self.bounds;
    _gutterMaskLayer.path = [self keyGutterPath];
    _gutterMaskHost = field;
    return _gutterMaskLayer;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // Old animations must not float over a new keyboard after rotation/resizing. The
    // pooled layers carry frames in this view's coordinates too, so a size change drops
    // the whole pool rather than trying to refit forty of them.
    if (!CGRectEqualToRect(_poolBounds, self.bounds)) {
        _poolBounds = self.bounds;
        [self discardWavePool];
    }
    for (CALayer *pulse in self.layer.sublayers.copy) {
        if (!CGRectEqualToRect(pulse.frame, self.bounds)) [pulse removeFromSuperlayer];
    }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self discardWavePool];
        for (CALayer *pulse in self.layer.sublayers.copy) [pulse removeFromSuperlayer];
    }
}
- (void)setKeyFrames:(NSArray<NSValue *> *)keyFrames {
    if ([_keyFrames isEqualToArray:keyFrames]) return;
    _keyFrames = [keyFrames copy];
    // Rebuild the flat table alongside it. The two must never drift: every hot read uses
    // the C array, the cached-path cache and the settings page read the array.
    if (_keyFrameRects) { free(_keyFrameRects); _keyFrameRects = NULL; }
    _keyFrameRectCount = _keyFrames.count;
    if (_keyFrameRectCount) {
        _keyFrameRects = malloc(sizeof(CGRect) * _keyFrameRectCount);
        for (NSUInteger i = 0; i < _keyFrameRectCount; i++) _keyFrameRects[i] = _keyFrames[i].CGRectValue;
    }
    _gutterPathValid = NO;
    // The pool is indexed by position in this array and holds this layout's geometry, so
    // a new key set means a new pool.
    [self discardWavePool];
    for (CALayer *pulse in self.layer.sublayers.copy) [pulse removeFromSuperlayer];
}
- (BOOL)updateKeyFramesForHost:(UIView *)host {
    double probeStart = RKProbeTic();
    if (!host) { RKProbeNoteGate(RKProbeTic() - probeStart); return NO; }
    // Three O(1) reads and no allocation, on every keystroke. This gate is the whole reason
    // the layout stamp can be bumped on every host layout pass: the stamp changing means the
    // frames must be re-collected, the stamp standing still means this keystroke -- during
    // which the host never laid out -- reuses them as they are. Bounds and the registered
    // count stay in the gate as independent corroboration (rotation, candidate bar appearing,
    // a key set installed without a host layout).
    // Do not try to make the stamp itself conditional (1.2.0 did): on the WeType keyboard both
    // key sets' keycaps stay registered across a switch, so neither "an unseen keycap arrived"
    // nor "the count moved" fires when returning to the nine-key layout -- the frames would
    // keep the retired layout's geometry, which is the 17.9 failure.
    // The caller also reads a YES here to re-raise the overlay, so a missed change looks like
    // a stale origin, or a light hidden under the freshly installed keycaps.
    CGRect hostBounds = host.bounds;
    uint64_t stamp = RKKeyboardLayoutStamp();
    NSUInteger keyCount = RKRegisteredKeyCount();
    if (_keyFramesStampValid && _keyFramesStamp == stamp &&
        _keyFramesKeyCount == keyCount && CGRectEqualToRect(_keyFramesHostBounds, hostBounds)) {
        RKProbeNoteGate(RKProbeTic() - probeStart);
        return NO;
    }
    self.frame = hostBounds;
    self.keyFrames = RKKeyboardKeyFrames(host);
    _keyFramesStamp = stamp;
    _keyFramesKeyCount = keyCount;
    _keyFramesHostBounds = hostBounds;
    _keyFramesStampValid = YES;
    RKProbeNoteGate(RKProbeTic() - probeStart);
    return YES;
}
// A pulse is one wave container plus everything it drew. Created on demand, then kept and
// re-armed forever, so the layer tree stops churning while typing.
- (RKWavePulse *)newWavePulse {
    RKWavePulse *pulse = [RKWavePulse new];
    pulse.container = [CALayer layer];
    pulse.container.name = @"rkWavePulse";
    RKDisableImplicitAnimations(pulse.container);
    pulse.container.frame = self.bounds;
    // No pulse mask here: the old code masked the pulse only to preserve black key faces,
    // and that feature is gone -- -preservesBlackFaces is a constant NO, so the branch that
    // fitted the gutter mask was never taken.
    pulse.fields = [NSMutableArray arrayWithCapacity:2];
    pulse.blooms = [NSMutableArray arrayWithCapacity:2];
    pulse.groups = [NSMutableArray arrayWithCapacity:self.keyFrames.count];
    [self.layer addSublayer:pulse.container];
    return pulse;
}
- (void)discardWavePool {
    if (!_wavePulses.count) return;
    for (RKWavePulse *pulse in _wavePulses) [pulse.container removeFromSuperlayer];
    [_wavePulses removeAllObjects];
    // Tells the probe why the press that follows had to build its layers.
    RKProbeNoteNote("pool-drop");
}
// Picks the pulse this press draws into. While the pool has room, the press gets a pulse
// of its own -- which is what the old code did, since it only ever dropped a pulse once the
// limit was reached, so the number of waves visible at once is unchanged. At the limit the
// pulse that finishes soonest is reused, and that is the same pulse the old code evicted;
// an idle pulse is taken in preference when there is one. Both paths after warm-up are
// pure reuse: no layer is ever created once every pulse exists.
- (RKWavePulse *)wavePulseForArmingWithLimit:(NSUInteger)limit {
    while (_wavePulses.count > limit) {
        RKWavePulse *extra = _wavePulses.lastObject;
        [extra.container removeFromSuperlayer];
        [_wavePulses removeLastObject];
    }
    if (_wavePulses.count < limit) {
        RKWavePulse *fresh = [self newWavePulse];
        [_wavePulses addObject:fresh];
        return fresh;
    }
    CFTimeInterval now = CACurrentMediaTime();
    RKWavePulse *chosen = nil;
    for (RKWavePulse *pulse in _wavePulses) {
        if (pulse.activeUntil <= now) { chosen = pulse; break; }
        if (!chosen || pulse.activeUntil < chosen.activeUntil) chosen = pulse;
    }
    // Unreachable while limit >= 1, but keeps the method total: the pool is grown above.
    if (!chosen) {
        chosen = [self newWavePulse];
        [_wavePulses addObject:chosen];
    }
    return chosen;
}
// The ambient wash, pooled the same way: the two field layers and their radial blooms are
// built once, and a press only re-centres the blooms, re-colours them and re-runs the
// animations. `preservesBlackFaces` is always NO today, so the field that used to carry
// the key-gutter mask never does; the branch is left in place so the picture stays
// recognisable against the old code.
- (void)armAmbientOnPulse:(RKWavePulse *)pulse origin:(CGPoint)origin radius:(CGFloat)radius
                      hue:(CGFloat)hue mode:(NSInteger)mode duration:(CGFloat)duration
                   counts:(RKProbeCounts *)counts {
    CGFloat strength = _params.ambientStrength;
    CGFloat alpha = _params.opacity * strength;
    BOOL wanted = _params.ambientGlow && _params.backgroundFeedback && alpha > 0;
    if (!wanted) {
        if (pulse.ambient) {
            [pulse.ambient removeFromSuperlayer];
            pulse.ambient = nil;
            [pulse.fields removeAllObjects];
            [pulse.blooms removeAllObjects];
        }
        return;
    }
    CGFloat brightness = _params.brightness;
    BOOL justBuilt = NO;
    if (!pulse.ambient) {
        justBuilt = YES;
        pulse.ambient = [CALayer layer];
        pulse.ambient.name = @"keyboardAmbientGlow";
        RKDisableImplicitAnimations(pulse.ambient);
        pulse.ambient.frame = self.bounds;
        [pulse.container addSublayer:pulse.ambient];
        // Solid black mode has backlighting only; the optional wash belongs to other themes.
        for (NSUInteger pass = [self preservesBlackFaces] ? 1 : 0; pass < 2; pass++) {
            CALayer *field = [CALayer layer];
            field.name = pass ? @"gutterLight" : @"keyFaceWash";
            RKDisableImplicitAnimations(field);
            field.frame = self.bounds;
            [pulse.ambient addSublayer:field];
            if (pass) field.mask = [self gutterMaskForField:field];
            CAGradientLayer *bloom = [CAGradientLayer layer];
            bloom.type = kCAGradientLayerRadial;
            RKDisableImplicitAnimations(bloom);
            bloom.startPoint = CGPointMake(.5, .5);
            bloom.endPoint = CGPointMake(1, 1);
            bloom.locations = RKAnimConstant(RKConstAmbientLocations);
            bloom.opacity = 0;
            [field addSublayer:bloom];
            [pulse.fields addObject:field];
            [pulse.blooms addObject:bloom];
            RKProbeCount(counts, layersNew, 2);
        }
    }
    CGRect bloomFrame = CGRectMake(origin.x - radius, origin.y - radius, radius * 2, radius * 2);
    CGPoint bloomCentre = CGPointMake(origin.x, origin.y);
    // Three base colours for the press, not six: both blooms tint the same hues and differ
    // only in how much of them is allowed to show. Returning a +1 CGColor keeps the colour
    // space the system chose for the hue instead of routing it back through UIColor.
    CGColorRef inner = RKHueColor(hue, [self neonSaturation:.82], brightness);
    CGColorRef middle = RKHueColor(mode == 1 ? hue : fmod(hue + .13, 1), [self neonSaturation:.75], brightness);
    CGColorRef outer = RKHueColor(mode == 1 ? hue : fmod(hue + .25, 1), [self neonSaturation:.9], brightness);
    for (NSUInteger pass = 0; pass < pulse.blooms.count; pass++) {
        CAGradientLayer *bloom = pulse.blooms[pass];
        if (!CGRectEqualToRect(bloom.frame, bloomFrame)) {
            // The bloom is re-centred on the key that was just pressed. With implicit
            // actions disabled the write lands at once -- that is what "no travel" looks
            // like, and it is exactly what the build before the pool did (it rebuilt the
            // bloom instead of moving one, so there was never an old centre to animate
            // from). With travel on, the move is re-created as an explicit animation that
            // resumes from wherever the last one had got to, so fast typing keeps the
            // continuous follow the pooled build produced.
            CGPoint previous = bloom.position;
            if ([bloom animationForKey:@"ambientGlide"]) {
                CALayer *shown = bloom.presentationLayer;
                if (shown) previous = shown.position;
            }
            bloom.frame = bloomFrame;
            if (!justBuilt && _params.ambientGlide) {
                CABasicAnimation *glide = [CABasicAnimation animationWithKeyPath:@"position"];
                glide.fromValue = [NSValue valueWithCGPoint:previous];
                glide.toValue = [NSValue valueWithCGPoint:bloomCentre];
                glide.duration = RKAmbientGlideDuration;
                glide.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionDefault];
                [bloom addAnimation:glide forKey:@"ambientGlide"];
            }
        }
        CGFloat level = alpha * (pass ? 1 : .24);
        NSMutableArray *colors = pulse.bloomColorBuffer;
        if (!colors) {
            colors = [NSMutableArray arrayWithCapacity:5];
            for (NSUInteger i = 0; i < 5; i++) [colors addObject:NSNull.null];
            pulse.bloomColorBuffer = colors;
        }
        CGColorRef ramp[5] = {
            RKCopiedAlpha(inner, level * .22),
            RKCopiedAlpha(inner, level * .6),
            RKCopiedAlpha(middle, level),
            RKCopiedAlpha(outer, level * .5),
            RKCopiedAlpha(outer, 0),
        };
        for (NSUInteger i = 0; i < 5; i++) {
            colors[i] = (__bridge id)ramp[i];
            CGColorRelease(ramp[i]);
        }
        bloom.colors = colors;
        CAKeyframeAnimation *spread = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        spread.values = RKAnimConstant(RKConstSpreadValues);
        spread.keyTimes = RKAnimConstant(RKConstSpreadKeyTimes);
        spread.duration = duration;
        [bloom addAnimation:spread forKey:@"ambientExpansion"];
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = RKAnimConstant(RKConstAmbientFadeValues);
        fade.keyTimes = RKAnimConstant(RKConstAmbientFadeKeyTimes);
        fade.duration = duration;
        [bloom addAnimation:fade forKey:@"ambientFade"];
    }
    CGColorRelease(inner);
    CGColorRelease(middle);
    CGColorRelease(outer);
}
- (void)showKeyWaveAtPoint:(CGPoint)point hue:(CGFloat)hue mode:(NSInteger)mode
                 startedAt:(double)startedAt {
    const NSUInteger keyCount = _keyFrameRectCount;
    if (!keyCount || !_keyFrameRects) return;
    double armStart = RKProbeTic();
    RKProbeCounts counts = {0};
    // Recorded so a log line can prove which value the renderer actually resolved, rather
    // than which value Settings saved -- those two are not the same thing when a key is
    // missing from the cross-process wire format.
    counts.glide = _params.ambientGlide ? 1 : 0;
    CGFloat alpha = _params.opacity;
    CGFloat brightness = _params.brightness;
    CGFloat duration = _params.duration;
    CGFloat travel = _params.backgroundDurationKeyWave;
    CGFloat spread = _params.spread;
    CGFloat reach = _params.backgroundRadius * spread / 2;
    CGFloat band = _params.backgroundBand;
    CGFloat strength = _params.backgroundStrengthKeyWave;
    CGFloat core = _params.core;
    BOOL propagate = _params.backgroundFeedback;
    CGRect pressed = CGRectNull;
    NSUInteger pressedIndex = NSNotFound;
    CGFloat nearest = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < keyCount; i++) {
        CGRect rect = _keyFrameRects[i];
        CGFloat dx = MAX(MAX(CGRectGetMinX(rect) - point.x, 0), point.x - CGRectGetMaxX(rect));
        CGFloat dy = MAX(MAX(CGRectGetMinY(rect) - point.y, 0), point.y - CGRectGetMaxY(rect));
        CGFloat distance = hypot(dx, dy);
        if (distance < nearest) { nearest = distance; pressed = rect; pressedIndex = i; }
    }
    // Ignore touches in padding / language-switch strips outside the actual keys.
    if (pressedIndex == NSNotFound || nearest > 14) return;
    CGPoint origin = CGPointMake(CGRectGetMidX(pressed), CGRectGetMidY(pressed));
    RKWavePulse *pulse = [self wavePulseForArmingWithLimit:MAX((NSUInteger)1, _params.maxEffects)];
    CFTimeInterval now = [pulse.container convertTime:CACurrentMediaTime() fromLayer:nil];
    CGFloat tail = duration * (.45 + band);
    [self armAmbientOnPulse:pulse origin:origin radius:reach hue:hue mode:mode
                   duration:travel + tail counts:&counts];
    double colorSec = 0, animSec = 0;
    for (NSUInteger keyIndex = 0; keyIndex < keyCount; keyIndex++) {
        CGRect rect = _keyFrameRects[keyIndex];
        BOOL touched = keyIndex == pressedIndex;
        CGFloat distance = hypot(CGRectGetMidX(rect) - origin.x, CGRectGetMidY(rect) - origin.y);
        if ((!propagate && !touched) || distance > reach) continue;
        CGFloat progress = MIN(1, distance / reach);
        CGFloat keyHue = mode == 1 ? hue : fmod(hue + progress * .24, 1);
        // Geometry: reused if this key has been lit before, built once if not. Everything
        // below this line is a value write on layers that already exist, and with the
        // implicit actions disabled each write lands without building a default animation.
        RKKeyWaveGroup *group = [self keyWaveGroupInPulse:pulse index:keyIndex rect:rect counts:&counts];
        RKInstallKeyWaveVariant(group, touched ? 2 : 1);
        double colorStart = RKProbeTic();
        // The rim width, the shadow's radius and its outline are functions of the variant
        // or the configuration, so they are written where those are. What is left here is
        // the hue, and each alpha variant is a copy of one CGColor rather than another
        // UIColor plus the CGColor that comes out of it.
        CGColorRef first = RKHueColor(keyHue, [self neonSaturation:.78], brightness);
        CGColorRef last = RKHueColor(mode == 1 ? hue : fmod(keyHue + .12, 1), [self neonSaturation:.9], brightness);
        if ([self preservesBlackFaces]) {
            group.halo.fillColor = UIColor.clearColor.CGColor;
        } else {
            CGColorRef fill = RKCopiedAlpha(first, touched ? core * .45 : strength * .12);
            group.halo.fillColor = fill;
            CGColorRelease(fill);
        }
        CGColorRef stroke = RKCopiedAlpha(first, .7);
        group.halo.strokeColor = stroke;
        CGColorRelease(stroke);
        group.halo.shadowColor = first;
        group.edgeColors[0] = (__bridge id)first;
        group.edgeColors[1] = (__bridge id)last;
        group.edge.colors = group.edgeColors;
        CGColorRelease(first);
        CGColorRelease(last);
        colorSec += RKProbeTic() - colorStart;
        // The fade's shape and duration are constants or configuration, set when the group
        // was built; only the start time moves per key. The peak rides on the layer's own
        // opacity, which is why the animation can be one shared curve.
        group.key.opacity = alpha * (1 - progress * .42);
        double animStart = RKProbeTic();
        CAKeyframeAnimation *fade = group.fade;
        fade.beginTime = now + progress * travel;
        [group.fader addAnimation:fade forKey:@"keyWave"];
        animSec += RKProbeTic() - animStart;
        counts.keys++;
    }
    counts.colorSec = colorSec;
    counts.animSec = animSec;
    // Nothing is torn down here any more: the pulse stays in the tree (invisible, its
    // model opacity is 0) and the next press re-arms it. Removing it, and rebuilding it
    // for the press after that, was most of what a keystroke used to cost.
    pulse.activeUntil = now + travel + tail + .05;
    double armEnd = RKProbeTic();
    RKProbeRecordWave(0, armEnd - armStart, armEnd - startedAt, counts);
}
// One key's layers, built on first use and kept afterwards. Both rim-width variants
// are built together, because which one is used depends on whether this key ends up being
// the one under the finger. Everything that does not depend on the press -- the shadow's
// blur and outline, the rim's fill rule, the fade's shape and start value -- is set once
// here, so the press path only writes what actually moves.
- (RKKeyWaveGroup *)keyWaveGroupInPulse:(RKWavePulse *)pulse index:(NSUInteger)index
                                   rect:(CGRect)rect counts:(RKProbeCounts *)counts {
    while (pulse.groups.count <= index) [pulse.groups addObject:NSNull.null];
    id existing = pulse.groups[index];
    if (existing != NSNull.null) {
        RKProbeCount(counts, groupsReused, 1);
        return existing;
    }
    UIBezierPath *faceOutline = RKKeyboardKeyFacePath(rect);
    RKKeyWaveGroup *group = [RKKeyWaveGroup new];
    group.key = [CALayer layer];
    group.key.name = @"keyWave";
    group.key.opacity = 0;
    RKDisableImplicitAnimations(group.key);
    // Everything visual sits under this one, which carries the fade. The key above it
    // holds the press's peak as its opacity, so the fade itself is a constant curve and
    // the press has no per-key animation values to build.
    group.fader = [CALayer layer];
    group.fader.name = @"keyWaveFade";
    // It is the layer the fade plays on, so its own value has to be the "off" state: the
    // animation is removed when it finishes, and whatever the model holds then is what the
    // key shows. (A layer's opacity defaults to 1, so leaving this out would leave every
    // key that was ever lit visibly glowing for good.)
    group.fader.opacity = 0;
    RKDisableImplicitAnimations(group.fader);
    group.halo = [CAShapeLayer layer];
    group.halo.shadowOffset = CGSizeZero;
    group.halo.shadowOpacity = .8;
    // Configuration, not press: set once here, and again only if the configuration
    // changes and the pool is rebuilt.
    group.halo.shadowRadius = _params.softness * .6;
    RKDisableImplicitAnimations(group.halo);
    group.edge = [CAGradientLayer layer];
    group.edge.startPoint = CGPointZero;
    group.edge.endPoint = CGPointMake(1, 1);
    RKDisableImplicitAnimations(group.edge);
    group.rim = [CAShapeLayer layer];
    // A filled outer ring keeps its full visible width after the black-face
    // exclusion mask; a centered stroke would lose its inner half.
    group.rim.fillRule = kCAFillRuleEvenOdd;
    group.rim.fillColor = UIColor.whiteColor.CGColor;
    RKDisableImplicitAnimations(group.rim);
    group.edge.mask = group.rim;
    group.edgeColors = [NSMutableArray arrayWithObjects:NSNull.null, NSNull.null, nil];
    group.fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    group.fade.values = RKAnimConstant(RKConstKeyFadeValues);
    group.fade.keyTimes = RKAnimConstant(RKConstKeyFadeKeyTimes);
    group.fade.duration = _params.duration * (.45 + _params.backgroundBand);
    [group.fader addSublayer:group.halo];
    [group.fader addSublayer:group.edge];
    [group.key addSublayer:group.fader];
    [pulse.container addSublayer:group.key];
    // The two variants go through locals: a property expression has no address to give.
    UIBezierPath *outline = nil, *outer = nil;
    CGRect variantFrame = CGRectZero;
    RKKeyWaveVariants(faceOutline, 2.6, &outline, &outer, &variantFrame);
    group.outlinePlain = outline;
    group.outerPlain = outer;
    group.framePlain = variantFrame;
    RKKeyWaveVariants(faceOutline, 3.0, &outline, &outer, &variantFrame);
    group.outlineWide = outline;
    group.outerWide = outer;
    group.frameWide = variantFrame;
    pulse.groups[index] = group;
    RKProbeCount(counts, groupsNew, 1);
    RKProbeCount(counts, layersNew, 5);   // key, fader, halo, edge, rim
    RKProbeCount(counts, pathsNew, 5);   // the face outline plus inner/outer per variant
    return group;
}
- (void)showRippleAtPoint:(CGPoint)point {
    [self showRippleAtPoint:point sourceView:nil];
}
- (void)showRippleAtPoint:(CGPoint)point sourceView:(UIView *)sourceView {
    double pressStart = RKProbeTic();
    // Push-driven: the configuration is re-resolved by RKPreferencesChangedCallback, and
    // this call is only the fallback for a push missed while this extension was suspended.
    // On the ordinary path it is one float compare, where the old code took a lock and
    // made two notify round-trips on every keystroke.
    [self refreshConfigurationIfStale];
    if (!_params.enabled || !_params.rippleEnabled || !_params.keyboardEnabled) {
        for (CALayer *l in self.layer.sublayers.copy) [l removeFromSuperlayer];
        [self discardWavePool];
        return;
    }
    NSInteger style = _params.style;
    if (style != self.lastStyle) {
        for (CALayer *layer in self.layer.sublayers.copy) [layer removeFromSuperlayer];
        [self discardWavePool];
        self.lastStyle = style;
    }
    CGFloat alpha = _params.opacity;
    CGFloat brightness = _params.brightness;
    CGFloat duration = _params.duration;
    CGFloat spread = _params.spread;
    CGFloat softness = _params.softness;
    CGFloat core = _params.core;
    NSUInteger limit = _params.maxEffects;
    NSInteger mode = _params.colorMode;
    self.hue = fmod(self.hue + .137, 1);
    CGFloat hue = mode == 1 ? _params.hue : (mode == 2 ? point.x / MAX(1,self.bounds.size.width) : self.hue);
    if (style == 0) {
        // The wave pool owns its own capacity -- it re-arms a finished pulse, or the one
        // that finishes soonest -- so the generic eviction below is skipped here. Counting
        // pooled layers as if they were live waves would evict the pool itself.
        [self showKeyWaveAtPoint:point hue:hue mode:mode startedAt:pressStart];
        return;
    }
    while (self.layer.sublayers.count >= limit) [self.layer.sublayers.firstObject removeFromSuperlayer];
    if (style == 2) {
        for (NSValue *value in self.keyFrames) {
            if (!CGRectContainsPoint(value.CGRectValue, point)) continue;
            self.pressHue = fmod(self.pressHue + .38196601125, 1);
            // 「亮色模式」（彩色/单色）已移除：轻弹固定使用逐次换色的鲜艳纯色。
            UIColor *color = [UIColor colorWithHue:self.pressHue saturation:1 brightness:1 alpha:1];
            RKShowNeonKeyPress(self, value.CGRectValue, color,
                _params.pressBrightness,
                duration, UIAccessibilityIsReduceMotionEnabled(), sourceView);
            break;
        }
        return;
    }
    CGFloat radius = MIN(160, MAX(24, self.bounds.size.width / 10.0 * spread));
    CALayer *pulse = [CALayer layer];
    pulse.frame = self.bounds;
    pulse.opacity = 1; // Child layers own their final transparent states.
    [self.layer addSublayer:pulse];
    // A wide radial band travels outward from this touch. It shares the
    // keyboard exclusion mask and has no whole-keyboard solid background.
    CGFloat waveTime = duration;
    if (_params.backgroundFeedback) {
        CGFloat reach = _params.backgroundRadius;
        CGFloat width = _params.backgroundBand;
        CGFloat strength = _params.backgroundStrengthWide;
        waveTime = _params.backgroundDurationWide;
        CAGradientLayer *wave = [CAGradientLayer layer];
        wave.type = kCAGradientLayerRadial;
        wave.frame = CGRectMake(point.x-reach,point.y-reach,reach*2,reach*2);
        wave.startPoint = CGPointMake(.5,.5);
        wave.endPoint = CGPointMake(1,1); // Nonzero radial extent on both axes.
        UIColor *c = [UIColor colorWithHue:hue saturation:[self neonSaturation:.8] brightness:brightness alpha:1];
        UIColor *edge = mode == 1 ? c : [UIColor colorWithHue:fmod(hue+.14,1)
            saturation:[self neonSaturation:.85] brightness:brightness alpha:1];
        wave.colors = @[(id)[c colorWithAlphaComponent:0].CGColor,
                        (id)[c colorWithAlphaComponent:0].CGColor,
                        (id)[c colorWithAlphaComponent:strength].CGColor,
                        (id)[edge colorWithAlphaComponent:strength*.5].CGColor,
                        (id)[edge colorWithAlphaComponent:0].CGColor];
        wave.locations = @[@0,@(1-width),@(1-width*.55),@(1-width*.2),@1];
        wave.opacity = 0;
        [pulse addSublayer:wave];
        CABasicAnimation *travel = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        travel.fromValue = @.025; travel.toValue = @1; travel.duration = waveTime;
        travel.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        [wave addAnimation:travel forKey:@"travelFromTouch"];
        CAKeyframeAnimation *waveFade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        waveFade.values = @[@0,@1,@.85,@0]; waveFade.keyTimes = @[@0,@.06,@.65,@1];
        waveFade.duration = waveTime;
        [wave addAnimation:waveFade forKey:@"waveFade"];
    }
    NSMutableArray *colors = [NSMutableArray array];
    for (NSInteger i=0;i<5;i++) {
        CGFloat h = mode == 1 ? hue : fmod(hue + i * .12, 1);
        [colors addObject:(id)[UIColor colorWithHue:h saturation:[self neonSaturation:.85] brightness:brightness alpha:1].CGColor];
    }
    CAGradientLayer *rainbow = [CAGradientLayer layer];
    rainbow.frame = self.bounds;
    rainbow.colors = colors;
    rainbow.startPoint = CGPointMake(0,0);
    rainbow.endPoint = CGPointMake(1,1);
    [pulse addSublayer:rainbow];
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = self.bounds;
    ring.fillColor = UIColor.clearColor.CGColor;
    ring.strokeColor = UIColor.whiteColor.CGColor;
    ring.lineWidth = 4 + softness * .4;
    ring.shadowColor = UIColor.whiteColor.CGColor;
    ring.shadowOpacity = .8;
    ring.shadowRadius = softness;
    ring.shadowOffset = CGSizeZero;
    UIBezierPath *start = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(point.x-3,point.y-3,6,6)];
    UIBezierPath *end = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(point.x-radius,point.y-radius,2*radius,2*radius)];
    ring.path = end.CGPath;
    rainbow.mask = ring;
    CABasicAnimation *expand = [CABasicAnimation animationWithKeyPath:@"path"];
    expand.fromValue = (__bridge id)start.CGPath;
    expand.toValue = (__bridge id)end.CGPath;
    expand.duration = duration;
    expand.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [ring addAnimation:expand forKey:@"expand"];
    CALayer *flash = [CALayer layer];
    flash.frame = CGRectMake(point.x-9,point.y-9,18,18);
    flash.cornerRadius = 9;
    UIColor *tint = [UIColor colorWithHue:hue saturation:[self neonSaturation:.5] brightness:brightness alpha:1];
    flash.backgroundColor = tint.CGColor;
    flash.shadowColor = tint.CGColor;
    flash.shadowRadius = softness;
    flash.shadowOpacity = .8;
    flash.shadowOffset = CGSizeZero;
    flash.opacity = 0;
    [pulse addSublayer:flash];
    CABasicAnimation *flashFade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    flashFade.fromValue = @(core); flashFade.toValue = @0; flashFade.duration = MIN(.2,duration*.5);
    [flash addAnimation:flashFade forKey:@"flash"];
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.values = @[@0,@(alpha),@(alpha*.6),@0];
    fade.keyTimes = @[@0,@.08,@.45,@1];
    fade.duration = duration;
    rainbow.opacity = 0;
    [rainbow addAnimation:fade forKey:@"fade"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((MAX(duration,waveTime)+.05)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [pulse removeFromSuperlayer]; });
}
@end
