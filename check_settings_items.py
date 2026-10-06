#!/usr/bin/env python3
"""设置项自检：功能开关必须同时具备「设置页入口」与「默认值源」。

本项目踩过的坑：功能本身还在，但设置页入口在某次重构里被静默丢掉
（1.2.1 之后滑条说明全丢、2.0.0 换基板后「轻弹」开关消失），
只能等装到设备上才发现。

这里固定住五条底线：
  1. 主面板存在轻弹开关（LightPop）、「与光效同色」开关（LightPopMatchColor）
     与「跟随系统深浅色」开关（LightPopFollowAppearance）；
  2. 高级设置存在「键帽灯光亮度」滑条（PressBrightness）；
  3. 这些键在两份 defaults.plist 与 RKPreferences.h 固化表里都有值
     （键盘扩展沙盒读不到偏好文件时靠固化表兜底，漏了就会回落出错值）；
  4. 「光效风格」的取值集合与源码 chooseEffectStyle 一致，且不再包含轻弹(2)；
  5. 「跟随系统深浅色」的两条易断链路：设置页必须把它重建成带 setter 的 specifier
     （否则写入绕过本类、联动静默失效），且开启时必须联动写入 LightPop。

用法：
    python3 check_settings_items.py
退出码 0 = 通过，1 = 有问题。
"""
import plistlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESOURCES = ROOT / "RainbowKeyboardPrefs" / "Resources"
CONTROLLER = ROOT / "RainbowKeyboardPrefs" / "RKBRootListController.m"
PREFS_HEADER = ROOT / "RKPreferences.h"
DEFAULT_PLISTS = [ROOT / "defaults.plist", RESOURCES / "defaults.plist"]

# 本次新增/改动的键：plist 键 -> 期望的默认值
# 2.3.34：轻弹与「跟随系统深浅色」默认改为开（浅色上色、深色不上色）。
# 2.3.36：「轻弹与光效同色」默认改为关（轻弹走自己的取色）。
LIGHT_POP_KEYS = {"LightPop": True, "LightPopMatchColor": False,
                  "LightPopFollowAppearance": True}
PRESS_BRIGHTNESS_KEY = "PressBrightness"
PRESS_BRIGHTNESS_DEFAULT = 0.6

# 「跟随系统深浅色」：plist 里是定义项，实际显示的是控制器重建后的 specifier，
# 两处标题必须一致（下面按这个名字做一致性断言）。
FOLLOW_KEY = "LightPopFollowAppearance"
FOLLOW_LABEL = "跟随系统深浅色"


def load_items(path):
    return plistlib.loads(path.read_bytes())["items"]


def find_items(items, cell, key):
    return [i for i in items if i.get("cell") == cell and i.get("key") == key]


def check_panels(errors):
    main = load_items(RESOURCES / "RainbowKeyboard.plist")
    advanced = load_items(RESOURCES / "RainbowKeyboardAdvanced.plist")

    for key, expected in LIGHT_POP_KEYS.items():
        found = find_items(main, "PSSwitchCell", key)
        if not found:
            errors.append("主面板缺少开关 %s（应为 PSSwitchCell）" % key)
            continue
        if bool(found[0].get("default")) != expected:
            errors.append("%s 的 default 应为 %s，实为 %r" % (key, expected, found[0].get("default")))

    sliders = find_items(advanced, "PSSliderCell", PRESS_BRIGHTNESS_KEY)
    if not sliders:
        errors.append("高级设置缺少滑条 %s" % PRESS_BRIGHTNESS_KEY)
    else:
        default = sliders[0].get("default")
        if not isinstance(default, float) or abs(default - PRESS_BRIGHTNESS_DEFAULT) > 1e-9:
            errors.append("%s 的 default 应为 %.2f，实为 %r" % (PRESS_BRIGHTNESS_KEY, PRESS_BRIGHTNESS_DEFAULT, default))


def openstep_keys(path):
    """两份 defaults.plist 是 OpenStep 文本格式（不是 XML），按 `键 = 值;` 抽键名。"""
    text = path.read_text(encoding="utf-8")
    return set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", text, re.M)), text


def check_defaults(errors):
    keys = list(LIGHT_POP_KEYS) + [PRESS_BRIGHTNESS_KEY]
    texts = []
    for path in DEFAULT_PLISTS:
        if not path.is_file():
            errors.append("缺少 %s" % path.relative_to(ROOT))
            continue
        try:
            present, text = openstep_keys(path)
        except Exception as exc:                                    # noqa: BLE001
            errors.append("%s 读取失败：%s" % (path.relative_to(ROOT), exc))
            continue
        texts.append(text)
        for key in keys:
            if key not in present:
                errors.append("%s 缺少键 %s（恢复默认会漏掉它）" % (path.relative_to(ROOT), key))

    if len(texts) == 2:
        # 两份必须逐项一致：一份给「恢复默认」读，一份随包分发。
        normalize = lambda t: sorted(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;]*);", t, re.M))
        if normalize(texts[0]) != normalize(texts[1]):
            errors.append("两份 defaults.plist 内容不一致（必须逐项相同）")


def check_self_use_table(errors):
    src = PREFS_HEADER.read_text(encoding="utf-8")
    for key in list(LIGHT_POP_KEYS) + [PRESS_BRIGHTNESS_KEY]:
        if not re.search(r'@"%s"\s*:' % re.escape(key), src):
            errors.append("RKPreferences.h 固化表缺少键 %s（键盘进程回落会出错值）" % key)


def check_effect_style(errors):
    src = CONTROLLER.read_text(encoding="utf-8")
    match = re.search(
        r'chooseSimpleOptionForKey:@"EffectStyle".*?options:@\[(.*?)\].*?values:@\[(.*?)\]',
        src, re.S)
    if not match:
        errors.append("RKBRootListController.m 里找不到 chooseEffectStyle 的选项定义")
        return
    options = re.findall(r'@"([^"]*)"', match.group(1))
    values = [int(v) for v in re.findall(r"@(-?\d+)", match.group(2))]
    if len(options) != len(values):
        errors.append("光效风格的选项数与取值数不一致（%r / %r）" % (options, values))
        return
    if 2 in values:
        errors.append("光效风格里仍保留轻弹(2)：轻弹已改为独立开关，不应再占风格选项")
    if len(options) != 3 or "轻弹" in "".join(options):
        errors.append("光效风格选项应为 波纹/扩散/流光底韵，实为 %r" % (options,))
    # 列表页的显示分支必须认得同一批取值。
    for value in values:
        if value not in (0, 1, 3):
            errors.append("光效风格出现未知取值 %d" % value)


def check_follow_appearance(errors):
    """「跟随系统深浅色」两条最容易断的链路。

    这个开关不是普通的 plist 开关：plist 载入的 specifier 走 Preferences 的默认
    写盘路径、不经过 RKBRootListController，所以控制器必须把它重建成带 setter 的
    specifier，才能做「开启时顺手打开轻弹」的联动。任何一环被重构掉，表现都是
    「设置能拨、但轻弹没被打开」，很难在设备上归因。
    """
    main = load_items(RESOURCES / "RainbowKeyboard.plist")
    found = find_items(main, "PSSwitchCell", FOLLOW_KEY)
    if not found:
        errors.append("主面板缺少开关 %s" % FOLLOW_KEY)
    elif found[0].get("label") != FOLLOW_LABEL:
        errors.append("「%s」在 plist 里的标题为 %r，与控制器重建用的 %r 不一致"
                      % (FOLLOW_LABEL, found[0].get("label"), FOLLOW_LABEL))

    src = CONTROLLER.read_text(encoding="utf-8")
    if ('preferenceSpecifierNamed:@"%s"' % FOLLOW_LABEL) not in src:
        errors.append("控制器没有重建「%s」开关：写入会绕过本类，开启时不会联动打开轻弹"
                      % FOLLOW_LABEL)
    keyed = re.search(r'setProperty:@"%s"\s*\n?\s*forKey:@"key"' % re.escape(FOLLOW_KEY), src)
    if not keyed:
        errors.append("重建的「%s」开关没有绑定 key=%s" % (FOLLOW_LABEL, FOLLOW_KEY))

    branch = re.search(r'\[key isEqualToString:@"%s"\]' % re.escape(FOLLOW_KEY), src)
    if not branch:
        errors.append("setPreferenceValue: 里缺少 %s 分支（开启跟随时不会打开轻弹）" % FOLLOW_KEY)
    else:
        window = src[branch.start():branch.start() + 700]
        if 'values[@"LightPop"]' not in window:
            errors.append("%s 分支没有联动写入 LightPop" % FOLLOW_KEY)


def main():
    errors = []
    check_panels(errors)
    check_defaults(errors)
    check_self_use_table(errors)
    check_effect_style(errors)
    check_follow_appearance(errors)
    if errors:
        print("!! 设置项自检未通过：")
        for err in errors:
            print("     " + err)
        return 1
    print("OK  设置项自检通过（轻弹开关 / 同色开关 / 跟随深浅色 / 键帽亮度滑条 / "
          "默认值源 / 风格取值 / 跟随联动）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
