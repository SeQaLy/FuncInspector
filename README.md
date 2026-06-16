# FuncInspector

C 言語のソースコードから **関数定義** の関数名を抽出するツールです。
同じ仕様を **PowerShell / C / Python** の 3 言語で実装してあり、様々な環境で動かせます。

## 出力フォーマット

```
file.c,line,funcname,steps
```

- `file.c` … ファイルパス
- `line` … 関数名が現れた行番号
- `funcname` … 関数名
- `steps` … ステップ数 (本体の実行行数。空行・コメント行・波括弧のみの行は除く)

スイッチ一覧モード (`--list-switches`) の出力:

```
switch,occurrences,state,file,line
```

- `switch` … コンパイルスイッチ名
- `occurrences` … `#if`/`#ifdef` 系での出現回数
- `state` … 現在 ON か OFF か (`-D`/`-U` の指定を反映)
- `file,line` … **最初に登場する箇所** (誤検知かどうかをここで確認できる)

## 特徴

- **`WINAMS` などのマクロ対応**: `void WINAMS startup(void)` のように呼び出し規約
  マクロが付いていても、関数名 (`( の直前の識別子`) を正しく取り出します。
- **誤検出が少ない**: コメントと文字列/文字リテラルを除去してから解析します。
- **宣言・呼び出しを除外**: プロトタイプ宣言 (末尾が `;`)、`if/for/while/switch`
  などの制御構文、関数呼び出しは出力しません。関数定義 (`...) {`) のみ抽出します。
- **コンパイルスイッチ一覧**: `#ifdef`/`#ifndef`/`#if`/`#elif` で参照される
  マクロを一覧表示できます (`--list-switches`)。
- **スイッチ ON/OFF で検出を制御**: 条件コンパイルを評価し、`-D NAME` で有効化した
  ブロックのみ対象にします。**未指定のスイッチは OFF (未定義) 扱い**なので、
  スイッチを切り替えると検出される関数が増減します。`#if VER>=2` のような式
  (`defined()`, 比較, `&&`/`||`, 算術) も評価します。条件を無視して全コードを
  対象にするには `--ignore-switches`。
- **ステップ数**: 各関数のステップ数 (本体の実行行数) を表示します。
- **進捗表示**: GUI は進捗バー＋現在ファイル名、CUI は標準エラーに「処理中 N/総数」を
  表示します。
- **バックグラウンド実行**: GUI のスキャン/スイッチ検出は別スレッド (Python は
  threading、PowerShell は runspace) で動くので、処理中も画面が固まりません。
- **スイッチ箇所を開く**: GUI でスイッチ行をダブルクリックすると最初の登場箇所を
  エディタで開けます (VS Code の `code` コマンドがあれば該当行へジャンプ、無ければ
  既定アプリ)。結果一覧の関数行もダブルクリックで開けます。CUI は出力の `file,line`
  列で場所を確認できます。
- **GUI と CUI の両方**: PowerShell 版と Python 版は GUI でフォルダ/ファイル選択、
  スイッチのチェック ON/OFF、ステップ数表示ができます。C 版は CUI のみです。

> インクルードガード (`#ifndef FOO_H ... #endif`) は「未定義の ifndef = 真」なので
> 既定 (全 OFF) でも中身は有効として扱われます。

## 1. Python 版 (`python/func_inspector.py`)

GUI は標準ライブラリ tkinter を使用します。

```bash
# CUI
python python/func_inspector.py ./src
python python/func_inspector.py ./src --out result.csv --header
python python/func_inspector.py ./src --list-switches        # スイッチ一覧
python python/func_inspector.py ./src -D CFG_A -D VER=2       # スイッチ ON
python python/func_inspector.py ./src --ignore-switches       # 条件無視

# GUI (引数なし、または --gui)
python python/func_inspector.py
python python/func_inspector.py --gui
```

オプション: `--out/-o 出力先` `--ext 拡張子` `--header` `--gui`
`--list-switches` `-D NAME[=VAL]` `-U NAME` `--ignore-switches`

## 2. PowerShell 版 (`powershell/FuncInspector.ps1`)

GUI は Windows Forms を使用します (Windows 環境)。
ファイルは **UTF-8 (BOM 付き)** で保存してあるため Windows PowerShell 5.1 / PowerShell 7 の
どちらでも文字化けせず動きます。本体ロジックは同フォルダの
`FuncInspector.Functions.ps1` にあり、`FuncInspector.ps1` はそれを読み込む薄い
ラッパーです (両ファイルを同じ場所に置いてください)。

```powershell
# CUI
.\powershell\FuncInspector.ps1 -Path .\src
.\powershell\FuncInspector.ps1 -Path .\src -Out result.csv -Header
.\powershell\FuncInspector.ps1 -Path .\src -ListSwitches        # スイッチ一覧
.\powershell\FuncInspector.ps1 -Path .\src -D CFG_A,VER=2        # スイッチ ON
.\powershell\FuncInspector.ps1 -Path .\src -IgnoreSwitches       # 条件無視

# GUI (-Gui、または -Path 省略)
.\powershell\FuncInspector.ps1 -Gui
```

オプション: `-Out` `-Extensions` `-Header` `-Gui` `-ListSwitches`
`-D/-Define NAME[,NAME=VAL]` `-U/-Undef NAME` `-IgnoreSwitches`

実行ポリシーで止まる場合:
`powershell -ExecutionPolicy Bypass -File .\powershell\FuncInspector.ps1 -Gui`

### 2-b. プロファイル埋め込み版 (`powershell/FuncInspector.Functions.ps1`)

起動プロファイル ($PROFILE) に読み込んでおき、使いたいときにコマンドで呼ぶタイプです。
このファイルは読み込んでも何も実行せず、**関数を定義するだけ**です。

セットアップ (1 回だけ):

```powershell
# $PROFILE に次の1行を追記 (パスは環境に合わせる)
. "Z:\develop\FuncInspector\powershell\FuncInspector.Functions.ps1"
# PowerShell を再起動するか、その場で再読込:
. $PROFILE
```

読み込み後の使い方:

```powershell
Invoke-FuncInspector -Path .\src                       # file,line,funcname,steps
Invoke-FuncInspector -Path .\src -ListSwitches         # スイッチ一覧
Invoke-FuncInspector -Path .\src -D CFG_A,VER=2        # スイッチ ON
Invoke-FuncInspector -Path .\src -IgnoreSwitches       # 条件無視
Invoke-FuncInspector -Gui                               # GUI を開く
funcinspect .\src                                       # 別名 (alias)

# パイプ処理向けにオブジェクトで受け取る
Invoke-FuncInspector -Path .\src -AsObject | Where-Object Function -like 'WINAMS*'
Find-CFunctions -FilePath .\src\main.c -Defines @{CFG_A='1'} | Format-Table
```

## 3. C 版 (`c/func_inspector.c`)

CUI のみ。フォルダ指定時は再帰的に走査します (Win32 / POSIX 両対応)。

```bash
# ビルド
gcc -O2 -o func_inspector c/func_inspector.c      # Linux / macOS / MinGW
cl  /O2 c/func_inspector.c                          # MSVC (Windows)

# 実行
./func_inspector ./src
./func_inspector ./src --list-switches              # スイッチ一覧
./func_inspector ./src -D CFG_A -D VER=2            # スイッチ ON
./func_inspector ./src --ignore-switches            # 条件無視
```

オプション: `--out 出力先` `--ext 拡張子` `--header` `--list-switches`
`-D NAME[=VAL]` `-U NAME` `--ignore-switches` `-h/--help`

## 検出ロジック

1. コメント・文字列を空白に置換 (行番号は保持)。
2. (スイッチ評価時) `#ifdef`/`#if` 等を評価し、無効ブロックを空行化。
3. `識別子 ( ... )` の括弧を対応付け (関数ポインタ引数のネストにも対応)。
4. 閉じ括弧の次が `{` なら **関数定義** と判定し、識別子を関数名として出力。
5. `if/for/while` 等のキーワード、`.`/`->` の直後 (メンバ呼び出し) は除外。
6. 本体 `{`〜`}` の範囲でステップ数 (実行行数) を集計。

### 既知の制限

- 古い **K&R スタイル**の定義 (`int f(a, b) int a; int b; { ... }`) は、
  `)` の直後が `{` でないため検出できません。
- `#if` 式は一般的な部分集合 (`defined`, 整数, 比較, `&&`/`||`, 算術) を評価します。
  関数形式マクロの完全な展開などは行いません。

## テスト

`tests/sample.c` で 3 実装とも同一結果になることを確認できます (既定=全スイッチ OFF)。

```
file,line,function,steps
tests/sample.c,11,add,1
tests/sample.c,17,startup,1
tests/sample.c,23,run_cb,3
tests/sample.c,41,feature_default,1
tests/sample.c,58,feature_legacy,1
tests/sample.c,64,main,2
```

スイッチ一覧 (初出箇所つき):

```
switch,occurrences,state,file,line
CFG_A,2,OFF,tests/sample.c,33
CFG_B,1,OFF,tests/sample.c,52
VER,1,OFF,tests/sample.c,47
```

`-D CFG_A` を付けると `feature_default` が消え `feature_a` が現れる、のように
スイッチで検出関数が増減します。
