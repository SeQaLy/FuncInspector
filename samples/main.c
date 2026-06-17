#include <stdio.h>
#include "features.h"

int main(void)
{
    return 0;
}

/* フラグ: USE_FEATURE_X を選択した時だけ */
#ifdef USE_FEATURE_X
int feature_x_init(void)
{
    return FEATURE_X_LEVEL;
}
#endif

/* 派生値 DEBUG_BUILD (BUILD_LEVEL>=2 → 1) → resolve では既定で出る */
#if DEBUG_BUILD == 1
int debug_dump(void)
{
    return 0;
}
#endif

/* ---- 複雑なネスト (最大4段) ---- */
#if BUILD_LEVEL >= 1
  #ifdef PLATFORM_ARM
    #if WORD_SIZE == 32
int arm32_handler(void) { return 0; }
    #elif WORD_SIZE == 16
int arm16_handler(void) { return 0; }
    #endif
  #else
    #if MAX_UNITS > 2
int generic_multi(void) { return 0; }
    #else
int generic_single(void) { return 0; }
    #endif
  #endif
#endif
