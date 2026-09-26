#import <Foundation/Foundation.h>
#import "RKBlackBitmap.h"

// Used only for an identified full-size key face, never for glyph atlases.
CGImageRef RKCreateColoredKeyboardFace(CGImageRef image, CGFloat red, CGFloat green, CGFloat blue) {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (CGImageIsMask(image) || width < 16 || height < 14 || width > 1024 || height > 512) return NULL;
    size_t count = width * height;
    NSMutableData *storage = [NSMutableData dataWithLength:count * 4];
    uint8_t *pixels = (uint8_t *)storage.mutableBytes;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    double samples[16][3] = {};
    BOOL valid[16] = {};
    for (NSUInteger i = 0; i < 16; i++) {
        double t = .15 + .7 * (i % 4) / 3.0;
        double x = i < 8 ? t : (i < 12 ? .15 : .85);
        double y = i < 4 ? .15 : (i < 8 ? .85 : t);
        uint8_t *p = pixels + ((size_t)(y * (height - 1)) * width + (size_t)(x * (width - 1))) * 4;
        valid[i] = p[3] >= 200;
        for (NSUInteger c = 0; c < 3; c++) samples[i][c] = p[3] ? p[c] * 255.0 / p[3] : 0;
    }
    NSUInteger best = 0, agreements = 0;
    for (NSUInteger i = 0; i < 16; i++) {
        if (!valid[i]) continue;
        NSUInteger matches = 0;
        for (NSUInteger j = 0; j < 16; j++) {
            BOOL match = valid[j];
            for (NSUInteger c = 0; c < 3; c++) match &= fabs(samples[i][c] - samples[j][c]) <= 12;
            matches += match;
        }
        if (matches > agreements) { best = i; agreements = matches; }
    }
    if (agreements < 12) { CGContextRelease(context); return NULL; }
    double *matte = samples[best];
    NSUInteger background = 0, dark = 0, light = 0;
    double matteMean = (matte[0] + matte[1] + matte[2]) / 3;
    for (size_t i = 0; i < count; i++) {
        uint8_t *p = pixels + i * 4;
        if (p[3] < 200) continue;
        BOOL match = YES;
        double mean = 0;
        for (NSUInteger c = 0; c < 3; c++) {
            double value = p[c] * 255.0 / p[3];
            match &= fabs(value - matte[c]) <= 12;
            mean += value / 3;
        }
        background += match;
        dark += mean < matteMean - 35;
        light += mean > matteMean + 35;
    }
    if (background < count * .55) { CGContextRelease(context); return NULL; }
    double foreground = dark > light && matteMean > 140 ? 0 : 255;
    double direction[3], norm = 0, color[3] = {red, green, blue};
    for (NSUInteger c = 0; c < 3; c++) {
        direction[c] = foreground - matte[c];
        norm += direction[c] * direction[c];
        color[c] = isfinite(color[c]) ? MIN(1, MAX(0, color[c])) : 0;
    }
    for (size_t i = 0; i < count; i++) {
        uint8_t *p = pixels + i * 4;
        if (!p[3]) continue;
        double values[3], coverage = 0;
        for (NSUInteger c = 0; c < 3; c++) {
            values[c] = p[c] * 255.0 / p[3];
            coverage += (values[c] - matte[c]) * direction[c];
        }
        coverage = norm > 1 ? MIN(1, MAX(0, coverage / norm)) : 0;
        BOOL textOrFace = YES;
        for (NSUInteger c = 0; c < 3; c++)
            textOrFace &= fabs(values[c] - (matte[c] + coverage * direction[c])) <= 18;
        if (!textOrFace) continue; // Preserve colored symbols not on the matte-to-ink line.
        for (NSUInteger c = 0; c < 3; c++)
            p[c] = (uint8_t)lround(p[3] * (coverage + (1 - coverage) * color[c]));
    }
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

CGImageRef RKCreateBlackKeyboardAtlas(CGImageRef image, BOOL backgroundOnly) {
    return RKCreateColoredKeyboardAtlas(image, backgroundOnly, 0, 0, 0);
}

CGImageRef RKCreateColoredKeyboardAtlas(CGImageRef image, BOOL backgroundOnly,
                                       CGFloat red, CGFloat green, CGFloat blueColor) {
    CGFloat color[3] = {red, green, blueColor};
    for (NSUInteger c = 0; c < 3; c++)
        color[c] = isfinite(color[c]) ? MIN(1, MAX(0, color[c])) : 0;
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    if (!width || !height || width > 4096 || height > 2048 || width * height > 2097152) return NULL;
    size_t count = width * height;
    NSMutableData *storage = [NSMutableData dataWithLength:count * 4];
    uint8_t *pixels = (uint8_t *)storage.mutableBytes;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) return NULL;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    BOOL changed = NO;
    if (backgroundOnly) {
        for (size_t i = 0; i < count; i++) {
            uint8_t *p = pixels + i * 4;
            for (NSUInteger c = 0; c < 3; c++) {
                uint8_t value = (uint8_t)lround(color[c] * p[3]);
                changed |= p[c] != value;
                p[c] = value;
            }
        }
    } else {
        // iOS 17 can cache all keycaps in one image. Opaque connected components
        // separate key bodies without assuming QWERTY positions or a fixed scale.
        NSMutableData *seenStorage = [NSMutableData dataWithLength:count];
        NSMutableData *queueStorage = [NSMutableData dataWithLength:count * sizeof(uint32_t)];
        uint8_t *seen = (uint8_t *)seenStorage.mutableBytes;
        uint32_t *queue = (uint32_t *)queueStorage.mutableBytes;
        NSUInteger components = 0;
        for (size_t seed = 0; seed < count; seed++) {
            if (seen[seed] || pixels[seed * 4 + 3] <= 8) continue;
            if (++components > 4096) break;
            size_t head = 0, tail = 1;
            queue[0] = (uint32_t)seed;
            seen[seed] = 1;
            size_t minX = width, minY = height, maxX = 0, maxY = 0;
            NSUInteger gray = 0, blue = 0, histogram[256] = {};
            while (head < tail) {
                size_t index = queue[head++], x = index % width, y = index / width;
                minX = MIN(minX, x); maxX = MAX(maxX, x);
                minY = MIN(minY, y); maxY = MAX(maxY, y);
                uint8_t *p = pixels + index * 4;
                int low = MIN(p[0], MIN(p[1], p[2])) * 255 / p[3];
                int high = MAX(p[0], MAX(p[1], p[2])) * 255 / p[3];
                if (high - low <= 3 && low >= 8 && high <= 245) {
                    histogram[low]++;
                    gray++;
                }
                if (p[0] * 255 / p[3] < 5 && p[2] * 255 / p[3] > 100 &&
                    (p[2] - p[1]) * 255 / p[3] > 20) blue++;
                size_t neighbors[4] = {x ? index - 1 : index, x + 1 < width ? index + 1 : index,
                    y ? index - width : index, y + 1 < height ? index + width : index};
                for (NSUInteger n = 0; n < 4; n++) {
                    size_t next = neighbors[n];
                    if (seen[next] || pixels[next * 4 + 3] <= 8) continue;
                    seen[next] = 1;
                    queue[tail++] = (uint32_t)next;
                }
            }
            NSUInteger matte = 0;
            for (NSUInteger i = 8; i <= 245; i++)
                if (histogram[i] > histogram[matte]) matte = i;
            size_t area = (maxX - minX + 1) * (maxY - minY + 1);
            BOOL blueBody = blue > area / 4;
            BOOL grayBody = gray > area / 3 && histogram[matte] > area / 12;
            if ((!blueBody && !grayBody) || maxX - minX < 8 || maxY - minY < 8) continue;
            changed = YES;
            // Include the one-pixel antialiased boundary, keeping its alpha.
            minX = minX ? minX - 1 : 0; minY = minY ? minY - 1 : 0;
            maxX = MIN(width - 1, maxX + 1); maxY = MIN(height - 1, maxY + 1);
            for (size_t y = minY; y <= maxY; y++) {
                NSUInteger row[256] = {}, rowMatte = matte;
                if (!blueBody) {
                    for (size_t x = minX; x <= maxX; x++) {
                        uint8_t *p = pixels + (y * width + x) * 4;
                        if (p[3] <= 8) continue;
                        int low = MIN(p[0], MIN(p[1], p[2])) * 255 / p[3];
                        int high = MAX(p[0], MAX(p[1], p[2])) * 255 / p[3];
                        if (high - low <= 3 && abs(low - (int)matte) <= 12) row[low]++;
                    }
                    for (NSUInteger i = MAX(8, (int)matte - 12); i <= MIN(245, matte + 12); i++)
                        if (row[i] > row[rowMatte]) rowMatte = i;
                }
                for (size_t x = minX; x <= maxX; x++) {
                    uint8_t *p = pixels + (y * width + x) * 4;
                    int low = MIN(p[0], MIN(p[1], p[2])), high = MAX(p[0], MAX(p[1], p[2]));
                    if (!p[3]) continue;
                    if (!blueBody && high - low > 3) continue;
                    int white = blueBody ? low :
                        MAX(0, low * 255 - (int)rowMatte * p[3]) / (255 - (int)rowMatte);
                    white = MIN((int)p[3], white);
                    for (NSUInteger c = 0; c < 3; c++)
                        p[c] = (uint8_t)lround(white + (p[3] - white) * color[c]);
                }
            }
        }
    }
    CGImageRef result = changed ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    return result;
}
