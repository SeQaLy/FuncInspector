# サンプル（手動テスト用）

複雑なネスト・ファイルまたぎの `#define`・フラグ／値マクロ・カスケード・排他分岐・
`WINAMS` 前置を一通り含むミニプロジェクトです。各モードの挙動を手で確認できます。

## 構成

```
samples/
  config.h          値マクロ(BUILD_LEVEL,MAX_UNITS) + フラグ(USE_FEATURE_X) / sub/platform.h を include
  sub/platform.h    フラグ(PLATFORM_ARM) → 条件付きで WORD_SIZE を定義(カスケード)
  features.h        config.h を include。USE_FEATURE_X→FEATURE_X_LEVEL, BUILD_LEVEL→DEBUG_BUILD を派生
  main.c            features.h を include。4段ネストの #if/#ifdef/#elif/#else
  module.c          features.h を include。MAX_UNITS の排他分岐 + WINAMS 前置 + フラグ配下のネスト
```

依存: `main.c`/`module.c` → `features.h` → `config.h` → `sub/platform.h`

## 実行コマンド（どれでも同じ結果）

```bash
# CUI
python python/func_inspector.py samples --resolve-includes
./c/func_inspector.exe samples --resolve-includes
```
```powershell
.\powershell\FuncInspector.ps1 -Path .\samples -ResolveIncludes
# GUI: -Gui → フォルダに samples を指定 →「include解決(重い)」にチェック → スキャン
.\powershell\FuncInspector.ps1 -Gui
```

## 期待される検出結果（モード別）

include解決は **完全 cpp 準拠**：ソースの `#define`（フラグ含む）をたどって反映します。
このサンプルは `config.h`/`platform.h` でフラグ（`USE_FEATURE_X`,`PLATFORM_ARM`）を
`#define` しているので、**include解決では既定で ON**。外したい時は `-U` で上書きします。

| モード / 上書き | 検出される関数 |
|---|---|
| **軽量(既定/include解決なし)** | `main`, `startup`, `units_other` |
| **include解決 / 上書きなし** | `main`, `startup`, `debug_dump`, `arm32_handler`, `units4_setup`, `feature_x_init`, `fx_advanced`（7個）|
| **include解決 / `-U USE_FEATURE_X`** | 上記から `feature_x_init`, `fx_advanced` が消える |
| **include解決 / `-U PLATFORM_ARM`** | `arm32_handler` → **`generic_multi`** に変わる |
| **include解決 / `-D MAX_UNITS=2`** | `units4_setup` → **`units2_setup`** に変わる |
| **全コード有効(スイッチ無視)** | すべての枝（13個。排他の枝も両方）|

### 読み解きの要点

- **軽量**は各ファイル単体なので `config.h` を読まない → `BUILD_LEVEL`/`MAX_UNITS` 等は未定義。
  `module.c` は `#else` の `units_other` になる（`feature_x_init`/`arm*` も出ない）。
- **include解決/上書きなし**:
  - 値マクロ `BUILD_LEVEL=2`,`MAX_UNITS=4` を反映 → `debug_dump`,`units4_setup`。
  - フラグ `USE_FEATURE_X`,`PLATFORM_ARM` も**ソースが定義しているので ON** →
    `FEATURE_X_LEVEL=3`/`WORD_SIZE=32` が**派生(カスケード)** → `feature_x_init`,`fx_advanced`,`arm32_handler`。
- **`-U USE_FEATURE_X`**: フラグを上書きOFF → `feature_x_init`,`fx_advanced` が消える。
- **`-U PLATFORM_ARM`**: フラグを上書きOFF → `WORD_SIZE=16` → `arm32_handler` が `generic_multi` に。
- **`-D MAX_UNITS=2`**: 値を上書き → `units2_setup`。
- 「全部OFFから選択で足す」探索がしたい場合は、**通常（軽量）モード**＝選択スイッチのみ有効を使う。

## スイッチ一覧（`--list-switches`）の見え方

`BUILD_LEVEL(1;2)`, `MAX_UNITS(2;4)`, `WORD_SIZE(16;32)`, `USE_FEATURE_X(1)`, `PLATFORM_ARM(1)` …
のように**値候補**つきで出ます。

> メモ: インクルードガード（`CONFIG_H`/`FEATURES_H`/`PLATFORM_H`）や派生マクロ
> （`DEBUG_BUILD`/`FEATURE_X_LEVEL`）も `#if`/`#ifndef` で参照されるため一覧に出ます。
> これは仕様で、関数検出の結果には影響しません。
