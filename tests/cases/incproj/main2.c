/* main2.c - 自動include検出テスト: "cfg2.h" は deep/ にあり -I 無しで解決させる */
#include "cfg2.h"

#if FEATURE2 == 1
int feat2(void) { return 0; }
#endif

void base2(void) { go(); }
