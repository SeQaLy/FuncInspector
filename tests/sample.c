/* sample.c - FuncInspector の動作確認用 */
#include <stdio.h>

#define WINAMS  /* 呼び出し規約マクロ (中身は空) */

/* プロトタイプ宣言: 検出されないこと */
int add(int a, int b);
void WINAMS startup(void);

/* 通常の関数定義 */
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

/* 戻り値の型が次行にある K&R 風でない普通の改行スタイル */
static long
helper_long(long x)
{
    return x * 2;
}

int main(void)
{
    startup();
    return add(1, 2);   /* 呼び出しは除外 */
}
