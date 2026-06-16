# FuncInspector テスト結果

`python tests/run_tests.py` で再実行できます。各テストは **期待値(アンカー)** と **3実装の相互一致** の両方を検証します。

- 実行日時: 2026-06-16 20:30:41
- 検証した実装: Python, C, PowerShell
- C: gcc でビルドして検証
- PowerShell: `pwsh.EXE` で検証
- 総合判定: **ALL PASS ✅**

## サマリ

| テスト | 内容 | Python | C | PowerShell | 3実装一致 |
|---|---|---|---|---|---|
| `basics` | 基本: 通常定義 / WINAMS前置 / 関数ポインタ引数。プロトタイプ・呼び出し・コメント/文字列は除外 | PASS | PASS | PASS | ✅ |
| `switch-default` | スイッチ既定(全OFF): #ifndef は真、#if/#elif は偽→#else | PASS | PASS | PASS | ✅ |
| `switch-CFG_A` | -D CFG_A: #ifdef有効/#ifndef無効 | PASS | PASS | PASS | ✅ |
| `switch-VER2` | -D VER=2: #if VER>=2 を式評価で真 | PASS | PASS | PASS | ✅ |
| `switch-CFG_B` | -D CFG_B: #elif defined(CFG_B) を真 | PASS | PASS | PASS | ✅ |
| `switch-list` | スイッチ一覧: 出現回数と状態 | PASS | PASS | PASS | ✅ |
| `edge-known` | 既知の限界(現挙動を固定): DEFINE_HANDLER誤検出、trail/getfp/knr見逃し | PASS | PASS | PASS | ✅ |

## テストデータと結果の詳細

### basics — basics.c

- 説明: 基本: 通常定義 / WINAMS前置 / 関数ポインタ引数。プロトタイプ・呼び出し・コメント/文字列は除外
- モード: 関数抽出  オプション: (なし)
- 期待: 4件 → add(steps=1), startup(steps=1), run_cb(steps=2), main(steps=1)
- 非検出を期待: ghost
- 実際の検出: L10 add (steps=1); L15 startup (steps=1); L22 run_cb (steps=2); L28 main (steps=1)
- 判定: Python=PASS, C=PASS, PowerShell=PASS / 3実装一致

### switch-default — switches.c

- 説明: スイッチ既定(全OFF): #ifndef は真、#if/#elif は偽→#else
- モード: 関数抽出  オプション: (なし)
- 期待: 3件 → notA(steps=1), leg(steps=1), always(steps=1)
- 非検出を期待: a, v2, b
- 実際の検出: L14 notA (steps=1); L22 leg (steps=1); L25 always (steps=1)
- 判定: Python=PASS, C=PASS, PowerShell=PASS / 3実装一致

### switch-CFG_A — switches.c

- 説明: -D CFG_A: #ifdef有効/#ifndef無効
- モード: 関数抽出  オプション: -D CFG_A
- 期待: 3件 → a(steps=1), leg(steps=1), always(steps=1)
- 非検出を期待: notA
- 実際の検出: L10 a (steps=1); L22 leg (steps=1); L25 always (steps=1)
- 判定: Python=PASS, C=PASS, PowerShell=PASS / 3実装一致

### switch-VER2 — switches.c

- 説明: -D VER=2: #if VER>=2 を式評価で真
- モード: 関数抽出  オプション: -D VER=2
- 期待: 3件 → notA(steps=1), v2(steps=1), always(steps=1)
- 非検出を期待: leg, b
- 実際の検出: L14 notA (steps=1); L18 v2 (steps=1); L25 always (steps=1)
- 判定: Python=PASS, C=PASS, PowerShell=PASS / 3実装一致

### switch-CFG_B — switches.c

- 説明: -D CFG_B: #elif defined(CFG_B) を真
- モード: 関数抽出  オプション: -D CFG_B
- 期待: 3件 → notA(steps=1), b(steps=1), always(steps=1)
- 非検出を期待: leg, v2
- 実際の検出: L14 notA (steps=1); L20 b (steps=1); L25 always (steps=1)
- 判定: Python=PASS, C=PASS, PowerShell=PASS / 3実装一致

### switch-list — switches.c

- 説明: スイッチ一覧: 出現回数と状態
- モード: スイッチ一覧  オプション: (なし)
- 期待: CFG_A(x2,OFF), CFG_B(x1,OFF), VER(x1,OFF)
- 実際の検出: CFG_A x2 OFF; CFG_B x1 OFF; VER x1 OFF
- 判定: Python=PASS, C=PASS, PowerShell=PASS / 3実装一致

### edge-known — edge.c

- 説明: 既知の限界(現挙動を固定): DEFINE_HANDLER誤検出、trail/getfp/knr見逃し
- モード: 関数抽出  オプション: (なし)
- 期待: 1件 → DEFINE_HANDLER(steps=1)
- 非検出を期待: trail, getfp, knr, h
- 実際の検出: L9 DEFINE_HANDLER (steps=1)
- 判定: Python=PASS, C=PASS, PowerShell=PASS / 3実装一致

## 入力ファイル

### tests/cases/basics.c

```c
/* basics.c - 基本的な検出/除外のテスト
 * 期待: add, startup, run_cb, main の4関数のみ検出
 *       プロトタイプ宣言・関数呼び出し・コメント/文字列中の偽定義は除外
 */
#include <stdio.h>
#define WINAMS

int add(int a, int b);                 /* プロトタイプ: 除外 */

int add(int a, int b)                  /* 通常定義 steps=1 */
{
    return a + b;
}

void WINAMS startup(void)              /* WINAMS 前置 steps=1 */
{
    printf("brace trap: { } ( )\n");   /* 文字列中の括弧は無視 */
}

/* コメント中の偽定義: void ghost(void) { } は検出されない */

void run_cb(int (*cmp)(int, int), int n)   /* 関数ポインタ引数 steps=2 */
{
    if (n > 0)
        cmp(0, 0);
}

int main(void)                         /* steps=1 */
{
    return add(1, 2);                  /* 呼び出し: 除外 */
}
```

### tests/cases/edge.c

```c
/* edge.c - 既知の限界を「現在の挙動」として固定するテスト
 * 期待 (既定):
 *   - DEFINE_HANDLER が関数として検出される (誤検出: 本当の名前は h)
 *   - trail  は検出されない () と { の間に属性があるため (見逃し)
 *   - getfp  は検出されない 関数ポインタを返す関数 (見逃し)
 *   - knr    は検出されない K&R 旧式定義 (見逃し)
 * => 既定では DEFINE_HANDLER のみ検出
 */
DEFINE_HANDLER(h)
{
    go();
}

int trail(void) __attribute__((noreturn))
{
    return 0;
}

void (*getfp(void))(int)
{
    return 0;
}

int knr(a, b)
int a;
int b;
{
    return a + b;
}
```

### tests/cases/switches.c

```c
/* switches.c - コンパイルスイッチ ON/OFF と一覧のテスト
 * always は常に検出。他は -D 次第。
 *   既定(全OFF): notA, leg, always
 *   -D CFG_A   : a,    leg, always
 *   -D VER=2   : notA, v2,  always
 *   -D CFG_B   : notA, b,   always
 * スイッチ一覧: CFG_A x2, CFG_B x1, VER x1
 */
#ifdef CFG_A
void a(void){ fa(); }
#endif

#ifndef CFG_A
void notA(void){ fn(); }
#endif

#if VER >= 2
void v2(void){ fv(); }
#elif defined(CFG_B)
void b(void){ fb(); }
#else
void leg(void){ fl(); }
#endif

void always(void){ fk(); }
```

