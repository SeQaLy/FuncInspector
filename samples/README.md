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

| モード / 選択 | 検出される関数 |
|---|---|
| **軽量(既定/include解決なし)** | `main`, `startup`, `units_other` |
| **include解決 / 未選択** | `main`, `startup`, `debug_dump`, `generic_multi`, `units4_setup` |
| **include解決 / `-D USE_FEATURE_X`** | 上記 ＋ `feature_x_init`, `fx_advanced` |
| **include解決 / `-D PLATFORM_ARM`** | `main`, `startup`, `debug_dump`, `units4_setup`, **`arm32_handler`**（`generic_multi` の代わり） |
| **include解決 / `-D MAX_UNITS=2`** | `main`, `startup`, `debug_dump`, **`generic_single`**, **`units2_setup`** |
| **全コード有効(スイッチ無視)** | すべての枝（13個。排他の枝も両方）|

### 読み解きの要点

- **軽量**は各ファイル単体なので `config.h` を読まない → `BUILD_LEVEL` 等は未定義。
  `MAX_UNITS` も未定義なので `module.c` は `#else` の `units_other` になる。
- **include解決/未選択**:
  - `BUILD_LEVEL=2`,`MAX_UNITS=4`（値マクロ）は反映 → `debug_dump`,`units4_setup`,`generic_multi`。
  - `USE_FEATURE_X`,`PLATFORM_ARM`（フラグ）は**選択していないので OFF** → `feature_x_init`/`arm*` は出ない。
- **`-D USE_FEATURE_X`**: フラグON → `FEATURE_X_LEVEL=3` が**派生(カスケード)** → `fx_advanced` まで出る。
- **`-D PLATFORM_ARM`**: フラグON → `WORD_SIZE=32` が派生 → `arm32_handler`。
- **`-D MAX_UNITS=2`**: ピン留めで `config.h` の `4` を上書き → `units2_setup`＋`generic_single`。

## スイッチ一覧（`--list-switches`）の見え方

`BUILD_LEVEL(1;2)`, `MAX_UNITS(2;4)`, `WORD_SIZE(16;32)`, `USE_FEATURE_X(1)`, `PLATFORM_ARM(1)` …
のように**値候補**つきで出ます。

> メモ: インクルードガード（`CONFIG_H`/`FEATURES_H`/`PLATFORM_H`）や派生マクロ
> （`DEBUG_BUILD`/`FEATURE_X_LEVEL`）も `#if`/`#ifndef` で参照されるため一覧に出ます。
> これは仕様で、関数検出の結果には影響しません。
