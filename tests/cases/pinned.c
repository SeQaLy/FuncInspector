/* pinned.c - コマンドライン -D がソース内の #define より優先(ピン留め)されるか
 * 期待:
 *   既定           : always のみ (#define TOOL_TEST 0 が効く)
 *   -D TOOL_TEST=1 : test_only と always (ピン留めで in-file #define を無視)
 */
#define TOOL_TEST 0

#if TOOL_TEST == 1
int test_only(void)
{
    return 0;
}
#endif

void always(void)
{
    ping();
}
