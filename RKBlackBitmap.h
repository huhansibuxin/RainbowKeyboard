#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Returns a new image only when a recognized keyboard surface was changed.
FOUNDATION_EXPORT CGImageRef RKCreateBlackKeyboardAtlas(CGImageRef image, BOOL backgroundOnly) CF_RETURNS_RETAINED;
FOUNDATION_EXPORT CGImageRef RKCreateColoredKeyboardAtlas(CGImageRef image, BOOL backgroundOnly,
    CGFloat red, CGFloat green, CGFloat blue) CF_RETURNS_RETAINED;
FOUNDATION_EXPORT CGImageRef RKCreateColoredKeyboardFace(CGImageRef image,
    CGFloat red, CGFloat green, CGFloat blue) CF_RETURNS_RETAINED;
