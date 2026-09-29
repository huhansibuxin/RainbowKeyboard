#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
候选栏渐变「关闭即零循环」回归防线（2.3.26）

背景：候选题的渐变靠一条 20fps 的 CADisplayLink 驱动。用户要求的硬约束是
「不打开候选栏渐变功能，就一次循环都不能有」。这条约束横跨三处代码，任何一处
在后续重构里被挪动/删掉，都会变成「关着开关却还在每帧烧 CPU」——而且不会报错。

本脚本把三条结构性保证钉成断言（纯文本解析，不依赖编译器）：

  ① CADisplayLink 只允许在 RKCandidateStartAnimationIfNeeded() 里创建，
     且该函数的守卫必须引用合成的 RKCandidateEnabled（总开关 && 至少一个子开关）,
     与绘制总闸 RKCandidateActive() 的开关部分同判据。
  ② RKCandidateReload()（开关变化的唯一入口）里必须有 RKCandidateTeardown() 调用，
     即关闭时主动停链、清重绘表。
  ③ RKCandidateTeardown() 必须同时做两件事：停 CADisplayLink + 清空 RKCandidateViews。
     （tick 首行靠 RKCandidateViews.count == 0 兜底立刻 invalidate。）

用法：python3 check_candidate_idle.py [源码路径，默认 CandidateGradient.xm]
退出码：0 = 全部通过；1 = 有断言失败
"""

import re
import sys
from pathlib import Path

SOURCE = Path(sys.argv[1] if len(sys.argv) > 1 else "CandidateGradient.xm")


def function_body(text, signature):
    """按花括号配平取出 signature 之后的函数体（含签名行）。

    signature 需带上开体大括号（如 "static void F(void) {"），否则会先命中
    @interface 里的方法声明，再往后误取到下一个函数的函数体。
    """
    start = text.find(signature)
    if start < 0:
        return None
    brace = text.find("{", start)
    if brace < 0:
        return None
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None


def main():
    if not SOURCE.is_file():
        print("FAIL 找不到源文件 %s" % SOURCE)
        return 1
    text = SOURCE.read_text(encoding="utf-8", errors="replace")
    errors = []

    start_fn = function_body(text, "static void RKCandidateStartAnimationIfNeeded(void) {")
    reload_fn = function_body(text, "static void RKCandidateReload(void) {")
    teardown_fn = function_body(text, "static void RKCandidateTeardown(void) {")

    # ① 启动函数存在、守卫正确、链只在这里创建
    if start_fn is None:
        errors.append("找不到 RKCandidateStartAnimationIfNeeded()")
    else:
        guard = re.search(r"if\s*\(([^)]*)\)\s*return;", start_fn)
        if not guard:
            errors.append("RKCandidateStartAnimationIfNeeded() 缺少首行守卫")
        elif "RKCandidateEnabled" not in guard.group(1):
            errors.append(
                "RKCandidateStartAnimationIfNeeded() 的守卫未使用合成值 RKCandidateEnabled"
                "（实际：%s）—— 总开关开着但两个子开关都关时会空转起链"
                % guard.group(1).strip())
        if "displayLinkWithTarget" not in start_fn:
            errors.append("RKCandidateStartAnimationIfNeeded() 里没有创建 CADisplayLink")

    # CADisplayLink 不得在别处创建
    total_creations = len(re.findall(r"displayLinkWithTarget", text))
    in_start = len(re.findall(r"displayLinkWithTarget", start_fn or ""))
    if total_creations != in_start:
        errors.append("CADisplayLink 在 RKCandidateStartAnimationIfNeeded() 之外被创建"
                      "（共 %d 处，函数内 %d 处）" % (total_creations, in_start))

    # ② 开关变化的唯一入口里必须有收尾调用
    if reload_fn is None:
        errors.append("找不到 RKCandidateReload()")
    elif "RKCandidateTeardown()" not in reload_fn:
        errors.append("RKCandidateReload() 里没有调用 RKCandidateTeardown()"
                      "—— 关闭功能时不会停链、不会清重绘表")
    else:
        # 顺序：撤像素的循环必须排在收尾之前，否则撤不干净
        loop_at = reload_fn.find("for (UIView *view in RKCandidateViews)")
        tear_at = reload_fn.find("RKCandidateTeardown()")
        if loop_at >= 0 and tear_at >= 0 and tear_at < loop_at:
            errors.append("RKCandidateReload() 里 RKCandidateTeardown() 排在清像素循环之前"
                          "—— 重绘表被提前清空，已渲染的渐变像素撤不干净")

    # ③ 收尾函数两件事都要做
    if teardown_fn is None:
        errors.append("找不到 RKCandidateTeardown()")
    else:
        if "RKCandidateStopAnimation()" not in teardown_fn:
            errors.append("RKCandidateTeardown() 没有停 CADisplayLink")
        if "removeAllObjects" not in teardown_fn:
            errors.append("RKCandidateTeardown() 没有清空 RKCandidateViews"
                          "—— tick 首行失去兜底判据")

    # 附加：tick 首行必须仍带自检（关掉功能后即便被外部触发也要立刻退出）
    tick_fn = function_body(text, "- (void)tick:(CADisplayLink *)link {")
    if tick_fn is None:
        errors.append("找不到 RKCandidateAnimatorProxy -tick:")
    elif "RKCandidateActive()" not in tick_fn:
        errors.append("tick: 首行缺少 RKCandidateActive() 自检")

    if errors:
        for e in errors:
            print("FAIL " + e)
        return 1
    print("OK  候选栏关闭路径自检通过（启动守卫 = 合成总闸 / 关闭即收尾 / tick 自检）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
