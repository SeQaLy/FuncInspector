/* flagsw.c - include解決モードのルール検証
 * フラグ(値なし #define)=選択駆動 / 値あり #define=反映。
 *   resolve 未選択      : always_fn のみ (CFG_AAA/CFG_UFS_ENABLE はフラグ→OFF, CFG_NUM=10≠5)
 *   resolve -D CFG_AAA  : aaa_fn, always_fn
 *   resolve -D CFG_UFS_ENABLE : ufs_fn, always_fn (CFG_ENABLE=1 が連鎖)
 *   resolve -D CFG_NUM=5: num5_fn, always_fn (ピン留めで 10 を上書き)
 */
#define CFG_AAA
#ifdef CFG_AAA
int aaa_fn(void) { return 0; }
#endif

#define CFG_UFS_ENABLE
#ifdef CFG_UFS_ENABLE
#define CFG_ENABLE 1
#else
#define CFG_ENABLE 0
#endif

#if CFG_ENABLE == 1
int ufs_fn(void) { return 0; }
#endif

#define CFG_NUM 10
#if CFG_NUM == 5
int num5_fn(void) { return 0; }
#endif

void always_fn(void) { go(); }
