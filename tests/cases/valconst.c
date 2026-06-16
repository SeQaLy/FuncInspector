/* valconst.c - 値定数 (CFG_A) の扱いのテスト
 * CFG_A は #define CFG_A 100 の値定数で、比較の右辺としてだけ使われる。
 *   スイッチ一覧 : CFG_A は除外、TOOL_TEST の値候補に CFG_A は残る (1;2;CFG_A)
 *   --external 未選択         : CFG_A=100 を尊重 → 0==100 偽 → t_cfg は出ない (always のみ)
 *   --external -D TOOL_TEST=1 : t1, always
 */
#define TOOL_TEST 1
#define CFG_A 100

#if TOOL_TEST == 1
int t1(void) { return 0; }
#elif TOOL_TEST == 2
int t2(void) { return 0; }
#elif TOOL_TEST == CFG_A
int t_cfg(void) { return 0; }
#endif

void always(void) { go(); }
