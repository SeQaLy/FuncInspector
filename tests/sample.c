/* sample.c - FuncInspector の動作確認用 */
#include <stdio.h>

#define WINAMS  /* 呼び出し規約マクロ (中身は空) */

/* プロトタイプ宣言: 検出されないこと */
int add(int a, int b);
void WINAMS startup(void);

/* 通常の関数定義 (本体は return 1行 = 1 step) */
int add(int a, int b)
{
    return a + b;
}

/* WINAMS 付き定義: 関数名は startup */
void WINAMS startup(void)
{
    printf("start\n");   /* 文字列内の foo() { は無視されること */
}

/* 関数ポインタ引数を持つ定義 */
void run_cb(int (*cmp)(int, int), int n)
{
    if (n > 0) {          /* if は除外 */
        for (int i = 0; i < n; ++i) {   /* for も除外 */
            cmp(i, i);    /* 呼び出しは除外 */
        }
    }
}

/* ---- コンパイルスイッチで囲まれた関数 ---- */
#ifdef CFG_A
void feature_a(void)
{
    startup();
}
#endif

#ifndef CFG_A
void feature_default(void)
{
    add(1, 2);
}
#endif

#if VER >= 2
void feature_v2(void)
{
    feature_a();
}
#elif defined(CFG_B)
void feature_b(void)
{
    add(3, 4);
}
#else
void feature_legacy(void)
{
    add(0, 0);
}
#endif

int main(void)
{
    startup();
    return add(1, 2);   /* 呼び出しは除外 */
}
