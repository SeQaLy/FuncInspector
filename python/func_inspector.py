#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FuncInspector (Python)
======================
C ソースコードから「関数定義」の関数名を抽出するツール。

出力フォーマット:
    file.c,line,funcname

特徴:
  - WINAMS などの呼び出し規約マクロが関数名の前に付いていても対応
    (関数名は「( の直前の識別子」として検出するため)
  - コメント / 文字列リテラルを除去してから解析するので誤検出が少ない
  - プロトタイプ宣言 (末尾が ;) や関数呼び出しは除外
  - CUI / GUI(tkinter) の両対応

使い方 (CUI):
    python func_inspector.py path1 [path2 ...] [options]
    python func_inspector.py src/ --out result.csv
    python func_inspector.py src/ --ext .c,.h --header

使い方 (GUI):
    python func_inspector.py            # 引数なしで GUI 起動
    python func_inspector.py --gui
"""

import os
import sys
import argparse

# 関数名になり得ない（=除外する）キーワード。
# if/for/while/switch などの制御構文を弾くのが主目的。
KEYWORDS = {
    "if", "for", "while", "switch", "return", "sizeof", "do", "else",
    "goto", "case", "default", "typedef", "struct", "union", "enum",
    "static", "extern", "const", "volatile", "register", "auto",
    "signed", "unsigned", "void", "char", "short", "int", "long",
    "float", "double", "_Bool", "inline", "__inline", "__attribute__",
    "_Static_assert", "_Generic", "_Alignas", "defined", "asm", "__asm",
}


def strip_comments_strings(src: str) -> str:
    """コメントと文字列/文字リテラルを空白に置換する。

    文字数と改行位置を維持するので、結果のインデックスは元ソースの
    行番号計算にそのまま使える。
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # 行コメント //
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                out.append(' ')
                i += 1
        # ブロックコメント /* */
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            out.append('  ')
            i += 2
            while i < n and not (src[i] == '*' and i + 1 < n and src[i + 1] == '/'):
                out.append('\n' if src[i] == '\n' else ' ')
                i += 1
            if i < n:
                out.append('  ')
                i += 2
        # 文字列 / 文字リテラル
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


def _is_ident_start(c: str) -> bool:
    return c.isalpha() or c == '_'


def _is_ident_char(c: str) -> bool:
    return c.isalnum() or c == '_'


def _preceded_by_member_access(s: str, idx: int) -> bool:
    """識別子の直前が . または -> なら (メンバアクセス=呼び出し) True。"""
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


def find_functions(src: str):
    """関数定義を (line, funcname) のリストで返す。"""
    clean = strip_comments_strings(src)
    n = len(clean)
    results = []
    i = 0
    while i < n:
        c = clean[i]
        if _is_ident_start(c):
            j = i
            while j < n and _is_ident_char(clean[j]):
                j += 1
            name = clean[i:j]

            # 識別子の後の空白を飛ばす
            k = j
            while k < n and clean[k] in ' \t\r\n':
                k += 1

            if k < n and clean[k] == '(' and name not in KEYWORDS:
                # 対応する ) を探す（関数ポインタ引数など括弧のネストに対応）
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
                # ) の後の空白を飛ばして { があれば定義
                q = p
                while q < n and clean[q] in ' \t\r\n':
                    q += 1
                if q < n and clean[q] == '{' and not _preceded_by_member_access(clean, i):
                    line = clean.count('\n', 0, i) + 1
                    results.append((line, name))
                    i = q + 1
                    continue
                # 定義でなければ ) の後ろから再開
                i = p
                continue
            else:
                i = j
                continue
        else:
            i += 1
    return results


def gather_files(paths, exts):
    """ファイル / ディレクトリの混在リストから対象ファイルを集める。"""
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


def analyze_file(path: str):
    """1ファイルを解析し (path, line, name) のリストを返す。"""
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            src = f.read()
    except OSError as e:
        sys.stderr.write("warning: cannot read %s: %s\n" % (path, e))
        return []
    return [(path, line, name) for (line, name) in find_functions(src)]


def analyze_paths(paths, exts):
    rows = []
    for fp in gather_files(paths, exts):
        rows.extend(analyze_file(fp))
    return rows


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
    root.geometry("760x520")

    top = ttk.Frame(root, padding=8)
    top.pack(fill="x")

    ttk.Label(top, text="フォルダ/ファイル:").pack(side="left")
    path_var = tk.StringVar()
    entry = ttk.Entry(top, textvariable=path_var)
    entry.pack(side="left", fill="x", expand=True, padx=4)

    def pick_folder():
        d = filedialog.askdirectory()
        if d:
            path_var.set(d)

    def pick_file():
        f = filedialog.askopenfilename(
            filetypes=[("C source", "*.c *.h"), ("All", "*.*")])
        if f:
            path_var.set(f)

    ttk.Button(top, text="フォルダ...", command=pick_folder).pack(side="left", padx=2)
    ttk.Button(top, text="ファイル...", command=pick_file).pack(side="left", padx=2)

    opt = ttk.Frame(root, padding=(8, 0))
    opt.pack(fill="x")
    ttk.Label(opt, text="拡張子:").pack(side="left")
    ext_var = tk.StringVar(value=".c,.h")
    ttk.Entry(opt, textvariable=ext_var, width=16).pack(side="left", padx=4)

    cols = ("file", "line", "func")
    tree = ttk.Treeview(root, columns=cols, show="headings")
    tree.heading("file", text="File")
    tree.heading("line", text="Line")
    tree.heading("func", text="Function")
    tree.column("file", width=440)
    tree.column("line", width=60, anchor="e")
    tree.column("func", width=220)
    tree.pack(fill="both", expand=True, padx=8, pady=8)

    status = tk.StringVar(value="準備完了")
    ttk.Label(root, textvariable=status, anchor="w").pack(fill="x", padx=8)

    def do_scan():
        p = path_var.get().strip()
        if not p:
            messagebox.showwarning("FuncInspector", "フォルダかファイルを指定してください。")
            return
        exts = [e.strip() if e.strip().startswith('.') else '.' + e.strip()
                for e in ext_var.get().split(',') if e.strip()]
        rows = analyze_paths([p], exts or [".c", ".h"])
        state["rows"] = rows
        for item in tree.get_children():
            tree.delete(item)
        for (fp, line, name) in rows:
            tree.insert("", "end", values=(fp, line, name))
        status.set("%d 件の関数を検出" % len(rows))

    def do_save():
        if not state["rows"]:
            messagebox.showinfo("FuncInspector", "保存するデータがありません。先にスキャンしてください。")
            return
        out = filedialog.asksaveasfilename(
            defaultextension=".csv",
            filetypes=[("CSV", "*.csv"), ("All", "*.*")])
        if not out:
            return
        try:
            with open(out, 'w', encoding='utf-8', newline='') as f:
                for (fp, line, name) in state["rows"]:
                    f.write("%s,%d,%s\n" % (fp, line, name))
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
def main(argv=None):
    parser = argparse.ArgumentParser(
        description="C ソースから関数名を抽出 (出力: file,line,funcname)")
    parser.add_argument("paths", nargs="*", help="ファイル または フォルダ")
    parser.add_argument("--gui", action="store_true", help="GUI を起動")
    parser.add_argument("--out", "-o", help="CSV 出力先 (省略時は標準出力)")
    parser.add_argument("--ext", default=".c,.h",
                        help="対象拡張子 (カンマ区切り, 既定: .c,.h)")
    parser.add_argument("--header", action="store_true",
                        help="ヘッダ行 file,line,function を付ける")
    args = parser.parse_args(argv)

    if args.gui or not args.paths:
        return run_gui()

    exts = [e if e.startswith('.') else '.' + e
            for e in (x.strip() for x in args.ext.split(',')) if e]
    rows = analyze_paths(args.paths, exts)

    lines = []
    if args.header:
        lines.append("file,line,function")
    for (fp, line, name) in rows:
        lines.append("%s,%d,%s" % (fp, line, name))
    text = "\n".join(lines)

    if args.out:
        with open(args.out, 'w', encoding='utf-8', newline='') as f:
            f.write(text + ("\n" if text else ""))
        sys.stderr.write("%d 件を %s に書き出しました\n" % (len(rows), args.out))
    else:
        if text:
            print(text)
        sys.stderr.write("%d 件検出\n" % len(rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
