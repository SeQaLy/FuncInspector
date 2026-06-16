/* external.c - 「選択スイッチのみ有効」(--external-switches) のテスト
 * ソースは #define TOOL_TEST 1 を直書きしている。
 *   既定(cpp準拠)           : 内蔵 #define が効き t1, always
 *   --external 未選択         : #define 無視で TOOL_TEST 未定義 -> always のみ
 *   --external -D TOOL_TEST=1 : t1, always
 *   --external -D TOOL_TEST=2 : t2, always (==1 は出ない)
 */
#define TOOL_TEST 1

#if TOOL_TEST == 1
int t1(void) { return 1; }
#endif

#if TOOL_TEST == 2
int t2(void) { return 2; }
#endif

void always(void) { go(); }
