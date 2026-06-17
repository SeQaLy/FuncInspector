#include "features.h"

/* 呼び出し規約マクロ前置 (WINAMS) も検出できる */
void WINAMS startup(void)
{
}

/* 値マクロ MAX_UNITS による排他分岐 */
#if MAX_UNITS == 4
int units4_setup(void) { return 0; }
#elif MAX_UNITS == 2
int units2_setup(void) { return 0; }
#else
int units_other(void) { return 0; }
#endif

/* フラグ + 派生値のネスト */
#ifdef USE_FEATURE_X
  #if FEATURE_X_LEVEL >= 3
int fx_advanced(void) { return 0; }
  #else
int fx_basic(void) { return 0; }
  #endif
#endif
