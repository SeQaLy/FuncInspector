#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FuncInspector テストランナー
============================
tests/cases/ の入力に対して Python / C / PowerShell の3実装を実行し、
  1) 期待値(アンカー)と一致するか
  2) 3実装が互いに一致するか
を検証し、結果を tests/TEST_RESULTS.md に書き出す。

使い方:  python tests/run_tests.py
gcc / pwsh(または powershell) が無い実装は SKIP 扱い。
"""
import os
import re
import sys
import shutil
import datetime
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "tests", "cases")
PY = os.path.join(ROOT, "python", "func_inspector.py")
CSRC = os.path.join(ROOT, "c", "func_inspector.c")
PSWRAP = os.path.join(ROOT, "powershell", "FuncInspector.ps1")


# --------------------------------------------------------------------------
# テスト定義: 論理仕様を各実装の CLI に変換して実行する
# --------------------------------------------------------------------------
# mode: 'scan' | 'switches'
# expect (scan):     {'count':N, 'funcs':{name:steps,...}, 'absent':[names]}
# expect (switches): {'switches':{name:(occ,state),...}}
TESTS = [
    dict(id="basics", file="basics.c", mode="scan", defines=[], ignore=False,
         desc="基本: 通常定義 / WINAMS前置 / 関数ポインタ引数。プロトタイプ・呼び出し・コメント/文字列は除外",
         expect={"count": 4, "funcs": {"add": 1, "startup": 1, "run_cb": 2, "main": 1},
                 "absent": ["ghost"]}),

    dict(id="switch-default", file="switches.c", mode="scan", defines=[], ignore=False,
         desc="スイッチ既定(全OFF): #ifndef は真、#if/#elif は偽→#else",
         expect={"count": 3, "funcs": {"notA": 1, "leg": 1, "always": 1},
                 "absent": ["a", "v2", "b"]}),

    dict(id="switch-CFG_A", file="switches.c", mode="scan", defines=["CFG_A"], ignore=False,
         desc="-D CFG_A: #ifdef有効/#ifndef無効",
         expect={"count": 3, "funcs": {"a": 1, "leg": 1, "always": 1},
                 "absent": ["notA"]}),

    dict(id="switch-VER2", file="switches.c", mode="scan", defines=["VER=2"], ignore=False,
         desc="-D VER=2: #if VER>=2 を式評価で真",
         expect={"count": 3, "funcs": {"notA": 1, "v2": 1, "always": 1},
                 "absent": ["leg", "b"]}),

    dict(id="switch-CFG_B", file="switches.c", mode="scan", defines=["CFG_B"], ignore=False,
         desc="-D CFG_B: #elif defined(CFG_B) を真",
         expect={"count": 3, "funcs": {"notA": 1, "b": 1, "always": 1},
                 "absent": ["leg", "v2"]}),

    dict(id="switch-list", file="switches.c", mode="switches", defines=[], ignore=False,
         desc="スイッチ一覧: 出現回数・状態・値候補",
         expect={"switches": {"CFG_A": (2, "OFF", "1"), "CFG_B": (1, "OFF", "1"), "VER": (1, "OFF", "2")}}),

    dict(id="switch-values", file="values.c", mode="switches", defines=[], ignore=False,
         desc="値候補の抽出: ==1/==2 は 1;2、==variable は variable、ifdef/bool は 1。variable は値定数なので一覧から除外",
         expect={"switches": {
             "LOCAL_LOG_ENABLE": (1, "OFF", "1"),
             "TOOL_TEST": (2, "OFF", "1;2"),
             "MODE": (1, "OFF", "variable")}}),

    dict(id="vc-list", file="valconst.c", mode="switches", defines=[], ignore=False,
         desc="値定数: CFG_A(=100, 右辺値のみ)はスイッチ一覧から除外。TOOL_TEST の値候補に CFG_A は残る",
         expect={"switches": {"TOOL_TEST": (3, "OFF", "1;2;CFG_A")}}),

    dict(id="vc-ext-none", file="valconst.c", mode="scan", defines=[], ignore=False, external=True,
         desc="選択スイッチのみ有効/未選択: CFG_A=100 を尊重し 0==100 偽 → t_cfg は出ない",
         expect={"count": 1, "funcs": {"always": 1}, "absent": ["t1", "t2", "t_cfg"]}),

    dict(id="vc-ext-1", file="valconst.c", mode="scan", defines=["TOOL_TEST=1"], ignore=False, external=True,
         desc="選択スイッチのみ有効/TOOL_TEST=1: t1 のみ",
         expect={"count": 2, "funcs": {"t1": 1, "always": 1}, "absent": ["t2", "t_cfg"]}),

    dict(id="pin-default", file="pinned.c", mode="scan", defines=[], ignore=False,
         desc="ピン留め既定: ソース内 #define TOOL_TEST 0 が効き test_only は隠れる",
         expect={"count": 1, "funcs": {"always": 1}, "absent": ["test_only"]}),

    dict(id="pin-on", file="pinned.c", mode="scan", defines=["TOOL_TEST=1"], ignore=False,
         desc="-D TOOL_TEST=1 をピン留め優先: 内蔵 #define TOOL_TEST 0 を無視し test_only を検出",
         expect={"count": 2, "funcs": {"test_only": 1, "always": 1}, "absent": []}),

    dict(id="ext-off", file="external.c", mode="scan", defines=[], ignore=False,
         desc="既定(cpp準拠): 内蔵 #define TOOL_TEST 1 が効き t1 が出る",
         expect={"count": 2, "funcs": {"t1": 1, "always": 1}, "absent": ["t2"]}),

    dict(id="ext-none", file="external.c", mode="scan", defines=[], ignore=False, external=True,
         desc="--external-switches 未選択: 内蔵 #define を無視 -> always のみ",
         expect={"count": 1, "funcs": {"always": 1}, "absent": ["t1", "t2"]}),

    dict(id="ext-1", file="external.c", mode="scan", defines=["TOOL_TEST=1"], ignore=False, external=True,
         desc="--external-switches -D TOOL_TEST=1: t1 が出る",
         expect={"count": 2, "funcs": {"t1": 1, "always": 1}, "absent": ["t2"]}),

    dict(id="ext-2", file="external.c", mode="scan", defines=["TOOL_TEST=2"], ignore=False, external=True,
         desc="--external-switches -D TOOL_TEST=2: t2 が出る (==1 は出ない)",
         expect={"count": 2, "funcs": {"t2": 1, "always": 1}, "absent": ["t1"]}),

    dict(id="inc-light", file="incmain.c", mode="scan", defines=[], ignore=False,
         desc="軽量(include解決なし): inccfg.h を読まないので TOOL_TEST 未定義 → inc_always のみ",
         expect={"count": 1, "funcs": {"inc_always": 1}, "absent": ["inc_t1", "inc_t2"]}),

    dict(id="inc-resolve", file="incmain.c", mode="scan", defines=[], ignore=False, resolve=True,
         desc="--resolve-includes: inccfg.h の TOOL_TEST=1 を反映 → inc_t1, inc_always",
         expect={"count": 2, "funcs": {"inc_t1": 1, "inc_always": 1}, "absent": ["inc_t2"]}),

    dict(id="inc-auto-light", file="incproj", mode="scan", defines=[], ignore=False,
         desc="軽量(ディレクトリ走査): サブフォルダ cfg2.h を読まない → base2 のみ",
         expect={"count": 1, "funcs": {"base2": 1}, "absent": ["feat2"]}),

    dict(id="inc-auto", file="incproj", mode="scan", defines=[], ignore=False, resolve=True,
         desc="自動include検出: -I 無しでサブフォルダ deep/cfg2.h を解決 (FEATURE2=1 → feat2)",
         expect={"count": 2, "funcs": {"feat2": 1, "base2": 1}, "absent": []}),

    dict(id="flag-resolve-none", file="flagsw.c", mode="scan", defines=[], ignore=False, resolve=True,
         desc="resolve/未選択: フラグ(CFG_AAA,CFG_UFS_ENABLE)はOFF, CFG_NUM=10≠5 → always_fn のみ",
         expect={"count": 1, "funcs": {"always_fn": 1}, "absent": ["aaa_fn", "ufs_fn", "num5_fn"]}),

    dict(id="flag-resolve-aaa", file="flagsw.c", mode="scan", defines=["CFG_AAA"], ignore=False, resolve=True,
         desc="resolve -D CFG_AAA: フラグを選択 → aaa_fn, always_fn",
         expect={"count": 2, "funcs": {"aaa_fn": 1, "always_fn": 1}, "absent": ["ufs_fn", "num5_fn"]}),

    dict(id="flag-resolve-ufs", file="flagsw.c", mode="scan", defines=["CFG_UFS_ENABLE"], ignore=False, resolve=True,
         desc="resolve -D CFG_UFS_ENABLE: CFG_ENABLE=1 が連鎖 → ufs_fn, always_fn",
         expect={"count": 2, "funcs": {"ufs_fn": 1, "always_fn": 1}, "absent": ["aaa_fn", "num5_fn"]}),

    dict(id="flag-resolve-num5", file="flagsw.c", mode="scan", defines=["CFG_NUM=5"], ignore=False, resolve=True,
         desc="resolve -D CFG_NUM=5: ピン留めで #define CFG_NUM 10 を上書き → num5_fn, always_fn",
         expect={"count": 2, "funcs": {"num5_fn": 1, "always_fn": 1}, "absent": ["aaa_fn", "ufs_fn"]}),

    dict(id="edge-known", file="edge.c", mode="scan", defines=[], ignore=False,
         desc="既知の限界(現挙動を固定): DEFINE_HANDLER誤検出、trail/getfp/knr見逃し",
         expect={"count": 1, "funcs": {"DEFINE_HANDLER": 1},
                 "absent": ["trail", "getfp", "knr", "h"]}),
]


# --------------------------------------------------------------------------
# 実行系
# --------------------------------------------------------------------------
def build_c():
    gcc = shutil.which("gcc") or shutil.which("cc")
    if not gcc:
        return None
    exe = os.path.join(ROOT, "tests", "_fi_test.exe")
    r = subprocess.run([gcc, "-O2", "-o", exe, CSRC],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return exe if r.returncode == 0 else None


def find_ps():
    return shutil.which("pwsh") or shutil.which("powershell")


def _run(argv):
    r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return r.stdout.decode("utf-8", "replace")


def run_python(t):
    a = [sys.executable, PY, os.path.join(CASES, t["file"])]
    a += _flags_common(t)
    return _run(a)


def run_c(exe, t):
    a = [exe, os.path.join(CASES, t["file"])]
    a += _flags_common(t)
    return _run(a)


def run_ps(ps, t):
    a = [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", PSWRAP,
         "-Path", os.path.join(CASES, t["file"])]
    if t["mode"] == "switches":
        a += ["-ListSwitches"]
    if t["defines"]:
        a += ["-D", ",".join(t["defines"])]
    if t["ignore"]:
        a += ["-IgnoreSwitches"]
    if t.get("external"):
        a += ["-ExternalSwitches"]
    if t.get("resolve"):
        a += ["-ResolveIncludes"]
    return _run(a)


def _flags_common(t):
    # Python と C は同じフラグ名
    a = []
    if t["mode"] == "switches":
        a += ["--list-switches"]
    for d in t["defines"]:
        a += ["-D", d]
    if t["ignore"]:
        a += ["--ignore-switches"]
    if t.get("external"):
        a += ["--external-switches"]
    if t.get("resolve"):
        a += ["--resolve-includes"]
    return a


# --------------------------------------------------------------------------
# 出力パース (パス表記の差を吸収し、キーで比較)
# --------------------------------------------------------------------------
def parse_scan(text):
    """-> set of (line, func, steps), dict func->steps"""
    rows = set()
    fmap = {}
    for ln in text.splitlines():
        p = ln.split(",")
        if len(p) != 4:
            continue
        try:
            line = int(p[1]); steps = int(p[3])
        except ValueError:
            continue
        func = p[2]
        rows.add((line, func, steps))
        fmap[func] = steps
    return rows, fmap


def parse_switches(text):
    """-> dict switch->(occ, state, values)"""
    out = {}
    for ln in text.splitlines():
        p = ln.split(",")
        if len(p) < 5:
            continue
        try:
            occ = int(p[1])
        except ValueError:
            continue
        if p[2] not in ("ON", "OFF"):
            continue
        values = p[5] if len(p) >= 6 else ""
        out[p[0]] = (occ, p[2], values)
    return out


# --------------------------------------------------------------------------
# 検証
# --------------------------------------------------------------------------
def check_expect(t, text):
    """期待アンカーとの一致。-> (ok, detail) """
    if t["mode"] == "scan":
        rows, fmap = parse_scan(text)
        exp = t["expect"]
        problems = []
        if len(fmap) != exp["count"]:
            problems.append("件数 %d (期待 %d)" % (len(fmap), exp["count"]))
        for name, steps in exp["funcs"].items():
            if name not in fmap:
                problems.append("未検出: %s" % name)
            elif fmap[name] != steps:
                problems.append("steps %s=%d (期待 %d)" % (name, fmap[name], steps))
        for name in exp.get("absent", []):
            if name in fmap:
                problems.append("誤検出: %s" % name)
        return (not problems), ("; ".join(problems) if problems else "OK")
    else:
        got = parse_switches(text)
        exp = t["expect"]["switches"]
        problems = []
        if set(got) != set(exp):
            problems.append("集合差: 検出=%s 期待=%s" % (sorted(got), sorted(exp)))
        for name, spec in exp.items():
            if name not in got:
                continue
            occ, state = spec[0], spec[1]
            if got[name][0] != occ or got[name][1] != state:
                problems.append("%s=(%s,%s) (期待 %s,%s)" % (name, got[name][0], got[name][1], occ, state))
            if len(spec) >= 3 and got[name][2] != spec[2]:
                problems.append("%s values='%s' (期待 '%s')" % (name, got[name][2], spec[2]))
        return (not problems), ("; ".join(problems) if problems else "OK")


def key_for_consistency(t, text):
    if t["mode"] == "scan":
        return frozenset(parse_scan(text)[0])
    return frozenset(parse_switches(text).items())


# --------------------------------------------------------------------------
# メイン
# --------------------------------------------------------------------------
def main():
    cexe = build_c()
    ps = find_ps()
    langs = ["Python"]
    if cexe:
        langs.append("C")
    if ps:
        langs.append("PowerShell")

    results = []          # per test: dict
    all_pass = True

    for t in TESTS:
        outs = {}
        outs_py = run_python(t); outs["Python"] = outs_py
        if cexe:
            outs["C"] = run_c(cexe, t)
        if ps:
            outs["PowerShell"] = run_ps(ps, t)

        per = {}
        for lang in langs:
            ok, detail = check_expect(t, outs[lang])
            per[lang] = (ok, detail)
            if not ok:
                all_pass = False

        keys = {lang: key_for_consistency(t, outs[lang]) for lang in langs}
        consistent = len(set(keys.values())) == 1
        if not consistent:
            all_pass = False

        # 表示用に Python の検出結果を採用
        if t["mode"] == "scan":
            rows = sorted(parse_scan(outs["Python"])[0])
            shown = ["L%d %s (steps=%d)" % (l, f, s) for (l, f, s) in rows]
        else:
            sw = parse_switches(outs["Python"])
            shown = ["%s x%d %s" % (k, v[0], v[1]) for k, v in sorted(sw.items())]

        results.append(dict(t=t, per=per, consistent=consistent, shown=shown))

    write_report(langs, results, all_pass, cexe, ps)
    print_console(langs, results, all_pass)
    if cexe and os.path.exists(cexe):
        try:
            os.remove(cexe)
        except OSError:
            pass
    return 0 if all_pass else 1


def print_console(langs, results, all_pass):
    print("実装:", ", ".join(langs))
    for r in results:
        t = r["t"]
        flags = " ".join("%s=%s" % (l, "PASS" if r["per"][l][0] else "FAIL") for l in langs)
        cons = "一致" if r["consistent"] else "不一致!"
        print("  [%-14s] %s  3実装:%s" % (t["id"], flags, cons))
        for l in langs:
            if not r["per"][l][0]:
                print("      %s: %s" % (l, r["per"][l][1]))
    print("総合:", "ALL PASS" if all_pass else "FAIL あり")


def write_report(langs, results, all_pass, cexe, ps):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    L = []
    L.append("# FuncInspector テスト結果")
    L.append("")
    L.append("`python tests/run_tests.py` で再実行できます。"
             "各テストは **期待値(アンカー)** と **3実装の相互一致** の両方を検証します。")
    L.append("")
    L.append("- 実行日時: %s" % now)
    L.append("- 検証した実装: %s" % ", ".join(langs))
    L.append("- C: %s" % ("gcc でビルドして検証" if cexe else "gcc が無いため SKIP"))
    L.append("- PowerShell: %s" % (("`%s` で検証" % os.path.basename(ps)) if ps else "pwsh/powershell が無いため SKIP"))
    L.append("- 総合判定: **%s**" % ("ALL PASS ✅" if all_pass else "FAIL あり ❌"))
    L.append("")
    L.append("## サマリ")
    L.append("")
    head = "| テスト | 内容 | " + " | ".join(langs) + " | 3実装一致 |"
    sep = "|" + "---|" * (3 + len(langs))
    L.append(head)
    L.append(sep)
    for r in results:
        t = r["t"]
        cells = []
        for l in langs:
            cells.append("PASS" if r["per"][l][0] else "**FAIL**")
        cons = "✅" if r["consistent"] else "❌"
        L.append("| `%s` | %s | %s | %s |" % (t["id"], t["desc"], " | ".join(cells), cons))
    L.append("")

    L.append("## テストデータと結果の詳細")
    L.append("")
    for r in results:
        t = r["t"]
        L.append("### %s — %s" % (t["id"], t["file"]))
        L.append("")
        L.append("- 説明: %s" % t["desc"])
        mode = "スイッチ一覧" if t["mode"] == "switches" else "関数抽出"
        opt = []
        if t["defines"]:
            opt.append("-D " + " -D ".join(t["defines"]))
        if t["ignore"]:
            opt.append("--ignore-switches")
        L.append("- モード: %s  オプション: %s" % (mode, " ".join(opt) if opt else "(なし)"))
        # 期待
        if t["mode"] == "scan":
            ex = t["expect"]
            fl = ", ".join("%s(steps=%d)" % (k, v) for k, v in ex["funcs"].items())
            L.append("- 期待: %d件 → %s" % (ex["count"], fl))
            if ex.get("absent"):
                L.append("- 非検出を期待: %s" % ", ".join(ex["absent"]))
        else:
            ex = t["expect"]["switches"]
            L.append("- 期待: " + ", ".join("%s(x%d,%s)" % (k, v[0], v[1]) for k, v in ex.items()))
        # 実際
        L.append("- 実際の検出: %s" % ("; ".join(r["shown"]) if r["shown"] else "(なし)"))
        verdict = []
        for l in langs:
            verdict.append("%s=%s" % (l, "PASS" if r["per"][l][0] else "FAIL(%s)" % r["per"][l][1]))
        L.append("- 判定: %s / 3実装%s" % (", ".join(verdict), "一致" if r["consistent"] else "不一致"))
        L.append("")

    L.append("## 入力ファイル")
    L.append("")
    for fn in sorted(os.listdir(CASES)):
        if not fn.endswith(".c"):
            continue
        L.append("### tests/cases/%s" % fn)
        L.append("")
        L.append("```c")
        with open(os.path.join(CASES, fn), "r", encoding="utf-8") as f:
            L.append(f.read().rstrip("\n"))
        L.append("```")
        L.append("")

    out = os.path.join(ROOT, "tests", "TEST_RESULTS.md")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    print("レポートを書き出しました:", out)


if __name__ == "__main__":
    sys.exit(main())
