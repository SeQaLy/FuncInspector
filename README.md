# FuncInspector

C 言語のソースコードから **関数定義** の関数名を抽出するツールです。
同じ仕様を **PowerShell / C / Python** の 3 言語で実装してあり、様々な環境で動かせます。

## 出力フォーマット

```
file.c,line,funcname
```

- `file.c` … ファイルパス
- `line` … 関数名が現れた行番号
- `funcname` … 関数名

## 特徴

- **`WINAMS` などのマクロ対応**: `void WINAMS startup(void)` のように呼び出し規約
  マクロが付いていても、関数名 (`( の直前の識別子`) を正しく取り出します。
- **誤検出が少ない**: コメントと文字列/文字リテラルを除去してから解析します。
- **宣言・呼び出しを除外**: プロトタイプ宣言 (末尾が `;`)、`if/for/while/switch`
  などの制御構文、関数呼び出しは出力しません。関数定義 (`...) {`) のみ抽出します。
- **GUI と CUI の両方**: PowerShell 版と Python 版は GUI でフォルダ/ファイルを
  選択できます。C 版は CUI のみです。

## 1. Python 版 (`python/func_inspector.py`)

GUI は標準ライブラリ tkinter を使用します。

```bash
# CUI
python python/func_inspector.py ./src
python python/func_inspector.py ./src --out result.csv --header
python python/func_inspector.py a.c b.c --ext .c,.h

# GUI (引数なし、または --gui)
python python/func_inspector.py
python python/func_inspector.py --gui
```

オプション: `--out/-o 出力先` `--ext 拡張子(カンマ区切り)` `--header` `--gui`

## 2. PowerShell 版 (`powershell/FuncInspector.ps1`)

GUI は Windows Forms を使用します (Windows 環境)。
ファイルは **UTF-8 (BOM 付き)** で保存してあるため Windows PowerShell 5.1 / PowerShell 7 の
どちらでも文字化けせず動きます。

```powershell
# CUI
.\powershell\FuncInspector.ps1 -Path .\src
.\powershell\FuncInspector.ps1 -Path .\src -Out result.csv -Header
.\powershell\FuncInspector.ps1 -Path a.c, b.c -Extensions .c, .h

# GUI (-Gui、または -Path 省略)
.\powershell\FuncInspector.ps1 -Gui
```

実行ポリシーで止まる場合:
`powershell -ExecutionPolicy Bypass -File .\powershell\FuncInspector.ps1 -Gui`

## 3. C 版 (`c/func_inspector.c`)

CUI のみ。フォルダ指定時は再帰的に走査します (Win32 / POSIX 両対応)。

```bash
# ビルド
gcc -O2 -o func_inspector c/func_inspector.c      # Linux / macOS / MinGW
cl  /O2 c/func_inspector.c                          # MSVC (Windows)

# 実行
./func_inspector ./src
./func_inspector ./src --out result.csv --header
./func_inspector a.c b.c --ext .c,.h
```

オプション: `--out 出力先` `--ext 拡張子` `--header` `-h/--help`

## 検出ロジック

1. コメント・文字列を空白に置換 (行番号は保持)。
2. `識別子 ( ... )` の括弧を対応付け (関数ポインタ引数のネストにも対応)。
3. 閉じ括弧の次が `{` なら **関数定義** と判定し、識別子を関数名として出力。
4. `if/for/while` 等のキーワード、`.`/`->` の直後 (メンバ呼び出し) は除外。

### 既知の制限

- 古い **K&R スタイル**の定義 (`int f(a, b) int a; int b; { ... }`) は、
  `)` の直後が `{` でないため検出できません。
- プリプロセッサで関数を生成するような特殊マクロは対象外です。

## テスト

`tests/sample.c` で 3 実装とも同一結果になることを確認できます。

```
tests/sample.c,11,add
tests/sample.c,17,startup
tests/sample.c,23,run_cb
tests/sample.c,34,helper_long
tests/sample.c,39,main
```
