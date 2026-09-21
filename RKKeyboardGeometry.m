#import "RKKeyboardGeometry.h"
#import "RainbowEffectView.h"
#import <math.h>

BOOL RKKeyboardExcludedView(UIView *view) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    for (NSString *part in @[@"candidate", @"prediction", @"suggestion", @"toolbar",
        @"accessory", @"dock", @"clipboard", @"shortcut", @"popup", @"editingbar"])
        if ([name containsString:part]) return YES;
    return [view isKindOfClass:RainbowEffectView.class];
}

UIView *RKKeyboardEffectHost(UIView *view) {
    UIView *fallback = nil;
    for (UIView *parent = view; parent && ![parent isKindOfClass:UIWindow.class]; parent = parent.superview) {
        if (RKKeyboardExcludedView(parent)) return nil;
        NSString *name = NSStringFromClass(parent.class).lowercaseString;
        if ([name containsString:@"keyboardlayoutstar"]) return parent;
        // Remote input containers also contain the dock, not just key rows.
        BOOL container = NO;
        for (NSString *part in @[@"inputset", @"itemcontainer", @"trackingwindow", @"placeholder", @"compatinput"])
            container |= [name containsString:part];
        if (container) break;
        if (!fallback && ([name containsString:@"keyboard"] || [name containsString:@"keyplane"]) &&
            parent.bounds.size.width > 180 && parent.bounds.size.height > 100 && parent.bounds.size.height < 500)
            fallback = parent;
    }
    return fallback;
}

UIBezierPath *RKKeyboardKeyFacePath(CGRect keyFrame) {
    CGRect face = CGRectInset(keyFrame, MIN(2.5, keyFrame.size.width * .065), 2);
    CGFloat corner = MIN(5, MIN(face.size.width, face.size.height) * .16);
    return [UIBezierPath bezierPathWithRoundedRect:face cornerRadius:corner];
}

// Private selectors vary by OS release. Validate their ABI before invoking them.
static NSInvocation *RKGetter(id object, NSString *name, const char *type) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, type)) return nil;
    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = object;
    call.selector = selector;
    [call invoke];
    return call;
}

static id RKObject(id object, NSString *name) {
    NSInvocation *call = RKGetter(object, name, @encode(id));
    __unsafe_unretained id result = nil;
    [call getReturnValue:&result];
    return result;
}

static CGRect RKRect(id object, NSString *name) {
    NSInvocation *call = RKGetter(object, name, @encode(CGRect));
    CGRect result = CGRectZero;
    [call getReturnValue:&result];
    return result;
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

static void RKViewKeys(UIView *node, UIView *host, NSMutableArray *frames, NSUInteger depth) {
    if (depth > 12 || frames.count >= 100) return;
    for (UIView *view in node.subviews) {
        if (view.hidden || view.alpha < .01 || RKKeyboardExcludedView(view)) continue;
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        BOOL key = [view isKindOfClass:UIButton.class] || [name containsString:@"keycap"] ||
            [name containsString:@"keyview"] || [name containsString:@"keybutton"];
        CGRect rect = [view convertRect:view.bounds toView:host];
        if (key && RKValidKeyRect(rect, host.bounds)) RKAddKey(frames, rect, host.bounds);
        else RKViewKeys(view, host, frames, depth + 1);
    }
}

NSArray<NSValue *> *RKKeyboardKeyFrames(UIView *host) {
    NSMutableArray *frames = [NSMutableArray array];
    id plane = RKObject(host, @"keyplane");
    id keys = RKObject(plane, @"keys");
    if ([keys isKindOfClass:NSArray.class] || [keys isKindOfClass:NSSet.class]) {
        for (id key in keys) {
            BOOL ghost = NO;
            NSInvocation *visibility = RKGetter(key, @"ghost", @encode(BOOL));
            [visibility getReturnValue:&ghost];
            if (ghost) continue;
            BOOL visible = YES;
            NSInvocation *visibleGetter = RKGetter(key, @"visible", @encode(BOOL));
            [visibleGetter getReturnValue:&visible];
            if (!visible) continue;
            CGRect rect = RKRect(key, @"displayFrame");
            if (!RKValidKeyRect(rect, host.bounds)) rect = RKRect(key, @"frame");
            RKAddKey(frames, rect, host.bounds);
        }
    }
    if (frames.count < 3) {
        [frames removeAllObjects];
        RKViewKeys(host, host, frames, 0);
    }
    return frames;
}
