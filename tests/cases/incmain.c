/* incmain.c - 別ファイル(inccfg.h)の #define を include 追従で解決するテスト
 *   軽量(既定/include解決なし) : inccfg.h を読まない → TOOL_TEST 未定義 → inc_always のみ
 *   --resolve-includes          : inccfg.h を読む → TOOL_TEST=1 → inc_t1, inc_always
 */
#include "inccfg.h"

#if TOOL_TEST == 1
int inc_t1(void) { return 0; }
#elif TOOL_TEST == 2
int inc_t2(void) { return 0; }
#endif

void inc_always(void) { go(); }
