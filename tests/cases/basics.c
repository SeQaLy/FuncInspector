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
