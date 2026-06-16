/* values.c - スイッチの値候補抽出のテスト
 *   LOCAL_LOG_ENABLE : 1        (#ifdef)
 *   TOOL_TEST        : 1;2      (#if ==1 / #elif ==2)
 *   MODE             : variable (右辺が識別子)
 *   variable         : MODE     (識別子なので自身もスイッチ扱い)
 */
#define LOCAL_LOG_ENABLE
#ifdef LOCAL_LOG_ENABLE
int a(void) { return 0; }
#endif

#if TOOL_TEST == 1
int t1(void) { return 0; }
#elif TOOL_TEST == 2
int t2(void) { return 0; }
#endif

#if MODE == variable
int v(void) { return 0; }
#endif
