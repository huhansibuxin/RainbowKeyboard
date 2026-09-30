#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全量代码结构体检（纯标准库，本地手动跑：python3 audit_code.py）。

⚠️ 刻意**不挂 CI**：它靠正则解析 C/ObjC 源码，个别写法可能误报，挂在 CI 上会平白阻塞
构建。它是"推之前自己先看一眼"的工具 —— CI 之前多一道人工闸，而不是自动闸。

覆盖：

本项目不开 LTO、且 .xm 按 Objective-C++ 编译、.m 按 C/ObjC 编译，历史上踩过的坑都属
"结构性问题"（重复定义、死代码、跨语言声明缺失导致链接失败、残留诊断代码）。这些只能
靠 CI（约十分钟一轮）才发现，代价高；这个脚本把它们一次查完。

查：
  1. C 函数重复定义（同文件 / 跨文件）
  2. static 函数定义了但从未被引用（死代码）
  3. 被调用但全项目找不到定义的 RK* 函数（链接失败风险）
  4. .xm 调用的 .m 内函数是否用 FOUNDATION_EXPORT / extern "C" 声明（跨语言链接风险）
  5. 同一个 @implementation 内的方法重复定义
  6. @interface / @implementation 配对
  7. 残留诊断 / 临时 / TODO 清单（提醒哪些是要删的）
  8. 版本字符串分布（control 与实际写盘标记是否一致）
"""
import os
import re
import sys
import glob
from collections import defaultdict, Counter

SRC_EXT = ('.m', '.xm', '.h')
KEYWORDS = {'if', 'for', 'while', 'switch', 'return', 'else', 'do', 'sizeof', 'catch',
            'dispatch_once', 'defined'}


def sources():
    files = []
    for pat in ('*.m', '*.xm', '*.h', '**/*.m', '**/*.xm', '**/*.h'):
        files += glob.glob(pat, recursive=True)
    out = []
    for f in sorted(set(files)):
        if 'ci-downloads' in f or f.startswith('.wetype') or 'build' in f.split(os.sep):
            continue
        if f.endswith(SRC_EXT):
            out.append(f)
    return out


def read(path):
    with open(path, encoding='utf-8', errors='replace') as fh:
        return fh.read()


DEF_RE = re.compile(
    r'^(?![ \t])'
    # 排除控制语句、预处理、注释、@ 指令与类型声明
    r'(?!(?:if|for|while|switch|return|do|else|@|#|//|/\*|\*|typedef|struct|enum|union))'
    # 名字必须是「本行第一个 标识符+左括号」——用它把匹配锚在该行，避免空行/注释起头跨行吞并，
    # 也避免贪婪匹配到行内最后一个 `ident(`（例如参数里的 `void (^original)(void)`）。
    # (?!__) 跳过 `__attribute__((...))` 这类修饰。
    r'(?=[^\n]*?\b(?P<name>(?!__)[A-Za-z_]\w*)\s*\()'
    r'[^;{}=]*?\b(?P=name)\s*\([^;{}]*\)\s*\{', re.M)


def strip_comments(text):
    """去掉注释再做「调用点」扫描 —— 否则注释里出现的 `Foo(` 会被当成调用（已踩过）。"""
    text = re.sub(r'/\*.*?\*/', ' ', text, flags=re.S)
    return re.sub(r'//[^\n]*', ' ', text)
METHOD_RE = re.compile(r'^\s*[-+]\s*\(([^)]*)\)\s*([^;{]*?)\s*(?:\{|;|$)', re.M)
IMPL_RE = re.compile(r'^\s*@(implementation|interface)\s+(\w+)', re.M)
HOOK_RE = re.compile(r'^\s*%(hook|end|group|endgroup)\b', re.M)
CALL_RE = re.compile(r'\b(RK[A-Z]\w*)\s*\(')
DECL_RE = re.compile(r'FOUNDATION_EXPORT\s+[^;]*?\b(RK\w+)\s*\(')


def full_selector(rest):
    """把 `drawInRect:withAttributes:` 这类完整的选择子拼出来，避免把重载误判成重复。"""
    parts = re.findall(r'([A-Za-z_]\w*)\s*:', rest)
    if parts:
        return ':'.join(parts) + ':'
    m = re.match(r'\s*([A-Za-z_]\w*)', rest)
    return m.group(1) if m else rest.strip()


def c_definitions(path):
    text = read(path)
    definitions = []
    for m in DEF_RE.finditer(text):
        name = m.group(1)
        if name in KEYWORDS or name.startswith('__'):
            continue
        line = text[:m.start()].count('\n') + 1
        line_text = text[m.start():text.find('\n', m.start())]
        is_static = bool(re.match(r'\s*static\b', line_text))
        # __attribute__((constructor)) 的函数由运行时自动调用，不算死代码。
        is_ctor = '__attribute__((constructor))' in text[max(0, m.start() - 160):m.start()]
        definitions.append((name, line, bool(is_static), is_ctor))
    return definitions


def objc_methods(path):
    text = read(path)
    result = []
    current = None
    for line_no, line in enumerate(text.splitlines(), 1):
        if HOOK_RE.match(line):
            # %hook 体内的方法属于宿主类，不是本文件的 @implementation，跳过。
            current = None
            continue
        m = IMPL_RE.match(line)
        if m:
            current = m.group(2) if m.group(1) == 'implementation' else None
            continue
        if current:
            m = METHOD_RE.match(line)
            if m:
                result.append((current, full_selector(m.group(2)), line_no))
    return result


def main():
    files = sources()
    problems = []

    print('=' * 78)
    print('体检范围：%d 个源文件' % len(files))
    for f in files:
        print('   ', f)
    print('=' * 78)

    # ---- 1/2：C 函数重复定义与死代码 ----
    definitions = defaultdict(list)   # name -> [(file, line, is_static, is_ctor)]
    per_file = {}
    for path in files:
        defs = c_definitions(path)
        per_file[path] = defs
        for name, line, is_static, is_ctor in defs:
            definitions[name].append((path, line, is_static, is_ctor))

    print('\n[1] C 函数重复定义')
    impl_files = [f for f in files if f.endswith(('.m', '.xm'))]
    real_dup = {}
    for n, v in definitions.items():
        impl = [x for x in v if x[0].endswith(('.m', '.xm'))]
        # 同一个文件里定义两次 = 编译错误；
        # 跨文件的多个定义只有「至少一个非 static」才会链接冲突（static 各有各的副本）。
        same_file = Counter(x[0] for x in impl)
        if any(c > 1 for c in same_file.values()) or (len(impl) > 1 and any(not x[2] for x in impl)):
            real_dup[n] = [(x[0], x[1], 'static' if x[2] else 'GLOBAL') for x in impl]
    if real_dup:
        for n, v in sorted(real_dup.items()):
            print('  !! 重复定义 %s: %s' % (n, v))
            problems.append('重复定义 %s' % n)
    else:
        print('  OK  无重复定义（跨文件的同名 static 不算冲突，已排除）')

    print('\n[2] static 函数从未被引用（死代码）')
    dead = []
    for path in impl_files:
        text = read(path)
        for name, line, is_static, is_ctor in per_file.get(path, []):
            if not is_static or is_ctor:
                continue
            if len(re.findall(r'\b%s\b' % re.escape(name), text)) <= 1:
                dead.append((path, line, name))
    if dead:
        for path, line, name in dead:
            print('  !! %s:%d  %s 定义后从未使用' % (path, line, name))
            problems.append('死代码 %s' % name)
    else:
        print('  OK  无死代码（constructor/destructor 已排除）')

    # ---- 3：被调用但找不到定义 ----
    print('\n[3] 被调用但全项目无定义的 RK* 函数')
    macros = set()
    for path in files:
        for m in re.finditer(r'^\s*#\s*define\s+(\w+)', strip_comments(read(path)), re.M):
            macros.add(m.group(1))
    class_names = set()
    for path in files:
        for m in re.finditer(r'^\s*@(?:interface|implementation)\s+(\w+)', strip_comments(read(path)), re.M):
            class_names.add(m.group(1))
    defined = set(definitions)
    unresolved = set()
    for path in impl_files:
        for m in CALL_RE.finditer(strip_comments(read(path))):
            name = m.group(1)
            if name in defined or name in macros or name in class_names:
                continue
            unresolved.add(name)
    if unresolved:
        for name in sorted(unresolved):
            print('  !! 调用了 %s() 但全项目找不到定义' % name)
            problems.append('未定义调用 %s' % name)
    else:
        print('  OK  所有调用都能找到定义')

    # ---- 4：跨语言声明 ----
    print('\n[4] .xm 调用的 .m 函数是否有 C 链接声明（FOUNDATION_EXPORT / extern "C"）')
    declared = set()
    extern_c_blocks = set()
    for path in files:
        if not path.endswith('.h'):
            continue
        text = read(path)
        declared |= {m.group(1) for m in DECL_RE.finditer(text)}
        for m in re.finditer(r'extern\s+"C"\s*\{([^}]*)\}', text, re.S):
            block = m.group(1)
            declared |= set(re.findall(r'\b(RK\w+)\s*\(', block))
            declared |= set(re.findall(r'\b(RK\w+)\s*;', block))
    c_defs = {n for n, v in definitions.items() if any(f.endswith('.m') for f, _, _, _ in v)}
    risk = []
    for path in [f for f in files if f.endswith('.xm')]:
        for m in CALL_RE.finditer(strip_comments(read(path))):
            name = m.group(1)
            if name in c_defs and name not in declared:
                risk.append((path, name))
    if risk:
        for path, name in sorted(set(risk)):
            print('  !! %s 调用了 .m 里的 %s()，但没有任何头文件用 FOUNDATION_EXPORT/extern "C" 声明它'
                  % (path, name))
            problems.append('跨语言声明缺失 %s' % name)
    else:
        print('  OK  跨语言调用全部有 C 链接声明')

    # ---- 5：同 @implementation 内方法重复 ----
    print('\n[5] 同一 @implementation 内方法重复定义')
    method_dups = []
    for path in impl_files:
        seen = Counter()
        for cls, first, line in objc_methods(path):
            seen[(cls, first)] += 1
        for (cls, first), count in seen.items():
            if count > 1:
                method_dups.append((path, cls, first, count))
    if method_dups:
        for path, cls, first, count in method_dups:
            print('  !! %s  %s 的 %s… 定义了 %d 次' % (path, cls, first, count))
            problems.append('方法重复 %s.%s' % (cls, first))
    else:
        print('  OK  无重复方法')

    # ---- 6：@interface / @implementation 配对 ----
    print('\n[6] @interface / @implementation 配对')
    ifaces = defaultdict(set)
    impls = defaultdict(set)
    for path in files:
        for m in re.finditer(r'^\s*@interface\s+(\w+)', read(path), re.M):
            ifaces[m.group(1)].add(path)
        for m in re.finditer(r'^\s*@implementation\s+(\w+)', read(path), re.M):
            impls[m.group(1)].add(path)
    missing_impl = [n for n in ifaces
                    if n not in impls
                    # .xm 里为「给宿主类加方法/属性」而写的 @interface 本来就没有实现
                    # （它们是 Logos 钩子目标），不算缺实现。
                    and not any(p.endswith('.xm') for p in ifaces[n])]
    missing_iface = [n for n in impls if n not in ifaces]
    if missing_impl or missing_iface:
        if missing_impl:
            print('  ?? @interface 无对应 @implementation：%s' % missing_impl)
        if missing_iface:
            print('  ?? @implementation 无对应 @interface（可用 extension/类扩展，需人工确认）：%s'
                  % missing_iface)
    else:
        print('  OK  全部配对')

    # ---- 7：残留诊断 / 临时 ----
    print('\n[7] 残留诊断 / 临时 / TODO 清单')
    markers = re.compile(r'临时|诊断|探针|TODO|FIXME|XXX|HACK|debug\b|验证后删|验完删')
    hits = []
    for path in impl_files:
        for line_no, line in enumerate(read(path).splitlines(), 1):
            if line.lstrip().startswith('//') or line.lstrip().startswith('*'):
                if markers.search(line):
                    hits.append((path, line_no, line.strip()[:110]))
    if hits:
        for path, line_no, text in hits:
            print('  %-28s:%-5d %s' % (path, line_no, text))
    else:
        print('  OK  无残留')

    # ---- 8：版本字符串 ----
    print('\n[8] 版本字符串分布')
    vers = Counter()
    where = defaultdict(list)
    for path in files + ['control']:
        for m in re.finditer(r'2\.3\.\d+', read(path)):
            vers[m.group(0)] += 1
            where[m.group(0)].append('%s:%d' % (path, read(path)[:m.start()].count('\n') + 1))
    control_version = None
    if os.path.exists('control'):
        m = re.search(r'^Version:\s*(\S+)', read('control'), re.M)
        control_version = m.group(1) if m else None
    print('  control 版本 = %s' % control_version)
    for v, c in sorted(vers.items()):
        print('  %-10s x%-3d  %s' % (v, c, ' / '.join(where[v][:6])))
    if control_version:
        others = [v for v in vers if v != control_version]
        if others:
            print('  ?? 除 control 外还出现其他版本号：%s（确认是否只是历史注释）' % others)

    print('\n' + '=' * 78)
    if problems:
        print('体检结论：发现 %d 个结构性问题' % len(problems))
        for p in problems:
            print('   -', p)
        return 1
    print('体检结论：无结构性问题')
    return 0


if __name__ == '__main__':
    sys.exit(main())
