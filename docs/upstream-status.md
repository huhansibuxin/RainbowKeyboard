# 上游比对：mowang7426/jianpan 1.2.1 → 1.2.2

> 采集时间：2026-10-03（初版）/ 2026-10-06（补充续更）
> 我们基线：`925dea9`（commit 说明「2.3.0 光效链路改用真正的上游 1.2.1 源代码(850a5b2)」）
> 上游最新：`5c1a421`（2026-10-06），`control` 里 `Version: 1.2.2`
> 关系：`compare/850a5b2...main` → **ahead = 58, behind = 0**（纯线性领先，无分叉）
> 另有一条未合入分支 `fix/safe-preferences-relay`（`fd4ab7a`）。

上游另有一个同名分支历史记录里提到的 `850a5b2` —— 那是上游 1.2.1 的 sha，我们通过本地
`git fetch upstream main` 拿到完整历史后再做比对（远端 API 对短 sha 直接 422）。

---

## 一、48 条提交按主题分组

| 组 | 日期 | 条数 | 主题 |
|---|---|---|---|
| ① | 09-26 | 19 | 微信键帽主题体系：预设主题（Sakura→Doraemon）、深色适配、26 键布局免遮挡、SpringBoard 启动期延迟 UIKit 主题刷新、候选栏绘制稳定化 |
| ② | 09-27 | 12 | 光效重构：new lighting → galaxy → simplify redesign → ARC 桥接 → replace → 强化 under-key → **remove galaxy** → restore glow → 系统键盘独立键帽主题 + day/night 预设 |
| ③ | 09-30 | 5 | 布局切换修复：清陈旧效果、symbol plane 切换重建遮罩、抑制切换期涟漪、switch 键涟漪延后到新键面落定、键帽方形阴影 |
| ④ | 10-01 | 6 | 候选栏 emoji 保色、Logos 原调用宏独占行、`1` 残留文件清理、「safe build disabling risky black keyboard hooks」（加即 revert） |
| ⑤ | 09-26~10-01 | 6 | 工程：新增 `Tests/` 2483 行、`RKDisplayTransport.h` +80、`RKThemeEngine.m` +161、设置页 `RKBRootListController.m` +279、defaults 系列大改、`control` +35 |

---

## 二、文件级 diff（`925dea9..upstream/main`，共 47 文件 / +6761 −795）

**光效与注入（核心）**

| 文件 | 改动 | 与我们的关系 |
|---|---|---|
| `RainbowEffectView.m` | 80 行 | 5 处 hunk，**全在 `RKEffectPreferencesChanged`**，我们的 `resolvePressedKeyFrameAtPoint:` 一行没被碰 |
| `Tweak.xm` | 25 行 | 布局切换分支加「清旧 + 延迟重放涟漪」 |
| `RKDisplayTransport.h` | 80 行 | ⚠️ 见冲突 A |
| `RKThemeEngine.m/.h` | +161/+11 | 上游主题引擎，我们未改 |
| `RKKeyboardGeometry.m` | 7 行 | 圆角键面几何 |
| `RKBlackBitmap.h/.m`、`RKBlackProbe.h` | +313 | 上游「黑键盘」安全版，已进编译 |
| `RKBlackKeyboardHost.m` | −10 | 上游旧版黑键盘宿主（已从编译单元移除） |
| `RKCandidateEmoji.h/.m`、`RKCandidateInk.h`、`RKCandidateEmojiData.h` | +379 | 候选栏 emoji 保色，未进主编译单元 |

**设置页与配置**

| 文件 | 改动 |
|---|---|
| `RainbowKeyboardPrefs/RKBRootListController.m` | +279（主题/深浅色/emoji 新面板） |
| `RainbowKeyboardPrefs/Resources/RainbowKeyboard.plist` | +123 |
| `RainbowKeyboardPrefs/Resources/defaults.plist` | +27 |
| `defaults.plist` | +26 |
| `controls` | +35（版本号与说明） |

---

## 三、⚠️ 冲突清单（这是"能不能合"的本质）

### A. `RKDisplayTransport.h` 位域硬冲突 —— 必须先解决

- **我们**：`WidenVoiceButton` 占 `words[1]` 的 **bit 54（存在位）+ bit 55（值位）**
  （`RKDisplayTransport.h` L113-114 / L187）。
- **上游新版**：`WeChatTheme` 用 `words[1] |= (value & 3) << 54` —— **低 2 位正好落在 54、55**
  （第二个字 `words[5]` 则存完整 0..8）。
- 后果：只要 `prefs[@"WeChatTheme"]` 存在（老板若选过微信主题），encode 会把 bit55 写成
  `(WeChatTheme>>1)&1` ⇒ **语音按钮加宽被静默关掉（WeChatTheme 偶数）或凭空打开（奇数）**。
- 两边 `RKDisplayWordCount` 都是 **15**，位空间够，挪位即可。
- 可选空位：`words[1]` 的 bit 47 / 48 / 49（已占用的是 41/42/43/44/45/46/50/51/52/53，
  56-62 是 magic `0xD1 << 56`）。

### B. `traitCollectionDidChange:` 双定义

- 上游新版在 `RainbowEffectView.m` 新增该重载（负责 `AppearanceModes` 切换后 `reloadConfiguration`
  + 清 pulse 层）。
- 我们 2.3.31 自己也写了这个重载（负责 `effectiveLightPop` 深浅色跟随重算）。
- ⛔ 直接整文件覆盖会丢轻弹的深浅色跟随 ⇒ 必须**合并实现**，而不是二选一。

### C. 键床遮罩改为「圆角键面切洞」（可合，但要回归观感）

上游删掉了 `usesNativeNineKeyBed` 分支，两处遮罩统一走 `RKKeyboardKeyFacePath`，
注释明确写「Rectangular cutouts leak square-edged shadows around every cap」。
⇒ 视觉改进（消键帽四周方影），但**键床遮罩几何变了**。

### D. defaults 默认值被上游改（要重同步）

| 键 | 1.2.1 | 1.2.2 |
|---|---|---|
| `MaxEffects` | 6 | **4** |
| `Opacity` | 0.78 | **0.65** |
| `Brightness` | 1.0 | **0.95** |
| `Duration` | 0.45 | **0.55** |
| `Spread` | 2.25 | **2** |
| `Softness` | 7 | **8** |
| `CoreStrength` | 0.62 | **0.5** |
| `BackgroundStrength` | 0.24 | **0.18** |
| `PureBlackKeyboard` | 0 | **1** |

老板设备上的实际值在 `com.minis.rainbowkeyboard.plist` 里，会盖住 defaults，
**只影响全新安装的观感**；但我们的「两份 defaults.plist 逐字节一致（md5 `4fcb482c…`）」
校验基准要跟着重算。

### E. 上游新增键（中性，与我们并存）

`AppearanceModes` / `LightEffectStyle` / `LightColorMode` / `LightPressColorMode` /
`LightHue` / `LightPressColor` / `Dark*`（同构）/ `WeChatTheme` / `NativeTheme`。

### F. 我们独享、上游完全没有（安全）

| 键 | 说明 |
|---|---|
| `WidenVoiceButton` | 语音按钮加宽（上游连键都不认识，见冲突 A） |
| `LightPop` / `LightPopFollowAppearance` / `LightPopMatchColor` | 轻弹独立开关组 |
| `PressBrightness` | 按压亮度（上游有 encode/decode，非自研） |
| `PureBlackKeyboard` / `MaxEffects` | 上游 defaults 有、但 `RKDisplayTransport` 无 encode/decode ⇒ 不受跨进程影响 |

我们自研且上游**完全没有**的编译单元（合上游时它们原样保留即可）：

```
RKAdaptivePerformanceOff.m   （RKAdaptiveLevel 恒 0）
RKBlackKeyboardHost.m        （我们自己的黑键盘宿主，替代上游 PureBlackKeyboard.xm）
RKVoiceToolbarWiden.xm       （工具栏语音按钮加宽 + 居中 + 底色）
```

两边编译单元对照：

|  ours (2.3.33) | upstream 1.2.2 |
|---|---|
| RKAdaptivePerformanceOff.m | RKAdaptivePerformance.m |
| Tweak.xm / RainbowEffectView.m / RKNeonPress.m / RKThemeEngine.m / RKKeyboardGeometry.m | （同名） |
| CandidateGradient.xm | （同名） |
| RKBlackKeyboardHost.m | — |
| **RKVoiceToolbarWiden.xm** | — |
| — | RKBlackBitmap.m |
| — | PureBlackKeyboard.xm |

---

## 四、建议（不整体 rebase，按块手动合）

| 优先级 | 动作 | 理由 |
|---|---|---|
| **前置** | 把 `WidenVoiceButton` 从 bit54/55 挪到 bit 47/48/49 | 否则 A 冲突必炸 |
| **前置** | 合并 `traitCollectionDidChange:`（调 `super` + 我们自己的 `effectiveLightPop` 重算） | 否则轻弹深浅色跟随丢失 |
| 高 | 合 9-30 那 5 条（`Tweak.xm` 布局切换清旧效果 + 涟漪延后） | 解决切键面残影/坐标错位；⚠️ 要Check 与我们 `showRippleAtPoint` 记忆化的交互 |
| 中 | 合「圆角键面切洞」2 处 hunk | 消键帽方影；需观感回归 |
| 中 | 合 `style == 3` → `style >= 3` 一行 | 新 style 支持 |
| **不合** | 主题体系（WeChatTheme / NativeTheme / AppearanceModes / Light-Dark 拆分） | 与我们自研路线方向不同，改 defaults 结构 + 设置页 279 行 |
| **不合** | 候选栏 emoji 保色（RKCandidateEmoji*） | 与我们候选栏三防线（总闸/启动守卫/Teardown）职责重叠 |
| 待定 | defaults 重同步（跑 `defaults.plist` 两份一致校验，md5 会变） | 只影响新装观感 |

---

## 五、复现命令

```bash
cd jianpan
git remote add upstream https://github.com/mowang7426/jianpan.git   # 若已存在会报 already
git fetch upstream main --tags
git diff --stat 925dea9 upstream/main
git diff 925dea9 upstream/main -- RKDisplayTransport.h RainbowEffectView.m Tweak.xm
git show upstream/main:control | head -3      # 看上游版本号
gh api "repos/mowang7426/jianpan/compare/850a5b2...main" --jq '{ahead:.ahead_by,behind:.behind_by}'
```

---

## 六、2026-10-06 续更：上游又推 10 条（`101b092` → `5c1a421`）

主题 = **新增可选键盘光效**。净效果：**设置页从 4 项扩到 7 项**，但新增的方法里
**只有 3 个真正接了线**，另 **2 个写完被弃用、留在代码里（零调用）**。
改动仍集中在 `RainbowEffectView.m`（+106/−1）与设置页 `RKBRootListController.m`（+5/−5）。

| commit | 说明 |
|---|---|
| `9d91287` | Add four selectable keyboard lighting effects |
| `2766ee2` / `a0b481a` / `650ccaf` | Redesign / Preserve legacy / Keep legacy and isolate new styles |
| `e4255f5` | Reduce new lighting layer buildup |
| `1c30bac` / `d4beec3` | Fix star flow syntax / **Replace final lighting effects with bottom spread** |
| `b3acc56` | Fix Objective-C key frame type inference |
| `98161cc` | **Remove duplicate key hit helper** |
| `5c1a421` | Remove local effect rewrite scripts |

### 设置页选项（`RKBRootListController.m:300`）

```
options: @[@"波纹",  @"扩散", @"轻弹", @"流光底韵", @"RGB 底板氛围", @"机械波", @"键底扩散"]
values:  @[@0,      @1,     @2,     @3,          @4,             @5,     @6]
```

分派入口：`showRippleAtPoint:sourceView:` 里三行 early return —
`style==4 → showAmbientBedAtPoint:` / `style==5 → showMechanicalWaveAtPoint:` /
`style==6 → showKeyBottomSpreadAtPoint:`；且 `EffectStyle` 上限从 `high:3` 提到 **`high:6`**。

### 3 个新接线的方法

| 方法 | 层名 | 做法要点 |
|---|---|---|
| `showAmbientBedAtPoint:`（RGB 底板氛围） | `RKNewAmbientBed` | 不是从按键扩散：一条**宽 3 倍屏宽**的横向渐变（5 段 `.0/.18/.82/.12/.0`）从 `−.55w` 滑到 `+1.55w`，遮罩 `waveUnderCapMask`；色相只推进 .09 |
| `showMechanicalWaveAtPoint:`（机械波） | `RKNewMechanicalWave` | 从按键**底部中心**发两个同心圆环：外环 lineWidth 15 / alpha .24、内环 3.2 / .9（粗柔 + 细锐双层）；半径 = clamp(`BackgroundRadius`, 85, 190) |
| `showKeyBottomSpreadAtPoint:`（键底扩散） | `RKKeyBottomSpread` | 从 `(midX, maxY+2)` 发**径向渐变**（`.95/.62/.18/0`），`transform.scale` 从 .035 → 1.0；起点另画一条胶囊发光短线（宽 = 键宽×.72，带 shadow） |

### 2 个零调用的死方法（上游忘了删）

- `showGapFlowAtPoint:`（星流，层名 `RKKeyGapFlow`）：按键周围**按距离取最近 9 个键**，
  逐点延迟 .055s 脉冲闪烁。
- `showEmberTrailAtPoint:`（余烬，层名 `RKNewEmberTrail`）：按距离取最近 **7** 个键中心
  连成折线，用 `strokeEnd` 0→1「画」出轨迹。

两处 `git grep '\[self showGapFlowAtPoint'` / `showEmberTrailAtPoint` 均为 **0 命中** ⇒
`d4beec3 Replace final lighting effects with bottom spread` 换掉最后一种时没清前两种
（`5c1a421` 只删了本地重写脚本）。**我们合上游时可以不带这两个。**

### 另新增「日间/夜间光效」两个设置项（非光效，但影响观感）

`LightEffectStyle`（日间光效，默认 2）/ `DarkEffectStyle`（夜间光效，默认 1）
⇒ 深浅色模式各自指定风格。这正是上游新增 `traitCollectionDidChange:` 的原因
（与我们 2.3.31 写同名方法的目的一样，但职责不同 —— 那个负责 `effectiveLightPop`）。

**对我们的影响评估：**

- ✅ **方法名零冲突**：上游走 `pressedKeyAtPoint:`，我们走 `resolvePressedKeyFrameAtPoint:sourceView:`，
  两套互不覆盖。
- ✅ **命中实现思路一致**：上游的 `pressedKeyAtPoint:` 就是「全表遍历 + 落点在矩形内 + 取面积最小」
  —— 正是我们 2.3.31 修好的那个正确版本（上游没做索引化，不会踩我们踩过的分桶容差坑）。
- ⚠️ `98161cc Remove duplicate key hit helper` 删的是**上游自己**的两个重复 helper，
  与我们 2.3.33 已删的兜底无关。
- ⚠️ 这些新光效若将来要合，需注意它们与我们 `RKEvictLayersByName` 图层驱逐体系、
  以及 `EffectStyle` 取值集合（我们校验只认 0/1/3）会冲突 —— 上游已把 style 扩到 4/5/6。
  `check_settings_items.py` 的 `check_effect_style` 会因此报错，合入时必须同步放宽。
- ℹ️ 上游新增的这几个都自带「每次按键先删同名层」的写法（`for (...) if (name isEqual) removeFromSuperlayer`），
  与我们「按名分组驱逐 `RKEvictLayersByName`」是两套并行机制；合入时应改走我们的驱逐器，
  否则会绕过 `MaxEffects` 上限。
