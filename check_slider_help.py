#!/usr/bin/env python3
"""设置页滑条说明自检：每个滑条都必须带一段说明文字。

设置页由 PreferenceLoader 直接渲染 plist，而 iOS 的 PSSliderCell **不支持**
footerText —— 滑条的说明只能由「紧邻上方的那个 PSGroupCell」的 footerText 承载。
这个结构一旦漏写，界面上就是一条没头没尾、看不出是干嘛的滑条
（本项目 1.2.1 之后的重构就丢过一次全部滑条说明）。

规则沿用 1.2.1 的 Tests/check-settings.swift：
  * 每个 PSSliderCell 前面必须紧跟一个 PSGroupCell；
  * 该 group 必须有非空 footerText（即说明文字）；
  * 该 group 的 label 必须包含滑条自身的 label（起「哪个大类 · 哪一项」的路径提示）；
  * 每个 PSSliderCell 后面必须紧跟一个 PSGroupCell（说明才会渲染在滑条正下方）。

用法：
    python3 check_slider_help.py                 # 校验默认的 Resources 目录
    python3 check_slider_help.py <Resources 目录>
退出码 0 = 通过，1 = 有问题。
"""
import plistlib
import sys
from pathlib import Path

PANELS = [
    "RainbowKeyboard.plist",
    "RainbowKeyboardAdvanced.plist",
    "RainbowKeyboardCandidate.plist",
]


def check_panel(path):
    """返回 (滑条数, 错误列表)。"""
    items = plistlib.loads(path.read_bytes())["items"]
    errors = []
    sliders = 0
    for i, item in enumerate(items):
        if item.get("cell") != "PSSliderCell":
            continue
        sliders += 1
        name = item.get("key") or "#%d" % i
        prev = items[i - 1] if i > 0 else None

        if prev is None or prev.get("cell") != "PSGroupCell":
            errors.append("%s：前面不是 PSGroupCell，说明没有地方显示" % name)
        else:
            if not (prev.get("footerText") or "").strip():
                errors.append("%s：上方分组的 footerText 为空，界面上看不到说明" % name)
            label = item.get("label") or ""
            if label and label not in (prev.get("label") or ""):
                errors.append("%s：分组标题未包含滑条名「%s」" % (name, label))

        if i + 1 < len(items) and items[i + 1].get("cell") != "PSGroupCell":
            errors.append("%s：后面不是 PSGroupCell，说明不会紧跟滑条显示" % name)
    return sliders, errors


def main(argv):
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parent / "RainbowKeyboardPrefs" / "Resources"
    if not root.is_dir():
        print("!! 找不到目录：%s" % root)
        return 1

    total = 0
    failed = False
    checked = 0
    for name in PANELS:
        path = root / name
        if not path.is_file():
            continue
        checked += 1
        try:
            sliders, errors = check_panel(path)
        except Exception as exc:                                    # noqa: BLE001
            print("!! %s 解析失败：%s" % (name, exc))
            failed = True
            continue
        total += sliders
        if errors:
            failed = True
            print("!! %s（%d 个滑条）：" % (name, sliders))
            for err in errors:
                print("     " + err)
        else:
            print("OK  %s：%d 个滑条均带说明" % (name, sliders))

    if not checked:
        print("!! 在 %s 下没有找到任何设置面板" % root)
        return 1
    if failed:
        print("!! 滑条说明自检未通过")
        return 1
    print("OK  滑条说明自检通过（共 %d 个滑条）" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
