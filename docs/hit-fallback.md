# 命中判定的「兜底」代码留档（2.3.33 删除）

**这个文件存在的唯一目的**：如果将来**微信输入法升级**后出现「整键无光」，说明它的视图结构
变了、我们那条拾取启发式不再成立 —— 照本文把兜底加回来即可。

- **含兜底+探针的最后版本** = `2.3.32`，git 提交 `ce535d5`，git tag **`v2.3.32-with-fallback`**。
- 想直接看当时完整实现：`git show v2.3.32-with-fallback:RainbowEffectView.m`
- 想对比删了什么：`git diff v2.3.32-with-fallback HEAD -- RainbowEffectView.m`

---

## 一、为什么删（2.3.32 实机探针，400 条样本 / 含 74 次九宫格空格）

| 指标 | 结果 |
|---|---|
| 微信判定给出答案 `W=1` | 398 / 400 |
| 主路径命中 `B=0`（微信与表结论一致） | 398 |
| 兜底：表覆盖 `B=1` | **0** |
| 兜底：最近键吸附 `B=2` | 2 |
| 无光 `B=3` | 0 |
| 九宫格空格命中 `139,171 153x50` | **74 / 74** |

那 2 条 `B=2` 的**现场**（这是关键证据）：

```
#222 p=202,56  B=2 W=0 R=173,59 84x50
  chain: [0] WBKeyView  173.0,59.0 84.3x50.0      ← touch.view 本身就是「5」键
#331 p=229,167 B=2 W=0 R=173,115 84x50
  chain: [0] WBKeyView  173.0,115.0 84.3x50.0     ← touch.view 本身就是「8」键
```

**`W=0` 不是微信失败，是我们自己把它的答案拒了**：原判据用 `CGRectInset(button, -2, -2)`
做含点检查，而
- #222 落点 y=56 比键顶 y=59 高 **3pt** > 2pt ⇒ 拒；
- #331 落点 y=167 压在键底 y=165 上，`CGRectContainsPoint` 对 `maxY` 是**开区间** ⇒ 拒。

两条落点都在 **6pt 宽的键缝里**。兜底接手后算出来的 `173,59` / `173,115`
**和微信给的答案一模一样** ⇒ **兜底从未提供过微信给不出的信息，是纯冗余。**

⇒ 2.3.33 删兜底，同时把容差 **2pt → 6pt**（键缝与行距都是 6pt，落点掉进缝里最多偏离
最近键 3pt；6pt 让微信的答案稳稳接住这类边缘按压，又不会越到隔壁键）。

---

## 二、删除后主路径长什么样（2.3.33）

`RainbowEffectView.m`：

```objc
- (CGRect)resolvePressedKeyFrameAtPoint:(CGPoint)point sourceView:(UIView *)sourceView {
    CGRect button = self.touchKeyRect;
    if (CGRectIsNull(button) || CGRectIsEmpty(button)) {
        button = sourceView ? RKKeyRectFromSourceView(sourceView, self.superview, point) : CGRectNull;
    }
    if (CGRectIsNull(button)) return CGRectNull;
    if (!CGRectContainsPoint(CGRectInset(button, -6, -6), point)) return CGRectNull;
    return button;
}
```

---

## 三、怎么加回来（恢复步骤）

### 步骤 1 — 恢复 `RKKeyRow` 类（放回 `@implementation RKKeyWaveGeometry @end` 之后）

```objc
// 命中索引的一「行」：键位表按行的顶边分桶，行内按键按 x 升序排列。
@interface RKKeyRow : NSObject
@property(nonatomic) CGRect bounds;                 // 该行的联合包围盒
@property(nonatomic,strong) NSArray<NSValue *> *keys; // 行内键，按 minX 升序
@end
@implementation RKKeyRow
@end
```

### 步骤 2 — 恢复属性（加回 `RainbowEffectView ()` 分类里，`keyBedBounds` 旁边）

```objc
@property(nonatomic,strong) NSArray<RKKeyRow *> *keyHitRows;
```

### 步骤 3 — 恢复两个 static 函数（放在 `RKKeyRectFromSourceView` 之前）

```objc
// 键位表 → 行索引：按行的顶边分桶（容差固定 8pt），行按 y 升序、行内按 x 升序。
// ⛔ 分桶容差必须与「行内键的并集高度」无关 —— 绝不能取 row.bounds.height × .5：
//    bounds 是一路 union 出来的，某个高矩形（跨行容器/宽键）并进来后容差就跟着变大，
//    下一排也被并进这一行、bounds 再涨，连锁成一整块，覆盖判定就只剩 x 在起作用。
static NSArray<RKKeyRow *> *RKBuildKeyHitRows(NSArray<NSValue *> *keyFrames) {
    if (!keyFrames.count) return @[];
    NSArray<NSValue *> *sorted = [keyFrames sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGRect ra = a.CGRectValue, rb = b.CGRectValue;
        if (ra.origin.y != rb.origin.y) return ra.origin.y < rb.origin.y ? NSOrderedAscending : NSOrderedDescending;
        if (ra.origin.x != rb.origin.x) return ra.origin.x < rb.origin.x ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<RKKeyRow *> *rows = [NSMutableArray array];
    for (NSValue *value in sorted) {
        CGRect rect = value.CGRectValue;
        RKKeyRow *row = rows.lastObject;
        if (row) {
            if (fabs(rect.origin.y - CGRectGetMinY(row.bounds)) > 8.0) row = nil;
        }
        if (!row) {
            row = [RKKeyRow new];
            row.bounds = rect;
            row.keys = [NSMutableArray array];
            [rows addObject:row];
        }
        row.bounds = CGRectUnion(row.bounds, rect);
        [(NSMutableArray *)row.keys addObject:value];
    }
    return rows;
}

// 行内按 x 找水平距离最近的键：二分出落点两侧相邻的两个键，取距离小者。
static NSInteger RKKeyRowNearestIndexAtX(RKKeyRow *row, CGFloat x) {
    NSArray<NSValue *> *keys = row.keys;
    if (!keys.count) return NSNotFound;
    NSUInteger lo = 0, hi = keys.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (x < CGRectGetMinX(keys[mid].CGRectValue)) hi = mid;
        else lo = mid + 1;
    }
    NSInteger candidates[2] = {
        lo > 0 ? (NSInteger)(lo - 1) : NSNotFound,
        lo < keys.count ? (NSInteger)lo : NSNotFound,
    };
    NSInteger best = NSNotFound;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < 2; i++) {
        NSInteger index = candidates[i];
        if (index == NSNotFound) continue;
        CGRect rect = keys[index].CGRectValue;
        CGFloat dx = 0;
        if (x < CGRectGetMinX(rect)) dx = CGRectGetMinX(rect) - x;
        else if (x > CGRectGetMaxX(rect)) dx = x - CGRectGetMaxX(rect);
        if (dx < bestDistance) { bestDistance = dx; best = index; }
    }
    return best;
}
```

### 步骤 4 — 在 `setKeyFrames:` 里重建索引（`self.cachedWaveGeometries = geometries;` 之后）

```objc
    self.keyHitRows = RKBuildKeyHitRows(_keyFrames);
```

### 步骤 5 — 把 `resolvePressedKeyFrameAtPoint:` 换成「微信优先 + 懒执行兜底」版

```objc
- (CGRect)resolvePressedKeyFrameAtPoint:(CGPoint)point sourceView:(UIView *)sourceView {
    CGRect resolved = CGRectNull;
    do {
        // 一、先问微信自己：「这一下打在哪个按钮上」—— 命中即返回。
        CGRect button = self.touchKeyRect;
        if (CGRectIsNull(button) || CGRectIsEmpty(button)) {
            button = sourceView ? RKKeyRectFromSourceView(sourceView, self.superview, point) : CGRectNull;
        }
        if (!CGRectIsNull(button) && !CGRectContainsPoint(CGRectInset(button, -6, -6), point)) button = CGRectNull;
        if (!CGRectIsNull(button)) { resolved = button; break; }

        // ---- 以下全是兜底：只在微信没给出答案时才跑，正常按键一次都不执行 ----
        NSArray<RKKeyRow *> *rows = self.keyHitRows;
        if (!rows.count) break;

        // 二、键位表覆盖：严格「落点落在键帽矩形内」，取面积最小者。
        //     ⛔ x 与 y 两个判据一个都不能少 —— 2.3.24 索引化时丢掉 y 复查，
        //        导致九宫格按空格亮 7/8/9（2.3.31 才定位修好）。
        CGRect pressed = CGRectNull;
        CGFloat pressedArea = CGFLOAT_MAX;
        for (RKKeyRow *row in rows) {
            if (point.y < CGRectGetMinY(row.bounds) || point.y > CGRectGetMaxY(row.bounds)) continue;
            for (NSValue *value in row.keys) {
                CGRect rect = value.CGRectValue;
                if (point.x < CGRectGetMinX(rect) || point.x > CGRectGetMaxX(rect)) continue;
                if (point.y < CGRectGetMinY(rect) || point.y > CGRectGetMaxY(rect)) continue;
                CGFloat area = rect.size.width * rect.size.height;
                if (area < pressedArea) { pressedArea = area; pressed = rect; }
            }
        }
        if (!CGRectIsNull(pressed)) { resolved = pressed; break; }

        // 三、最近键吸附 —— 微信认不出、表也没覆盖（如触摸落在键缝）。
        //     须落在键区包围盒外扩 8pt 内，挡住候选栏 / 工具条误触发。
        if (CGRectIsNull(self.keyBedBounds) ||
            !CGRectContainsPoint(CGRectInset(self.keyBedBounds, -8, -8), point)) break;
        CGRect nearest = CGRectNull;
        CGFloat nearestDistance = CGFLOAT_MAX;
        for (RKKeyRow *row in rows) {
            CGFloat dy = 0;
            if (point.y < CGRectGetMinY(row.bounds)) dy = CGRectGetMinY(row.bounds) - point.y;
            else if (point.y > CGRectGetMaxY(row.bounds)) dy = point.y - CGRectGetMaxY(row.bounds);
            if (dy > 26.0) continue;    // 粗筛：行 bounds 被撑大过，dy 只会偏小、不会漏行
            NSInteger index = RKKeyRowNearestIndexAtX(row, point.x);
            if (index == NSNotFound) continue;
            CGRect rect = row.keys[index].CGRectValue;
            CGFloat dx = 0;
            if (point.x < CGRectGetMinX(rect)) dx = CGRectGetMinX(rect) - point.x;
            else if (point.x > CGRectGetMaxX(rect)) dx = point.x - CGRectGetMaxX(rect);
            // ⛔ 距离必须按「键的实际矩形」算，不能用行 bounds —— 行 bounds 可能被跨行的
            //    高矩形撑大，用它会让这一行每个键都显得更近，末行落点又被吸到上一行的 7/8/9。
            CGFloat keyDy = 0;
            if (point.y < CGRectGetMinY(rect)) keyDy = CGRectGetMinY(rect) - point.y;
            else if (point.y > CGRectGetMaxY(rect)) keyDy = point.y - CGRectGetMaxY(rect);
            CGFloat distance = hypot(dx, keyDy);
            if (distance < nearestDistance) { nearestDistance = distance; nearest = rect; }
        }
        if (CGRectIsNull(nearest)) break;
        CGFloat maxSnap = MIN(26.0, MAX(8.0, nearest.size.height * .6));
        if (nearestDistance > maxSnap) break;
        resolved = nearest;
    } while (0);
    return resolved;
}
```

---

## 四、加回后的验证方法

1. 探针已随 2.3.33 一并删除（它是主路径上唯一的真开销：一次 `NSString` 格式化 +
   UTF-8 编码 + `NSFileHandle` + `open/lseek/write/close` ≈ 10~25 µs/按键）。
   要重新取证，从 tag 取回探针：
   `git show v2.3.32-with-fallback:RainbowEffectView.m`（里面 `RKLogResolve` / `RKHitLogMarkLoaded` 等一整段）。
2. 判定「兜底是否需要」的判据：探针里 **`W=0` 的占比**。
   - `W=0` 仍接近 0 ⇒ 微信判定依旧有效，兜底**不需要**；
   - `W=0` 明显上升或出现「整键无光」⇒ 微信视图结构变了，**把上面的兜底加回来**。
3. 顺带自查：`Tweak.xm` 的 `%ctor` 里要重新加 `RKHitLogMarkLoaded();`，
   `RainbowEffectView.h` 里要重新加 `FOUNDATION_EXPORT void RKHitLogMarkLoaded(void);`
   （`.xm` 按 ObjC++ 编译，不加 `FOUNDATION_EXPORT` 会因 C++ mangling 链接失败）。
