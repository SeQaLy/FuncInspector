# FuncInspector

C 言語のソースコードから **関数定義** の関数名を抽出するツールです。
同じ仕様を **PowerShell / C / Python** の 3 言語で実装してあり、様々な環境で動かせます。

## 出力フォーマット

CSV の **先頭行にヘッダ(フォーマット行)が既定で付きます**。抑制するには
`--no-header` (PowerShell は `-NoHeader`)。

```
filepath,line,funcname,steps
src/foo.c,42,do_init,8
...
```

- `filepath` … ファイルパス
- `line` … 関数名が現れた行番号
- `funcname` … 関数名
- `steps` … ステップ数 (本体の実行行数。空行・コメント行・波括弧のみの行は除く)

スイッチ一覧モード (`--list-switches`) の出力:

```
switch,occurrences,state,filepath,line
```

- `switch` … コンパイルスイッチ名
- `occurrences` … `#if`/`#ifdef` 系での出現回数
- `state` … 現在 ON か OFF か (`-D`/`-U` の指定を反映)
- `filepath,line` … **最初に登場する箇所** (誤検知かどうかをここで確認できる)
- `values` … そのスイッチが `#if`/`#elif` で比較されている**値候補** (`;` 区切り)。
  例: `TOOL_TEST==1` / `#elif TOOL_TEST==2` → `1;2`、`#ifdef`/ブール使用は `1`。
  GUI ではこれがプルダウンの選択肢。
- **値定数の区別**: `#elif TOOL_TEST == CFG_A` のように、比較の**右辺(値)としてだけ**
  使われる識別子 (例 `#define CFG_A 100`) は「値定数」とみなし、**スイッチ一覧から除外**します
  (TOOL_TEST の値候補としては `CFG_A` が残ります)。さらに `--external-switches`
  (選択スイッチのみ有効) でも**値定数の `#define` は尊重**するので、未選択時に
  `TOOL_TEST(0) == CFG_A(0)` で `0==0` が成立して関数が誤って出てしまう、という事故を防ぎます
  (`CFG_A=100` を尊重 → `0==100` で偽)。

## 用途で切り分ける2モード

| | 関数一覧モード (既定・軽量) | スイッチ追跡モード (`--resolve-includes`・重い) |
|---|---|---|
| 想定ユーザー | 「とにかく関数の一覧が欲しい」 | 「どのスイッチでどの関数が有効かを正確に追いたい」 |
| `#include "..."` | **たどらない**(各ファイル単体で解析) | **たどる**(プロジェクト include を解決し別ファイルの `#define` も反映) |
| 速度 | 速い | ヘッダ処理ぶん遅い (`"..."` のみ。`<...>` システムヘッダは追わない) |
| 例 | `config.h` の `TOOL_TEST 1` は見えない | `config.h` を読んで `#if TOOL_TEST==1` を正しく判定 |

> 高速化: PowerShell GUI のスイッチ追跡モードは、**コメント除去済みソースを
> プロセス内にキャッシュ**します（パス＋更新時刻＋サイズで検証）。スイッチを
> 変えて再スキャンしても、ディスク読み込みとヘッダ解析を省けるので2回目以降が
> 速くなります（ファイルを編集した場合はそのファイルだけ自動で読み直し）。

スイッチ追跡モードは **完全 cpp 準拠**：ソースの `#define` を順にたどって反映します
（`-D`/`-U`・グリッド選択は常に最優先で上書き）。
- **値あり `#define X 10`＝ その値**、**フラグ（値なし `#define X`）＝ 定義(ON)**。
  どちらもファイルをまたいで反映され、条件付き定義の連鎖も自動（例: `CFG_UFS_ENABLE`
  が定義/選択されると中の `#define CFG_ENABLE 1` が効き、`#if CFG_ENABLE==1` の関数まで出る）。
- 値が実値と違う枝（例 `CFG_NUM=10` のとき `#if CFG_NUM==5`）は出ません（実ビルド準拠）。
- 探索のしかた：**ソースが定義したスイッチを外す**には `-U NAME`、**値を変える**には
  `-D NAME=val`（常に優先）。「全部OFFから選択で足したい」場合は通常（軽量）モード＝
  `--external-switches`（選択スイッチのみ有効）を使う。

**スキャン対象ツリーは自動で検索パスに含めるので、通常は `-I` 不要**です
（`config.h` がプロジェクト内のどこにあっても見つかります）。

**`-I` は上書き/追加用（任意・優先）**: ツリーの外にあるヘッダを足したい時や、
解決先を明示したい時だけ指定します。解決順は ① インクルード元ファイルと同じフォルダ →
② `-I` で指定したフォルダ → ③ スキャン対象ツリー（自動）。GUI では「include解決(重い)」
チェック＋「-I(任意)」欄（空でOK）です。

> 補足: プロジェクト内に**同名ヘッダが複数**ある場合だけ、自動検索ではどれが選ばれるか
> 不定になり得ます。その時は `-I` で優先フォルダを指定して確定させてください。

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
- **`-D`/`-U` はコマンドライン優先 (ピン留め)**: `-D NAME[=val]` / `-U NAME` で
  指定した名前は、**ソース内の `#define`/`#undef` では上書きされません**。
  たとえば `#define TOOL_TEST 0` がソースにあっても `-D TOOL_TEST=1` を付ければ
  `#if TOOL_TEST==1` のブロックが有効になります (ガード無しマクロの what-if 解析が
  そのままできる)。GUI でチェックしたスイッチも同様にピン留めされます。
- **選択スイッチのみ有効モード (`--external-switches`)**: ソース内の `#define`/`#undef`
  を**一切無視**し、スイッチは `-D` 選択だけで決めます。これにより
  「**選択した時だけ `#if` ブロックの関数が出る**」挙動になります。
  例: ソースに `#define TOOL_TEST 1` があっても、未選択なら `#if TOOL_TEST==1` は
  出ず、`-D TOOL_TEST=1` で出る、`-D TOOL_TEST=2` なら `#if TOOL_TEST==2` 側が出る。
  **GUI ではこのモードが既定 ON**（「選択スイッチのみ有効」チェック）で、値が必要な
  場合は「追加 -D」欄に `TOOL_TEST=2` のように入力します。
- **スイッチ値のプルダウン (PowerShell GUI)**: スイッチ一覧は表形式 (DataGridView) で、
  各行に「ON」チェックと「値」プルダウンがあります。プルダウンには `#if` から集めた
  値候補 (例 `1` / `2`、識別子なら `variable`) が入り、`TOOL_TEST==1` と `==2` の
  出し分けがその場で選べます。ON にした行の選択値で `-D` 相当の定義が行われます。
- **ステップ数**: 各関数のステップ数 (本体の実行行数) を表示します。
- **進捗表示**: GUI は進捗バー＋現在ファイル名、CUI は標準エラーに「処理中 N/総数」を
  表示します。
- **バックグラウンド実行**: GUI のスキャン/スイッチ検出は別スレッド (Python は
  threading、PowerShell は runspace) で動くので、処理中も画面が固まりません。
- **スイッチ箇所を開く**: GUI でスイッチ行をダブルクリックすると最初の登場箇所を
  エディタで開けます (VS Code の `code` コマンドがあれば該当行へジャンプ、無ければ
  既定アプリ)。結果一覧の関数行もダブルクリックで開けます。CUI は出力の `file,line`
  列で場所を確認できます。
- **GUI 説明ボタン (PowerShell GUI)**: 「説明」ボタンで子ウィンドウを開き、各モード
  (何も選択しない / スイッチ選択 / 全コード有効 / include解決) で**何が検出対象になるか**を
  まとめて確認できます。
- **GUI 検索 (PowerShell GUI)**: スイッチ表・関数一覧それぞれに絞り込みボックスがあり、
  スイッチ名 / ファイルパス・関数名で部分一致フィルタできます (大文字小文字無視)。
  スイッチ側は表示行を切り替えるだけなので ON/値の選択状態は保持されます。
- **GUI と CUI の両方**: PowerShell 版と Python 版は GUI でフォルダ/ファイル選択、
  スイッチのチェック ON/OFF、ステップ数表示ができます。C 版は CUI のみです。

> インクルードガード (`#ifndef FOO_H ... #endif`) は「未定義の ifndef = 真」なので
> 既定 (全 OFF) でも中身は有効として扱われます。

## 1. Python 版 (`python/func_inspector.py`)

GUI は標準ライブラリ tkinter を使用します。

```bash
# CUI
python python/func_inspector.py ./src
python python/func_inspector.py ./src --out result.csv
python python/func_inspector.py ./src --list-switches        # スイッチ一覧
python python/func_inspector.py ./src -D CFG_A -D VER=2       # スイッチ ON
python python/func_inspector.py ./src --ignore-switches       # 条件無視

# GUI (引数なし、または --gui)
python python/func_inspector.py
python python/func_inspector.py --gui
```

オプション: `--out/-o 出力先` `--ext 拡張子` `--no-header` `--gui`
`--list-switches` `-D NAME[=VAL]` `-U NAME` `--ignore-switches` `--external-switches` `--resolve-includes` `-I DIR(任意)`

## 2. PowerShell 版 (`powershell/FuncInspector.ps1`)

GUI は Windows Forms を使用します (Windows 環境)。
ファイルは **UTF-8 (BOM 付き)** で保存してあるため Windows PowerShell 5.1 / PowerShell 7 の
どちらでも文字化けせず動きます。本体ロジックは同フォルダの
`FuncInspector.Functions.ps1` にあり、`FuncInspector.ps1` はそれを読み込む薄い
ラッパーです (両ファイルを同じ場所に置いてください)。

```powershell
# CUI
.\powershell\FuncInspector.ps1 -Path .\src
.\powershell\FuncInspector.ps1 -Path .\src -Out result.csv
.\powershell\FuncInspector.ps1 -Path .\src -ListSwitches        # スイッチ一覧
.\powershell\FuncInspector.ps1 -Path .\src -D CFG_A,VER=2        # スイッチ ON
.\powershell\FuncInspector.ps1 -Path .\src -IgnoreSwitches       # 条件無視

# GUI (-Gui、または -Path 省略)
.\powershell\FuncInspector.ps1 -Gui
```

オプション: `-Out` `-Extensions` `-NoHeader` `-Gui` `-ListSwitches`
`-D/-Define NAME[,NAME=VAL]` `-U/-Undef NAME` `-IgnoreSwitches` `-ExternalSwitches` `-ResolveIncludes` `-I/-IncludeDirs DIR(任意)`

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

オプション: `--out 出力先` `--ext 拡張子` `--no-header` `--list-switches`
`-D NAME[=VAL]` `-U NAME` `--ignore-switches` `--external-switches` `--resolve-includes` `-I DIR(任意)` `-h/--help`

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

## パフォーマンス

- **関数本体を再走査しない**: 関数定義を見つけたら、本体は対応する `}` まで
  読み飛ばします (C に入れ子関数は無いため安全)。走査量が減り、誤検出も減ります。
- **PowerShell は C# にコンパイルして実行**: コメント除去・条件コンパイル評価・
  関数走査・スイッチ収集を `Add-Type` で C# 化し、純 PowerShell 実装の数十〜数百倍
  高速にしています。初回のみコンパイル(約 0.3〜0.7 秒)が走り、以降はキャッシュされます。
  C# が使えない環境では自動的に純 PowerShell 実装にフォールバックします
  (結果は同一)。

計測例 (約 52 万文字 / 27,600 行の C ファイル, 関数 2,400 個):

| 実装 | 改善前 | 改善後 |
|---|---|---|
| C | 約 0.06 s | 約 0.06 s |
| Python | 約 0.074 s | 約 0.061 s |
| PowerShell | 約 3.7 s | **約 0.016 s** (初回のみ +コンパイル) |

> Python/C は元々高速なので体感差は小さめです。効果が大きいのは PowerShell で、
> C# 化により実用上ほぼ C と同等になります。

## テスト

テストランナーで 3 実装をまとめて検証できます。**期待値(アンカー)との一致**と
**3 実装の相互一致**の両方をチェックします (gcc / pwsh が無い実装は自動 SKIP)。

```bash
python tests/run_tests.py        # 実行 → tests/TEST_RESULTS.md を生成
```

- 入力: `tests/cases/*.c` (基本・スイッチ・既知の限界の3種)
- 結果: [tests/TEST_RESULTS.md](tests/TEST_RESULTS.md) にテストデータ・期待値・実際の
  検出結果・判定が表で出力されます。
- 検証項目: 通常定義 / `WINAMS` 前置 / 関数ポインタ引数の検出、プロトタイプ・呼び出し・
  コメント/文字列の除外、スイッチ ON/OFF による増減、スイッチ一覧、そして既知の限界
  (`DEFINE_HANDLER` 誤検出・属性付き/K&R/関数ポインタ戻りの見逃し) を「現挙動」として固定。

また `tests/sample.c` 単体でも 3 実装が同一結果になることを確認できます (既定=全スイッチ OFF)。

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
