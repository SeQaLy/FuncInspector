#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FuncInspector (Python)
======================
C ソースコードから「関数定義」の関数名を抽出するツール。

出力フォーマット:
    file.c,line,funcname,steps

機能:
  - WINAMS などの呼び出し規約マクロが関数名の前に付いていても対応
  - コメント / 文字列リテラルを除去してから解析
  - プロトタイプ宣言 (末尾 ;) や関数呼び出しは除外
  - コンパイルスイッチ (#ifdef / #ifndef / #if / #elif) の一覧表示
  - スイッチを -D / -U で ON/OFF し、条件コンパイルを評価して
    検出する関数を増減できる (未指定スイッチは OFF=未定義 扱い)
  - 各関数のステップ数 (本体の実行行数。空行・コメント・波括弧のみの行は除く)
  - CUI / GUI(tkinter) 両対応

使い方 (CUI):
    python func_inspector.py path1 [path2 ...] [options]
    python func_inspector.py src/ --list-switches          # スイッチ一覧
    python func_inspector.py src/ -D CFG_A -D VER=2         # スイッチ ON
    python func_inspector.py src/ --ignore-switches         # 条件無視(全部有効)

使い方 (GUI):
    python func_inspector.py            # 引数なしで GUI 起動
    python func_inspector.py --gui
"""

import os
import re
import sys
import bisect
import argparse

# 関数名になり得ない（除外する）キーワード
KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "do", "else",
    "goto", "case", "default", "typedef", "struct", "union", "enum",
    "static", "extern", "const", "volatile", "register", "auto",
    "signed", "unsigned", "void", "char", "short", "int", "long",
    "float", "double", "_Bool", "inline", "__inline", "__attribute__",
    "_Static_assert", "_Generic", "_Alignas", "defined", "asm", "__asm",
}

_DIRECTIVE = re.compile(r'^\s*#\s*(ifdef|ifndef|if|elif|else|endif|define|undef)\b(.*)$')
_IDENT = re.compile(r'[A-Za-z_]\w*')


# --------------------------------------------------------------------------
# コメント / 文字列の除去
# --------------------------------------------------------------------------
def strip_comments_strings(src: str) -> str:
    """コメントと文字列/文字リテラルを空白に置換 (文字数・改行位置は維持)。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out.append(' ')
                i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            out.append('  ')
            i += 2
            while i < n and not (src[i] == '*' and i + 1 < n and src[i + 1] == '/'):
                out.append('\n' if src[i] == '\n' else ' ')
                i += 1
            if i < n:
                out.append('  ')
                i += 2
        elif c == '"' or c == "'":
            quote = c
            out.append(' ')
            i += 1
            while i < n and src[i] != quote:
                if src[i] == '\\' and i + 1 < n:
                    out.append('  ')
                    i += 2
                else:
                    out.append('\n' if src[i] == '\n' else ' ')
                    i += 1
            if i < n:
                out.append(' ')
                i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)


# --------------------------------------------------------------------------
# コンパイルスイッチの収集
# --------------------------------------------------------------------------
def collect_switches(src: str) -> dict:
    """#if 系ディレクティブで参照されるマクロ名 -> 出現回数 を返す。"""
    clean = strip_comments_strings(src)
    counts = {}
    for line in clean.split('\n'):
        m = _DIRECTIVE.match(line)
        if not m:
            continue
        kind, rest = m.group(1), m.group(2)
        if kind in ('ifdef', 'ifndef'):
            mm = _IDENT.search(rest)
            if mm:
                counts[mm.group(0)] = counts.get(mm.group(0), 0) + 1
        elif kind in ('if', 'elif'):
            for mm in _IDENT.finditer(rest):
                name = mm.group(0)
                if name == 'defined':
                    continue
                counts[name] = counts.get(name, 0) + 1
    return counts


# --------------------------------------------------------------------------
# #if 式の評価
# --------------------------------------------------------------------------
def _tokenize_expr(s: str):
    toks = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c.isspace():
            i += 1
            continue
        if c.isdigit():
            if c == '0' and i + 1 < n and s[i + 1] in 'xX':
                j = i + 2
                while j < n and s[j] in '0123456789abcdefABCDEF':
                    j += 1
                toks.append(('num', int(s[i:j], 16)))
                i = j
            else:
                j = i
                while j < n and s[j].isdigit():
                    j += 1
                val = int(s[i:j])
                while j < n and s[j] in 'uUlL':
                    j += 1
                toks.append(('num', val))
                i = j
            continue
        if c == '_' or c.isalpha():
            j = i
            while j < n and (s[j].isalnum() or s[j] == '_'):
                j += 1
            toks.append(('id', s[i:j]))
            i = j
            continue
        two = s[i:i + 2]
        if two in ('&&', '||', '==', '!=', '<=', '>='):
            toks.append(('op', two))
            i += 2
            continue
        if c in '!()<>+-*/%':
            toks.append(('op', c))
            i += 1
            continue
        i += 1
    return toks


def _macro_int(name, defines, seen):
    if name not in defines:
        return 0
    if name in seen:
        return 0
    v = defines[name]
    if v is None or v == '':
        return 1
    v = v.strip()
    try:
        return int(v, 0)
    except ValueError:
        if _IDENT.fullmatch(v):
            return _macro_int(v, defines, seen | {name})
        return 0


def _apply(op, a, b):
    if op == '*':  return a * b
    if op == '/':  return a // b if b else 0
    if op == '%':  return a % b if b else 0
    if op == '+':  return a + b
    if op == '-':  return a - b
    if op == '<':  return 1 if a < b else 0
    if op == '>':  return 1 if a > b else 0
    if op == '<=': return 1 if a <= b else 0
    if op == '>=': return 1 if a >= b else 0
    if op == '==': return 1 if a == b else 0
    if op == '!=': return 1 if a != b else 0
    if op == '&&': return 1 if (a and b) else 0
    if op == '||': return 1 if (a or b) else 0
    return 0


def _eval_expr(expr: str, defines: dict) -> int:
    toks = _tokenize_expr(expr)
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def adv():
        t = toks[pos[0]]
        pos[0] += 1
        return t

    def primary():
        t = peek()
        if t is None:
            return 0
        if t == ('op', '('):
            adv()
            v = p_or()
            if peek() == ('op', ')'):
                adv()
            return v
        if t[0] == 'id' and t[1] == 'defined':
            adv()
            nm = None
            if peek() == ('op', '('):
                adv()
                if peek() and peek()[0] == 'id':
                    nm = adv()[1]
                if peek() == ('op', ')'):
                    adv()
            elif peek() and peek()[0] == 'id':
                nm = adv()[1]
            return 1 if (nm in defines) else 0
        if t[0] == 'id':
            adv()
            return _macro_int(t[1], defines, set())
        if t[0] == 'num':
            adv()
            return t[1]
        adv()
        return 0

    def unary():
        t = peek()
        if t and t[0] == 'op' and t[1] in ('!', '-', '+'):
            adv()
            v = unary()
            if t[1] == '!':
                return 0 if v else 1
            if t[1] == '-':
                return -v
            return v
        return primary()

    def binop(sub, ops):
        v = sub()
        while True:
            t = peek()
            if t and t[0] == 'op' and t[1] in ops:
                adv()
                v = _apply(t[1], v, sub())
            else:
                break
        return v

    def p_mul():  return binop(unary, ('*', '/', '%'))
    def p_add():  return binop(p_mul, ('+', '-'))
    def p_rel():  return binop(p_add, ('<', '>', '<=', '>='))
    def p_eq():   return binop(p_rel, ('==', '!='))
    def p_and():  return binop(p_eq, ('&&',))
    def p_or():   return binop(p_and, ('||',))

    try:
        return 1 if p_or() else 0
    except Exception:
        return 0


# --------------------------------------------------------------------------
# プリプロセス (条件コンパイル評価)
# --------------------------------------------------------------------------
def preprocess(clean: str, defines: dict) -> str:
    """条件コンパイルを評価し、無効ブロックとディレクティブ行を空行化する。
    行番号を保つため行数は変えない。defines は破壊的に更新され得る (呼び元でコピー)。
    """
    out = []
    stack = []  # 各フレーム: {'parent':bool, 'taken':bool, 'active':bool}

    def emitting():
        for f in stack:
            if not f['active']:
                return False
        return True

    for line in clean.split('\n'):
        m = _DIRECTIVE.match(line)
        if m:
            kind, rest = m.group(1), m.group(2).strip()
            if kind == 'ifdef':
                parent = emitting()
                mm = _IDENT.search(rest)
                cond = bool(mm) and (mm.group(0) in defines)
                stack.append({'parent': parent, 'taken': parent and cond, 'active': parent and cond})
            elif kind == 'ifndef':
                parent = emitting()
                mm = _IDENT.search(rest)
                cond = (not mm) or (mm.group(0) not in defines)
                stack.append({'parent': parent, 'taken': parent and cond, 'active': parent and cond})
            elif kind == 'if':
                parent = emitting()
                cond = bool(_eval_expr(rest, defines)) if parent else False
                stack.append({'parent': parent, 'taken': parent and cond, 'active': parent and cond})
            elif kind == 'elif':
                if stack:
                    f = stack[-1]
                    if f['parent'] and not f['taken']:
                        cond = bool(_eval_expr(rest, defines))
                        f['active'] = cond
                        f['taken'] = f['taken'] or cond
                    else:
                        f['active'] = False
            elif kind == 'else':
                if stack:
                    f = stack[-1]
                    if f['parent'] and not f['taken']:
                        f['active'] = True
                        f['taken'] = True
                    else:
                        f['active'] = False
            elif kind == 'endif':
                if stack:
                    stack.pop()
            elif kind == 'define':
                if emitting():
                    mm = _IDENT.search(rest)
                    if mm:
                        after = rest[mm.end():].strip()
                        defines[mm.group(0)] = after if after else '1'
            elif kind == 'undef':
                if emitting():
                    mm = _IDENT.search(rest)
                    if mm and mm.group(0) in defines:
                        del defines[mm.group(0)]
            out.append('')  # ディレクティブ行自体は空行化
        else:
            out.append(line if emitting() else '')
    return '\n'.join(out)


# --------------------------------------------------------------------------
# 関数検出 + ステップ数
# --------------------------------------------------------------------------
def _is_ident_start(c): return c.isalpha() or c == '_'
def _is_ident_char(c):  return c.isalnum() or c == '_'


def _preceded_by_member_access(s, idx):
    j = idx - 1
    while j >= 0 and s[j] in ' \t\r\n':
        j -= 1
    if j < 0:
        return False
    if s[j] == '.':
        return True
    if s[j] == '>' and j - 1 >= 0 and s[j - 1] == '-':
        return True
    return False


def _build_line_starts(s):
    starts = [0]
    for i, ch in enumerate(s):
        if ch == '\n':
            starts.append(i + 1)
    return starts


def _line_of(starts, idx):
    return bisect.bisect_right(starts, idx)


def _count_steps(lines, l1, l2):
    """[l1..l2] 行のうち、空行・コメント行・波括弧のみの行を除いた行数。"""
    cnt = 0
    for k in range(l1, l2 + 1):
        if k - 1 < 0 or k - 1 >= len(lines):
            continue
        stripped = ''.join(ch for ch in lines[k - 1] if not ch.isspace())
        if not stripped:
            continue
        if all(ch in '{}' for ch in stripped):
            continue
        cnt += 1
    return cnt


def _scan(clean):
    """クリーン化済みテキストから (line, name, steps) を抽出。"""
    n = len(clean)
    starts = _build_line_starts(clean)
    lines = clean.split('\n')
    results = []
    i = 0
    while i < n:
        c = clean[i]
        if _is_ident_start(c):
            j = i
            while j < n and _is_ident_char(clean[j]):
                j += 1
            name = clean[i:j]
            k = j
            while k < n and clean[k] in ' \t\r\n':
                k += 1
            if k < n and clean[k] == '(' and name not in KEYWORDS:
                depth = 0
                p = k
                while p < n:
                    if clean[p] == '(':
                        depth += 1
                    elif clean[p] == ')':
                        depth -= 1
                        if depth == 0:
                            p += 1
                            break
                    p += 1
                q = p
                while q < n and clean[q] in ' \t\r\n':
                    q += 1
                if q < n and clean[q] == '{' and not _preceded_by_member_access(clean, i):
                    # 本体の対応する } を探す
                    d2 = 0
                    r = q
                    close = n - 1
                    while r < n:
                        if clean[r] == '{':
                            d2 += 1
                        elif clean[r] == '}':
                            d2 -= 1
                            if d2 == 0:
                                close = r
                                break
                        r += 1
                    l1 = _line_of(starts, q)
                    l2 = _line_of(starts, close)
                    steps = _count_steps(lines, l1, l2)
                    results.append((_line_of(starts, i), name, steps))
                    i = q + 1
                    continue
                i = p
                continue
            else:
                i = j
                continue
        else:
            i += 1
    return results


def find_functions(src, defines=None):
    """関数定義を (line, name, steps) のリストで返す。
    defines が None なら条件コンパイルを無視 (全コード有効)。
    dict (空可) を渡すとスイッチ評価を行う。
    """
    clean = strip_comments_strings(src)
    if defines is not None:
        clean = preprocess(clean, dict(defines))
    return _scan(clean)


# --------------------------------------------------------------------------
# ファイル収集 / 解析
# --------------------------------------------------------------------------
def gather_files(paths, exts):
    exts = tuple(e.lower() for e in exts)
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, names in os.walk(p):
                for nm in names:
                    if nm.lower().endswith(exts):
                        files.append(os.path.join(root, nm))
        elif os.path.isfile(p):
            files.append(p)
        else:
            sys.stderr.write("warning: not found: %s\n" % p)
    return files


def _read(path):
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError as e:
        sys.stderr.write("warning: cannot read %s: %s\n" % (path, e))
        return None


def analyze_file(path, defines=None):
    src = _read(path)
    if src is None:
        return []
    return [(path, line, name, steps) for (line, name, steps) in find_functions(src, defines)]


def analyze_paths(paths, exts, defines=None):
    rows = []
    for fp in gather_files(paths, exts):
        rows.extend(analyze_file(fp, defines))
    return rows


def switches_in_paths(paths, exts):
    counts = {}
    for fp in gather_files(paths, exts):
        src = _read(fp)
        if src is None:
            continue
        for name, c in collect_switches(src).items():
            counts[name] = counts.get(name, 0) + c
    return counts


# --------------------------------------------------------------------------
# GUI (tkinter)
# --------------------------------------------------------------------------
def run_gui():
    try:
        import tkinter as tk
        from tkinter import ttk, filedialog, messagebox
    except ImportError:
        sys.stderr.write("tkinter が無いため GUI を起動できません。CUI を使ってください。\n")
        return 1

    state = {"rows": []}

    root = tk.Tk()
    root.title("FuncInspector - C 関数名抽出")
    root.geometry("860x600")

    top = ttk.Frame(root, padding=8)
    top.pack(fill="x")
    ttk.Label(top, text="フォルダ/ファイル:").pack(side="left")
    path_var = tk.StringVar()
    ttk.Entry(top, textvariable=path_var).pack(side="left", fill="x", expand=True, padx=4)

    def pick_folder():
        d = filedialog.askdirectory()
        if d:
            path_var.set(d)

    def pick_file():
        f = filedialog.askopenfilename(filetypes=[("C source", "*.c *.h"), ("All", "*.*")])
        if f:
            path_var.set(f)

    ttk.Button(top, text="フォルダ...", command=pick_folder).pack(side="left", padx=2)
    ttk.Button(top, text="ファイル...", command=pick_file).pack(side="left", padx=2)

    opt = ttk.Frame(root, padding=(8, 0))
    opt.pack(fill="x")
    ttk.Label(opt, text="拡張子:").pack(side="left")
    ext_var = tk.StringVar(value=".c,.h")
    ttk.Entry(opt, textvariable=ext_var, width=16).pack(side="left", padx=4)
    ignore_var = tk.BooleanVar(value=False)
    ttk.Checkbutton(opt, text="スイッチを無視(全コード有効)", variable=ignore_var).pack(side="left", padx=8)

    mid = ttk.Frame(root, padding=8)
    mid.pack(fill="both", expand=True)

    # 左: スイッチ一覧 (選択=ON)
    left = ttk.Frame(mid)
    left.pack(side="left", fill="y")
    ttk.Label(left, text="コンパイルスイッチ (選択=ON)").pack(anchor="w")
    sw_list = tk.Listbox(left, selectmode="extended", width=26, height=22, exportselection=False)
    sw_list.pack(fill="y", expand=True)

    def detect_switches():
        p = path_var.get().strip()
        if not p:
            messagebox.showwarning("FuncInspector", "フォルダかファイルを指定してください。")
            return
        exts = _parse_exts(ext_var.get())
        counts = switches_in_paths([p], exts)
        sw_list.delete(0, "end")
        for name in sorted(counts):
            sw_list.insert("end", "%s  (x%d)" % (name, counts[name]))
        status.set("%d 個のスイッチを検出" % len(counts))

    ttk.Button(left, text="スイッチ検出", command=detect_switches).pack(fill="x", pady=4)

    # 右: 結果ツリー
    right = ttk.Frame(mid)
    right.pack(side="left", fill="both", expand=True, padx=(8, 0))
    cols = ("file", "line", "func", "steps")
    tree = ttk.Treeview(right, columns=cols, show="headings")
    for c, t, w, a in (("file", "File", 360, "w"), ("line", "Line", 55, "e"),
                       ("func", "Function", 180, "w"), ("steps", "Steps", 60, "e")):
        tree.heading(c, text=t)
        tree.column(c, width=w, anchor=a)
    tree.pack(fill="both", expand=True)

    status = tk.StringVar(value="準備完了")
    ttk.Label(root, textvariable=status, anchor="w").pack(fill="x", padx=8)

    def selected_defines():
        defs = {}
        for idx in sw_list.curselection():
            text = sw_list.get(idx)
            name = text.split()[0]
            defs[name] = '1'
        return defs

    def do_scan():
        p = path_var.get().strip()
        if not p:
            messagebox.showwarning("FuncInspector", "フォルダかファイルを指定してください。")
            return
        exts = _parse_exts(ext_var.get())
        defines = None if ignore_var.get() else selected_defines()
        rows = analyze_paths([p], exts, defines)
        state["rows"] = rows
        for it in tree.get_children():
            tree.delete(it)
        for (fp, line, name, steps) in rows:
            tree.insert("", "end", values=(fp, line, name, steps))
        total = sum(r[3] for r in rows)
        status.set("%d 関数 / 合計 %d ステップ" % (len(rows), total))

    def do_save():
        if not state["rows"]:
            messagebox.showinfo("FuncInspector", "保存するデータがありません。先にスキャンしてください。")
            return
        out = filedialog.asksaveasfilename(defaultextension=".csv",
                                           filetypes=[("CSV", "*.csv"), ("All", "*.*")])
        if not out:
            return
        try:
            with open(out, 'w', encoding='utf-8', newline='') as f:
                for (fp, line, name, steps) in state["rows"]:
                    f.write("%s,%d,%s,%d\n" % (fp, line, name, steps))
            status.set("保存しました: %s" % out)
        except OSError as e:
            messagebox.showerror("FuncInspector", "保存に失敗: %s" % e)

    btns = ttk.Frame(root, padding=8)
    btns.pack(fill="x")
    ttk.Button(btns, text="スキャン", command=do_scan).pack(side="left")
    ttk.Button(btns, text="CSV 保存", command=do_save).pack(side="left", padx=6)
    ttk.Button(btns, text="終了", command=root.destroy).pack(side="right")

    root.mainloop()
    return 0


# --------------------------------------------------------------------------
# CUI
# --------------------------------------------------------------------------
def _parse_exts(s):
    return [e if e.startswith('.') else '.' + e
            for e in (x.strip() for x in s.split(',')) if e]


def _build_defines(define_args, undef_args):
    defines = {}
    for d in (define_args or []):
        if '=' in d:
            name, val = d.split('=', 1)
            defines[name.strip()] = val
        else:
            defines[d.strip()] = '1'
    for u in (undef_args or []):
        defines.pop(u.strip(), None)
    return defines


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="C ソースから関数名を抽出 (出力: file,line,funcname,steps)")
    parser.add_argument("paths", nargs="*", help="ファイル または フォルダ")
    parser.add_argument("--gui", action="store_true", help="GUI を起動")
    parser.add_argument("--out", "-o", help="CSV 出力先 (省略時は標準出力)")
    parser.add_argument("--ext", default=".c,.h", help="対象拡張子 (既定: .c,.h)")
    parser.add_argument("--header", action="store_true", help="ヘッダ行を付ける")
    parser.add_argument("--list-switches", action="store_true",
                        help="コンパイルスイッチの一覧を出力 (switch,occurrences,state)")
    parser.add_argument("-D", dest="define", action="append", metavar="NAME[=VAL]",
                        help="スイッチを ON (定義)。複数指定可")
    parser.add_argument("-U", dest="undef", action="append", metavar="NAME",
                        help="スイッチを OFF (未定義)。複数指定可")
    parser.add_argument("--ignore-switches", action="store_true",
                        help="条件コンパイルを無視して全コードを対象にする")
    args = parser.parse_args(argv)

    if args.gui or not args.paths:
        return run_gui()

    exts = _parse_exts(args.ext)
    defines = _build_defines(args.define, args.undef)

    # スイッチ一覧モード
    if args.list_switches:
        counts = switches_in_paths(args.paths, exts)
        lines = []
        if args.header:
            lines.append("switch,occurrences,state")
        for name in sorted(counts):
            state = "ON" if name in defines else "OFF"
            lines.append("%s,%d,%s" % (name, counts[name], state))
        text = "\n".join(lines)
        _emit(text, args.out)
        sys.stderr.write("%d 個のスイッチ\n" % len(counts))
        return 0

    # 関数抽出モード
    use_defines = None if args.ignore_switches else defines
    rows = analyze_paths(args.paths, exts, use_defines)
    lines = []
    if args.header:
        lines.append("file,line,function,steps")
    for (fp, line, name, steps) in rows:
        lines.append("%s,%d,%s,%d" % (fp, line, name, steps))
    text = "\n".join(lines)
    _emit(text, args.out)
    total = sum(r[3] for r in rows)
    sys.stderr.write("%d 関数 / 合計 %d ステップ\n" % (len(rows), total))
    return 0


def _emit(text, out):
    if out:
        with open(out, 'w', encoding='utf-8', newline='') as f:
            f.write(text + ("\n" if text else ""))
        sys.stderr.write("%s に書き出しました\n" % out)
    elif text:
        print(text)


if __name__ == "__main__":
    sys.exit(main())
